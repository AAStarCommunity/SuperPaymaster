// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title DeployNewGTokenStaking
 * @notice Deploy GTokenStaking v2.0.0 with new GToken address
 */
contract DeployNewGTokenStaking is Script {
    function run() external {
        address gtoken = vm.envAddress("GTOKEN");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying GTokenStaking v2.0.0 ===");
        console.log("GToken:", gtoken);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking staking = new GTokenStaking(gtoken);

        vm.stopBroadcast();

        console.log();
        console.log("=== Deployment Complete ===");
        console.log("GTokenStaking:", address(staking));
        console.log();
        console.log("Verifying VERSION interface...");
        console.log("VERSION:", staking.VERSION());
        console.log("VERSION_CODE:", staking.VERSION_CODE());
        console.log("GTOKEN:", staking.GTOKEN());
    }
}
