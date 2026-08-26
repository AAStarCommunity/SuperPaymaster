// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import {BLSKeyScanLib, IAggregatorKeyScan} from "./BLSKeyScanLib.sol";

/**
 * @title ScanDuplicateBLSKeys
 * @notice CC-48: audit an ALREADY-DEPLOYED BLSAggregator for the conditions
 *         `blsKeyOwner` now prevents — the same G1 public key bound to more than one
 *         validator address — plus keys whose secret scalar is publicly known.
 *
 * Why a script and not only an in-contract check: BLSAggregator is not upgradeable, so
 * contracts deployed before 4.7.0 keep whatever key table they accumulated. The
 * on-chain guard protects new registrations on new deployments; it cannot retroactively
 * inspect an old one.
 *
 * Round-3 note: the logic moved into contracts/script/checks/BLSKeyScanLib.sol so the
 * migration preflight (UpgradeRegistryTo580) runs the SAME checks automatically. This
 * script remains the standalone, human-facing entry point.
 *
 * Usage:
 *   BLS_AGGREGATOR=0x... forge script contracts/script/checks/ScanDuplicateBLSKeys.s.sol \
 *     --rpc-url $RPC_URL
 *
 * Optional: MIN_DISTINCT_KEYS overrides the threshold floor (defaults to the largest
 * threshold the aggregator itself configures).
 *
 * Exit behaviour: reverts if a duplicate, a known-weak key, or too few distinct active
 * keys is found, so it can gate a pipeline instead of only printing. It also reverts if
 * the RPC's EVM lacks EIP-2537 — a weak-key scan that cannot run must not report clean.
 */
contract ScanDuplicateBLSKeys is Script {
    function run() external view {
        address aggregator = vm.envAddress("BLS_AGGREGATOR");
        IAggregatorKeyScan agg = IAggregatorKeyScan(aggregator);

        console.log("aggregator :", aggregator);
        console.log("version    :", agg.version());
        console.log("registry   :", agg.REGISTRY());

        BLSKeyScanLib.ScanResult memory result = BLSKeyScanLib.scan(aggregator);
        for (uint256 i = 0; i < result.activeSlots; i++) {
            console.log("holder", i, result.holders[i]);
            console.logBytes32(result.keyHashes[i]);
            if (result.weak[i]) {
                console.log("  !! WEAK KEY: derived from a small public scalar");
            }
        }

        console.log("active slots      :", result.activeSlots);
        console.log("distinct keys     :", result.distinctKeys);
        console.log("duplicate keys    :", result.duplicates);
        console.log("weak (public) keys:", result.weakKeys);

        uint256 required = vm.envOr("MIN_DISTINCT_KEYS", BLSKeyScanLib.maxRequiredThreshold(aggregator));
        console.log("required distinct :", required);

        // Reverts with a typed error naming the exact failure.
        BLSKeyScanLib.requireHealthy(aggregator, required);
        console.log("OK: no duplicates, no publicly-known keys, quorum reachable");
    }
}
