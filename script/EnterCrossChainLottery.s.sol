// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CrossChainLotteryEntry} from "../src/CrossChainLotteryEntry.sol";

contract EnterCrossChainLottery is Script {
    // Contract addresses - Your deployed contract
    address payable constant CROSS_CHAIN_CONTRACT = payable(0xc81093DaB394729bD5432351cfa0e5a33C8EA367);
    
    function run() external {
        uint256 playerPrivateKey = vm.envUint("ENTER_PRIVATE_KEY");
        address player = vm.addr(playerPrivateKey);
        
        console.log("=== Cross-Chain Lottery Entry ===");
        console.log("Player address:", player);
        console.log("Player balance:", player.balance);
        console.log("Cross-chain contract:", CROSS_CHAIN_CONTRACT);
        
        require(CROSS_CHAIN_CONTRACT != address(0), "UPDATE CROSS_CHAIN_CONTRACT ADDRESS IN SCRIPT");
        require(player.balance > 0, "Player has no balance");
        
        CrossChainLotteryEntry crossChainLottery = CrossChainLotteryEntry(CROSS_CHAIN_CONTRACT);
        
        // Check if player already has pending entry
        (
            bool hasPending,
            uint256 timestamp,
            uint256 ccipFeePaid,
            bool verified
        ) = crossChainLottery.getPendingEntry(player);
        
        if (hasPending) {
            console.log("WARNING: Player already has pending entry!");
            console.log("Entry timestamp:", timestamp);
            console.log("CCIP fee paid:", ccipFeePaid);
            console.log("Verified:", verified);
            console.log("Wait for verification or use emergency admin functions");
            return;
        }
        
        // Get entry cost information
        (
            uint256 entryFee,
            uint256 estimatedCCIPFee,
            uint256 recommendedTotal,
            string memory message
        ) = crossChainLottery.getEntryTotalCost();
        
        console.log("=== Entry Cost Information ===");
        console.log("Entry fee (BONE):", entryFee);
        console.log("Estimated CCIP fee:", estimatedCCIPFee);
        console.log("Recommended total:", recommendedTotal);
        console.log("Message:", message);
        
        // Check if player has enough balance
        if (player.balance < recommendedTotal) {
            console.log("ERROR: Insufficient balance!");
            console.log("Required:", recommendedTotal);
            console.log("Available:", player.balance);
            console.log("Shortfall:", recommendedTotal - player.balance);
            return;
        }
        
        // Get current round info
        (
            uint256 playerCount,
            uint256 localPrizePool,
            bool winnersReceived,
            address[3] memory winners,
            uint256 totalChainPrizePool
        ) = crossChainLottery.getRoundInfo(crossChainLottery.currentRoundId());
        
        console.log("=== Current Round Info ===");
        console.log("Current round ID:", crossChainLottery.currentRoundId());
        console.log("Local players:", playerCount);
        console.log("Local prize pool:", localPrizePool);
        console.log("Winners received:", winnersReceived);
        console.log("Total chain prize pool:", totalChainPrizePool);
        
        // Check contract balance for CCIP responses
        uint256 contractBalance = crossChainLottery.getContractBalance();
        console.log("Contract balance (for CCIP):", contractBalance);
        
        vm.startBroadcast(playerPrivateKey);
        
        console.log("=== Entering Cross-Chain Lottery ===");
        console.log("Sending:", recommendedTotal, "wei");
        console.log("Entry fee portion:", entryFee);
        console.log("CCIP fee portion:", estimatedCCIPFee);
        
        try crossChainLottery.enterLottery{value: recommendedTotal}() {
            console.log("SUCCESS: Entry request sent!");
            console.log("Transaction submitted to cross-chain verification");
            console.log("Wait for CCIP response from main contract");
        } catch Error(string memory reason) {
            console.log("FAILED: Entry rejected");
            console.log("Reason:", reason);
        } catch {
            console.log("FAILED: Unknown error during entry");
        }
        
        vm.stopBroadcast();
        
        // Check if entry was added to pending
        (
            bool nowHasPending,
            uint256 newTimestamp,
            uint256 newCcipFeePaid,
            bool nowVerified
        ) = crossChainLottery.getPendingEntry(player);
        
        if (nowHasPending) {
            console.log("=== Entry Added to Pending Queue ===");
            console.log("Entry timestamp:", newTimestamp);
            console.log("CCIP fee paid:", newCcipFeePaid);
            console.log("Awaiting verification from main contract...");
            
            console.log("=== Next Steps ===");
            console.log("1. Wait for CCIP response from Ethereum main contract");
            console.log("2. Check status with: cast call", CROSS_CHAIN_CONTRACT, "getPendingEntry(address)(bool,uint256,uint256,bool)", player);
            console.log("3. If approved, you'll be added to the current round");
            console.log("4. If rejected, entry fee will be allocated to dev fund");
        } else {
            console.log("WARNING: Entry not found in pending queue");
            console.log("Transaction may have failed or been reverted");
        }
        
        console.log("=== Monitoring Commands ===");
        console.log("Check pending entry:");
        console.log("cast call", CROSS_CHAIN_CONTRACT, "getPendingEntry(address)(bool,uint256,uint256,bool)", player);
        console.log("Check current round:");
        console.log("cast call", CROSS_CHAIN_CONTRACT, "getCurrentRoundPlayers()");
        console.log("Check player stats:");
        console.log("cast call", CROSS_CHAIN_CONTRACT, "getPlayerStats(address)(uint256,uint256,uint256,uint256,bool)", player);
    }
}

