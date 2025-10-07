// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GasTokenFactory} from "../src/GasTokenFactory.sol";

/**
 * @title DeployGasTokenFactory
 * @notice Deploy GasTokenFactory contract
 * @dev Run: forge script script/DeployGasTokenFactory.s.sol:DeployGasTokenFactory --rpc-url sepolia --broadcast --verify
 */
contract DeployGasTokenFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy GasTokenFactory
        GasTokenFactory factory = new GasTokenFactory();

        console.log("GasTokenFactory deployed:", address(factory));
        console.log("Owner:", factory.owner());

        vm.stopBroadcast();

        console.log("\n=== Deployment Summary ===");
        console.log("GasTokenFactory:", address(factory));
        console.log("\nNext: Deploy new PNT with correct Settlement address");
    }
}
