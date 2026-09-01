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
            uint256(c.classify(NONE, NONE, NONE, NONE, true)),
            uint256(Check11_AggregatorPointers.Verdict.Unconfigured),
            "an unwired stack must not be reported as consistent"
        );
    }

    /// A zero among non-zeros is still a split, not an unconfigured stack.
    function test_SettledSplit_OnePointerZeroedWhileOthersSet() public view {
        assertEq(uint256(c.classify(A, NONE, A, NONE, true)), uint256(Check11_AggregatorPointers.Verdict.SettledSplit));
    }

    /// Three pointers can agree on something that is not a contract at all.
    function test_NotAContract_ThreeAgreeOnACodelessAddress() public view {
        assertEq(
            uint256(c.classify(A, A, A, NONE, false)),
            uint256(Check11_AggregatorPointers.Verdict.NotAContract),
            "agreement says they were configured together, not that the target exists"
        );
    }

    /// Zero is reported as Unconfigured, not NotAContract: the operator action differs
    /// (wire it vs fix the address), so the two must not collapse into one message.
    function test_Unconfigured_TakesPrecedenceOverMissingCode() public view {
        assertEq(
            uint256(c.classify(NONE, NONE, NONE, NONE, false)), uint256(Check11_AggregatorPointers.Verdict.Unconfigured)
        );
    }

    function test_Ok_AllThreeAgreeAndNothingQueued() public view {
        assertEq(uint256(c.classify(A, A, A, NONE, true)), uint256(Check11_AggregatorPointers.Verdict.Ok));
    }

    /// Re-queuing the value already in force is harmless: applying it changes nothing.
    function test_Ok_QueuedRotationTargetsTheSameAddress() public view {
        assertEq(uint256(c.classify(A, A, A, A, true)), uint256(Check11_AggregatorPointers.Verdict.OkRequeueSameValue));
    }

    /// THE REGRESSION. Three agree, but SP is queued to move somewhere else.
    /// The first version of this check returned OK here.
    function test_ArmedSplit_QueuedRotationToAnotherAddressIsNotOk() public view {
        assertEq(
            uint256(c.classify(A, A, A, B, true)),
            uint256(Check11_AggregatorPointers.Verdict.ArmedSplit),
            "three agreeing pointers + a rotation queued elsewhere is a split waiting to happen"
        );
    }

    /// The state this repository was actually in on 2026-08-30..09-01: Registry moved
    /// first, SP and DVTValidator left behind, and an SP rotation queued to catch up.
    function test_RotationInFlight_MatchesTheRealIncidentShape() public view {
        assertEq(uint256(c.classify(B, A, A, B, true)), uint256(Check11_AggregatorPointers.Verdict.RotationInFlight));
    }

    /// The same incident BEFORE the queue existed: one pointer moved, nothing pending.
    function test_SettledSplit_OnePointerMovedAndNothingPending() public view {
        assertEq(uint256(c.classify(B, A, A, NONE, true)), uint256(Check11_AggregatorPointers.Verdict.SettledSplit));
    }

    /// A split can also be DVTValidator alone lagging; it must not be reported as OK.
    function test_SettledSplit_DvtValidatorAloneLagging() public view {
        assertEq(uint256(c.classify(B, B, A, NONE, true)), uint256(Check11_AggregatorPointers.Verdict.SettledSplit));
    }
}