/**
 * @title Check Cross-Chain Lottery Status
 * @dev Script to check current status without making transactions
 */
contract CheckCrossChainStatus is Script {
    function run() external view {
        address payable CROSS_CHAIN_CONTRACT = payable(vm.envAddress("CROSS_CHAIN_CONTRACT"));
        address PLAYER_ADDRESS = vm.envAddress("PLAYER_ADDRESS");
        
        require(CROSS_CHAIN_CONTRACT != address(0), "Set CROSS_CHAIN_CONTRACT env var");
        require(PLAYER_ADDRESS != address(0), "Set PLAYER_ADDRESS env var");
        
        CrossChainLotteryEntry crossChainLottery = CrossChainLotteryEntry(CROSS_CHAIN_CONTRACT);
        
        console.log("=== Cross-Chain Lottery Status ===");
        console.log("Contract:", CROSS_CHAIN_CONTRACT);
        console.log("Player:", PLAYER_ADDRESS);
        console.log("Current round:", crossChainLottery.currentRoundId());
        
        // Check pending entry
        (
            bool hasPending,
            uint256 timestamp,
            uint256 ccipFeePaid,
            bool verified
        ) = crossChainLottery.getPendingEntry(PLAYER_ADDRESS);
        
        console.log("=== Pending Entry Status ===");
        console.log("Has pending entry:", hasPending);
        if (hasPending) {
            console.log("Entry timestamp:", timestamp);
            console.log("CCIP fee paid:", ccipFeePaid);
            console.log("Verified:", verified);
            console.log("Time elapsed:", block.timestamp - timestamp, "seconds");
        }
        
        // Check player stats
        (
            uint256 totalWon,
            uint256 participationCount,
            uint256 points,
            uint256 pendingAmount,
            bool hasPendingEntry
        ) = crossChainLottery.getPlayerStats(PLAYER_ADDRESS);
        
        console.log("=== Player Statistics ===");
        console.log("Total won:", totalWon);
        console.log("Participation count:", participationCount);
        console.log("Points:", points);
        console.log("Pending withdrawal:", pendingAmount);
        console.log("Has pending entry:", hasPendingEntry);
        
        // Check current round
        (
            uint256 playerCount,
            uint256 localPrizePool,
            bool winnersReceived,
            address[3] memory winners,
            uint256 totalChainPrizePool
        ) = crossChainLottery.getRoundInfo(crossChainLottery.currentRoundId());
        
        console.log("=== Current Round ===");
        console.log("Local players:", playerCount);
        console.log("Local prize pool:", localPrizePool);
        console.log("Winners received:", winnersReceived);
        console.log("Total chain prize pool:", totalChainPrizePool);
        
        if (winnersReceived) {
            console.log("=== Winners ===");
            for (uint256 i = 0; i < 3; i++) {
                if (winners[i] != address(0)) {
                    console.log("Winner", i + 1, ":", winners[i]);
                }
            }
        }
        
        // Check if player is in current round
        address[] memory currentPlayers = crossChainLottery.getCurrentRoundPlayers();
        bool playerInRound = false;
        for (uint256 i = 0; i < currentPlayers.length; i++) {
            if (currentPlayers[i] == PLAYER_ADDRESS) {
                playerInRound = true;
                console.log("Player is in current round at position:", i);
                break;
            }
        }
        
        if (!playerInRound && !hasPending) {
            console.log("Player is NOT in current round and has no pending entry");
        }
        
        // Check entry costs
        (
            uint256 entryFee,
            uint256 estimatedCCIPFee,
            uint256 recommendedTotal,
            string memory message
        ) = crossChainLottery.getEntryTotalCost();
        
        console.log("=== Entry Costs ===");
        console.log("Entry fee:", entryFee);
        console.log("Estimated CCIP fee:", estimatedCCIPFee);
        console.log("Recommended total:", recommendedTotal);
        console.log("Message:", message);
        
        console.log("=== Contract Info ===");
        console.log("Contract balance:", crossChainLottery.getContractBalance());
        console.log("Admin:", crossChainLottery.getAdmin());
    }
}

