// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {Check11_AggregatorPointers} from "../../script/checks/Check11_AggregatorPointers.s.sol";

/**
 * @title Check11ClassifyTest
 * @notice Pins every branch of the aggregator-pointer verdict, including the one the
 *         first version of the check got wrong.
 *
 * @dev    THE BRANCH THAT MATTERS. The original check computed
 *         `agree = (registry == sp) && (sp == dvt)` and returned OK on `agree`, never
 *         looking at `pendingBLSAgg`. So a stack whose three pointers agree TODAY, with
 *         a matured SP rotation queued to a DIFFERENT address, passed — while the very
 *         next `applyBLSAggregator()` would move SP alone and split them. A gate that is
 *         green right up until a routine call breaks the invariant is not guarding it.
 *         `test_ArmedSplit_QueuedRotationToAnotherAddressIsNotOk` is that case.
 *
 *         The verdict is a pure function precisely so these four states can be asserted
 *         here rather than only observed against whatever the live chain happens to be in.
 */
contract Check11ClassifyTest is Test {
    Check11_AggregatorPointers internal c;

    address constant A = address(0xA11); // current aggregator
    address constant B = address(0xB22); // some other aggregator
    address constant NONE = address(0);

    function setUp() public {
        c = new Check11_AggregatorPointers();
    }

    /// Three zeros "agree". The first two versions of this function called that Ok.
    function test_Unconfigured_ThreeZerosIsNotHealth() public view {
        assertEq(
            uint256(c.classify(NONE, NONE, NONE, NONE, true, NONE, true)),
            uint256(Check11_AggregatorPointers.Verdict.Unconfigured),
            "an unwired stack must not be reported as consistent"
        );
    }

    /// A zero among non-zeros is still a split, not an unconfigured stack.
    function test_SettledSplit_OnePointerZeroedWhileOthersSet() public view {
        assertEq(
            uint256(c.classify(A, NONE, A, NONE, true, A, true)),
            uint256(Check11_AggregatorPointers.Verdict.SettledSplit)
        );
    }

    /// Three pointers can agree on something that is not a contract at all.
    function test_NotAContract_ThreeAgreeOnACodelessAddress() public view {
        assertEq(
            uint256(c.classify(A, A, A, NONE, false, A, true)),
            uint256(Check11_AggregatorPointers.Verdict.NotAContract),
            "agreement says they were configured together, not that the target exists"
        );
    }

    /// Zero is reported as Unconfigured, not NotAContract: the operator action differs
    /// (wire it vs fix the address), so the two must not collapse into one message.
    function test_Unconfigured_TakesPrecedenceOverMissingCode() public view {
        assertEq(
            uint256(c.classify(NONE, NONE, NONE, NONE, false, NONE, true)),
            uint256(Check11_AggregatorPointers.Verdict.Unconfigured)
        );
    }

    /// The chain can be perfectly consistent while the file every consumer reads is not.
    function test_RecordStale_ChainAgreesButConfigStillNamesTheOldAggregator() public view {
        assertEq(
            uint256(c.classify(A, A, A, NONE, true, B, true)),
            uint256(Check11_AggregatorPointers.Verdict.RecordStale),
            "on-chain agreement says nothing about the record downstream reads"
        );
    }

    /// @notice A SuperPaymaster older than P0-3 has no pendingBLSAgg() at all. run()
    ///         cannot read a queue there, and the earlier version of this script died
    ///         on that read before ever reaching a verdict. The fallback must not be
    ///         "pending = 0" — that would report OK while asserting a 24h delay on
    ///         who-may-slash that this deployment does not have.
    function test_LegacyNoTimelock_AgreementWithoutTheDelayIsNotPlainOk() public view {
        assertEq(
            uint256(c.classify(A, A, A, NONE, true, A, false)),
            uint256(Check11_AggregatorPointers.Verdict.LegacyNoTimelock)
        );
        // Same inputs, timelock present -> the plain Ok. The flag is the only difference.
        assertEq(uint256(c.classify(A, A, A, NONE, true, A, true)), uint256(Check11_AggregatorPointers.Verdict.Ok));
    }

    /// @notice The op-sepolia state that made this finding concrete: Registry and
    ///         DVTValidator agree on one address, SP reads zero, and SP is 3.2.2 so the
    ///         pending read reverts. The verdict must still be the split, not a revert.
    function test_LegacyNoTimelock_SplitIsStillClassifiedWithoutAPendingRead() public view {
        assertEq(
            uint256(c.classify(A, NONE, A, NONE, true, A, false)),
            uint256(Check11_AggregatorPointers.Verdict.SettledSplit)
        );
    }

    /// @notice The legacy flag must not outrank the states that are checked earlier.
    ///         An unwired or codeless stack is still that, whatever the SP version.
    function test_LegacyNoTimelock_DoesNotMaskUnconfiguredOrStaleRecord() public view {
        assertEq(
            uint256(c.classify(NONE, NONE, NONE, NONE, true, NONE, false)),
            uint256(Check11_AggregatorPointers.Verdict.Unconfigured)
        );
        assertEq(
            uint256(c.classify(A, A, A, NONE, true, B, false)), uint256(Check11_AggregatorPointers.Verdict.RecordStale)
        );
        assertEq(
            uint256(c.classify(A, A, A, NONE, false, A, false)),
            uint256(Check11_AggregatorPointers.Verdict.NotAContract)
        );
    }

    function test_Ok_AllThreeAgreeAndNothingQueued() public view {
        assertEq(uint256(c.classify(A, A, A, NONE, true, A, true)), uint256(Check11_AggregatorPointers.Verdict.Ok));
    }

    /// Re-queuing the value already in force is harmless: applying it changes nothing.
    function test_Ok_QueuedRotationTargetsTheSameAddress() public view {
        assertEq(
            uint256(c.classify(A, A, A, A, true, A, true)),
            uint256(Check11_AggregatorPointers.Verdict.OkRequeueSameValue)
        );
    }

    /// THE REGRESSION. Three agree, but SP is queued to move somewhere else.
    /// The first version of this check returned OK here.
    function test_ArmedSplit_QueuedRotationToAnotherAddressIsNotOk() public view {
        assertEq(
            uint256(c.classify(A, A, A, B, true, A, true)),
            uint256(Check11_AggregatorPointers.Verdict.ArmedSplit),
            "three agreeing pointers + a rotation queued elsewhere is a split waiting to happen"
        );
    }

    /// The state this repository was actually in on 2026-08-30..09-01: Registry moved
    /// first, SP and DVTValidator left behind, and an SP rotation queued to catch up.
    function test_RotationInFlight_MatchesTheRealIncidentShape() public view {
        assertEq(
            uint256(c.classify(B, A, A, B, true, B, true)), uint256(Check11_AggregatorPointers.Verdict.RotationInFlight)
        );
    }

    /// The same incident BEFORE the queue existed: one pointer moved, nothing pending.
    function test_SettledSplit_OnePointerMovedAndNothingPending() public view {
        assertEq(
            uint256(c.classify(B, A, A, NONE, true, B, true)), uint256(Check11_AggregatorPointers.Verdict.SettledSplit)
        );
    }

    /// A split can also be DVTValidator alone lagging; it must not be reported as OK.
    function test_SettledSplit_DvtValidatorAloneLagging() public view {
        assertEq(
            uint256(c.classify(B, B, A, NONE, true, B, true)), uint256(Check11_AggregatorPointers.Verdict.SettledSplit)
        );
    }

    // ---------------------------------------------------------------------------
    // EXPECT_AGGREGATOR_ROTATION_TO — the only path that turns a red gate green.
    // The live shape these encode: sepolia mid-rotation on 2026-09-01, Registry
    // already at 4.11.0 (EaeC), SP and DVTValidator still at 4.3.0 (OLD), SP queued
    // to EaeC. Every case below was also run against that chain.
    // ---------------------------------------------------------------------------

    address constant OLD = address(0x174b);
    address constant THIRD = address(0xC0DE);

    function test_Declared_TheRealSepoliaRotationIsAccepted() public view {
        (bool holds, address other,) = c.checkDeclaredTarget(A, OLD, OLD, A, A, true);
        assertTrue(holds, "a declared rotation matching the chain must pass");
        assertEq(other, OLD, "the address being rotated away from is reported");
    }

    /// @notice The bug this function was extracted to fix. "Moved or zero" rejected
    ///         the real rotation, because an untouched pointer holds the OLD address.
    function test_Declared_UntouchedPointersHoldTheOldAddressNotZero() public view {
        (bool holds,,) = c.checkDeclaredTarget(OLD, OLD, OLD, A, A, true);
        assertTrue(holds, "queued but nothing moved yet is still the declared rotation");
    }

    function test_Declared_AThirdAddressAnywhereIsRejected() public view {
        (bool holds,, string memory why) = c.checkDeclaredTarget(A, OLD, THIRD, A, A, true);
        assertFalse(holds);
        assertEq(why, "the pointers name more than two distinct addresses");
    }

    /// @notice Declaring the OLD address as the target while SP is queued elsewhere.
    ///         Ran against live sepolia; stayed red.
    function test_Declared_QueueToSomewhereElseIsRejected() public view {
        (bool holds,, string memory why) = c.checkDeclaredTarget(A, OLD, OLD, A, OLD, true);
        assertFalse(holds);
        assertEq(why, "SP has a rotation queued to a different address");
    }

    /// @notice An unrelated address, the op-sepolia aggregator in the live run.
    ///         Nothing is moving toward it, so the declaration is a wish.
    function test_Declared_ATargetNothingIsMovingTowardIsRejected() public view {
        (bool holds,, string memory why) = c.checkDeclaredTarget(OLD, OLD, OLD, NONE, A, true);
        assertFalse(holds);
        assertEq(why, "nothing on-chain points at, or is queued to, the target");
    }

    function test_Declared_ACodelessTargetIsRejected() public view {
        (bool holds,, string memory why) = c.checkDeclaredTarget(A, OLD, OLD, A, A, false);
        assertFalse(holds);
        assertEq(why, "the declared target has no code on this chain");
    }

    /// @notice A zero pointer is not "not moved yet" — a rotation never passes through
    ///         zero, `setBLSAggregator` goes old -> new in one call. Reading it as benign
    ///         let the declaration flag pass an unwired stack: SP.BLS_AGGREGATOR == 0 with
    ///         a queue to the target classifies as RotationInFlight, which is releasable.
    ///         Before the tightening this returned holds == true. Found by pr-daemon.
    function test_Declared_AnUnsetPointerIsNotARotationState() public view {
        (bool holds,, string memory why) = c.checkDeclaredTarget(A, NONE, A, A, A, true);
        assertFalse(holds, "an unset SP pointer must not be waved through by a declaration");
        assertEq(why, "a pointer is unset; that is not a rotation state");
    }

    /// @notice The op-sepolia shape exactly: SP torn out, DVT still on the old address.
    function test_Declared_UnsetPointerRejectedEvenMidTransition() public view {
        (bool holds,,) = c.checkDeclaredTarget(A, NONE, OLD, A, A, true);
        assertFalse(holds);
    }
}
