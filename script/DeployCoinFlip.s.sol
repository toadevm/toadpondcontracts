// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {CoinFlip} from "../src/CoinFlip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Comprehensive CoinFlip Deployment Script
 * @dev Handles deployment, configuration, and initial setup
 */
contract DeployCoinFlip is Script {
    
    // Network configurations
    struct NetworkConfig {
        address vrfWrapper;
        address linkToken;
        address weth;
        string name;
    }
    
    mapping(uint256 => NetworkConfig) public networkConfigs;
    
    // Contract instances
    CoinFlip public coinFlip;
    
    // Deployment tracking
    address public deployedContract;
    uint256 public deploymentBlock;
    uint256 public deploymentTimestamp;
    
    function setUp() public {
        // Sepolia testnet
        networkConfigs[11155111] = NetworkConfig({
            vrfWrapper: 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1,
            linkToken: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
            weth: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
            name: "Sepolia"
        });
        
        // Ethereum mainnet
        networkConfigs[1] = NetworkConfig({
            vrfWrapper: 0x02aae1A04f9828517b3007f83f6181900CaD910c,
            linkToken: 0x514910771AF9Ca656af840dff83E8264EcF986CA,
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            name: "Mainnet"
        });
        
        // Polygon mainnet
        networkConfigs[137] = NetworkConfig({
            vrfWrapper: 0x4e42f0adEB69203ef7AaA4B7c414e5b1331c14dc,
            linkToken: 0xb0897686c545045aFc77CF20eC7A532E3120E0F1,
            weth: 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270, // WMATIC
            name: "Polygon"
        });
        
        // Arbitrum One
        networkConfigs[42161] = NetworkConfig({
            vrfWrapper: 0x2D159AE3bFf04a10A355B608D22BDEC092e934fa,
            linkToken: 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4,
            weth: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            name: "Arbitrum"
        });

        // Arbitrum Sepolia testnet
        networkConfigs[421614] = NetworkConfig({
            vrfWrapper: 0x29576aB8152A09b9DC634804e4aDE73dA1f3a3CC,
            linkToken: 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E,
            weth: 0x980B62Da83eFf3D4576C647993b0c1D7faf17c73, // WETH on Arbitrum Sepolia
            name: "Arbitrum Sepolia"
        });
    }
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;
        
        console.log("=== COINFLIP DEPLOYMENT ===");
        console.log("Chain ID:", chainId);
        console.log("Network:", networkConfigs[chainId].name);
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance / 1e18, "ETH");
        
        // Get network configuration
        NetworkConfig memory config = networkConfigs[chainId];
        require(config.vrfWrapper != address(0), "Unsupported network");
        
        // Get token addresses from environment or use defaults
        address toadToken = vm.envOr("TOAD_TOKEN", address(0));
        address boneToken = vm.envOr("BONE_TOKEN", address(0));
        
        if (toadToken == address(0)) {
            console.log("WARNING: Using placeholder TOAD token address");
            toadToken = 0x1234567890123456789012345678901234567890;
        }
        
        if (boneToken == address(0)) {
            console.log("WARNING: Using placeholder BONE token address");
            boneToken = 0x0987654321098765432109876543210987654321;
        }
        
        console.log("TOAD Token:", toadToken);
        console.log("BONE Token:", boneToken);
        console.log("VRF Wrapper:", config.vrfWrapper);
        console.log("LINK Token:", config.linkToken);
        console.log("WETH:", config.weth);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy CoinFlip contract
        coinFlip = new CoinFlip(
            config.vrfWrapper,
            config.linkToken,
            toadToken,
            boneToken,
            config.weth
        );
        
        deployedContract = address(coinFlip);
        deploymentBlock = block.number;
        deploymentTimestamp = block.timestamp;
        
        console.log("Contract deployed at:", deployedContract);
        console.log("Deployment block:", deploymentBlock);
        console.log("Gas used for deployment:", gasleft());
        
        // Setup gas tokens if pools are provided
        address toadPool = vm.envOr("TOAD_WETH_POOL", address(0));
        address bonePool = vm.envOr("BONE_WETH_POOL", address(0));
        
        if (toadPool != address(0)) {
            console.log("Setting up TOAD DEX oracle...");
            bool toadToken0IsWETH = vm.envOr("TOAD_TOKEN0_IS_WETH", false);
            uint128 toadMinLiquidity = uint128(vm.envOr("TOAD_MIN_LIQUIDITY", uint256(1000000)));
            
            coinFlip.setupGasToken(
                toadToken,
                toadPool,
                toadToken0IsWETH,
                toadMinLiquidity,
                300 // 5 minutes
            );
            console.log("TOAD DEX oracle configured");
        } else {
            console.log("No TOAD pool provided - skipping DEX oracle setup");
        }
        
        if (bonePool != address(0)) {
            console.log("Setting up BONE DEX oracle...");
            bool boneToken0IsWETH = vm.envOr("BONE_TOKEN0_IS_WETH", false);
            uint128 boneMinLiquidity = uint128(vm.envOr("BONE_MIN_LIQUIDITY", uint256(500000)));
            
            coinFlip.setupGasToken(
                boneToken,
                bonePool,
                boneToken0IsWETH,
                boneMinLiquidity,
                300 // 5 minutes
            );
            console.log("BONE DEX oracle configured");
        } else {
            console.log("No BONE pool provided - skipping DEX oracle setup");
        }
        
        // Fund contract with LINK if specified
        uint256 linkFunding = vm.envOr("INITIAL_LINK_FUNDING", uint256(0));
        if (linkFunding > 0) {
            console.log("Funding contract with", linkFunding / 1e18, "LINK");
            IERC20(config.linkToken).transfer(deployedContract, linkFunding);
        }
        
        vm.stopBroadcast();
        
        // Post-deployment verification
        _verifyDeployment(config);
        _printInstructions();
        
        console.log("=== DEPLOYMENT COMPLETE ===");
    }
    
    function _verifyDeployment(NetworkConfig memory config) internal view {
        console.log("=== DEPLOYMENT VERIFICATION ===");
        
        // Verify contract deployed correctly
        require(deployedContract.code.length > 0, "Contract deployment failed");
        console.log(" Contract has bytecode");
        
        // Verify contract configuration
        require(coinFlip.TOAD_TOKEN() != address(0), "TOAD token not set");
        require(coinFlip.BONE_TOKEN() != address(0), "BONE token not set");
        require(coinFlip.LINK_TOKEN() == config.linkToken, "LINK token mismatch");
        require(coinFlip.WETH() == config.weth, "WETH mismatch");
        console.log(" Contract configuration verified");
        
        // Check VRF configuration
        require(coinFlip.callbackGasLimit() == 300000, "VRF gas limit incorrect");
        require(coinFlip.requestConfirmations() == 3, "VRF confirmations incorrect");
        console.log(" VRF configuration verified");
        
        // Check ownership
        require(coinFlip.owner() != address(0), "Owner not set");
        console.log(" Ownership configured");
        
        // Check LINK balance
        uint256 linkBalance = coinFlip.getLinkBalance();
        console.log("LINK balance:", linkBalance / 1e18, "LINK");
        
        if (linkBalance >= 1e18) {
            console.log(" Sufficient LINK balance");
        } else {
            console.log("  Low LINK balance - fund contract for VRF");
        }
        
        console.log("Contract can afford VRF:", coinFlip.canAffordVRF());
    }
    
    function _printInstructions() internal view {
        console.log("=== NEXT STEPS ===");
        console.log("1. Update .env with deployed contract address:");
        console.log("   COINFLIP_ADDRESS=%s", deployedContract);
        console.log("");
        console.log("2. Fund contract with LINK tokens:");
        console.log("   Recommended: 10+ LINK for ~40 games");
        console.log("   cast send %s 'transfer(address,uint256)' %s 10000000000000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY", 
                   coinFlip.LINK_TOKEN(), deployedContract);
        console.log("");
        console.log("3. If no DEX pools configured, set up Uniswap V3 pools:");
        console.log("   - Create TOAD/WETH and BONE/WETH pools");
        console.log("   - Add liquidity (>$10k recommended)");
        console.log("   - Configure oracles using setupGasToken()");
        console.log("");
        console.log("4. Test with small amounts first:");
        console.log("   forge script script/TestScript.s.sol --rpc-url $RPC_URL --broadcast");
        console.log("");
        console.log("5. Verify contract on Etherscan:");
        console.log("   forge verify-contract %s src/CoinFlip.sol:CoinFlip --etherscan-api-key $ETHERSCAN_API_KEY", deployedContract);
    }
    
    /**
     * @dev Emergency function to setup gas tokens post-deployment
     */
    function setupGasTokens() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address contractAddress = vm.envAddress("COINFLIP_ADDRESS");
        
        CoinFlip coinFlipContract = CoinFlip(payable(contractAddress));
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=== SETTING UP GAS TOKENS ===");
        
        // Setup TOAD
        address toadPool = vm.envAddress("TOAD_WETH_POOL");
        bool toadToken0IsWETH = vm.envBool("TOAD_TOKEN0_IS_WETH");
        uint128 toadMinLiquidity = uint128(vm.envUint("TOAD_MIN_LIQUIDITY"));
        
        coinFlipContract.setupGasToken(
            coinFlipContract.TOAD_TOKEN(),
            toadPool,
            toadToken0IsWETH,
            toadMinLiquidity,
            300
        );
        console.log(" TOAD configured");
        
        // Setup BONE
        address bonePool = vm.envAddress("BONE_WETH_POOL");
        bool boneToken0IsWETH = vm.envBool("BONE_TOKEN0_IS_WETH");
        uint128 boneMinLiquidity = uint128(vm.envUint("BONE_MIN_LIQUIDITY"));
        
        coinFlipContract.setupGasToken(
            coinFlipContract.BONE_TOKEN(),
            bonePool,
            boneToken0IsWETH,
            boneMinLiquidity,
            300
        );
        console.log(" BONE configured");
        
        vm.stopBroadcast();
        
        console.log("Gas tokens setup complete!");
    }
    
    /**
     * @dev Fund contract with LINK tokens
     */
    function fundWithLink() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address contractAddress = vm.envAddress("COINFLIP_ADDRESS");
        uint256 linkAmount = vm.envUint("LINK_AMOUNT") * 1e18; // Convert to wei
        
        uint256 chainId = block.chainid;
        NetworkConfig memory config = networkConfigs[chainId];
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=== FUNDING WITH LINK ===");
        console.log("Contract:", contractAddress);
        console.log("Amount:", linkAmount / 1e18, "LINK");
        
        IERC20(config.linkToken).transfer(contractAddress, linkAmount);
        
        console.log(" Contract funded with LINK");
        
        // Verify funding
        CoinFlip coinFlipContract = CoinFlip(payable(contractAddress));
        uint256 newBalance = coinFlipContract.getLinkBalance();
        console.log("New LINK balance:", newBalance / 1e18, "LINK");
        console.log("Can afford VRF:", coinFlipContract.canAffordVRF());
        
        vm.stopBroadcast();
    }
}