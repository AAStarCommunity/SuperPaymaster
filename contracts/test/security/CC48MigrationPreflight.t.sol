// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {BLSKeyScanLib} from "../../script/checks/BLSKeyScanLib.sol";

/// @notice The 4.3.0/4.1.0 shape, reduced to what the capability probe looks at: the
///         key-table surface exists, the guardian-slash surface does not, and there is
///         NO fallback — so every guardian-slash selector reverts, exactly as it does
///         on the aggregators deployed on Sepolia today.
contract LegacySurfaceStub {
    function MAX_VALIDATORS() external pure returns (uint256) {
        return 13;
    }

    function validatorAtSlot(uint8) external pure returns (address) {
        return address(0);
    }

    function version() external pure returns (string memory) {
        return "BLSAggregator-4.3.0";
    }
}

/// @notice A 4.7.0+ shape: `pendingGuardianSlashCount` answers, so nothing is skipped.
contract ModernSurfaceStub {
    mapping(address => uint256) public pendingGuardianSlashCount;

    function setPending(address guardian, uint256 n) external {
        pendingGuardianSlashCount[guardian] = n;
    }

    function MAX_VALIDATORS() external pure returns (uint256) {
        return 2;
    }

    function validatorAtSlot(uint8 slot) external pure returns (address) {
        return slot == 1 ? address(0xA11CE) : address(0);
    }

    function version() external pure returns (string memory) {
        return "BLSAggregator-4.12.0";
    }
}

/// @notice The shape the probe must REFUSE to classify: a catch-all fallback answers
///         every probe with empty returndata, so "the selector is missing" and "the
///         contract swallowed my call" become indistinguishable. Silence must never be
///         read as "this contract cannot hold a guardian-slash case".
contract FallbackAggregatorStub {
    fallback() external {}
}

/// @notice A HALF-migrated shape: `guardianSlashCases` exists, `pendingGuardianSlashCount`
///         does not. Nothing real should look like this, which is exactly why the
///         preflight must stop instead of guessing.
contract PartialGuardianSurfaceStub {
    function guardianSlashCases(uint256)
        external
        pure
        returns (bytes32, bytes32, uint64, uint8, uint16, uint16, address)
    {
        return (bytes32(0), bytes32(0), 0, 0, 0, 0, address(0));
    }

    function version() external pure returns (string memory) {
        return "BLSAggregator-4.5.0-frankenstein";
    }
}

/// @notice THE SHAPE THAT IS ACTUALLY ON SEPOLIA — CC-48 round-6 BLOCKER-1.
///         `0x174b60bB…0158` is a `BLSAggregator-4.3.0`: it ANSWERS
///         `fraudProofVerifier()` with a 32-byte address (CC-89's queue-less
///         direct-execute path, `BLSAggregator-4.2.0`) and REVERTS on all four
///         case-machine getters, which only arrived two minor versions later with
///         `queueGuardianSlash`. Round-5 probed `fraudProofVerifier` as if it belonged to
///         the same feature, so the REAL migration source classified as `Ambiguous` and
///         the preflight had no runnable `OLD_BLS_AGGREGATOR` at all. It has no fallback,
///         exactly like the deployed contract.
contract Legacy43RealShapeStub {
    /// @dev The verifier address read off Sepolia's 4.3.0 by `cast call`.
    address public constant FRAUD_PROOF_VERIFIER = 0x128847cFD6e0C8247ED297Fb27a1302f2ad66D51;

    function fraudProofVerifier() external pure returns (address) {
        return FRAUD_PROOF_VERIFIER;
    }

    function MAX_VALIDATORS() external pure returns (uint256) {
        return 13;
    }

    function validatorAtSlot(uint8) external pure returns (address) {
        return address(0);
    }

    function version() external pure returns (string memory) {
        return "BLSAggregator-4.3.0";
    }
}

/// @notice The other half of the catch-all problem, and the half round-5 left open
///         (CC-48 round-6 MEDIUM-1). `FallbackAggregatorStub` returns ZERO bytes, which
///         the old `>=` width test already rejected. A fallback that returns 32+ bytes —
///         the ordinary shape of a proxy delegating to a different implementation — was
///         read as a REAL `pendingGuardianSlashCount`, and a fabricated 0 reported "no
///         pending cases" for a contract that was never actually asked.
contract WideFallbackAggregatorStub {
    fallback() external {
        assembly {
            mstore(0x00, 0)
            return(0x00, 0x20)
        }
    }
}

