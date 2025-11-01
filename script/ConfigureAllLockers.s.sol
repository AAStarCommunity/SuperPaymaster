// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title ConfigureAllLockers
 * @notice Configure MySBT and SuperPaymaster as lockers in GTokenStaking
 */
contract ConfigureAllLockers is Script {

    address constant GTOKEN_STAKING = 0x7b0bb7D5a5bf7A5839A6e6B53bDD639865507A69;
    address constant MYSBT = 0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920;
    address constant SUPER_PAYMASTER_V2 = 0xB97A20aca3D6770Deca299a1aD9DAFb12d1e5eCf;

    function run() external {
        console.log("=== Configuring GTokenStaking Lockers ===");
        console.log("");

        vm.startBroadcast();

        GTokenStaking staking = GTokenStaking(GTOKEN_STAKING);

        // MySBT locker: 1% fee, 0.01 GT min exit fee
        console.log("Configuring MySBT locker...");
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
        console.log("  MySBT locker configured");
        console.log("");

        // SuperPaymaster locker: time-based percentage fees
        console.log("Configuring SuperPaymaster locker...");
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
        console.log("  SuperPaymaster locker configured");
        console.log("");

        vm.stopBroadcast();

        console.log("====================================");
        console.log("CONFIGURATION COMPLETE");
        console.log("====================================");
    }
}