/**
 * @title Withdraw Cross-Chain Winnings
 * @dev Script to withdraw pending winnings
 */
contract WithdrawCrossChain is Script {
    function run() external {
        address payable CROSS_CHAIN_CONTRACT = payable(vm.envAddress("CROSS_CHAIN_CONTRACT"));
        uint256 playerPrivateKey = vm.envUint("ENTER_PRIVATE_KEY");
        address player = vm.addr(playerPrivateKey);
        
        require(CROSS_CHAIN_CONTRACT != address(0), "Set CROSS_CHAIN_CONTRACT env var");
        
        CrossChainLotteryEntry crossChainLottery = CrossChainLotteryEntry(CROSS_CHAIN_CONTRACT);
        
        // Check pending withdrawal amount
        (
            uint256 totalWon,
            uint256 participationCount,
            uint256 points,
            uint256 pendingAmount,
            bool hasPendingEntry
        ) = crossChainLottery.getPlayerStats(player);
        
        console.log("=== Withdrawal Status ===");
        console.log("Player:", player);
        console.log("Pending withdrawal:", pendingAmount);
        console.log("Total historical winnings:", totalWon);
        
        if (pendingAmount == 0) {
            console.log("No pending withdrawal available");
            return;
        }
        
        console.log("Player balance before:", player.balance);
        
        vm.startBroadcast(playerPrivateKey);
        
        try crossChainLottery.withdraw() {
            console.log("SUCCESS: Withdrawal completed!");
            console.log("Withdrawn amount:", pendingAmount);
        } catch Error(string memory reason) {
            console.log("FAILED: Withdrawal rejected");
            console.log("Reason:", reason);
        } catch {
            console.log("FAILED: Unknown error during withdrawal");
        }
        
        vm.stopBroadcast();
        
        console.log("Player balance after:", player.balance);
        
        // Verify withdrawal
        (, , , uint256 newPendingAmount, ) = crossChainLottery.getPlayerStats(player);
        console.log("Remaining pending withdrawal:", newPendingAmount);
    }
}