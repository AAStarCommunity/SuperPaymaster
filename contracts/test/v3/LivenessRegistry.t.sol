// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {Test} from "forge-std/Test.sol";
import {LivenessRegistry} from "src/core/LivenessRegistry.sol";
import {ILivenessRegistry} from "src/interfaces/v3/ILivenessRegistry.sol";
import {Ownable} from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/// @title LivenessRegistry tests (CC-29)
/// @notice Covers self-attest, the objective offline predicate + its window boundary, never-attested
///         = offline, auto-jail self-heal, batch areOffline, block.number-based archival determinism
///         (via vm.roll), governance window set (onlyOwner + bounds + event + effect), and bounds.
contract LivenessRegistryTest is Test {
    LivenessRegistry internal reg;

    address internal governance = makeAddr("governance");
    address internal op1 = makeAddr("op1");
    address internal op2 = makeAddr("op2");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant WINDOW = 1000; // blocks

    event LivenessAttested(address indexed operator, uint256 atBlock);
    event LivenessWindowUpdated(uint256 oldWindow, uint256 newWindow);

    function setUp() public {
        // Start well past block 0 so `block.number` arithmetic is realistic.
        vm.roll(5_000_000);
        reg = new LivenessRegistry(governance, WINDOW);
    }

    // ── Construction ─────────────────────────────────────────────────────────

    function test_constructor_setsOwnerAndWindow() public view {
        assertEq(reg.owner(), governance);
        assertEq(reg.livenessWindow(), WINDOW);
        assertEq(reg.version(), "LivenessRegistry-1.0.0");
    }

    function test_constructor_revertsOnWindowBelowMin() public {
        uint256 bad = reg.MIN_LIVENESS_WINDOW() - 1;
        vm.expectRevert(abi.encodeWithSelector(ILivenessRegistry.InvalidWindow.selector, bad));
        new LivenessRegistry(governance, bad);
    }

    function test_constructor_revertsOnWindowAboveMax() public {
        uint256 bad = reg.MAX_LIVENESS_WINDOW() + 1;
        vm.expectRevert(abi.encodeWithSelector(ILivenessRegistry.InvalidWindow.selector, bad));
        new LivenessRegistry(governance, bad);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new LivenessRegistry(address(0), WINDOW);
    }

    // ── attestLiveness ─────────────────────────────────────────────────────────

    function test_attest_recordsBlockAndEmits() public {
        vm.expectEmit(true, false, false, true, address(reg));
        emit LivenessAttested(op1, block.number);
        vm.prank(op1);
        reg.attestLiveness();
        assertEq(reg.lastLive(op1), block.number);
    }

    function test_attest_updatesOnReattest() public {
        vm.prank(op1);
        reg.attestLiveness();
        uint256 first = reg.lastLive(op1);

        vm.roll(block.number + 42);
        vm.prank(op1);
        reg.attestLiveness();
        assertEq(reg.lastLive(op1), first + 42);
    }

    // ── isOffline: never attested ──────────────────────────────────────────────

    function test_isOffline_neverAttested_isTrue() public view {
        assertEq(reg.lastLive(op1), 0);
        assertTrue(reg.isOffline(op1));
    }

    // ── isOffline: window boundary ─────────────────────────────────────────────

    function test_isOffline_liveImmediatelyAfterAttest() public {
        vm.prank(op1);
        reg.attestLiveness();
        assertFalse(reg.isOffline(op1));
    }

    function test_isOffline_atExactlyWindowEdge_stillLive() public {
        vm.prank(op1);
        reg.attestLiveness();
        uint256 last = reg.lastLive(op1);
        // block.number == last + window  → NOT offline (predicate is strict `>`).
        vm.roll(last + WINDOW);
        assertFalse(reg.isOffline(op1));
    }

    function test_isOffline_oneBlockPastWindow_isOffline() public {
        vm.prank(op1);
        reg.attestLiveness();
        uint256 last = reg.lastLive(op1);
        vm.roll(last + WINDOW + 1);
        assertTrue(reg.isOffline(op1));
    }

    // ── auto-jail self-heal ────────────────────────────────────────────────────

    function test_selfHeal_reattestClearsOffline() public {
        vm.prank(op1);
        reg.attestLiveness();
        vm.roll(reg.lastLive(op1) + WINDOW + 500); // drift into offline
        assertTrue(reg.isOffline(op1));

        vm.prank(op1);
        reg.attestLiveness(); // permissionless self-heal
        assertFalse(reg.isOffline(op1));
    }

    // ── batch areOffline (live-set denominator) ────────────────────────────────

    function test_areOffline_batchMixedSet() public {
        // op2 attests, then time drifts past its window; stranger never attests.
        vm.prank(op2);
        reg.attestLiveness();
        vm.roll(reg.lastLive(op2) + WINDOW + 1);
        // op1 attests fresh AFTER the drift, so only op1 is live at read time.
        vm.prank(op1);
        reg.attestLiveness();

        address[] memory ops = new address[](3);
        ops[0] = op1;
        ops[1] = op2;
        ops[2] = stranger;
        bool[] memory res = reg.areOffline(ops);

        assertFalse(res[0], "op1 live");
        assertTrue(res[1], "op2 drifted offline");
        assertTrue(res[2], "stranger never attested");

        // Empty input is a valid no-op.
        assertEq(reg.areOffline(new address[](0)).length, 0);
    }

    // ── archival determinism: block.number drives the predicate ────────────────

    /// @dev DVT pins `blockTag=epoch`; the archive node runs the view with `block.number == epoch`.
    ///      This test mimics that: the SAME operator+state is live at one block height and offline at
    ///      a later one, deterministically, purely from `block.number` — no caller-supplied block.
    function test_determinism_predicateFollowsExecutingBlock() public {
        vm.prank(op1);
        reg.attestLiveness();
        uint256 last = reg.lastLive(op1);

        vm.roll(last + WINDOW); // "epoch A" — within window
        assertFalse(reg.isOffline(op1));

        vm.roll(last + WINDOW + 1); // "epoch B" — past window
        assertTrue(reg.isOffline(op1));
    }

    // ── governance: setLivenessWindow ──────────────────────────────────────────

    function test_setWindow_onlyOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        vm.prank(stranger);
        reg.setLivenessWindow(2000);
    }

    function test_setWindow_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(reg));
        emit LivenessWindowUpdated(WINDOW, 2000);
        vm.prank(governance);
        reg.setLivenessWindow(2000);
        assertEq(reg.livenessWindow(), 2000);
    }

    function test_setWindow_boundsEnforced() public {
        uint256 min = reg.MIN_LIVENESS_WINDOW();
        uint256 max = reg.MAX_LIVENESS_WINDOW();

        vm.startPrank(governance);

        vm.expectRevert(abi.encodeWithSelector(ILivenessRegistry.InvalidWindow.selector, min - 1));
        reg.setLivenessWindow(min - 1);

        vm.expectRevert(abi.encodeWithSelector(ILivenessRegistry.InvalidWindow.selector, max + 1));
        reg.setLivenessWindow(max + 1);

        // Boundaries themselves are valid.
        reg.setLivenessWindow(min);
        assertEq(reg.livenessWindow(), min);
        reg.setLivenessWindow(max);
        assertEq(reg.livenessWindow(), max);

        vm.stopPrank();
    }

    /// @dev Shrinking the window can flip a previously-live operator to offline — the fleet-sensitive
    ///      direction the interface warns about (owner SHOULD be a timelock/multisig).
    function test_setWindow_shrinkFlipsLiveToOffline() public {
        vm.prank(op1);
        reg.attestLiveness();
        uint256 last = reg.lastLive(op1);

        vm.roll(last + 500); // within the 1000-block window → live
        assertFalse(reg.isOffline(op1));

        // Cache the view BEFORE pranking — an external call in the argument would consume the prank.
        uint256 minWindow = reg.MIN_LIVENESS_WINDOW();
        vm.prank(governance);
        reg.setLivenessWindow(minWindow); // 100 < 500 elapsed → now offline
        assertTrue(reg.isOffline(op1));
    }

    // ── fuzz: predicate is exactly `elapsed > window` ──────────────────────────

    function testFuzz_isOffline_matchesElapsedVsWindow(uint256 window, uint96 elapsed) public {
        window = bound(window, reg.MIN_LIVENESS_WINDOW(), reg.MAX_LIVENESS_WINDOW());
        vm.prank(governance);
        reg.setLivenessWindow(window);

        vm.prank(op1);
        reg.attestLiveness();
        uint256 last = reg.lastLive(op1);

        vm.roll(last + uint256(elapsed));
        assertEq(reg.isOffline(op1), uint256(elapsed) > window);
    }
}
