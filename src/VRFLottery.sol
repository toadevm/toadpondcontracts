// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Chainlink VRF and CCIP imports
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// OpenZeppelin imports
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Uniswap V4 imports
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IUniswapV2Router02} from "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

interface IUniversalRouter {
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external payable;
}

contract VRFLottery is
    VRFV2PlusWrapperConsumerBase,
    CCIPReceiver,
    ReentrancyGuard,
    Pausable
{
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ===== CONSTANTS =====
    address private constant VRF_WRAPPER =
        0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1;
    address public constant POOL_MANAGER =
        0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address public constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant UNIVERSAL_ROUTER =
        0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address public constant UNISWAP_V2_ROUTER =
        0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;
    address public constant TOAD_TOKEN =
        0x0194d984f4445a3a0F4D0A6BD6D7c7fFba5363Bf;
    address public constant WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;

    uint256 public entryFeeBone = 100 ether;
    uint8 public constant MAX_PLAYERS = 10;
    uint8 public constant POINTS_PER_ENTRY = 5;
    uint8 public constant WINNERS_SHARE = 60;
    uint8 public constant DEV_SHARE = 5;
    uint8 public constant FUNDING_SHARE = 30;
    uint8 public constant BURN_SHARE = 5;

    uint256 public baseSlippage = 2500;
    uint256 public constant MIN_SLIPPAGE = 1000;
    uint256 public constant MAX_SLIPPAGE = 6000;
    uint256 public constant MIN_BONE_PER_ETH = 10;
    uint256 public constant MAX_BONE_PER_ETH = 100000000;

    // ===== MESSAGE TYPES =====
    enum MessageType {
        ENTRY_RESPONSE,
        WINNERS_NOTIFICATION,
        ROUND_SYNC,
        ENTRY_REQUEST
    }

    // ===== PACKED STRUCTS =====
    enum RoundState {
        Active,
        Full,
        VRFRequested,
        WinnersSelected,
        PrizesDistributed,
        Completed
    }

    struct Player {
        address playerAddress;
        uint64 sourceChain;
        uint8 flags; // bit 0: isLocal, bit 1: paidWithETH, bit 2: usedWinnings
    }

    struct LotteryRound {
        Player[] players;
        address[3] winners;
        uint128 totalPrizePoolBone;
        uint64 startTime;
        RoundState state;
        uint256 vrfRequestId;
        mapping(uint64 => uint32) chainPlayerCounts;
        mapping(uint64 => uint128) chainPrizePools;
    }

    struct RequestStatus {
        uint128 roundId;
        uint8 flags; // bit 0: fulfilled, bit 1: exists
        uint256[] randomWords;
    }

    struct BurnData {
        uint256 totalBoneForBurn;
        uint256 lastBurnTimestamp;
        uint256 burnCount;
    }

    // ===== EVENTS  =====
    event Enter(
        address indexed player,
        uint64 indexed sourceChain,
        bool paidWithETH
    );

    event CrossEntry(address indexed player, uint64 sourceChain);
    event Full(uint256 indexed roundId);
    event VRFDone(uint256 indexed requestId, uint256 roundId);
    event Winners(address[3] winners, uint256 roundId);
    event Withdraw(address indexed recipient, uint256 amount);
    event CCIPFail(address indexed player, uint64 indexed chain, string reason);
    event WinNotify(uint64 indexed chain, uint256 indexed roundId);
    event RoundSync(uint256 oldRound, uint256 newRound);
    event CCIPMessageReceived(
        uint64 indexed sourceChain,
        address sender,
        uint256 timestamp
    );
    event CCIPMessageType(uint8 messageType, uint64 sourceChain);
    event CCIPEntryRequest(
        address player,
        uint64 sourceChain,
        uint256 roundId,
        uint256 amount
    );
    event CCIPRejected(uint64 sourceChain, string reason);
    event EntryResponse(
        address indexed player,
        uint64 indexed sourceChain,
        bool accepted,
        string reason
    );

    // ===== ERRORS (shortened) =====
    error NotAdmin();
    error ZeroAddr();
    error MaxReached();
    error RoundFull();
    error Duplicate();
    error NoNFT();
    error NoWithdraw();
    error WithdrawFail();
    error ChainNotOK();
    error NotActive();
    error NotFull();
    error VRFAlready();
    error NoWinners();
    error AlreadyDist();
    error NotDist();
    error NotComplete();
    error AlreadyComplete();
    error LowBone();
    error LowLink();
    error LowETH();
    error SwapFail();
    error SlippageHigh();
    error BadState();
    error BadPrice();
    error StalePrice();
    error LowWinnings();
    error BadRoute();
    error BurnSlippageHigh();
    error NothingBurn();

    // ===== MODIFIERS =====
    modifier onlyAdmin() {
        if (contractAdmin != msg.sender) revert NotAdmin();
        _;
    }

    modifier onlyActiveRound() {
        LotteryRound storage round = lotteryRounds[currentRoundId];
        if (round.state != RoundState.Active) revert NotActive();
        if (round.players.length >= MAX_PLAYERS) revert RoundFull();
        _;
    }

    // ===== STORAGE =====
    address public contractAdmin;

    IERC721 public immutable nftContract;
    IERC20 public immutable boneToken;
    address payable public immutable devAddress;
    uint64 public immutable currentChainSelector;
    IPoolManager public immutable poolManager;
    IPermit2 public immutable permit2;
    IUniversalRouter public immutable universalRouter;
    IUniswapV2Router02 public immutable uniswapV2Router;
    AggregatorV3Interface public immutable ethUsdPriceFeed;

    PoolKey public boneEthPoolKey;
    uint128 public currentRoundId;
    uint32 public vrfConfig;
    address[] public toadBurnRoute;
    uint256 public burnSlippage = 1000;
    BurnData public burnData;
    address payable[5] public fundingAddresses;
    uint64[] public configuredChains;
    uint32 public ccipGasLimit = 400000;

    mapping(uint64 => bool) public allowedChains;
    mapping(uint64 => address) public chainContracts;
    mapping(uint256 => LotteryRound) public lotteryRounds;
    mapping(uint256 => RequestStatus) public vrfRequests;
    mapping(address => uint128) public pendingWithdrawalsBone;
    mapping(address => uint128) public totalWinningsBone;
    mapping(address => uint32) public entriesCount;
    mapping(address => uint32) public playerPoints;

    // ===== CONSTRUCTOR =====
    constructor(
        address _ccipRouter,
        uint64 _currentChainSelector,
        address _nftContract,
        address _existingBoneToken,
        address payable _devAddress,
        address payable[5] memory _fundingAddresses,
        PoolKey memory _existingBoneEthPoolKey,
        address _ethUsdPriceFeed
    ) VRFV2PlusWrapperConsumerBase(VRF_WRAPPER) CCIPReceiver(_ccipRouter) {
        if (
            _nftContract == address(0) ||
            _existingBoneToken == address(0) ||
            _devAddress == address(0) ||
            _ethUsdPriceFeed == address(0)
        ) {
            revert ZeroAddr();
        }

        contractAdmin = _devAddress;

        currentChainSelector = _currentChainSelector;
        nftContract = IERC721(_nftContract);
        boneToken = IERC20(_existingBoneToken);
        devAddress = _devAddress;
        fundingAddresses = _fundingAddresses;

        poolManager = IPoolManager(POOL_MANAGER);
        permit2 = IPermit2(PERMIT2);
        universalRouter = IUniversalRouter(UNIVERSAL_ROUTER);
        uniswapV2Router = IUniswapV2Router02(UNISWAP_V2_ROUTER);
        boneEthPoolKey = _existingBoneEthPoolKey;
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);

        toadBurnRoute = [_existingBoneToken, WETH, TOAD_TOKEN];
        IERC20(_existingBoneToken).approve(
            UNISWAP_V2_ROUTER,
            type(uint256).max
        );

        // Pack VRF config: callbackGasLimit(500000) + requestConfirmations(3) + numWords(3)
        vrfConfig = (2000000 << 8) | (3 << 4) | 3;

        currentRoundId = 1;
        lotteryRounds[1].state = RoundState.Active;
        lotteryRounds[1].startTime = uint64(block.timestamp);
    }

    // ===== INTERNAL HELPERS =====
    function _getVRFParams()
        internal
        view
        returns (uint32 gasLimit, uint16 confirmations, uint32 numWords)
    {
        gasLimit = uint32(vrfConfig >> 8);
        confirmations = uint16((vrfConfig >> 4) & 0xF);
        numWords = uint32(vrfConfig & 0xF);
    }

    function _createPlayerFlags(
        bool isLocal,
        bool paidWithETH,
        bool usedWinnings
    ) internal pure returns (uint8 flags) {
        flags = 0;
        if (isLocal) flags |= 1;
        if (paidWithETH) flags |= 2;
        if (usedWinnings) flags |= 4;
    }

    function _getPlayerFlags(
        Player memory player
    )
        internal
        pure
        returns (bool isLocal, bool paidWithETH, bool usedWinnings)
    {
        isLocal = (player.flags & 1) != 0;
        paidWithETH = (player.flags & 2) != 0;
        usedWinnings = (player.flags & 4) != 0;
    }

    // ===== PRICE FUNCTIONS =====
    function _getETHPriceUSD()
        internal
        view
        returns (uint256 ethPrice, bool valid)
    {
        try ethUsdPriceFeed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (answer > 0 && block.timestamp - updatedAt <= 3600) {
                ethPrice = uint256(answer);
                valid = true;
            }
        } catch {
            valid = false;
        }
    }

    function _getBonePriceFromPool()
        internal
        view
        returns (uint256 bonePerEth, bool valid)
    {
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(
            boneEthPoolKey.toId()
        );
        if (sqrtPriceX96 == 0) return (0, false);

        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        bonePerEth = numerator >> 192;

        valid =
            bonePerEth >= MIN_BONE_PER_ETH &&
            bonePerEth <= MAX_BONE_PER_ETH;
    }

    function _calculateETHRequired()
        internal
        view
        returns (uint256 ethRequired, bool valid)
    {
        (uint256 poolBonePerETH, bool poolValid) = _getBonePriceFromPool();

        if (!poolValid || poolBonePerETH == 0) return (0, false);

        ethRequired = entryFeeBone / poolBonePerETH;
        ethRequired = (ethRequired * (10000 + baseSlippage)) / 10000;

        valid = ethRequired >= 0.00001 ether && ethRequired <= 5 ether;
    }

    // ===== ENTRY FUNCTIONS =====
    function enterWithBone()
        external
        nonReentrant
        whenNotPaused
        onlyActiveRound
    {
        if (nftContract.balanceOf(msg.sender) == 0) revert NoNFT();
        if (boneToken.balanceOf(msg.sender) < entryFeeBone) revert LowBone();

        boneToken.transferFrom(msg.sender, address(this), entryFeeBone);
        _addPlayerToRound(msg.sender, currentChainSelector, true, false, false);

        emit Enter(msg.sender, currentChainSelector, false);
    }

    function enterWithWinnings()
        external
        nonReentrant
        whenNotPaused
        onlyActiveRound
    {
        if (nftContract.balanceOf(msg.sender) == 0) revert NoNFT();

        uint256 pendingAmount = pendingWithdrawalsBone[msg.sender];
        if (pendingAmount < entryFeeBone) revert LowWinnings();

        pendingWithdrawalsBone[msg.sender] -= uint128(entryFeeBone);
        _addPlayerToRound(msg.sender, currentChainSelector, true, false, true);

        emit Enter(msg.sender, currentChainSelector, false);
    }

    function enterWithETH()
        external
        payable
        nonReentrant
        whenNotPaused
        onlyActiveRound
    {
        if (nftContract.balanceOf(msg.sender) == 0) revert NoNFT();

        (, bool ethValid) = _getETHPriceUSD();
        (uint256 poolBonePerETH, bool poolValid) = _getBonePriceFromPool();

        if (!ethValid || !poolValid) revert BadPrice();

        uint256 baseRequired = entryFeeBone / poolBonePerETH;
        uint256 ethWithSlippage = (baseRequired * (10000 + baseSlippage)) /
            10000;
        uint256 optimalAmount = (ethWithSlippage * 12000) / 10000;

        if (msg.value < optimalAmount) revert LowETH();

        uint256 initialBoneBalance = boneToken.balanceOf(address(this));
        uint256 ethUsed;
        bool swapSucceeded = false;

        try this._performSwap(entryFeeBone, optimalAmount) returns (
            uint256 _ethUsed
        ) {
            ethUsed = _ethUsed;
            swapSucceeded = true;

            uint256 finalBoneBalance = boneToken.balanceOf(address(this));
            require(
                finalBoneBalance >= initialBoneBalance + entryFeeBone,
                "Low BONE"
            );
        } catch {
            swapSucceeded = false;
            (bool success, ) = msg.sender.call{value: msg.value}("");
            require(success, "Refund fail");
            revert SwapFail();
        }

        _adjustSlippage(swapSucceeded, optimalAmount, ethUsed);

        uint256 ethToRefund = msg.value - ethUsed;
        if (ethToRefund > 0) {
            (bool success, ) = msg.sender.call{value: ethToRefund}("");
            require(success, "Refund fail");
        }

        _addPlayerToRound(msg.sender, currentChainSelector, true, true, false);

        emit Enter(msg.sender, currentChainSelector, true);
    }

    function getOptimalETHAmount()
        external
        view
        returns (uint256 optimalAmount, bool available, string memory message)
    {
        (, bool ethValid) = _getETHPriceUSD();
        (uint256 poolBonePerETH, bool poolValid) = _getBonePriceFromPool();

        if (!ethValid || !poolValid) {
            return (0, false, "ETH entry unavailable - use BONE");
        }

        uint256 baseRequired = entryFeeBone / poolBonePerETH;
        uint256 ethWithSlippage = (baseRequired * (10000 + baseSlippage)) /
            10000;
        optimalAmount = (ethWithSlippage * 12000) / 10000;

        available = true;
        message = "Auto-optimal amount";
    }

    function _performSwap(
        uint256 boneAmountOut,
        uint256 maxEthIn
    ) external returns (uint256 ethUsed) {
        require(msg.sender == address(this), "Internal only");
        return _swapETHForFixedBone(boneAmountOut, maxEthIn);
    }

    function _swapETHForFixedBone(
        uint256 boneAmountOut,
        uint256 maxEthIn
    ) internal returns (uint256 ethUsed) {
        uint256 initialEthBalance = address(this).balance - maxEthIn;

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        bool zeroForOne = Currency.unwrap(boneEthPoolKey.currency0) ==
            address(0);

        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: boneEthPoolKey,
                zeroForOne: zeroForOne,
                amountOut: uint128(boneAmountOut),
                amountInMaximum: uint128(maxEthIn),
                hookData: bytes("")
            })
        );

        params[1] = abi.encode(Currency.wrap(address(0)), maxEthIn);
        params[2] = abi.encode(
            Currency.wrap(address(boneToken)),
            boneAmountOut
        );

        inputs[0] = abi.encode(actions, params);
        uint256 deadline = block.timestamp + 300;

        universalRouter.execute{value: maxEthIn}(commands, inputs, deadline);

        uint256 finalEthBalance = address(this).balance;
        ethUsed = initialEthBalance + maxEthIn - finalEthBalance;

        return ethUsed;
    }

    function _adjustSlippage(bool swapSucceeded, uint256, uint256) internal {
        if (swapSucceeded) {
            if (baseSlippage > MIN_SLIPPAGE + 300) {
                baseSlippage -= 50;
            }
        } else {
            baseSlippage += 200;
            if (baseSlippage > MAX_SLIPPAGE) {
                baseSlippage = MAX_SLIPPAGE;
            }
        }
    }

    // ===== PLAYER MANAGEMENT =====
    function _addPlayerToRound(
        address player,
        uint64 sourceChain,
        bool isLocal,
        bool paidWithETH,
        bool usedWinnings
    ) internal {
        LotteryRound storage round = lotteryRounds[currentRoundId];

        uint256 length = round.players.length;
        for (uint256 i; i < length; ) {
            if (round.players[i].playerAddress == player) revert Duplicate();
            unchecked {
                ++i;
            }
        }

        Player memory newPlayer = Player({
            playerAddress: player,
            sourceChain: sourceChain,
            flags: _createPlayerFlags(isLocal, paidWithETH, usedWinnings)
        });
        round.players.push(newPlayer);

        unchecked {
            round.totalPrizePoolBone += uint128(entryFeeBone);
            ++round.chainPlayerCounts[sourceChain];
            round.chainPrizePools[sourceChain] += uint128(entryFeeBone);
            ++entriesCount[player];
            playerPoints[player] += POINTS_PER_ENTRY;
        }

        if (round.players.length == MAX_PLAYERS) {
            round.state = RoundState.Full;
            emit Full(currentRoundId);
        }
    }

    // ===== VRF FUNCTIONS =====
    function requestRandomWords() external {
        LotteryRound storage round = lotteryRounds[currentRoundId];
        if (round.state != RoundState.Full) revert NotFull();
        if (round.vrfRequestId != 0) revert VRFAlready();

        uint256 linkBalance = i_linkToken.balanceOf(address(this));
        if (linkBalance < 1 ether) revert LowLink();

        bytes memory extraArgs = VRFV2PlusClient._argsToBytes(
            VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
        );

        (
            uint32 gasLimit,
            uint16 confirmations,
            uint32 numWords
        ) = _getVRFParams();

        (uint256 requestId, ) = requestRandomness(
            gasLimit,
            confirmations,
            numWords,
            extraArgs
        );

        RequestStatus storage request = vrfRequests[requestId];
        request.roundId = currentRoundId;
        request.flags = 2; // exists = true
        delete request.randomWords;

        round.state = RoundState.VRFRequested;
        round.vrfRequestId = requestId;
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        RequestStatus storage request = vrfRequests[requestId];
        if ((request.flags & 2) == 0) return; // not exists

        request.flags |= 1; // fulfilled = true
        request.randomWords = randomWords;

        uint256 roundId = request.roundId;
        LotteryRound storage round = lotteryRounds[roundId];
        if (round.state != RoundState.VRFRequested) return;

        _selectWinnersOnly(roundId, randomWords);
        emit VRFDone(requestId, roundId);

        _distributePrizesInternal(roundId);
        _completeRoundInternal(roundId);
    }

    function _selectWinnersOnly(
        uint256 roundId,
        uint256[] memory randomWords
    ) internal {
        LotteryRound storage round = lotteryRounds[roundId];
        if (round.state != RoundState.VRFRequested) return;

        uint256 playerCount = round.players.length;
        if (playerCount == 0) return;

        // Clear previous winners
        round.winners[0] = address(0);
        round.winners[1] = address(0);
        round.winners[2] = address(0);

        uint256 winnerCount = playerCount >= 3 ? 3 : playerCount;
        address[] memory tempWinners = new address[](winnerCount);

        // Create a copy of players to modify during selection
        address[] memory availablePlayers = new address[](playerCount);
        for (uint256 i = 0; i < playerCount; i++) {
            availablePlayers[i] = round.players[i].playerAddress;
        }

        // Select winners without replacement
        for (uint256 i = 0; i < winnerCount; i++) {
            uint256 randomIndex = randomWords[i % randomWords.length] %
                (playerCount - i);
            tempWinners[i] = availablePlayers[randomIndex];

            // Remove selected player by swapping with last element
            availablePlayers[randomIndex] = availablePlayers[
                playerCount - 1 - i
            ];
        }

        // Store winners in round
        for (uint256 i = 0; i < winnerCount; i++) {
            round.winners[i] = tempWinners[i];
        }

        round.state = RoundState.WinnersSelected;
        emit Winners(round.winners, roundId);
    }

    function distributePrizes(uint256 roundId) external {
        LotteryRound storage round = lotteryRounds[roundId];
        if (round.state != RoundState.WinnersSelected) revert NoWinners();
        _distributePrizesInternal(roundId);
    }

    function _distributePrizesInternal(uint256 roundId) internal {
        LotteryRound storage round = lotteryRounds[roundId];
        uint256 totalPrize = round.totalPrizePoolBone;
        if (totalPrize == 0) return;

        // Calculate local chain's contribution
        uint256 localContribution = totalPrize;
        for (uint256 i = 0; i < configuredChains.length; i++) {
            localContribution -= round.chainPrizePools[configuredChains[i]];
        }

        // Distribute based on local contribution
        uint256 localWinnersTotal = (localContribution * WINNERS_SHARE) / 100;
        uint256 localDevAmount = (localContribution * DEV_SHARE) / 100;
        uint256 localFundingTotal = (localContribution * FUNDING_SHARE) / 100;

        uint256 localWinnerAmount = localWinnersTotal / 3;
        uint256 localFundingPerAddress = localFundingTotal / 5;

        // Distribute to winners (proportional share from this chain)
        for (uint256 i; i < 3; ) {
            if (round.winners[i] != address(0)) {
                pendingWithdrawalsBone[round.winners[i]] += uint128(
                    localWinnerAmount
                );
                totalWinningsBone[round.winners[i]] += uint128(
                    localWinnerAmount
                );
            }
            unchecked {
                ++i;
            }
        }

        // Local dev and funding distribution
        pendingWithdrawalsBone[devAddress] += uint128(localDevAmount);
        totalWinningsBone[devAddress] += uint128(localDevAmount);

        for (uint256 i; i < 5; ) {
            pendingWithdrawalsBone[fundingAddresses[i]] += uint128(
                localFundingPerAddress
            );
            totalWinningsBone[fundingAddresses[i]] += uint128(
                localFundingPerAddress
            );
            unchecked {
                ++i;
            }
        }

        round.state = RoundState.PrizesDistributed;
    }

    function completeRound(uint256 roundId) external {
        LotteryRound storage round = lotteryRounds[roundId];
        if (round.state != RoundState.PrizesDistributed) revert NotDist();
        _completeRoundInternal(roundId);
    }

    function _completeRoundInternal(uint256 roundId) internal {
        LotteryRound storage round = lotteryRounds[roundId];
        round.state = RoundState.Completed;

        uint256 burnAmount = (uint256(round.totalPrizePoolBone) * BURN_SHARE) /
            100;
        if (burnAmount > 0) {
            burnData.totalBoneForBurn += burnAmount;
        }

        _notifyCrossChainWinners(roundId);

        if (roundId == currentRoundId) {
            unchecked {
                ++currentRoundId;
            }

            LotteryRound storage newRound = lotteryRounds[currentRoundId];
            newRound.state = RoundState.Active;
            newRound.startTime = uint64(block.timestamp);
        }
    }

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawalsBone[msg.sender];
        if (amount == 0) revert NoWithdraw();

        pendingWithdrawalsBone[msg.sender] = 0;
        boneToken.transfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    // ===== TOAD BURNING FUNCTIONS =====
    function buyAndBurnTOAD(
        uint256 boneAmount
    ) external onlyAdmin nonReentrant {
        if (boneAmount > burnData.totalBoneForBurn) revert NothingBurn();
        if (boneAmount == 0) revert NothingBurn();

        burnData.totalBoneForBurn -= boneAmount;

        try this._performTOADBuy(boneAmount) returns (uint256 toadReceived) {
            if (toadReceived > 0) {
                IERC20(TOAD_TOKEN).transfer(DEAD_ADDRESS, toadReceived);

                unchecked {
                    ++burnData.burnCount;
                }
                burnData.lastBurnTimestamp = block.timestamp;
            }
        } catch {
            burnData.totalBoneForBurn += boneAmount;
            revert SwapFail();
        }
    }

    function _performTOADBuy(
        uint256 boneAmount
    ) external returns (uint256 toadReceived) {
        require(msg.sender == address(this), "Internal only");
        return _swapBoneForTOAD(boneAmount);
    }

    function _swapBoneForTOAD(
        uint256 boneAmount
    ) internal returns (uint256 toadReceived) {
        uint256[] memory amountsOut = uniswapV2Router.getAmountsOut(
            boneAmount,
            toadBurnRoute
        );
        uint256 minToadOut = (amountsOut[amountsOut.length - 1] *
            (10000 - burnSlippage)) / 10000;

        uint256[] memory amounts = uniswapV2Router.swapExactTokensForTokens(
            boneAmount,
            minToadOut,
            toadBurnRoute,
            address(this),
            block.timestamp + 300
        );

        toadReceived = amounts[amounts.length - 1];

        return toadReceived;
    }

    function updateBurnSlippage(uint256 newSlippage) external onlyAdmin {
        if (newSlippage > 5000) revert BurnSlippageHigh();
        burnSlippage = newSlippage;
    }

    // ===== UPDATED CCIP FUNCTIONS =====

    function _notifyCrossChainWinners(uint256 roundId) internal {
        LotteryRound storage round = lotteryRounds[roundId];

        // Build chain contributions array
        uint256 chainCount = configuredChains.length;
        uint64[] memory chains = new uint64[](chainCount);
        uint128[] memory contributions = new uint128[](chainCount);

        for (uint256 i = 0; i < chainCount; i++) {
            uint64 chainSelector = configuredChains[i];
            chains[i] = chainSelector;
            contributions[i] = round.chainPrizePools[chainSelector];
        }

        // Calculate this chain's contribution
        uint128 thisChainContribution = round.totalPrizePoolBone;
        for (uint256 i = 0; i < chainCount; i++) {
            thisChainContribution -= contributions[i];
        }

        for (uint256 i = 0; i < chainCount; i++) {
            uint64 chainSelector = chains[i];
            address contractAddress = chainContracts[chainSelector];

            if (contractAddress != address(0)) {
                // Send only winners, not all players
                bytes memory data = abi.encode(
                    uint8(MessageType.WINNERS_NOTIFICATION),
                    roundId,
                    round.winners,
                    round.totalPrizePoolBone,
                    thisChainContribution,
                    chains,
                    contributions
                );

                Client.EVM2AnyMessage memory ccipMessage = Client
                    .EVM2AnyMessage({
                        receiver: abi.encode(contractAddress),
                        data: data,
                        tokenAmounts: new Client.EVMTokenAmount[](0),
                        extraArgs: Client._argsToBytes(
                            Client.EVMExtraArgsV1({gasLimit: ccipGasLimit})
                        ),
                        feeToken: address(0)
                    });

                try
                    IRouterClient(i_ccipRouter).ccipSend{
                        value: IRouterClient(i_ccipRouter).getFee(
                            chainSelector,
                            ccipMessage
                        )
                    }(chainSelector, ccipMessage)
                {
                    emit WinNotify(chainSelector, roundId);
                } catch {
                    emit CCIPFail(
                        address(0),
                        chainSelector,
                        "Winners notification failed"
                    );
                }
            }
        }
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        uint64 sourceChain = message.sourceChainSelector;

        // Emit event for any CCIP message received
        emit CCIPMessageReceived(
            sourceChain,
            abi.decode(message.sender, (address)),
            block.timestamp
        );

        if (!allowedChains[sourceChain]) {
            emit CCIPRejected(sourceChain, "Chain not allowed");
            revert ChainNotOK();
        }

        bytes memory data = message.data;
        uint8 messageType;
        assembly {
            messageType := byte(0, mload(add(data, 63)))
        }

        // Emit message type
        emit CCIPMessageType(messageType, sourceChain);

        if (messageType == uint8(MessageType.ENTRY_REQUEST)) {
            (
                ,
                // Skip the message type
                uint256 remoteRoundId,
                address player,
                uint256 boneAmount
            ) = abi.decode(data, (uint8, uint256, address, uint256));

            // Emit entry request details
            emit CCIPEntryRequest(
                player,
                sourceChain,
                remoteRoundId,
                boneAmount
            );

            if (remoteRoundId > currentRoundId) {
                _syncToRound(remoteRoundId);
            }

            // Process the entry request
            _processEntryRequest(player, boneAmount, sourceChain);
        } else if (messageType == uint8(MessageType.ROUND_SYNC)) {
            (, uint256 newRoundId) = abi.decode(data, (uint8, uint256));

            if (newRoundId > currentRoundId) {
                _syncToRound(newRoundId);
            }
        }
    }

    function _processEntryRequest(
        address player,
        uint256 boneAmount,
        uint64 sourceChain
    ) internal {
        bool hasNFT = nftContract.balanceOf(player) > 0;
        bool accepted = false;
        string memory reason = "";

        if (!hasNFT) {
            reason = "No NFT owned";
        } else if (boneAmount != entryFeeBone) {
            reason = "Incorrect entry fee";
        } else {
            LotteryRound storage round = lotteryRounds[currentRoundId];

            if (round.state != RoundState.Active) {
                reason = "Round not active";
            } else if (round.players.length >= MAX_PLAYERS) {
                reason = "Round full";
            } else {
                // Check for duplicate
                bool isDuplicate = false;
                for (uint256 i = 0; i < round.players.length; i++) {
                    if (round.players[i].playerAddress == player) {
                        isDuplicate = true;
                        break;
                    }
                }

                if (isDuplicate) {
                    reason = "Already entered";
                } else {
                    // SUCCESS - Add player and send success response
                    _addPlayerToRound(player, sourceChain, false, false, false);
                    emit CrossEntry(player, sourceChain);
                    accepted = true;
                    reason = "Entry accepted";
                }
            }
        }

        // Send verification response back to cross-chain contract
        _sendVerificationResponse(player, sourceChain, accepted, reason);

        emit EntryResponse(player, sourceChain, accepted, reason);
    }

    function _sendVerificationResponse(
        address player,
        uint64 sourceChain,
        bool accepted,
        string memory reason
    ) internal {
        address contractAddress = chainContracts[sourceChain];

        if (contractAddress == address(0)) {
            emit CCIPFail(player, sourceChain, "Chain contract not set");
            return;
        }

        bytes memory data = abi.encode(
            uint8(MessageType.ENTRY_RESPONSE),
            currentRoundId,
            player,
            accepted,
            reason
        );

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(contractAddress),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: ccipGasLimit})
            ),
            feeToken: address(0)
        });

        try
            IRouterClient(i_ccipRouter).ccipSend{
                value: IRouterClient(i_ccipRouter).getFee(
                    sourceChain,
                    ccipMessage
                )
            }(sourceChain, ccipMessage)
        {
            // Response sent successfully
        } catch {
            emit CCIPFail(player, sourceChain, "Response send failed");
        }
    }

    function _syncToRound(uint256 newRoundId) internal {
        if (newRoundId <= currentRoundId) return;

        uint256 oldRound = currentRoundId;

        // Complete current round if needed
        LotteryRound storage currentRound = lotteryRounds[currentRoundId];
        if (currentRound.state != RoundState.Completed) {
            currentRound.state = RoundState.Completed;
        }

        currentRoundId = uint128(newRoundId);

        // Initialize new round
        LotteryRound storage newRound = lotteryRounds[currentRoundId];
        newRound.state = RoundState.Active;
        newRound.startTime = uint64(block.timestamp);

        emit RoundSync(oldRound, newRoundId);
    }

    function getCCIPResponseCosts()
        external
        view
        returns (
            uint256 entryResponseCost,
            uint256 winnersNotificationCost,
            uint256 totalEstimatedCost
        )
    {
        bytes memory entryData = abi.encode(
            uint8(MessageType.ENTRY_RESPONSE),
            currentRoundId,
            address(0),
            true,
            "test"
        );
        Client.EVM2AnyMessage memory entryMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(address(0)),
            data: entryData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200000})
            ),
            feeToken: address(0)
        });

        if (configuredChains.length > 0) {
            uint64 exampleChain = configuredChains[0];
            try
                IRouterClient(i_ccipRouter).getFee(exampleChain, entryMessage)
            returns (uint256 entryCost) {
                entryResponseCost = entryCost;
            } catch {
                entryResponseCost = 0.001 ether;
            }

            // Estimate winners notification cost (larger message)
            winnersNotificationCost = entryResponseCost * 2;
        }

        totalEstimatedCost =
            (entryResponseCost * 4) +
            (winnersNotificationCost * configuredChains.length);
    }

    function getCurrentRoundPlayers() external view returns (Player[] memory) {
        return lotteryRounds[currentRoundId].players;
    }

    function getRoundInfo(
        uint256 roundId
    )
        external
        view
        returns (
            uint256 playerCount,
            RoundState state,
            address[3] memory winners,
            uint256 totalPrizePool,
            uint256 startTime
        )
    {
        LotteryRound storage round = lotteryRounds[roundId];
        return (
            round.players.length,
            round.state,
            round.winners,
            round.totalPrizePoolBone,
            round.startTime
        );
    }

    function getVRFRequestStatus(
        uint256 requestId
    )
        external
        view
        returns (
            bool exists,
            bool fulfilled,
            uint256[] memory randomWords,
            uint256 roundId
        )
    {
        RequestStatus storage request = vrfRequests[requestId];
        exists = (request.flags & 2) != 0;
        fulfilled = (request.flags & 1) != 0;
        randomWords = request.randomWords;
        roundId = request.roundId;
    }

    function setCCIPGasLimit(uint32 newGasLimit) external onlyAdmin {
        require(
            newGasLimit >= 100000 && newGasLimit <= 1000000,
            "Invalid gas limit"
        );
        ccipGasLimit = newGasLimit;
    }

    function getRoundVRFRequestId(
        uint256 roundId
    ) external view returns (uint256 requestId) {
        return lotteryRounds[roundId].vrfRequestId;
    }

    function getPoolKeyInfo() external view returns (PoolKey memory) {
        return boneEthPoolKey;
    }

    function getETHAmountForEntry() external view returns (uint256) {
        (uint256 ethRequired, bool valid) = _calculateETHRequired();
        return valid ? ethRequired : 0;
    }

    function getWinnerShareFromChain(
        uint256 roundId,
        address winner
    ) external view returns (uint256) {
        LotteryRound storage round = lotteryRounds[roundId];

        // Check if address is a winner
        bool isWinner = false;
        for (uint256 i = 0; i < 3; i++) {
            if (round.winners[i] == winner) {
                isWinner = true;
                break;
            }
        }

        if (!isWinner || round.totalPrizePoolBone == 0) return 0;

        // Calculate local contribution
        uint256 localContribution = round.totalPrizePoolBone;
        for (uint256 i = 0; i < configuredChains.length; i++) {
            localContribution -= round.chainPrizePools[configuredChains[i]];
        }

        // Calculate winner's share from this chain
        uint256 localWinnersTotal = (localContribution * WINNERS_SHARE) / 100;
        return localWinnersTotal / 3;
    }

    // ===== ADMIN FUNCTIONS =====
    function updatePoolKey(PoolKey memory _newPoolKey) external onlyAdmin {
        boneEthPoolKey = _newPoolKey;
    }

    function resetSlippage() external onlyAdmin {
        baseSlippage = 2500;
    }

    function emergencySelectWinners(uint256 roundId) external onlyAdmin {
        LotteryRound storage round = lotteryRounds[roundId];
        if (round.state != RoundState.VRFRequested || round.players.length == 0)
            return;

        uint256 pseudoRandom = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    blockhash(block.number - 1),
                    roundId
                )
            )
        );

        uint256[] memory randomWords = new uint256[](3);
        randomWords[0] = pseudoRandom;
        randomWords[1] = uint256(
            keccak256(abi.encodePacked(pseudoRandom, uint256(1)))
        );
        randomWords[2] = uint256(
            keccak256(abi.encodePacked(pseudoRandom, uint256(2)))
        );

        _selectWinnersOnly(roundId, randomWords);
    }

    function emergencyWithdrawTokens(
        address token,
        uint256 amount
    ) external onlyAdmin {
        require(
            token != address(boneToken) ||
                amount <= boneToken.balanceOf(address(this)) / 30,
            "Max 10% BONE"
        );
        IERC20(token).transfer(contractAdmin, amount);
    }

    function emergencyWithdrawETH() external onlyAdmin {
        uint256 balance = address(this).balance;
        (bool success, ) = contractAdmin.call{value: balance}("");
        require(success, "ETH fail");
    }

    function setVRFConfig(
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations,
        uint32 _numWords
    ) external onlyAdmin {
        vrfConfig =
            (_callbackGasLimit << 8) |
            (_requestConfirmations << 4) |
            _numWords;
    }

    function setEntryFee(uint256 newEntryFee) external onlyAdmin {
        require(newEntryFee > 0, "Entry fee must be positive");
        require(newEntryFee <= 1000 ether, "Entry fee too high");

        uint256 oldFee = entryFeeBone;
        entryFeeBone = newEntryFee;
    }

    function pauseContract() external onlyAdmin {
        _pause();
    }

    function unpauseContract() external onlyAdmin {
        _unpause();
    }

    function setChainContract(
        uint64 chainSelector,
        address contractAddress
    ) external onlyAdmin {
        chainContracts[chainSelector] = contractAddress;
        allowedChains[chainSelector] = contractAddress != address(0);

        if (contractAddress != address(0)) {
            bool exists = false;
            for (uint256 i = 0; i < configuredChains.length; i++) {
                if (configuredChains[i] == chainSelector) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                configuredChains.push(chainSelector);
            }
        } else {
            for (uint256 i = 0; i < configuredChains.length; i++) {
                if (configuredChains[i] == chainSelector) {
                    configuredChains[i] = configuredChains[
                        configuredChains.length - 1
                    ];
                    configuredChains.pop();
                    break;
                }
            }
        }
    }

    function emergencyNotifyWinners(
        uint256 roundId,
        uint64 destinationChain
    ) external onlyAdmin {
        LotteryRound storage round = lotteryRounds[roundId];
        address contractAddress = chainContracts[destinationChain];
        require(contractAddress != address(0), "Chain not set");

        // Build single chain data for emergency notification
        uint64[] memory chains = new uint64[](1);
        uint128[] memory contributions = new uint128[](1);
        chains[0] = currentChainSelector;
        contributions[0] = round.totalPrizePoolBone;

        // Send only winners data - no allPlayers array
        bytes memory data = abi.encode(
            uint8(MessageType.WINNERS_NOTIFICATION),
            roundId,
            round.winners,
            round.totalPrizePoolBone,
            round.totalPrizePoolBone,
            chains,
            contributions
        );

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(contractAddress),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: ccipGasLimit})
            ),
            feeToken: address(0)
        });

        IRouterClient(i_ccipRouter).ccipSend{
            value: IRouterClient(i_ccipRouter).getFee(
                destinationChain,
                ccipMessage
            )
        }(destinationChain, ccipMessage);

        emit WinNotify(destinationChain, roundId);
    }

    function forceRoundSync(uint256 newRoundId) external onlyAdmin {
        if (newRoundId > currentRoundId) {
            _syncToRound(newRoundId);
        }
    }

    receive() external payable {}
}
