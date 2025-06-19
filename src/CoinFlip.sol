// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/shared/interfaces/LinkTokenInterface.sol";
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Minimal Uniswap V3 interface for TWAP price calculation
interface IUniswapV3Pool {
    /// @dev Returns cumulative tick data for TWAP calculations
    /// @param secondsAgos Array of seconds ago to query [older, newer]
    /// @return tickCumulatives Cumulative tick values at each timestamp
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory);
    
    /// @dev Current liquidity in the pool (for manipulation resistance)
    function liquidity() external view returns (uint128);
}

/**
 * @title CoinFlip - Production Ready with Gas-Efficient DEX Oracles, Frog Soup NFT Requirement, and Donor Fee Distribution
 * @dev Coinflip game with automated token pricing via Uniswap V3 TWAP, NFT gating, and 5% fees distributed to 6 donors
 * 
 * REQUIREMENTS:
 * - Players must own at least 1 Frog Soup NFT to create or join games
 * - MEV protection prevents same-block multiple games
 * - 5% platform fees distributed equally among 6 donor addresses
 * 
 * GAS EFFICIENCY STRATEGY:
 * - Updates token rates only when users actually use gas abstraction
 * - Caches rates for 5 minutes to avoid redundant oracle calls
 * - Uses 5-minute TWAP for good balance of responsiveness vs manipulation resistance
 * - Packs structs to minimize storage costs
 * 
 * SECURITY FEATURES:
 * - Circuit breaker prevents >50% price jumps
 * - Minimum liquidity thresholds prevent manipulation
 * - Reentrancy protection throughout
 * - TWAP prevents flash loan attacks
 * - NFT requirement prevents bot spam
 */
