// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/tokens/MySBTFactory.sol";

/**
 * @title DeployMySBTFactory
 * @notice Deployment script for MySBTFactory contract
 * @dev Deploys MySBTFactory with existing GToken and GTokenStaking addresses
 *
 * Usage:
 * forge script script/DeployMySBTFactory.s.sol:DeployMySBTFactory \
 *   --rpc-url $RPC_URL \
 *   --private-key $PRIVATE_KEY \
 *   --broadcast \
 *   --verify \
 *   --slow
 */
contract DeployMySBTFactory is Script {

    // ====================================
    // Configuration (Sepolia Testnet)
    // ====================================

    /// @notice GToken address (from .env.local)
    address constant GTOKEN = 0x54Afca294BA9824E6858E9b2d0B9a19C440f6D35;

    /// @notice GTokenStaking address (from .env.local)
    address constant GTOKEN_STAKING = 0xc3aa5816B000004F790e1f6B9C65f4dd5520c7b2;

    // ====================================
    // Deployment State
    // ====================================

    MySBTFactory public factory;

    // ====================================
    // Main Deployment
    // ====================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== MySBTFactory Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("GToken:", GTOKEN);
        console.log("GTokenStaking:", GTOKEN_STAKING);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MySBTFactory
        factory = new MySBTFactory(GTOKEN, GTOKEN_STAKING);

        vm.stopBroadcast();

        // ====================================
        // Deployment Summary
        // ====================================

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("MySBTFactory:", address(factory));
        console.log("");
        console.log("[OK] Deployment successful!");
        console.log("");
        console.log("Next steps:");
        console.log("1. Add factory address to .env.local:");
        console.log("   VITE_MYSBT_FACTORY_ADDRESS=%s", address(factory));
        console.log("2. Verify on Etherscan (if --verify didn't work):");
        console.log("   forge verify-contract %s MySBTFactory --chain-id 11155111", address(factory));
    }
}
