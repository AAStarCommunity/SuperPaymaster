// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";

contract InitializeV3Roles is Script {
    // Sepolia Addresses (from script/v3/config.json)
    // Double check these match your deployment
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        address gTokenAddr = vm.envAddress("GTOKEN_ADDRESS");

        console.log("=== Initialize Resources (V3) ===");
        console.log("Deployer:", deployer);
        console.log("GToken:", gTokenAddr);

        GToken gtoken = GToken(gTokenAddr);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Mint initial GToken to Deployer for testing
        // Regression tests distribute tokens from Deployer to test accounts
        uint256 balance = gtoken.balanceOf(deployer);
        console.log("Current Deployer Balance:", balance);

        // Ensure we have at least 1,000,000 GToken
        if (balance < 1000000 ether) {
            try gtoken.mint(deployer, 1000000 ether) {
                console.log("Minted 1,000,000 GToken to deployer.");
            } catch {
                console.log("Failed to mint GToken (Are you Owner?)");
            }
        } else {
            console.log("Deployer has sufficient GToken.");
        }

        vm.stopBroadcast();
        console.log("=== Initialization Complete ===");
    }
}
