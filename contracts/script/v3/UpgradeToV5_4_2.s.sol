// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeToV5_4_2
 * @notice UUPS upgrade: SuperPaymaster 5.4.1 -> 5.4.2 (CC-13, closes #333).
 *
 * Changes:
 *   - executeSlashWithBLS: anti-double-slash cooldown on the BLS/DVT path.
 *   - queueSlash: BLS/DVT re-arm gated during the cooldown (primary gate — no parked pending).
 *   - New dedicated `_blsSlashCd` mapping + `_blsSlashCdFloor` (both appended; __gap 30->28, UUPS-safe), decoupled from the
 *     owner path's `_slashCd` so an owner slash never blocks the DVT path.
 *   - New `isSlashPending(address) view` for DVT peer-failover.
 *
 * NO 24h timelock: _authorizeUpgrade is onlyOwner (immediate single owner tx). This is an in-place
 * impl swap — the proxy ADDRESS is unchanged, so BLSAggregator/DVTValidator/validators/slots/SDK
 * addresses all stay wired; no re-registration, no aggregator re-deploy.
 *
 * No reinitializer: new storage is appended (defaults to 0), no state migration.
 * Idempotent: skips the upgrade if SP already reports the target version.
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/UpgradeToV5_4_2.s.sol:UpgradeToV5_4_2 \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast -vvvv
 */
contract UpgradeToV5_4_2 is Script {
    string constant TARGET_SP_VERSION = "SuperPaymaster-5.4.2";

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address spProxy       = vm.parseJsonAddress(config, ".superPaymaster");
        address entryPoint    = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed     = vm.parseJsonAddress(config, ".priceFeed");
        address cfgBlsAgg     = vm.parseJsonAddress(config, ".blsAggregator");

        SuperPaymaster sp = SuperPaymaster(payable(spProxy));

        console.log("=== UUPS Upgrade: SuperPaymaster v5.4.2 (CC-13) ===");
        console.log("  Network:        ", network);
        console.log("  SP proxy:       ", spProxy);
        console.log("  Registry proxy: ", registryProxy, "(unchanged)");

        // ---- Snapshot critical state BEFORE the upgrade (storage-integrity guard) ----
        string memory spBefore = sp.version();
        address ownerBefore    = sp.owner();
        address apntsBefore     = sp.APNTS_TOKEN();
        address treasuryBefore  = sp.treasury();
        address blsAggBefore    = sp.BLS_AGGREGATOR();
        uint256 feeBefore       = sp.protocolFeeBPS();
        uint256 priceBefore     = sp.aPNTsPriceUSD();
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
            // Atomically prime the global BLS-slash cooldown floor in the SAME tx as the impl swap,
            // closing the cold-start double-slash window (an operator slashed shortly before the
            // upgrade has no per-operator _blsSlashCd recorded). Delegatecalled with msg.sender ==
            // the owner performing the upgrade, so the onlyOwner guard passes.
            UUPSUpgradeable(spProxy).upgradeToAndCall(
                newImpl,
                abi.encodeCall(SuperPaymaster.primeBlsSlashCooldown, ())
            );
            console.log("  SP upgradeToAndCall + primeBlsSlashCooldown executed");
        } else {
            console.log("  SuperPaymaster already at target version - skipping");
            bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
            newImpl = address(uint160(uint256(vm.load(spProxy, slot))));
        }

        vm.stopBroadcast();

        // ---- Post-upgrade verification: version, storage integrity, new fn, wiring ----
        require(
            keccak256(bytes(sp.version())) == keccak256(bytes(TARGET_SP_VERSION)),
            "V: version mismatch after upgrade"
        );
        // Storage integrity: every snapshotted slot must be byte-identical after the impl swap.
        require(sp.owner() == ownerBefore,          "V: owner drifted");
        require(sp.APNTS_TOKEN() == apntsBefore,     "V: APNTS_TOKEN drifted");
        require(sp.treasury() == treasuryBefore,     "V: treasury drifted");
        require(sp.BLS_AGGREGATOR() == blsAggBefore,  "V: BLS_AGGREGATOR drifted");
        require(sp.protocolFeeBPS() == feeBefore,     "V: protocolFeeBPS drifted");
        require(sp.aPNTsPriceUSD() == priceBefore,    "V: aPNTsPriceUSD drifted");
        // New function must be live and default-false for a fresh address.
        require(sp.isSlashPending(address(0)) == false, "V: isSlashPending not live");
        // Slash wiring must still point at the deployed aggregator (defense against 'missed wiring').
        require(sp.BLS_AGGREGATOR() == cfgBlsAgg,      "V: BLS_AGGREGATOR != config.blsAggregator");
        console.log("  Verified: version + storage integrity + isSlashPending + BLS_AGGREGATOR wiring");

        // ---- Auto-patch config (spImpl / srcHash / updateTime) ----
        string memory srcHash    = vm.envOr("SRC_HASH",    vm.parseJsonString(config, ".srcHash"));
        string memory updateTime = vm.envOr("DEPLOY_TIME", vm.parseJsonString(config, ".updateTime"));

        vm.writeJson(vm.toString(newImpl),     configPath, ".spImpl");
        vm.writeJson(srcHash,                  configPath, ".srcHash");
        vm.writeJson(updateTime,               configPath, ".updateTime");
        _ensureTrailingNewline(configPath);

        console.log("  Config patched:", configPath);
        console.log("    spImpl =", newImpl);
        console.log("=== Upgrade successful! ===");
        console.log("");
        console.log("REMINDER (off-chain, not done by this script):");
        console.log("  1. Re-extract abis/SuperPaymaster.json + sync_to_sdk.sh (isSlashPending added).");
        console.log("  2. Notify @repo:sdk (new ABI) + @repo:dvt (queueSlash reverts SlashCooldown in-window).");
        console.log("  3. Run version-check-onchain.sh; confirm 5.4.2. See runbook doc.");
    }

    function _ensureTrailingNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0) return;
        if (content[content.length - 1] == 0x0a) return;
        vm.writeFile(path, string.concat(string(content), "\n"));
    }
}
