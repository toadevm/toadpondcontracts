// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {CrossChainLotteryEntry} from "../src/CrossChainLotteryEntry.sol";

contract DeployCrossChainLottery is Script {
    // Network Configuration - SINGLE SOURCE OF TRUTH
    struct NetworkConfig {
        address ccipRouter;
        uint64 puppynetChainSelector;
        uint64 sepoliaChainSelector;
        address ethereumMainContract;
    }

    function getNetworkConfig() internal pure returns (NetworkConfig memory) {
        return NetworkConfig({
            ccipRouter: 0x449E234FEDF3F907b9E9Dd6BAf1ddc36664097E5, // Puppynet CCIP Router
            puppynetChainSelector: 17833296867764334567, // Update with actual Puppynet selector
            sepoliaChainSelector: 16015286601757825753, // Sepolia chain selector
            ethereumMainContract: 0xe5F919CF96Cd14EfFCc31230588f424b71e09244 // Your latest main contract
        });
    }
    
    function run() external {
        NetworkConfig memory config = getNetworkConfig();
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Deployment Configuration ===");
        console.log("Deploying from address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        console.log("Network: Shibarium Puppynet");
        console.log("CCIP Router:", config.ccipRouter);
        console.log("Ethereum Main Contract:", config.ethereumMainContract);
        console.log("Puppynet Chain Selector:", config.puppynetChainSelector);
        console.log("Sepolia Chain Selector:", config.sepoliaChainSelector);
        
        require(deployer.balance > 0.1 ether, "Insufficient BONE for deployment");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Set up funding addresses
        address payable[5] memory fundingAddresses = [
            payable(deployer),
            payable(deployer),
            payable(deployer),
            payable(deployer),
            payable(deployer)
        ];
        
        // Deploy the cross-chain contract
        CrossChainLotteryEntry crossChainLottery = new CrossChainLotteryEntry(
            config.ccipRouter,
            config.ethereumMainContract,
            config.sepoliaChainSelector,
            config.puppynetChainSelector,
            payable(deployer),
            fundingAddresses
        );
        
        console.log("=== Deployment Successful ===");
        console.log("CrossChain Lottery deployed at:", address(crossChainLottery));
        
        // Verify deployment
        console.log("=== Contract Verification ===");
        console.log("Contract admin:", crossChainLottery.getAdmin());
        console.log("Current round ID:", crossChainLottery.currentRoundId());
        console.log("Entry fee (BONE):", crossChainLottery.ENTRY_FEE_BONE());
        console.log("Ethereum main contract:", crossChainLottery.ethereumMainContract());
        console.log("Cross-chain gas limit:", crossChainLottery.crossChainGasLimit());
        
        // Test cost functions
        console.log("=== Cross-Chain Entry Costs ===");
        (uint256 entryFee, uint256 estimatedCCIPFee, uint256 recommendedTotal, string memory message) = crossChainLottery.getEntryTotalCost();
        console.log("Entry fee:", entryFee);
        console.log("Estimated CCIP fee:", estimatedCCIPFee);
        console.log("Recommended total:", recommendedTotal);
        console.log("Cost message:", message);
        
        // Get entry instructions
        (string memory instructions, uint256 minimumRequired, uint256 recommendedAmount) = crossChainLottery.getEntryInstructions();
        console.log("=== Entry Instructions ===");
        console.log("Instructions:", instructions);
        console.log("Minimum required:", minimumRequired);
        console.log("Recommended amount:", recommendedAmount);
        
        // Get current round info
        (
            uint256 playerCount,
            uint256 localPrizePool,
            bool winnersReceived,
            ,
            uint256 totalChainPrizePool
        ) = crossChainLottery.getRoundInfo(1);
        
        console.log("=== Current Round Info ===");
        console.log("Player count:", playerCount);
        console.log("Local prize pool:", localPrizePool);
        console.log("Winners received:", winnersReceived);
        console.log("Total chain prize pool:", totalChainPrizePool);
        
        vm.stopBroadcast();
        
        console.log("=== Verification Instructions ===");
        console.log("Contract Address:", address(crossChainLottery));
        console.log("Network: Shibarium Puppynet");
        console.log("Deployer:", deployer);
        console.log("Status: Ready for cross-chain entries");
        
        console.log("\n=== Manual Verification Command ===");
        console.log("forge verify-contract \\");
        console.log("  --rpc-url $SHIBARIUM_PUPPYNET_RPC_URL \\");
        console.log("  --verifier blockscout \\");
        console.log("  --verifier-url 'https://puppyscan.shib.io/api/' \\");
        console.log("  ", address(crossChainLottery), " \\");
        console.log("  src/CrossChainLotteryEntry.sol:CrossChainLotteryEntry");
        
        console.log("\n=== Get Constructor Args Command ===");
        console.log("forge script script/DeployCrossChainLottery.s.sol:GetConstructorArgs --sig 'run()'");
        
        console.log("\n=== Test Entry Command (after updating contract address) ===");
        console.log("forge script script/DeployCrossChainLottery.s.sol:TestCrossChainEntry --rpc-url $SHIBARIUM_PUPPYNET_RPC_URL --broadcast");
    }
}

/**
 * @title Helper Contract for Getting Constructor Arguments
 */
contract GetConstructorArgs is Script {
    function run() external pure returns (bytes memory) {
        // Since we can't call getNetworkConfig from here, define inline
        address ccipRouter = 0x449E234FEDF3F907b9E9Dd6BAf1ddc36664097E5 ;
        uint64 sepoliaChainSelector = 16015286601757825753;
        uint64 puppynetChainSelector = 17833296867764334567;
        address ethereumMainContract = 0xCAAd79b0b0cdB695B73C412A0D2BcD9B172d7039;
        address deployerAddr = 0xB2DAF3f589C637F17c726729DdbdF9Be7B5334E5; // UPDATE THIS
        
        address payable[5] memory fundingAddresses = [
            payable(deployerAddr),
            payable(deployerAddr),
            payable(deployerAddr),
            payable(deployerAddr),
            payable(deployerAddr)
        ];
        
        return abi.encode(
            ccipRouter,
            ethereumMainContract,
            sepoliaChainSelector,
            puppynetChainSelector,
            payable(deployerAddr),
            fundingAddresses
        );
    }
}

/**
 * @title Test Cross-Chain Entry
 */
contract TestCrossChainEntry is Script {
    // UPDATE THIS AFTER DEPLOYMENT
    address payable constant CROSS_CHAIN_CONTRACT = payable(0x0);
    
    function run() external {
        require(CROSS_CHAIN_CONTRACT != payable(0x0), "Update CROSS_CHAIN_CONTRACT address first!");
        
        uint256 privateKey = vm.envUint("ENTER_PRIVATE_KEY");
        address sender = vm.addr(privateKey);
        
        vm.startBroadcast(privateKey);
        
        CrossChainLotteryEntry lottery = CrossChainLotteryEntry(CROSS_CHAIN_CONTRACT);
        
        console.log("=== Testing Cross-Chain Entry ===");
        console.log("Sender:", sender);
        console.log("Sender BONE balance:", sender.balance);
        console.log("Contract:", CROSS_CHAIN_CONTRACT);
        
        // Get entry costs
        (uint256 entryFee, uint256 estimatedCCIPFee, uint256 recommendedTotal, string memory message) = lottery.getEntryTotalCost();
        console.log("Entry fee:", entryFee);
        console.log("Estimated CCIP fee:", estimatedCCIPFee);
        console.log("Recommended total:", recommendedTotal);
        console.log("Message:", message);
        
        require(sender.balance >= recommendedTotal, "Insufficient BONE balance");
        
        // Check if already has pending entry
        (bool exists, uint256 timestamp, uint256 ccipFeePaid, bool verified) = lottery.getPendingEntry(sender);
        console.log("Has pending entry:", exists);
        
        if (!exists) {
            console.log("Entering lottery with recommended amount:", recommendedTotal);
            lottery.enterLottery{value: recommendedTotal}();
            console.log("Entry submitted! Waiting for NFT verification...");
            console.log("CCIP message sent to main contract for verification");
        } else {
            console.log("Already has pending entry from timestamp:", timestamp);
            console.log("CCIP fee paid:", ccipFeePaid);
            console.log("Verified:", verified);
        }
        
        // Check updated status
        (uint256 playerCount, uint256 localPrizePool,,,) = lottery.getRoundInfo(lottery.currentRoundId());
        console.log("=== Updated Round Status ===");
        console.log("Current round players:", playerCount);
        console.log("Local prize pool:", localPrizePool);
        console.log("Contract balance:", address(lottery).balance);
        
        vm.stopBroadcast();
        
        console.log("=== Next Steps ===");
        console.log("1. Wait for CCIP message to reach main contract");
        console.log("2. Main contract will verify NFT ownership");
        console.log("3. Response will be sent back via CCIP");
        console.log("4. Check entry status again in a few minutes");
    }
}

/**
 * @title Check Entry Status
 */
contract CheckEntryStatus is Script {
    function run() external view {
        address contractAddr = vm.envAddress("CROSS_CHAIN_CONTRACT");
        address playerAddr = vm.envAddress("PLAYER_ADDRESS");
        
        CrossChainLotteryEntry lottery = CrossChainLotteryEntry(payable(contractAddr));
        
        console.log("=== Entry Status Check ===");
        console.log("Contract:", contractAddr);
        console.log("Player:", playerAddr);
        
        // Check pending entry
        (bool exists, uint256 timestamp, uint256 ccipFeePaid, bool verified) = lottery.getPendingEntry(playerAddr);
        console.log("Has pending entry:", exists);
        console.log("Timestamp:", timestamp);
        console.log("CCIP fee paid:", ccipFeePaid);
        console.log("Verified:", verified);
        
        // Check if entered in current round
        uint256 currentRound = lottery.currentRoundId();
        bool hasEntered = lottery.hasPlayerEntered(currentRound, playerAddr);
        console.log("Has entered round", currentRound, ":", hasEntered);
        
        // Get player stats
        (uint256 totalWon, uint256 participationCount, uint256 points, uint256 pendingAmount, bool hasPending) = lottery.getPlayerStats(playerAddr);
        console.log("=== Player Stats ===");
        console.log("Total won:", totalWon);
        console.log("Participation count:", participationCount);
        console.log("Points:", points);
        console.log("Pending withdrawals:", pendingAmount);
        console.log("Has pending entry:", hasPending);
    }
}