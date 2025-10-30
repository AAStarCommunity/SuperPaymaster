// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/Registry.sol";

/**
 * @title DeployRegistry_v2_1_3
 * @notice Deploy Registry v2.1.3 with transferCommunityOwnership
 */
contract DeployRegistry_v2_1_3 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address gtokenStaking = vm.envAddress("GTOKEN_STAKING");

        console.log("=== Deploy Registry v2.1.3 ===");
        console.log("GTokenStaking:", gtokenStaking);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        Registry registry = new Registry(gtokenStaking);

        vm.stopBroadcast();

        console.log("Registry v2.1.3 deployed:", address(registry));
        console.log();
        console.log("New features:");
        console.log("- transferCommunityOwnership (EOA -> Gnosis Safe)");
        console.log("- InvalidParameter error for validation");
        console.log("- CommunityOwnershipTransferred event");
    }
}
