// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v2/core/Registry.sol";

/**
 * @title DeployRegistry_v2_1_4
 * @notice Deploy Registry v2.1.4 with allowPermissionlessMint default true
 */
contract DeployRegistry_v2_1_4 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");

        console.log("=== Deploy Registry v2.1.4 ===");
        console.log("GTokenStaking:", gtokenStaking);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        Registry registry = new Registry(gtokenStaking);

        vm.stopBroadcast();

        console.log("Registry v2.1.4 deployed:", address(registry));
        console.log();
        console.log("New features:");
        console.log("- allowPermissionlessMint defaults to true on registration");
        console.log("- Communities can mint SBTs permissionlessly by default");
    }
}
