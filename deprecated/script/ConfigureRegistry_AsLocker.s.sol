// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v2/core/GTokenStaking_v2_0_1.sol";

/**
 * @title Configure Registry as Authorized Locker
 * @notice Configure Registry v2.1.4 as authorized locker in GTokenStaking v2.0.1
 */
contract ConfigureRegistry_AsLocker is Script {
    address constant GTOKENSTAKING = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0; // v2.0.1
    address constant REGISTRY = 0xf384c592D5258c91805128291c5D4c069DD30CA6; // Registry v2.1.4

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========================================");
        console.log("Configuring Registry as Authorized Locker");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("GTokenStaking:", GTOKENSTAKING);
        console.log("Registry:", REGISTRY);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking gtokenStaking = GTokenStaking(GTOKENSTAKING);

        // Configure Registry as authorized locker
        // Parameters: authorized=true, feeRate=1%, minFee=0.01 GT, maxFee=5%
        uint256[] memory timeTiers = new uint256[](0); // No time tiers
        uint256[] memory tierFees = new uint256[](0); // No tier fees

        gtokenStaking.configureLocker(
            REGISTRY,                // locker address
            true,                    // authorized
            100,                     // feeRateBps (1% = 100 basis points)
            0.01 ether,             // minExitFee (0.01 GT)
            500,                     // maxFeePercent (5% = 500 basis points)
            timeTiers,              // No time-based tiers
            tierFees,               // No tier-specific fees
            REGISTRY                // feeRecipient (fees go to Registry)
        );

        vm.stopBroadcast();

        console.log("========================================");
        console.log("Configuration Complete");
        console.log("========================================");
        console.log("Registry v2.1.4 is now authorized locker");
        console.log("Fee Rate: 1% (100 bps)");
        console.log("Min Exit Fee: 0.01 GT");
        console.log("Max Fee: 5% (500 bps)");
        console.log("");
        console.log("Authorized Lockers:");
        console.log("1. Registry: 0xf384c592D5258c91805128291c5D4c069DD30CA6");
        console.log("2. MySBT v2.4.2: 0xD20F64718485E8aA317c0f353420cdB147661b20");
        console.log("");
    }
}
