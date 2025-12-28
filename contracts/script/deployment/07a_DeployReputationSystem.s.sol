// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/modules/reputation/ReputationSystemV3.sol";

contract DeployReputationSystem is Script {
    function run(address registryAddr) external {
        require(registryAddr != address(0), "Registry address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying ReputationSystemV3 with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        ReputationSystemV3 repSystem = new ReputationSystemV3(registryAddr);

        vm.stopBroadcast();

        console.log("ReputationSystemV3 deployed to:", address(repSystem));
    }
}
