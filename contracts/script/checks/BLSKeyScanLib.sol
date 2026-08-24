// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {BLS} from "src/utils/BLS.sol";

interface IAggregatorKeyScan {
    function MAX_VALIDATORS() external view returns (uint256);
    function validatorAtSlot(uint8 slot) external view returns (address);
    function getBLSPublicKey(address validator)
        external
        view
        returns (BLS.G1Point memory publicKey, uint8 slot, bool isActive);
    function blsKeyOwner(bytes32 keyHash) external view returns (address);
    function pendingGuardianSlashCount(address guardian) external view returns (uint256);
    function defaultThreshold() external view returns (uint256);
    function minThreshold() external view returns (uint256);
    function slashThresholds(uint8 level) external view returns (uint8);
    function version() external view returns (string memory);
    function REGISTRY() external view returns (address);
    function domainSeparator() external view returns (bytes32);
}

/**
 * @title BLSKeyScanLib
 * @notice CC-48 round-3 MEDIUM-4: the validator-set health checks, in ONE place that
 *         both the standalone audit script and the migration preflight call.
 *
 * @dev Round-2 shipped these checks as a script nobody ran — `deploy-core`,
 *      `DeployBLSAggregatorSepolia` and `UpgradeRegistryTo570` all ignored it. An
 *      opt-in gate is not a gate, so the logic now lives here and
 *      `UpgradeRegistryTo570` calls it unconditionally.
 *
 *      What it checks and why each one is a real failure mode:
 *
 *      1. DUPLICATE KEYS. N slots holding one G1 key make the reconstructed pkAgg equal
 *         N*pk, so the single holder of sk can produce N*sk*H(m) — a valid aggregate
 *         for an N-signer mask, held by one party. A deployment with duplicates has an
 *         effective quorum of (distinct keys), not (slots). 4.7.0's `blsKeyOwner`
 *         prevents this going forward; contracts deployed earlier are NOT upgradeable
 *         and keep whatever they accumulated, which is exactly why the scan exists.
 *
 *      2. WEAK KEYS. A public key derived from a small public scalar (1, 2, 3, ...) has
 *         a publicly known secret. That is the exact state the RepCredit experiment
 *         stack was found in, and it is indistinguishable from a legitimate key by
 *         shape alone.
 *
 *      3. DISTINCT ACTIVE KEYS >= every threshold. A freshly deployed 4.8.0 starts with
 *         an EMPTY key table. Wiring it into Registry before validators have re-filed
 *         their PoPs points the reputation / blacklist paths at an aggregator with no
 *         signers: every proposal reverts with InsufficientConsensus until onboarding
 *         completes, and un-doing the order costs another full timelock cycle.
 *
 *      4. NO TAINTED KEY CARRIED OVER. Any key that is duplicated or weak on the OLD
 *         aggregator must not appear on the NEW one. This is the check that makes
 *         "fresh deployment, fresh keys" enforceable instead of aspirational.
 *
 *      EIP-2537 requirement: check (2) recomputes g1*s for small s, so the RPC's EVM
 *      must implement the BLS12-381 precompiles (Prague). The library FAILS CLOSED if
 *      they are absent rather than silently reporting "no weak keys found".
 */
