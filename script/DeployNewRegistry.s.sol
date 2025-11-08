// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/Registry.sol";

/**
 * @title DeployNewRegistry
 * @notice Deploy Registry v2.1.3 with new GTokenStaking address
 */
contract DeployNewRegistry is Script {
    function run() external {
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying Registry v2.1.3 ===");
        console.log("GTokenStaking:", gtokenStaking);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        Registry registry = new Registry(gtokenStaking);

        vm.stopBroadcast();

        console.log();
        console.log("=== Deployment Complete ===");
        console.log("Registry:", address(registry));
        console.log();
        console.log("Verifying VERSION interface...");
        console.log("VERSION:", registry.VERSION());
        console.log("VERSION_CODE:", registry.VERSION_CODE());
        console.log("GTOKEN_STAKING:", address(registry.GTOKEN_STAKING()));
    }
}
