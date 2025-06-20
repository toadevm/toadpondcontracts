// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {CoinFlip} from "../src/CoinFlip.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title CoinFlip Deployment Script with Gas Analysis
 * @dev Handles deployment with detailed gas cost analysis
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
        address frogSoupNFT = vm.envOr("FROG_SOUP_NFT", address(0));
        
        if (toadToken == address(0)) {
            console.log("WARNING: Using placeholder TOAD token address");
            toadToken = 0x1234567890123456789012345678901234567890;
        }
        
        if (boneToken == address(0)) {
            console.log("WARNING: Using placeholder BONE token address");
            boneToken = 0x0987654321098765432109876543210987654321;
        }
        
        if (frogSoupNFT == address(0)) {
            console.log("WARNING: Using placeholder Frog Soup NFT address");
            frogSoupNFT = 0x0987654321098765432109876543210987654321;
        }
        
        // Get donor addresses from environment or use defaults
        address[6] memory donors;
        donors[0] = vm.envOr("DONOR_1", address(0x1111111111111111111111111111111111111111));
        donors[1] = vm.envOr("DONOR_2", address(0x2222222222222222222222222222222222222222));
        donors[2] = vm.envOr("DONOR_3", address(0x3333333333333333333333333333333333333333));
        donors[3] = vm.envOr("DONOR_4", address(0x4444444444444444444444444444444444444444));
        donors[4] = vm.envOr("DONOR_5", address(0x5555555555555555555555555555555555555555));
        donors[5] = vm.envOr("DONOR_6", address(0x6666666666666666666666666666666666666666));
        
        console.log("TOAD Token:", toadToken);
        console.log("BONE Token:", boneToken);
        console.log("Frog Soup NFT:", frogSoupNFT);
        console.log("VRF Wrapper:", config.vrfWrapper);
        console.log("LINK Token:", config.linkToken);
        console.log("WETH:", config.weth);
        
        console.log("=== DONOR ADDRESSES ===");
        for (uint256 i = 0; i < 6; i++) {
            console.log("Donor", i + 1, ":", donors[i]);
            require(donors[i] != address(0), string(abi.encodePacked("Donor ", vm.toString(i + 1), " address is zero")));
        }
        
        // Validate all addresses are unique
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = i + 1; j < 6; j++) {
                require(donors[i] != donors[j], "Duplicate donor addresses detected");
            }
        }
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy CoinFlip contract with NEW constructor parameters
        coinFlip = new CoinFlip(
            config.vrfWrapper,  // _wrapperAddress
            config.linkToken,   // _linkToken
            toadToken,          // _toadToken
            boneToken,          // _boneToken
            config.weth,        // _weth
            frogSoupNFT,        // _frogSoupNFT (NEW)
            donors              // _donors (NEW - array of 6 addresses)
        );
        
        deployedContract = address(coinFlip);
        deploymentBlock = block.number;
        deploymentTimestamp = block.timestamp;
        
        console.log("Contract deployed at:", deployedContract);
        console.log("Deployment block:", deploymentBlock);
        
        vm.stopBroadcast();
        
        // Calculate deployment costs
        uint256 bytecodeSize = deployedContract.code.length;
        uint256 gasUsed = 21000 + (bytecodeSize * 200) + 500000; // Estimate for CoinFlip
        
        console.log("=== DEPLOYMENT COST ANALYSIS ===");
        console.log("Contract bytecode size:", bytecodeSize, "bytes");
        console.log("Estimated gas used:", gasUsed);
        console.log("Gas breakdown:");
        console.log("  - Base deployment cost: 21,000 gas");
        console.log("  - Bytecode cost:", bytecodeSize * 200, "gas");
        console.log("  - Constructor execution: ~500,000 gas");
        
        // Gas price scenarios with ETH conversion
        console.log("\n=== Cost at Different Gas Prices ===");
        
        // Calculate costs in wei, then convert to ETH (divide by 1e18)
        uint256 lowCostWei = gasUsed * 500000000; // 0.5 gwei in wei
        uint256 normalCostWei = gasUsed * 2000000000; // 2 gwei in wei  
        uint256 highCostWei = gasUsed * 10000000000; // 10 gwei in wei
        uint256 veryHighCostWei = gasUsed * 20000000000; // 20 gwei in wei
        
        console.log("Low (0.5 gwei):", lowCostWei / 1e18, "ETH");
        console.log("Normal (2 gwei):", normalCostWei / 1e18, "ETH");
        console.log("High (10 gwei):", highCostWei / 1e18, "ETH");
        console.log("Very High (20 gwei):", veryHighCostWei / 1e18, "ETH");
        
        // Post-deployment verification
        _verifyDeployment(config);
        _printInstructions();
        
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Contract Address:", deployedContract);
        console.log("Network:", config.name);
        console.log("Status: Ready for CoinFlip games");
    }
    
    function _verifyDeployment(NetworkConfig memory config) internal view {
        console.log("\n=== DEPLOYMENT VERIFICATION ===");
        
        // Verify contract deployed correctly
        require(deployedContract.code.length > 0, "Contract deployment failed");
        console.log(" Contract has bytecode");
        
        // Verify contract configuration
        require(coinFlip.TOAD_TOKEN() != address(0), "TOAD token not set");
        require(coinFlip.BONE_TOKEN() != address(0), "BONE token not set");
        require(coinFlip.LINK_TOKEN() == config.linkToken, "LINK token mismatch");
        require(coinFlip.WETH() == config.weth, "WETH mismatch");
        require(coinFlip.getFrogSoupNFT() != address(0), "Frog Soup NFT not set");
        console.log(" Contract configuration verified");
        
        // Verify donor configuration
        address[6] memory deployedDonors = coinFlip.getDonors();
        for (uint256 i = 0; i < 6; i++) {
            require(deployedDonors[i] != address(0), "Donor address not set");
        }
        console.log(" All 6 donors configured correctly");
        
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
            console.log(" Low LINK balance - fund contract for VRF");
        }
        
        console.log("Can afford VRF:", coinFlip.canAffordVRF());
        console.log("Platform fee percentage:", coinFlip.PLATFORM_FEE_PERCENT(), "%");
    }
    
    function _printInstructions() internal view {
        console.log("\n=== NEXT STEPS ===");
        console.log("1. Fund contract with LINK tokens:");
        console.log("   Recommended: 10+ LINK for ~40 games");
        console.log("");
        console.log("2. Verify Frog Soup NFT requirement:");
        console.log("   Players need at least 1 NFT from:", coinFlip.getFrogSoupNFT());
        console.log("");
        console.log("3. Donors can withdraw fees using:");
        console.log("   Each donor gets ~0.833%% of each game pot (5%% / 6 donors)");
        console.log("");
        console.log("4. Test with small amounts first");
        console.log("");
        console.log("5. Verify contract on Etherscan");
    }
}