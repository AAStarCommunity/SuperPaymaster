// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title ConfigureSuperPaymasterLocker
 * @notice Configure SuperPaymasterV2 as authorized locker in GTokenStaking
 */
contract ConfigureSuperPaymasterLocker is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");
        address superPaymaster = vm.envAddress("SUPER_PAYMASTER");

        console.log("=== Configure SuperPaymaster as Locker ===");
        console.log("GTokenStaking:", gtokenStaking);
        console.log("SuperPaymaster:", superPaymaster);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking staking = GTokenStaking(gtokenStaking);

        // Configure time tiers: [90 days, 180 days, 365 days]
        uint256[] memory timeTiers = new uint256[](3);
        timeTiers[0] = 90 days;
        timeTiers[1] = 180 days;
        timeTiers[2] = 365 days;

        // Configure tier fees (basis points): [<90 days, 90-180 days, 180-365 days, >=365 days]
        uint256[] memory tierFees = new uint256[](4);
        tierFees[0] = 150;  // < 90 days: 1.5%
        tierFees[1] = 100;  // 90-180 days: 1%
        tierFees[2] = 70;   // 180-365 days: 0.7%
        tierFees[3] = 50;   // >= 365 days: 0.5%

        // Configure SuperPaymaster as locker with time-based fees
        staking.configureLocker(
            superPaymaster,
            true,                // authorized
            100,                 // feeRateBps (1% base)
            0.01 ether,          // minExitFee
            500,                 // maxFeePercent (5%)
            timeTiers,
            tierFees,
            address(0)           // feeRecipient (use default treasury)
        );

        vm.stopBroadcast();

        console.log("[OK] SuperPaymaster configured as authorized locker");
        console.log("  Fee structure: Time-based tiers");
        console.log("  < 90 days: 1.5%");
        console.log("  90-180 days: 1%");
        console.log("  180-365 days: 0.7%");
        console.log("  >= 365 days: 0.5%");
    }
}
