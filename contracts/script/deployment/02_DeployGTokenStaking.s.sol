// SPDX-License-Identifier: MIT
// 02_DeployGTokenStaking.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/GTokenStaking.sol";

contract Deploy02_GTokenStaking is Script {
    function run(address gTokenAddr) external {
        require(gTokenAddr != address(0), "GToken address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying GTokenStaking with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking gTokenStaking = new GTokenStaking(gTokenAddr, deployer);

        vm.stopBroadcast();

        console.log("GTokenStaking deployed to:", address(gTokenStaking));
    }
}