/// @notice CC-48 round-7 MEDIUM-1. The catch-all that ROUND 6 STILL MISSED, and the exact
///         reason the sentinel now carries its declared arguments.
///
///         Round 6 sent the sentinel as a BARE 4-BYTE SELECTOR while every real getter
///         probe was sent with full arguments. One `lt(calldatasize(), 36)` is enough to
///         tell the two apart: this fixture reverts on any call shorter than
///         `selector + one word` and answers a fabricated full word to everything else. So
///         under round 6 it
///           • reverted on the 4-byte sentinel  -> "not a catch-all",
///           • answered `pendingGuardianSlashCount(address)` with 32 clean bytes -> `Present`,
///           • and `requireNoPendingCases` then read its fabricated 0 as "no pending case"
///             for a contract that was never actually asked anything.
///
///         That is the same fail-open step 0 was written to close, reopened by the shape of
///         the probe rather than by the width test. With the sentinel sent as
///         `(bytes32,uint256)` the fixture answers it too, and lands in `Ambiguous`.
contract ArgStrictCatchAllStub {
    fallback() external {
        assembly {
            // A catch-all that only serves calls which "look real".
            if lt(calldatasize(), 36) { revert(0, 0) }
            mstore(0x00, 0)
            return(0x00, 0x20)
        }
    }
}

/// @notice CC-48 round-8 MEDIUM-1. Round 7's fix moved the evasion, it did not remove it.
///
///         Round 7 sent the sentinel at 68 bytes (`selector + bytes32 + uint256`) and
///         declared it "indistinguishable from a genuine call to a real method". It was the
///         only 68-byte probe in the entire library, so ONE instruction told it apart:
///         `if gt(calldatasize(), 36) { revert }` — the exact mirror image of the `lt` that
///         defeated round 6. Under round 7 this fixture
///           • reverted on the 68-byte sentinel                     -> "not a catch-all",
///           • fabricated a clean 32-byte word for every real getter -> `Present`,
///           • fabricated `MAX_VALIDATORS() == 0`                    -> "no keys, no taint",
///         so `requireDeclaredPredecessor` + the taint scan + the pending scan ALL reported
///         clean for a contract that was never actually asked anything.
///
///         Round 8 probes the sentinel at 4, 36 AND 68 bytes, and every real getter in the
///         library is 4 or 36. So a fallback answering anything the library will later
///         trust answers a sentinel of the same width, and no `calldatasize` predicate in
///         either direction can separate them.
contract SizeDiscriminatingCatchAllStub {
    fallback() external {
        assembly {
            // The mirror of `ArgStrictCatchAllStub`: serve the SHORT shapes, refuse the
            // long one that round 7 happened to pick for its sentinel.
            if gt(calldatasize(), 36) { revert(0, 0) }
            mstore(0x00, 0)
            return(0x00, 0x20)
        }
    }
}

/// @notice CC-48 round-8 MEDIUM-1, one level below `SizeDiscriminatingCatchAllStub`: a
///         catch-all that discriminates on the ARGUMENT WORD rather than on
///         `calldatasize`. It serves only calls whose first argument word is non-zero,
///         which is exactly the shape `pendingGuardianSlashCount(address(1))` and
///         `guardianExitRequests(address(1))` have — so under a sentinel probed only with
///         a zero argument it would fabricate a clean `Present` and a clean zero count
///         while refusing every probe sent to check on it.
///
///         The 36-byte sentinel is therefore sent with BOTH argument values the real
///         probes use (0 and 1), so this predicate cannot separate them in either
///         direction.
contract ArgValueDiscriminatingCatchAllStub {
    fallback() external {
        assembly {
            if lt(calldatasize(), 36) { revert(0, 0) }
            if iszero(calldataload(4)) { revert(0, 0) } // <- only serves non-zero arguments
            mstore(0x00, 0)
            return(0x00, 0x20)
        }
    }
}

