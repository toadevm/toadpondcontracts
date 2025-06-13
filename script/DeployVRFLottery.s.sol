// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VRFLottery} from "../src/VRFLottery.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract DeployVRFLottery is Script {
    // Sepolia addresses
    address constant SEPOLIA_CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    uint64 constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
    
    // Chainlink ETH/USD price feed on Sepolia
    address constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    
    // Your updated addresses
    address constant BONE_TOKEN = 0x427a32e47Cd5eBa1ff0F2e9d50D76dA53bd8aD92;
    
    // You'll need to set these to your actual addresses
    address constant NFT_CONTRACT = 0x720Abad4270D3834F815e0d9eFf8E76C4eAEe4FA; // UPDATE THIS
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying from address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        
        require(deployer.balance > 0.1 ether, "Insufficient ETH for deployment");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Set up funding addresses (you can update these)
        address payable[5] memory fundingAddresses = [
            payable(deployer), // Funding address 1
            payable(deployer), // Funding address 2
            payable(deployer), // Funding address 3
            payable(deployer), // Funding address 4
            payable(deployer)  // Funding address 5
        ];
        
        // Create the pool key based on your transaction data
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(BONE_TOKEN), // BONE
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(address(0)) // No hooks
        });
        
        console.log("Deploying VRF Lottery with parameters:");
        console.log("CCIP Router:", SEPOLIA_CCIP_ROUTER);
        console.log("Chain Selector:", SEPOLIA_CHAIN_SELECTOR);
        console.log("NFT Contract:", NFT_CONTRACT);
        console.log("BONE Token:", BONE_TOKEN);
        console.log("ETH/USD Price Feed:", SEPOLIA_ETH_USD_FEED);
        console.log("Dev Address:", deployer);
        
        // Deploy the contract
        VRFLottery lottery = new VRFLottery(
            SEPOLIA_CCIP_ROUTER,
            SEPOLIA_CHAIN_SELECTOR,
            NFT_CONTRACT,
            BONE_TOKEN,
            payable(deployer), // Dev address
            fundingAddresses,
            poolKey,
            SEPOLIA_ETH_USD_FEED // Added ETH/USD price feed
        );
        
        console.log("VRF Lottery deployed at:", address(lottery));
        
        // Verify deployment
        console.log("Contract admin:", lottery.getAdmin());
        console.log("Current round ID:", lottery.currentRoundId());
        console.log("Entry fee (BONE):", lottery.ENTRY_FEE_BONE());
        console.log("Max players:", lottery.MAX_PLAYERS());
        
        // Check pool key
        PoolKey memory deployedPoolKey = lottery.getPoolKeyInfo();
        console.log("Pool currency0:", Currency.unwrap(deployedPoolKey.currency0));
        console.log("Pool currency1:", Currency.unwrap(deployedPoolKey.currency1));
        console.log("Pool fee:", deployedPoolKey.fee);
        console.log("Pool tick spacing:", deployedPoolKey.tickSpacing);
        
        // Check if pool exists and get price info
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
            }
        } catch {
            console.log("Could not get pool price info - pool might not exist yet");
        }
        
        // Check ETH entry availability
        try lottery.canEnterWithETH() returns (bool available, string memory status) {
            console.log("ETH entry available:", available);
            console.log("ETH entry status:", status);
        } catch {
            console.log("Could not check ETH entry status");
        }
        
        // Check optimal ETH amount
        try lottery.getOptimalETHAmount() returns (
            uint256 optimalAmount,
            bool available,
            string memory message
        ) {
            console.log("Optimal ETH amount:", optimalAmount);
            console.log("ETH entry available:", available);
            console.log("Message:", message);
        } catch {
            console.log("Could not get optimal ETH amount");
        }
        
        // Check system status
        // try lottery.getSystemStatus() returns (
        //     uint256 currentSlippage,
        //     bool ethPriceValid,
        //     bool poolPriceValid,
        //     uint256 estimatedETHCost,
        //     string memory systemHealth
        // ) {
        //     console.log("=== System Status ===");
        //     console.log("Current slippage:", currentSlippage);
        //     console.log("ETH price valid:", ethPriceValid);
        //     console.log("Pool price valid:", poolPriceValid);
        //     console.log("Estimated ETH cost:", estimatedETHCost);
        //     console.log("System health:", systemHealth);
        // } catch {
        //     console.log("Could not get system status");
        // }
        
        // Check VRF funding status
        (
            uint256 linkBalance,
            uint256 costPerRequest,
            uint256 requestsAffordable,
            bool sufficientFunds
        ) = lottery.getVRFFundingStatus();
        
        console.log("=== VRF Funding Status ===");
        console.log("LINK balance:", linkBalance);
        console.log("Cost per request:", costPerRequest);
        console.log("Requests affordable:", requestsAffordable);
        console.log("Sufficient funds:", sufficientFunds);
        
        if (!sufficientFunds) {
            console.log("WARNING: Contract needs LINK tokens for VRF!");
            console.log("Send LINK to contract address:", address(lottery));
        }
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Summary ===");
        console.log("Contract Address:", address(lottery));
        console.log("Network: Sepolia");
        console.log("Deployer:", deployer);
        console.log("Verify with:");
        console.log("forge verify-contract --chain sepolia --etherscan-api-key $ETHERSCAN_API_KEY", address(lottery), "src/VRFLottery.sol:VRFLottery");
    }
}

/**
 * @title Helper Contract for Getting Constructor Arguments
 * @dev Use this to get the encoded constructor arguments for verification
 */
contract GetConstructorArgs is Script {
    function run() external pure returns (bytes memory) {
        // Sepolia addresses
        address SEPOLIA_CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
        uint64 SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
        address SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        address BONE_TOKEN = 0x427a32e47Cd5eBa1ff0F2e9d50D76dA53bd8aD92;
        address NFT_CONTRACT = 0x720Abad4270D3834F815e0d9eFf8E76C4eAEe4FA;
        address deployer = 0x1c3216D6b999f7f5D87b317d1797aB9bEEAEA4EF; // UPDATE THIS to your deployer address
        
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
            SEPOLIA_CCIP_ROUTER,
            SEPOLIA_CHAIN_SELECTOR,
            NFT_CONTRACT,
            BONE_TOKEN,
            payable(deployer),
            fundingAddresses,
            poolKey,
            SEPOLIA_ETH_USD_FEED
        );
    }
}