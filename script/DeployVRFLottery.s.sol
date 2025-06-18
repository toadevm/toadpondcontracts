// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VRFLottery} from "../src/VRFLottery.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract DeployVRFLottery is Script {
    // Sepolia addresses (updated for latest versions)
    address constant SEPOLIA_CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    uint64 constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
    
    // Chainlink ETH/USD price feed on Sepolia
    address constant SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    
    // Your token addresses
    address constant BONE_TOKEN = 0x427a32e47Cd5eBa1ff0F2e9d50D76dA53bd8aD92;
    address constant NFT_CONTRACT = 0x720Abad4270D3834F815e0d9eFf8E76C4eAEe4FA;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== VRF Lottery Deployment ===");
        console.log("Deploying from address:", deployer);
        console.log("Deployer balance:", deployer.balance);
        console.log("Network: Sepolia Testnet");
        
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
        
        // Create the pool key for BONE/ETH pool
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(BONE_TOKEN), // BONE
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(address(0)) // No hooks
        });
        
        console.log("=== Deployment Parameters ===");
        console.log("CCIP Router:", SEPOLIA_CCIP_ROUTER);
        console.log("Chain Selector:", SEPOLIA_CHAIN_SELECTOR);
        console.log("NFT Contract:", NFT_CONTRACT);
        console.log("BONE Token:", BONE_TOKEN);
        console.log("ETH/USD Price Feed:", SEPOLIA_ETH_USD_FEED);
        console.log("Dev Address:", deployer);
        
        // Deploy the main VRF lottery contract
        VRFLottery lottery = new VRFLottery(
            SEPOLIA_CCIP_ROUTER,
            SEPOLIA_CHAIN_SELECTOR,
            NFT_CONTRACT,
            BONE_TOKEN,
            payable(deployer), // Dev address
            fundingAddresses,
            poolKey,
            SEPOLIA_ETH_USD_FEED
        );
        
        console.log("=== Deployment Successful ===");
        console.log("VRF Lottery deployed at:", address(lottery));
        
        // Verify deployment
        console.log("=== Contract Verification ===");
        console.log("Current round ID:", lottery.currentRoundId());
        console.log("Entry fee (BONE):", lottery.ENTRY_FEE_BONE());
        console.log("Max players:", lottery.MAX_PLAYERS());
        console.log("Winners share:", lottery.WINNERS_SHARE(), "%");
        console.log("Dev share:", lottery.DEV_SHARE(), "%");
        console.log("Funding share:", lottery.FUNDING_SHARE(), "%");
        console.log("Burn share:", lottery.BURN_SHARE(), "%");
        
        // Check pool configuration
        PoolKey memory deployedPoolKey = lottery.getPoolKeyInfo();
        console.log("=== Pool Configuration ===");
        console.log("Pool currency0 (ETH):", Currency.unwrap(deployedPoolKey.currency0));
        console.log("Pool currency1 (BONE):", Currency.unwrap(deployedPoolKey.currency1));
        console.log("Pool fee:", deployedPoolKey.fee);
        console.log("Pool tick spacing:", deployedPoolKey.tickSpacing);
        
        // Check pool price info
        try lottery.getPoolPriceInfo() returns (
            uint160 sqrtPriceX96,
            uint256 bonePerEth,
            uint256 ethNeededForEntry,
            bool poolExists
        ) {
            console.log("=== Pool Price Info ===");
            console.log("Pool exists:", poolExists);
            if (poolExists) {
                console.log("SqrtPriceX96:", sqrtPriceX96);
                console.log("BONE per ETH:", bonePerEth);
                console.log("ETH needed for entry:", ethNeededForEntry);
            } else {
                console.log("WARNING: Pool does not exist yet!");
            }
        } catch Error(string memory reason) {
            console.log("Could not get pool price info:", reason);
        }
        
        // Check ETH entry availability
        try lottery.canEnterWithETH() returns (bool available, string memory status) {
            console.log("=== ETH Entry Status ===");
            console.log("ETH entry available:", available);
            console.log("Status:", status);
        } catch Error(string memory reason) {
            console.log("Could not check ETH entry status:", reason);
        }
        
        // Check optimal ETH amount
        try lottery.getOptimalETHAmount() returns (
            uint256 optimalAmount,
            bool available,
            string memory message
        ) {
            console.log("=== Optimal ETH Amount ===");
            console.log("Optimal amount:", optimalAmount);
            console.log("Available:", available);
            console.log("Message:", message);
        } catch Error(string memory reason) {
            console.log("Could not get optimal ETH amount:", reason);
        }
        
        
        // Check CCIP response costs
        (
            uint256 entryResponseCost,
            uint256 winnersNotificationCost,
            uint256 totalEstimatedCost
        ) = lottery.getCCIPResponseCosts();
        
        console.log("=== CCIP Response Costs ===");
        console.log("Entry response cost:", entryResponseCost);
        console.log("Winners notification cost:", winnersNotificationCost);
        console.log("Total estimated cost:", totalEstimatedCost);
        
        if (address(lottery).balance < totalEstimatedCost) {
            console.log("WARNING: Contract needs ETH for CCIP responses!");
            console.log("Send ETH to contract:", address(lottery));
            console.log("Recommended amount:", totalEstimatedCost);
        }
        
        vm.stopBroadcast();
        
        console.log("=== Deployment Complete ===");
        console.log("Contract Address:", address(lottery));
        console.log("Network: Sepolia Testnet");
        console.log("Deployer:", deployer);
        console.log("Status: Ready for lottery entries");
        
        console.log("\n=== Verification Command ===");
        console.log("forge verify-contract \\");
        console.log("  --chain sepolia \\");
        console.log("  --etherscan-api-key $ETHERSCAN_API_KEY \\");
        console.log("  ", address(lottery), " \\");
        console.log("  src/VRFLottery.sol:VRFLottery");
        
        console.log("\n=== Next Steps ===");
        console.log("1. Fund contract with LINK tokens for VRF");
        console.log("2. Fund contract with ETH for CCIP responses");
        console.log("3. Create BONE/ETH pool on Uniswap V4 (if not exists)");
        console.log("4. Configure cross-chain contracts");
        console.log("5. Start accepting lottery entries!");
    }
}

