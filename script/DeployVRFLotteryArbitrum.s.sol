// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VRFLottery} from "../src/VRFLottery.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract DeployVRFLotteryArbitrum is Script {
    // Arbitrum Sepolia addresses
    address constant ARBITRUM_SEPOLIA_CCIP_ROUTER = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    uint64 constant ARBITRUM_SEPOLIA_CHAIN_SELECTOR = 3478487238524512106;
    
    // Chainlink ETH/USD price feed on Arbitrum Sepolia
    address constant ARBITRUM_SEPOLIA_ETH_USD_FEED = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    
    // VRF Wrapper on Arbitrum Sepolia (if available)
    // Note: VRF might not be available on Arbitrum Sepolia - check Chainlink docs
    address constant ARBITRUM_SEPOLIA_VRF_WRAPPER = 0x29576aB8152A09b9DC634804e4aDE73dA1f3a3CC; // This might not exist
    
    // Your token addresses (deploy these first if they don't exist on Arbitrum Sepolia)
    address constant BONE_TOKEN = 0xD2dcc238F36Dca475Efbe86006aDaab1025E738A; // UPDATE: Deploy BONE on Arbitrum Sepolia
    address constant NFT_CONTRACT = 0xFB7d7b95DeE4D58D420AfC95827dfe02a66db123; // UPDATE: Deploy NFT on Arbitrum Sepolia
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Arbitrum Sepolia Deployment ===");
        console.log("Deploying from address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        require(deployer.balance > 0.01 ether, "Insufficient ETH for deployment on Arbitrum");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Set up funding addresses
        address payable[5] memory fundingAddresses = [
            payable(deployer), // Funding address 1
            payable(deployer), // Funding address 2  
            payable(deployer), // Funding address 3
            payable(deployer), // Funding address 4
            payable(deployer)  // Funding address 5
        ];
        
        // Create the pool key for Arbitrum Sepolia
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(BONE_TOKEN), // BONE
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(address(0)) // No hooks
        });
        
        console.log("Deploying VRF Lottery on Arbitrum Sepolia with parameters:");
        console.log("CCIP Router:", ARBITRUM_SEPOLIA_CCIP_ROUTER);
        console.log("Chain Selector:", ARBITRUM_SEPOLIA_CHAIN_SELECTOR);
        console.log("NFT Contract:", NFT_CONTRACT);
        console.log("BONE Token:", BONE_TOKEN);
        console.log("ETH/USD Price Feed:", ARBITRUM_SEPOLIA_ETH_USD_FEED);
        console.log("Dev Address:", deployer);
        
        // Deploy the contract
        VRFLottery lottery = new VRFLottery(
            ARBITRUM_SEPOLIA_CCIP_ROUTER,
            ARBITRUM_SEPOLIA_CHAIN_SELECTOR,
            NFT_CONTRACT,
            BONE_TOKEN,
            payable(deployer), // Dev address
            fundingAddresses,
            poolKey,
            ARBITRUM_SEPOLIA_ETH_USD_FEED
        );
        
        console.log("VRF Lottery deployed at:", address(lottery));
        
        // Basic verification
        console.log("Contract admin:", lottery.getAdmin());
        console.log("Current round ID:", lottery.currentRoundId());
        console.log("Entry fee (BONE):", lottery.ENTRY_FEE_BONE());
        console.log("Max players:", lottery.MAX_PLAYERS());
        
        // Check pool configuration
        PoolKey memory deployedPoolKey = lottery.getPoolKeyInfo();
        console.log("=== Pool Configuration ===");
        console.log("Pool currency0:", Currency.unwrap(deployedPoolKey.currency0));
        console.log("Pool currency1:", Currency.unwrap(deployedPoolKey.currency1));
        console.log("Pool fee:", deployedPoolKey.fee);
        console.log("Pool tick spacing:", deployedPoolKey.tickSpacing);
        
        // Safely check pool status
        console.log("=== Pool Status Check ===");
        try lottery.getPoolPriceInfo() returns (
            uint160 sqrtPriceX96,
            uint256 bonePerEth,
            uint256 ethNeededForEntry,
            bool poolExists
        ) {
            console.log("Pool exists:", poolExists);
            if (poolExists) {
                console.log("SqrtPriceX96:", sqrtPriceX96);
                console.log("BONE per ETH:", bonePerEth);
                console.log("ETH needed for entry:", ethNeededForEntry);
            } else {
                console.log("Pool does not exist - you'll need to create the Uniswap V4 pool");
            }
        } catch {
            console.log("Could not get pool price info - Uniswap V4 might not be deployed on Arbitrum Sepolia");
        }
        
        // Check ETH entry status
        // try lottery.canEnterWithETH() returns (bool available, string memory status) {
        //     console.log("ETH entry available:", available);
        //     console.log("ETH entry status:", status);
        // } catch {
        //     console.log("ETH entry not available - pool or price feed issues");
        // }
        
        // Safely check VRF status (might fail if VRF not available)
        console.log("=== VRF Status Check ===");
        // try lottery.getVRFFundingStatus() returns (
        //     uint256 linkBalance,
        //     uint256 costPerRequest,
        //     uint256 requestsAffordable,
        //     bool sufficientFunds
        // ) {
        //     console.log("LINK balance:", linkBalance);
        //     console.log("Cost per request:", costPerRequest);
        //     console.log("Requests affordable:", requestsAffordable);
        //     console.log("Sufficient funds:", sufficientFunds);
            
        //     if (!sufficientFunds) {
        //         console.log("WARNING: Contract needs LINK tokens for VRF!");
        //         console.log("Send LINK to contract address:", address(lottery));
        //     }
        // } catch {
        //     console.log("VRF funding status check failed - VRF might not be available on Arbitrum Sepolia");
        //     console.log("You may need to use a different randomness source or deploy on a network with VRF support");
        // }
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Summary ===");
        console.log("Network: Arbitrum Sepolia");
        console.log("Contract Address:", address(lottery));
        console.log("Deployer:", deployer);
        console.log("Block Explorer: https://sepolia.arbiscan.io/address/", address(lottery));
        
        console.log("\n=== Next Steps ===");
        console.log("1. Verify contract on Arbiscan:");
        console.log("   forge verify-contract --chain arbitrum_sepolia --etherscan-api-key $ARBISCAN_API_KEY", address(lottery), "src/VRFLottery.sol:VRFLottery");
        
        console.log("2. If VRF is not available on Arbitrum Sepolia:");
        console.log("   - Consider deploying on Ethereum Sepolia or Polygon Mumbai");
        console.log("   - Or implement alternative randomness source");
        
        console.log("3. If Uniswap V4 pool doesn't exist:");
        console.log("   - Create the BONE/ETH pool on Uniswap V4");
        console.log("   - Or deploy on a network where the pool exists");
        
        console.log("4. Fund the contract with LINK tokens if VRF is available");
    }
}

