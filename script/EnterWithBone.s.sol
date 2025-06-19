// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {VRFLottery} from "../src/VRFLottery.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract EnterWithBone is Script {
    // Your deployed contract address - UPDATE THIS to your actual contract
    address payable constant LOTTERY_CONTRACT = payable(0xFC693f60FE0781CCB0Fe07f681381B78a022986a);
    
    // BONE token address on Sepolia
    address constant BONE_TOKEN = 0x427a32e47Cd5eBa1ff0F2e9d50D76dA53bd8aD92;
    
    function run() external {
        // Get private key from environment
        uint256 privateKey = vm.envUint("ENTER_PRIVATE_KEY_2");
        
        // Start broadcasting transactions
        vm.startBroadcast(privateKey);
        
        // Get the lottery contract instance
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        
        // Get BONE token instance
        IERC20 boneToken = IERC20(BONE_TOKEN);
        
        // Get sender address
        address sender = vm.addr(privateKey);
        console.log("=== WALLET INFO ===");
        console.log("Sender address:", sender);
        
        // Track wallet balances BEFORE any operations
        uint256 walletETHBalanceBefore = sender.balance;
        uint256 walletBONEBalanceBefore = boneToken.balanceOf(sender);
        console.log("Wallet ETH balance:", walletETHBalanceBefore);
        console.log("Wallet BONE balance:", walletBONEBalanceBefore);
        
        // Check if BONE token address matches
        address contractBoneToken = address(lottery.boneToken());
        console.log("=== TOKEN VERIFICATION ===");
        console.log("Expected BONE token:", BONE_TOKEN);
        console.log("Contract BONE token:", contractBoneToken);
        require(contractBoneToken == BONE_TOKEN, "BONE token address mismatch");
        
        // Check NFT ownership requirement
        address nftContract = address(lottery.nftContract());
        console.log("=== NFT REQUIREMENT ===");
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
            uint256 currentPrizePool,
        ) = lottery.getRoundInfo(lottery.currentRoundId());
        
        console.log("=== ROUND INFO ===");
        console.log("Current round ID:", lottery.currentRoundId());
        console.log("Round state (0=Active, 1=Full, 2=VRFRequested, 3=WinnersSelected, 4=PrizesDistributed, 5=Completed):", uint256(roundState));
        console.log("Current players in round:", currentPlayerCount);
        console.log("Max players allowed:", lottery.MAX_PLAYERS());
        console.log("Current prize pool:", currentPrizePool);
        
        require(roundState == VRFLottery.RoundState.Active, "Current round is not active");
        require(currentPlayerCount < lottery.MAX_PLAYERS(), "Round is full");
        
        // Get entry fee
        uint256 entryFeeBone = lottery.ENTRY_FEE_BONE();
        console.log("=== ENTRY FEE ===");
        console.log("Entry fee required:", entryFeeBone);
        console.log("Entry fee (in BONE):", entryFeeBone / 1e18);
        
        // Check BONE balance
        require(walletBONEBalanceBefore >= entryFeeBone, "Insufficient BONE balance");
        console.log("Wallet has sufficient BONE:", walletBONEBalanceBefore >= entryFeeBone);
        
        // === CHECK AND HANDLE APPROVAL ===
        console.log("=== CHECKING BONE TOKEN APPROVAL ===");
        uint256 currentAllowance = boneToken.allowance(sender, LOTTERY_CONTRACT);
        console.log("Current allowance:", currentAllowance);
        console.log("Required allowance:", entryFeeBone);
        
        if (currentAllowance < entryFeeBone) {
            console.log("Insufficient allowance, need to approve...");
            
            // If there's existing allowance, reset it to 0 first (some tokens require this)
            if (currentAllowance > 0) {
                console.log("Resetting existing allowance to 0...");
                try boneToken.approve(LOTTERY_CONTRACT, 0) {
                    console.log("Successfully reset allowance to 0");
                } catch {
                    console.log("Failed to reset allowance - continuing anyway");
                }
            }
            
            // Approve exactly the entry fee amount
            console.log("Approving BONE tokens...");
            console.log("Approving amount:", entryFeeBone);
            
            try boneToken.approve(LOTTERY_CONTRACT, entryFeeBone) {
                console.log("SUCCESS: BONE tokens approved!");
                
                // Verify approval
                uint256 newAllowance = boneToken.allowance(sender, LOTTERY_CONTRACT);
                console.log("New allowance:", newAllowance);
                require(newAllowance >= entryFeeBone, "Approval failed - allowance still insufficient");
            } catch Error(string memory reason) {
                console.log("FAILED: Approval failed with reason:", reason);
                revert(reason);
            } catch {
                console.log("FAILED: Approval failed with unknown error");
                revert("Failed to approve BONE tokens");
            }
        } else {
            console.log("Sufficient allowance already exists, no approval needed");
        }
        
        // === TRACK BALANCES BEFORE ENTRY ===
        console.log("=== PRE-TRANSACTION BALANCE TRACKING ===");
        console.log("BONE balance before entry:", walletBONEBalanceBefore);
        console.log("ETH balance before entry:", walletETHBalanceBefore);
        console.log("BONE to be spent:", entryFeeBone);
        console.log("Expected BONE balance after:", walletBONEBalanceBefore - entryFeeBone);
        
        // === ENTER THE LOTTERY WITH BONE ===
        console.log("=== ENTERING LOTTERY WITH BONE ===");
        console.log("Calling enterWithBone()...");
        console.log("This will:");
        console.log("1. Transfer exactly", entryFeeBone, "BONE from your wallet");
        console.log("2. Add you to the current lottery round");
        console.log("3. Increase the prize pool by", entryFeeBone);
        
        try lottery.enterWithBone() {
            // Get wallet balances immediately after transaction
            uint256 walletETHBalanceAfter = sender.balance;
            uint256 walletBONEBalanceAfter = boneToken.balanceOf(sender);
            
            // Calculate actual amounts spent
            uint256 actualBONESpent = walletBONEBalanceBefore - walletBONEBalanceAfter;
            uint256 gasUsed = walletETHBalanceBefore - walletETHBalanceAfter;
            
            console.log("=== POST-TRANSACTION BALANCE ANALYSIS ===");
            console.log("SUCCESS: Entered lottery with BONE!");
            console.log("");
            console.log("BONE BALANCE TRACKING:");
            console.log("- BONE balance BEFORE:", walletBONEBalanceBefore);
            console.log("- BONE balance AFTER: ", walletBONEBalanceAfter);
            console.log("- BONE spent:         ", actualBONESpent);
            console.log("- Expected BONE spent:", entryFeeBone);
            console.log("- Match:", actualBONESpent == entryFeeBone ? "YES" : "NO");
            console.log("");
            
            console.log("GAS TRACKING:");
            console.log("- ETH balance BEFORE:", walletETHBalanceBefore);
            console.log("- ETH balance AFTER: ", walletETHBalanceAfter);
            console.log("- Gas used (ETH):    ", gasUsed);
            console.log("- Gas used (wei):    ", gasUsed, "wei");
            console.log("");
            
            // Validate the transaction
            if (actualBONESpent == entryFeeBone) {
                console.log(" VALIDATION PASSED: Correct amount of BONE was spent");
            } else if (actualBONESpent > entryFeeBone) {
                console.log("WARNING: More BONE was spent than expected!");
                console.log("  Extra BONE spent:", actualBONESpent - entryFeeBone);
            } else {
                console.log("WARNING: Less BONE was spent than expected!");
                console.log("  BONE shortfall:", entryFeeBone - actualBONESpent);
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
            console.log("Prize pool increase:", newPrizePool - currentPrizePool);
            
            // Check if round is now full
            if (newPlayerCount == lottery.MAX_PLAYERS()) {
                console.log("*** ROUND IS NOW FULL! ***");
                console.log("Ready for VRF to select winners!");
                console.log("Someone needs to call requestRandomWords()");
                console.log("NOTE: Contract needs LINK tokens for VRF!");
            } else {
                uint256 spotsRemaining = lottery.MAX_PLAYERS() - newPlayerCount;
                console.log("Spots remaining in round:", spotsRemaining);
            }
            
            // Display player stats
            uint32 totalEntries = lottery.entriesCount(sender);
            uint32 playerPoints = lottery.playerPoints(sender);
            uint128 pendingWithdrawals = lottery.pendingWithdrawalsBone(sender);
            uint128 totalWinnings = lottery.totalWinningsBone(sender);
            
            console.log("=== YOUR PLAYER STATS ===");
            console.log("Total entries:", totalEntries);
            console.log("Player points:", playerPoints);
            console.log("Pending withdrawals:", pendingWithdrawals);
            console.log("Total winnings:", totalWinnings);
            
            // Check current players in round
            VRFLottery.Player[] memory players = lottery.getCurrentRoundPlayers();
            console.log("=== CURRENT ROUND PLAYERS ===");
            for (uint i = 0; i < players.length; i++) {
                console.log("Player", i + 1, ":", players[i].playerAddress);
                if (players[i].playerAddress == sender) {
                    console.log("  ^ That's you!");
                }
            }
            
            // Final summary
            console.log("=== FINAL SUMMARY ===");
            console.log(" Entry completed successfully!");
            console.log(" You are now player #", newPlayerCount, "in round", lottery.currentRoundId());
            console.log(" Total BONE cost:", actualBONESpent);
            console.log(" Gas cost (ETH):", gasUsed);
            console.log(" BONE balance remaining:", walletBONEBalanceAfter);
            console.log(" ETH balance remaining:", walletETHBalanceAfter);
            
        } catch Error(string memory reason) {
            // Get wallet balances after failed transaction to account for gas costs
            uint256 walletETHBalanceAfterFailure = sender.balance;
            uint256 walletBONEBalanceAfterFailure = boneToken.balanceOf(sender);
            uint256 gasCostFromFailure = walletETHBalanceBefore - walletETHBalanceAfterFailure;
            
            console.log("=== TRANSACTION FAILED ===");
            console.log("Transaction failed with reason:", reason);
            console.log("BONE balance before:", walletBONEBalanceBefore);
            console.log("BONE balance after failure:", walletBONEBalanceAfterFailure);
            console.log("ETH balance before:", walletETHBalanceBefore);
            console.log("ETH balance after failure:", walletETHBalanceAfterFailure);
            console.log("Gas cost from failed transaction:", gasCostFromFailure);
            
            // Provide helpful debugging based on error
            if (keccak256(bytes(reason)) == keccak256("No NFT")) {
                console.log("SOLUTION: You need to own at least 1 NFT from contract:", nftContract);
            } else if (keccak256(bytes(reason)) == keccak256("Low BONE")) {
                console.log("SOLUTION: Your BONE balance is too low. You need at least:", entryFeeBone);
                console.log("Your current balance:", walletBONEBalanceAfterFailure);
            } else if (keccak256(bytes(reason)) == keccak256("Not active")) {
                console.log("SOLUTION: The current round is not active. Wait for it to complete.");
            } else if (keccak256(bytes(reason)) == keccak256("Round full")) {
                console.log("SOLUTION: The current round is full. Wait for the next round.");
            }
            
            revert(reason);
        } catch {
            // Get wallet balances after failed transaction to account for gas costs
            uint256 walletETHBalanceAfterFailure = sender.balance;
            uint256 walletBONEBalanceAfterFailure = boneToken.balanceOf(sender);
            uint256 gasCostFromFailure = walletETHBalanceBefore - walletETHBalanceAfterFailure;
            
            console.log("=== TRANSACTION FAILED WITH UNKNOWN ERROR ===");
            console.log("BONE balance before:", walletBONEBalanceBefore);
            console.log("BONE balance after failure:", walletBONEBalanceAfterFailure);
            console.log("ETH balance before:", walletETHBalanceBefore);
            console.log("ETH balance after failure:", walletETHBalanceAfterFailure);
            console.log("Gas cost from failed transaction:", gasCostFromFailure);
            console.log("This might be due to:");
            console.log("1. Contract is paused");
            console.log("2. Insufficient gas limit");
            console.log("3. Token transfer failed");
            console.log("4. Reentrancy protection triggered");
            revert("Unknown error occurred");
        }
        
        vm.stopBroadcast();
    }
    
    /**
     * @dev Helper function to check contract state before entering
     */
    // function checkContractState() external view {
    //     VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
    //     IERC20 boneToken = IERC20(BONE_TOKEN);
        
    //     console.log("=== CONTRACT STATE CHECK ===");
    //     console.log("Lottery contract:", LOTTERY_CONTRACT);
    //     console.log("BONE token contract:", BONE_TOKEN);
    //     console.log("Current round ID:", lottery.currentRoundId());
        
    //     (
    //         uint256 playerCount, 
    //         VRFLottery.RoundState roundState, 
    //         address[3] memory winners, 
    //         uint256 totalPrizePool, 
    //         uint256 startTime
    //     ) = lottery.getRoundInfo(lottery.currentRoundId());
            
    //     console.log("Players in current round:", playerCount);
    //     console.log("Round state:", uint256(roundState));
    //     console.log("Total prize pool:", totalPrizePool);
    //     console.log("Round start time:", startTime);
        
    //     // Display winners if any
    //     bool hasWinners = false;
    //     for (uint i = 0; i < 3; i++) {
    //         if (winners[i] != address(0)) {
    //             console.log("Winner", i + 1, ":", winners[i]);
    //             hasWinners = true;
    //         }
    //     }
    //     if (!hasWinners) {
    //         console.log("No winners selected yet");
    //     }
        
    //     // Check entry fee
    //     uint256 entryFee = lottery.ENTRY_FEE_BONE();
    //     console.log("=== ENTRY REQUIREMENTS ===");
    //     console.log("Entry fee (BONE):", entryFee);
    //     console.log("Entry fee (in tokens):", entryFee / 1e18);
        
    //     // Get total supply and basic token info
    //     console.log("=== BONE TOKEN INFO ===");
    //     console.log("BONE token address:", BONE_TOKEN);
    //     console.log("BONE token name:", boneToken.name());
    //     console.log("BONE token symbol:", boneToken.symbol());
    //     console.log("BONE token decimals:", boneToken.decimals());
    // }
    
    /**
     * @dev Helper function to check wallet balance without making any transactions
     */
    function checkWalletBalance() external view {
        uint256 privateKey = vm.envUint("ENTER_PRIVATE_KEY");
        address sender = vm.addr(privateKey);
        IERC20 boneToken = IERC20(BONE_TOKEN);
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        
        console.log("=== WALLET BALANCE CHECK ===");
        console.log("Wallet address:", sender);
        console.log("Current ETH balance:", sender.balance);
        console.log("Current ETH balance (in ETH):", sender.balance / 1e18);
        console.log("Current BONE balance:", boneToken.balanceOf(sender));
        console.log("Current BONE balance (in tokens):", boneToken.balanceOf(sender) / 1e18);
        
        // Check allowance
        uint256 currentAllowance = boneToken.allowance(sender, LOTTERY_CONTRACT);
        console.log("=== APPROVAL STATUS ===");
        console.log("Current BONE allowance:", currentAllowance);
        console.log("Current allowance (in tokens):", currentAllowance / 1e18);
        
        // Check if wallet can afford entry
        uint256 entryFee = lottery.ENTRY_FEE_BONE();
        bool hasEnoughBone = boneToken.balanceOf(sender) >= entryFee;
        bool hasApproval = currentAllowance >= entryFee;
        
        console.log("=== ENTRY READINESS ===");
        console.log("Required BONE:", entryFee);
        console.log("Has enough BONE:", hasEnoughBone ? "YES" : "NO");
        console.log("Has approval:", hasApproval ? "YES" : "NO");
        console.log("Ready to enter:", (hasEnoughBone && hasApproval) ? "YES" : "NO");
        
        if (!hasEnoughBone) {
            uint256 shortfall = entryFee - boneToken.balanceOf(sender);
            console.log("BONE needed:", shortfall);
            console.log("BONE needed (in tokens):", shortfall / 1e18);
        }
        
        if (!hasApproval) {
            console.log("Need to approve BONE before entering!");
            console.log("Approval needed:", entryFee - currentAllowance);
        }
        
        // Check NFT ownership
        address nftContract = address(lottery.nftContract());
        IERC721 nft = IERC721(nftContract);
        uint256 nftBalance = nft.balanceOf(sender);
        console.log("=== NFT STATUS ===");
        console.log("NFT contract:", nftContract);
        console.log("NFT balance:", nftBalance);
        console.log("Has required NFT:", nftBalance > 0 ? "YES" : "NO");
    }
    
    /**
     * @dev Helper function to approve BONE tokens separately
     */
    function approveBone() external {
        uint256 privateKey = vm.envUint("ENTER_PRIVATE_KEY");
        address sender = vm.addr(privateKey);
        
        vm.startBroadcast(privateKey);
        
        IERC20 boneToken = IERC20(BONE_TOKEN);
        VRFLottery lottery = VRFLottery(LOTTERY_CONTRACT);
        uint256 entryFee = lottery.ENTRY_FEE_BONE();
        
        console.log("=== APPROVING BONE TOKENS ===");
        console.log("Sender:", sender);
        console.log("Spender (Lottery):", LOTTERY_CONTRACT);
        console.log("Amount to approve:", entryFee);
        
        // Check current allowance
        uint256 currentAllowance = boneToken.allowance(sender, LOTTERY_CONTRACT);
        console.log("Current allowance:", currentAllowance);
        
        if (currentAllowance >= entryFee) {
            console.log("Already have sufficient approval!");
        } else {
            // Reset to 0 first if needed
            if (currentAllowance > 0) {
                console.log("Resetting allowance to 0...");
                boneToken.approve(LOTTERY_CONTRACT, 0);
            }
            
            // Approve entry fee
            console.log("Approving", entryFee, "BONE...");
            boneToken.approve(LOTTERY_CONTRACT, entryFee);
            
            // Verify
            uint256 newAllowance = boneToken.allowance(sender, LOTTERY_CONTRACT);
            console.log("New allowance:", newAllowance);
            console.log("Approval successful:", newAllowance >= entryFee ? "YES" : "NO");
        }
        
        vm.stopBroadcast();
    }
}