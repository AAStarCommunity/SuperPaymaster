// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/GasTokenFactory.sol";
import "../src/GasToken.sol";

/**
 * @title DeployGasToken
 * @notice Deployment script for GasToken Factory and PNT base token
 *
 * Usage:
 *   forge script script/DeployGasToken.s.sol:DeployGasToken --rpc-url $RPC_URL --broadcast
 */
contract DeployGasToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address settlement = vm.envAddress("SETTLEMENT_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Factory
        GasTokenFactory factory = new GasTokenFactory();
        console.log("GasTokenFactory deployed at:", address(factory));

        // 2. Deploy base PNT token
        address pntAddress = factory.createToken(
            "Points Token",
            "PNT",
            settlement,
            1e18  // 1:1 exchange rate (base)
        );

        console.log("PNT Token deployed at:", pntAddress);
        console.log("Settlement address:", settlement);

        GasToken pnt = GasToken(pntAddress);
        console.log("PNT Exchange Rate:", pnt.exchangeRate());
        console.log("PNT Settlement:", pnt.settlement());

        vm.stopBroadcast();

        // Save deployment info
        console.log("\n=== Deployment Summary ===");
        console.log("Factory:", address(factory));
        console.log("PNT Token:", pntAddress);
        console.log("Please update .env with these addresses");
    }
}
