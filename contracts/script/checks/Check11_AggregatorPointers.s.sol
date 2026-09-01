// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

interface IAggPtrRegistry {
    function blsAggregator() external view returns (address);
}

interface IAggPtrSuperPaymaster {
    function BLS_AGGREGATOR() external view returns (address);
    function pendingBLSAgg() external view returns (address);
    function pendingBLSAggEta() external view returns (uint48);
}

interface IAggPtrDVTValidator {
    function BLS_AGGREGATOR() external view returns (address);
}

interface IAggVersion {
    function version() external view returns (string memory);
}

/**
 * @title Check11_AggregatorPointers
 * @notice THREE contracts independently store "which BLSAggregator do I trust", and
 *         nothing on-chain keeps them in agreement. This check is what notices when
 *         they drift apart.
 *
 * @dev    WHY THIS EXISTS, stated plainly because it is a real incident and not a
 *         hypothetical. On 2026-08-30 the Sepolia stack was rotated from
 *         BLSAggregator-4.3.0 to 4.11.0 by calling `Registry.setBLSAggregator` — and
 *         only that. `SuperPaymaster.BLS_AGGREGATOR` and
 *         `DVTValidator.BLS_AGGREGATOR` were left pointing at the old contract, and
 *         the deployment record said "nothing else moved". The split survived for two
 *         days and was found by repo:sdk, not by this repository. Nothing was red,
 *         because nothing was looking.
 *
 *         WHY THE THREE COPIES ARE NOT A BUG. They are deliberately not equivalent:
 *
 *           Registry.blsAggregator        setBLSAggregator            immediate
 *           DVTValidator.BLS_AGGREGATOR   setBLSAggregator            immediate
 *           SuperPaymaster.BLS_AGGREGATOR queue -> 24h -> apply       DELAYED
 *
 *         SP's copy is an ACCESS-CONTROL anchor, not a lookup: every use is
 *         `if (msg.sender != BLS_AGGREGATOR) revert Unauthorized()`. It never calls
 *         the aggregator. The 24h timelock exists so that changing WHO MAY SLASH
 *         cannot be done in one transaction (`SuperPaymaster.sol`, P0-3). Making SP
 *         read `Registry.blsAggregator()` live would delete that delay, which is why
 *         the copies stay and this check exists instead.
 *
 *         So the invariant is NOT "one source of truth". It is: the three agree in the
 *         steady state, and any disagreement is either an in-flight rotation (SP has a
 *         pending value) or a mistake. This check distinguishes those two.
 *
 * Run:
 *   CONFIG_FILE=config.sepolia.json forge script \
 *     contracts/script/checks/Check11_AggregatorPointers.s.sol:Check11_AggregatorPointers \
 *     --rpc-url "$SEPOLIA_RPC_URL"
 *
 *   The file lives in deployments/ and every real caller passes the
 *   `config.<env>.json` form; the default below matches that form so a bare
 *   run fails on a missing file rather than on a filename shape nobody uses.
 */
