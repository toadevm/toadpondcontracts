// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Chainlink VRF and CCIP imports
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

// OpenZeppelin imports
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// Uniswap V4 imports
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

// Universal Router imports
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/**
 * @title Fully Automatic VRF Lottery
 * @dev Prices update automatically before each ETH entry - zero manual intervention
 * @notice Users call enterWithETH() with any reasonable amount - contract handles all pricing
 */
contract VRFLottery is
    VRFV2PlusWrapperConsumerBase,
    CCIPReceiver,
    ReentrancyGuard,
    Pausable
{
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ===== CONSTANTS =====
    address private constant VRF_WRAPPER_ADDRESS = 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1;
    address public constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant UNIVERSAL_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Game constants
    uint256 public constant ENTRY_FEE_BONE = 1 ether;
    uint8 public constant MAX_PLAYERS = 4; // Maximum players per round to be modified later (e.g. 10 players)
    uint8 public constant POINTS_PER_ENTRY = 5;
    uint8 public constant WINNERS_SHARE = 60;
    uint8 public constant DEV_SHARE = 5;
    uint8 public constant FUNDING_SHARE = 30;
    uint8 public constant BURN_SHARE = 5;

    // ===== AUTOMATIC PRICING STRATEGY =====
    
    // Chainlink ETH/USD feed (reliable, exists everywhere)
    AggregatorV3Interface public immutable ethUsdPriceFeed;
    
    // Adaptive slippage based on market conditions
    uint256 public baseSlippage = 2500;               // 25% base (for low TVL pools)
    uint256 public constant MIN_SLIPPAGE = 1000;      // 10% minimum
    uint256 public constant MAX_SLIPPAGE = 6000;      // 60% maximum
    
    // Safety bounds (reasonable for existing BONE token)
    uint256 public constant MIN_BONE_PER_ETH = 10;
    uint256 public constant MAX_BONE_PER_ETH = 100000000;

    // ===== STRUCTS AND ENUMS =====
    
    enum RoundState {
        Active, Full, VRFRequested, WinnersSelected, PrizesDistributed, Completed
    }

    struct Player {
        address playerAddress;
        uint64 sourceChain;
        bool isLocal;
        bool paidWithETH;
    }

    struct LotteryRound {
        Player[] players;
        address[3] winners;
        uint128 totalPrizePoolBone;
        uint64 startTime;
        RoundState state;
        mapping(uint64 => uint32) chainPlayerCounts;
        mapping(uint64 => uint128) chainPrizePools;
    }

    struct RequestStatus {
        uint128 roundId;
        bool fulfilled;
        bool exists;
        uint256[] randomWords;
    }

    // ===== EVENTS =====
    
    event LotteryEnter(address indexed player, uint64 indexed sourceChain, bool paidWithETH);
    event ETHSwappedToBone(address indexed player, uint256 ethSent, uint256 ethUsed, uint256 ethRefunded, uint256 boneReceived);
    event CrossChainEntryReceived(address indexed player, uint64 sourceChain);
    event RoundFull(uint256 indexed roundId);
    event VRFRequested(uint256 indexed requestId, uint256 roundId);
    event VRFFulfilled(uint256 indexed requestId, uint256 roundId);
    event WinnersSelected(address[3] winners, uint256 roundId);
    event PrizesDistributed(uint256 roundId, uint256 totalPrizes);
    event RoundCompleted(uint256 indexed roundId, uint256 newRoundId);
    event WithdrawalMade(address indexed recipient, uint256 amount);
    event NewRoundStarted(uint256 indexed roundId);
    event TokensBurned(uint256 boneAmount);
    event LinkFunded(uint256 amount);
    event ETHWithdrawn(address indexed recipient, uint256 amount);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event PoolKeyUpdated(PoolKey newPoolKey);
    event GameCycleCompleted(uint256 indexed roundId);
    
    // Auto-pricing events
    event PricesUpdated(uint256 ethPriceUSD, uint256 poolBonePerETH, uint256 ethRequired);
    event SlippageAdjusted(uint256 oldSlippage, uint256 newSlippage, string reason);

    // CCIP events
    event CCIPFunded(address indexed funder, uint256 amount);
    event CCIPResponseFailed(address indexed player, uint64 indexed chain, string reason);
    event WinnersNotificationSent(uint64 indexed chain, uint256 indexed roundId);

    // ===== STATE VARIABLES =====
    
    address public contractAdmin;
    modifier onlyAdmin() {
        require(contractAdmin == msg.sender, "Caller is not the admin");
        _;
    }

    // Immutable variables
    IERC721 public immutable nftContract;
    IERC20 public immutable boneToken;
    address payable public immutable devAddress;
    uint64 public immutable currentChainSelector;
    IPoolManager public immutable poolManager;
    IPermit2 public immutable permit2;
    IUniversalRouter public immutable universalRouter;

    // Uniswap V4 configuration
    PoolKey public boneEthPoolKey;

    // Game state
    uint128 public currentRoundId;
    uint32 public callbackGasLimit = 500000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 3;

    // Funding addresses
    address payable[5] public fundingAddresses;

    // Chain configuration
    uint64[] public configuredChains;
    mapping(uint64 => bool) public allowedChains;
    mapping(uint64 => address) public chainContracts;

    // Lottery data
    mapping(uint256 => LotteryRound) public lotteryRounds;
    mapping(uint256 => RequestStatus) public vrfRequests;

    // Player data
    mapping(address => uint128) public pendingWithdrawalsBone;
    mapping(address => uint128) public totalWinningsBone;
    mapping(address => uint32) public entriesCount;
    mapping(address => uint32) public playerPoints;

    // ===== CUSTOM ERRORS =====
    
    error InvalidZeroAddress();
    error MaxPlayersReached();
    error DuplicateEntry();
    error NoNFTOwnership();
    error NoWithdrawalAvailable();
    error WithdrawalFailed();
    error ChainNotAllowed();
    error RoundNotActive();
    error RoundNotFull();
    error VRFAlreadyRequested();
    error WinnersNotSelected();
    error PrizesAlreadyDistributed();
    error PrizesNotDistributed();
    error RoundNotCompleted();
    error RoundAlreadyCompleted();
    error InsufficientBoneBalance();
    error InsufficientLinkFunds();
    error InsufficientETHAmount();
    error SwapFailed();
    error SlippageExceeded();
    error InvalidRoundState();
    error PoolPriceInvalid();
    error ETHPriceStale();

    modifier onlyActiveRound() {
        if (lotteryRounds[currentRoundId].state != RoundState.Active) revert RoundNotActive();
        _;
    }

    // ===== CONSTRUCTOR =====
    
    constructor(
        address _ccipRouter,
        uint64 _currentChainSelector,
        address _nftContract,
        address _existingBoneToken,      // Existing BONE token address
        address payable _devAddress,
        address payable[5] memory _fundingAddresses,
        PoolKey memory _existingBoneEthPoolKey, // Existing BONE/ETH pool
        address _ethUsdPriceFeed         // Chainlink ETH/USD feed
    ) VRFV2PlusWrapperConsumerBase(VRF_WRAPPER_ADDRESS) CCIPReceiver(_ccipRouter) {
        if (_nftContract == address(0) || _existingBoneToken == address(0) || _devAddress == address(0)) {
            revert InvalidZeroAddress();
        }
        if (_ethUsdPriceFeed == address(0)) revert InvalidZeroAddress();

        contractAdmin = _devAddress;
        emit AdminChanged(address(0), _devAddress);

        currentChainSelector = _currentChainSelector;
        nftContract = IERC721(_nftContract);
        boneToken = IERC20(_existingBoneToken);
        devAddress = _devAddress;
        fundingAddresses = _fundingAddresses;

        // Set Uniswap V4 addresses
        poolManager = IPoolManager(POOL_MANAGER);
        permit2 = IPermit2(PERMIT2);
        universalRouter = IUniversalRouter(UNIVERSAL_ROUTER);
        boneEthPoolKey = _existingBoneEthPoolKey;

        // Set Chainlink price feed
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);

        // Initialize first round
        currentRoundId = 1;
        lotteryRounds[1].state = RoundState.Active;
        lotteryRounds[1].startTime = uint64(block.timestamp);

        emit NewRoundStarted(1);
    }

    // ===== AUTOMATIC PRICE UPDATE SYSTEM =====

    /**
     * @dev Get current ETH price from Chainlink (automatically updated)
     */
    function _getETHPriceUSD() internal view returns (uint256 ethPrice, bool valid) {
        try ethUsdPriceFeed.latestRoundData() returns (
            uint80 /* roundId */,
            int256 answer,
            uint256 /* startedAt */,
            uint256 updatedAt,
            uint80 /* answeredInRound */
        ) {
            if (answer > 0 && block.timestamp - updatedAt <= 3600) {
                ethPrice = uint256(answer);
                valid = true;
            }
        } catch {
            // ETH price not available
            valid = false;
        }
    }

    /**
     * @dev Get BONE price from existing Uniswap pool (automatically updated) - FIXED
     */
    function _getBonePriceFromPool() internal view returns (uint256 bonePerEth, bool valid) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(boneEthPoolKey.toId());
        if (sqrtPriceX96 == 0) return (0, false);

        // CORRECTED CALCULATION:
        // sqrtPriceX96 = sqrt(BONE/ETH) * 2^96
        // price = (sqrtPriceX96)^2 / 2^192
        
        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        bonePerEth = numerator >> 192; // Right shift by 192 = divide by 2^192
        
        // Validate reasonable bounds
        valid = bonePerEth >= MIN_BONE_PER_ETH && bonePerEth <= MAX_BONE_PER_ETH;
    }

    /**
     * @dev Calculate required ETH amount with current prices (automatic) - FIXED BOUNDS
     */
    function _calculateETHRequired() internal view returns (uint256 ethRequired, bool valid) {
        (uint256 poolBonePerETH, bool poolValid) = _getBonePriceFromPool();
        
        if (!poolValid || poolBonePerETH == 0) return (0, false);
        
        // Calculate base ETH required for 1 BONE
        ethRequired = ENTRY_FEE_BONE / poolBonePerETH;
        
        // Add adaptive slippage
        ethRequired = (ethRequired * (10000 + baseSlippage)) / 10000;
        
        // FIXED BOUNDS: Allow smaller amounts (was 0.001 ether, now 0.00001 ether)
        valid = ethRequired >= 0.00001 ether && ethRequired <= 5 ether;
    }

    // ===== ENTRY FUNCTIONS =====

    /**
     * @dev Enter lottery with BONE tokens
     */
    function enterWithBone() external nonReentrant whenNotPaused onlyActiveRound {
        if (nftContract.balanceOf(msg.sender) == 0) revert NoNFTOwnership();
        if (boneToken.balanceOf(msg.sender) < ENTRY_FEE_BONE) revert InsufficientBoneBalance();

        boneToken.transferFrom(msg.sender, address(this), ENTRY_FEE_BONE);
        _addPlayerToRound(msg.sender, currentChainSelector, true, false);
        emit LotteryEnter(msg.sender, currentChainSelector, false);
    }

    /**
     * @dev Enter lottery with ETH - ZERO USER INPUT REQUIRED
     * @notice Users just call this function - contract calculates and uses optimal ETH amount
     */
    function enterWithETH() external payable nonReentrant whenNotPaused onlyActiveRound {
        if (nftContract.balanceOf(msg.sender) == 0) revert NoNFTOwnership();

        // 1. AUTOMATIC PRICE UPDATE & CALCULATION
        (, bool ethValid) = _getETHPriceUSD();
        (uint256 poolBonePerETH, bool poolValid) = _getBonePriceFromPool();
        
        if (!ethValid || !poolValid) {
            revert PoolPriceInvalid();
        }

        // 2. CALCULATE OPTIMAL ETH AMOUNT AUTOMATICALLY
        uint256 baseRequired = ENTRY_FEE_BONE / poolBonePerETH;
        uint256 ethWithSlippage = (baseRequired * (10000 + baseSlippage)) / 10000;
        
        // Add safety buffer (20% extra) for market volatility
        uint256 optimalAmount = (ethWithSlippage * 12000) / 10000;
        
        // Cap at reasonable maximum (2 ETH) and minimum (0.01 ETH)
        if (optimalAmount > 2 ether) optimalAmount = 2 ether;
        if (optimalAmount < 0.01 ether) optimalAmount = 0.01 ether;

        // 3. VALIDATE USER SENT ENOUGH ETH
        if (msg.value < optimalAmount) {
            revert("Insufficient ETH - contract calculated optimal amount automatically");
        }

        emit PricesUpdated(ethValid ? 1 : 0, poolBonePerETH, optimalAmount);

        // 4. PERFORM SWAP WITH CALCULATED AMOUNT
        uint256 initialBoneBalance = boneToken.balanceOf(address(this));
        uint256 ethUsed;
        bool swapSucceeded = false;

        try this._performSwap(ENTRY_FEE_BONE, optimalAmount) returns (uint256 _ethUsed) {
            ethUsed = _ethUsed;
            swapSucceeded = true;
            
            // Verify BONE received
            uint256 finalBoneBalance = boneToken.balanceOf(address(this));
            require(finalBoneBalance >= initialBoneBalance + ENTRY_FEE_BONE, "Insufficient BONE received");
            
        } catch {
            // Swap failed - refund and adjust slippage for next user
            swapSucceeded = false;
            
            (bool success, ) = msg.sender.call{value: msg.value}("");
            require(success, "Emergency refund failed");
            revert SwapFailed();
        }

        // 5. AUTO-ADJUST SLIPPAGE FOR FUTURE USERS
        _adjustSlippage(swapSucceeded, optimalAmount, ethUsed);

        // 6. REFUND ALL EXCESS ETH (user always gets refund)
        uint256 ethToRefund = msg.value - ethUsed;
        if (ethToRefund > 0) {
            (bool success, ) = msg.sender.call{value: ethToRefund}("");
            require(success, "ETH refund failed");
        }

        // 7. ADD PLAYER TO LOTTERY
        _addPlayerToRound(msg.sender, currentChainSelector, true, true);
        emit ETHSwappedToBone(msg.sender, msg.value, ethUsed, ethToRefund, ENTRY_FEE_BONE);
        emit LotteryEnter(msg.sender, currentChainSelector, true);
    }

    /**
     * @dev Get the current optimal ETH amount for entry (for frontend display)
     */
    function getOptimalETHAmount() external view returns (
        uint256 optimalAmount,
        bool available,
        string memory message
    ) {
        (, bool ethValid) = _getETHPriceUSD();
        (uint256 poolBonePerETH, bool poolValid) = _getBonePriceFromPool();
        
        if (!ethValid || !poolValid) {
            return (0, false, "ETH entry temporarily unavailable - use BONE entry");
        }

        // Calculate optimal amount
        uint256 baseRequired = ENTRY_FEE_BONE / poolBonePerETH;
        uint256 ethWithSlippage = (baseRequired * (10000 + baseSlippage)) / 10000;
        optimalAmount = (ethWithSlippage * 12000) / 10000; // 20% safety buffer
        
        // Apply caps
        if (optimalAmount > 2 ether) optimalAmount = 2 ether;
        if (optimalAmount < 0.01 ether) optimalAmount = 0.01 ether;
        
        available = true;
        message = "Contract will automatically use optimal amount";
    }

    /**
     * @dev Internal swap wrapper for try/catch
     */
    function _performSwap(uint256 boneAmountOut, uint256 maxEthIn) external returns (uint256 ethUsed) {
        require(msg.sender == address(this), "Internal function");
        return _swapETHForFixedBone(boneAmountOut, maxEthIn);
    }

    /**
     * @dev Swap ETH for exact BONE amount using Uniswap V4
     */
    function _swapETHForFixedBone(uint256 boneAmountOut, uint256 maxEthIn) internal returns (uint256 ethUsed) {
        uint256 initialEthBalance = address(this).balance - maxEthIn;
        
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        
        bytes[] memory params = new bytes[](3);
        bool zeroForOne = Currency.unwrap(boneEthPoolKey.currency0) == address(0);
        
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
        params[2] = abi.encode(Currency.wrap(address(boneToken)), boneAmountOut);
        
        inputs[0] = abi.encode(actions, params);
        uint256 deadline = block.timestamp + 300;
        
        universalRouter.execute{value: maxEthIn}(commands, inputs, deadline);
        
        uint256 finalEthBalance = address(this).balance;
        ethUsed = initialEthBalance + maxEthIn - finalEthBalance;
        
        return ethUsed;
    }

    /**
     * @dev Adjust slippage based on swap performance (automatic learning)
     */
    function _adjustSlippage(bool swapSucceeded, uint256 /* ethSent */, uint256 /* ethUsed */) internal {
        uint256 oldSlippage = baseSlippage;
        
        if (swapSucceeded) {
            // Success - slightly reduce slippage for efficiency
            if (baseSlippage > MIN_SLIPPAGE + 100) {
                baseSlippage -= 100; // Reduce by 1%
            }
            emit SlippageAdjusted(oldSlippage, baseSlippage, "Success - reduced");
        } else {
            // Failed - increase slippage for reliability
            baseSlippage += 200; // Increase by 2%
            if (baseSlippage > MAX_SLIPPAGE) {
                baseSlippage = MAX_SLIPPAGE;
            }
            emit SlippageAdjusted(oldSlippage, baseSlippage, "Failure - increased");
        }
    }

    // ===== PLAYER MANAGEMENT =====

    function _addPlayerToRound(address player, uint64 sourceChain, bool isLocal, bool paidWithETH) internal {
        LotteryRound storage round = lotteryRounds[currentRoundId];

        if (round.players.length >= MAX_PLAYERS) revert MaxPlayersReached();

        uint256 length = round.players.length;
        for (uint256 i; i < length;) {
            if (round.players[i].playerAddress == player) revert DuplicateEntry();
            unchecked { ++i; }
        }

        round.players.push(Player({ 
            playerAddress: player, 
            sourceChain: sourceChain, 
            isLocal: isLocal, 
            paidWithETH: paidWithETH 
        }));

        unchecked {
            round.totalPrizePoolBone += uint128(ENTRY_FEE_BONE);
            ++round.chainPlayerCounts[sourceChain];
            round.chainPrizePools[sourceChain] += uint128(ENTRY_FEE_BONE);
            ++entriesCount[player];
            playerPoints[player] += POINTS_PER_ENTRY;
        }

        if (round.players.length == MAX_PLAYERS) {
            round.state = RoundState.Full;
            emit RoundFull(currentRoundId);
        }
    }

    // ===== VRF AND GAME LOGIC =====

    function requestRandomWords() external {
        LotteryRound storage round = lotteryRounds[currentRoundId];
        if (round.state != RoundState.Full) revert RoundNotFull();

        uint256 requestPrice = i_vrfV2PlusWrapper.calculateRequestPrice(callbackGasLimit, numWords);
        if (i_linkToken.balanceOf(address(this)) < requestPrice) {
            revert InsufficientLinkFunds();
        }

        (uint256 requestId, ) = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords,
            VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({ nativePayment: false }))
        );

        vrfRequests[requestId] = RequestStatus({ 
            randomWords: new uint256[](0), 
            exists: true, 
            fulfilled: false, 
            roundId: currentRoundId 
        });

        round.state = RoundState.VRFRequested;
        emit VRFRequested(requestId, currentRoundId);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        RequestStatus storage request = vrfRequests[requestId];
        if (!request.exists) return;

        request.fulfilled = true;
        request.randomWords = randomWords;

        LotteryRound storage round = lotteryRounds[request.roundId];
        if (round.state != RoundState.VRFRequested) return;

        _selectWinnersOnly(request.roundId, randomWords);
        emit VRFFulfilled(requestId, request.roundId);
    }

    function _selectWinnersOnly(uint256 roundId, uint256[] memory randomWords) internal {
        LotteryRound storage round = lotteryRounds[roundId];
        if (round.state != RoundState.VRFRequested) return;

        uint256 playerCount = round.players.length;
        if (playerCount == 0) return;

        uint256 winnerCount = playerCount >= 3 ? 3 : playerCount;
        bool[] memory used = new bool[](playerCount);

        for (uint256 i; i < winnerCount;) {
            uint256 index = randomWords[i % randomWords.length] % playerCount;
            uint256 attempts = 0;

            while (used[index] && attempts < playerCount) {
                index = (index + 1) % playerCount;
                attempts++;
            }

            if (attempts < playerCount) {
                used[index] = true;
                round.winners[i] = round.players[index].playerAddress;
            }

            unchecked { ++i; }
        }

        round.state = RoundState.WinnersSelected;
        emit WinnersSelected(round.winners, roundId);
    }

    function distributePrizes(uint256 roundId) external {
        LotteryRound storage round = lotteryRounds[roundId];
        if (round.state != RoundState.WinnersSelected) revert WinnersNotSelected();
        _distributePrizesInternal(roundId);
    }

    function _distributePrizesInternal(uint256 roundId) internal {
        LotteryRound storage round = lotteryRounds[roundId];
        uint256 totalPrize = round.totalPrizePoolBone;
        if (totalPrize == 0) return;

        uint256 winnersTotal = (totalPrize * WINNERS_SHARE) / 100;
        uint256 devAmount = (totalPrize * DEV_SHARE) / 100;
        uint256 fundingTotal = (totalPrize * FUNDING_SHARE) / 100;

        uint256 winnerAmount = winnersTotal / 3;
        for (uint256 i; i < 3;) {
            if (round.winners[i] != address(0)) {
                pendingWithdrawalsBone[round.winners[i]] += uint128(winnerAmount);
                totalWinningsBone[round.winners[i]] += uint128(winnerAmount);
            }
            unchecked { ++i; }
        }

        pendingWithdrawalsBone[devAddress] += uint128(devAmount);
        totalWinningsBone[devAddress] += uint128(devAmount);

        uint256 fundingPerAddress = fundingTotal / 5;
        for (uint256 i; i < 5;) {
            pendingWithdrawalsBone[fundingAddresses[i]] += uint128(fundingPerAddress);
            totalWinningsBone[fundingAddresses[i]] += uint128(fundingPerAddress);
            unchecked { ++i; }
        }

        round.state = RoundState.PrizesDistributed;
        emit PrizesDistributed(roundId, totalPrize);
    }

    function completeRound(uint256 roundId) external {
        LotteryRound storage round = lotteryRounds[roundId];
        if (round.state != RoundState.PrizesDistributed) revert PrizesNotDistributed();
        _completeRoundInternal(roundId);
    }

    function _completeRoundInternal(uint256 roundId) internal {
        LotteryRound storage round = lotteryRounds[roundId];
        round.state = RoundState.Completed;

        uint256 burnAmount = (uint256(round.totalPrizePoolBone) * BURN_SHARE) / 100;
        if (burnAmount > 0) {
            boneToken.transfer(DEAD_ADDRESS, burnAmount);
            emit TokensBurned(burnAmount);
        }

        // Notify cross-chain contracts about winners
        _notifyCrossChainWinners(roundId);

        if (roundId == currentRoundId) {
            unchecked { ++currentRoundId; }
            LotteryRound storage newRound = lotteryRounds[currentRoundId];
            newRound.state = RoundState.Active;
            newRound.startTime = uint64(block.timestamp);

            emit RoundCompleted(roundId, currentRoundId);
            emit NewRoundStarted(currentRoundId);
        }
    }

    

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawalsBone[msg.sender];
        if (amount == 0) revert NoWithdrawalAvailable();

        pendingWithdrawalsBone[msg.sender] = 0;
        boneToken.transfer(msg.sender, amount);
        emit WithdrawalMade(msg.sender, amount);
    }

    // ===== CCIP RESPONSE FUNCTIONS =====

    /**
     * @dev Send entry verification response to cross-chain contract
     */
    function _sendEntryResponse(
        address player, 
        bool approved, 
        string memory reason,
        uint64 destinationChain,
        address destinationContract
    ) internal {
        bytes memory data = abi.encode(player, approved, reason);
        
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(destinationContract),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200000}) // Gas limit for destination
            ),
            feeToken: address(0) // Pay with ETH
        });

        // Send CCIP message (contract pays from its ETH balance)
        try IRouterClient(i_ccipRouter).ccipSend{
            value: IRouterClient(i_ccipRouter).getFee(destinationChain, ccipMessage)
        }(destinationChain, ccipMessage) {
            // Success - response sent
        } catch {
            // CCIP failed - log but don't revert (player entry still valid)
            emit CCIPResponseFailed(player, destinationChain, "Entry response failed");
        }
    }

    /**
     * @dev Send winners notification to cross-chain contracts
     */
    function _notifyCrossChainWinners(uint256 roundId) internal {
        LotteryRound storage round = lotteryRounds[roundId];
        
        for (uint256 i = 0; i < configuredChains.length; i++) {
            uint64 chainSelector = configuredChains[i];
            address contractAddress = chainContracts[chainSelector];
            
            if (contractAddress != address(0)) {
                bytes memory data = abi.encode(roundId, round.winners, round.totalPrizePoolBone);
                
                Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
                    receiver: abi.encode(contractAddress),
                    data: data,
                    tokenAmounts: new Client.EVMTokenAmount[](0),
                    extraArgs: Client._argsToBytes(
                        Client.EVMExtraArgsV1({gasLimit: 300000})
                    ),
                    feeToken: address(0)
                });

                try IRouterClient(i_ccipRouter).ccipSend{
                    value: IRouterClient(i_ccipRouter).getFee(chainSelector, ccipMessage)
                }(chainSelector, ccipMessage) {
                    emit WinnersNotificationSent(chainSelector, roundId);
                } catch {
                    emit CCIPResponseFailed(address(0), chainSelector, "Winners notification failed");
                }
            }
        }
    }

    // ===== UPDATED CCIP RECEIVE FUNCTION =====

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        uint64 sourceChain = message.sourceChainSelector;
        if (!allowedChains[sourceChain]) revert ChainNotAllowed();

        (address player, uint256 boneAmount) = abi.decode(message.data, (address, uint256));
        
        // Verify NFT ownership
        bool hasNFT = nftContract.balanceOf(player) > 0;
        string memory reason = hasNFT ? "Approved" : "No NFT ownership";
        address targetContract = chainContracts[sourceChain];
        
        if (hasNFT && boneAmount == ENTRY_FEE_BONE) {
            // Add player to current round
            LotteryRound storage round = lotteryRounds[currentRoundId];
            
            if (round.state == RoundState.Active && round.players.length < MAX_PLAYERS) {
                // Check for duplicate entry
                bool isDuplicate = false;
                for (uint256 i = 0; i < round.players.length; i++) {
                    if (round.players[i].playerAddress == player) {
                        isDuplicate = true;
                        break;
                    }
                }
                
                if (!isDuplicate) {
                    _addPlayerToRound(player, sourceChain, false, false);
                    
                    // Send approval response
                    if (targetContract != address(0)) {
                        _sendEntryResponse(player, true, "Entry approved", sourceChain, targetContract);
                    }
                    
                    emit CrossChainEntryReceived(player, sourceChain);
                    return;
                } else {
                    reason = "Duplicate entry";
                }
            } else {
                reason = round.state != RoundState.Active ? "Round not active" : "Round full";
            }
        }
        
        // Send rejection response
        if (targetContract != address(0)) {
            _sendEntryResponse(player, false, reason, sourceChain, targetContract);
        }
    }

    // ===== CCIP FUNDING FUNCTIONS =====

    /**
     * @dev Fund contract with ETH for CCIP responses
     */
    function fundCCIPResponses() external payable {
        require(msg.value > 0, "Must send ETH for CCIP funding");
        emit CCIPFunded(msg.sender, msg.value);
    }

    /**
     * @dev Get estimated CCIP cost for responses
     */
    function getCCIPResponseCosts() external view returns (
        uint256 entryResponseCost,
        uint256 winnersNotificationCost,
        uint256 totalEstimatedCost
    ) {
        // Estimate entry response cost
        bytes memory entryData = abi.encode(address(0), true, "test");
        Client.EVM2AnyMessage memory entryMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(address(0)),
            data: entryData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 200000})),
            feeToken: address(0)
        });
        
        // Estimate winners notification cost
        address[3] memory dummyWinners;
        bytes memory winnersData = abi.encode(1, dummyWinners, uint256(4 ether));
        Client.EVM2AnyMessage memory winnersMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(address(0)),
            data: winnersData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 300000})),
            feeToken: address(0)
        });
        
        // Get costs for first configured chain (as example)
        if (configuredChains.length > 0) {
            uint64 exampleChain = configuredChains[0];
            try IRouterClient(i_ccipRouter).getFee(exampleChain, entryMessage) returns (uint256 entryCost) {
                entryResponseCost = entryCost;
            } catch {
                entryResponseCost = 0.001 ether; // Fallback estimate
            }
            
            try IRouterClient(i_ccipRouter).getFee(exampleChain, winnersMessage) returns (uint256 winnersCost) {
                winnersNotificationCost = winnersCost;
            } catch {
                winnersNotificationCost = 0.002 ether; // Fallback estimate
            }
        }
        
        // Estimate total for all configured chains
        totalEstimatedCost = (entryResponseCost * 4) + (winnersNotificationCost * configuredChains.length);
    }

    /**
     * @dev Check if contract has sufficient CCIP funds
     */
    // function hasSufficientCCIPFunds() external view returns (
    //     bool sufficient,
    //     uint256 currentBalance,
    //     uint256 estimatedNeeded
    // ) {
    //     currentBalance = address(this).balance;
    //     (, , estimatedNeeded) = this.getCCIPResponseCosts();
    //     sufficient = currentBalance >= estimatedNeeded;
    // }

    // ===== VIEW FUNCTIONS =====

    /**
     * @dev Simple check if ETH entry is available (for frontend)
     */
    function canEnterWithETH() external view returns (bool available, string memory status) {
        (, bool valid) = _calculateETHRequired();
        
        if (valid) {
            available = true;
            status = "ETH entry available";
        } else {
            available = false;
            status = "ETH entry temporarily unavailable - use BONE";
        }
    }

    /**
     * @dev Get current system status (optional monitoring)
     */
    // function getSystemStatus() external view returns (
    //     uint256 currentSlippage,
    //     bool ethPriceValid,
    //     bool poolPriceValid,
    //     uint256 estimatedETHCost,
    //     string memory systemHealth
    // ) {
    //     currentSlippage = baseSlippage;
        
    //     (, bool ethValid) = _getETHPriceUSD();
    //     (, bool poolValid) = _getBonePriceFromPool();
    //     (uint256 ethRequired, bool calcValid) = _calculateETHRequired();
        
    //     ethPriceValid = ethValid;
    //     poolPriceValid = poolValid;
    //     estimatedETHCost = calcValid ? ethRequired : 0;
        
    //     if (ethValid && poolValid && calcValid) {
    //         systemHealth = "All systems operational";
    //     } else if (!ethValid) {
    //         systemHealth = "Chainlink ETH price issue";
    //     } else if (!poolValid) {
    //         systemHealth = "Uniswap pool price issue";
    //     } else {
    //         systemHealth = "Calculation error - check pool liquidity";
    //     }
    // }

    // function getCurrentRoundPlayers() external view returns (Player[] memory) {
    //     return lotteryRounds[currentRoundId].players;
    // }

    function getRoundInfo(uint256 roundId) external view returns (
        uint256 playerCount,
        RoundState state,
        address[3] memory winners,
        uint256 totalPrizePool,
        uint256 startTime
    ) {
        LotteryRound storage round = lotteryRounds[roundId];
        return (
            round.players.length,
            round.state,
            round.winners,
            round.totalPrizePoolBone,
            round.startTime
        );
    }

    function getVRFFundingStatus() external view returns (
        uint256 currentLinkBalance,
        uint256 estimatedCostPerRequest,
        uint256 requestsAffordable,
        bool sufficientFunds
    ) {
        currentLinkBalance = i_linkToken.balanceOf(address(this));
        estimatedCostPerRequest = i_vrfV2PlusWrapper.calculateRequestPrice(callbackGasLimit, numWords);
        requestsAffordable = estimatedCostPerRequest > 0 ? currentLinkBalance / estimatedCostPerRequest : 0;
        sufficientFunds = currentLinkBalance >= estimatedCostPerRequest;
    }

    function getPoolKeyInfo() external view returns (PoolKey memory) {
        return boneEthPoolKey;
    }

    function getAdmin() public view returns (address) {
        return contractAdmin;
    }

    function isRoundReadyForVRF(uint256 roundId) external view returns (bool) {
        return lotteryRounds[roundId].state == RoundState.Full;
    }

    function isRoundReadyForPrizeDistribution(uint256 roundId) external view returns (bool) {
        return lotteryRounds[roundId].state == RoundState.WinnersSelected;
    }

    function isRoundReadyForCompletion(uint256 roundId) external view returns (bool) {
        return lotteryRounds[roundId].state == RoundState.PrizesDistributed;
    }

    // Legacy compatibility functions
    function getETHAmountForEntry() external view returns (uint256) {
        (uint256 ethRequired, bool valid) = _calculateETHRequired();
        if (valid) {
            return ethRequired;
        }
        return 0;
    }

    function getPoolPriceInfo() external view returns (
        uint160 sqrtPriceX96,
        uint256 bonePerEth,
        uint256 ethNeededForEntry,
        bool poolExists
    ) {
        (sqrtPriceX96,,,) = poolManager.getSlot0(boneEthPoolKey.toId());
        poolExists = sqrtPriceX96 > 0;
        (bonePerEth, ) = _getBonePriceFromPool();
        
        (uint256 ethRequired, bool calcValid) = _calculateETHRequired();
        if (calcValid) {
            ethNeededForEntry = ethRequired;
        } else {
            ethNeededForEntry = 0;
        }
    }

    // ===== ADMIN FUNCTIONS =====


    // function updatePoolKey(PoolKey memory _newPoolKey) external onlyAdmin {
    //     boneEthPoolKey = _newPoolKey;
    //     emit PoolKeyUpdated(_newPoolKey);
    // }

    // function resetSlippage() external onlyAdmin {
    //     uint256 oldSlippage = baseSlippage;
    //     baseSlippage = 2500; // Reset to 25%
    //     emit SlippageAdjusted(oldSlippage, baseSlippage, "Admin reset");
    // }


    // function emergencySelectWinners(uint256 roundId) external onlyAdmin {
    //     LotteryRound storage round = lotteryRounds[roundId];
    //     if (round.state != RoundState.VRFRequested || round.players.length == 0) return;

    //     uint256 pseudoRandom = uint256(
    //         keccak256(abi.encodePacked(block.timestamp, block.prevrandao, blockhash(block.number - 1), roundId))
    //     );

    //     uint256[] memory randomWords = new uint256[](3);
    //     randomWords[0] = pseudoRandom;
    //     randomWords[1] = uint256(keccak256(abi.encodePacked(pseudoRandom, uint256(1))));
    //     randomWords[2] = uint256(keccak256(abi.encodePacked(pseudoRandom, uint256(2))));

    //     _selectWinnersOnly(roundId, randomWords);
    // }

    // function emergencyWithdrawTokens(address token, uint256 amount) external onlyAdmin {
    //     require(
    //         token != address(boneToken) || amount <= boneToken.balanceOf(address(this)) / 10,
    //         "Cannot withdraw more than 10% of BONE"
    //     );
    //     IERC20(token).transfer(contractAdmin, amount);
    // }

    // function emergencyWithdrawETH() external onlyAdmin {
    //     uint256 balance = address(this).balance;
    //     (bool success,) = contractAdmin.call{value: balance}("");
    //     require(success, "ETH withdrawal failed");
    //     emit ETHWithdrawn(contractAdmin, balance);
    // }

    function setVRFConfig(uint32 _callbackGasLimit, uint16 _requestConfirmations, uint32 _numWords) external onlyAdmin {
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
        numWords = _numWords;
    }

    function pauseContract() external onlyAdmin { _pause(); }
    function unpauseContract() external onlyAdmin { _unpause(); }

    function setChainContract(uint64 chainSelector, address contractAddress) external onlyAdmin {
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
                    configuredChains[i] = configuredChains[configuredChains.length - 1];
                    configuredChains.pop();
                    break;
                }
            }
        }
    }

    // ===== EMERGENCY CCIP FUNCTIONS =====

    /**
     * @dev Manually send entry response (emergency)
     */
    // function emergencySendEntryResponse(
    //     address player,
    //     bool approved,
    //     string memory reason,
    //     uint64 destinationChain
    // ) external onlyAdmin {
    //     address contractAddress = chainContracts[destinationChain];
    //     require(contractAddress != address(0), "Chain not configured");
        
    //     _sendEntryResponse(player, approved, reason, destinationChain, contractAddress);
    // }

    // /**
    //  * @dev Manually notify winners (emergency)
    //  */
    // function emergencyNotifyWinners(uint256 roundId, uint64 destinationChain) external onlyAdmin {
    //     LotteryRound storage round = lotteryRounds[roundId];
    //     address contractAddress = chainContracts[destinationChain];
    //     require(contractAddress != address(0), "Chain not configured");
        
    //     bytes memory data = abi.encode(roundId, round.winners, round.totalPrizePoolBone);
        
    //     Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
    //         receiver: abi.encode(contractAddress),
    //         data: data,
    //         tokenAmounts: new Client.EVMTokenAmount[](0),
    //         extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 300000})),
    //         feeToken: address(0)
    //     });

    //     IRouterClient(i_ccipRouter).ccipSend{
    //         value: IRouterClient(i_ccipRouter).getFee(destinationChain, ccipMessage)
    //     }(destinationChain, ccipMessage);
        
    //     emit WinnersNotificationSent(destinationChain, roundId);
    // }

    receive() external payable {
        // Allow ETH deposits for swaps and refunds
    }
}