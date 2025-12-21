// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title DeployGTokenStaking_v2
 * @notice Deploy GTokenStaking v2 with permissionless stake additions
 */
contract DeployGTokenStaking_v2 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address gtoken = vm.envAddress("GTOKEN");
        address treasury = vm.envAddress("TREASURY");

        console.log("=== Deploy GTokenStaking v2 ===");
        console.log("GToken:", gtoken);
        console.log("Treasury:", treasury);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking staking = new GTokenStaking(gtoken);

        // Set treasury
        staking.setTreasury(treasury);

        vm.stopBroadcast();

        console.log("GTokenStaking v2 deployed:", address(staking));
        console.log("Treasury set to:", treasury);
        console.log();
        console.log("Changes:");
        console.log("- Removed AlreadyStaked restriction");
        console.log("- Support multiple stake additions");
        console.log("- Auto-reset unstake request on new stake");
    }
}
