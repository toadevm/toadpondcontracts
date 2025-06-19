// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VRFLottery} from "../src/VRFLottery.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract EnterWithETH is Script {
    // Your deployed contract address - UPDATE THIS to your actual contract
    address payable constant LOTTERY_CONTRACT = payable(0xFC693f60FE0781CCB0Fe07f681381B78a022986a);
    
    function run() external {
        // Get private key from environment
        uint256 privateKey = vm.envUint("ENTER_PRIVATE_KEY_3");
        
        // Start broadcasting transactions
        vm.startBroadcast(privateKey);
        
        // Get the lottery contract instance
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        
        // Get sender address
        address sender = vm.addr(privateKey);
        console.log("=== WALLET INFO ===");
        console.log("Sender address:", sender);
        
        // Track wallet balance BEFORE any operations
        uint256 walletBalanceBefore = sender.balance;
        console.log("Wallet ETH balance BEFORE entry:", walletBalanceBefore);
        
        // Check NFT ownership requirement
        address nftContract = address(lottery.nftContract());
        console.log("NFT contract address:", nftContract);
        
        IERC721 nft = IERC721(nftContract);
        uint256 nftBalance = nft.balanceOf(sender);
        console.log("Sender NFT balance:", nftBalance);
        
        require(nftBalance > 0, "Must own at least 1 NFT to enter lottery");
        
        // Check round info
        (
            uint256 currentPlayerCount,
            VRFLottery.RoundState roundState,
            ,
            ,
        ) = lottery.getRoundInfo(lottery.currentRoundId());
        
        console.log("=== ROUND INFO ===");
        console.log("Current round ID:", lottery.currentRoundId());
        console.log("Round state (0=Active, 1=Full, 2=VRFRequested, 3=WinnersSelected, 4=PrizesDistributed, 5=Completed):", uint256(roundState));
        console.log("Current players in round:", currentPlayerCount);
        console.log("Max players allowed:", lottery.MAX_PLAYERS());
        
        require(roundState == VRFLottery.RoundState.Active, "Current round is not active");
        require(currentPlayerCount < lottery.MAX_PLAYERS(), "Round is full");
        
        // === USE CONTRACT'S AUTOMATIC PRICING SYSTEM ===
        
        // // Check if ETH entry is available
        // (bool ethEntryAvailable, string memory ethStatus) = lottery.canEnterWithETH();
        // console.log("=== ETH ENTRY STATUS ===");
        // console.log("ETH entry available:", ethEntryAvailable);
        // console.log("ETH entry status:", ethStatus);
        
        // if (!ethEntryAvailable) {
        //     console.log("ETH entry not available - please use BONE tokens instead");
        //     revert("ETH entry not available");
        // }
        
        // Get the contract's calculated optimal ETH amount
        (
            uint256 optimalAmount,
            bool optimalAvailable,
            string memory optimalMessage
        ) = lottery.getOptimalETHAmount();
        
        console.log("=== CONTRACT'S AUTOMATIC PRICING ===");
        console.log("Optimal ETH amount:", optimalAmount);
        console.log("Optimal available:", optimalAvailable);
        console.log("Message:", optimalMessage);
        
        require(optimalAvailable, "Contract cannot calculate optimal ETH amount");
        require(optimalAmount > 0, "Invalid optimal amount calculated");
        
        // Get pool price info for debugging
        // (
        //     uint160 sqrtPriceX96,
        //     uint256 bonePerEth,
        //     uint256 ethNeededForEntry,
        //     bool poolExists
        // ) = lottery.getPoolPriceInfo();
        
        // console.log("=== POOL PRICE INFO ===");
        // console.log("Pool exists:", poolExists);
        // console.log("SqrtPriceX96:", sqrtPriceX96);
        // console.log("BONE per ETH:", bonePerEth);
        // console.log("ETH needed for entry (legacy calc):", ethNeededForEntry);
        
        // Safety check - use the contract's optimal amount
        uint256 ethToSend = optimalAmount;
        
        // Add a small safety buffer (5%) in case of price movement between calls
        ethToSend = (ethToSend * 105) / 100;
        
        // Cap at reasonable maximum
        if (ethToSend > 3 ether) {
            ethToSend = 3 ether;
            console.log("Capped ETH amount to 3 ETH for safety");
        }
        
        console.log("=== TRANSACTION PREPARATION ===");
        console.log("Final ETH amount to send:", ethToSend);
        console.log("(This includes 5% safety buffer)");
        
        require(walletBalanceBefore >= ethToSend, "Insufficient ETH balance");
        
        // Get entry fee in BONE for reference
        uint256 entryFeeBone = lottery.ENTRY_FEE_BONE();
        console.log("Entry fee (BONE):", entryFeeBone);
        
        // === DETAILED BALANCE TRACKING ===
        console.log("=== PRE-TRANSACTION BALANCE TRACKING ===");
        console.log("Wallet balance before transaction:", walletBalanceBefore);
        console.log("ETH being sent to contract:", ethToSend);
        console.log("Expected wallet balance after send (before refund):", walletBalanceBefore - ethToSend);
        
        // Enter the lottery with ETH using contract's automatic system
        console.log("=== ENTERING LOTTERY ===");
        console.log("Calling enterWithETH() with amount:", ethToSend);
        console.log("Contract will automatically:");
        console.log("1. Calculate exact ETH needed");
        console.log("2. Perform swap for exactly 1 BONE");
        console.log("3. Refund unused ETH");
        console.log("4. Add you to lottery");
        
        try lottery.enterWithETH{value: ethToSend}() {
            // Get wallet balance immediately after transaction
            uint256 walletBalanceAfter = sender.balance;
            
            // Calculate the actual ETH spent from wallet perspective
            uint256 actualETHSpentFromWallet = walletBalanceBefore - walletBalanceAfter;
            uint256 ethRefundedToWallet = ethToSend - actualETHSpentFromWallet;
            
            console.log("=== POST-TRANSACTION BALANCE ANALYSIS ===");
            console.log("SUCCESS: Entered lottery with ETH!");
            console.log("");
            console.log("WALLET BALANCE TRACKING:");
            console.log("- Wallet balance BEFORE:", walletBalanceBefore);
            console.log("- Wallet balance AFTER: ", walletBalanceAfter);
            console.log("- ETH sent to contract:  ", ethToSend);
            console.log("- Actual ETH spent:      ", actualETHSpentFromWallet);
            console.log("- ETH refunded to wallet:", ethRefundedToWallet);
            console.log("");
            
            // Calculate percentages for better understanding
            uint256 refundPercentage = (ethRefundedToWallet * 100) / ethToSend;
            uint256 usedPercentage = (actualETHSpentFromWallet * 100) / ethToSend;
            
            console.log("EFFICIENCY METRICS:");
            console.log("- Percentage of ETH actually used:", usedPercentage, "%");
            console.log("- Percentage of ETH refunded:    ", refundPercentage, "%");
            console.log("");
            
            // Validate refund logic
            if (ethRefundedToWallet > 0) {
                console.log(" REFUND SUCCESSFUL: Contract properly refunded unused ETH");
                console.log("   Refund amount:", ethRefundedToWallet, "wei");
                console.log("   Refund amount (ETH):", ethRefundedToWallet / 1e18, "ETH");
            } else if (ethRefundedToWallet == 0) {
                console.log(" NO REFUND: Contract used exactly the amount sent (unlikely but possible)");
            } else {
                console.log(" REFUND ERROR: Negative refund detected - this should not happen!");
            }
            
            // Additional validation - check if we spent more than expected
            if (actualETHSpentFromWallet > ethToSend) {
                console.log(" ERROR: Spent more ETH than sent - this indicates a serious problem!");
            } else {
                console.log(" VALIDATION: ETH spent is within expected range");
            }
            
            // Get updated round info
            (
                uint256 newPlayerCount,
                VRFLottery.RoundState newRoundState,
                ,
                uint256 newPrizePool,
            ) = lottery.getRoundInfo(lottery.currentRoundId());
            
            console.log("=== UPDATED ROUND INFO ===");
            console.log("Players in round:", newPlayerCount);
            console.log("Round state:", uint256(newRoundState));
            console.log("Total prize pool (BONE):", newPrizePool);
            
            // Check if round is now full
            if (newPlayerCount == lottery.MAX_PLAYERS()) {
                console.log("*** ROUND IS NOW FULL! ***");
                console.log("You can now call requestRandomWords() to trigger VRF!");
                console.log("NOTE: Contract needs LINK tokens for VRF to work!");
            }
            
            // Display player stats
            uint32 totalEntries = lottery.entriesCount(sender);
            uint32 playerPoints = lottery.playerPoints(sender);
            console.log("=== YOUR STATS ===");
            console.log("Total entries:", totalEntries);
            console.log("Player points:", playerPoints);
            
            // Final summary
            console.log("=== FINAL SUMMARY ===");
            console.log("Entry completed successfully!");
            console.log("Total ETH cost:", actualETHSpentFromWallet);
            console.log("ETH savings from refund:", ethRefundedToWallet);
            console.log("Wallet balance remaining:", walletBalanceAfter);
            
        } catch Error(string memory reason) {
            // Get wallet balance after failed transaction to account for gas costs
            uint256 walletBalanceAfterFailure = sender.balance;
            uint256 gasCostFromFailure = walletBalanceBefore - walletBalanceAfterFailure;
            
            console.log("=== TRANSACTION FAILED ===");
            console.log("Transaction failed with reason:", reason);
            console.log("Wallet balance before:", walletBalanceBefore);
            console.log("Wallet balance after failure:", walletBalanceAfterFailure);
            console.log("Gas cost from failed transaction:", gasCostFromFailure);
            
            // Provide helpful debugging
            if (keccak256(bytes(reason)) == keccak256("Insufficient ETH - contract calculated optimal amount automatically")) {
                console.log("SOLUTION: The contract calculated a different optimal amount.");
                console.log("Try calling getOptimalETHAmount() again for the latest amount.");
            } else if (keccak256(bytes(reason)) == keccak256("ETH entry temporarily unavailable - use BONE")) {
                console.log("SOLUTION: ETH pricing system is temporarily down. Use BONE tokens instead.");
            }
            
            revert(reason);
        } catch {
            // Get wallet balance after failed transaction to account for gas costs
            uint256 walletBalanceAfterFailure = sender.balance;
            uint256 gasCostFromFailure = walletBalanceBefore - walletBalanceAfterFailure;
            
            console.log("=== TRANSACTION FAILED WITH UNKNOWN ERROR ===");
            console.log("Wallet balance before:", walletBalanceBefore);
            console.log("Wallet balance after failure:", walletBalanceAfterFailure);
            console.log("Gas cost from failed transaction:", gasCostFromFailure);
            console.log("This might be due to:");
            console.log("1. Pool liquidity issues");
            console.log("2. Price feed problems");
            console.log("3. Network congestion");
            revert("Unknown error occurred");
        }
        
        vm.stopBroadcast();
    }
    
    /**
     * @dev Helper function to check contract state before entering
     */
    function checkContractState() external view {
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        
        console.log("=== CONTRACT STATE CHECK ===");
        console.log("Contract address:", LOTTERY_CONTRACT);
        console.log("Current round ID:", lottery.currentRoundId());
        
        (
            uint256 playerCount, 
            VRFLottery.RoundState roundState, 
            address[3] memory winners, 
            uint256 totalPrizePool, 
            uint256 startTime
        ) = lottery.getRoundInfo(lottery.currentRoundId());
            
        console.log("Players in current round:", playerCount);
        console.log("Round state:", uint256(roundState));
        console.log("Total prize pool:", totalPrizePool);
        console.log("Round start time:", startTime);
        
        // Display winners if any
        bool hasWinners = false;
        for (uint i = 0; i < 3; i++) {
            if (winners[i] != address(0)) {
                console.log("Winner", i + 1, ":", winners[i]);
                hasWinners = true;
            }
        }
        if (!hasWinners) {
            console.log("No winners selected yet");
        }
        
        // // Check ETH entry availability
        // (bool ethAvailable, string memory ethStatus) = lottery.canEnterWithETH();
        // console.log("=== ETH ENTRY STATUS ===");
        // console.log("ETH entry available:", ethAvailable);
        // console.log("Status:", ethStatus);
        
        // if (ethAvailable) {
        //     (uint256 optimalAmount, bool optimalAvailable, string memory message) = lottery.getOptimalETHAmount();
        //     console.log("Optimal ETH amount:", optimalAmount);
        //     console.log("Optimal available:", optimalAvailable);
        //     console.log("Message:", message);
        // }
    }
    
    /**
     * @dev Helper function to check wallet balance without making any transactions
     */
    function checkWalletBalance() external view {
        uint256 privateKey = vm.envUint("ENTER_PRIVATE_KEY");
        address sender = vm.addr(privateKey);
        
        console.log("=== WALLET BALANCE CHECK ===");
        console.log("Wallet address:", sender);
        console.log("Current ETH balance:", sender.balance);
        console.log("Current ETH balance (in ETH):", sender.balance / 1e18);
        
        // Check if wallet has enough for optimal amount
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        (uint256 optimalAmount, bool available,) = lottery.getOptimalETHAmount();
        
        if (available) {
            uint256 ethToSend = (optimalAmount * 105) / 100; // Including 5% buffer
            console.log("Required ETH (with buffer):", ethToSend);
            console.log("Can afford entry:", sender.balance >= ethToSend ? "YES" : "NO");
            
            if (sender.balance >= ethToSend) {
                console.log("Remaining after entry (estimated):", sender.balance - ethToSend);
            } else {
                console.log("Additional ETH needed:", ethToSend - sender.balance);
            }
        }
    }
}