/**
 * @title Helper Contract for Getting Constructor Arguments
 * @dev Use this to get the encoded constructor arguments for verification
 */
contract GetConstructorArgs is Script {
    function run() external pure returns (bytes memory) {
        // Sepolia configuration
        address SEPOLIA_CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
        uint64 SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
        address SEPOLIA_ETH_USD_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
        address BONE_TOKEN = 0x427a32e47Cd5eBa1ff0F2e9d50D76dA53bd8aD92;
        address NFT_CONTRACT = 0x720Abad4270D3834F815e0d9eFf8E76C4eAEe4FA;
        
        // ⚠️ UPDATE THIS to your actual deployer address
        address deployer = 0x1c3216D6b999f7f5D87b317d1797aB9bEEAEA4EF;
        
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

/**
 * @title Test VRF Lottery Entry
 */
contract TestVRFLotteryEntry is Script {
    // ⚠️ UPDATE THIS AFTER DEPLOYMENT
    address payable constant VRF_LOTTERY_CONTRACT = payable(0x0000000000000000000000000000000000000000);
    
    function run() external {
        require(VRF_LOTTERY_CONTRACT != payable(0x0), "Update VRF_LOTTERY_CONTRACT address first!");
        
        uint256 privateKey = vm.envUint("ENTER_PRIVATE_KEY");
        address sender = vm.addr(privateKey);
        
        vm.startBroadcast(privateKey);
        
        VRFLottery lottery = VRFLottery(VRF_LOTTERY_CONTRACT);
        
        console.log("=== Testing VRF Lottery Entry ===");
        console.log("Sender:", sender);
        console.log("Sender ETH balance:", sender.balance);
        console.log("Contract:", VRF_LOTTERY_CONTRACT);
        
        // Check if can enter with ETH
        (bool ethAvailable, string memory ethStatus) = lottery.canEnterWithETH();
        console.log("ETH entry available:", ethAvailable);
        console.log("ETH status:", ethStatus);
        
        if (ethAvailable) {
            // Get optimal ETH amount
            (uint256 optimalAmount, bool available, string memory message) = lottery.getOptimalETHAmount();
            console.log("Optimal ETH amount:", optimalAmount);
            console.log("Message:", message);
            
            if (sender.balance >= optimalAmount) {
                console.log("Entering lottery with ETH amount:", optimalAmount);
                lottery.enterWithETH{value: optimalAmount}();
                console.log("ETH entry successful!");
            } else {
                console.log("Insufficient ETH balance");
            }
        } else {
            console.log("ETH entry not available, trying BONE entry...");
            
            // Check BONE balance and allowance
            console.log("Sender BONE balance:", lottery.boneToken().balanceOf(sender));
            console.log("BONE allowance:", lottery.boneToken().allowance(sender, address(lottery)));
            
            uint256 entryFee = lottery.ENTRY_FEE_BONE();
            if (lottery.boneToken().balanceOf(sender) >= entryFee) {
                if (lottery.boneToken().allowance(sender, address(lottery)) >= entryFee) {
                    lottery.enterWithBone();
                    console.log("BONE entry successful!");
                } else {
                    console.log("Need to approve BONE tokens first");
                    console.log("Run: BONE.approve(contract_address, entry_fee)");
                }
            } else {
                console.log("Insufficient BONE balance");
            }
        }
        
        // Check round status
        (uint256 playerCount, , address[3] memory winners, uint256 totalPrizePool, uint256 startTime) = lottery.getRoundInfo(lottery.currentRoundId());
        console.log("=== Round Status ===");
        console.log("Players in round:", playerCount);
        console.log("Total prize pool:", totalPrizePool);
        console.log("Round start time:", startTime);
        
        if (playerCount == lottery.MAX_PLAYERS()) {
            console.log("Round is full! Ready for VRF!");
        }
        
        vm.stopBroadcast();
    }
}