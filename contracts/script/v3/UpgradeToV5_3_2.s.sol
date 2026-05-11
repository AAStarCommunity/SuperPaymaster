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
 * @notice UUPS upgrade: SuperPaymaster 5.3.1 -> 5.3.2.
 *
 * Changes:
 *   - SuperPaymaster.setXPNTsFactory rejects address(0). Fix-4.
 *
 * Registry stays at 5.3.3: the originally planned Fix-1 (auto-revoke hasRole
 * on stake==0) was withdrawn after Codex review revealed it would leave
 * userRoleCount / userRoles / roleMembers / SBT state stale and corrupt
 * future re-registrations. See docs/v5.4-todo.md section 0 for the full
 * analysis; a complete fix lands in v5.4 alongside Registry byte-compression.
 *
 * No reinitializer needed: no new storage layout, no state migration.
 *
 * Idempotent: skips upgrade if SP already reports the target version.
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/UpgradeToV5_3_2.s.sol:UpgradeToV5_3_2 \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast -vvvv
 */
contract UpgradeToV5_3_2 is Script {
    string constant TARGET_SP_VERSION = "SuperPaymaster-5.3.2";

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address spProxy       = vm.parseJsonAddress(config, ".superPaymaster");
        address entryPoint    = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed     = vm.parseJsonAddress(config, ".priceFeed");

        console.log("=== UUPS Upgrade: SuperPaymaster v5.3.2 ===");
        console.log("  Network:        ", network);
        console.log("  SP proxy:       ", spProxy);
        console.log("  Registry proxy: ", registryProxy, "(unchanged)");

        string memory spBefore = SuperPaymaster(payable(spProxy)).version();
        console.log("  SP before:      ", spBefore);

        address newImpl;

        vm.startBroadcast();

        if (keccak256(bytes(spBefore)) != keccak256(bytes(TARGET_SP_VERSION))) {
            SuperPaymaster newSPImpl = new SuperPaymaster(
                IEntryPoint(entryPoint),
                Registry(registryProxy),
                priceFeed
            );
            newImpl = address(newSPImpl);
            console.log("  New SP impl:", newImpl);
            UUPSUpgradeable(spProxy).upgradeToAndCall(newImpl, "");
            console.log("  SP upgradeToAndCall executed");
        } else {
            console.log("  SuperPaymaster already at target version - skipping");
            // Read current impl from ERC-1967 slot for idempotent runs.
            // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
            bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
            newImpl = address(uint160(uint256(vm.load(spProxy, slot))));
        }

        vm.stopBroadcast();

        string memory spAfter = SuperPaymaster(payable(spProxy)).version();
        console.log("  SP after:      ", spAfter);

        require(
            keccak256(bytes(spAfter)) == keccak256(bytes(TARGET_SP_VERSION)),
            "SuperPaymaster version mismatch after upgrade"
        );

        // ---- Auto-patch config ----
        // Patch in-place so we keep all the other fields (pnts, microPaymentChannel,
        // agent registries, etc.) that DeployLive doesn't know about.
        // SRC_HASH / DEPLOY_TIME are exported by deploy-core; fall back to whatever
        // is already on disk if invoked directly via `forge script`.
        string memory srcHash    = vm.envOr("SRC_HASH",    vm.parseJsonString(config, ".srcHash"));
        string memory updateTime = vm.envOr("DEPLOY_TIME", vm.parseJsonString(config, ".updateTime"));

        vm.writeJson(vm.toString(newImpl),     configPath, ".spImpl");
        vm.writeJson(srcHash,                  configPath, ".srcHash");
        vm.writeJson(updateTime,               configPath, ".updateTime");

        console.log("  Config patched:", configPath);
        console.log("    spImpl     =", newImpl);
        console.log("    srcHash    =", srcHash);
        console.log("    updateTime =", updateTime);

        console.log("=== Upgrade successful! ===");
    }
}
