// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80);
}

interface IUniswapV3Pool {
    function observe(
        uint32[] calldata
    ) external view returns (int56[] memory, uint160[] memory);

    function liquidity() external view returns (uint128);

    function token0() external view returns (address);

    function token1() external view returns (address);
}

library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    function getSqrtRatioAtTick(
        int24 tick
    ) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0
            ? uint256(-int256(tick))
            : uint256(int256(tick));
        require(absTick <= uint256(int256(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0)
            ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0)
            ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0)
            ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0)
            ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0)
            ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0)
            ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0)
            ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0)
            ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0)
            ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0)
            ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0)
            ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0)
            ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0)
            ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0)
            ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0)
            ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0)
            ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0)
            ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0)
            ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0)
            ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160(
            (ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1)
        );
    }
}

contract CoinFlip is
    VRFV2PlusWrapperConsumerBase,
    ConfirmedOwner,
    ReentrancyGuard
{
    event GameCreated(
        uint256 indexed gameId,
        address indexed creator,
        uint256 amount,
        address token,
        bool coinSide
    );
    event GameJoined(uint256 indexed gameId, address indexed joiner);
    event GameResolved(
        uint256 indexed gameId,
        address indexed winner,
        bool result
    );
    event BatchGameCreated(address indexed creator, uint256[] gameIds);

    event FundsWithdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    enum GameState {
        Pending,
        WaitingForVRF,
        Resolved,
        Cancelled
    }

    struct Game {
        address creator;
        address joiner;
        uint256 amount;
        address token;
        bool creatorCoinSide;
        GameState state;
        uint256 vrfRequestId;
        bool result;
        address winner;
        uint256 createdAt;
    }

    struct VRFRequest {
        uint256 gameId;
        bool fulfilled;
    }

    struct BatchGameParams {
        uint256 amount;
        address token;
        bool coinSide;
    }

    struct GasTokenConfig {
        bool isSupported;
        address dexPool;
        bool token0IsWETH;
        uint8 tokenDecimals;
        uint128 cachedRate;
        uint64 lastUpdate;
        uint32 updateInterval;
        uint128 minLiquidity;
        uint256 lastValidPrice;
    }

    mapping(address => uint256) public minBetAmounts;
    mapping(uint256 => Game) public games;
    mapping(uint256 => VRFRequest) public vrfRequests;
    mapping(address => uint256) public playerPoints;
    mapping(address => mapping(address => uint256)) public donorBalances;
    mapping(address => uint256) public playerLastGameBlock;
    mapping(address => GasTokenConfig) public gasTokenConfigs;
    mapping(address => mapping(address => uint256)) public playerBalances;
    mapping(uint256 => uint256) public gameTotalPot;

    uint256 public gameCounter;
    uint256[] public pendingGameIds;
    uint256[] public resolvedGameIds;
    address[6] public donors;

    uint32 public callbackGasLimit = 315000;
    uint16 public requestConfirmations = 3;
    uint32 public constant numWords = 1;

    address public immutable TOAD_TOKEN;
    address public immutable BONE_TOKEN;
    address public immutable LINK_TOKEN;
    address public immutable WETH;
    address public FROG_SOUP_NFT;

    address public constant ETH_USD_PRICE_FEED =
        0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    uint256 public constant PRICE_STALENESS_THRESHOLD = 3600;
    uint256 public constant FALLBACK_ETH_PRICE = 3000;
    uint256 public constant MIN_ETH_PRICE = 500;
    uint256 public constant MAX_ETH_PRICE = 50000;

    uint256 public maxGasUSDLimit = 20;
    uint256 public gasBufferPercent = 115;
    uint256 public constant MIN_GAS_USD_LIMIT = 5;
    uint256 public constant MAX_GAS_USD_LIMIT = 100;
    uint256 public constant MIN_BUFFER_PERCENT = 105;
    uint256 public constant MAX_BUFFER_PERCENT = 150;

    uint256 public constant DONOR_COUNT = 6;
    uint256 public constant PLATFORM_FEE_PERCENT = 10;
    uint256 public constant MAX_GAS_PRICE = 25 gwei;
    uint256 public constant MAX_BATCH_SIZE = 10;
    uint256 public constant MAX_PRICE_CHANGE = 30;
    uint256 public constant MIN_RATE = 1e12;
    uint256 public constant MAX_RATE = 1e30;
    uint32 public constant TWAP_PERIOD = 300;
    uint256 public constant MIN_BLOCK_INTERVAL = 1;

    bool public emergencyMode = false;

    modifier requiresFrogSoupNFT(address user) {
        require(
            IERC721(FROG_SOUP_NFT).balanceOf(user) > 0,
            "Must own Frog Soup NFT"
        );
        _;
    }

    modifier enforceBlockInterval(address user) {
        require(
            block.number > playerLastGameBlock[user] + MIN_BLOCK_INTERVAL,
            "Must wait before next game"
        );
        playerLastGameBlock[user] = block.number;
        _;
    }

    modifier gasLimitCheck() {
        require(tx.gasprice <= MAX_GAS_PRICE, "Gas price too high");
        _;
    }

    constructor(
        address _wrapperAddress,
        address _linkToken,
        address _toadToken,
        address _boneToken,
        address _weth,
        address _frogSoupNFT,
        address[6] memory _donors
    ) ConfirmedOwner(msg.sender) VRFV2PlusWrapperConsumerBase(_wrapperAddress) {
        LINK_TOKEN = _linkToken;
        TOAD_TOKEN = _toadToken;
        BONE_TOKEN = _boneToken;
        WETH = _weth;
        FROG_SOUP_NFT = _frogSoupNFT;
        for (uint256 i = 0; i < DONOR_COUNT; i++) {
            donors[i] = _donors[i];
        }
    }

    function setMaxGasUSDLimit(uint256 newLimit) external onlyOwner {
        require(
            newLimit >= MIN_GAS_USD_LIMIT && newLimit <= MAX_GAS_USD_LIMIT,
            "Invalid USD limit range"
        );

        maxGasUSDLimit = newLimit;
    }

    function setGasBufferPercent(uint256 newPercent) external onlyOwner {
        require(
            newPercent >= MIN_BUFFER_PERCENT &&
                newPercent <= MAX_BUFFER_PERCENT,
            "Invalid buffer percent range"
        );

        gasBufferPercent = newPercent;
    }

    function getGasLimitConfig()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (
            maxGasUSDLimit,
            gasBufferPercent,
            MIN_GAS_USD_LIMIT,
            MAX_GAS_USD_LIMIT,
            MIN_BUFFER_PERCENT,
            MAX_BUFFER_PERCENT
        );
    }

    function getETHPrice() public view returns (uint256) {
        try
            AggregatorV3Interface(ETH_USD_PRICE_FEED).latestRoundData()
        returns (uint80, int256 price, uint256, uint256 updatedAt, uint80) {
            if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD)
                return FALLBACK_ETH_PRICE * 1e18;
            uint256 priceUSD = uint256(price) / 1e8;
            if (priceUSD < MIN_ETH_PRICE || priceUSD > MAX_ETH_PRICE)
                return FALLBACK_ETH_PRICE * 1e18;
            return priceUSD * 1e18;
        } catch {
            return FALLBACK_ETH_PRICE * 1e18;
        }
    }

    function createGame(
        uint256 amount,
        address token,
        bool coinSide,
        address gasToken
    )
        external
        payable
        nonReentrant
        requiresFrogSoupNFT(msg.sender)
        enforceBlockInterval(msg.sender)
        gasLimitCheck
        returns (uint256 gameId)
    {
        require(amount > 0, "Amount must be > 0");
        require(_isValidToken(token), "Invalid token");
        require(amount >= minBetAmounts[token], "Below minimum bet");

        gameId = gameCounter++;
        if (gasToken != address(0)) _handleGasAbstraction(gasToken);

        if (playerBalances[msg.sender][token] >= amount) {
            playerBalances[msg.sender][token] -= amount;
        } else {
            if (token == address(0)) {
                require(msg.value == amount, "Incorrect ETH amount");
            } else {
                require(msg.value == 0, "ETH not needed");
                require(
                    IERC20(token).transferFrom(
                        msg.sender,
                        address(this),
                        amount
                    ),
                    "Transfer failed"
                );
            }
        }

        games[gameId] = Game(
            msg.sender,
            address(0),
            amount,
            token,
            coinSide,
            GameState.Pending,
            0,
            false,
            address(0),
            block.timestamp
        );
        gameTotalPot[gameId] = amount;
        playerPoints[msg.sender] += 1;
        pendingGameIds.push(gameId);
        emit GameCreated(gameId, msg.sender, amount, token, coinSide);
    }

    function createGamesBatch(
        BatchGameParams[] calldata params,
        address gasToken
    )
        external
        payable
        nonReentrant
        requiresFrogSoupNFT(msg.sender)
        enforceBlockInterval(msg.sender)
        gasLimitCheck
        returns (uint256[] memory gameIds)
    {
        require(
            params.length > 0 && params.length <= MAX_BATCH_SIZE,
            "Invalid batch size"
        );

        gameIds = new uint256[](params.length);
        uint256 totalEthRequired = 0;

        if (gasToken != address(0)) _handleGasAbstraction(gasToken);

        for (uint256 i = 0; i < params.length; i++) {
            require(
                params[i].amount >= minBetAmounts[params[i].token],
                "Below minimum bet"
            );
            require(params[i].amount > 0, "Amount must be > 0");
            require(_isValidToken(params[i].token), "Invalid token");
            if (
                playerBalances[msg.sender][params[i].token] >= params[i].amount
            ) {
                playerBalances[msg.sender][params[i].token] -= params[i].amount;
            } else {
                if (params[i].token == address(0))
                    totalEthRequired += params[i].amount;
            }
        }

        require(msg.value == totalEthRequired, "Incorrect ETH amount");

        for (uint256 i = 0; i < params.length; i++) {
            uint256 gameId = gameCounter++;
            gameIds[i] = gameId;

            if (
                playerBalances[msg.sender][params[i].token] <
                params[i].amount &&
                params[i].token != address(0)
            ) {
                require(
                    params[i].amount >= minBetAmounts[params[i].token],
                    "Below minimum bet"
                );
                require(
                    IERC20(params[i].token).transferFrom(
                        msg.sender,
                        address(this),
                        params[i].amount
                    ),
                    "Token transfer failed"
                );
            }

            games[gameId] = Game(
                msg.sender,
                address(0),
                params[i].amount,
                params[i].token,
                params[i].coinSide,
                GameState.Pending,
                0,
                false,
                address(0),
                block.timestamp
            );
            gameTotalPot[gameId] = params[i].amount;
            pendingGameIds.push(gameId);
            emit GameCreated(
                gameId,
                msg.sender,
                params[i].amount,
                params[i].token,
                params[i].coinSide
            );
        }

        playerPoints[msg.sender] += params.length;
        emit BatchGameCreated(msg.sender, gameIds);
    }

    function joinGame(
        uint256 gameId,
        address gasToken
    )
        external
        payable
        nonReentrant
        requiresFrogSoupNFT(msg.sender)
        enforceBlockInterval(msg.sender)
        gasLimitCheck
    {
        Game storage game = games[gameId];
        require(game.creator != address(0), "Game does not exist");
        require(game.state == GameState.Pending, "Game not pending");
        require(game.creator != msg.sender, "Cannot join own game");

        if (gasToken != address(0)) _handleGasAbstraction(gasToken);

        if (playerBalances[msg.sender][game.token] >= game.amount) {
            playerBalances[msg.sender][game.token] -= game.amount;
        } else {
            if (game.token == address(0)) {
                require(msg.value == game.amount, "Incorrect ETH amount");
            } else {
                require(msg.value == 0, "ETH not needed");
                require(
                    IERC20(game.token).transferFrom(
                        msg.sender,
                        address(this),
                        game.amount
                    ),
                    "Transfer failed"
                );
            }
        }

        game.joiner = msg.sender;
        game.state = GameState.WaitingForVRF;
        gameTotalPot[gameId] = game.amount * 2;
        playerPoints[msg.sender] += 1;
        playerPoints[game.creator] += 1;

        _removePendingGame(gameId);
        _requestVRF(gameId);
        emit GameJoined(gameId, msg.sender);
    }

    function cancelGame(uint256 gameId) external nonReentrant {
        Game storage game = games[gameId];
        require(game.creator == msg.sender, "Only creator can cancel");
        require(game.state == GameState.Pending, "Game not pending");
        game.state = GameState.Cancelled;
        _removePendingGame(gameId);
        playerBalances[game.creator][game.token] += game.amount;
        delete gameTotalPot[gameId];
    }

    function emergencyRefund(uint256 gameId) external onlyOwner {
        require(emergencyMode, "Not in emergency mode");
        Game storage game = games[gameId];
        require(game.state == GameState.WaitingForVRF, "Invalid state");
        game.state = GameState.Cancelled;
        playerBalances[game.creator][game.token] += game.amount;
        playerBalances[game.joiner][game.token] += game.amount;
        delete gameTotalPot[gameId];
    }

    function setEmergencyMode(bool _emergencyMode) external onlyOwner {
        emergencyMode = _emergencyMode;
    }

    function withdrawFunds(
        address token,
        uint256 amount
    ) external nonReentrant {
        require(amount > 0, "Amount must be > 0");
        require(
            playerBalances[msg.sender][token] >= amount,
            "Insufficient balance"
        );
        playerBalances[msg.sender][token] -= amount;
        _transferFunds(msg.sender, amount, token);
        emit FundsWithdrawn(msg.sender, token, amount);
    }

    function withdrawAllFunds(address token) external nonReentrant {
        uint256 balance = playerBalances[msg.sender][token];
        require(balance > 0, "No balance to withdraw");
        playerBalances[msg.sender][token] = 0;
        _transferFunds(msg.sender, balance, token);
        emit FundsWithdrawn(msg.sender, token, balance);
    }

    function _handleGasAbstraction(address gasToken) internal {
        uint256 tokenRate = _getTokenRateWithCache(gasToken);
        uint256 gasEstimate = gasleft();
        if (gasEstimate > 800000) gasEstimate = 800000;
        uint256 gasEstimateETH = tx.gasprice * gasEstimate;
        uint256 tokenAmount = (gasEstimateETH * tokenRate) / 1e18;
        tokenAmount = (tokenAmount * gasBufferPercent) / 100;
        uint256 maxTokensUSD = _calculateMaxTokensForUSD(gasToken);
        require(tokenAmount <= maxTokensUSD, "Gas cost exceeds USD limit");
        require(
            IERC20(gasToken).transferFrom(
                msg.sender,
                address(this),
                tokenAmount
            ),
            "Gas token transfer failed"
        );
    }

    function _calculateMaxTokensForUSD(
        address gasToken
    ) internal returns (uint256) {
        uint256 tokenRate = _getTokenRateWithCache(gasToken);
        uint256 ethPriceUSD = getETHPrice();
        uint256 maxEthForGas = (maxGasUSDLimit * 1e36) / ethPriceUSD;
        return (maxEthForGas * tokenRate) / 1e18;
    }

    function _getTokenRateWithCache(
        address token
    ) internal returns (uint256 rate) {
        GasTokenConfig storage config = gasTokenConfigs[token];
        require(config.isSupported, "Token not supported");
        uint256 timeSinceUpdate = block.timestamp - config.lastUpdate;
        bool cacheValid = (config.cachedRate > 0 &&
            timeSinceUpdate < config.updateInterval);
        if (cacheValid) return uint256(config.cachedRate);
        uint256 freshRate = _calculateDEXRate(config);
        if (config.lastValidPrice > 0) {
            uint256 priceChange = freshRate > config.lastValidPrice
                ? ((freshRate - config.lastValidPrice) * 100) /
                    config.lastValidPrice
                : ((config.lastValidPrice - freshRate) * 100) /
                    config.lastValidPrice;
            if (priceChange > MAX_PRICE_CHANGE)
                freshRate = config.lastValidPrice;
        }
        require(freshRate >= MIN_RATE && freshRate <= MAX_RATE, "Invalid rate");
        config.cachedRate = uint128(freshRate);
        config.lastUpdate = uint64(block.timestamp);
        config.lastValidPrice = freshRate;

        return freshRate;
    }

    function _calculateDEXRate(
        GasTokenConfig storage config
    ) internal view returns (uint256) {
        IUniswapV3Pool pool = IUniswapV3Pool(config.dexPool);
        require(
            pool.liquidity() >= config.minLiquidity,
            "Insufficient DEX liquidity"
        );
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_PERIOD;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 averageTick = int24(
            tickCumulativesDelta / int56(uint56(TWAP_PERIOD))
        );
        return
            _tickToPriceCorrect(
                averageTick,
                config.token0IsWETH,
                config.tokenDecimals
            );
    }

    function _tickToPriceCorrect(
        int24 tick,
        bool token0IsWETH,
        uint8 tokenDecimals
    ) internal pure returns (uint256 rate) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 denominator = 1 << 192;
        if (token0IsWETH) {
            if (tokenDecimals < 18) {
                denominator = denominator * (10 ** (18 - tokenDecimals));
            } else if (tokenDecimals > 18) {
                numerator = numerator * (10 ** (tokenDecimals - 18));
            }
        } else {
            if (tokenDecimals > 18) {
                denominator = denominator * (10 ** (tokenDecimals - 18));
            } else if (tokenDecimals < 18) {
                numerator = numerator * (10 ** (18 - tokenDecimals));
            }
            uint256 temp = numerator;
            numerator = denominator * (10 ** tokenDecimals);
            denominator = temp;
        }
        return numerator / denominator;
    }

    function _isValidToken(address token) internal view returns (bool) {
        return
            token == address(0) || token == TOAD_TOKEN || token == BONE_TOKEN;
    }

    function _requestVRF(uint256 gameId) internal {
        bytes memory extraArgs = VRFV2PlusClient._argsToBytes(
            VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
        );
        (uint256 requestId, ) = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords,
            extraArgs
        );
        games[gameId].vrfRequestId = requestId;
        vrfRequests[requestId] = VRFRequest({gameId: gameId, fulfilled: false});
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override nonReentrant {
        VRFRequest storage vrfRequest = vrfRequests[requestId];
        uint256 gameId = vrfRequest.gameId;
        require(gameId != 0, "Invalid VRF request");
        require(!vrfRequest.fulfilled, "Request already fulfilled");
        Game storage game = games[gameId];
        require(game.creator != address(0), "Game does not exist");
        require(
            game.state == GameState.WaitingForVRF,
            "Game not waiting for VRF"
        );
        vrfRequest.fulfilled = true;
        bool coinResult = randomWords[0] % 2 == 0;
        address winner = game.creatorCoinSide == coinResult
            ? game.creator
            : game.joiner;
        game.result = coinResult;
        game.state = GameState.Resolved;
        game.winner = winner;
        resolvedGameIds.push(gameId);
        emit GameResolved(gameId, winner, coinResult);
    }

    function distributeAllPendingPayouts() external onlyOwner {
        for (uint256 i = 0; i < resolvedGameIds.length; i++) {
            uint256 gameId = resolvedGameIds[i];
            Game storage game = games[gameId];
            uint256 totalPot = gameTotalPot[gameId];
            uint256 platformFee = (totalPot * PLATFORM_FEE_PERCENT) / 100;
            uint256 winnerPayout = totalPot - platformFee;
            playerBalances[game.winner][game.token] += winnerPayout;
            uint256 feePerDonor = platformFee / DONOR_COUNT;
            for (uint256 j = 0; j < DONOR_COUNT; j++) {
                donorBalances[donors[j]][game.token] += feePerDonor;
            }
            delete gameTotalPot[gameId];
        }
        delete resolvedGameIds;
    }

    function _transferFunds(
        address to,
        uint256 amount,
        address token
    ) internal {
        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            require(
                IERC20(token).transfer(to, amount),
                "Token transfer failed"
            );
        }
    }

    function _removePendingGame(uint256 gameId) internal {
        uint256 length = pendingGameIds.length;
        for (uint256 i = 0; i < length; i++) {
            if (pendingGameIds[i] == gameId) {
                pendingGameIds[i] = pendingGameIds[length - 1];
                pendingGameIds.pop();
                break;
            }
        }
    }

    function getPendingGames() external view returns (uint256[] memory) {
        return pendingGameIds;
    }

    function getGameDetails(
        uint256 gameId
    ) external view returns (Game memory) {
        return games[gameId];
    }

    function getPlayerPoints(address player) external view returns (uint256) {
        return playerPoints[player];
    }

    function getPlayerBalances(
        address player
    ) external view returns (uint256, uint256, uint256) {
        return (
            playerBalances[player][address(0)],
            playerBalances[player][TOAD_TOKEN],
            playerBalances[player][BONE_TOKEN]
        );
    }

    function getDonorBalance(
        address donor,
        address token
    ) external view returns (uint256) {
        return donorBalances[donor][token];
    }

    function getDonors() external view returns (address[6] memory) {
        return donors;
    }

    function getGasTokenRate(address token) external view returns (uint256) {
        GasTokenConfig storage config = gasTokenConfigs[token];
        require(config.isSupported, "Token not supported");
        uint256 timeSinceUpdate = block.timestamp - config.lastUpdate;
        bool cacheValid = (config.cachedRate > 0 &&
            timeSinceUpdate < config.updateInterval);
        if (cacheValid) return uint256(config.cachedRate);
        return _calculateDEXRate(config);
    }

    function getGasTokenConfig(
        address token
    )
        external
        view
        returns (bool, address, uint256, uint256, uint256, uint256, uint8)
    {
        GasTokenConfig storage config = gasTokenConfigs[token];
        return (
            config.isSupported,
            config.dexPool,
            uint256(config.cachedRate),
            uint256(config.lastUpdate),
            uint256(config.updateInterval),
            uint256(config.minLiquidity),
            config.tokenDecimals
        );
    }

    function getMaxTokensForGasUSD(
        address gasToken
    ) external returns (uint256) {
        return _calculateMaxTokensForUSD(gasToken);
    }

    function withdrawDonorFees(address token) external nonReentrant {
        uint256 amount = donorBalances[msg.sender][token];
        require(amount > 0, "No fees to withdraw");
        donorBalances[msg.sender][token] = 0;
        _transferFunds(msg.sender, amount, token);
    }

    function withdrawAccumulatedGasTokens(
        address token,
        uint256 amount
    ) external onlyOwner {
        require(
            token == BONE_TOKEN || token == TOAD_TOKEN,
            "Invalid gas token"
        );
        require(amount > 0, "Amount must be greater than 0");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(amount <= balance, "Insufficient contract balance");
        require(IERC20(token).transfer(msg.sender, amount), "Transfer failed");
    }

    function updateDonor(
        uint256 donorIndex,
        address newDonor
    ) external onlyOwner {
        require(donorIndex < DONOR_COUNT, "Invalid donor index");
        require(newDonor != address(0), "Invalid donor address");

        donors[donorIndex] = newDonor;
    }

    function setupGasToken(
        address token,
        address dexPool,
        bool token0IsWETH,
        uint8 tokenDecimals,
        uint128 minLiquidity,
        uint256 updateInterval
    ) external onlyOwner {
        require(token == TOAD_TOKEN || token == BONE_TOKEN, "Invalid token");
        require(dexPool != address(0), "Invalid pool");
        require(
            updateInterval >= 60 && updateInterval <= 3600,
            "Invalid interval"
        );
        require(minLiquidity > 0, "Invalid min liquidity");
        require(tokenDecimals <= 18, "Invalid token decimals");

        IUniswapV3Pool pool = IUniswapV3Pool(dexPool);
        address token0 = pool.token0();
        address token1 = pool.token1();

        if (token0IsWETH) {
            require(token0 == WETH && token1 == token, "Pool token mismatch");
        } else {
            require(token0 == token && token1 == WETH, "Pool token mismatch");
        }

        gasTokenConfigs[token] = GasTokenConfig({
            isSupported: true,
            dexPool: dexPool,
            token0IsWETH: token0IsWETH,
            tokenDecimals: tokenDecimals,
            cachedRate: 0,
            lastUpdate: 0,
            updateInterval: uint32(updateInterval),
            minLiquidity: minLiquidity,
            lastValidPrice: 0
        });

        uint256 currentRate = _calculateDEXRate(gasTokenConfigs[token]);
        gasTokenConfigs[token].cachedRate = uint128(currentRate);
        gasTokenConfigs[token].lastUpdate = uint64(block.timestamp);
        gasTokenConfigs[token].lastValidPrice = currentRate;
    }

    function withdrawLink() external onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(LINK_TOKEN);
        uint256 balance = link.balanceOf(address(this));
        require(balance > 0, "No LINK to withdraw");
        require(link.transfer(msg.sender, balance), "LINK transfer failed");
    }

    function updateVRFConfig(
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external onlyOwner {
        require(
            _callbackGasLimit >= 200000 && _callbackGasLimit <= 2500000,
            "Invalid gas limit"
        );
        require(
            _requestConfirmations >= 1 && _requestConfirmations <= 200,
            "Invalid confirmations"
        );
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
    }

    function setMinBetAmount(
        address token,
        uint256 minAmount
    ) external onlyOwner {
        require(_isValidToken(token), "Invalid token");
        minBetAmounts[token] = minAmount;
    }

    receive() external payable {}
}