/// @notice CC-48 round-8 MEDIUM-1, the HONEST LIMIT of step 0 — this fixture is NOT
///         detected, and the test that uses it asserts exactly that.
///
///         It is an ordinary contract with no fallback at all. It implements precisely the
///         selectors the preflight probes, answers each with the right width, and lies in
///         the values:
///           `pendingGuardianSlashCount` -> 0   ("no pending case")
///           `MAX_VALIDATORS`            -> 0   ("no slots, so no key to be tainted")
///         Because it has no fallback, every sentinel — at any width, present or future —
///         reverts against it, so no probe can distinguish it from a genuine getter set.
///         That is not a defect in the sentinel; it is what "implements this function"
///         means over a `staticcall` interface.
///
///         What keeps it out is `requireDeclaredPredecessor`: the preflight only ever scans
///         whatever `Registry.blsAggregator()` returns right now, so this contract is only
///         reachable if governance has ALREADY wired it into the live Registry.
contract SelectorWhitelistLiarStub {
    function pendingGuardianSlashCount(address) external pure returns (uint256) {
        return 0;
    }

    function MAX_VALIDATORS() external pure returns (uint256) {
        return 0;
    }

    function validatorAtSlot(uint8) external pure returns (address) {
        return address(0);
    }

    function blsKeyOwner(bytes32) external pure returns (address) {
        return address(0);
    }

    function version() external pure returns (string memory) {
        return "BLSAggregator-4.3.0";
    }
}

