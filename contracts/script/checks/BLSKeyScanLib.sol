// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {BLS} from "src/utils/BLS.sol";
import {console} from "forge-std/console.sol";

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
    function guardianSlashCases(uint256 fraudProofId)
        external
        view
        returns (bytes32, bytes32, uint64, uint8, uint16, uint16, address);
    /// @dev DELIBERATELY NOT part of the capability probe — see `guardianSlashCapability`.
    ///      `fraudProofVerifier` shipped with CC-89's queue-less direct-execute path in
    ///      `BLSAggregator-4.2.0`, TWO minor versions before the case machine existed, so
    ///      its presence says nothing about whether a case can be stored. Kept here only
    ///      so the exclusion is visible at the declaration site.
    function fraudProofVerifier() external view returns (address);
    function GUARDIAN_SLASH_CASE_WINDOW() external view returns (uint256);
    function guardianExitRequests(address guardian) external view returns (uint64, uint64);
}

interface IRegistryWiring {
    function blsAggregator() external view returns (address);
}

/**
 * @title BLSKeyScanLib
 * @notice CC-48 round-3 MEDIUM-4: the validator-set health checks, in ONE place that
 *         both the standalone audit script and the migration preflight call.
 *
 * @dev Round-2 shipped these checks as a script nobody ran — `deploy-core`,
 *      `DeployBLSAggregatorSepolia` and `UpgradeRegistryTo580` all ignored it. An
 *      opt-in gate is not a gate, so the logic now lives here and
 *      `UpgradeRegistryTo580` calls it unconditionally.
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
 *      3. DISTINCT ACTIVE KEYS >= every threshold. A freshly deployed 4.11.0 starts with
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

    /// @dev CC-48 round-6 MEDIUM-1. A selector no build of this aggregator implements or
    ///      ever will: a contract that ANSWERS it (rather than reverting) is running a
    ///      catch-all fallback, so nothing else it returns can be trusted. Probed FIRST,
    ///      before any real getter, and — since round-8 MEDIUM-1 — at every calldata width
    ///      this library ever sends, so no `calldatasize` predicate can tell the sentinel
    ///      apart from a real getter. Derived from a string, so the value is auditable and
    ///      cannot silently collide with a real function — `BLSAggregator` classifying as
    ///      `Present` in the suite is the standing proof that it does not collide.
    bytes4 internal constant CATCH_ALL_SENTINEL =
        bytes4(keccak256("cc48CatchAllFallbackSentinel_NoBuildImplementsThis(bytes32,uint256)"));

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
    /// @dev CC-48 round-5 HIGH-1 / round-6 BLOCKER-1 + MEDIUM-1: the predecessor exposes
    ///      SOME of the case-machine surface but not `pendingGuardianSlashCount`, answers
    ///      a probe with the wrong ABI width, or answers `CATCH_ALL_SENTINEL` at all (a
    ///      catch-all fallback, whose every answer is fabricated). In each case the "it
    ///      cannot hold a case" argument is not provable, so the migration stops rather
    ///      than skipping.
    error AmbiguousGuardianSlashCapability(address aggregator);
    /// @dev CC-48 round-5 HIGH-1: `OLD_BLS_AGGREGATOR` does not match the aggregator this
    ///      Registry is wired to right now. Declaring 0 ("first-ever deployment") on a
    ///      Registry that already has a predecessor is the exact way the tainted-key gate
    ///      gets switched off by accident.
    error PredecessorMismatch(address registry, address declared, address wired);

    /// @notice What a predecessor aggregator can do about guardian slashing.
    /// @dev    `Absent` is a positive proof WITHIN THIS REPOSITORY'S BUILD LINEAGE, and
    ///         nowhere wider (CC-48 round-7 LOW-1). In this repo a pending case can only be
    ///         created by `queueGuardianSlash`, and `queueGuardianSlash` landed in the SAME
    ///         commit as the four case-machine getters probed below — so a build OF THIS
    ///         AGGREGATOR exposing none of them has no code path that can produce one.
    ///
    ///         It is NOT a statement about arbitrary contracts. A contract with a real case
    ///         store and a real `queueGuardianSlash` whose counters are `private` exposes
    ///         none of the four getters and classifies `Absent` too, and for that contract
    ///         "it cannot hold a case" is simply false. What keeps that out of reach is
    ///         `requireDeclaredPredecessor`: the scanned address is not a free parameter,
    ///         it must be the aggregator `Registry` is wired to right now.
    enum GuardianSlashCapability {
        Absent,
        Present,
        Ambiguous
    }

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
    ///
    /// @dev    CC-48 round-5 HIGH-1 — LEGACY PREDECESSORS. `pendingGuardianSlashCount`
    ///         arrived with the CASE MACHINE (CC-48, shipped as `BLSAggregator-4.7.0`);
    ///         the aggregators actually deployed today (Sepolia `BLSAggregator-4.3.0`,
    ///         and `4.1.0` before it) do not have that selector at all. Round-3 called this function first and
    ///         unconditionally, so pointing the migration at the REAL predecessor made
    ///         the whole preflight revert on a missing selector — and the only way to
    ///         make the script run was `OLD_BLS_AGGREGATOR=0`, which ALSO skipped
    ///         `requireNoTaintedKeyCarriedOver`, the sole on-chain gate stopping the
    ///         experiment stack's publicly-known keys from being re-onboarded. A gate
    ///         whose only usable setting disables a second gate is worse than no gate.
    ///
    ///         The skip is therefore narrow and PROVEN, never assumed:
    ///           • if `pendingGuardianSlashCount` answers, nothing is skipped;
    ///           • it is skipped only when the predecessor exposes NONE of the FOUR
    ///             case-machine getters that shipped in the same commit as
    ///             `queueGuardianSlash` — which, FOR A BUILD OF THIS AGGREGATOR, means no
    ///             code path in it can create a case (see `guardianSlashCapability`, whose
    ///             round-7 LOW-1 note states the scope of that argument exactly);
    ///           • any in-between shape reverts with `AmbiguousGuardianSlashCapability`.
    ///         The caller keeps running `requireNoTaintedKeyCarriedOver` regardless —
    ///         that check works fine against 4.3.0's ABI and is not what was failing.
    function requireNoPendingCases(address oldAggregator) internal view {
        GuardianSlashCapability capability = guardianSlashCapability(oldAggregator);
        if (capability == GuardianSlashCapability.Ambiguous) {
            revert AmbiguousGuardianSlashCapability(oldAggregator);
        }
        if (capability == GuardianSlashCapability.Absent) {
            console.log("  WARNING: predecessor has no guardian-slash surface at all:", oldAggregator);
            console.log("           version:", _versionOrUnknown(oldAggregator));
            console.log("           pending-case check SKIPPED: no build of THIS aggregator with");
            console.log("           none of the four case-machine getters can create a case, and the");
            console.log("           predecessor is bound to Registry.blsAggregator() above.");
            console.log("           tainted/weak/duplicate key carry-over check still ENFORCED.");
            return;
        }

        IAggregatorKeyScan agg = IAggregatorKeyScan(oldAggregator);
        uint256 maxValidators = agg.MAX_VALIDATORS();
        for (uint8 slot = 1; slot <= uint8(maxValidators); slot++) {
            address validator = agg.validatorAtSlot(slot);
            if (validator == address(0)) continue;
            uint256 pending = agg.pendingGuardianSlashCount(validator);
            if (pending != 0) revert PendingCaseOnOldAggregator(oldAggregator, validator, pending);
        }
    }

    /// @notice Decide, from the deployed bytecode's own ABI surface, whether `aggregator`
    ///         can hold a guardian-slash case at all.
    ///
    /// @dev    THE ONLY THING THAT CAN CREATE A PENDING CASE is `queueGuardianSlash`, and
    ///         it does so by writing `guardianSlashCases[id]` and bumping
    ///         `pendingGuardianSlashCount`. Those two mappings, the case window constant
    ///         and the exit-request surface that reads the counter all arrived in ONE
    ///         commit (CC-48, `daa1d1ec`/`2c0ed76b`, shipped as `BLSAggregator-4.7.0`).
    ///         That co-arrival is what makes their JOINT absence positive evidence: a
    ///         build with none of them contains no `queueGuardianSlash`, hence no case
    ///         store, hence nothing for the pending scan to find.
    ///
    ///         CC-48 round-6 BLOCKER-1 — WHY `fraudProofVerifier` IS NOT IN THIS SET.
    ///         It is NOT part of that commit. It arrived two minor versions earlier with
    ///         CC-89's queue-less direct-execute path (`75b3f9f4`,
    ///         `BLSAggregator-4.2.0`), which slashes inside a single call and writes no
    ///         case storage whatsoever. Sepolia's live predecessor
    ///         `0x174b60bB…0158` (`BLSAggregator-4.3.0`) sits exactly in that gap: it
    ///         ANSWERS `fraudProofVerifier()` with a 32-byte address and REVERTS on all
    ///         four case-machine getters. Round-5 probed all five as if they were one
    ///         feature, so the real migration source classified as `Ambiguous` and the
    ///         preflight could not run against ANY value of `OLD_BLS_AGGREGATOR`. Probing
    ///         it proved nothing about case storage and broke the only usable path.
    ///
    ///         The classification, in order:
    ///           0. SHAPE-CATCH-ALL DETECTION FIRST. A selector that cannot exist on any
    ///              build is probed before anything else, AT EVERY CALLDATA WIDTH THIS
    ///              LIBRARY EVER SENDS (round-8 MEDIUM-1; see `_answersAnySentinelShape`).
    ///              If it ANSWERS at ANY of those widths — with any returndata, empty or
    ///              32+ bytes — the contract has a catch-all fallback and every subsequent
    ///              answer is fabricated. Unconditionally `Ambiguous`; see `_probe`.
    ///              (Round-5 only caught the empty-returndata half of this: a proxy
    ///              fallback returning >= 32 bytes was read as a REAL
    ///              `pendingGuardianSlashCount`, and a fabricated 0 reported "no pending
    ///              cases" for a contract that was never asked.)
    ///           1. `Present` iff `pendingGuardianSlashCount(address)` returns EXACTLY
    ///              32 bytes — that is the only getter the pending scan needs.
    ///           2. `Absent` iff ALL FOUR case-machine getters are missing:
    ///              `pendingGuardianSlashCount`, `guardianSlashCases`,
    ///              `GUARDIAN_SLASH_CASE_WINDOW`, `guardianExitRequests`.
    ///           3. Everything else is `Ambiguous` and must stop the migration: a partial
    ///              surface is an unrecognised build, and a wrong-width answer is a
    ///              contract that is not what its ABI claims. Fail closed, loudly.
    ///
    ///         STATED LIMITATION 1 — WHAT STEP 0 PROVES IS NARROWER THAN ROUNDS 6 AND 7
    ///         CLAIMED (CC-48 round-8 MEDIUM-1). Step 0 proves ONE thing: a contract that
    ///         answers by CALLDATA SHAPE rather than by selector — a catch-all fallback,
    ///         with or without a `calldatasize` filter in either direction — is refused.
    ///         It proves NOTHING about a contract that answers by SELECTOR. One that
    ///         declares exactly the probed selectors, returns a fabricated value of the
    ///         correct width for each, and has no fallback is INDISTINGUISHABLE from a
    ///         genuine getter set at the probe layer, at any sentinel width, by
    ///         construction — that is what "implements this function" means over a
    ///         `staticcall` interface. The claim this NatSpec used to make ("the sentinel
    ///         is indistinguishable from a genuine call to a real method", therefore no
    ///         forgery survives) is FALSE and is retracted.
    ///           Concretely, such a contract classifies `Present` — not `Absent` — so the
    ///           pending scan is not skipped: it RUNS, reads a fabricated
    ///           `MAX_VALIDATORS() == 0`, iterates zero times and reports clean. Probing
    ///           harder cannot fix that; the inputs, not the classification, are the lie.
    ///           What keeps such a contract out is NOT this step. It is
    ///           `requireDeclaredPredecessor`: the scan target is pinned to whatever
    ///           `Registry.blsAggregator()` returns RIGHT NOW, so reaching this fail-open
    ///           requires governance to have already wired a hostile aggregator into the
    ///           live Registry. Step 0 is defence in depth against an accidental proxy or
    ///           a shape-based forgery, not a proof of honesty.
    ///           `CC48MigrationPreflight.test_ASelectorWhitelistLiarIsNotDetectableAtTheProbeLayer`
    ///           is the standing, executable statement of this limit.
    ///
    ///         STATED LIMITATION 2: every probe is a `staticcall`, so a fallback that WRITES
    ///         state reverts on all of them and classifies as `Absent`. Such a contract
    ///         also cannot answer the pending scan, so the migration would be reasoning
    ///         about a shape no aggregator in this repo's history has ever had; the
    ///         predecessor binding (`requireDeclaredPredecessor`) is what keeps the target
    ///         to the one Registry is actually wired to.
    function guardianSlashCapability(address aggregator) internal view returns (GuardianSlashCapability) {
        // 0. Catch-all fallback detection, BEFORE any known getter is trusted.
        if (_answersAnySentinelShape(aggregator)) return GuardianSlashCapability.Ambiguous;

        (bool pendingOk, bool pendingDecodable) =
            _probe(aggregator, abi.encodeCall(IAggregatorKeyScan.pendingGuardianSlashCount, (address(1))), 32);
        if (pendingOk && pendingDecodable) return GuardianSlashCapability.Present;
        if (pendingOk) return GuardianSlashCapability.Ambiguous; // answered, but not as a uint256

        bool anyOther;
        bool anyUndecodable;
        (bool ok, bool decodable) =
            _probe(aggregator, abi.encodeCall(IAggregatorKeyScan.guardianSlashCases, (uint256(0))), 224);
        anyOther = anyOther || (ok && decodable);
        anyUndecodable = anyUndecodable || (ok && !decodable);
        (ok, decodable) =
            _probe(aggregator, abi.encodeCall(IAggregatorKeyScan.GUARDIAN_SLASH_CASE_WINDOW, ()), 32);
        anyOther = anyOther || (ok && decodable);
        anyUndecodable = anyUndecodable || (ok && !decodable);
        (ok, decodable) =
            _probe(aggregator, abi.encodeCall(IAggregatorKeyScan.guardianExitRequests, (address(1))), 64);
        anyOther = anyOther || (ok && decodable);
        anyUndecodable = anyUndecodable || (ok && !decodable);

        if (anyOther || anyUndecodable) return GuardianSlashCapability.Ambiguous;
        return GuardianSlashCapability.Absent;
    }

    /// @dev CC-48 round-8 MEDIUM-1. Send `CATCH_ALL_SENTINEL` at EVERY calldata width this
    ///      library ever puts on the wire, and treat an answer at ANY of them as a
    ///      catch-all.
    ///
    ///      WHY WIDTH, NOT "REALISM". Rounds 6 and 7 each picked ONE width and called it
    ///      indistinguishable from a real call, and each time one `calldatasize` comparison
    ///      separated it from every real getter:
    ///        • round 6 sent 4 bytes  -> `if lt(calldatasize(), 36) { revert }` evaded it
    ///          while still fabricating a clean 32-byte `pendingGuardianSlashCount`;
    ///        • round 7 sent 68 bytes -> `if gt(calldatasize(), 36) { revert }` evaded THAT
    ///          while still fabricating clean answers to every real getter. 68 was the only
    ///          68-byte probe in the whole library, so it was the easiest thing in the file
    ///          to fingerprint. Symmetric defect, opposite sign.
    ///
    ///      The fix is not a better single width, it is the SET of widths. This library
    ///      makes exactly nine distinct calls to an aggregator, and every one of them is
    ///      either 4 bytes — `MAX_VALIDATORS`, `defaultThreshold`, `minThreshold`,
    ///      `version`, `GUARDIAN_SLASH_CASE_WINDOW` — or 36 bytes — `validatorAtSlot`,
    ///      `getBLSPublicKey`, `blsKeyOwner`, `pendingGuardianSlashCount`,
    ///      `slashThresholds`, `guardianSlashCases`, `guardianExitRequests`. Every probed
    ///      argument list is exactly one static word; nothing here sends a dynamic type.
    ///      So a fallback that answers ANY call this library will later trust necessarily
    ///      answers a sentinel of the SAME width, and no `calldatasize` predicate — `lt`,
    ///      `gt`, `eq`, a range, or a set — can admit the one and refuse the other. The
    ///      68-byte pre-image width is kept as well, so round 7's property is not lost.
    ///
    ///      ARGUMENT VALUES, NOT JUST WIDTHS. The 36-byte shape is sent TWICE, carrying 0
    ///      and 1. Every one-argument probe this library makes carries one of those two
    ///      values in practice (`guardianSlashCases(0)`, `validatorAtSlot(0)` vs
    ///      `pendingGuardianSlashCount(address(1))`, `guardianExitRequests(address(1))`), so
    ///      a fallback keyed on `iszero(calldataload(4))` in EITHER direction — the same
    ///      mirror-image trick one level down from `calldatasize` — cannot admit a real
    ///      probe while refusing the sentinel.
    ///
    ///      WHAT THIS STILL DOES NOT PROVE: see STATED LIMITATION 1 on
    ///      `guardianSlashCapability`. A predicate over the SELECTOR, or over the argument
    ///      value across its whole unbounded domain, is out of reach of any finite set of
    ///      probes — a fixed probe set cannot cover an unbounded one. This step closes the
    ///      shape-based class; the predecessor binding is what covers the rest.
    function _answersAnySentinelShape(address aggregator) private view returns (bool) {
        // 4 bytes — the width of every no-argument getter this library reads.
        (bool ok,) = _probe(aggregator, abi.encodeWithSelector(CATCH_ALL_SENTINEL), 0);
        if (ok) return true;
        // 36 bytes — the width of every one-argument getter this library reads, including
        // `pendingGuardianSlashCount(address)`, the single answer `Present` is built on.
        // Both argument values the real probes actually use.
        (ok,) = _probe(aggregator, abi.encodeWithSelector(CATCH_ALL_SENTINEL, bytes32(0)), 0);
        if (ok) return true;
        (ok,) = _probe(aggregator, abi.encodeWithSelector(CATCH_ALL_SENTINEL, bytes32(uint256(1))), 0);
        if (ok) return true;
        // 68 bytes — the sentinel's own declared `(bytes32,uint256)` pre-image (round 7).
        (ok,) = _probe(aggregator, abi.encodeWithSelector(CATCH_ALL_SENTINEL, bytes32(0), uint256(0)), 0);
        return ok;
    }

    /// @notice The declared predecessor must be the aggregator this Registry is wired to
    ///         RIGHT NOW.
    /// @dev    CC-48 round-5 HIGH-1. `OLD_BLS_AGGREGATOR` has no default precisely so a
    ///         forgotten predecessor fails loudly — but "loudly" only helps if the value
    ///         is also CHECKED. Without this, 0 is both "there is no predecessor" and
    ///         "make the preflight stop complaining", and the two are indistinguishable
    ///         to the script. Registry knows the answer, so ask it: a live migration
    ///         cannot declare itself first-ever, and a typo'd or stale predecessor
    ///         address (scanning the wrong contract for tainted keys) is caught too.
    function requireDeclaredPredecessor(address registry, address declaredOld)
        internal
        view
        returns (address wired)
    {
        wired = IRegistryWiring(registry).blsAggregator();
        if (declaredOld != wired) revert PredecessorMismatch(registry, declaredOld, wired);
    }

    /// @dev staticcall probe. Returns (the call succeeded, the returndata is EXACTLY the
    ///      expected ABI width). Split in two because "reverted" and "answered with
    ///      something of the wrong width" mean very different things here: the first is a
    ///      missing selector on a fallback-less contract (informative), the second is a
    ///      contract that is not what its ABI claims (never trustworthy).
    ///
    ///      CC-48 round-6 MEDIUM-1: the width test is `==`, not `>=`. Every getter probed
    ///      by `guardianSlashCapability` returns a STATIC head, so its ABI encoding has
    ///      one exact length; `>=` accepted anything longer, which is precisely what a
    ///      proxy fallback delegating to a different implementation produces. Answers that
    ///      are the wrong width are reported as undecodable and land in `Ambiguous`, and
    ///      the caller separately refuses any contract that answers `CATCH_ALL_SENTINEL`.
    function _probe(address target, bytes memory callData, uint256 expectedReturnLength)
        private
        view
        returns (bool ok, bool decodable)
    {
        bytes memory ret;
        (ok, ret) = target.staticcall(callData);
        decodable = ret.length == expectedReturnLength;
    }

    /// @dev CC-48 round-6 LOW-1. This is a pure WARNING path — it exists to name the
    ///      predecessor in the log line printed next to a skipped pending-case check — so
    ///      it must never be the thing that reverts. `abi.decode(ret, (string))` reverts
    ///      on a malformed head (an offset or length pointing outside the returndata),
    ///      which a predecessor can produce trivially, turning an informational message
    ///      into an unexplained revert inside a view library. The head is therefore
    ///      bounds-checked by hand before the decode, exactly as the ABI decoder would,
    ///      and any failure degrades to a label instead.
    function _versionOrUnknown(address aggregator) private view returns (string memory) {
        (bool ok, bytes memory ret) = aggregator.staticcall(abi.encodeCall(IAggregatorKeyScan.version, ()));
        if (!ok || ret.length < 64) return "<no version() getter>";

        uint256 offset;
        assembly {
            offset := mload(add(ret, 0x20))
        }
        // the length word must sit wholly inside the returndata
        if (offset > ret.length - 32) return "<malformed version() return>";
        uint256 len;
        assembly {
            len := mload(add(add(ret, 0x20), offset))
        }
        // ...and so must the bytes it claims
        if (len > ret.length - offset - 32) return "<malformed version() return>";
        return abi.decode(ret, (string));
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
