// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeToV5_3_2
 * @notice UUPS upgrade for Registry 5.3.3 -> 5.3.4 AND SuperPaymaster 5.3.1 -> 5.3.2.
 *
 * Changes:
 *   - Registry.syncStakeFromStaking now auto-revokes hasRole when stake drops
 *     to zero (invariant: hasRole => stake > 0). Fix-1.
 *   - SuperPaymaster.setXPNTsFactory rejects address(0). Fix-4.
 *
 * No reinitializer needed: no new storage layout, no state migration.
 *
 * Idempotent: if version already matches target, skips that side.
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/UpgradeToV5_3_2.s.sol:UpgradeToV5_3_2 \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast -vvvv
 */
contract UpgradeToV5_3_2 is Script {
    string constant TARGET_REGISTRY_VERSION = "Registry-5.3.4";
    string constant TARGET_SP_VERSION       = "SuperPaymaster-5.3.2";

    function run() external {
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.sepolia.json");
        string memory config = vm.readFile(configPath);

        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address spProxy       = vm.parseJsonAddress(config, ".superPaymaster");
        address entryPoint    = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed     = vm.parseJsonAddress(config, ".priceFeed");

        console.log("=== UUPS Upgrade: v5.3.2 / Registry v5.3.4 ===");
        console.log("  Registry proxy: ", registryProxy);
        console.log("  SP proxy:       ", spProxy);

        string memory regBefore = Registry(registryProxy).version();
        string memory spBefore  = SuperPaymaster(payable(spProxy)).version();
        console.log("  Registry before:", regBefore);
        console.log("  SP before:      ", spBefore);

        vm.startBroadcast();

        // -------- Registry --------
        if (keccak256(bytes(regBefore)) != keccak256(bytes(TARGET_REGISTRY_VERSION))) {
            Registry newRegistryImpl = new Registry();
            console.log("  New Registry impl:", address(newRegistryImpl));
            UUPSUpgradeable(registryProxy).upgradeToAndCall(address(newRegistryImpl), "");
            console.log("  Registry upgradeToAndCall executed");
        } else {
            console.log("  Registry already at target version - skipping");
        }

        // -------- SuperPaymaster --------
        if (keccak256(bytes(spBefore)) != keccak256(bytes(TARGET_SP_VERSION))) {
            SuperPaymaster newSPImpl = new SuperPaymaster(
                IEntryPoint(entryPoint),
                Registry(registryProxy),
                priceFeed
            );
            console.log("  New SP impl:", address(newSPImpl));
            UUPSUpgradeable(spProxy).upgradeToAndCall(address(newSPImpl), "");
            console.log("  SP upgradeToAndCall executed");
        } else {
            console.log("  SuperPaymaster already at target version - skipping");
        }

        vm.stopBroadcast();

        // -------- Verification --------
        string memory regAfter = Registry(registryProxy).version();
        string memory spAfter  = SuperPaymaster(payable(spProxy)).version();
        console.log("  Registry after:", regAfter);
        console.log("  SP after:      ", spAfter);

        require(
            keccak256(bytes(regAfter)) == keccak256(bytes(TARGET_REGISTRY_VERSION)),
            "Registry version mismatch after upgrade"
        );
        require(
            keccak256(bytes(spAfter)) == keccak256(bytes(TARGET_SP_VERSION)),
            "SuperPaymaster version mismatch after upgrade"
        );

        console.log("=== Upgrade successful! ===");
    }
}
