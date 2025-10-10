// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/MockUSDT.sol";
import "../src/SimpleAccountFactory.sol";
import { IEntryPoint } from "../src/vendor/account-abstraction/contracts/interfaces/IEntryPoint.sol";

/// @title DeployTestContracts
/// @notice Deploy Mock USDT and SimpleAccountFactory for testing
contract DeployTestContracts is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying with:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Mock USDT
        MockUSDT usdt = new MockUSDT();
        console.log("MockUSDT deployed at:", address(usdt));

        // Deploy SimpleAccountFactory
        IEntryPoint entryPoint = IEntryPoint(0x0000000071727De22E5E9d8BAf0edAc6f37da032); // EntryPoint v0.7
        SimpleAccountFactory factory = new SimpleAccountFactory(entryPoint);
        console.log("SimpleAccountFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // Save deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("MockUSDT:", address(usdt));
        console.log("SimpleAccountFactory:", address(factory));
        console.log("EntryPoint:", address(entryPoint));
    }
}
