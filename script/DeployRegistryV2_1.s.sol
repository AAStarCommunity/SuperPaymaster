// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/Registry.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title DeployRegistryV2_1
 * @notice Deploy Registry v2.1 (upgrade from v2.0)
 * @dev Reuses existing GTokenStaking, only deploys new Registry contract
 *
 * Usage:
 * forge script script/DeployRegistryV2_1.s.sol:DeployRegistryV2_1 \
 *   --rpc-url $SEPOLIA_RPC_URL \
 *   --private-key $PRIVATE_KEY \
 *   --broadcast \
 *   --verify \
 *   -vvvv
 */
contract DeployRegistryV2_1 is Script {

    // ====================================
    // Configuration - Sepolia Addresses
    // ====================================

    /// @notice Existing GTokenStaking V2 address on Sepolia (Production)
    address constant GTOKEN_STAKING = 0x199402b3F213A233e89585957F86A07ED1e1cD67;

    /// @notice Existing SuperPaymasterV2 address (for setSuperPaymasterV2)
    address constant SUPER_PAYMASTER_V2 = 0xb96d8BC6d771AE5913C8656FAFf8721156AC8141;

    // ====================================
    // Deployment State
    // ====================================

    Registry public registryV2_1;

    // ====================================
    // Main Deployment
    // ====================================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Registry v2.1 Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("GTokenStaking (existing):", GTOKEN_STAKING);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Registry v2.1
        console.log("1. Deploying Registry v2.1...");
        registryV2_1 = new Registry(GTOKEN_STAKING);
        console.log("   Registry v2.1:", address(registryV2_1));

        // Configure SuperPaymasterV2 address
        console.log("\n2. Configuring SuperPaymasterV2 address...");
        registryV2_1.setSuperPaymasterV2(SUPER_PAYMASTER_V2);
        console.log("   SuperPaymasterV2 set to:", SUPER_PAYMASTER_V2);

        // Configure Registry as authorized locker in GTokenStaking
        console.log("\n3. Configuring Registry v2.1 as locker in GTokenStaking...");
        GTokenStaking gtokenStaking = GTokenStaking(GTOKEN_STAKING);

        uint256[] memory emptyTimeTiers = new uint256[](0);
        uint256[] memory emptyTierFees = new uint256[](0);

        gtokenStaking.configureLocker(
            address(registryV2_1),  // locker
            true,                   // authorized
            0,                      // feeRateBps (no percentage fee)
            0,                      // minExitFee (no minimum)
            0,                      // maxFeePercent (no cap needed if rate is 0)
            emptyTimeTiers,         // timeTiers
            emptyTierFees,          // tierFees
            address(0)              // feeRecipient (not applicable)
        );
        console.log("   Registry v2.1 authorized as locker: true");

        // Verify locker configuration
        console.log("\n4. Verifying locker configuration...");
        GTokenStaking.LockerConfig memory config = gtokenStaking.getLockerConfig(address(registryV2_1));
        require(config.authorized, "Locker authorization failed!");
        console.log("   Verification successful: authorized =", config.authorized);

        vm.stopBroadcast();

        // ====================================
        // Summary
        // ====================================

        console.log("\n=== Deployment Summary ===");
        console.log("Registry v2.1:", address(registryV2_1));
        console.log("GTokenStaking:", GTOKEN_STAKING);
        console.log("SuperPaymasterV2:", registryV2_1.superPaymasterV2());

        console.log("\n=== Default Node Type Configs ===");

        // PAYMASTER_AOA
        (uint256 minStake, uint256 slashThreshold, uint256 slashBase, uint256 slashIncrement, uint256 slashMax)
            = registryV2_1.nodeTypeConfigs(Registry.NodeType.PAYMASTER_AOA);
        console.log("\nPAYMASTER_AOA:");
        console.log("  Min Stake:", minStake / 1e18);
        console.log("  Slash Threshold:", slashThreshold);
        console.log("  Slash Base:", slashBase);
        console.log("  Slash Max:", slashMax);

        // PAYMASTER_SUPER
        (minStake, slashThreshold, slashBase, slashIncrement, slashMax)
            = registryV2_1.nodeTypeConfigs(Registry.NodeType.PAYMASTER_SUPER);
        console.log("\nPAYMASTER_SUPER:");
        console.log("  Min Stake:", minStake / 1e18);
        console.log("  Slash Threshold:", slashThreshold);
        console.log("  Slash Base:", slashBase);
        console.log("  Slash Max:", slashMax);

        // ANODE
        (minStake, slashThreshold, slashBase, slashIncrement, slashMax)
            = registryV2_1.nodeTypeConfigs(Registry.NodeType.ANODE);
        console.log("\nANODE:");
        console.log("  Min Stake:", minStake / 1e18);
        console.log("  Slash Threshold:", slashThreshold);
        console.log("  Slash Base:", slashBase);
        console.log("  Slash Max:", slashMax);

        // KMS
        (minStake, slashThreshold, slashBase, slashIncrement, slashMax)
            = registryV2_1.nodeTypeConfigs(Registry.NodeType.KMS);
        console.log("\nKMS:");
        console.log("  Min Stake:", minStake / 1e18);
        console.log("  Slash Threshold:", slashThreshold);
        console.log("  Slash Base:", slashBase);
        console.log("  Slash Max:", slashMax);

        console.log("\n=== Next Steps ===");
        console.log("1. Update frontend configs with new Registry v2.1 address:");
        console.log("   networkConfig.ts -> registryV2_1:", address(registryV2_1));
        console.log("\n2. Update .env files:");
        console.log("   VITE_REGISTRY_V2_1_ADDRESS=", address(registryV2_1));
        console.log("\n3. (Optional) Transfer ownership to multisig when ready:");
        console.log("   registryV2_1.transferOwnership(MULTISIG_ADDRESS)");
    }
}
