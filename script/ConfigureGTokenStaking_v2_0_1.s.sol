// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/GTokenStaking_v2_0_1.sol";

/**
 * @title Configure GTokenStaking v2.0.1
 * @notice Configure MySBT v2.4.1 as authorized locker
 */
contract ConfigureGTokenStaking_v2_0_1 is Script {
    address constant GTOKENSTAKING = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0; // v2.0.1
    address constant MYSBT_V2_4_1 = 0x02dbB53442631398473862b757B703688860205a; // NEW MySBT v2.4.1

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("========================================");
        console.log("Configuring GTokenStaking v2.0.1");
        console.log("========================================");
        console.log("Deployer:", deployer);
        console.log("GTokenStaking:", GTOKENSTAKING);
        console.log("MySBT to authorize:", MYSBT_V2_4_1);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking gtokenStaking = GTokenStaking(GTOKENSTAKING);

        // Configure MySBT as authorized locker
        // Parameters: authorized=true, feeRate=1%, minFee=0.01 GT, maxFee=5%
        uint256[] memory timeTiers = new uint256[](0); // No time tiers
        uint256[] memory tierFees = new uint256[](0); // No tier fees

        gtokenStaking.configureLocker(
            MYSBT_V2_4_1,           // locker address
            true,                    // authorized
            100,                     // feeRateBps (1% = 100 basis points)
            0.01 ether,             // minExitFee (0.01 GT)
            500,                     // maxFeePercent (5% = 500 basis points)
            timeTiers,              // No time-based tiers
            tierFees,               // No tier-specific fees
            MYSBT_V2_4_1            // feeRecipient (fees go to MySBT)
        );

        vm.stopBroadcast();

        console.log("========================================");
        console.log("Configuration Complete");
        console.log("========================================");
        console.log("MySBT v2.4.1 is now authorized locker");
        console.log("");
    }
}