library BLSKeyScanLib {
    /// @dev Small scalars that appear in every BLS tutorial and in this repo's own
    ///      Prague fixtures. Cheap to rule out (<= 32 MSMs per key).
    uint256 internal constant WEAK_SCALAR_SCAN_LIMIT = 32;

    struct ScanResult {
        uint256 activeSlots;
        uint256 distinctKeys;
        uint256 duplicates;
        uint256 weakKeys;
        bytes32[] keyHashes; // one entry per ACTIVE slot, in slot order
        address[] holders; //  parallel to keyHashes
        bool[] weak; //        parallel to keyHashes
    }

    error EIP2537Unavailable();
    error DuplicateKeysFound(address aggregator, uint256 duplicates);
    error WeakKeysFound(address aggregator, uint256 weakKeys);
    error TooFewDistinctKeys(address aggregator, uint256 distinctKeys, uint256 required);
    error TaintedKeyCarriedOver(bytes32 keyHash, address oldHolder, address newHolder);
    error PendingCaseOnOldAggregator(address aggregator, address guardian, uint256 pendingCount);

    /// @notice Enumerate the ACTIVE key table of `aggregator` and classify it.
    function scan(address aggregator) internal view returns (ScanResult memory result) {
        requireEip2537();
        IAggregatorKeyScan agg = IAggregatorKeyScan(aggregator);
        uint256 maxValidators = agg.MAX_VALIDATORS();

        result.keyHashes = new bytes32[](maxValidators);
        result.holders = new address[](maxValidators);
        result.weak = new bool[](maxValidators);

        for (uint8 slot = 1; slot <= uint8(maxValidators); slot++) {
            address validator = agg.validatorAtSlot(slot);
            if (validator == address(0)) continue;
            (BLS.G1Point memory pk,, bool isActive) = agg.getBLSPublicKey(validator);
            if (!isActive) continue;

            bytes32 keyHash = keccak256(abi.encode(pk.x_a, pk.x_b, pk.y_a, pk.y_b));
            bool seen;
            for (uint256 i = 0; i < result.activeSlots; i++) {
                if (result.keyHashes[i] == keyHash) {
                    seen = true;
                    break;
                }
            }
            if (seen) result.duplicates++;
            else result.distinctKeys++;

            bool isWeak = isWeakScalarKey(pk);
            if (isWeak) result.weakKeys++;

            result.keyHashes[result.activeSlots] = keyHash;
            result.holders[result.activeSlots] = validator;
            result.weak[result.activeSlots] = isWeak;
            result.activeSlots++;
        }
    }

    /// @notice The gate for a validator set that is about to become live.
    /// @param minDistinctKeys the largest threshold any path on this aggregator uses.
    function requireHealthy(address aggregator, uint256 minDistinctKeys)
        internal
        view
        returns (ScanResult memory result)
    {
        result = scan(aggregator);
        if (result.duplicates != 0) revert DuplicateKeysFound(aggregator, result.duplicates);
        if (result.weakKeys != 0) revert WeakKeysFound(aggregator, result.weakKeys);
        if (result.distinctKeys < minDistinctKeys) {
            revert TooFewDistinctKeys(aggregator, result.distinctKeys, minDistinctKeys);
        }
    }

    /// @notice The largest signer count any consensus path on `aggregator` requires.
    /// @dev Reading all of them (not just `defaultThreshold`) matters: a set that
    ///      satisfies the reputation path but not `slashThresholds[MAJOR]` leaves the
    ///      slash path silently unusable, which is the half of the protocol nobody
    ///      exercises until it is needed.
    function maxRequiredThreshold(address aggregator) internal view returns (uint256 required) {
        IAggregatorKeyScan agg = IAggregatorKeyScan(aggregator);
        required = agg.defaultThreshold();
        uint256 minT = agg.minThreshold();
        if (minT > required) required = minT;
        for (uint8 level = 0; level <= 2; level++) {
            uint256 t = uint256(agg.slashThresholds(level));
            if (t > required) required = t;
        }
    }

    /// @notice Refuse to carry a duplicated or weak key from `oldAggregator` onto
    ///         `newAggregator`. Keys the old deployment never had are unaffected.
    function requireNoTaintedKeyCarriedOver(address oldAggregator, address newAggregator) internal view {
        ScanResult memory old = scan(oldAggregator);
        IAggregatorKeyScan next = IAggregatorKeyScan(newAggregator);

        for (uint256 i = 0; i < old.activeSlots; i++) {
            bool tainted = old.weak[i];
            if (!tainted) {
                // duplicated on the old aggregator?
                uint256 occurrences;
                for (uint256 j = 0; j < old.activeSlots; j++) {
                    if (old.keyHashes[j] == old.keyHashes[i]) occurrences++;
                }
                tainted = occurrences > 1;
            }
            if (!tainted) continue;

            address newHolder = next.blsKeyOwner(old.keyHashes[i]);
            if (newHolder != address(0)) {
                revert TaintedKeyCarriedOver(old.keyHashes[i], old.holders[i], newHolder);
            }
        }
    }

    /// @notice A guardian frozen by an unresolved case on the OLD aggregator loses that
    ///         freeze the moment Registry points at the new one. Enumerable for anyone
    ///         still holding a slot.
    /// @dev    LIMITATION, stated plainly: an accused address whose key was already
    ///         revoked holds no slot and cannot be enumerated on-chain. Watchers must
    ///         cross-check `GuardianSlashQueued` events for the case window before
    ///         scheduling the batch; this function covers the enumerable majority.
    function requireNoPendingCases(address oldAggregator) internal view {
        IAggregatorKeyScan agg = IAggregatorKeyScan(oldAggregator);
        uint256 maxValidators = agg.MAX_VALIDATORS();
        for (uint8 slot = 1; slot <= uint8(maxValidators); slot++) {
            address validator = agg.validatorAtSlot(slot);
            if (validator == address(0)) continue;
            uint256 pending = agg.pendingGuardianSlashCount(validator);
            if (pending != 0) revert PendingCaseOnOldAggregator(oldAggregator, validator, pending);
        }
    }

    /// @dev Recomputes g1 * s for the small public scalars and compares.
    function isWeakScalarKey(BLS.G1Point memory pk) internal view returns (bool) {
        for (uint256 s = 1; s <= WEAK_SCALAR_SCAN_LIMIT; s++) {
            BLS.G1Point[] memory points = new BLS.G1Point[](1);
            bytes32[] memory scalars = new bytes32[](1);
            points[0] = g1Generator();
            scalars[0] = bytes32(s);
            BLS.G1Point memory candidate = BLS.msm(points, scalars);
            if (
                candidate.x_a == pk.x_a && candidate.x_b == pk.x_b && candidate.y_a == pk.y_a
                    && candidate.y_b == pk.y_b
            ) {
                return true;
            }
        }
        return false;
    }

    /// @notice Fail closed when the EVM has no EIP-2537: a weak-key scan that cannot
    ///         run must not report "clean".
    function requireEip2537() internal view {
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = address(0x0b).staticcall(twoIdentities);
        if (!ok || result.length != 128) revert EIP2537Unavailable();
    }

    function g1Generator() internal pure returns (BLS.G1Point memory generator) {
        generator.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        generator.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        generator.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        generator.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }
}
