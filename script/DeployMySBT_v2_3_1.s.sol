// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/tokens/MySBT_v2.3.1.sol";

/**
 * @title DeployMySBT_v2_3_1
 * @notice Deployment script for MySBT v2.3.1 - Permissionless Mint Release
 * @dev Deploys MySBT v2.3.1 with userMint() for permissionless minting
 *
 * Usage:
 * GTOKEN=0x868F843723a98c6EECC4BF0aF3352C53d5004147 \
 * GTOKEN_STAKING=0x92eD5b659Eec9D5135686C9369440D71e7958527 \
 * REGISTRY=0x529912C52a934fA02441f9882F50acb9b73A3c5B \
 * DEPLOYER_ADDRESS=0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA \
 * forge script script/DeployMySBT_v2_3_1.s.sol:DeployMySBT_v2_3_1 \
 *   --rpc-url https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N \
 *   --private-key $OWNER2_PRIVATE_KEY \
 *   --broadcast \
 *   --legacy
 */
contract DeployMySBT_v2_3_1 is Script {

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

    MySBT_v2_3_1 public mysbt;

    // ====================================
    // Main Deployment
    // ====================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load addresses from environment
        GTOKEN = vm.envAddress("GTOKEN");
        GTOKEN_STAKING = vm.envAddress("GTOKEN_STAKING");
        REGISTRY = vm.envAddress("REGISTRY");
        DAO_MULTISIG = vm.envAddress("DEPLOYER_ADDRESS");

        console.log("=== MySBT v2.3.1 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("GToken:", GTOKEN);
        console.log("GTokenStaking:", GTOKEN_STAKING);
        console.log("Registry:", REGISTRY);
        console.log("DAO Multisig:", DAO_MULTISIG);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy MySBT v2.3.1
        mysbt = new MySBT_v2_3_1(
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
        console.log("MySBT v2.3.1:", address(mysbt));
        console.log("Version:", mysbt.VERSION());
        console.log("Version Code:", mysbt.VERSION_CODE());
        console.log("");
        console.log("[OK] MySBT v2.3.1 Permissionless Mint Release deployed successfully!");
        console.log("");
        console.log("New Features:");
        console.log("- userMint(): Permissionless minting for users");
        console.log("- Community-level permission control via Registry");
        console.log("- Preserves invitation-only mode compatibility");
        console.log("");
        console.log("Security:");
        console.log("- Validates community registration");
        console.log("- Checks allowPermissionlessMint flag");
        console.log("- Same security features as v2.3");
        console.log("");
        console.log("Next steps:");
        console.log("1. Update shared-config with new address:");
        console.log("   mySBT: '%s'", address(mysbt));
        console.log("2. Deploy Registry v2.1.1 with allowPermissionlessMint support");
        console.log("3. Register communities and enable permissionless mint");
    }
}