contract Check11_AggregatorPointers is Script {
    function run() external view {
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/deployments/", vm.envOr("CONFIG_FILE", string("config.anvil.json")))
        );
        address registry = stdJson.readAddress(json, ".registry");
        address sp = stdJson.readAddress(json, ".superPaymaster");
        address dvt = stdJson.readAddress(json, ".dvtValidator");

        address fromRegistry = IAggPtrRegistry(registry).blsAggregator();
        address fromSp = IAggPtrSuperPaymaster(sp).BLS_AGGREGATOR();
        address fromDvt = IAggPtrDVTValidator(dvt).BLS_AGGREGATOR();
        address recorded = stdJson.readAddress(json, ".blsAggregator");

        // Both pending reads are optional: `pendingBLSAgg`/`pendingBLSAggEta` arrived
        // with the P0-3 timelock, and a SuperPaymaster older than that has neither
        // selector. Read unconditionally, this check died with a bare "EvmError: Revert"
        // on exactly the deployments it was written to diagnose — op-sepolia is split
        // right now (Registry == DVTValidator, SP.BLS_AGGREGATOR == 0) and running
        // SuperPaymaster-3.2.2, so it reverted before reaching classify() on a value
        // whose answer it did not need.
        //
        // The fallback is NOT `pending = address(0)`. "This SP has no timelock" and
        // "this SP has a timelock and nothing is queued" are different states, and
        // collapsing them would give Verdict.Ok two meanings — the second of which
        // silently asserts a delay that does not exist. `timelockSupported` carries
        // the difference into classify() instead.
        address pending;
        uint48 eta;
        bool timelockSupported = true;
        try IAggPtrSuperPaymaster(sp).pendingBLSAgg() returns (address p) {
            pending = p;
        } catch {
            timelockSupported = false;
        }
        if (timelockSupported) {
            try IAggPtrSuperPaymaster(sp).pendingBLSAggEta() returns (uint48 e) {
                eta = e;
            } catch {}
        }

        console.log("--- Aggregator pointer consistency ---");
        console.log("Registry.blsAggregator       :", fromRegistry, _ver(fromRegistry));
        console.log("SuperPaymaster.BLS_AGGREGATOR:", fromSp, _ver(fromSp));
        console.log("DVTValidator.BLS_AGGREGATOR  :", fromDvt, _ver(fromDvt));
        if (pending != address(0)) {
            console.log("SP pending rotation to       :", pending);
            console.log("  matures at (unix)          :", uint256(eta));
        }

        // A coordinated rotation spends the whole 24h timelock in a verdict that
        // reverts — queue-first lands in ArmedSplit, move-Registry-and-DVT-first lands
        // in RotationInFlight — so for one day `./deploy-sepolia.sh` and
        // `./audit-core sepolia` are both red on a rotation that is going exactly to
        // plan, and an unrelated hotfix cannot ship. That is a real cost, but a plain
        // "skip this check" flag would delete the gate on the day it matters most.
        //
        // EXPECT_AGGREGATOR_ROTATION_TO is narrower: it does not suppress the check, it
        // states the intended end address. The rotation passes ONLY if every pointer
        // that has already moved, and any queued value, equals that address — i.e. the
        // operator's declared target and the chain agree. Point it at the wrong address
        // and it still fails; set it during a split nobody declared and it still fails.
        address expected = vm.envOr("EXPECT_AGGREGATOR_ROTATION_TO", address(0));

        bool agreedHasCode = fromRegistry != address(0) && fromRegistry.code.length > 0;
        Verdict v = classify(fromRegistry, fromSp, fromDvt, pending, agreedHasCode, recorded, timelockSupported);

        if (v == Verdict.RecordStale) {
            console.log("RESULT: DEPLOYMENT RECORD STALE");
            console.log("  The three on-chain pointers agree, but config .blsAggregator does not");
            console.log("  match them. On-chain consistency is not the same as a correct record:");
            console.log("  that file is machine-read by the deploy scripts and copied into");
            console.log("  aastar-sdk by sync_to_sdk.sh, so every consumer stays pinned to the");
            console.log("  old address while the chain has moved on.");
            console.log("  recorded :", recorded);
            console.log("  on-chain :", fromRegistry);
            revert("Check11: deployments config .blsAggregator is stale");
        }
        if (v == Verdict.NotAContract) {
            console.log("RESULT: NOT A CONTRACT");
            console.log("  All three agree on an address that has no code on this chain.");
            console.log("  Agreement says they were configured together, not that the");
            console.log("  target exists. Check the address and the network.");
            revert("Check11: aggregator address has no code");
        }
        if (v == Verdict.Unconfigured) {
            console.log("RESULT: UNCONFIGURED");
            console.log("  All three read the zero address. This is not 'consistent', it is");
            console.log("  an unwired stack: no BLS aggregator means Registry's domain");
            console.log("  separator is degenerate and SP's slash entry points are");
            console.log("  unreachable. Wire it before treating this deployment as done.");
            revert("Check11: no aggregator configured");
        }
        if (v == Verdict.LegacyNoTimelock) {
            console.log("RESULT: OK (LEGACY SP - NO ROTATION TIMELOCK)");
            console.log("  All three agree and the record matches, so the invariant this");
            console.log("  check guards holds. What does NOT hold is the assumption behind");
            console.log("  it: this SuperPaymaster predates P0-3 and exposes no");
            console.log("  pendingBLSAgg(), so changing WHO MAY SLASH is a single");
            console.log("  transaction with no 24h delay. Reported separately from OK");
            console.log("  because a plain OK would be claiming a delay that is not there.");
            console.log("  Not a failure of this check; upgrade SP to gate that change.");
            return;
        }
        if (v == Verdict.Ok) {
            console.log("RESULT: OK - all three agree, no rotation queued");
            return;
        }
        if (v == Verdict.OkRequeueSameValue) {
            console.log("RESULT: OK - all three agree; queued rotation targets the SAME address");
            return;
        }
        if (expected != address(0) && (v == Verdict.ArmedSplit || v == Verdict.RotationInFlight)) {
            // A rotation in progress is a TWO-address state, not "moved or zero": a
            // pointer that has not been touched yet still holds the OLD aggregator.
            // The declaration is accepted only when the chain looks like a transition
            // between exactly two addresses, one of them the declared target, with
            // nothing queued anywhere else. A third address anywhere means whatever is
            // happening is not the rotation that was declared.
            (bool declarationHolds, address other, string memory why) =
                checkDeclaredTarget(fromRegistry, fromSp, fromDvt, pending, expected, expected.code.length > 0);
            if (declarationHolds) {
                console.log("RESULT: ROTATION IN PROGRESS, MATCHES DECLARED TARGET");
                console.log("  declared EXPECT_AGGREGATOR_ROTATION_TO:", expected, _ver(expected));
                console.log("  rotating away from                    :", other, _ver(other));
                console.log("  Every pointer holds either the declared target or the one");
                console.log("  address being rotated away from, and nothing is queued");
                console.log("  elsewhere. Passing so a 24h timelock does not also freeze");
                console.log("  unrelated deployments. Remove this variable once");
                console.log("  applyBLSAggregator() has landed: it asserts an in-flight");
                console.log("  change, it does not mute the check.");
                return;
            }
            console.log("DECLARED TARGET DOES NOT MATCH THE CHAIN - falling through to the failure");
            console.log("  EXPECT_AGGREGATOR_ROTATION_TO:", expected);
            console.log("  reason:", why);
        }
        if (v == Verdict.ArmedSplit) {
            console.log("RESULT: ARMED SPLIT");
            console.log("  The three pointers agree TODAY, but SuperPaymaster has a rotation");
            console.log("  queued to a DIFFERENT address. Whoever calls applyBLSAggregator()");
            console.log("  next moves SP alone and splits them. Queuing is not the problem;");
            console.log("  an apply without the matching Registry/DVTValidator updates is.");
            console.log("  Either cancel it, or land all three together.");
            revert("Check11: a queued SP rotation would split the pointers");
        }
        if (v == Verdict.RotationInFlight) {
            console.log("RESULT: MISMATCH - rotation in flight");
            console.log("  SP has a pending value; finish with applyBLSAggregator() and");
            console.log("  make sure Registry and DVTValidator are moved too, then re-run.");
            revert("Check11: aggregator pointers disagree (rotation in flight)");
        }
        console.log("RESULT: MISMATCH - settled split");
        if (timelockSupported) {
            console.log("  No SP rotation is pending, so this is NOT a transition window.");
        } else {
            console.log("  This SuperPaymaster predates P0-3 and has no pendingBLSAgg(), so");
            console.log("  no rotation CAN be in flight on it. Same conclusion, different");
            console.log("  reason: read as 'no such mechanism', not 'queue read and empty'.");
        }
        console.log("  Someone moved one pointer and not the others. Rotating requires ALL THREE:");
        console.log("    Registry.setBLSAggregator(new)");
        console.log("    DVTValidator.setBLSAggregator(new)");
        console.log("    SuperPaymaster.queueBLSAggregator(new) -> 24h -> applyBLSAggregator()");
        revert("Check11: aggregator pointers disagree");
    }

    enum Verdict {
        Ok,
        OkRequeueSameValue,
        ArmedSplit,
        RotationInFlight,
        SettledSplit,
        Unconfigured,
        NotAContract,
        RecordStale,
        LegacyNoTimelock
    }

    /// @notice Does the chain look like the rotation the operator declared?
    /// @dev    Pure for the same reason `classify` is: this decides whether a red gate
    ///         goes green, so every way it can say yes has to be reachable from a test.
    ///         A rotation in progress is a TWO-address state — a pointer nobody has
    ///         touched yet still holds the OLD aggregator, it does not read zero — so
    ///         "already moved or zero" was the wrong shape and rejected the very
    ///         rotation this exists to allow (measured on live sepolia).
    /// @return holds whether the declaration may stand in for the check
    /// @return other the single address being rotated away from, for the log
    /// @return why the specific reason it does not hold, empty when it does
    function checkDeclaredTarget(
        address fromRegistry,
        address fromSp,
        address fromDvt,
        address pending,
        address expected,
        bool expectedHasCode
    ) public pure returns (bool holds, address other, string memory why) {
        address[3] memory ptrs = [fromRegistry, fromSp, fromDvt];
        for (uint256 i = 0; i < 3; i++) {
            if (ptrs[i] == expected || ptrs[i] == address(0)) continue;
            if (other == address(0)) other = ptrs[i];
            else if (other != ptrs[i]) return (false, other, "the pointers name more than two distinct addresses");
        }
        if (!expectedHasCode) return (false, other, "the declared target has no code on this chain");
        if (pending != address(0) && pending != expected) {
            return (false, other, "SP has a rotation queued to a different address");
        }
        // Declaring a target nothing is moving toward is not a rotation, it is a wish.
        if (pending != expected && fromRegistry != expected && fromSp != expected && fromDvt != expected) {
            return (false, other, "nothing on-chain points at, or is queued to, the target");
        }
        return (true, other, "");
    }

    /// @notice The whole decision, as a pure function so every branch can be tested.
    /// @dev    `pending` matters even when the three CURRENTLY agree: a queued rotation to
    ///         a different address is a split that has not happened yet, and the earlier
    ///         version of this check returned OK for exactly that state — it looked only at
    ///         the three current values. A gate that passes while the next routine call
    ///         breaks the invariant is not guarding the invariant.
    /// @param agreedHasCode whether the address all three point at actually has code.
    ///        Passed in rather than read here so this stays pure and every branch is
    ///        testable; `run()` supplies it from `.code.length`.
    /// @param recorded the `blsAggregator` value in deployments/config.<env>.json.
    ///        Checked because the chain agreeing with itself says nothing about the record
    ///        downstream actually reads: that file is machine-read by the deploy scripts and
    ///        copied into aastar-sdk by sync_to_sdk.sh. A rotation that moves all three
    ///        pointers and forgets the record leaves every consumer pinned to the previous
    ///        aggregator while this check says OK.
    function classify(
        address fromRegistry,
        address fromSp,
        address fromDvt,
        address pending,
        bool agreedHasCode,
        address recorded,
        bool timelockSupported
    ) public pure returns (Verdict) {
        bool agree = (fromRegistry == fromSp) && (fromSp == fromDvt);
        if (agree) {
            // Three zeros "agree", and the first version of this function called that Ok.
            // It is not health, it is an unwired stack: with no aggregator, Registry's
            // domain separator is degenerate and nothing can call SP's slash entry points
            // at all. Agreement is necessary, not sufficient.
            if (fromRegistry == address(0)) return Verdict.Unconfigured;
            // Non-zero and agreed is still not health. Three pointers can agree on an EOA,
            // a typo'd address, or a contract that never got deployed on this chain: every
            // call into it then either reverts or, worse, succeeds vacuously. This is the
            // fifth thing that had to be true rather than merely necessary; the previous
            // four were "connected to a gate", "not stamp-skippable", "no queued rotation"
            // and "not all zero".
            if (!agreedHasCode) return Verdict.NotAContract;
            if (recorded != fromRegistry) return Verdict.RecordStale;
            // Reached only when the three agree and the record matches. On a
            // pre-P0-3 SuperPaymaster there is no pending value to consult and no
            // 24h delay on changing who may slash, so this is not the same Ok.
            if (!timelockSupported) return Verdict.LegacyNoTimelock;
            if (pending == address(0)) return Verdict.Ok;
            if (pending == fromSp) return Verdict.OkRequeueSameValue;
            return Verdict.ArmedSplit;
        }
        return pending == address(0) ? Verdict.SettledSplit : Verdict.RotationInFlight;
    }

    function _ver(address a) internal view returns (string memory) {
        if (a == address(0) || a.code.length == 0) return "(no code)";
        try IAggVersion(a).version() returns (string memory v) {
            return v;
        } catch {
            return "(no version())";
        }
    }
}
