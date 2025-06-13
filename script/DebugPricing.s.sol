// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VRFLottery} from "../src/VRFLottery.sol";

contract DebugPricing is Script {
    address payable constant LOTTERY_CONTRACT = payable(0x748Ba4583D2627BE5fD6E231E734879EFfa731BD);
    
    function run() external view {
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        
        console.log("=== DEBUGGING ETH PRICING SYSTEM ===");
        
        // // 1. Check system status
        // (
        //     uint256 currentSlippage,
        //     bool ethPriceValid,
        //     bool poolPriceValid,
        //     uint256 estimatedETHCost,
        //     string memory systemHealth
        // ) = lottery.getSystemStatus();
        
        // console.log("Current slippage:", currentSlippage);
        // console.log("ETH price valid:", ethPriceValid);
        // console.log("Pool price valid:", poolPriceValid);
        // console.log("Estimated ETH cost:", estimatedETHCost);
        // console.log("System health:", systemHealth);
        
        // 2. Check pool information
        (
            uint160 sqrtPriceX96,
            uint256 bonePerEth,
            uint256 ethNeededForEntry,
            bool poolExists
        ) = lottery.getPoolPriceInfo();
        
        console.log("=== POOL INFORMATION ===");
        console.log("Pool exists:", poolExists);
        console.log("SqrtPriceX96:", sqrtPriceX96);
        console.log("BONE per ETH:", bonePerEth);
        console.log("ETH needed for entry:", ethNeededForEntry);
        
        // 3. Check ETH entry functions
        (bool canEnter, string memory status) = lottery.canEnterWithETH();
        console.log("=== ETH ENTRY STATUS ===");
        console.log("Can enter with ETH:", canEnter);
        console.log("Status:", status);
        
        (
            uint256 optimalAmount,
            bool optimalAvailable,
            string memory message
        ) = lottery.getOptimalETHAmount();
        
        console.log("Optimal ETH amount:", optimalAmount);
        console.log("Optimal available:", optimalAvailable);
        console.log("Message:", message);
        
        // // 4. Manual calculation to compare
        // uint256 entryFee = lottery.ENTRY_FEE_BONE();
        // console.log("=== MANUAL CALCULATION ===");
        // console.log("Entry fee (BONE):", entryFee);
        
        // if (bonePerEth > 0) {
        //     uint256 baseRequired = (entryFee * 1e18) / bonePerEth;
        //     console.log("Base ETH required:", baseRequired);
            
        //     uint256 withSlippage = (baseRequired * (10000 + currentSlippage)) / 10000;
        //     console.log("With slippage:", withSlippage);
            
        //     uint256 withBuffer = (withSlippage * 12000) / 10000;
        //     console.log("With 20% buffer:", withBuffer);
            
        //     uint256 minEthBound = 1000000000000000;
        //     uint256 maxEthBound = 5000000000000000000;
        //     console.log("Min ETH bound:", minEthBound);
        //     console.log("Max ETH bound:", maxEthBound);
        //     console.log("Is within bounds:", withBuffer >= minEthBound && withBuffer <= maxEthBound);
        // }
        
        // 5. Check constants
        console.log("=== CONTRACT CONSTANTS ===");
        console.log("MIN_BONE_PER_ETH:", lottery.MIN_BONE_PER_ETH());
        console.log("MAX_BONE_PER_ETH:", lottery.MAX_BONE_PER_ETH());
        console.log("Base slippage:", lottery.baseSlippage());
        
        // 6. Check if pool bounds are valid
        bool bonePerEthValid = bonePerEth >= lottery.MIN_BONE_PER_ETH() && 
                              bonePerEth <= lottery.MAX_BONE_PER_ETH();
        console.log("BONE per ETH within bounds:", bonePerEthValid);
    }
    
    function checkPoolDetails() external view {
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        
        console.log("=== DETAILED POOL ANALYSIS ===");
        
        // Get pool info
        (
            uint160 sqrtPriceX96,
            uint256 bonePerEth,
            uint256 ethNeededForEntry,
            bool poolExists
        ) = lottery.getPoolPriceInfo();
        
        if (poolExists && sqrtPriceX96 > 0) {
            console.log("Pool is active");
            console.log("SqrtPriceX96:", sqrtPriceX96);
            
            // Manual calculation of price from sqrtPriceX96
            uint256 priceX96 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
            console.log("PriceX96:", priceX96);
            
            console.log("Contract calculated BONE per ETH:", bonePerEth);
            
            if (bonePerEth > 0) {
                uint256 ethFor1Bone = 1e18 / bonePerEth;
                console.log("ETH needed for 1 BONE (no slippage):", ethFor1Bone);
                uint256 ethInUnits = ethFor1Bone / 100000000000000;
                console.log("That's about", ethInUnits, "* 0.0001 ETH");
            }
        } else {
            console.log("Pool issue detected:");
            console.log("- Pool exists:", poolExists);
            console.log("- SqrtPriceX96:", sqrtPriceX96);
        }
    }
    
    function verifyPriceCalculation() external pure {
        console.log("=== MANUAL PRICE VERIFICATION ===");
        
        // Your exact sqrtPriceX96 value from deployment logs
        uint256 inputSqrtPrice = 7904567351497526327410704003238;
        console.log("Input sqrtPriceX96:", inputSqrtPrice);
        
        // Calculate using the correct formula
        uint256 numerator = inputSqrtPrice * inputSqrtPrice;
        uint256 calculatedPrice = numerator >> 192;
        
        console.log("Calculated BONE per ETH:", calculatedPrice);
        console.log("Expected around 9953:", calculatedPrice >= 9000 && calculatedPrice <= 11000);
        
        // Show what ETH would be needed for 1 BONE entry
        if (calculatedPrice > 0) {
            uint256 ethFor1Bone = 1e18 / calculatedPrice;
            console.log("ETH needed for 1 BONE (no slippage):", ethFor1Bone);
            
            // With 25% slippage
            uint256 withSlippage = (ethFor1Bone * 12500) / 10000;
            console.log("With 25% slippage:", withSlippage);
            
            // Check if reasonable (should be around 0.0001 ETH)
            uint256 minReasonable = 50000000000000;  // 0.00005 ETH
            uint256 maxReasonable = 1000000000000000; // 0.001 ETH
            bool reasonable = withSlippage >= minReasonable && withSlippage <= maxReasonable;
            console.log("Is reasonable amount:", reasonable);
        }
    }
    
    function testCurrentContract() external view {
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        
        console.log("=== TESTING CURRENT CONTRACT ===");
        console.log("Contract address:", LOTTERY_CONTRACT);
        
        // Test all the pricing functions
        (bool canEnter, string memory status) = lottery.canEnterWithETH();
        console.log("Can enter with ETH:", canEnter);
        console.log("Status:", status);
        
        (uint256 optimal, bool available, string memory message) = lottery.getOptimalETHAmount();
        console.log("Optimal amount:", optimal);
        console.log("Available:", available);
        console.log("Message:", message);
        
        // Get pool info
        (uint160 sqrtPrice, uint256 bonePerEth, uint256 ethNeeded, bool poolExists) = lottery.getPoolPriceInfo();
        console.log("Pool exists:", poolExists);
        console.log("SqrtPriceX96:", sqrtPrice);
        console.log("BONE per ETH from contract:", bonePerEth);
        console.log("ETH needed from contract:", ethNeeded);
        
        // Manual verification
        if (sqrtPrice > 0) {
            uint256 manualCalc = (uint256(sqrtPrice) * uint256(sqrtPrice)) >> 192;
            console.log("Manual calculation result:", manualCalc);
            console.log("Matches contract result:", manualCalc == bonePerEth);
        }
    }
}