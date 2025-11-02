// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title ConfigureRegistryLocker
 * @notice Configure Registry v2.1.4 as authorized locker in GTokenStaking
 *
 * Usage:
 * forge script script/ConfigureRegistryLocker.s.sol:ConfigureRegistryLocker \
 *   --rpc-url $SEPOLIA_RPC_URL \
 *   --private-key $DEPLOYER_PRIVATE_KEY \
 *   --broadcast --legacy
 */
contract ConfigureRegistryLocker is Script {
    // Sepolia deployed contract addresses
    address constant GTOKEN_STAKING = 0x60Bd54645b0fDabA1114B701Df6f33C4ecE87fEa;
    address constant REGISTRY_V2_1_4 = 0xf384c592D5258c91805128291c5D4c069DD30CA6;

    // Locker configuration parameters
    bool constant AUTHORIZED = true;
    uint256 constant FEE_RATE_BPS = 0;          // 0% base fee for Registry
    uint256 constant MIN_EXIT_FEE = 0;          // No minimum exit fee for Registry
    uint256 constant MAX_FEE_PERCENT = 0;       // No max fee for Registry

    // Fee recipient (deployer address)
    address constant FEE_RECIPIENT = 0x411BD567E46C0781248dbB6a9211891C032885e5;

    function run() external {
        console.log("================================================");
        console.log("   Configuring Registry v2.1.4 as Locker");
        console.log("================================================");

        console.log("\nContract Addresses:");
        console.log("  GTokenStaking:", GTOKEN_STAKING);
        console.log("  Registry v2.1.4:", REGISTRY_V2_1_4);
        console.log("  Fee Recipient:", FEE_RECIPIENT);

        console.log("\nLocker Configuration:");
        console.log("  Authorized:", AUTHORIZED);
        console.log("  Base Fee Rate (bps):", FEE_RATE_BPS);
        console.log("  Min Exit Fee (GT):", MIN_EXIT_FEE);
        console.log("  Max Fee Percent (bps):", MAX_FEE_PERCENT);

        // Start broadcasting transactions
        vm.startBroadcast();

        GTokenStaking gTokenStaking = GTokenStaking(GTOKEN_STAKING);

        console.log("\nCalling configureLocker...");
        gTokenStaking.configureLocker(
            REGISTRY_V2_1_4,
            AUTHORIZED,
            FEE_RATE_BPS,
            MIN_EXIT_FEE,
            MAX_FEE_PERCENT,
            new uint256[](0),  // No time tiers for Registry
            new uint256[](0),  // No tier fees for Registry
            FEE_RECIPIENT
        );

        vm.stopBroadcast();

        console.log("\n================================================");
        console.log("   Configuration Complete!");
        console.log("================================================");
        console.log("\nRegistry v2.1.4 is now authorized as a locker");
        console.log("Users can now register communities via Registry");

        // Verify configuration
        console.log("\nVerifying configuration...");
        GTokenStaking.LockerConfig memory config = gTokenStaking.getLockerConfig(REGISTRY_V2_1_4);

        console.log("  Authorized:", config.authorized);
        console.log("  Fee Rate (bps):", config.feeRateBps);
        console.log("  Min Exit Fee (GT):", config.minExitFee);
        console.log("  Max Fee Percent (bps):", config.maxFeePercent);
        console.log("  Fee Recipient:", config.feeRecipient);

        require(config.authorized == AUTHORIZED, "Authorization mismatch");
        require(config.feeRateBps == FEE_RATE_BPS, "Fee rate mismatch");
        require(config.minExitFee == MIN_EXIT_FEE, "Min exit fee mismatch");
        require(config.maxFeePercent == MAX_FEE_PERCENT, "Max fee percent mismatch");
        require(config.feeRecipient == FEE_RECIPIENT, "Fee recipient mismatch");

        console.log("\nVerification passed!");
    }
}
