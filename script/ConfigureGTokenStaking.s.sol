// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title ConfigureGTokenStaking
 * @notice Configure GTokenStaking with Registry as authorized locker
 */
contract ConfigureGTokenStaking is Script {
    function run() external {
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");
        address registry = vm.envAddress("REGISTRY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Configuring GTokenStaking ===");
        console.log("GTokenStaking:", gtokenStaking);
        console.log("Registry:", registry);
        console.log();

        GTokenStaking staking = GTokenStaking(gtokenStaking);

        vm.startBroadcast(deployerPrivateKey);

        // Authorize Registry as locker
        console.log("Authorizing Registry as locker...");

        // Configure Registry locker (100 = 1%, minExitFee = 0.01 GT, maxFeePercent = 500 = 5%)
        uint256[] memory timeTiers = new uint256[](3);
        timeTiers[0] = 7 days;
        timeTiers[1] = 30 days;
        timeTiers[2] = 90 days;

        uint256[] memory tierFees = new uint256[](4);
        tierFees[0] = 300; // 3% for < 7 days
        tierFees[1] = 200; // 2% for 7-30 days
        tierFees[2] = 100; // 1% for 30-90 days
        tierFees[3] = 50;  // 0.5% for > 90 days

        staking.configureLocker(
            registry,
            true,                   // authorized
            200,                    // feeRateBps (2%)
            0.01 ether,             // minExitFee
            500,                    // maxFeePercent (5%)
            timeTiers,
            tierFees,
            address(0)              // use default treasury
        );

        vm.stopBroadcast();

        console.log();
        console.log("=== Configuration Complete ===");
        console.log("Registry authorized as locker");
    }
}
