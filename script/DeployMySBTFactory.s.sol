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
    // Configuration (loaded from environment)
    // ====================================

    address public GTOKEN;
    address public GTOKEN_STAKING;

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

        // Load addresses from environment
        GTOKEN = vm.envAddress("GTOKEN_ADDRESS");
        GTOKEN_STAKING = vm.envAddress("GTOKEN_STAKING_ADDRESS");

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