/// @notice Answers the pending getter, but not as a `uint256`: 64 bytes where the ABI says
///         32. Not what its ABI claims, therefore not trustworthy.
contract WrongWidthPendingStub {
    function pendingGuardianSlashCount(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function version() external pure returns (string memory) {
        return "BLSAggregator-impostor";
    }
}

/// @notice A legacy-shaped predecessor whose `version()` returns a malformed dynamic head:
///         the string offset points outside the returndata (CC-48 round-6 LOW-1). The
///         capability is `Absent`, so the warning path runs and calls `_versionOrUnknown`.
contract MalformedVersionOffsetStub {
    /// @dev Same selector as `version()`, a head of (offset = 2**256-1, length = 0).
    function version() external pure returns (bytes32, bytes32) {
        return (bytes32(type(uint256).max), bytes32(0));
    }

    function MAX_VALIDATORS() external pure returns (uint256) {
        return 1;
    }

    function validatorAtSlot(uint8) external pure returns (address) {
        return address(0);
    }
}

/// @notice The other malformed head: the offset is in range, the LENGTH is not.
contract MalformedVersionLengthStub {
    function version() external pure returns (bytes32, bytes32) {
        return (bytes32(uint256(32)), bytes32(type(uint256).max));
    }

    function MAX_VALIDATORS() external pure returns (uint256) {
        return 1;
    }

    function validatorAtSlot(uint8) external pure returns (address) {
        return address(0);
    }
}

contract RegistryWiringStub {
    address public blsAggregator;

    function setBLSAggregator(address a) external {
        blsAggregator = a;
    }
}

/**
 * @title CC48MigrationPreflight
 * @notice CC-48 round-5 HIGH-1. Two gates that were, respectively, un-runnable and
 *         unenforced:
 *
 *           1. `requireNoPendingCases` called a selector that does not exist on ANY
 *              aggregator deployed today, so pointing the migration at the real
 *              predecessor reverted the whole preflight — and the only way to make the
 *              script run (`OLD_BLS_AGGREGATOR=0`) ALSO skipped
 *              `requireNoTaintedKeyCarriedOver`, the sole on-chain gate stopping the
 *              experiment stack's publicly-known keys from being re-onboarded.
 *
 *           2. `OLD_BLS_AGGREGATOR` was required but never checked, so 0 doubled as both
 *              "there is no predecessor" and "make the preflight be quiet".
 *
 *         These tests run under Cancun on purpose: the capability probe and the
 *         predecessor binding are pure ABI/staticcall properties with no BLS in them, so
 *         they must not be reachable only through the Prague-gated suite (which is how
 *         the legacy shape went uncovered in the first place). The end-to-end
 *         legacy-predecessor regression, which needs the real weak-key scan, lives in
 *         `contracts/test/paper7/CC48KeyScanPreflight.t.sol`.
 */
contract CC48MigrationPreflight is Test {
    // =================================================================
    // Capability probe
    // =================================================================

    /// The legacy shape is classified from its ABI surface alone — no version string is
    /// trusted, no allow-list is consulted.
    function test_LegacyShapeIsProvablyIncapableOfHoldingACase() public {
        LegacySurfaceStub legacy = new LegacySurfaceStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(legacy))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Absent)
        );
        // ...and the pending check steps aside instead of reverting on a missing selector.
        this.callRequireNoPendingCases(address(legacy));
    }

    /// A predecessor that HAS the feature is scanned in full — the skip is proven per
    /// contract, not granted to everything that predates a version number.
    function test_ModernShapeIsScannedNotSkipped() public {
        ModernSurfaceStub modern = new ModernSurfaceStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(modern))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Present)
        );
        this.callRequireNoPendingCases(address(modern)); // clean today

        modern.setPending(address(0xA11CE), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PendingCaseOnOldAggregator.selector,
                address(modern),
                address(0xA11CE),
                uint256(1)
            )
        );
        this.callRequireNoPendingCases(address(modern));
    }

    /// The failure mode a naive "selector missing ⇒ feature absent" probe would have:
    /// a contract with a catch-all fallback answers everything with empty returndata and
    /// would be waved through as "cannot hold a case".
    function test_AFallbackContractIsAmbiguousNotAbsent() public {
        FallbackAggregatorStub swallower = new FallbackAggregatorStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(swallower))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.AmbiguousGuardianSlashCapability.selector, address(swallower)
            )
        );
        this.callRequireNoPendingCases(address(swallower));
    }

    /// A partial guardian-slash surface is an unrecognised build. Stop, do not guess.
    function test_APartialGuardianSurfaceIsAmbiguous() public {
        PartialGuardianSurfaceStub partialStub = new PartialGuardianSurfaceStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(partialStub))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.AmbiguousGuardianSlashCapability.selector, address(partialStub)
            )
        );
        this.callRequireNoPendingCases(address(partialStub));
    }

    /// CC-48 round-6 BLOCKER-1. The regression that made round-5's preflight unrunnable
    /// against the ONE contract it exists to preflight. `fraudProofVerifier` predates the
    /// case machine by two minor versions, so its presence is not evidence of a case
    /// store; probing it turned Sepolia's real 4.3.0 into `Ambiguous`, and with
    /// `requireDeclaredPredecessor` also refusing `OLD_BLS_AGGREGATOR=0`, NO value of that
    /// variable could complete the script.
    ///
    /// The positive argument this asserts instead: a pending case can only be created by
    /// `queueGuardianSlash`, which landed in the SAME commit as the four case-machine
    /// getters. All four missing ⇒ no `queueGuardianSlash` ⇒ no case store.
    function test_TheRealSepolia43ShapeIsAbsentNotAmbiguous() public {
        Legacy43RealShapeStub legacy = new Legacy43RealShapeStub();

        // Precondition of the test itself: this fixture really does answer the getter
        // that used to poison the classification.
        assertTrue(legacy.fraudProofVerifier() != address(0), "fixture must expose the live shape");

        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(legacy))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Absent),
            "4.3.0 exposes fraudProofVerifier and still cannot hold a case"
        );
        // ...so the migration can actually run against the real predecessor.
        this.callRequireNoPendingCases(address(legacy));
    }

    /// CC-48 round-6 MEDIUM-1, the `Present` direction. A catch-all fallback that returns
    /// 32 bytes (an ordinary proxy to a different implementation) used to satisfy the old
    /// `ret.length >= 32` test and be classified `Present`; the scan then read its
    /// fabricated 0 as "no pending cases" for a contract that was never asked. It is now
    /// caught before any real getter is probed, by a selector no build implements.
    function test_AWideReturningFallbackIsAmbiguousNotPresent() public {
        WideFallbackAggregatorStub proxyish = new WideFallbackAggregatorStub();

        // The fixture really does answer 32 bytes — i.e. it would have passed the old test.
        (bool ok, bytes memory ret) = address(proxyish).staticcall(
            abi.encodeWithSignature("pendingGuardianSlashCount(address)", address(1))
        );
        assertTrue(ok && ret.length == 32, "fixture must answer a full word");

        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(proxyish))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.AmbiguousGuardianSlashCapability.selector, address(proxyish)
            )
        );
        this.callRequireNoPendingCases(address(proxyish));
    }

    /// CC-48 round-7 MEDIUM-1. The sentinel must be indistinguishable from a real call, or
    /// the catch-all detector is itself detectable — and round 6's was, by one `lt`.
    ///
    /// This test asserts the DEFECT first (the fixture really does fabricate a full,
    /// clean word for the pending getter, i.e. it would be read as `Present` by anything
    /// that trusted that answer) and only then asserts the fix. Without the first half the
    /// second half would still pass against a fixture that answered nothing at all.
    function test_AnArgStrictCatchAllCannotForgePresentOrZeroPending() public {
        ArgStrictCatchAllStub selective = new ArgStrictCatchAllStub();

        // 1. It is genuinely a catch-all for real-looking calls: a fabricated 32-byte 0.
        (bool ok, bytes memory ret) = address(selective).staticcall(
            abi.encodeWithSignature("pendingGuardianSlashCount(address)", address(1))
        );
        assertTrue(ok && ret.length == 32, "fixture must fabricate a full word");
        assertEq(abi.decode(ret, (uint256)), 0, "and the fabrication is a zero pending count");

        // 2. It evades a SELECTOR-ONLY sentinel — the round-6 probe shape, reproduced here
        //    so this test fails again if the probe ever regresses to it.
        (ok,) = address(selective).staticcall(
            abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL)
        );
        assertFalse(ok, "the round-6 probe shape is evadable; that is the whole finding");

        // 3. ...and cannot evade the sentinel sent with its declared arguments.
        (ok,) = address(selective).staticcall(
            abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL, bytes32(0), uint256(0))
        );
        assertTrue(ok, "an arg-carrying sentinel is indistinguishable from a real call");

        // 4. So the classifier refuses it instead of reading its fabricated zero.
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(selective))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous),
            "a catch-all must never classify as Present"
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.AmbiguousGuardianSlashCapability.selector, address(selective)
            )
        );
        this.callRequireNoPendingCases(address(selective));
    }

    /// CC-48 round-8 MEDIUM-1. The MIRROR of the test above, and the finding that reopened
    /// it: round 7 replaced `lt(calldatasize(), 36)` with a 68-byte probe, which one
    /// `gt(calldatasize(), 36)` separates from every real getter just as cleanly.
    ///
    /// Asserts the DEFECT first (this fixture really does fabricate clean answers to the
    /// getters the preflight trusts) and only then the fix, so the second half cannot pass
    /// against a fixture that answers nothing.
    function test_ASizeDiscriminatingCatchAllCannotEvadeTheSentinelEither() public {
        SizeDiscriminatingCatchAllStub selective = new SizeDiscriminatingCatchAllStub();

        // 1. It fabricates a clean 32-byte zero for the getter `Present` is built on.
        (bool ok, bytes memory ret) = address(selective).staticcall(
            abi.encodeWithSignature("pendingGuardianSlashCount(address)", address(1))
        );
        assertTrue(ok && ret.length == 32, "fixture must fabricate a full word");
        assertEq(abi.decode(ret, (uint256)), 0, "and the fabrication is a zero pending count");

        // 2. ...and for the getter the TAINT scan is built on: zero slots, zero keys.
        (ok, ret) = address(selective).staticcall(abi.encodeWithSignature("MAX_VALIDATORS()"));
        assertTrue(ok && ret.length == 32, "fixture must fabricate MAX_VALIDATORS too");
        assertEq(abi.decode(ret, (uint256)), 0, "so the key scan would iterate zero times");

        // 3. It evades the ROUND-7 probe shape — 68 bytes — reproduced here so this test
        //    fails again if the probe ever regresses to a single wide width.
        (ok,) = address(selective).staticcall(
            abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL, bytes32(0), uint256(0))
        );
        assertFalse(ok, "the round-7 probe shape is evadable; that is the whole finding");

        // 4. ...but not the 4-byte and 36-byte shapes, which are the widths every real
        //    getter in the library actually uses.
        (ok,) = address(selective).staticcall(abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL));
        assertTrue(ok, "a 4-byte sentinel matches every no-argument getter's shape");
        (ok,) = address(selective).staticcall(
            abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL, bytes32(0))
        );
        assertTrue(ok, "a 36-byte sentinel matches every one-argument getter's shape");

        // 5. So the classifier refuses it instead of reading its fabricated zero.
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(selective))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous),
            "a size-discriminating catch-all must never classify as Present"
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.AmbiguousGuardianSlashCapability.selector, address(selective)
            )
        );
        this.callRequireNoPendingCases(address(selective));
    }

    /// CC-48 round-8 MEDIUM-1, one level below the test above: a catch-all keyed on the
    /// ARGUMENT WORD instead of on `calldatasize`. Sending the 36-byte sentinel with a
    /// single argument value would have reopened the same fail-open a third time, so it is
    /// sent with both values the real probes carry.
    function test_AnArgValueDiscriminatingCatchAllCannotEvadeTheSentinelEither() public {
        ArgValueDiscriminatingCatchAllStub selective = new ArgValueDiscriminatingCatchAllStub();

        // 1. The defect: it fabricates a clean zero for the getter `Present` is built on,
        //    which is probed with `address(1)`.
        (bool ok, bytes memory ret) = address(selective).staticcall(
            abi.encodeWithSignature("pendingGuardianSlashCount(address)", address(1))
        );
        assertTrue(ok && ret.length == 32, "fixture must fabricate a full word");
        assertEq(abi.decode(ret, (uint256)), 0, "and the fabrication is a zero pending count");

        // 2. A zero-argument 36-byte sentinel does NOT see it -- that is the finding.
        (ok,) = address(selective).staticcall(
            abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL, bytes32(0))
        );
        assertFalse(ok, "a single-value sentinel is evadable; that is why two are sent");

        // 3. The non-zero one does.
        (ok,) = address(selective).staticcall(
            abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL, bytes32(uint256(1)))
        );
        assertTrue(ok, "the second argument value closes the mirror case");

        // 4. So it is refused rather than believed.
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(selective))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.AmbiguousGuardianSlashCapability.selector, address(selective)
            )
        );
        this.callRequireNoPendingCases(address(selective));
    }

    /// CC-48 round-8 MEDIUM-1 — THE STATED LIMIT, asserted rather than promised.
    ///
    /// Rounds 6 and 7 both wrote that the sentinel made forgery detectable. It does not,
    /// and cannot: a contract that discriminates by SELECTOR rather than by calldata shape
    /// is indistinguishable from a genuine getter set over a `staticcall` interface, at any
    /// sentinel width. This test pins that down so nobody re-derives the false claim:
    ///   - the liar answers every probed getter with a clean, wrong value;
    ///   - EVERY sentinel width reverts against it;
    ///   - so it classifies `Present` -- the preflight believes it is a real, fully
    ///     featured aggregator -- and then the pending scan RUNS, is fed
    ///     `MAX_VALIDATORS() == 0`, iterates zero times and reports clean.
    /// Note this is NOT the `Absent`/skip path: the check is not skipped, it is executed
    /// against fabricated inputs, which no amount of probing can fix.
    /// The backstop is `requireDeclaredPredecessor` (exercised at the end), not step 0.
    function test_ASelectorWhitelistLiarIsNotDetectableAtTheProbeLayer() public {
        SelectorWhitelistLiarStub liar = new SelectorWhitelistLiarStub();

        // No sentinel width can see it: it has no fallback, so unknown selectors revert.
        (bool ok,) = address(liar).staticcall(abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL));
        assertFalse(ok, "4-byte sentinel reverts");
        (ok,) = address(liar).staticcall(abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL, bytes32(0)));
        assertFalse(ok, "36-byte sentinel reverts");
        (ok,) = address(liar).staticcall(
            abi.encodeWithSelector(BLSKeyScanLib.CATCH_ALL_SENTINEL, bytes32(0), uint256(0))
        );
        assertFalse(ok, "68-byte sentinel reverts");

        // And it is NOT caught. Recorded as the honest scope of step 0, not as a pass.
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(liar))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Present),
            "step 0 cannot detect a selector-whitelist liar -- this is the stated limit"
        );
        // The pending scan runs in full and still reports clean, because every input it
        // reads is fabricated. `MAX_VALIDATORS() == 0` makes the loop body unreachable.
        this.callRequireNoPendingCases(address(liar));

        // The thing that actually keeps it out: it is not what Registry is wired to. A
        // migration can only scan the live predecessor, so reaching the fail-open above
        // requires governance to have already wired this contract in.
        RegistryWiringStub wiring = new RegistryWiringStub();
        wiring.setBLSAggregator(address(0xFEED));
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PredecessorMismatch.selector,
                address(wiring),
                address(liar),
                address(0xFEED)
            )
        );
        this.callRequireDeclaredPredecessor(address(wiring), address(liar));
    }

    /// The width test is `==`, not `>=`: a contract answering the pending getter with the
    /// wrong ABI width is not what its ABI claims, and must not be enumerated.
    function test_AWrongWidthPendingAnswerIsAmbiguous() public {
        WrongWidthPendingStub impostor = new WrongWidthPendingStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(impostor))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.AmbiguousGuardianSlashCapability.selector, address(impostor)
            )
        );
        this.callRequireNoPendingCases(address(impostor));
    }

    /// CC-48 round-6 LOW-1. The version string is printed in a WARNING line next to a
    /// skipped pending-case check; a predecessor returning a malformed dynamic head must
    /// not be able to turn that informational path into an unexplained revert inside a
    /// view library. Both malformed shapes — offset out of range, and length out of range
    /// — degrade to a label and let the preflight finish.
    function test_AMalformedVersionReturnDegradesInsteadOfReverting() public {
        MalformedVersionOffsetStub badOffset = new MalformedVersionOffsetStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(badOffset))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Absent)
        );
        this.callRequireNoPendingCases(address(badOffset)); // pre-fix: abi.decode reverts here

        MalformedVersionLengthStub badLength = new MalformedVersionLengthStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(badLength))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Absent)
        );
        this.callRequireNoPendingCases(address(badLength));
    }

    /// An address with no code at all cannot be reasoned about either.
    function test_AnEmptyAddressIsAmbiguous() public view {
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(0xDEAD))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous)
        );
    }

    // =================================================================
    // Predecessor binding: OLD_BLS_AGGREGATOR must match the live wiring
    // =================================================================

    /// THE round-5 HIGH-1 bypass, closed: on a Registry that already has an aggregator
    /// wired, declaring "first-ever deployment" is rejected. That declaration was the
    /// one operation that switched the tainted-key gate off while printing a line that
    /// read like a normal, successful path.
    function test_DeclaringFirstEverOnALiveRegistryIsRejected() public {
        RegistryWiringStub registry = new RegistryWiringStub();
        registry.setBLSAggregator(address(0x174b60bB));

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PredecessorMismatch.selector,
                address(registry),
                address(0),
                address(0x174b60bB)
            )
        );
        this.callRequireDeclaredPredecessor(address(registry), address(0));
    }

    /// A stale or typo'd predecessor scans the WRONG contract for tainted keys and
    /// reports clean. Caught for the same reason and by the same check.
    function test_DeclaringTheWrongPredecessorIsRejected() public {
        RegistryWiringStub registry = new RegistryWiringStub();
        registry.setBLSAggregator(address(0x174b60bB));

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PredecessorMismatch.selector,
                address(registry),
                address(0xF51c0298),
                address(0x174b60bB)
            )
        );
        this.callRequireDeclaredPredecessor(address(registry), address(0xF51c0298));
    }

    /// The honest declaration passes, and returns the wiring it verified against.
    function test_TheLivePredecessorIsAccepted() public {
        RegistryWiringStub registry = new RegistryWiringStub();
        registry.setBLSAggregator(address(0x174b60bB));
        assertEq(
            BLSKeyScanLib.requireDeclaredPredecessor(address(registry), address(0x174b60bB)),
            address(0x174b60bB)
        );
    }

    /// A genuine first-ever deployment still works — but only because the live Registry
    /// says so, not because the operator typed 0.
    function test_FirstEverIsAcceptedOnlyWhenRegistryHasNoAggregatorWired() public {
        RegistryWiringStub registry = new RegistryWiringStub();
        assertEq(BLSKeyScanLib.requireDeclaredPredecessor(address(registry), address(0)), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PredecessorMismatch.selector,
                address(registry),
                address(0xBEEF),
                address(0)
            )
        );
        this.callRequireDeclaredPredecessor(address(registry), address(0xBEEF));
    }

    // =================================================================
    // External wrappers — `vm.expectRevert` needs a real CALL boundary for a
    // library's internal function to revert across.
    // =================================================================

    function callRequireNoPendingCases(address agg) external view {
        BLSKeyScanLib.requireNoPendingCases(agg);
    }

    function callRequireDeclaredPredecessor(address registry, address declared) external view {
        BLSKeyScanLib.requireDeclaredPredecessor(registry, declared);
    }
}
