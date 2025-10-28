// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/tokens/MySBT_v2.3.sol";

/**
 * @title DeployMySBT_v2_3
 * @notice Deployment script for MySBT v2.3 - Security Enhanced Release
 * @dev Deploys MySBT v2.3 with rate limiting, NFT verification, and Pausable
 *
 * Usage:
 * forge script script/DeployMySBT_v2_3.s.sol:DeployMySBT_v2_3 \
 *   --rpc-url $SEPOLIA_RPC_URL \
 *   --private-key $DEPLOYER_PRIVATE_KEY \
 *   --broadcast \
 *   --verify \
 *   --etherscan-api-key $ETHERSCAN_API_KEY \
 *   --slow
 */
contract DeployMySBT_v2_3 is Script {

    // ====================================
    // Configuration (loaded from environment)
    // ====================================

    address public GTOKEN;
    address public GTOKEN_STAKING;
    address public REGISTRY;
    address public DAO_MULTISIG;

    // ====================================
    // Deployment State
    // ====================================

    MySBT_v2_3 public mysbt;

    // ====================================
    // Main Deployment
    // ====================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load addresses from environment
        GTOKEN = vm.envAddress("V2_GTOKEN");
        GTOKEN_STAKING = vm.envAddress("V2_GTOKEN_STAKING");
        REGISTRY = vm.envAddress("V2_REGISTRY");
        DAO_MULTISIG = vm.envAddress("DEPLOYER_ADDRESS"); // Using deployer as DAO for now

        console.log("=== MySBT v2.3 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("GToken:", GTOKEN);
        console.log("GTokenStaking:", GTOKEN_STAKING);
        console.log("Registry:", REGISTRY);
        console.log("DAO Multisig:", DAO_MULTISIG);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MySBT v2.3
        mysbt = new MySBT_v2_3(
            GTOKEN,
            GTOKEN_STAKING,
            REGISTRY,
            DAO_MULTISIG
        );

        vm.stopBroadcast();

        // ====================================
        // Deployment Summary
        // ====================================

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("MySBT v2.3:", address(mysbt));
        console.log("Version:", mysbt.VERSION());
        console.log("Version Code:", mysbt.VERSION_CODE());
        console.log("");
        console.log("[OK] MySBT v2.3 Security Enhanced Release deployed successfully!");
        console.log("");
        console.log("Security Features:");
        console.log("- H-1: Rate limiting (5 min interval)");
        console.log("- H-2: Real-time NFT ownership verification");
        console.log("- M-1: Pausable emergency mechanism");
        console.log("- M-4: Comprehensive input validation");
        console.log("- L-3: Enhanced admin events");
        console.log("");
        console.log("Next steps:");
        console.log("1. Update .env with new address:");
        console.log("   V2_MYSBT_V2_3=%s", address(mysbt));
        console.log("2. Update frontend environment variables:");
        console.log("   VITE_MYSBT_ADDRESS=%s", address(mysbt));
        console.log("3. Verify on Etherscan (if --verify didn't work):");
        console.log("   forge verify-contract %s MySBT_v2_3 --chain-id 11155111", address(mysbt));
    }
}
