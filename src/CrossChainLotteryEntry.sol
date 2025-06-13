// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Updated imports to match main contract
import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title CrossChainLotteryEntry - User Pays CCIP Fees Version
 * @dev Self-sustaining cross-chain lottery contract for Shibarium/Puppynet
 * @notice Users pay both entry fee and cross-chain verification fees
 */
contract CrossChainLotteryEntry is CCIPReceiver, ReentrancyGuard, Pausable {
    // Packed structs for gas efficiency
    struct PendingEntry {
        uint64 timestamp;
        uint128 ccipFeePaid; // Track CCIP fee paid by user
        bool verified;
    }

    struct RoundInfo {
        address[] localPlayers;
        address[3] winners;
        uint128 localPrizePool;
        uint128 totalChainPrizePool;
        bool winnersReceived;
        mapping(address => bool) hasEntered;
        mapping(address => uint32) playerIndex;
    }

    // Events
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
    event EthereumContractUpdated(
        address indexed oldContract,
        address indexed newContract
    );
    event PlayerRemoved(
        address indexed player,
        uint256 refundAmount,
        string reason
    );
    event NativeBoneBurned(uint256 amount);
    event WithdrawalMade(address indexed recipient, uint256 amount);
    event LocalEntryAdded(address indexed player);
    event PendingEntryAdded(address indexed player, uint256 totalPaid, uint256 ccipFee);
    event DevFundsAllocated(uint256 amount);
    event CCIPMessageSent(
        uint64 indexed destinationChain,
        bytes32 indexed messageId,
        uint256 feePaid
    );
    event CCIPFeeRefunded(address indexed player, uint256 amount);
    event EmergencyEntryConfirmed(address indexed player, uint256 roundId);
    event EmergencyEntryRejected(address indexed player, string reason);
    event NativeBoneReceived(address indexed from, uint256 amount);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event ContractSynced(uint256 roundId);

    // Constants (matching main contract)
    uint256 public constant ENTRY_FEE_BONE = 1 ether; // 1 BONE for testing
    uint8 public constant POINTS_PER_ENTRY = 5;
    uint8 public constant WINNERS_SHARE = 60;
    uint8 public constant DEV_SHARE = 5;
    uint8 public constant FUNDING_SHARE = 30;
    uint8 public constant BURN_SHARE = 5;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Immutable variables
    uint64 public immutable ethereumChainSelector;
    uint64 public immutable currentChainSelector;
    address payable public immutable devAddress;

    // State variables
    address public contractAdmin;
    address public ethereumMainContract;
    uint128 public currentRoundId;
    uint32 public crossChainGasLimit = 500000;

    // Funding addresses
    address payable[5] public fundingAddresses;

    // Mappings
    mapping(uint256 => RoundInfo) public rounds;
    mapping(address => PendingEntry) public pendingEntries;
    mapping(address => uint128) public pendingWithdrawalsBone;
    mapping(address => uint128) public totalWinningsBone;
    mapping(address => uint32) public entriesCount;
    mapping(address => uint32) public playerPoints;
    mapping(address => bool) public hasPendingEntry;

    // Custom errors
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

    modifier onlyAdmin() {
        if (msg.sender != contractAdmin) revert OnlyAdmin();
        _;
    }

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
        
        contractAdmin = _devAddress;
        emit AdminChanged(address(0), _devAddress);
        
        ethereumMainContract = _ethereumMainContract;
        ethereumChainSelector = _ethereumChainSelector;
        currentChainSelector = _currentChainSelector;
        devAddress = _devAddress;
        fundingAddresses = _fundingAddresses;
        currentRoundId = 1;
    }

    // ===== CCIP FEE CALCULATION FUNCTIONS =====

    /**
     * @dev Get estimated total cost for lottery entry (entry fee + CCIP fee)
     */
    function getEntryTotalCost() external view returns (
        uint256 entryFee,
        uint256 estimatedCCIPFee, 
        uint256 recommendedTotal,
        string memory message
    ) {
        entryFee = ENTRY_FEE_BONE;
        estimatedCCIPFee = _estimateCCIPFee();
        recommendedTotal = entryFee + ((estimatedCCIPFee * 120) / 100); // 20% buffer for CCIP fee volatility
        message = "Entry fee + cross-chain verification fee (with buffer). Excess will be refunded.";
    }

    /**
     * @dev Estimate CCIP fee for cross-chain message
     */
    function _estimateCCIPFee() internal view returns (uint256) {
        bytes memory data = abi.encode(address(this), ENTRY_FEE_BONE); // Use dummy data for estimation
        
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(ethereumMainContract),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: crossChainGasLimit})
            ),
            feeToken: address(0)
        });
        
        try IRouterClient(getRouter()).getFee(ethereumChainSelector, ccipMessage) returns (uint256 fee) {
            return fee;
        } catch {
            revert CCIPFeeCalculationFailed();
        }
    }

    /**
     * @dev Get user-friendly entry instructions
     */
    function getEntryInstructions() external view returns (
        string memory instructions,
        uint256 minimumRequired,
        uint256 recommendedAmount
    ) {
        uint256 entryFee = ENTRY_FEE_BONE;
        uint256 ccipFee = _estimateCCIPFee();
        
        minimumRequired = entryFee + ccipFee;
        recommendedAmount = entryFee + ((ccipFee * 120) / 100); // 20% buffer
        
        instructions = "Send entry fee (1 BONE) + cross-chain fee (~0.01 BONE). Any unused amount will be refunded automatically.";
    }

    // ===== ENTRY FUNCTIONS =====

    /**
     * @dev Enter lottery with native BONE (user pays entry fee + CCIP fee)
     */
    function enterLottery() external payable nonReentrant whenNotPaused {
        if (hasPendingEntry[msg.sender]) revert AlreadyHasPendingEntry();

        RoundInfo storage round = rounds[currentRoundId];
        if (round.hasEntered[msg.sender]) revert DuplicateEntry();

        // Calculate required amounts
        uint256 entryFee = ENTRY_FEE_BONE;
        uint256 estimatedCCIPFee = _estimateCCIPFee();
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

        // Request NFT verification (using user's BONE for CCIP)
        _requestNFTVerification(msg.sender, ccipBudget);

        emit PendingEntryAdded(msg.sender, msg.value, ccipBudget);
        emit NativeBoneReceived(msg.sender, entryFee); // Only count entry fee as received
    }

    /**
     * @dev Request NFT verification using user-provided CCIP budget
     */
    function _requestNFTVerification(address player, uint256 ccipBudget) internal {
        bytes memory data = abi.encode(player, ENTRY_FEE_BONE);

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(ethereumMainContract),
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: crossChainGasLimit})
            ),
            feeToken: address(0)
        });

        // Get actual CCIP fee
        uint256 actualCCIPFee = IRouterClient(getRouter()).getFee(ethereumChainSelector, ccipMessage);
        
        if (ccipBudget < actualCCIPFee) {
            // Insufficient CCIP budget - refund and reject
            _removePendingEntryWithRefund(player, "Insufficient CCIP fee");
            return;
        }

        try
            IRouterClient(getRouter()).ccipSend{value: actualCCIPFee}(
                ethereumChainSelector, 
                ccipMessage
            )
        returns (bytes32 messageId) {
            emit CrossChainEntryRequested(player, ethereumChainSelector, actualCCIPFee);
            emit CCIPMessageSent(ethereumChainSelector, messageId, actualCCIPFee);
            
            // Refund unused CCIP budget
            uint256 ccipRefund = ccipBudget - actualCCIPFee;
            if (ccipRefund > 0) {
                (bool success,) = payable(player).call{value: ccipRefund}("");
                if (success) {
                    emit CCIPFeeRefunded(player, ccipRefund);
                } else {
                    // If refund fails, allocate to dev
                    pendingWithdrawalsBone[devAddress] += uint128(ccipRefund);
                    emit DevFundsAllocated(ccipRefund);
                }
            }
        } catch {
            _removePendingEntryWithRefund(player, "CCIP message failed");
        }
    }

    // ===== CCIP MESSAGE HANDLING =====

    /**
     * @dev Receive CCIP messages from Ethereum main contract
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        if (abi.decode(message.sender, (address)) != ethereumMainContract) return;

        bytes memory data = message.data;

        // Try different message types
        try this.handleEntryResponse(data) {
            return;
        } catch {}

        try this.handleWinnersNotification(data) {
            return;
        } catch {}

        try this.handleRoundSync(data) {
            return;
        } catch {}
    }

    /**
     * @dev Handle entry verification response from main contract
     */
    function handleEntryResponse(bytes memory data) external {
        require(msg.sender == address(this), "Internal call only");

        (address player, bool approved, string memory reason) = abi.decode(
            data,
            (address, bool, string)
        );

        if (!hasPendingEntry[player]) return;

        if (approved) {
            _confirmPlayerEntry(player);
            emit CrossChainEntryConfirmed(player, currentRoundId);
        } else {
            _removePendingEntry(player, reason);
            emit CrossChainEntryRejected(player, reason);
        }
    }

    /**
     * @dev Handle winners notification from main contract
     */
    function handleWinnersNotification(bytes memory data) external {
        require(msg.sender == address(this), "Internal call only");

        (
            uint256 roundId,
            address[3] memory winners,
            uint256 chainPrizePool
        ) = abi.decode(data, (uint256, address[3], uint256));

        _processRoundWinners(roundId, winners, chainPrizePool);
    }

    /**
     * @dev Handle round synchronization from main contract
     */
    function handleRoundSync(bytes memory data) external {
        require(msg.sender == address(this), "Internal call only");

        uint256 newRoundId = abi.decode(data, (uint256));
        
        if (newRoundId > currentRoundId) {
            currentRoundId = uint128(newRoundId);
            emit ContractSynced(newRoundId);
        }
    }

    // ===== PLAYER MANAGEMENT =====

    /**
     * @dev Confirm player entry
     */
    function _confirmPlayerEntry(address player) internal {
        if (!hasPendingEntry[player]) return;

        RoundInfo storage round = rounds[currentRoundId];

        // Add player
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

    /**
     * @dev Remove pending entry (allocate entry fee to dev, no refund)
     */
    function _removePendingEntry(address player, string memory reason) internal {
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
     * @dev Remove pending entry with full refund (technical failures before CCIP)
     */
    function _removePendingEntryWithRefund(address player, string memory reason) internal {
        if (!hasPendingEntry[player]) return;

        // Calculate total refund (entry fee + unused CCIP fee)
        uint256 totalRefund = ENTRY_FEE_BONE + pendingEntries[player].ccipFeePaid;

        // Try refund
        (bool success,) = payable(player).call{value: totalRefund}("");
        if (!success) {
            // If refund fails, allocate to dev
            unchecked {
                pendingWithdrawalsBone[devAddress] += uint128(totalRefund);
                totalWinningsBone[devAddress] += uint128(totalRefund);
            }
            emit DevFundsAllocated(totalRefund);
        }

        delete pendingEntries[player];
        hasPendingEntry[player] = false;

        emit PlayerRemoved(player, totalRefund, reason);
    }

    /**
     * @dev Process round winners and distribute prizes
     */
    function _processRoundWinners(
        uint256 roundId,
        address[3] memory winners,
        uint256 chainPrizePool
    ) internal {
        RoundInfo storage round = rounds[roundId];
        round.winnersReceived = true;
        round.winners = winners;
        round.totalChainPrizePool = uint128(chainPrizePool);

        _distributePrizes(roundId);
        _burnNativeBone(roundId);

        emit WinnersReceived(roundId, winners, chainPrizePool);
        
        if (roundId == currentRoundId) {
            _startNewRound();
        }
    }

    /**
     * @dev Distribute prizes (matching main contract logic)
     */
    function _distributePrizes(uint256 roundId) internal {
        RoundInfo storage round = rounds[roundId];
        if (!round.winnersReceived || round.localPrizePool == 0) return;

        uint256 totalLocalPrize = round.localPrizePool;
        uint256 winnersTotal = (totalLocalPrize * WINNERS_SHARE) / 100;
        uint256 devAmount = (totalLocalPrize * DEV_SHARE) / 100;
        uint256 fundingTotal = (totalLocalPrize * FUNDING_SHARE) / 100;

        // Distribute winner prizes
        uint256 winnerAmount = winnersTotal / 3;
        for (uint256 i; i < 3;) {
            if (
                round.winners[i] != address(0) &&
                round.hasEntered[round.winners[i]]
            ) {
                unchecked {
                    pendingWithdrawalsBone[round.winners[i]] += uint128(winnerAmount);
                    totalWinningsBone[round.winners[i]] += uint128(winnerAmount);
                }
                emit LocalWinnerPayout(round.winners[i], winnerAmount);
            }
            unchecked { ++i; }
        }

        // Distribute to dev
        unchecked {
            pendingWithdrawalsBone[devAddress] += uint128(devAmount);
            totalWinningsBone[devAddress] += uint128(devAmount);
        }

        // Distribute to funding addresses
        uint256 fundingPerAddress = fundingTotal / 5;
        for (uint256 i; i < 5;) {
            unchecked {
                pendingWithdrawalsBone[fundingAddresses[i]] += uint128(fundingPerAddress);
                totalWinningsBone[fundingAddresses[i]] += uint128(fundingPerAddress);
                ++i;
            }
        }
    }

    /**
     * @dev Burn native BONE
     */
    function _burnNativeBone(uint256 roundId) internal {
        RoundInfo storage round = rounds[roundId];
        uint256 burnAmount = (uint256(round.localPrizePool) * BURN_SHARE) / 100;
        if (burnAmount == 0) return;

        (bool success,) = DEAD_ADDRESS.call{value: burnAmount}("");
        if (success) {
            emit NativeBoneBurned(burnAmount);
        }
    }

    /**
     * @dev Start new round
     */
    function _startNewRound() internal {
        unchecked { ++currentRoundId; }
    }

    /**
     * @dev Withdraw native BONE winnings
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawalsBone[msg.sender];
        if (amount == 0) revert NoWithdrawalAvailable();

        pendingWithdrawalsBone[msg.sender] = 0;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert WithdrawalFailed();

        emit WithdrawalMade(msg.sender, amount);
    }

    // ===== VIEW FUNCTIONS =====

    function getCurrentRoundPlayers() external view returns (address[] memory) {
        return rounds[currentRoundId].localPlayers;
    }

    function getRoundInfo(uint256 roundId) external view returns (
        uint256 playerCount,
        uint256 localPrizePool,
        bool winnersReceived,
        address[3] memory winners,
        uint256 totalChainPrizePool
    ) {
        RoundInfo storage round = rounds[roundId];
        return (
            round.localPlayers.length,
            round.localPrizePool,
            round.winnersReceived,
            round.winners,
            round.totalChainPrizePool
        );
    }

    function getPlayerStats(address player) external view returns (
        uint256 totalWon,
        uint256 participationCount,
        uint256 points,
        uint256 pendingAmount,
        bool hasPending
    ) {
        return (
            totalWinningsBone[player],
            entriesCount[player],
            playerPoints[player],
            pendingWithdrawalsBone[player],
            hasPendingEntry[player]
        );
    }

    function getPendingEntry(address player) external view returns (
        bool exists, 
        uint256 timestamp, 
        uint256 ccipFeePaid,
        bool verified
    ) {
        PendingEntry storage entry = pendingEntries[player];
        return (
            hasPendingEntry[player], 
            entry.timestamp, 
            entry.ccipFeePaid,
            entry.verified
        );
    }

    function hasPlayerEntered(uint256 roundId, address player) external view returns (bool) {
        return rounds[roundId].hasEntered[player];
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getAdmin() public view returns (address) {
        return contractAdmin;
    }

    // ===== ADMIN FUNCTIONS =====

    function changeAdmin(address newAdmin) public onlyAdmin {
        require(newAdmin != address(0), "New admin is the zero address");
        emit AdminChanged(contractAdmin, newAdmin);
        contractAdmin = newAdmin;
    }

    function setEthereumMainContract(address _ethereumMainContract) external onlyAdmin {
        if (_ethereumMainContract == address(0)) revert InvalidZeroAddress();
        emit EthereumContractUpdated(ethereumMainContract, _ethereumMainContract);
        ethereumMainContract = _ethereumMainContract;
    }

    function setCrossChainGasLimit(uint256 gasLimit) external onlyAdmin {
        crossChainGasLimit = uint32(gasLimit);
    }

    function pauseContract() external onlyAdmin { _pause(); }
    function unpauseContract() external onlyAdmin { _unpause(); }

    // ===== EMERGENCY FUNCTIONS =====

    function emergencyResyncPlayer(address player, uint256 roundId, bool shouldAdd) external onlyAdmin {
        if (roundId == 0) roundId = currentRoundId;

        if (shouldAdd) {
            if (hasPendingEntry[player] && !rounds[roundId].hasEntered[player]) {
                _confirmPlayerEntry(player);
                emit EmergencyEntryConfirmed(player, roundId);
            }
        } else {
            if (hasPendingEntry[player]) {
                _removePendingEntry(player, "Rejected manually by admin");
                emit EmergencyEntryRejected(player, "Rejected manually by admin");
            }
        }
    }

    function emergencyClearPendingEntry(address player, string calldata reason) external onlyAdmin {
        if (!hasPendingEntry[player]) return;
        _removePendingEntry(player, reason);
    }

    function emergencyProcessWinners(
        uint256 roundId,
        address[3] calldata winners,
        uint256 chainPrizePool
    ) external onlyAdmin {
        if (roundId == 0) return;
        _processRoundWinners(roundId, winners, chainPrizePool);
    }

    function emergencyWithdrawNativeBone() external onlyAdmin {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success,) = payable(contractAdmin).call{value: balance}("");
            require(success, "Native BONE withdrawal failed");
        }
    }

    function cleanupExpiredEntries(address[] calldata players) external onlyAdmin {
        for (uint256 i; i < players.length;) {
            address player = players[i];
            if (
                hasPendingEntry[player] &&
                block.timestamp > pendingEntries[player].timestamp + 1 hours
            ) {
                _removePendingEntry(player, "Entry expired");
            }
            unchecked { ++i; }
        }
    }

    // ===== RECEIVE FUNCTIONS =====

    receive() external payable {
        emit NativeBoneReceived(msg.sender, msg.value);
    }

    fallback() external payable {
        emit NativeBoneReceived(msg.sender, msg.value);
    }
}