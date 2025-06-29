// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CCIPReceiver} from "@chainlink/contracts/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CrossChainLotteryEntry is CCIPReceiver, ReentrancyGuard, Pausable {
    // ===== MESSAGE TYPES =====
    enum MessageType {
        ENTRY_RESPONSE,
        WINNERS_NOTIFICATION,
        ROUND_SYNC,
        ENTRY_REQUEST
    }

    // ===== ROUND STATE =====
    enum RoundState {
        Active,
        Completed
    }

    // ===== STRUCTS =====
    struct PendingEntry {
        uint64 timestamp;
        uint128 roundId;
        uint128 ccipFeePaid;
        bool verified;
    }

    struct RoundInfo {
        address[] localPlayers;
        address[3] winners;
        uint128 localPrizePool;
        uint128 totalChainPrizePool;
        bool winnersReceived;
        RoundState state;
        mapping(address => bool) hasEntered;
        mapping(address => uint32) playerIndex;
        mapping(uint64 => uint128) chainContributions;
        uint64[] contributingChains;
        uint128 mainChainContribution;
    }

    // ===== CONSTANTS =====
    uint256 public entryFeeBone = 100 ether;
    uint8 public constant MAX_PLAYERS = 10;
    uint8 public constant POINTS_PER_ENTRY = 5;
    uint8 public constant WINNERS_SHARE = 60;
    uint8 public constant DEV_SHARE = 5;
    uint8 public constant FUNDING_SHARE = 35;
    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    uint256 public maxCCIPFee = 1000 ether;
    uint256 public ccipFeeBufferPercent = 150;
    uint256 public constant ENTRY_EXPIRY_TIME = 1 hours;
    uint256 public constant EMERGENCY_TIMELOCK = 24 hours;
    uint256 public constant MAX_CLEANUP_BATCH = 100;

    // ===== IMMUTABLE VARIABLES =====
    uint64 public immutable ethereumChainSelector;
    uint64 public immutable currentChainSelector;
    address payable public immutable devAddress;

    // ===== STATE VARIABLES =====
    address public contractAdmin;
    address public ethereumMainContract;
    mapping(address => bool) public authorizedCCIPSenders;
    address[] public pendingPlayers;

    uint128 public currentRoundId;
    uint32 public crossChainGasLimit = 500000;

    uint256 public emergencyWithdrawalTimestamp;
    bool public emergencyWithdrawalRequested;

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
    event CCIPMessageSent(
        uint64 indexed destinationChain,
        bytes32 indexed messageId,
        uint256 feePaid
    );
    event CCIPFeeRefunded(address indexed player, uint256 amount);
    event RefundStored(address indexed player, uint256 amount);
    event EntryFeeUpdated(uint256 oldFee, uint256 newFee);
    event WithdrawalMade(address indexed recipient, uint256 amount);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event RoundCompleted(uint256 indexed roundId, address[3] winners);
    event NewRound(uint256 indexed roundId);
    event EntryAccepted(address indexed player, uint256 roundId);
    event EntryRejected(address indexed player, uint256 roundId, string reason);
    event RoundMigration(
        address indexed player,
        uint256 fromRound,
        uint256 toRound
    );

    // ===== CUSTOM ERRORS =====
    error OnlyAdmin();
    error InvalidZeroAddress();
    error DuplicateEntry();
    error AlreadyHasPendingEntry();
    error NoWithdrawalAvailable();
    error WithdrawalFailed();
    error CCIPFeeCalculationFailed();
    error InsufficientCCIPFee();
    error ArrayTooLarge();
    error GasLimitOutOfBounds();
    error EmergencyNotRequested();
    error TimelockNotExpired();
    error InvalidFundingAddress();
    error RoundNotActive();

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

    modifier onlyActiveRound() {
        if (rounds[currentRoundId].state != RoundState.Active)
            revert RoundNotActive();
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

        // Initialize first round as active
        rounds[1].state = RoundState.Active;

        authorizedCCIPSenders[_ethereumMainContract] = true;
    }

    // ===== ENTRY FUNCTIONS =====
    function enterLottery()
        external
        payable
        nonReentrant
        whenNotPaused
        onlyActiveRound
        validFundingAddresses
    {
        if (hasPendingEntry[msg.sender]) revert AlreadyHasPendingEntry();

        RoundInfo storage round = rounds[currentRoundId];
        if (round.hasEntered[msg.sender]) revert DuplicateEntry();

        uint256 entryFee = entryFeeBone;
        uint256 estimatedCCIPFee;

        try this.estimateCCIPFee() returns (uint256 fee) {
            estimatedCCIPFee = fee > maxCCIPFee ? maxCCIPFee : fee;
        } catch {
            revert CCIPFeeCalculationFailed();
        }

        uint256 minimumRequired = entryFee + estimatedCCIPFee;
        if (msg.value < minimumRequired) {
            revert InsufficientCCIPFee();
        }

        uint256 ccipBudget = msg.value - entryFee;

        // Add entry fee to prize pool immediately
        round.localPrizePool += uint128(entryFee);
        round.hasEntered[msg.sender] = true;
        round.localPlayers.push(msg.sender);

        // Update player stats immediately
        entriesCount[msg.sender]++;
        playerPoints[msg.sender] += POINTS_PER_ENTRY;

        pendingEntries[msg.sender] = PendingEntry({
            timestamp: uint64(block.timestamp),
            roundId: currentRoundId,
            ccipFeePaid: uint128(ccipBudget),
            verified: false
        });
        hasPendingEntry[msg.sender] = true;
        pendingPlayers.push(msg.sender);

        _requestNFTVerification(msg.sender, ccipBudget);
    }

    function _requestNFTVerification(
        address player,
        uint256 ccipBudget
    ) internal {
        bytes memory data = abi.encode(
            uint8(MessageType.ENTRY_REQUEST),
            currentRoundId,
            player,
            entryFeeBone
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
            emit CCIPMessageSent(
                ethereumChainSelector,
                messageId,
                actualCCIPFee
            );

            uint256 ccipRefund = ccipBudget - actualCCIPFee;
            if (ccipRefund > 0) {
                (bool success, ) = payable(player).call{
                    value: ccipRefund,
                    gas: 10000
                }("");
                if (success) {
                    emit CCIPFeeRefunded(player, ccipRefund);
                } else {
                    pendingWithdrawalsBone[player] += uint128(ccipRefund);
                    emit RefundStored(player, ccipRefund);
                }
            }
        } catch {
            _removePendingEntryWithRefund(player, "CCIP message failed");
        }
    }

    // ===== CCIP MESSAGE HANDLING =====
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
            uint256 roundId,
            address player,
            bool accepted,
            string memory reason
        ) = abi.decode(data, (uint8, uint256, address, bool, string));

        if (!hasPendingEntry[player]) return;

        PendingEntry storage entry = pendingEntries[player];
        // Don't check roundId match here - we'll handle it with Option 3

        if (accepted) {
            // OPTION 3: If entry approved, sync to latest round from main contract
            if (roundId > currentRoundId) {
                _syncToRound(roundId);
            }

            // Now process the accepted entry
            entry.verified = true;
            emit EntryAccepted(player, roundId);

            // Refund excess CCIP fee
            uint256 ccipRefund = entry.ccipFeePaid;
            if (ccipRefund > 0) {
                (bool success, ) = payable(player).call{
                    value: ccipRefund,
                    gas: 10000
                }("");
                if (!success) {
                    pendingWithdrawalsBone[player] += uint128(ccipRefund);
                    emit RefundStored(player, ccipRefund);
                } else {
                    emit CCIPFeeRefunded(player, ccipRefund);
                }
            }

            // Update the player's entry to be in the correct round
            // If they entered round 1 but got accepted into round 2, update their local state
            RoundInfo storage oldRound = rounds[entry.roundId];
            RoundInfo storage newRound = rounds[roundId];

            // If the rounds are different, move the player's local entry
            if (entry.roundId != roundId) {
                emit RoundMigration(player, entry.roundId, roundId);

                // Remove from old round
                if (oldRound.hasEntered[player]) {
                    oldRound.hasEntered[player] = false;
                    oldRound.localPrizePool -= uint128(entryFeeBone);

                    // Remove from old round players array
                    for (uint256 i = 0; i < oldRound.localPlayers.length; i++) {
                        if (oldRound.localPlayers[i] == player) {
                            oldRound.localPlayers[i] = oldRound.localPlayers[
                                oldRound.localPlayers.length - 1
                            ];
                            oldRound.localPlayers.pop();
                            break;
                        }
                    }
                }

                // Add to new round (if not already there)
                if (!newRound.hasEntered[player]) {
                    newRound.hasEntered[player] = true;
                    newRound.localPlayers.push(player);
                    newRound.localPrizePool += uint128(entryFeeBone);
                }
            }
        } else {
            // Entry was rejected - full refund (same as before)
            emit EntryRejected(player, roundId, reason);
            _removePendingEntryWithRefund(player, reason);

            // Remove from round since entry was rejected
            RoundInfo storage round = rounds[entry.roundId];
            if (round.hasEntered[player]) {
                round.hasEntered[player] = false;
                round.localPrizePool -= uint128(entryFeeBone);

                // Remove from players array
                for (uint256 i = 0; i < round.localPlayers.length; i++) {
                    if (round.localPlayers[i] == player) {
                        round.localPlayers[i] = round.localPlayers[
                            round.localPlayers.length - 1
                        ];
                        round.localPlayers.pop();
                        break;
                    }
                }

                // Revert player stats
                if (entriesCount[player] > 0) {
                    entriesCount[player]--;
                    if (playerPoints[player] >= POINTS_PER_ENTRY) {
                        playerPoints[player] -= POINTS_PER_ENTRY;
                    }
                }
            }
        }

        // Clean up pending entry
        delete pendingEntries[player];
        hasPendingEntry[player] = false;

        // Remove from pending players array
        for (uint256 i = 0; i < pendingPlayers.length; i++) {
            if (pendingPlayers[i] == player) {
                pendingPlayers[i] = pendingPlayers[pendingPlayers.length - 1];
                pendingPlayers.pop();
                break;
            }
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

        // Complete current round if not already completed
        rounds[currentRoundId].state = RoundState.Completed;

        currentRoundId = uint128(newRoundId);
        rounds[currentRoundId].state = RoundState.Active;

        emit NewRound(currentRoundId);
    }

    // ===== PLAYER MANAGEMENT =====
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
        round.state = RoundState.Completed; // Mark round as completed

        for (uint256 i = 0; i < chains.length; i++) {
            round.chainContributions[chains[i]] = contributions[i];
            round.contributingChains.push(chains[i]);
        }

        _cleanupPendingEntries(roundId);
        _distributePrizesProportionally(roundId);

        emit RoundCompleted(roundId, winners);

        // Always advance to next round when winners are received
        // The main contract has already moved to the next round
        if (roundId >= currentRoundId) {
            currentRoundId = uint128(roundId + 1);
            // Initialize new round as active
            rounds[currentRoundId].state = RoundState.Active;
            emit NewRound(currentRoundId);
        }
    }

    function _cleanupPendingEntries(uint256 roundId) internal {
        uint256 i = 0;
        while (i < pendingPlayers.length) {
            address player = pendingPlayers[i];

            if (
                !hasPendingEntry[player] ||
                pendingEntries[player].roundId != roundId
            ) {
                i++;
                continue;
            }

            // Mark entry as verified (all entries are considered valid)
            pendingEntries[player].verified = true;

            // Refund excess CCIP fee to player
            uint256 ccipRefund = pendingEntries[player].ccipFeePaid;
            if (ccipRefund > 0) {
                (bool success, ) = payable(player).call{value: ccipRefund}("");
                if (!success) {
                    pendingWithdrawalsBone[player] += uint128(ccipRefund);
                }
            }

            delete pendingEntries[player];
            hasPendingEntry[player] = false;
            _removePendingPlayerFromArray(i);
        }
    }

    function _removePendingPlayerFromArray(uint256 index) internal {
        pendingPlayers[index] = pendingPlayers[pendingPlayers.length - 1];
        pendingPlayers.pop();
    }

    function _distributePrizesProportionally(uint256 roundId) internal {
        RoundInfo storage round = rounds[roundId];
        if (!round.winnersReceived || round.localPrizePool == 0) return;

        uint256 localContribution = round.localPrizePool;
        uint256 localWinnersShare = (localContribution * WINNERS_SHARE) / 100;
        uint256 localDevShare = (localContribution * DEV_SHARE) / 100;
        uint256 localFundingShare = (localContribution * FUNDING_SHARE) / 100;

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
            }
        }

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
    }

    function _removePendingEntryWithRefund(
        address player,
        string memory reason
    ) internal {
        if (!hasPendingEntry[player]) return;

        uint256 totalRefund = entryFeeBone + pendingEntries[player].ccipFeePaid;

        pendingWithdrawalsBone[player] += uint128(totalRefund);
        emit RefundStored(player, totalRefund);

        delete pendingEntries[player];
        hasPendingEntry[player] = false;
    }

    // ===== WITHDRAWAL =====
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawalsBone[msg.sender];
        if (amount == 0) revert NoWithdrawalAvailable();

        pendingWithdrawalsBone[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount, gas: 10000}(
            ""
        );
        if (!success) {
            pendingWithdrawalsBone[msg.sender] = uint128(amount);
            revert WithdrawalFailed();
        }

        emit WithdrawalMade(msg.sender, amount);
    }

    // ===== VIEW FUNCTIONS =====
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
        entryFee = entryFeeBone;

        try this.estimateCCIPFee() returns (uint256 fee) {
            estimatedCCIPFee = fee;
            if (estimatedCCIPFee > maxCCIPFee) {
                estimatedCCIPFee = maxCCIPFee;
            }
        } catch {
            estimatedCCIPFee = 10 ether;
        }

        recommendedTotal =
            entryFee +
            ((estimatedCCIPFee * ccipFeeBufferPercent) / 100);
        message = "Entry fee + cross-chain fee. Excess BONE will be refunded.";
    }

    function estimateCCIPFee() external view returns (uint256) {
        bytes memory data = abi.encode(
            uint8(MessageType.ENTRY_REQUEST),
            currentRoundId,
            address(this),
            entryFeeBone
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
            uint256 totalChainPrizePool,
            RoundState state
        )
    {
        RoundInfo storage round = rounds[roundId];
        return (
            round.localPlayers.length,
            round.localPrizePool,
            round.winnersReceived,
            round.winners,
            round.totalChainPrizePool,
            round.state
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

    function getPendingPlayers() external view returns (address[] memory) {
        return pendingPlayers;
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getCurrentRoundState() external view returns (RoundState) {
        return rounds[currentRoundId].state;
    }

    // ===== ADMIN FUNCTIONS =====
    function setEntryFee(uint256 newEntryFee) external onlyAdmin {
        require(newEntryFee > 0, "Entry fee must be positive");
        require(newEntryFee <= 1000 ether, "Entry fee too high");

        uint256 oldFee = entryFeeBone;
        entryFeeBone = newEntryFee;

        emit EntryFeeUpdated(oldFee, newEntryFee);
    }

    function changeAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidZeroAddress();
        emit AdminChanged(contractAdmin, newAdmin);
        contractAdmin = newAdmin;
    }

    function setEthereumMainContract(
        address _ethereumMainContract
    ) external onlyAdmin {
        if (_ethereumMainContract == address(0)) revert InvalidZeroAddress();

        authorizedCCIPSenders[ethereumMainContract] = false;
        ethereumMainContract = _ethereumMainContract;
        authorizedCCIPSenders[_ethereumMainContract] = true;
    }

    function setCrossChainGasLimit(uint256 gasLimit) external onlyAdmin {
        crossChainGasLimit = uint32(gasLimit);
    }

    function setMaxCCIPFee(uint256 newMaxFee) external onlyAdmin {
        maxCCIPFee = newMaxFee;
    }

    function setCCIPFeeBuffer(uint256 newBufferPercent) external onlyAdmin {
        ccipFeeBufferPercent = newBufferPercent;
    }

    function updateFundingAddresses(
        address payable[5] calldata newFundingAddresses
    ) external onlyAdmin {
        for (uint256 i = 0; i < 5; i++) {
            if (newFundingAddresses[i] == address(0))
                revert InvalidFundingAddress();
        }
        fundingAddresses = newFundingAddresses;
    }

    function pauseContract() external onlyAdmin {
        _pause();
    }

    function unpauseContract() external onlyAdmin {
        _unpause();
    }

    function forceRoundSync(uint256 newRoundId) external onlyAdmin {
        if (newRoundId > currentRoundId) {
            _syncToRound(newRoundId);
        }
    }

    function cleanupExpiredEntries(
        address[] calldata players
    ) external onlyAdmin {
        if (players.length > MAX_CLEANUP_BATCH) revert ArrayTooLarge();

        for (uint256 i; i < players.length; ) {
            address player = players[i];
            if (
                hasPendingEntry[player] &&
                block.timestamp >
                pendingEntries[player].timestamp + ENTRY_EXPIRY_TIME
            ) {
                uint256 ccipRefund = pendingEntries[player].ccipFeePaid;
                pendingWithdrawalsBone[devAddress] += uint128(entryFeeBone);

                if (ccipRefund > 0) {
                    pendingWithdrawalsBone[player] += uint128(ccipRefund);
                }

                delete pendingEntries[player];
                hasPendingEntry[player] = false;
            }
            unchecked {
                ++i;
            }
        }
    }

    function recoverStuckFunds(
        address token,
        uint256 amount
    ) external onlyAdmin {
        if (token == address(0)) {
            require(amount <= address(this).balance, "Amount exceeds balance");
            (bool success, ) = payable(contractAdmin).call{value: amount}("");
            require(success, "Recovery failed");
        } else {
            IERC20(token).transfer(contractAdmin, amount);
        }
    }

    function requestEmergencyWithdrawal() external onlyAdmin {
        emergencyWithdrawalTimestamp = block.timestamp + EMERGENCY_TIMELOCK;
        emergencyWithdrawalRequested = true;
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
    }

    receive() external payable {}

    fallback() external payable {}
}
