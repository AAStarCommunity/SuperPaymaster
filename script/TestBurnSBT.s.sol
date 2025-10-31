// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/tokens/MySBT_v2.3.3.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title TestBurnSBT
 * @notice Simplified test for burnSBT function (assumes user has SBT)
 */
contract TestBurnSBT is Script {
    function run() external {
        uint256 userPrivateKey = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(userPrivateKey);

        address mysbtAddress = vm.envAddress("MYSBT");
        address gtokenStakingAddress = vm.envAddress("GTOKEN_STAKING");
        address gtokenAddress = vm.envAddress("GTOKEN");
        address treasury = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

        console.log("=== Test burnSBT Function ===");
        console.log("User:", user);
        console.log("MySBT:", mysbtAddress);
        console.log("GTokenStaking:", gtokenStakingAddress);
        console.log("GToken:", gtokenAddress);
        console.log("Treasury:", treasury);
        console.log();

        MySBT_v2_3_3 mysbt = MySBT_v2_3_3(mysbtAddress);
        GTokenStaking staking = GTokenStaking(gtokenStakingAddress);
        IERC20 gtoken = IERC20(gtokenAddress);

        // Check if user has an SBT
        uint256 tokenId = mysbt.getUserSBT(user);
        if (tokenId == 0) {
            console.log("[ERROR] User does not have an SBT");
            console.log("Please mint an SBT first");
            return;
        }

        console.log("[OK] User has SBT #", tokenId);
        console.log();

        // Check state before burn
        console.log("=== State before burn ===");
        uint256 userStakedBefore = staking.balanceOf(user);
        uint256 treasuryBalanceBefore = gtoken.balanceOf(treasury);
        uint256 userGTokenBefore = gtoken.balanceOf(user);

        console.log("User staked balance (before):", userStakedBefore);
        console.log("Treasury balance (before):", treasuryBalanceBefore);
        console.log("User GT balance (before):", userGTokenBefore);
        console.log();

        // Burn SBT
        console.log("=== Burning SBT ===");
        vm.startBroadcast(userPrivateKey);

        uint256 netAmount = mysbt.burnSBT();

        vm.stopBroadcast();

        console.log("[OK] SBT burned!");
        console.log("Net amount returned:", netAmount);
        console.log();

        // Verify results
        console.log("=== State after burn ===");
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
