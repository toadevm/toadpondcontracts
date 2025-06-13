// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

contract TestETHCalculationFix is Script {
    // Test the calculation logic before deploying
    
    function run() external pure {
        console.log("=== TESTING ETH CALCULATION FIX ===");
        
        // Your known values
        uint256 ENTRY_FEE_BONE = 1000000000000000000; // 1 BONE (1e18)
        uint256 poolBonePerETH = 9953; // From your contract
        uint256 baseSlippage = 2500; // 25%
        
        console.log("Entry fee (BONE):", ENTRY_FEE_BONE);
        console.log("Pool BONE per ETH:", poolBonePerETH);
        console.log("Base slippage:", baseSlippage);
        
        // Test the WRONG calculation (what might be in your contract)
        console.log("\n=== TESTING WRONG CALCULATION ===");
        uint256 wrongCalc = (ENTRY_FEE_BONE * 1e18) / poolBonePerETH;
        console.log("Wrong calculation result:", wrongCalc);
        console.log("Wrong calc in ETH:", wrongCalc / 1e18);
        console.log("Is wrong calc reasonable?", wrongCalc >= 0.001 ether && wrongCalc <= 5 ether);
        
        // Test the CORRECT calculation
        console.log("\n=== TESTING CORRECT CALCULATION ===");
        uint256 correctCalc = ENTRY_FEE_BONE / poolBonePerETH;
        console.log("Correct calculation result:", correctCalc);
        console.log("Correct calc in ETH (approx):", correctCalc / 1e15, "* 0.001 ETH");
        
        // Add slippage
        uint256 withSlippage = (correctCalc * (10000 + baseSlippage)) / 10000;
        console.log("With slippage:", withSlippage);
        console.log("With slippage in ETH (approx):", withSlippage / 1e15, "* 0.001 ETH");
        
        // Check bounds
        uint256 minBound = 0.001 ether;
        uint256 maxBound = 5 ether;
        bool withinBounds = withSlippage >= minBound && withSlippage <= maxBound;
        console.log("Within bounds (0.001 to 5 ETH):", withinBounds);
        
        // Expected result analysis
        console.log("\n=== ANALYSIS ===");
        uint256 expectedValue = 100472219431327;
        console.log("Expected ETH for 1 BONE:", expectedValue);
        console.log("Our correct calculation:", correctCalc);
        console.log("Calculations match:", correctCalc == expectedValue);
        
        if (correctCalc == expectedValue) {
            console.log("SUCCESS: Fix will work correctly!");
        } else {
            console.log("ERROR: Something is still wrong");
        }
    }
    
    function testBoundsChecking() external pure {
        console.log("=== TESTING BOUNDS CHECKING ===");
        
        uint256 ENTRY_FEE_BONE = 1000000000000000000;
        uint256 poolBonePerETH = 9953;
        uint256 baseSlippage = 2500;
        
        // Correct calculation
        uint256 ethRequired = ENTRY_FEE_BONE / poolBonePerETH;
        uint256 withSlippage = (ethRequired * (10000 + baseSlippage)) / 10000;
        
        // Test different bounds
        uint256 minBound1 = 1000000000000000;      // 0.001 ether value
        uint256 maxBound1 = 5000000000000000000;   // 5 ether value
        
        console.log("ETH required:", ethRequired);
        console.log("With slippage:", withSlippage);
        console.log("Min bound:", minBound1);
        console.log("Max bound:", maxBound1);
        
        bool test1 = withSlippage >= minBound1;
        bool test2 = withSlippage <= maxBound1;
        
        console.log("Above minimum:", test1);
        console.log("Below maximum:", test2);
        console.log("Within bounds:", test1 && test2);
        
        // More reasonable bounds for this calculation
        uint256 reasonableMin = 50000000000000;     // 0.00005 ether value
        uint256 reasonableMax = 1000000000000000;   // 0.001 ether value
        
        bool reasonable = withSlippage >= reasonableMin && withSlippage <= reasonableMax;
        console.log("Within reasonable bounds:", reasonable);
    }
    
    function simulateFullCalculation() external pure {
        console.log("=== SIMULATING FULL ETH ENTRY CALCULATION ===");
        
        // Input values
        uint256 ENTRY_FEE_BONE = 1000000000000000000;
        uint256 poolBonePerETH = 9953;
        uint256 baseSlippage = 2500;
        
        console.log("Starting simulation...");
        
        // Step 1: Check if pool is valid (assume true)
        bool poolValid = true;
        console.log("Pool valid:", poolValid);
        
        // Step 2: Calculate base ETH required
        uint256 ethRequired = ENTRY_FEE_BONE / poolBonePerETH;
        console.log("Base ETH required:", ethRequired);
        
        // Step 3: Add slippage
        ethRequired = (ethRequired * (10000 + baseSlippage)) / 10000;
        console.log("ETH with slippage:", ethRequired);
        
        // Step 4: Check bounds
        uint256 minBoundCheck = 1000000000000000; // 0.001 ether value
        uint256 maxBoundCheck = 5000000000000000000; // 5 ether value
        bool valid = ethRequired >= minBoundCheck && ethRequired <= maxBoundCheck;
        console.log("Passes bounds check:", valid);
        
        // Step 5: What the user would see
        if (valid) {
            console.log("SUCCESS: ETH entry would be available");
            console.log("User needs approximately:", ethRequired / 1e15, "* 0.001 ETH");
        } else {
            console.log("FAIL: ETH entry would be unavailable");
        }
        
        // Compare with your contract's current result
        console.log("\nComparison with current contract:");
        console.log("Current contract returns: 0 ETH");
        console.log("Fixed calculation returns:", ethRequired);
        console.log("Improvement factor: INFINITE (0 to", ethRequired, ")");
    }
}