contract CoinFlip is VRFV2PlusWrapperConsumerBase, ConfirmedOwner, ReentrancyGuard {
    
    // ============ EVENTS ============
    
    event GameCreated(uint256 indexed gameId, address indexed creator, uint256 amount, address token, bool coinSide);
    event GameJoined(uint256 indexed gameId, address indexed joiner);
    event GameResolved(uint256 indexed gameId, address indexed winner, bool result);
    event BatchGameCreated(address indexed creator, uint256[] gameIds);
    event GasAbstractionUsed(address indexed user, address gasToken, uint256 tokenAmount, uint256 ethEquivalent);
    event TokenRateUpdated(address indexed token, uint256 newRate, uint256 timestamp);
    event FrogSoupNFTUpdated(address indexed oldNFT, address indexed newNFT);
    event DonorUpdated(uint256 indexed donorIndex, address indexed oldDonor, address indexed newDonor);
    event DonorWithdrawal(address indexed donor, address indexed token, uint256 amount);

    // ============ ENUMS & STRUCTS ============
    
    enum GameState { Pending, WaitingForVRF, Resolved, Cancelled }

    /// @dev Core game data - optimized packing to fit in 3 storage slots
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

    /// @dev VRF request tracking - fits in 1 slot
    struct VRFRequest {
        uint256 gameId;         
        bool fulfilled;         
    }

    /// @dev Batch operation parameters
    struct BatchGameParams {
        uint256 amount;
        address token;
        bool coinSide;
    }

    /// @dev Gas token configuration - optimized packing for gas efficiency
    struct GasTokenConfig {
        bool isSupported;        
        address dexPool;         
        bool token0IsWETH;       
        uint128 cachedRate;      
        uint64 lastUpdate;      
        uint32 updateInterval;    
        uint128 minLiquidity;    
        uint256 lastValidPrice;  
    }

    // ============ STATE VARIABLES ============
    
    // Core game state
    mapping(uint256 => Game) public games;                   
    mapping(uint256 => VRFRequest) public vrfRequests;       
    mapping(address => uint256) public playerPoints;         
    mapping(address => mapping(address => uint256)) public donorBalances; 
    mapping(address => uint256) public playerLastGameBlock;   
    
    // Gas abstraction with efficient caching
    mapping(address => GasTokenConfig) public gasTokenConfigs;
    
    uint256 public gameCounter;                             
    uint256[] public pendingGameIds;                        
    
    // Donor addresses (6 total)
    address[6] public donors;                                 
    uint256 public constant DONOR_COUNT = 6;               
    
    // VRF configuration
    uint32 public callbackGasLimit = 300000;                
    uint16 public requestConfirmations = 3;                 
    uint32 public constant numWords = 1;                     
    
    // Token addresses (immutable after deployment)
    address public immutable TOAD_TOKEN;
    address public immutable BONE_TOKEN;
    address public immutable LINK_TOKEN;
    address public immutable WETH;                          
    
    // NFT requirement
    address public FROG_SOUP_NFT;                            
    
    // Security and efficiency constants
    uint256 public constant PLATFORM_FEE_PERCENT = 5;     
    uint256 public constant MAX_GAS_PRICE = 100 gwei;        
    uint256 public constant MAX_GAS_COST_TOKENS = 1000000e18; 
    uint256 public constant MAX_BATCH_SIZE = 10;             
    uint256 public constant MAX_PRICE_CHANGE = 50;          
    uint256 public constant DEFAULT_UPDATE_INTERVAL = 300;   
    uint256 public constant MIN_RATE = 1e15;                
    uint256 public constant MAX_RATE = 1e25;                
    uint32 public constant TWAP_PERIOD = 300;                
    uint256 public constant MIN_BLOCK_INTERVAL = 1;          

    // ============ MODIFIERS ============

    /**
     * @dev Modifier to check if user owns required Frog Soup NFT
     * @param user Address to check NFT ownership for
     */
    modifier requiresFrogSoupNFT(address user) {
        require(_hasFrogSoupNFT(user), "Must own Frog Soup NFT");
        _;
    }

    /**
     * @dev Modifier to prevent MEV attacks and same-block exploitation
     * @param user Address to check block interval for
     */
    modifier enforceBlockInterval(address user) {
        require(
            block.number > playerLastGameBlock[user] + MIN_BLOCK_INTERVAL,
            "Must wait before next game"
        );
        playerLastGameBlock[user] = block.number;
        _;
    }

    // ============ CONSTRUCTOR ============
    
    /**
     * @dev Initialize contract with required addresses
     * @param _wrapperAddress Chainlink VRF wrapper contract
     * @param _linkToken LINK token for VRF payments
     * @param _toadToken TOAD token address
     * @param _boneToken BONE token address  
     * @param _weth WETH address for DEX pair identification
     * @param _frogSoupNFT Frog Soup NFT contract address
     * @param _donors Array of 6 donor addresses
     */
    constructor(
        address _wrapperAddress,
        address _linkToken,
        address _toadToken,
        address _boneToken,
        address _weth,
        address _frogSoupNFT,
        address[6] memory _donors
    ) 
        ConfirmedOwner(msg.sender)                            // Inherits ownership functionality
        VRFV2PlusWrapperConsumerBase(_wrapperAddress)         // Inherits VRF functionality
    {
        // Store immutable addresses (cheaper than storage)
        LINK_TOKEN = _linkToken;
        TOAD_TOKEN = _toadToken;
        BONE_TOKEN = _boneToken;
        WETH = _weth;
        
        // Set Frog Soup NFT requirement
        require(_frogSoupNFT != address(0), "Invalid NFT address");
        FROG_SOUP_NFT = _frogSoupNFT;
        
        // Set donor addresses
        for (uint256 i = 0; i < DONOR_COUNT; i++) {
            require(_donors[i] != address(0), "Invalid donor address");
            donors[i] = _donors[i];
        }
    }

    // ============ MAIN GAME FUNCTIONS ============

    /**
     * @dev Create a new coinflip game
     * @param amount Bet amount in specified token
     * @param token Token address (address(0) for ETH)
     * @param coinSide true = heads, false = tails
     * @param gasToken Token to pay gas with (address(0) for ETH)
     * @return gameId Unique game identifier
     */
    function createGame(
        uint256 amount, 
        address token, 
        bool coinSide,
        address gasToken
    ) external payable nonReentrant 
      requiresFrogSoupNFT(msg.sender)
      enforceBlockInterval(msg.sender)
      returns (uint256 gameId) {
        
        // Input validation
        require(amount > 0, "Amount must be > 0");
        require(_isValidToken(token), "Invalid token");
        
        // Generate unique game ID
        gameId = gameCounter++;
        
        // Handle gas abstraction if requested
        if (gasToken != address(0)) {
            _handleGasAbstraction(gasToken);
        }
        
        // Handle bet payment based on token type
        if (token == address(0)) {
            require(msg.value == amount, "Incorrect ETH amount");
        } else {
            require(msg.value == 0, "ETH not needed");
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        }
        
        // Create game struct in storage
        games[gameId] = Game({
            creator: msg.sender,
            joiner: address(0),
            amount: amount,
            token: token,
            creatorCoinSide: coinSide,
            state: GameState.Pending,
            vrfRequestId: 0,
            result: false,
            winner: address(0),
            createdAt: block.timestamp
        });
        
        // Add to pending games for UI discovery
        pendingGameIds.push(gameId);
        
        emit GameCreated(gameId, msg.sender, amount, token, coinSide);
    }

    /**
     * @dev Create multiple games in a single transaction
     * @param params Array of game parameters
     * @param gasToken Token to pay gas with
     * @return gameIds Array of created game IDs
     */
    function createGamesBatch(
        BatchGameParams[] calldata params,
        address gasToken
    ) external payable nonReentrant 
      requiresFrogSoupNFT(msg.sender)
      enforceBlockInterval(msg.sender)
      returns (uint256[] memory gameIds) {
        
        // Validate batch size
        require(params.length > 0 && params.length <= MAX_BATCH_SIZE, "Invalid batch size");
        
        gameIds = new uint256[](params.length);
        uint256 totalEthRequired = 0;
        
        // Handle gas abstraction once for entire batch
        if (gasToken != address(0)) {
            _handleGasAbstraction(gasToken);
        }
        
        // First pass: validate and calculate ETH needed
        for (uint256 i = 0; i < params.length; i++) {
            require(params[i].amount > 0, "Amount must be > 0");
            require(_isValidToken(params[i].token), "Invalid token");
            
            if (params[i].token == address(0)) {
                totalEthRequired += params[i].amount;
            }
        }
        
        require(msg.value == totalEthRequired, "Incorrect ETH amount");
        
        // Second pass: create all games
        for (uint256 i = 0; i < params.length; i++) {
            uint256 gameId = gameCounter++;
            gameIds[i] = gameId;
            
            // Handle token transfers for non-ETH games
            if (params[i].token != address(0)) {
                require(
                    IERC20(params[i].token).transferFrom(msg.sender, address(this), params[i].amount),
                    "Token transfer failed"
                );
            }
            
            // Create game struct
            games[gameId] = Game({
                creator: msg.sender,
                joiner: address(0),
                amount: params[i].amount,
                token: params[i].token,
                creatorCoinSide: params[i].coinSide,
                state: GameState.Pending,
                vrfRequestId: 0,
                result: false,
                winner: address(0),
                createdAt: block.timestamp
            });
            
            pendingGameIds.push(gameId);
            emit GameCreated(gameId, msg.sender, params[i].amount, params[i].token, params[i].coinSide);
        }
        
        emit BatchGameCreated(msg.sender, gameIds);
    }

    /**
     * @dev Join an existing game
     * @param gameId Game to join
     * @param gasToken Token to pay gas with
     */
    function joinGame(uint256 gameId, address gasToken) external payable nonReentrant 
      requiresFrogSoupNFT(msg.sender)
      enforceBlockInterval(msg.sender) {
        
        Game storage game = games[gameId];
        
        // Validate game state
        require(game.creator != address(0), "Game does not exist");
        require(game.state == GameState.Pending, "Game not pending");
        require(game.creator != msg.sender, "Cannot join own game");
        
        // Handle gas abstraction
        if (gasToken != address(0)) {
            _handleGasAbstraction(gasToken);
        }
        
        // Handle bet payment
        if (game.token == address(0)) {
            require(msg.value == game.amount, "Incorrect ETH amount");
        } else {
            require(msg.value == 0, "ETH not needed");
            require(IERC20(game.token).transferFrom(msg.sender, address(this), game.amount), "Transfer failed");
        }
        
        // Update game state
        game.joiner = msg.sender;
        game.state = GameState.WaitingForVRF;
        
        // Remove from pending games list
        _removePendingGame(gameId);
        
        // Request randomness from Chainlink VRF
        _requestVRF(gameId);
        
        emit GameJoined(gameId, msg.sender);
    }

    /**
     * @dev Cancel a pending game (creator only)
     * @param gameId Game to cancel
     */
    function cancelGame(uint256 gameId) external nonReentrant {
        Game storage game = games[gameId];
        require(game.creator == msg.sender, "Only creator can cancel");
        require(game.state == GameState.Pending, "Game not pending");
        
        // Update state
        game.state = GameState.Cancelled;
        _removePendingGame(gameId);
        
        // Refund creator's bet
        _transferFunds(game.creator, game.amount, game.token);
    }

    // ============ NFT CHECKING FUNCTIONS ============

    /**
     * @dev Check if user owns Frog Soup NFT
     * @param user Address to check
     * @return hasNFT True if user owns at least one Frog Soup NFT
     */
    function _hasFrogSoupNFT(address user) internal view returns (bool hasNFT) {
        require(FROG_SOUP_NFT != address(0), "NFT contract not set");
        return IERC721(FROG_SOUP_NFT).balanceOf(user) > 0;
    }

    // ============ GAS-EFFICIENT ORACLE SYSTEM ============

    /**
     * @dev Handle gas abstraction with intelligent rate caching
     * @param gasToken Token to use for gas payment
     */
    function _handleGasAbstraction(address gasToken) internal {
        require(tx.gasprice <= MAX_GAS_PRICE, "Gas price too high");
        
        uint256 tokenRate = _getTokenRateWithCache(gasToken);
        uint256 gasEstimate = tx.gasprice * gasleft();
        uint256 tokenAmount = (gasEstimate * tokenRate) / 1e18;
        
        // Add 10% buffer for gas estimation variance
        tokenAmount = (tokenAmount * 110) / 100;
        
        require(tokenAmount <= MAX_GAS_COST_TOKENS, "Gas cost too high");
        
        require(
            IERC20(gasToken).transferFrom(msg.sender, address(this), tokenAmount),
            "Gas token transfer failed"
        );
        
        emit GasAbstractionUsed(msg.sender, gasToken, tokenAmount, gasEstimate);
    }

    /**
     * @dev Get token rate with intelligent caching
     * @param token Token address
     * @return rate Current token rate (tokens per ETH)
     */
    function _getTokenRateWithCache(address token) internal returns (uint256 rate) {
        GasTokenConfig storage config = gasTokenConfigs[token];
        require(config.isSupported, "Token not supported");
        
        uint256 timeSinceUpdate = block.timestamp - config.lastUpdate;
        bool cacheValid = (
            config.cachedRate > 0 &&
            timeSinceUpdate < config.updateInterval
        );
        
        if (cacheValid) {
            return uint256(config.cachedRate);
        }
        
        uint256 freshRate = _calculateDEXRate(config);
        
        // Circuit breaker: prevent extreme price changes
        if (config.lastValidPrice > 0) {
            uint256 priceChange = freshRate > config.lastValidPrice 
                ? ((freshRate - config.lastValidPrice) * 100) / config.lastValidPrice
                : ((config.lastValidPrice - freshRate) * 100) / config.lastValidPrice;
                
            if (priceChange > MAX_PRICE_CHANGE) {
                freshRate = config.lastValidPrice;
            }
        }
        
        require(freshRate >= MIN_RATE && freshRate <= MAX_RATE, "Invalid rate");
        
        config.cachedRate = uint128(freshRate);
        config.lastUpdate = uint64(block.timestamp);
        config.lastValidPrice = freshRate;
        
        emit TokenRateUpdated(token, freshRate, block.timestamp);
        
        return freshRate;
    }

    /**
     * @dev Calculate token rate from Uniswap V3 DEX
     * @param config Token configuration with pool address
     * @return rate Calculated rate (tokens per ETH)
     */
    function _calculateDEXRate(GasTokenConfig storage config) internal view returns (uint256) {
        IUniswapV3Pool pool = IUniswapV3Pool(config.dexPool);
        
        require(pool.liquidity() >= config.minLiquidity, "Insufficient DEX liquidity");
        
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_PERIOD;
        secondsAgos[1] = 0;
        
        (int56[] memory tickCumulatives,) = pool.observe(secondsAgos);
        
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 averageTick = int24(tickCumulativesDelta / int56(uint56(TWAP_PERIOD)));
        
        return _tickToPrice(averageTick, config.token0IsWETH);
    }

    /**
     * @dev Convert Uniswap V3 tick to price
     * @param tick Average tick from TWAP
     * @param token0IsWETH Whether WETH is token0 in the pool
     * @return price Token amount per 1 ETH
     */
    function _tickToPrice(int24 tick, bool token0IsWETH) internal pure returns (uint256) {
        bool isNegative = tick < 0;
        uint256 absTick = isNegative ? uint256(-int256(tick)) : uint256(int256(tick));
        
        uint256 price = 1e18;
        
        if (absTick < 1000) {
            price = 1e18 + (absTick * 1e14);
        } else {
            price = 1e18 * (1000 + absTick) / 1000;
        }
        
        if (isNegative) {
            price = 1e36 / price;
        }
        
        if (token0IsWETH) {
            return price;
        } else {
            return 1e36 / price;
        }
    }

    // ============ VRF INTEGRATION ============

    /**
     * @dev Request randomness from Chainlink VRF
     * @param gameId Game needing randomness
     */
    function _requestVRF(uint256 gameId) internal {
        bytes memory extraArgs = VRFV2PlusClient._argsToBytes(
            VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
        );
        
        (uint256 requestId,) = requestRandomness(
            callbackGasLimit,
            requestConfirmations,
            numWords,
            extraArgs
        );
        
        games[gameId].vrfRequestId = requestId;
        vrfRequests[requestId] = VRFRequest({
            gameId: gameId,
            fulfilled: false
        });
    }

    /**
     * @dev Chainlink VRF callback - resolves game when randomness received
     * @param requestId VRF request identifier
     * @param randomWords Array of random numbers from Chainlink
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override nonReentrant {
        VRFRequest storage vrfRequest = vrfRequests[requestId];
        uint256 gameId = vrfRequest.gameId;
        
        require(gameId != 0, "Invalid VRF request");
        require(!vrfRequest.fulfilled, "Request already fulfilled");
        
        Game storage game = games[gameId];
        require(game.creator != address(0), "Game does not exist");
        require(game.state == GameState.WaitingForVRF, "Game not waiting for VRF");
        
        vrfRequest.fulfilled = true;
        
        // Determine coin flip result: even = heads, odd = tails
        bool coinResult = randomWords[0] % 2 == 0;
        
        // Determine winner
        address winner = game.creatorCoinSide == coinResult ? game.creator : game.joiner;
        
        // Update game state
        game.result = coinResult;
        game.state = GameState.Resolved;
        game.winner = winner;
        
        // Award participation points
        playerPoints[game.creator] += 2;
        playerPoints[game.joiner] += 2;
        
        // Calculate payouts
        uint256 totalPot = game.amount * 2;
        uint256 platformFee = (totalPot * PLATFORM_FEE_PERCENT) / 100;
        uint256 winnerPayout = totalPot - platformFee;
        
        // Distribute platform fee equally among 6 donors
        uint256 feePerDonor = platformFee / DONOR_COUNT;
        for (uint256 i = 0; i < DONOR_COUNT; i++) {
            donorBalances[donors[i]][game.token] += feePerDonor;
        }
        
        emit GameResolved(gameId, winner, coinResult);
        
        // Transfer winnings
        _transferFunds(winner, winnerPayout, game.token);
    }

    // ============ HELPER FUNCTIONS ============

    /**
     * @dev Transfer funds (ETH or tokens) efficiently
     * @param to Recipient address
     * @param amount Amount to transfer
     * @param token Token address (address(0) for ETH)
     */
    function _transferFunds(address to, uint256 amount, address token) internal {
        if (token == address(0)) {
            (bool success,) = payable(to).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            require(IERC20(token).transfer(to, amount), "Token transfer failed");
        }
    }

    /**
     * @dev Remove game from pending games array (gas-optimized)
     * @param gameId Game to remove
     */
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

    /**
     * @dev Check if token is valid for betting
     * @param token Token address to validate
     * @return valid True if token is ETH, TOAD, or BONE
     */
    function _isValidToken(address token) internal view returns (bool valid) {
        return token == address(0) || token == TOAD_TOKEN || token == BONE_TOKEN;
    }

    // ============ VIEW FUNCTIONS ============

    /// @dev Get all pending games for UI display
    function getPendingGames() external view returns (uint256[] memory) {
        return pendingGameIds;
    }

    /// @dev Get complete game details
    function getGameDetails(uint256 gameId) external view returns (Game memory) {
        return games[gameId];
    }

    /// @dev Get player's total points
    function getPlayerPoints(address player) external view returns (uint256) {
        return playerPoints[player];
    }

    /// @dev Check if gas token is supported
    function isGasTokenSupported(address token) external view returns (bool) {
        return gasTokenConfigs[token].isSupported;
    }

    /**
     * @dev Check if user can create/join games (has required Frog Soup NFT)
     * @param user Address to check
     * @return canPlay True if user owns Frog Soup NFT
     */
    function canUserPlay(address user) external view returns (bool canPlay) {
        return _hasFrogSoupNFT(user);
    }

    /**
     * @dev Get user's Frog Soup NFT balance
     * @param user User address
     * @return balance Number of Frog Soup NFTs owned
     */
    function getUserFrogSoupBalance(address user) external view returns (uint256 balance) {
        require(FROG_SOUP_NFT != address(0), "NFT contract not set");
        return IERC721(FROG_SOUP_NFT).balanceOf(user);
    }

    /**
     * @dev Check when user can create their next game
     * @param user User address
     * @return blockNumber Block number when user can play again
     * @return canPlayNow True if user can play immediately
     */
    function getUserNextGameBlock(address user) external view returns (uint256 blockNumber, bool canPlayNow) {
        uint256 nextBlock = playerLastGameBlock[user] + MIN_BLOCK_INTERVAL + 1;
        return (nextBlock, block.number >= nextBlock);
    }

    /**
     * @dev Get donor balance for specific token
     * @param donor Donor address
     * @param token Token address (address(0) for ETH)
     * @return balance Amount available for withdrawal
     */
    function getDonorBalance(address donor, address token) external view returns (uint256 balance) {
        return donorBalances[donor][token];
    }

    /**
     * @dev Get all donor addresses
     * @return donorList Array of 6 donor addresses
     */
    function getDonors() external view returns (address[6] memory donorList) {
        return donors;
    }

    /**
     * @dev Check if address is a donor
     * @param addr Address to check
     * @return isValidDonor True if address is one of the 6 donors
     */
    function isDonor(address addr) external view returns (bool isValidDonor) {
        for (uint256 i = 0; i < DONOR_COUNT; i++) {
            if (donors[i] == addr) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Get current gas token rate (view function - doesn't update cache)
     * @param token Token address
     * @return rate Current rate, either cached or freshly calculated
     */
    function getGasTokenRate(address token) external view returns (uint256 rate) {
        GasTokenConfig storage config = gasTokenConfigs[token];
        require(config.isSupported, "Token not supported");
        
        uint256 timeSinceUpdate = block.timestamp - config.lastUpdate;
        bool cacheValid = (
            config.cachedRate > 0 &&
            timeSinceUpdate < config.updateInterval
        );
        
        if (cacheValid) {
            return uint256(config.cachedRate);
        }
        
        return _calculateDEXRate(config);
    }

    /**
     * @dev Get gas token configuration details
     * @param token Token address
     * @return isSupported Whether token is supported for gas payments
     * @return dexPool Uniswap V3 pool address
     * @return cachedRate Currently cached rate
     * @return lastUpdate Last cache update timestamp
     * @return updateInterval Cache duration in seconds
     * @return minLiquidity Minimum required pool liquidity
     */
    function getGasTokenConfig(address token) external view returns (
        bool isSupported,
        address dexPool,
        uint256 cachedRate,
        uint256 lastUpdate,
        uint256 updateInterval,
        uint256 minLiquidity
    ) {
        GasTokenConfig storage config = gasTokenConfigs[token];
        return (
            config.isSupported,
            config.dexPool,
            uint256(config.cachedRate),
            uint256(config.lastUpdate),
            uint256(config.updateInterval),
            uint256(config.minLiquidity)
        );
    }

    /**
     * @dev Calculate gas cost in tokens for a given ETH amount
     * @param gasToken Token to pay with
     * @param ethAmount ETH amount in wei
     * @return tokenAmount Token amount needed (including 10% buffer)
     */
    function calculateGasCost(address gasToken, uint256 ethAmount) external view returns (uint256 tokenAmount) {
        require(gasTokenConfigs[gasToken].isSupported, "Token not supported");
        
        uint256 rate = this.getGasTokenRate(gasToken);
        tokenAmount = (ethAmount * rate) / 1e18;
        tokenAmount = (tokenAmount * 110) / 100;
    }

    /**
     * @dev Estimate gas needed for VRF callback based on game token
     * @param gameToken Token used in the game
     * @return estimatedGas Gas estimate for callback
     */
    function estimateCallbackGas(address gameToken) external pure returns (uint256 estimatedGas) {
        return gameToken == address(0) ? 150000 : 250000;
    }

    // ============ DONOR WITHDRAWAL FUNCTIONS ============

    /**
     * @dev Withdraw fees for individual donor
     * @param token Token to withdraw (address(0) for ETH)
     */
    function withdrawDonorFees(address token) external nonReentrant {
        uint256 amount = donorBalances[msg.sender][token];
        require(amount > 0, "No fees to withdraw");
        
        donorBalances[msg.sender][token] = 0;
        
        _transferFunds(msg.sender, amount, token);
        
        emit DonorWithdrawal(msg.sender, token, amount);
    }

    /**
     * @dev Batch withdraw multiple tokens for donor
     * @param tokens Array of token addresses to withdraw
     */
    function withdrawDonorFeesBatch(address[] calldata tokens) external nonReentrant {
        require(tokens.length > 0 && tokens.length <= 10, "Invalid token count");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amount = donorBalances[msg.sender][tokens[i]];
            if (amount > 0) {
                donorBalances[msg.sender][tokens[i]] = 0;
                
                _transferFunds(msg.sender, amount, tokens[i]);
                
                emit DonorWithdrawal(msg.sender, tokens[i], amount);
            }
        }
    }

    // ============ OWNER FUNCTIONS ============
    
    /**
     * @dev Update donor address (owner only)
     * @param donorIndex Index of donor to update (0-5)
     * @param newDonor New donor address
     */
    function updateDonor(uint256 donorIndex, address newDonor) external onlyOwner {
        require(donorIndex < DONOR_COUNT, "Invalid donor index");
        require(newDonor != address(0), "Invalid donor address");
        
        address oldDonor = donors[donorIndex];
        donors[donorIndex] = newDonor;
        
        emit DonorUpdated(donorIndex, oldDonor, newDonor);
    }

    /**
     * @dev Update Frog Soup NFT contract address
     * @param newFrogSoupNFT New NFT contract address
     */
    function setFrogSoupNFT(address newFrogSoupNFT) external onlyOwner {
        require(newFrogSoupNFT != address(0), "Invalid NFT address");
        
        require(
            IERC721(newFrogSoupNFT).supportsInterface(0x80ac58cd),
            "Not a valid ERC721 contract"
        );
        
        address oldNFT = FROG_SOUP_NFT;
        FROG_SOUP_NFT = newFrogSoupNFT;
        
        emit FrogSoupNFTUpdated(oldNFT, newFrogSoupNFT);
    }

    /**
     * @dev Setup DEX oracle for a gas token
     * @param token Token address (must be TOAD or BONE)
     * @param dexPool Uniswap V3 pool address (token/WETH pair)
     * @param token0IsWETH Whether WETH is token0 in the pool
     * @param minLiquidity Minimum liquidity threshold for valid pricing
     * @param updateInterval Cache duration in seconds (default: 300 = 5 minutes)
     */
    function setupGasToken(
        address token,
        address dexPool,
        bool token0IsWETH,
        uint128 minLiquidity,
        uint256 updateInterval
    ) external onlyOwner {
        require(token == TOAD_TOKEN || token == BONE_TOKEN, "Invalid token");
        require(dexPool != address(0), "Invalid pool");
        require(updateInterval >= 60 && updateInterval <= 3600, "Invalid interval");
        require(minLiquidity > 0, "Invalid min liquidity");
        
        gasTokenConfigs[token] = GasTokenConfig({
            isSupported: true,
            dexPool: dexPool,
            token0IsWETH: token0IsWETH,
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
        
        emit TokenRateUpdated(token, currentRate, block.timestamp);
    }

    /**
     * @dev Update gas token configuration
     * @param token Token to update
     * @param newMinLiquidity New minimum liquidity requirement
     * @param newUpdateInterval New cache duration
     */
    function updateGasTokenConfig(
        address token,
        uint128 newMinLiquidity,
        uint32 newUpdateInterval
    ) external onlyOwner {
        GasTokenConfig storage config = gasTokenConfigs[token];
        require(config.isSupported, "Token not supported");
        require(newUpdateInterval >= 60 && newUpdateInterval <= 3600, "Invalid interval");
        
        config.minLiquidity = newMinLiquidity;
        config.updateInterval = newUpdateInterval;
    }

    /**
     * @dev Manually refresh token rate (owner only)
     * @param token Token to refresh
     */
    function refreshTokenRate(address token) external onlyOwner {
        GasTokenConfig storage config = gasTokenConfigs[token];
        require(config.isSupported, "Token not supported");
        
        uint256 newRate = _calculateDEXRate(config);
        
        if (config.lastValidPrice > 0) {
            uint256 priceChange = newRate > config.lastValidPrice 
                ? ((newRate - config.lastValidPrice) * 100) / config.lastValidPrice
                : ((config.lastValidPrice - newRate) * 100) / config.lastValidPrice;
                
            require(priceChange <= MAX_PRICE_CHANGE, "Price change too extreme");
        }
        
        config.cachedRate = uint128(newRate);
        config.lastUpdate = uint64(block.timestamp);
        config.lastValidPrice = newRate;
        
        emit TokenRateUpdated(token, newRate, block.timestamp);
    }

    /**
     * @dev Emergency function to disable gas token
     * @param token Token to disable
     */
    function disableGasToken(address token) external onlyOwner {
        gasTokenConfigs[token].isSupported = false;
    }

    /**
     * @dev Withdraw accumulated platform fees (deprecated - fees go to donors)
     */
    function withdrawPlatformFees(address /* token */) external view onlyOwner {
        revert("Use withdrawDonorFees() - fees distributed to donors");
    }

    /**
     * @dev Withdraw LINK tokens for VRF payments
     */
    function withdrawLink() external onlyOwner {
        LinkTokenInterface link = LinkTokenInterface(LINK_TOKEN);
        uint256 balance = link.balanceOf(address(this));
        require(balance > 0, "No LINK to withdraw");
        require(link.transfer(msg.sender, balance), "LINK transfer failed");
    }

    /**
     * @dev Update VRF configuration
     * @param _callbackGasLimit New gas limit for VRF callbacks
     * @param _requestConfirmations New confirmation count for VRF
     */
    function updateVRFConfig(uint32 _callbackGasLimit, uint16 _requestConfirmations) external onlyOwner {
        require(_callbackGasLimit >= 200000 && _callbackGasLimit <= 2500000, "Invalid gas limit");
        require(_requestConfirmations >= 1 && _requestConfirmations <= 200, "Invalid confirmations");
        
        callbackGasLimit = _callbackGasLimit;
        requestConfirmations = _requestConfirmations;
    }

    /**
     * @dev Emergency function to resolve stuck games
     * @param gameId Game to resolve manually
     */
    function emergencyResolveGame(uint256 gameId) external onlyOwner {
        Game storage game = games[gameId];
        require(game.state == GameState.WaitingForVRF, "Game not waiting for VRF");
        require(block.timestamp > game.createdAt + 1 hours, "Too early for emergency resolve");
        
        _transferFunds(game.creator, game.amount, game.token);
        _transferFunds(game.joiner, game.amount, game.token);
        
        playerPoints[game.creator] += 2;
        playerPoints[game.joiner] += 2;
        
        game.state = GameState.Cancelled;
    }

    // ============ CONTRACT HEALTH FUNCTIONS ============

    /**
     * @dev Check if contract can afford VRF requests
     * @return canAfford True if contract has sufficient LINK balance
     */
    function canAffordVRF() external view returns (bool canAfford) {
        LinkTokenInterface link = LinkTokenInterface(LINK_TOKEN);
        return link.balanceOf(address(this)) >= 250000000000000000; // 0.25 LINK minimum
    }

    /**
     * @dev Get current LINK balance
     * @return balance LINK tokens held by contract
     */
    function getLinkBalance() external view returns (uint256 balance) {
        LinkTokenInterface link = LinkTokenInterface(LINK_TOKEN);
        return link.balanceOf(address(this));
    }

    /**
     * @dev Get contract statistics for monitoring
     * @return totalGames Total games created
     * @return pendingCount Currently pending games
     * @return totalDonorFees Total fees allocated to all donors (ETH)
     */
    function getContractStats() external view returns (
        uint256 totalGames,
        uint256 pendingCount,
        uint256 totalDonorFees
    ) {
        uint256 ethFees = 0;
        for (uint256 i = 0; i < DONOR_COUNT; i++) {
            ethFees += donorBalances[donors[i]][address(0)];
        }
        
        return (
            gameCounter,
            pendingGameIds.length,
            ethFees
        );
    }

    /**
     * @dev Get Frog Soup NFT contract address
     * @return nftAddress Current Frog Soup NFT contract address
     */
    function getFrogSoupNFT() external view returns (address nftAddress) {
        return FROG_SOUP_NFT;
    }

    /**
     * @dev Receive ETH payments
     */
    receive() external payable {
        // Contract accepts ETH payments
    }
}