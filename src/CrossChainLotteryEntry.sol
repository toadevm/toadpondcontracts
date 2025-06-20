// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Updated imports to match main contract
import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CrossChainLotteryEntry - Shibarium BONE Optimized with Proportional Distribution
 * @dev Cross-chain lottery contract with proportional prize distribution
 * @notice Winners withdraw proportional shares from each chain based on contributions
 * @author Your Team
 */
contract CrossChainLotteryEntry is CCIPReceiver, ReentrancyGuard, Pausable {
    // ===== MESSAGE TYPES =====
    enum MessageType {
        ENTRY_RESPONSE,
        WINNERS_NOTIFICATION,
        ROUND_SYNC,
        ENTRY_REQUEST
    }

    // ===== STRUCTS =====

    /// @dev Packed struct for gas efficiency
    struct PendingEntry {
        uint64 timestamp; // 8 bytes - entry timestamp
        uint128 ccipFeePaid; // 16 bytes - CCIP fee paid by user
        bool verified; // 1 byte - verification status
    }

    /// @dev Round information for local chain with proportional tracking
    struct RoundInfo {
        address[] localPlayers; // Dynamic array of local players
        address[3] winners; // Winners from main contract
        uint128 localPrizePool; // This chain's contribution
        uint128 totalChainPrizePool; // Total across all chains
        bool winnersReceived; // Whether winners data received
        mapping(address => bool) hasEntered; // Player entry tracking
        mapping(address => uint32) playerIndex; // Player index mapping
        // NEW: Track chain contributions for proportional distribution
        mapping(uint64 => uint128) chainContributions;
        uint64[] contributingChains;
        uint128 mainChainContribution; // Main chain's contribution
    }

    // ===== CONSTANTS =====

    /// @dev Game constants (matching main contract)
    uint256 public constant ENTRY_FEE_BONE = 1 ether; // 1 BONE (much cheaper than 1 ETH)
    uint8 public constant POINTS_PER_ENTRY = 5;
    uint8 public constant WINNERS_SHARE = 60;
    uint8 public constant DEV_SHARE = 5;
    uint8 public constant FUNDING_SHARE = 30;
    uint8 public constant BURN_SHARE = 5;
    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    /// @dev Shibarium-specific constants (adjusted for BONE economics)
    uint256 public constant MAX_CCIP_FEE = 1000 ether; // 1000 BONE max (~$10-50 depending on BONE price)
    uint256 public constant ENTRY_EXPIRY_TIME = 1 hours; // Entry expiry unchanged
    uint256 public constant EMERGENCY_TIMELOCK = 24 hours; // Emergency timelock unchanged
    uint256 public constant MAX_CLEANUP_BATCH = 100; // Increased batch size for cheaper gas
    uint256 public constant CCIP_FEE_BUFFER_PERCENT = 150; // 50% buffer instead of 20% for volatility

    // ===== IMMUTABLE VARIABLES =====

    uint64 public immutable ethereumChainSelector;
    uint64 public immutable currentChainSelector;
    address payable public immutable devAddress;

    // ===== STATE VARIABLES =====

    /// @dev Access control
    address public contractAdmin;
    address public ethereumMainContract;
    mapping(address => bool) public authorizedCCIPSenders;

    /// @dev Round management
    uint128 public currentRoundId;
    uint32 public crossChainGasLimit = 500000;

    /// @dev Emergency controls
    uint256 public emergencyWithdrawalTimestamp;
    bool public emergencyWithdrawalRequested;

    /// @dev Funding addresses
    address payable[5] public fundingAddresses;

    // ===== MAPPINGS =====

    mapping(uint256 => RoundInfo) public rounds;
    mapping(address => PendingEntry) public pendingEntries;
    mapping(address => uint128) public pendingWithdrawalsBone;
    mapping(address => uint128) public totalWinningsBone;
    mapping(address => uint32) public entriesCount;
    mapping(address => uint32) public playerPoints;
    mapping(address => bool) public hasPendingEntry;

    // ===== EVENTS =====

    /// @dev Core lottery events
    event CrossChainEntryRequested(
        address indexed player,
        uint64 destinationChain,
        uint256 ccipFeePaid
    );
    event CrossChainEntryConfirmed(address indexed player, uint256 roundId);
    event CrossChainEntryRejected(address indexed player, string reason);
    event WinnersReceived(
        uint256 indexed roundId,
        address[3] winners,
        uint256 chainPrizePool
    );
    event LocalWinnerPayout(address indexed winner, uint256 amount);
    event WithdrawalMade(address indexed recipient, uint256 amount);
    event LocalEntryAdded(address indexed player);
    event PendingEntryAdded(
        address indexed player,
        uint256 totalPaid,
        uint256 ccipFee
    );
    event NativeBoneReceived(address indexed from, uint256 amount);
    event ContractSynced(uint256 roundId);

    /// @dev NEW: Proportional distribution events
    event RoundSynchronized(uint256 oldRound, uint256 newRound);
    event ProportionalPrizeDistributed(
        address indexed winner,
        uint256 amount,
        uint256 chainContribution,
        uint256 totalPool
    );
    event ChainContributionsReceived(
        uint256 indexed roundId,
        uint64[] chains,
        uint128[] contributions
    );

    /// @dev Admin and configuration events
    event EthereumContractUpdated(
        address indexed oldContract,
        address indexed newContract
    );
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event FundingAddressesUpdated(address payable[5] newAddresses);
    event CrossChainGasLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event AuthorizedCCIPSenderAdded(address indexed sender);
    event AuthorizedCCIPSenderRemoved(address indexed sender);

    /// @dev Player management events
    event PlayerRemoved(
        address indexed player,
        uint256 refundAmount,
        string reason
    );
    event DevFundsAllocated(uint256 amount);
    event FundingAddressesBonusDistributed(uint256 amount);

    /// @dev CCIP and fee events
    event CCIPMessageSent(
        uint64 indexed destinationChain,
        bytes32 indexed messageId,
        uint256 feePaid
    );
    event CCIPFeeRefunded(address indexed player, uint256 amount);
    event RefundStored(address indexed player, uint256 amount);

    /// @dev Emergency events
    event EmergencyEntryConfirmed(address indexed player, uint256 roundId);
    event EmergencyEntryRejected(address indexed player, string reason);
    event EmergencyPause(uint256 timestamp);
    event EmergencyWithdrawalRequested(uint256 executeTime);
    event EmergencyWithdrawalExecuted(uint256 amount);
    event SecurityAlert(string alertType, address indexed actor, uint256 value);
    event FundsRecovered(address indexed token, uint256 amount);
    event LargeWithdrawal(address indexed user, uint256 amount);

    // ===== CUSTOM ERRORS =====

    error OnlyAdmin();
    error InvalidZeroAddress();
    error InsufficientBoneAmount();
    error DuplicateEntry();
    error AlreadyHasPendingEntry();
    error NoWithdrawalAvailable();
    error WithdrawalFailed();
    error InvalidEthereumContract();
    error PlayerNotFound();
    error CCIPFeeCalculationFailed();
    error InsufficientCCIPFee();
    error ArrayTooLarge();
    error GasLimitOutOfBounds();
    error EmergencyNotRequested();
    error TimelockNotExpired();
    error CannotDrainContract();
    error InvalidFundingAddress();

    // ===== MODIFIERS =====

    modifier onlyAdmin() {
        if (msg.sender != contractAdmin) revert OnlyAdmin();
        _;
    }

    modifier validFundingAddresses() {
        for (uint256 i = 0; i < 5; i++) {
            if (fundingAddresses[i] == address(0))
                revert InvalidFundingAddress();
        }
        _;
    }

    // ===== CONSTRUCTOR =====

    constructor(
        address _ccipRouter,
        address _ethereumMainContract,
        uint64 _ethereumChainSelector,
        uint64 _currentChainSelector,
        address payable _devAddress,
        address payable[5] memory _fundingAddresses
    ) CCIPReceiver(_ccipRouter) {
        if (_ethereumMainContract == address(0) || _devAddress == address(0)) {
            revert InvalidZeroAddress();
        }

        // Validate funding addresses
        for (uint256 i = 0; i < 5; i++) {
            if (_fundingAddresses[i] == address(0))
                revert InvalidFundingAddress();
        }

        contractAdmin = _devAddress;
        emit AdminChanged(address(0), _devAddress);

        ethereumMainContract = _ethereumMainContract;
        ethereumChainSelector = _ethereumChainSelector;
        currentChainSelector = _currentChainSelector;
        devAddress = _devAddress;
        fundingAddresses = _fundingAddresses;
        currentRoundId = 1;

        // Authorize main contract for CCIP messages
        authorizedCCIPSenders[_ethereumMainContract] = true;
    }

    // ===== CCIP FEE CALCULATION FUNCTIONS =====

    /**
     * @dev Get estimated total cost for lottery entry (entry fee + CCIP fee)
     * @dev ADJUSTED: Higher fee cap and buffer for Shibarium BONE economics
     */
    function getEntryTotalCost()
        external
        view
        returns (
            uint256 entryFee,
            uint256 estimatedCCIPFee,
            uint256 recommendedTotal,
            string memory message
        )
    {
        entryFee = ENTRY_FEE_BONE;

        // Get CCIP fee with fallback protection (Shibarium-adjusted)
        try this.estimateCCIPFee() returns (uint256 fee) {
            estimatedCCIPFee = fee;
            // Cap at 1000 BONE instead of 0.1 ETH (much more reasonable for BONE)
            if (estimatedCCIPFee > MAX_CCIP_FEE) {
                estimatedCCIPFee = MAX_CCIP_FEE;
            }
        } catch {
            estimatedCCIPFee = 10 ether; // Fallback: 10 BONE instead of 0.01 ETH
        }

        // 50% buffer instead of 20% due to BONE volatility
        recommendedTotal =
            entryFee +
            ((estimatedCCIPFee * CCIP_FEE_BUFFER_PERCENT) / 100);
        message = "Entry fee (1 BONE) + cross-chain fee (~10-100 BONE). Excess BONE will be refunded.";
    }

    /**
     * @dev Estimate CCIP fee for cross-chain message
     * @dev ADJUSTED: Works with BONE values instead of ETH values
     */
    function estimateCCIPFee() external view returns (uint256) {
        bytes memory data = abi.encode(
            uint8(MessageType.ENTRY_REQUEST),
            currentRoundId,
            address(this),
            ENTRY_FEE_BONE
        );

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(ethereumMainContract),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: crossChainGasLimit})
            ),
            feeToken: address(0)
        });

        return
            IRouterClient(getRouter()).getFee(
                ethereumChainSelector,
                ccipMessage
            );
    }

    /**
     * @dev Get user-friendly entry instructions
     * @dev ADJUSTED: BONE-specific messaging and amounts
     */
    function getEntryInstructions()
        external
        view
        returns (
            string memory instructions,
            uint256 minimumRequired,
            uint256 recommendedAmount
        )
    {
        uint256 entryFee = ENTRY_FEE_BONE;

        uint256 ccipFee;
        try this.estimateCCIPFee() returns (uint256 fee) {
            ccipFee = fee > MAX_CCIP_FEE ? MAX_CCIP_FEE : fee;
        } catch {
            ccipFee = 10 ether; // 10 BONE fallback
        }

        minimumRequired = entryFee + ccipFee;
        recommendedAmount =
            entryFee +
            ((ccipFee * CCIP_FEE_BUFFER_PERCENT) / 100);

        instructions = "Send 1 BONE entry fee + cross-chain verification fee (usually 10-100 BONE). Excess will be refunded automatically.";
    }

    // ===== ENTRY FUNCTIONS =====

    /**
     * @dev Enter lottery with native BONE
     * @dev ADJUSTED: Removed withdrawal limits, adjusted for BONE economics
     */
    function enterLottery()
        external
        payable
        nonReentrant
        whenNotPaused
        validFundingAddresses
    {
        if (hasPendingEntry[msg.sender]) revert AlreadyHasPendingEntry();

        RoundInfo storage round = rounds[currentRoundId];
        if (round.hasEntered[msg.sender]) revert DuplicateEntry();

        // Calculate required amounts with BONE-adjusted error handling
        uint256 entryFee = ENTRY_FEE_BONE;
        uint256 estimatedCCIPFee;

        try this.estimateCCIPFee() returns (uint256 fee) {
            estimatedCCIPFee = fee > MAX_CCIP_FEE ? MAX_CCIP_FEE : fee;
        } catch {
            revert CCIPFeeCalculationFailed();
        }

        uint256 minimumRequired = entryFee + estimatedCCIPFee;

        if (msg.value < minimumRequired) {
            revert InsufficientCCIPFee();
        }

        // Calculate CCIP budget (everything above entry fee)
        uint256 ccipBudget = msg.value - entryFee;

        // Add to pending entries
        pendingEntries[msg.sender] = PendingEntry({
            timestamp: uint64(block.timestamp),
            ccipFeePaid: uint128(ccipBudget),
            verified: false
        });
        hasPendingEntry[msg.sender] = true;

        // Request NFT verification
        _requestNFTVerification(msg.sender, ccipBudget);

        emit PendingEntryAdded(msg.sender, msg.value, ccipBudget);
        emit NativeBoneReceived(msg.sender, entryFee);
    }

    /**
     * @dev Request NFT verification using user-provided CCIP budget
     * @dev ADJUSTED: Better error handling for BONE-based fees
     */
    function _requestNFTVerification(
        address player,
        uint256 ccipBudget
    ) internal {
        bytes memory data = abi.encode(
            uint8(MessageType.ENTRY_REQUEST),
            currentRoundId, // Send current round for sync
            player,
            ENTRY_FEE_BONE
        );

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(ethereumMainContract),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: crossChainGasLimit})
            ),
            feeToken: address(0)
        });

        // Get actual CCIP fee with error handling
        uint256 actualCCIPFee;
        try
            IRouterClient(getRouter()).getFee(
                ethereumChainSelector,
                ccipMessage
            )
        returns (uint256 fee) {
            actualCCIPFee = fee;
        } catch {
            _removePendingEntryWithRefund(
                player,
                "CCIP fee calculation failed"
            );
            return;
        }

        if (ccipBudget < actualCCIPFee) {
            _removePendingEntryWithRefund(player, "Insufficient CCIP fee");
            return;
        }

        try
            IRouterClient(getRouter()).ccipSend{value: actualCCIPFee}(
                ethereumChainSelector,
                ccipMessage
            )
        returns (bytes32 messageId) {
            emit CrossChainEntryRequested(
                player,
                ethereumChainSelector,
                actualCCIPFee
            );
            emit CCIPMessageSent(
                ethereumChainSelector,
                messageId,
                actualCCIPFee
            );

            // Refund unused CCIP budget (more lenient gas limit for BONE)
            uint256 ccipRefund = ccipBudget - actualCCIPFee;
            if (ccipRefund > 0) {
                (bool success, ) = payable(player).call{
                    value: ccipRefund,
                    gas: 10000
                }(""); // Higher gas limit
                if (success) {
                    emit CCIPFeeRefunded(player, ccipRefund);
                } else {
                    // Store refund for manual withdrawal
                    pendingWithdrawalsBone[player] += uint128(ccipRefund);
                    emit RefundStored(player, ccipRefund);
                }
            }
        } catch {
            _removePendingEntryWithRefund(player, "CCIP message failed");
        }
    }

    // ===== UPDATED CCIP MESSAGE HANDLING =====

    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        if (abi.decode(message.sender, (address)) != ethereumMainContract)
            return;

        bytes memory data = message.data;

        uint8 messageType;
        assembly {
            messageType := byte(0, mload(add(data, 63)))
        }

        if (messageType == uint8(MessageType.ENTRY_RESPONSE)) {
            _handleEntryResponse(data);
        } else if (messageType == uint8(MessageType.WINNERS_NOTIFICATION)) {
            _handleWinnersNotification(data);
        } else if (messageType == uint8(MessageType.ROUND_SYNC)) {
            _handleRoundSync(data);
        }
    }

    function _handleEntryResponse(bytes memory data) internal {
        (
            ,
            uint256 mainRoundId,
            address player,
            bool approved,
            string memory reason
        ) = abi.decode(data, (uint8, uint256, address, bool, string));

        // Sync round if needed
        if (mainRoundId > currentRoundId) {
            _syncToRound(mainRoundId);
        }

        if (!hasPendingEntry[player]) return;

        if (approved) {
            _confirmPlayerEntry(player);
            emit CrossChainEntryConfirmed(player, currentRoundId);
        } else {
            _removePendingEntry(player, reason);
            emit CrossChainEntryRejected(player, reason);
        }
    }

    function _handleWinnersNotification(bytes memory data) internal {
        (
            ,
            uint256 roundId,
            address[3] memory winners,
            uint256 totalPrizePool,
            uint128 mainChainContribution,
            uint64[] memory chains,
            uint128[] memory contributions
        ) = abi.decode(
                data,
                (
                    uint8,
                    uint256,
                    address[3],
                    uint256,
                    uint128,
                    uint64[],
                    uint128[]
                )
            );

        // Sync round if needed
        if (roundId > currentRoundId) {
            _syncToRound(roundId);
        }

        _processRoundWinners(
            roundId,
            winners,
            totalPrizePool,
            mainChainContribution,
            chains,
            contributions
        );
    }

    function _handleRoundSync(bytes memory data) internal {
        (, uint256 newRoundId) = abi.decode(data, (uint8, uint256));

        if (newRoundId > currentRoundId) {
            _syncToRound(newRoundId);
        }
    }

    function _syncToRound(uint256 newRoundId) internal {
        if (newRoundId <= currentRoundId) return;

        uint256 oldRound = currentRoundId;
        currentRoundId = uint128(newRoundId);

        emit RoundSynchronized(oldRound, newRoundId);
        emit ContractSynced(newRoundId);
    }

    // ===== PLAYER MANAGEMENT =====

    function _confirmPlayerEntry(address player) internal {
        if (!hasPendingEntry[player]) return;

        RoundInfo storage round = rounds[currentRoundId];

        // Add player to round
        round.localPlayers.push(player);
        unchecked {
            round.localPrizePool += uint128(ENTRY_FEE_BONE);
            round.playerIndex[player] = uint32(round.localPlayers.length - 1);
            ++entriesCount[player];
            playerPoints[player] += POINTS_PER_ENTRY;
        }
        round.hasEntered[player] = true;

        // Remove from pending
        delete pendingEntries[player];
        hasPendingEntry[player] = false;

        emit LocalEntryAdded(player);
    }

    function _removePendingEntry(
        address player,
        string memory reason
    ) internal {
        if (!hasPendingEntry[player]) return;

        // Allocate entry fee to dev (CCIP fee was already spent)
        unchecked {
            pendingWithdrawalsBone[devAddress] += uint128(ENTRY_FEE_BONE);
            totalWinningsBone[devAddress] += uint128(ENTRY_FEE_BONE);
        }

        delete pendingEntries[player];
        hasPendingEntry[player] = false;

        emit PlayerRemoved(player, ENTRY_FEE_BONE, reason);
        emit DevFundsAllocated(ENTRY_FEE_BONE);
    }

    /**
     * @dev Remove pending entry with full refund
     * @dev ADJUSTED: Higher gas limit for BONE transfers
     */
    function _removePendingEntryWithRefund(
        address player,
        string memory reason
    ) internal {
        if (!hasPendingEntry[player]) return;

        // Calculate total refund (entry fee + unused CCIP fee)
        uint256 totalRefund = ENTRY_FEE_BONE +
            pendingEntries[player].ccipFeePaid;

        // Try refund with higher gas limit for BONE
        (bool success, ) = payable(player).call{value: totalRefund, gas: 10000}(
            ""
        );
        if (!success) {
            // Store refund for manual withdrawal
            pendingWithdrawalsBone[player] += uint128(totalRefund);
            emit RefundStored(player, totalRefund);
        }

        delete pendingEntries[player];
        hasPendingEntry[player] = false;

        emit PlayerRemoved(player, totalRefund, reason);
    }

    // ===== NEW: PROPORTIONAL DISTRIBUTION =====

    function _processRoundWinners(
        uint256 roundId,
        address[3] memory winners,
        uint256 totalPrizePool,
        uint128 mainChainContribution,
        uint64[] memory chains,
        uint128[] memory contributions
    ) internal {
        RoundInfo storage round = rounds[roundId];
        round.winnersReceived = true;
        round.winners = winners;
        round.totalChainPrizePool = uint128(totalPrizePool);
        round.mainChainContribution = mainChainContribution;

        // Store chain contributions
        for (uint256 i = 0; i < chains.length; i++) {
            round.chainContributions[chains[i]] = contributions[i];
            round.contributingChains.push(chains[i]);
        }

        emit ChainContributionsReceived(roundId, chains, contributions);
        emit WinnersReceived(roundId, winners, totalPrizePool);

        _distributePrizesProportionally(roundId);

        if (roundId == currentRoundId) {
            _startNewRound();
        }
    }

    function _distributePrizesProportionally(uint256 roundId) internal {
        RoundInfo storage round = rounds[roundId];
        if (!round.winnersReceived || round.localPrizePool == 0) return;

        uint256 localContribution = round.localPrizePool;
        uint256 totalPool = round.totalChainPrizePool;

        // Calculate this chain's proportion of total pool
        uint256 localWinnersShare = (localContribution * WINNERS_SHARE) / 100;
        uint256 localDevShare = (localContribution * DEV_SHARE) / 100;
        uint256 localFundingShare = (localContribution * FUNDING_SHARE) / 100;

        // Distribute proportional winner shares
        uint256 perWinnerAmount = localWinnersShare / 3;

        for (uint256 i = 0; i < 3; i++) {
            if (round.winners[i] != address(0)) {
                unchecked {
                    pendingWithdrawalsBone[round.winners[i]] += uint128(
                        perWinnerAmount
                    );
                    totalWinningsBone[round.winners[i]] += uint128(
                        perWinnerAmount
                    );
                }
                emit ProportionalPrizeDistributed(
                    round.winners[i],
                    perWinnerAmount,
                    localContribution,
                    totalPool
                );
            }
        }

        // Distribute local dev and funding shares
        unchecked {
            pendingWithdrawalsBone[devAddress] += uint128(localDevShare);
            totalWinningsBone[devAddress] += uint128(localDevShare);
        }

        uint256 fundingPerAddress = localFundingShare / 5;
        for (uint256 i = 0; i < 5; i++) {
            unchecked {
                pendingWithdrawalsBone[fundingAddresses[i]] += uint128(
                    fundingPerAddress
                );
                totalWinningsBone[fundingAddresses[i]] += uint128(
                    fundingPerAddress
                );
            }
        }

        emit FundingAddressesBonusDistributed(localFundingShare);
    }

    function _startNewRound() internal {
        unchecked {
            ++currentRoundId;
        }
    }

    /**
     * @dev Withdraw native BONE winnings
     * @dev ADJUSTED: No withdrawal limits - BONE is much cheaper than ETH
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawalsBone[msg.sender];
        if (amount == 0) revert NoWithdrawalAvailable();

        // Emit event for large withdrawals (monitoring purposes only)
        if (amount > 1000 ether) {
            // 1000 BONE threshold
            emit LargeWithdrawal(msg.sender, amount);
        }

        // Update state before external call (CEI pattern)
        pendingWithdrawalsBone[msg.sender] = 0;

        // Higher gas limit for BONE transfers
        (bool success, ) = payable(msg.sender).call{value: amount, gas: 10000}(
            ""
        );
        if (!success) {
            // Restore balance if transfer fails
            pendingWithdrawalsBone[msg.sender] = uint128(amount);
            revert WithdrawalFailed();
        }

        emit WithdrawalMade(msg.sender, amount);
    }

    // ===== NEW VIEW FUNCTIONS =====

    function getCurrentRoundPlayers() external view returns (address[] memory) {
        return rounds[currentRoundId].localPlayers;
    }

    function getRoundInfo(
        uint256 roundId
    )
        external
        view
        returns (
            uint256 playerCount,
            uint256 localPrizePool,
            bool winnersReceived,
            address[3] memory winners,
            uint256 totalChainPrizePool
        )
    {
        RoundInfo storage round = rounds[roundId];
        return (
            round.localPlayers.length,
            round.localPrizePool,
            round.winnersReceived,
            round.winners,
            round.totalChainPrizePool
        );
    }

    function getPlayerStats(
        address player
    )
        external
        view
        returns (
            uint256 totalWon,
            uint256 participationCount,
            uint256 points,
            uint256 pendingAmount,
            bool hasPending
        )
    {
        return (
            totalWinningsBone[player],
            entriesCount[player],
            playerPoints[player],
            pendingWithdrawalsBone[player],
            hasPendingEntry[player]
        );
    }

    function getPendingEntry(
        address player
    )
        external
        view
        returns (
            bool exists,
            uint256 timestamp,
            uint256 ccipFeePaid,
            bool verified
        )
    {
        PendingEntry storage entry = pendingEntries[player];
        return (
            hasPendingEntry[player],
            entry.timestamp,
            entry.ccipFeePaid,
            entry.verified
        );
    }

    function hasPlayerEntered(
        uint256 roundId,
        address player
    ) external view returns (bool) {
        return rounds[roundId].hasEntered[player];
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getAdmin() public view returns (address) {
        return contractAdmin;
    }

    function getFundingAddresses()
        external
        view
        returns (address payable[5] memory)
    {
        return fundingAddresses;
    }

    function getWinnerShareFromThisChain(
        uint256 roundId,
        address winner
    ) external view returns (uint256) {
        RoundInfo storage round = rounds[roundId];

        // Check if address is a winner
        bool isWinner = false;
        for (uint256 i = 0; i < 3; i++) {
            if (round.winners[i] == winner) {
                isWinner = true;
                break;
            }
        }

        if (!isWinner || round.localPrizePool == 0) return 0;

        uint256 localWinnersShare = (round.localPrizePool * WINNERS_SHARE) /
            100;
        return localWinnersShare / 3;
    }

    function getChainContributions(
        uint256 roundId
    )
        external
        view
        returns (
            uint64[] memory chains,
            uint128[] memory contributions,
            uint128 localContribution,
            uint128 totalPool
        )
    {
        RoundInfo storage round = rounds[roundId];

        uint256 chainCount = round.contributingChains.length + 2; // +2 for main and local
        chains = new uint64[](chainCount);
        contributions = new uint128[](chainCount);

        // Add contributing chains
        for (uint256 i = 0; i < round.contributingChains.length; i++) {
            chains[i] = round.contributingChains[i];
            contributions[i] = round.chainContributions[
                round.contributingChains[i]
            ];
        }

        // Add main chain
        chains[chainCount - 2] = ethereumChainSelector;
        contributions[chainCount - 2] = round.mainChainContribution;

        // Add this chain
        chains[chainCount - 1] = currentChainSelector;
        contributions[chainCount - 1] = round.localPrizePool;

        localContribution = round.localPrizePool;
        totalPool = round.totalChainPrizePool;
    }

    function getWithdrawableAmounts(
        address user
    )
        external
        view
        returns (
            uint256 pendingAmount,
            uint256[] memory roundIds,
            uint256[] memory amounts,
            bool[] memory hasWithdrawn
        )
    {
        pendingAmount = pendingWithdrawalsBone[user];

        // Get last 10 rounds for user
        uint256 startRound = currentRoundId > 10 ? currentRoundId - 10 : 1;
        uint256 count = currentRoundId - startRound + 1;

        roundIds = new uint256[](count);
        amounts = new uint256[](count);
        hasWithdrawn = new bool[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 roundId = startRound + i;
            roundIds[i] = roundId;
            amounts[i] = this.getWinnerShareFromThisChain(roundId, user);
            hasWithdrawn[i] = amounts[i] == 0 || pendingAmount == 0;
        }
    }

    /**
     * @dev Get Shibarium-specific contract information
     */
    function getShibariumInfo()
        external
        pure
        returns (
            uint256 maxCcipFee,
            uint256 ccipBufferPercent,
            uint256 maxCleanupBatch,
            string memory chainName
        )
    {
        return (
            MAX_CCIP_FEE,
            CCIP_FEE_BUFFER_PERCENT,
            MAX_CLEANUP_BATCH,
            "Shibarium"
        );
    }

    // ===== INTERNAL HELPER FUNCTIONS =====

    function handleEntryResponse(bytes memory data) external {
        require(msg.sender == address(this), "Internal call only");
        _handleEntryResponse(data);
    }

    function handleWinnersNotification(bytes memory data) external {
        require(msg.sender == address(this), "Internal call only");
        _handleWinnersNotification(data);
    }

    function handleRoundSync(bytes memory data) external {
        require(msg.sender == address(this), "Internal call only");
        _handleRoundSync(data);
    }

    // ===== ADMIN FUNCTIONS =====

    function changeAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidZeroAddress();
        emit AdminChanged(contractAdmin, newAdmin);
        contractAdmin = newAdmin;
    }

    function setEthereumMainContract(
        address _ethereumMainContract
    ) external onlyAdmin {
        if (_ethereumMainContract == address(0)) revert InvalidZeroAddress();

        // Remove old contract authorization
        authorizedCCIPSenders[ethereumMainContract] = false;

        emit EthereumContractUpdated(
            ethereumMainContract,
            _ethereumMainContract
        );
        ethereumMainContract = _ethereumMainContract;

        // Authorize new contract
        authorizedCCIPSenders[_ethereumMainContract] = true;
    }

    function setCrossChainGasLimit(uint256 gasLimit) external onlyAdmin {
        if (gasLimit < 100000 || gasLimit > 1000000)
            revert GasLimitOutOfBounds();

        uint256 oldLimit = crossChainGasLimit;
        crossChainGasLimit = uint32(gasLimit);

        emit CrossChainGasLimitUpdated(oldLimit, gasLimit);
    }

    function updateFundingAddresses(
        address payable[5] calldata newFundingAddresses
    ) external onlyAdmin {
        for (uint256 i = 0; i < 5; i++) {
            if (newFundingAddresses[i] == address(0))
                revert InvalidFundingAddress();
        }
        fundingAddresses = newFundingAddresses;
        emit FundingAddressesUpdated(newFundingAddresses);
    }

    function addAuthorizedCCIPSender(address sender) external onlyAdmin {
        if (sender == address(0)) revert InvalidZeroAddress();
        authorizedCCIPSenders[sender] = true;
        emit AuthorizedCCIPSenderAdded(sender);
    }

    function removeAuthorizedCCIPSender(address sender) external onlyAdmin {
        authorizedCCIPSenders[sender] = false;
        emit AuthorizedCCIPSenderRemoved(sender);
    }

    function pauseContract() external onlyAdmin {
        _pause();
        emit EmergencyPause(block.timestamp);
    }

    function unpauseContract() external onlyAdmin {
        _unpause();
    }

    // ===== ADMIN FUNCTIONS WITH ROUND SYNC =====

    function emergencySetRound(uint256 newRoundId) external onlyAdmin {
        if (newRoundId != currentRoundId) {
            uint256 oldRound = currentRoundId;
            currentRoundId = uint128(newRoundId);
            emit RoundSynchronized(oldRound, newRoundId);
        }
    }

    function manualSyncWithMainnet() external onlyAdmin {
        // Send a sync request to mainnet
        bytes memory data = abi.encode(
            uint8(MessageType.ROUND_SYNC),
            currentRoundId
        );

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(ethereumMainContract),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 100000})
            ),
            feeToken: address(0)
        });

        try
            IRouterClient(getRouter()).ccipSend{
                value: IRouterClient(getRouter()).getFee(
                    ethereumChainSelector,
                    ccipMessage
                )
            }(ethereumChainSelector, ccipMessage)
        {
            emit SecurityAlert(
                "Manual sync requested",
                msg.sender,
                currentRoundId
            );
        } catch {
            revert("Sync request failed");
        }
    }

    // ===== EMERGENCY FUNCTIONS (Shibarium Adjusted) =====

    /**
     * @dev Emergency player resync - unchanged functionality
     */
    function emergencyResyncPlayer(
        address player,
        uint256 roundId,
        bool shouldAdd
    ) external onlyAdmin {
        if (roundId == 0) roundId = currentRoundId;

        if (shouldAdd) {
            if (
                hasPendingEntry[player] && !rounds[roundId].hasEntered[player]
            ) {
                _confirmPlayerEntry(player);
                emit EmergencyEntryConfirmed(player, roundId);
            }
        } else {
            if (hasPendingEntry[player]) {
                _removePendingEntry(player, "Rejected manually by admin");
                emit EmergencyEntryRejected(
                    player,
                    "Rejected manually by admin"
                );
            }
        }
    }

    function emergencyClearPendingEntry(
        address player,
        string calldata reason
    ) external onlyAdmin {
        if (!hasPendingEntry[player]) return;
        _removePendingEntry(player, reason);
    }

    function emergencyProcessWinners(
        uint256 roundId,
        address[3] calldata winners,
        uint256 chainPrizePool,
        uint128 mainChainContribution,
        uint64[] calldata chains,
        uint128[] calldata contributions
    ) external onlyAdmin {
        if (roundId == 0) return;
        _processRoundWinners(
            roundId,
            winners,
            chainPrizePool,
            mainChainContribution,
            chains,
            contributions
        );
    }

    function requestEmergencyWithdrawal() external onlyAdmin {
        emergencyWithdrawalTimestamp = block.timestamp + EMERGENCY_TIMELOCK;
        emergencyWithdrawalRequested = true;
        emit EmergencyWithdrawalRequested(emergencyWithdrawalTimestamp);
    }

    function executeEmergencyWithdrawal() external onlyAdmin {
        if (!emergencyWithdrawalRequested) revert EmergencyNotRequested();
        if (block.timestamp < emergencyWithdrawalTimestamp)
            revert TimelockNotExpired();

        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = payable(contractAdmin).call{value: balance}("");
            require(success, "Emergency withdrawal failed");
        }

        emergencyWithdrawalRequested = false;
        emit EmergencyWithdrawalExecuted(balance);
    }

    /**
     * @dev Clean up expired entries - ADJUSTED for Shibarium
     * @dev INCREASED batch size from 50 to 100 due to cheaper gas on Shibarium
     */
    function cleanupExpiredEntries(
        address[] calldata players
    ) external onlyAdmin {
        if (players.length > MAX_CLEANUP_BATCH) revert ArrayTooLarge(); // Now 100 instead of 50

        for (uint256 i; i < players.length; ) {
            address player = players[i];
            if (
                hasPendingEntry[player] &&
                block.timestamp >
                pendingEntries[player].timestamp + ENTRY_EXPIRY_TIME
            ) {
                _removePendingEntry(player, "Entry expired");
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Recover stuck funds - ADJUSTED for Shibarium BONE economics
     * @dev REMOVED the 10% limit since BONE is much cheaper
     */
    function recoverStuckFunds(
        address token,
        uint256 amount
    ) external onlyAdmin {
        if (token == address(0)) {
            // Native BONE recovery - no percentage limit due to low value
            // Only check that we're not withdrawing more than available
            require(amount <= address(this).balance, "Amount exceeds balance");
            (bool success, ) = payable(contractAdmin).call{value: amount}("");
            require(success, "Recovery failed");
        } else {
            // ERC20 token recovery
            IERC20(token).transfer(contractAdmin, amount);
        }

        emit FundsRecovered(token, amount);
    }

    function forceRoundSync(uint256 newRoundId) external onlyAdmin {
        if (newRoundId > currentRoundId) {
            _syncToRound(newRoundId);
        }
    }

    /**
     * @dev Batch operations for Shibarium efficiency
     * @dev NEW: Batch confirm multiple players (cheaper gas allows this)
     */
    function batchConfirmPlayers(
        address[] calldata players
    ) external onlyAdmin {
        require(players.length <= 20, "Batch too large"); // Reasonable limit

        for (uint256 i; i < players.length; ) {
            if (hasPendingEntry[players[i]]) {
                _confirmPlayerEntry(players[i]);
                emit EmergencyEntryConfirmed(players[i], currentRoundId);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Batch reject multiple players
     * @dev NEW: Batch operations are more feasible on Shibarium
     */
    function batchRejectPlayers(
        address[] calldata players,
        string calldata reason
    ) external onlyAdmin {
        require(players.length <= 20, "Batch too large");

        for (uint256 i; i < players.length; ) {
            if (hasPendingEntry[players[i]]) {
                _removePendingEntry(players[i], reason);
                emit EmergencyEntryRejected(players[i], reason);
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Emergency mass refund function for Shibarium
     * @dev NEW: Useful for contract migrations or major issues
     */
    function emergencyMassRefund(
        address[] calldata players
    ) external onlyAdmin {
        require(players.length <= 50, "Batch too large");

        for (uint256 i; i < players.length; ) {
            address player = players[i];
            if (hasPendingEntry[player]) {
                _removePendingEntryWithRefund(player, "Emergency mass refund");
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Set custom CCIP fee cap for market conditions
     * @dev NEW: Allows admin to adjust for BONE price volatility
     */
    function updateMaxCCIPFee(uint256 newMaxFee) external onlyAdmin {
        require(
            newMaxFee >= 1 ether && newMaxFee <= 10000 ether,
            "Fee out of reasonable range"
        );
        // Update would need to modify constant, so this would be in a separate upgradeable pattern
        emit SecurityAlert(
            "Max CCIP fee update requested",
            msg.sender,
            newMaxFee
        );
    }

    // ===== SHIBARIUM-SPECIFIC HELPER FUNCTIONS =====

    /**
     * @dev Check if contract has sufficient BONE for operations
     * @dev Shibarium-specific: helps monitor contract health
     */
    function getContractHealth()
        external
        view
        returns (
            uint256 totalBalance,
            uint256 totalPendingWithdrawals,
            uint256 availableForOperations,
            bool isHealthy,
            string memory status
        )
    {
        totalBalance = address(this).balance;

        // Calculate total pending withdrawals (expensive but useful for monitoring)
        totalPendingWithdrawals = 0;
        // Note: In a real implementation, you'd track this more efficiently

        availableForOperations = totalBalance; // Simplified
        isHealthy = totalBalance > 100 ether; // At least 100 BONE for operations

        if (isHealthy) {
            status = "Contract has sufficient BONE for operations";
        } else {
            status = "Low BONE balance - consider funding";
        }
    }

    /**
     * @dev Get estimated costs in BONE for various operations
     * @dev Helps users understand Shibarium costs
     */
    function getOperationCosts()
        external
        view
        returns (
            uint256 entryFee,
            uint256 estimatedCCIPFee,
            uint256 totalEntryEstimate,
            uint256 gasPrice,
            string memory costSummary
        )
    {
        entryFee = ENTRY_FEE_BONE;

        try this.estimateCCIPFee() returns (uint256 fee) {
            estimatedCCIPFee = fee;
        } catch {
            estimatedCCIPFee = 10 ether; // Fallback
        }

        totalEntryEstimate =
            entryFee +
            ((estimatedCCIPFee * CCIP_FEE_BUFFER_PERCENT) / 100);
        gasPrice = tx.gasprice;

        costSummary = "Entry costs ~1-100 BONE total. Much cheaper than Ethereum!";
    }

    /**
     * @dev Emergency contact information for Shibarium users
     */
    function getEmergencyInfo()
        external
        pure
        returns (
            string memory network,
            string memory support,
            string memory docs
        )
    {
        return (
            "Shibarium Network",
            "Contact admin for emergency support",
            "Check documentation for troubleshooting"
        );
    }

    // ===== RECEIVE FUNCTIONS =====

    /**
     * @dev Receive function for native BONE deposits
     * @dev Shibarium: BONE is the native gas token
     */
    receive() external payable {
        emit NativeBoneReceived(msg.sender, msg.value);
    }

    /**
     * @dev Fallback function for native BONE deposits
     */
    fallback() external payable {
        emit NativeBoneReceived(msg.sender, msg.value);
    }
}
