// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/tokens/MySBT_v2.3.3.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";
import "../src/paymasters/v2/core/Registry.sol";

/**
 * @title TestMySBTExitFlow
 * @notice Test complete mint → burn → verify exitFee flow
 */
contract TestMySBTExitFlow is Script {
    function run() external {
        uint256 userPrivateKey = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(userPrivateKey);

        address mysbtAddress = vm.envAddress("MYSBT");
        address gtokenStakingAddress = vm.envAddress("GTOKEN_STAKING");
        address gtokenAddress = vm.envAddress("GTOKEN");
        address registryAddress = vm.envAddress("REGISTRY");
        address treasury = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

        console.log("=== Test MySBT Exit Flow ===");
        console.log("User:", user);
        console.log("MySBT:", mysbtAddress);
        console.log("GTokenStaking:", gtokenStakingAddress);
        console.log("GToken:", gtokenAddress);
        console.log("Registry:", registryAddress);
        console.log("Treasury:", treasury);
        console.log();

        MySBT_v2_3_3 mysbt = MySBT_v2_3_3(mysbtAddress);
        GTokenStaking staking = GTokenStaking(gtokenStakingAddress);
        IERC20 gtoken = IERC20(gtokenAddress);
        Registry registry = Registry(registryAddress);

        // Check if user already has an SBT
        uint256 existingTokenId = mysbt.getUserSBT(user);
        if (existingTokenId > 0) {
            console.log("[SKIP] User already has SBT #", existingTokenId);
            console.log("Proceeding to burn test...");
            console.log();
        } else {
            // Step 1: Check if user is a registered community
            bool isRegistered = registry.isRegisteredCommunity(user);
            if (!isRegistered) {
                console.log("[ERROR] User is not a registered community");
                console.log("Please register as a community first using Registry.registerCommunity()");
                return;
            }
            console.log("[OK] User is a registered community");

            // Step 2: Prepare to mint SBT (requires 0.3 stGT + 0.1 GT burn)
            console.log();
            console.log("=== Step 1: Mint SBT ===");

            uint256 userGTokenBalance = gtoken.balanceOf(user);
            uint256 userStakedBalance = staking.balanceOf(user);

            console.log("User GT balance:", userGTokenBalance);
            console.log("User staked balance:", userStakedBalance);

            uint256 minLockAmount = mysbt.minLockAmount(); // 0.3 ether
            uint256 mintFee = mysbt.mintFee(); // 0.1 ether

            console.log("Required stGT for lock:", minLockAmount);
            console.log("Required GT for burn:", mintFee);

            if (userStakedBalance < minLockAmount) {
                console.log("[ERROR] Insufficient staked balance");
                console.log("User needs to stake at least", minLockAmount, "stGT");
                return;
            }

            if (userGTokenBalance < mintFee) {
                console.log("[ERROR] Insufficient GT balance for mint fee");
                console.log("User needs at least", mintFee, "GT");
                return;
            }

            // Step 3: Mint SBT
            vm.startBroadcast(userPrivateKey);

            (uint256 newTokenId, bool isNewMint) = mysbt.mintOrAddMembership(user, "");

            vm.stopBroadcast();

            console.log("[OK] SBT minted!");
            console.log("Token ID:", newTokenId);
            console.log("Is new mint:", isNewMint);
            console.log();
        }

        // Step 4: Check state before burn
        console.log("=== Step 2: Check state before burn ===");

        uint256 tokenId = mysbt.getUserSBT(user);
        uint256 userStakedBefore = staking.balanceOf(user);
        uint256 treasuryBalanceBefore = gtoken.balanceOf(treasury);
        uint256 userGTokenBefore = gtoken.balanceOf(user);

        console.log("User SBT token ID:", tokenId);
        console.log("User staked balance (before):", userStakedBefore);
        console.log("Treasury balance (before):", treasuryBalanceBefore);
        console.log("User GT balance (before):", userGTokenBefore);
        console.log();

        // Step 5: Burn SBT
        console.log("=== Step 3: Burn SBT ===");

        vm.startBroadcast(userPrivateKey);

        uint256 netAmount = mysbt.burnSBT();

        vm.stopBroadcast();

        console.log("[OK] SBT burned!");
        console.log("Net amount returned:", netAmount);
        console.log();

        // Step 6: Verify results
        console.log("=== Step 4: Verify results ===");

        uint256 userStakedAfter = staking.balanceOf(user);
        uint256 treasuryBalanceAfter = gtoken.balanceOf(treasury);
        uint256 userGTokenAfter = gtoken.balanceOf(user);
        uint256 tokenIdAfter = mysbt.getUserSBT(user);

        console.log("User SBT token ID (after):", tokenIdAfter);
        console.log("User staked balance (after):", userStakedAfter);
        console.log("Treasury balance (after):", treasuryBalanceAfter);
        console.log("User GT balance (after):", userGTokenAfter);
        console.log();

        // Calculate differences
        uint256 stakedDiff = userStakedAfter > userStakedBefore
            ? userStakedAfter - userStakedBefore
            : userStakedBefore - userStakedAfter;
        uint256 treasuryDiff = treasuryBalanceAfter - treasuryBalanceBefore;
        uint256 userGTokenDiff = userGTokenAfter - userGTokenBefore;

        console.log("=== Verification ===");
        console.log("User received (GT):", userGTokenDiff);
        console.log("Treasury received (GT):", treasuryDiff);
        console.log("Expected user return: 0.2 GT (200000000000000000)");
        console.log("Expected treasury fee: 0.1 GT (100000000000000000)");
        console.log();

        // Validate
        bool success = true;

        if (tokenIdAfter != 0) {
            console.log("[FAIL] SBT was not burned properly");
            success = false;
        } else {
            console.log("[PASS] SBT burned successfully");
        }

        if (userGTokenDiff == 0.2 ether) {
            console.log("[PASS] User received correct amount (0.2 GT)");
        } else {
            console.log("[FAIL] User received incorrect amount:", userGTokenDiff);
            success = false;
        }

        if (treasuryDiff == 0.1 ether) {
            console.log("[PASS] Treasury received correct fee (0.1 GT)");
        } else {
            console.log("[FAIL] Treasury received incorrect fee:", treasuryDiff);
            success = false;
        }

        console.log();
        if (success) {
            console.log("====================================");
            console.log("[SUCCESS] All tests passed!");
            console.log("====================================");
        } else {
            console.log("====================================");
            console.log("[FAILURE] Some tests failed");
            console.log("====================================");
        }
    }
}