/**
 * @title Arbitrum Sepolia Constructor Args Helper
 * @dev Get encoded constructor arguments for verification
 */
contract GetArbitrumConstructorArgs is Script {
    function run() external pure returns (bytes memory) {
        // Arbitrum Sepolia configuration
        address ARBITRUM_SEPOLIA_CCIP_ROUTER = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
        uint64 ARBITRUM_SEPOLIA_CHAIN_SELECTOR = 3478487238524512106;
        address ARBITRUM_SEPOLIA_ETH_USD_FEED = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
        address BONE_TOKEN = 0x427a32e47Cd5eBa1ff0F2e9d50D76dA53bd8aD92; // UPDATE TO ARBITRUM DEPLOYMENT
        address NFT_CONTRACT = 0x720Abad4270D3834F815e0d9eFf8E76C4eAEe4FA; // UPDATE TO ARBITRUM DEPLOYMENT
        address deployer = 0xB2DAF3f589C637F17c726729DdbdF9Be7B5334E5; // Your deployer address
        
        address payable[5] memory fundingAddresses = [
            payable(deployer),
            payable(deployer),
            payable(deployer),
            payable(deployer),
            payable(deployer)
        ];
        
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(BONE_TOKEN),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        return abi.encode(
            ARBITRUM_SEPOLIA_CCIP_ROUTER,
            ARBITRUM_SEPOLIA_CHAIN_SELECTOR,
            NFT_CONTRACT,
            BONE_TOKEN,
            payable(deployer),
            fundingAddresses,
            poolKey,
            ARBITRUM_SEPOLIA_ETH_USD_FEED
        );
    }
}

/**
 * @title Deploy Prerequisites
 * @dev Deploy BONE token and NFT contract if they don't exist on Arbitrum Sepolia
 */
contract DeployPrerequisites is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== Deploying Prerequisites on Arbitrum Sepolia ===");
        console.log("Deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Note: You'll need to create and deploy your BONE token and NFT contracts
        // This is just a placeholder to show where they would be deployed
        
        console.log("Deploy your BONE token contract here");
        console.log("Deploy your NFT contract here");
        console.log("Update the addresses in the main deployment script");
        
        vm.stopBroadcast();
    }
}