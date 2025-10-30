// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/Registry.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title DeployRegistryV2_1_1
 * @notice Deploy Registry v2.1.1 with allowPermissionlessMint support
 * @dev Reuses existing GTokenStaking, only deploys new Registry contract
 *
 * Usage:
 * GTOKEN_STAKING=0x92eD5b659Eec9D5135686C9369440D71e7958527 \
 * SUPER_PAYMASTER_V2=0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a \
 * forge script script/DeployRegistryV2_1_1.s.sol:DeployRegistryV2_1_1 \
 *   --rpc-url https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N \
 *   --private-key $OWNER2_PRIVATE_KEY \
 *   --broadcast \
 *   --legacy
 */
contract DeployRegistryV2_1_1 is Script {

    // ====================================
    // Configuration - loaded from env
    // ====================================

    address public GTOKEN_STAKING;
    address public SUPER_PAYMASTER_V2;

    // ====================================
    // Deployment State
    // ====================================

    Registry public registryV2_1_1;

    // ====================================
    // Main Deployment
    // ====================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load addresses from environment
        GTOKEN_STAKING = vm.envAddress("GTOKEN_STAKING");
        SUPER_PAYMASTER_V2 = vm.envAddress("SUPER_PAYMASTER_V2");

        console.log("=== Registry v2.1.1 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("GTokenStaking (existing):", GTOKEN_STAKING);
        console.log("SuperPaymasterV2 (existing):", SUPER_PAYMASTER_V2);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Registry v2.1.1
        console.log("1. Deploying Registry v2.1.1...");
        registryV2_1_1 = new Registry(GTOKEN_STAKING);
        console.log("   Registry v2.1.1:", address(registryV2_1_1));

        // Configure SuperPaymasterV2 address
        console.log("\n2. Configuring SuperPaymasterV2 address...");
        registryV2_1_1.setSuperPaymasterV2(SUPER_PAYMASTER_V2);
        console.log("   SuperPaymasterV2 set to:", SUPER_PAYMASTER_V2);

        // Configure Registry as authorized locker in GTokenStaking
        console.log("\n3. Configuring Registry v2.1.1 as locker in GTokenStaking...");
        GTokenStaking gtokenStaking = GTokenStaking(GTOKEN_STAKING);

        uint256[] memory emptyTimeTiers = new uint256[](0);
        uint256[] memory emptyTierFees = new uint256[](0);

        gtokenStaking.configureLocker(
            address(registryV2_1_1),  // locker
            true,                      // authorized
            0,                         // baseExitFee (no fee)
            emptyTimeTiers,            // timeTiers
            emptyTierFees,             // tierFees
            address(0)                 // feeRecipient (not applicable)
        );
        console.log("   Registry v2.1.1 authorized as locker: true");

        // Verify locker configuration
        console.log("\n4. Verifying locker configuration...");
        GTokenStaking.LockerConfig memory config = gtokenStaking.getLockerConfig(address(registryV2_1_1));
        require(config.authorized, "Locker authorization failed!");
        console.log("   Verification successful: authorized =", config.authorized);

        vm.stopBroadcast();

        // ====================================
        // Summary
        // ====================================

        console.log("\n=== Deployment Summary ===");
        console.log("Registry v2.1.1:", address(registryV2_1_1));
        console.log("GTokenStaking:", GTOKEN_STAKING);
        console.log("SuperPaymasterV2:", registryV2_1_1.superPaymasterV2());

        console.log("\n=== New Features in v2.1.1 ===");
        console.log("- allowPermissionlessMint: Community-level toggle");
        console.log("- setPermissionlessMint(): Operator control");
        console.log("- isPermissionlessMintAllowed(): Public view");
        console.log("- Default: true (permissionless enabled)");

        console.log("\n=== Default Node Type Configs ===");

        // PAYMASTER_AOA
        (uint256 minStake, uint256 slashThreshold, uint256 slashBase, uint256 slashIncrement, uint256 slashMax)
            = registryV2_1_1.nodeTypeConfigs(Registry.NodeType.PAYMASTER_AOA);
        console.log("\nPAYMASTER_AOA:");
        console.log("  Min Stake:", minStake / 1e18, "stGToken");
        console.log("  Slash Threshold:", slashThreshold);

        // PAYMASTER_SUPER
        (minStake, slashThreshold, slashBase, slashIncrement, slashMax)
            = registryV2_1_1.nodeTypeConfigs(Registry.NodeType.PAYMASTER_SUPER);
        console.log("\nPAYMASTER_SUPER:");
        console.log("  Min Stake:", minStake / 1e18, "stGToken");
        console.log("  Slash Threshold:", slashThreshold);

        // ANODE
        (minStake, slashThreshold, slashBase, slashIncrement, slashMax)
            = registryV2_1_1.nodeTypeConfigs(Registry.NodeType.ANODE);
        console.log("\nANODE:");
        console.log("  Min Stake:", minStake / 1e18, "stGToken");
        console.log("  Slash Threshold:", slashThreshold);

        // KMS
        (minStake, slashThreshold, slashBase, slashIncrement, slashMax)
            = registryV2_1_1.nodeTypeConfigs(Registry.NodeType.KMS);
        console.log("\nKMS:");
        console.log("  Min Stake:", minStake / 1e18, "stGToken");
        console.log("  Slash Threshold:", slashThreshold);

        console.log("\n=== Next Steps ===");
        console.log("1. Update shared-config with new Registry v2.1.1 address:");
        console.log("   registry: '%s'", address(registryV2_1_1));
        console.log("\n2. Deploy MySBT v2.3.1 to use new Registry interface");
        console.log("\n3. Register communities and configure permissionless mint");
    }
}
