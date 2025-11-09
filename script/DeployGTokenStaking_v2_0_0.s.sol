// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title DeployGTokenStaking_v2_0_0
 * @notice Deploy GTokenStaking v2.0.0 with VERSION interface
 */
contract DeployGTokenStaking_v2_0_0 is Script {
    function run() external {
        address gToken = vm.envAddress("GTOKEN_ADDRESS");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        
        console.log("=== Deploying GTokenStaking v2.0.0 ===");
        console.log("GToken:", gToken);
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast();

        // Deploy GTokenStaking
        GTokenStaking staking = new GTokenStaking(gToken);

        vm.stopBroadcast();

        console.log("====================================");
        console.log("GTokenStaking deployed:", address(staking));
        console.log("VERSION:", staking.VERSION());
        console.log("VERSION_CODE:", staking.VERSION_CODE());
        console.log("MIN_STAKE:", staking.MIN_STAKE() / 1e18, "GT");
        console.log("UNSTAKE_DELAY:", staking.UNSTAKE_DELAY() / 1 days, "days");
        console.log("====================================");
    }
}
