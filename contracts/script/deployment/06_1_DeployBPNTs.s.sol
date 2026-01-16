// SPDX-License-Identifier: MIT
// 06_1_DeployBPNTs.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsFactory.sol";

contract Deploy06_1_BPNTs is Script {
    function run(address factoryAddr) external {
        require(factoryAddr != address(0), "Factory address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_ANNI");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying bPNTs via Factory with account (Anni):", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy bPNTs using Anni's key
        address mockToken = xPNTsFactory(factoryAddr).deployxPNTsToken(
            "BreadCommunity PNT B",
            "bPNTs",
            "BreadCommunity",
            "breadcommunity.eth",
            1e18, // 1:1 exchange rate
            address(0) // No AOA paymaster linked yet
        );

        vm.stopBroadcast();

        console.log("Community Token (bPNTs) deployed to:", mockToken);
    }
}
