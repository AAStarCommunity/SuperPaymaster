// SPDX-License-Identifier: MIT
// 12_DeployFactoryAndImpl.s.sol
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "src/paymasters/v4/PaymasterV4_1i.sol";

contract Deploy12_FactoryAndImpl is Script {
    function run() external {
        uint256 anniPrivateKey = vm.envUint("PRIVATE_KEY_ANNI");
        address deployer = vm.addr(anniPrivateKey);
        console.log("Deploying Factory & Impl with account (Anni):", deployer);

        vm.startBroadcast(anniPrivateKey);

        // 1. Deploy Factory
        PaymasterFactory factory = new PaymasterFactory();
        console.log("PaymasterFactory deployed to:", address(factory));

        // 2. Deploy Implementation (No args in constructor)
        PaymasterV4_1i implementation = new PaymasterV4_1i();
        console.log("PaymasterV4_1i (Impl) deployed to:", address(implementation));

        // 3. Register Impl
        factory.addImplementation("v4.1", address(implementation));
        console.log("Registered v4.1 implementation in Factory.");

        vm.stopBroadcast();
    }
}
