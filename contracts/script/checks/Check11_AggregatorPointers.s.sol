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
 *   CONFIG_FILE=sepolia.json forge script \
 *     contracts/script/checks/Check11_AggregatorPointers.s.sol:Check11_AggregatorPointers \
 *     --rpc-url "$SEPOLIA_RPC_URL"
 */
contract Check11_AggregatorPointers is Script {
    function run() external view {
        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/deployments/", vm.envOr("CONFIG_FILE", string("anvil.json")))
        );
        address registry = stdJson.readAddress(json, ".registry");
        address sp = stdJson.readAddress(json, ".superPaymaster");
        address dvt = stdJson.readAddress(json, ".dvtValidator");

        address fromRegistry = IAggPtrRegistry(registry).blsAggregator();
        address fromSp = IAggPtrSuperPaymaster(sp).BLS_AGGREGATOR();
        address fromDvt = IAggPtrDVTValidator(dvt).BLS_AGGREGATOR();
        address pending = IAggPtrSuperPaymaster(sp).pendingBLSAgg();
        uint48 eta = IAggPtrSuperPaymaster(sp).pendingBLSAggEta();

        console.log("--- Aggregator pointer consistency ---");
        console.log("Registry.blsAggregator       :", fromRegistry, _ver(fromRegistry));
        console.log("SuperPaymaster.BLS_AGGREGATOR:", fromSp, _ver(fromSp));
        console.log("DVTValidator.BLS_AGGREGATOR  :", fromDvt, _ver(fromDvt));
        if (pending != address(0)) {
            console.log("SP pending rotation to       :", pending);
            console.log("  matures at (unix)          :", uint256(eta));
        }

        bool agreedHasCode = fromRegistry != address(0) && fromRegistry.code.length > 0;
        Verdict v = classify(fromRegistry, fromSp, fromDvt, pending, agreedHasCode);

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
        if (v == Verdict.Ok) {
            console.log("RESULT: OK - all three agree, no rotation queued");
            return;
        }
        if (v == Verdict.OkRequeueSameValue) {
            console.log("RESULT: OK - all three agree; queued rotation targets the SAME address");
            return;
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
        console.log("  No SP rotation is pending, so this is NOT a transition window.");
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
        NotAContract
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
    function classify(address fromRegistry, address fromSp, address fromDvt, address pending, bool agreedHasCode)
        public
        pure
        returns (Verdict)
    {
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
