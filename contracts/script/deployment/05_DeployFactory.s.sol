// SPDX-License-Identifier: MIT
// 05_DeployFactory.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsFactory.sol";

contract Deploy05_Factory is Script {
    function run(address registryAddr) external {
        require(registryAddr != address(0), "Registry address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying xPNTsFactory with account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy factory with a placeholder for SuperPaymaster address
        xPNTsFactory factory = new xPNTsFactory(address(0), registryAddr);

        vm.stopBroadcast();

        console.log("xPNTsFactory deployed to:", address(factory));
    }
}
