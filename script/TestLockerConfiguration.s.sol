// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/GTokenStaking_v2_0_1.sol";

/**
 * @title Test Locker Configuration
 * @notice Verify that Registry and MySBT are configured as authorized lockers
 */
contract TestLockerConfiguration is Script {
    address constant GTOKENSTAKING = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0; // v2.0.1
    address constant REGISTRY = 0xf384c592D5258c91805128291c5D4c069DD30CA6; // Registry v2.1.4
    address constant MYSBT_V2_4_2 = 0xD20F64718485E8aA317c0f353420cdB147661b20; // MySBT v2.4.2

    function run() external view {
        console.log("========================================");
        console.log("Testing Locker Configuration");
        console.log("========================================");
        console.log("GTokenStaking:", GTOKENSTAKING);
        console.log("");

        GTokenStaking gtokenStaking = GTokenStaking(GTOKENSTAKING);

        // Test Registry locker configuration
        console.log("1. Registry Locker Configuration");
        console.log("   Address:", REGISTRY);

        (
            bool registryAuthorized,
            uint256 registryFeeRate,
            uint256 registryMinFee,
            uint256 registryMaxFeePercent,
            address registryFeeRecipient
        ) = gtokenStaking.lockerConfigs(REGISTRY);

        console.log("   Authorized:", registryAuthorized);
        console.log("   Fee Rate:", registryFeeRate, "bps");
        console.log("   Min Fee:", registryMinFee / 1e18, "GT");
        console.log("   Max Fee:", registryMaxFeePercent, "bps");
        console.log("   Fee Recipient:", registryFeeRecipient);
        console.log("");

        // Test MySBT locker configuration
        console.log("2. MySBT v2.4.2 Locker Configuration");
        console.log("   Address:", MYSBT_V2_4_2);

        (
            bool mysbtAuthorized,
            uint256 mysbtFeeRate,
            uint256 mysbtMinFee,
            uint256 mysbtMaxFeePercent,
            address mysbtFeeRecipient
        ) = gtokenStaking.lockerConfigs(MYSBT_V2_4_2);

        console.log("   Authorized:", mysbtAuthorized);
        console.log("   Fee Rate:", mysbtFeeRate, "bps");
        console.log("   Min Fee:", mysbtMinFee / 1e18, "GT");
        console.log("   Max Fee:", mysbtMaxFeePercent, "bps");
        console.log("   Fee Recipient:", mysbtFeeRecipient);
        console.log("");

        // Summary
        console.log("========================================");
        console.log("Test Summary");
        console.log("========================================");

        if (registryAuthorized && mysbtAuthorized) {
            console.log("SUCCESS: Both lockers are properly configured");
            console.log("");
            console.log("Authorized Lockers:");
            console.log("- Registry v2.1.4");
            console.log("- MySBT v2.4.2");
        } else {
            console.log("FAILED: Some lockers are not authorized");
            if (!registryAuthorized) {
                console.log("- Registry is NOT authorized");
            }
            if (!mysbtAuthorized) {
                console.log("- MySBT v2.4.2 is NOT authorized");
            }
        }
        console.log("");
    }
}
