// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title ConfigureLockers_v2
 * @notice Configure MySBT, SuperPaymasterV2, and Registry as authorized lockers
 *
 * @dev This script configures three lockers for GTokenStaking:
 *   1. MySBT v2.4.3 - Simple flat fee (1%)
 *   2. SuperPaymasterV2 v2.0.1 - Time-based percentage fees
 *   3. Registry v2.2.0 - Moderate fee for community registration
 *
 * @dev Usage:
 *   forge script script/ConfigureLockers_v2.s.sol:ConfigureLockers_v2 \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract ConfigureLockers_v2 is Script {

    // Sepolia testnet addresses (2025-11-08 deployment)
    address constant GTOKEN_STAKING = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0;  // v2.0.1
    address constant MYSBT = 0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C;              // v2.4.3
    address constant SUPER_PAYMASTER_V2 = 0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC;  // v2.0.1 (2025-11-08)
    address constant REGISTRY = 0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75;           // v2.2.0 (2025-11-08)

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("================================================================================");
        console.log("=== Configuring GTokenStaking Lockers (v2 Update) ===");
        console.log("================================================================================");
        console.log("GTokenStaking:       ", GTOKEN_STAKING);
        console.log("MySBT v2.4.3:        ", MYSBT);
        console.log("SuperPaymaster v2.0.1:", SUPER_PAYMASTER_V2);
        console.log("Registry v2.2.0:      ", REGISTRY);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking staking = GTokenStaking(GTOKEN_STAKING);

        // 1. MySBT locker: Simple 1% fee
        console.log("1. Configuring MySBT v2.4.3 locker...");
        console.log("   - Authorization: true");
        console.log("   - Fee Rate: 1% (100 bps)");
        console.log("   - Min Exit Fee: 0.01 GT");
        console.log("   - Max Fee: 5%");

        staking.configureLocker(
            MYSBT,
            true,                // authorized
            100,                 // feeRateBps (1%)
            0.01 ether,          // minExitFee
            500,                 // maxFeePercent (5%)
            new uint256[](0),    // timeTiers (no time-based tiers)
            new uint256[](0),    // tierFees (no tier fees)
            address(0)           // feeRecipient (use default treasury)
        );
        console.log("   \u2713 MySBT locker configured");
        console.log("");

        // 2. SuperPaymasterV2 locker: Time-based percentage fees
        console.log("2. Configuring SuperPaymasterV2 v2.0.1 locker...");
        console.log("   - Authorization: true");
        console.log("   - Base Fee Rate: 1% (100 bps)");
        console.log("   - Min Exit Fee: 0.01 GT");
        console.log("   - Max Fee: 5%");
        console.log("   - Time-based tiers:");
        console.log("     < 7 days:    5%");
        console.log("     7-30 days:   4%");
        console.log("     30-90 days:  3%");
        console.log("     90-180 days: 2%");
        console.log("     > 180 days:  1%");

        uint256[] memory timeTiers = new uint256[](4);
        timeTiers[0] = 7 days;      // 1 week
        timeTiers[1] = 30 days;     // 1 month
        timeTiers[2] = 90 days;     // 3 months
        timeTiers[3] = 180 days;    // 6 months

        uint256[] memory tierFees = new uint256[](5);  // length = timeTiers.length + 1
        tierFees[0] = 500;          // 5% for < 7 days
        tierFees[1] = 400;          // 4% for 7-30 days
        tierFees[2] = 300;          // 3% for 30-90 days
        tierFees[3] = 200;          // 2% for 90-180 days
        tierFees[4] = 100;          // 1% for > 180 days

        staking.configureLocker(
            SUPER_PAYMASTER_V2,
            true,                // authorized
            100,                 // feeRateBps (1% base)
            0.01 ether,          // minExitFee
            500,                 // maxFeePercent (5%)
            timeTiers,
            tierFees,
            address(0)           // feeRecipient (use default treasury)
        );
        console.log("   \u2713 SuperPaymasterV2 locker configured");
        console.log("");

        // 3. Registry locker: Moderate fee for community registration
        console.log("3. Configuring Registry v2.2.0 locker...");
        console.log("   - Authorization: true");
        console.log("   - Fee Rate: 2% (200 bps)");
        console.log("   - Min Exit Fee: 0.05 GT");
        console.log("   - Max Fee: 10%");

        staking.configureLocker(
            REGISTRY,
            true,                // authorized
            200,                 // feeRateBps (2% - higher for communities)
            0.05 ether,          // minExitFee (higher for communities)
            1000,                // maxFeePercent (10% - allow higher fees for community exits)
            new uint256[](0),    // timeTiers (no time-based tiers)
            new uint256[](0),    // tierFees (no tier fees)
            address(0)           // feeRecipient (use default treasury)
        );
        console.log("   \u2713 Registry locker configured");
        console.log("");

        vm.stopBroadcast();

        console.log("================================================================================");
        console.log("=== CONFIGURATION COMPLETE ===");
        console.log("================================================================================");
        console.log("");
        console.log("Summary:");
        console.log("  - MySBT:             1% flat fee");
        console.log("  - SuperPaymasterV2:  1-5% time-based fee");
        console.log("  - Registry:          2% flat fee (higher for communities)");
        console.log("");
        console.log("Next Steps:");
        console.log("  1. Verify locker configurations:");
        console.log("     cast call", GTOKEN_STAKING, '"lockerConfigs(address)" <locker_address>');
        console.log("  2. Test lock/unlock operations");
        console.log("  3. Monitor locker activity");
        console.log("================================================================================");
    }
}
