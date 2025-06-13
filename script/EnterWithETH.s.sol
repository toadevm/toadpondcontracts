// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VRFLottery} from "../src/VRFLottery.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract EnterWithETH is Script {
    // Your deployed contract address - UPDATE THIS to your actual contract
    address payable constant LOTTERY_CONTRACT = payable(0xCAAd79b0b0cdB695B73C412A0D2BcD9B172d7039);
    
    function run() external {
        // Get private key from environment
        uint256 privateKey = vm.envUint("ENTER_PRIVATE_KEY");
        
        // Start broadcasting transactions
        vm.startBroadcast(privateKey);
        
        // Get the lottery contract instance
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        
        // Get sender address
        address sender = vm.addr(privateKey);
        console.log("Sender address:", sender);
        console.log("Sender ETH balance:", sender.balance);
        
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
        
        console.log("Current round ID:", lottery.currentRoundId());
        console.log("Round state (0=Active, 1=Full, 2=VRFRequested, 3=WinnersSelected, 4=PrizesDistributed, 5=Completed):", uint256(roundState));
        console.log("Current players in round:", currentPlayerCount);
        console.log("Max players allowed:", lottery.MAX_PLAYERS());
        
        require(roundState == VRFLottery.RoundState.Active, "Current round is not active");
        require(currentPlayerCount < lottery.MAX_PLAYERS(), "Round is full");
        
        // === USE CONTRACT'S AUTOMATIC PRICING SYSTEM ===
        
        // Check if ETH entry is available
        (bool ethEntryAvailable, string memory ethStatus) = lottery.canEnterWithETH();
        console.log("ETH entry available:", ethEntryAvailable);
        console.log("ETH entry status:", ethStatus);
        
        if (!ethEntryAvailable) {
            console.log("ETH entry not available - please use BONE tokens instead");
            revert("ETH entry not available");
        }
        
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
        (
            uint160 sqrtPriceX96,
            uint256 bonePerEth,
            uint256 ethNeededForEntry,
            bool poolExists
        ) = lottery.getPoolPriceInfo();
        
        console.log("=== POOL PRICE INFO ===");
        console.log("Pool exists:", poolExists);
        console.log("SqrtPriceX96:", sqrtPriceX96);
        console.log("BONE per ETH:", bonePerEth);
        console.log("ETH needed for entry (legacy calc):", ethNeededForEntry);
        
        // Safety check - use the contract's optimal amount
        uint256 ethToSend = optimalAmount;
        
        // Add a small safety buffer (5%) in case of price movement between calls
        ethToSend = (ethToSend * 105) / 100;
        
        // Cap at reasonable maximum
        if (ethToSend > 3 ether) {
            ethToSend = 3 ether;
            console.log("Capped ETH amount to 3 ETH for safety");
        }
        
        console.log("Final ETH amount to send:", ethToSend);
        console.log("(This includes 5% safety buffer)");
        
        require(sender.balance >= ethToSend, "Insufficient ETH balance");
        
        // Get entry fee in BONE for reference
        uint256 entryFeeBone = lottery.ENTRY_FEE_BONE();
        console.log("Entry fee (BONE):", entryFeeBone);
        
        // Enter the lottery with ETH using contract's automatic system
        console.log("=== ENTERING LOTTERY ===");
        console.log("Calling enterWithETH() with amount:", ethToSend);
        console.log("Contract will automatically:");
        console.log("1. Calculate exact ETH needed");
        console.log("2. Perform swap for exactly 1 BONE");
        console.log("3. Refund unused ETH");
        console.log("4. Add you to lottery");
        
        uint256 balanceBefore = sender.balance;
        
        try lottery.enterWithETH{value: ethToSend}() {
            uint256 balanceAfter = sender.balance;
            uint256 actualETHUsed = balanceBefore - balanceAfter;
            
            console.log("SUCCESS: Entered lottery with ETH!");
            console.log("ETH sent:", ethToSend);
            console.log("Actual ETH used:", actualETHUsed);
            console.log("ETH refunded:", ethToSend - actualETHUsed);
            console.log("Refund percentage:", ((ethToSend - actualETHUsed) * 100) / ethToSend);
            
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
                
                // Check VRF funding
                (, , , bool sufficientFunds) = lottery.getVRFFundingStatus();
                if (!sufficientFunds) {
                    console.log("WARNING: Contract needs LINK funding before VRF can work!");
                }
            }
            
            // Display player stats
            uint32 totalEntries = lottery.entriesCount(sender);
            uint32 playerPoints = lottery.playerPoints(sender);
            console.log("=== YOUR STATS ===");
            console.log("Total entries:", totalEntries);
            console.log("Player points:", playerPoints);
            
        } catch Error(string memory reason) {
            console.log("Transaction failed with reason:", reason);
            
            // Provide helpful debugging
            if (keccak256(bytes(reason)) == keccak256("Insufficient ETH - contract calculated optimal amount automatically")) {
                console.log("SOLUTION: The contract calculated a different optimal amount.");
                console.log("Try calling getOptimalETHAmount() again for the latest amount.");
            } else if (keccak256(bytes(reason)) == keccak256("ETH entry temporarily unavailable - use BONE")) {
                console.log("SOLUTION: ETH pricing system is temporarily down. Use BONE tokens instead.");
            }
            
            revert(reason);
        } catch {
            console.log("Transaction failed with unknown error");
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
        
        // Check ETH entry availability
        (bool ethAvailable, string memory ethStatus) = lottery.canEnterWithETH();
        console.log("=== ETH ENTRY STATUS ===");
        console.log("ETH entry available:", ethAvailable);
        console.log("Status:", ethStatus);
        
        if (ethAvailable) {
            (uint256 optimalAmount, bool optimalAvailable, string memory message) = lottery.getOptimalETHAmount();
            console.log("Optimal ETH amount:", optimalAmount);
            console.log("Optimal available:", optimalAvailable);
            console.log("Message:", message);
        }
        
        // Check VRF funding
        (uint256 linkBalance, uint256 costPerRequest, uint256 requestsAffordable, bool sufficientFunds) = 
            lottery.getVRFFundingStatus();
            
        console.log("=== VRF FUNDING STATUS ===");
        console.log("LINK balance:", linkBalance);
        console.log("Cost per request:", costPerRequest);
        console.log("Requests affordable:", requestsAffordable);
        console.log("Sufficient funds:", sufficientFunds);
        
        // Check round readiness
        console.log("=== ROUND READINESS ===");
        console.log("Ready for VRF:", lottery.isRoundReadyForVRF(lottery.currentRoundId()));
        console.log("Ready for prize distribution:", lottery.isRoundReadyForPrizeDistribution(lottery.currentRoundId()));
        console.log("Ready for completion:", lottery.isRoundReadyForCompletion(lottery.currentRoundId()));
    }
    
    /**
     * @dev Test function to see what the automatic pricing system calculates
     */
    function testPricingCalculation() external view {
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        
        console.log("=== AUTOMATIC PRICING TEST ===");
        
        // Get all pricing information
        (bool canEnter, string memory status) = lottery.canEnterWithETH();
        console.log("Can enter with ETH:", canEnter);
        console.log("Entry status:", status);
        
        (uint256 optimal, bool available, string memory message) = lottery.getOptimalETHAmount();
        console.log("Optimal amount:", optimal);
        console.log("Available:", available);
        console.log("Message:", message);
        
        // Pool information
        (, uint256 bonePerEth, uint256 ethNeeded, bool poolExists) = lottery.getPoolPriceInfo();
        console.log("Pool exists:", poolExists);
        console.log("BONE per ETH:", bonePerEth);
        console.log("ETH needed (legacy calc):", ethNeeded);
        
        if (bonePerEth > 0) {
            // Manual calculation for comparison
            uint256 entryFee = lottery.ENTRY_FEE_BONE();
            uint256 baseSlippage = lottery.baseSlippage();
            uint256 baseRequired = (entryFee * 1e18) / bonePerEth;
            uint256 withSlippage = (baseRequired * (10000 + baseSlippage)) / 10000;
            uint256 withBuffer = (withSlippage * 12000) / 10000; // 20% buffer
            
            console.log("=== MANUAL CALCULATION ===");
            console.log("Entry fee (BONE):", entryFee);
            console.log("Base slippage:", baseSlippage);
            console.log("Base ETH required:", baseRequired);
            console.log("With slippage:", withSlippage);
            console.log("With 20% buffer:", withBuffer);
        }
    }
}