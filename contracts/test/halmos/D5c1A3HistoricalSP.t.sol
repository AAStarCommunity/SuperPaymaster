// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsV2Base } from "src/tokens/v2/xPNTsV2Base.sol";
import { V2TokenDeployer, IxPNTsV2Admin } from "../helpers/V2TokenDeployer.sol";
import { MockRegistryV2, DummySpender, IExt } from "../helpers/V2TestFixtures.sol";

/**
 * @title D5c-1 A-3 follow-ups (PR #465 reviewer Lows): historicalSP spender guards and the
 *        emergency-switch rotation path.
 * @notice Companion to D5c1A3Negatives.t.sol, same fixtures, exact v5.5.0-rc.2 source.
 *   HSP-1  `activateSpender` rejects a spender that became the SP (current or historical) while
 *          its 48 h spender proposal was pending, with `InvalidAddress(spender)`
 *          (xPNTsTokenV2Ext.activateSpender `historicalSP` guard). Three entry paths into
 *          historicalSP: activateSP (still current), activateSP then rotated out (historical
 *          only), emergencySwitchToStandby. Positive control: a fresh approved spender proposed
 *          at the same time activates after 48 h.
 *   HSP-2  `proposeSpender` rejects a historical (no longer current) SP with
 *          `InvalidAddress(spender)` — isolates the `historicalSP` term from the
 *          `== SUPERPAYMASTER_ADDRESS` term of the proposal guard.
 *   ESW    NEG-2 variant via S-4/S-5/S-6: an auto-approved spender designated as standby and
 *          switched in by `emergencySwitchToStandby` is removed from autoApprovedSpenders in the
 *          same call (`AutoApprovedSpenderRemoved` before `SuperPaymasterAddressUpdated`), is
 *          historicalSP, its allowance reads 0 despite an unlimited explicit approval, and
 *          transferFrom / burn(from) revert `SPCannotTransfer`; the revoked previous SP stays
 *          banned as well; both bans survive clearing the emergency and a later rotation.
 */
/// @dev Time is read with `vm.getBlockTimestamp()`: under via_ir `block.timestamp` may be folded to
///      its value at the start of the test call, so repeated `vm.warp(block.timestamp + ...)` would
///      not advance.
contract D5c1A3HistoricalSPTest is Test {
    address internal sp = address(0x5B);
    address internal owner_ = address(0xC0);
    address internal community = address(0xC1);
    address internal user = address(0xB0B);
    MockRegistryV2 internal registry;
    V2TokenDeployer.Stack internal st;
    xPNTsTokenV2 internal tok;

    function setUp() public {
        registry = new MockRegistryV2();
        st = V2TokenDeployer.deployStack(sp, address(registry));
        tok = V2TokenDeployer.newToken(st, owner_, community, sp, 1 ether);
    }

    /// Approved both as a spender implementation (codehash) and as an SP (address key).
    function _dualApproved() internal returns (DummySpender x) {
        x = new DummySpender();
        st.aoa.bootstrapApprove(st.aoa.KIND_SPENDER(), address(x).codehash);
        V2TokenDeployer.approveSP(st, address(x));
        assertTrue(st.aoa.isApprovedSP(address(x)), "fixture: x is an approved SP");
        assertTrue(st.aoa.isApprovedImpl(st.aoa.KIND_SPENDER(), address(x)), "fixture: x is an approved spender impl");
    }

    function _rotateTo(address newSP) internal {
        vm.prank(owner_);
        IExt(address(tok)).proposeSP(newSP);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IExt(address(tok)).activateSP();
        assertEq(tok.SUPERPAYMASTER_ADDRESS(), newSP, "fixture: rotated");
    }

    function _proposeSpender(address s) internal {
        vm.prank(owner_);
        IExt(address(tok)).proposeSpender(s);
        assertEq(tok.spenderActivatesAt(s), uint64(vm.getBlockTimestamp() + 48 hours), "fixture: spender pending");
    }

    function _expectActivateRejected(address s) internal {
        // A nonzero stored approval makes the allowance view assertion meaningful.
        vm.prank(user);
        tok.approve(s, type(uint256).max);
        assertTrue(tok.historicalSP(s), "pre: spender is historicalSP");
        assertGe(vm.getBlockTimestamp(), tok.spenderActivatesAt(s), "pre: timelock elapsed (guard is the only cause)");
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, s));
        IExt(address(tok)).activateSpender(s);
        assertFalse(tok.autoApprovedSpenders(s), "HSP-1: historical SP not auto-approved");
        assertEq(tok.allowance(user, s), 0, "HSP-1: historical SP allowance 0");
    }

    // ============================================================ HSP-1 activateSpender guard

    /// Spender proposal pending -> x becomes the CURRENT SP -> activation rejected.
    function test_D5c1_A3_HSP1_activateSpenderRejectsCurrentSP() public {
        DummySpender x = _dualApproved();
        DummySpender z = _dualApproved(); // positive control, proposed in the same block
        _proposeSpender(address(x));
        _proposeSpender(address(z));
        _rotateTo(address(x)); // warps 48 h: both spender timelocks elapsed
        _expectActivateRejected(address(x));
        // positive control: same timing, not an SP -> activates
        IExt(address(tok)).activateSpender(address(z));
        assertTrue(tok.autoApprovedSpenders(address(z)), "control: fresh spender activated after 48h");
        assertEq(tok.spenderActivatesAt(address(z)), 0, "control: pending entry consumed");
    }

    /// Spender proposal pending -> x becomes SP -> x rotated OUT (historical only) -> rejected.
    function test_D5c1_A3_HSP1_activateSpenderRejectsHistoricalSP() public {
        DummySpender x = _dualApproved();
        _proposeSpender(address(x));
        _rotateTo(address(x));
        address y = address(0x5C);
        V2TokenDeployer.approveSP(st, y);
        _rotateTo(y);
        assertTrue(tok.SUPERPAYMASTER_ADDRESS() != address(x), "pre: x no longer current");
        _expectActivateRejected(address(x));
    }

    /// Spender proposal pending -> x switched in via emergencySwitchToStandby -> rejected.
    function test_D5c1_A3_HSP1_activateSpenderRejectsEmergencyStandbySP() public {
        DummySpender x = _dualApproved();
        _proposeSpender(address(x));
        vm.prank(owner_);
        IExt(address(tok)).proposeStandby(address(x));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IExt(address(tok)).activateStandbyDesignation();
        vm.startPrank(owner_);
        IExt(address(tok)).emergencyRevokePaymaster();
        IExt(address(tok)).emergencySwitchToStandby();
        vm.stopPrank();
        assertEq(tok.SUPERPAYMASTER_ADDRESS(), address(x), "pre: x switched in");
        _expectActivateRejected(address(x));
    }

    /// Positive control for HSP-1 on its own: a fresh spender activates at exactly eta, not before.
    function test_D5c1_A3_HSP1_control_freshSpenderActivatesAfter48h() public {
        DummySpender z = _dualApproved();
        _proposeSpender(address(z));
        uint64 eta = tok.spenderActivatesAt(address(z));
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.TimelockActive.selector, eta));
        IExt(address(tok)).activateSpender(address(z));
        vm.warp(eta);
        vm.expectEmit(true, false, false, true, address(tok));
        emit xPNTsV2Base.AutoApprovedSpenderAdded(address(z));
        IExt(address(tok)).activateSpender(address(z));
        assertTrue(tok.autoApprovedSpenders(address(z)), "control: activated");
        assertFalse(tok.historicalSP(address(z)), "control: not an SP");
    }

    // ============================================================ HSP-2 proposeSpender guard

    function test_D5c1_A3_HSP2_proposeSpenderRejectsHistoricalSP() public {
        // x is an approved spender implementation, so the ONLY reason left to reject is historicalSP
        DummySpender x = _dualApproved();
        _rotateTo(address(x));
        address y = address(0x5C);
        V2TokenDeployer.approveSP(st, y);
        _rotateTo(y);
        assertTrue(tok.historicalSP(address(x)), "pre: x historical");
        assertTrue(tok.SUPERPAYMASTER_ADDRESS() != address(x), "pre: x not current");
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, address(x)));
        IExt(address(tok)).proposeSpender(address(x));
        assertEq(tok.spenderActivatesAt(address(x)), 0, "HSP-2: nothing pending");
    }

    // ============================================================ ESW emergencySwitchToStandby

    function test_D5c1_A3_ESW_spenderSwitchedInAsStandbyIsRemoved() public {
        DummySpender x = _dualApproved();
        _proposeSpender(address(x));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IExt(address(tok)).activateSpender(address(x));

        IxPNTsV2Admin(address(tok)).mint(user, 1_000 ether); // test contract = FACTORY
        assertTrue(tok.autoApprovedSpenders(address(x)), "pre: x auto-approved");
        assertFalse(tok.historicalSP(address(x)), "pre: x not historical SP");
        vm.startPrank(user);
        IExt(address(tok)).setAutoAllowance(address(x), 100 ether);
        tok.approve(address(x), type(uint256).max);
        tok.approve(sp, type(uint256).max);
        vm.stopPrank();
        assertGt(tok.allowance(user, address(x)), 0, "pre: x has allowance");
        x.pull(address(tok), user, 1 ether); // pre-switch x CAN pull
        assertEq(tok.balanceOf(address(x)), 1 ether, "pre: x pulled 1");

        // ---- S-5: designate x as standby (grants no privilege, not historical)
        vm.prank(owner_);
        IExt(address(tok)).proposeStandby(address(x));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IExt(address(tok)).activateStandbyDesignation();
        assertEq(tok.standbySP(), address(x));
        assertFalse(tok.historicalSP(address(x)), "standby designation does not mark historicalSP");
        assertTrue(tok.autoApprovedSpenders(address(x)), "standby designation keeps spender");

        // ---- S-4 + S-6: revoke the current SP, switch to the standby
        vm.prank(owner_);
        IExt(address(tok)).emergencyRevokePaymaster();
        assertEq(tok.emergencyRevokedAddress(), sp);
        vm.recordLogs();
        vm.expectEmit(true, false, false, true, address(tok));
        emit xPNTsV2Base.AutoApprovedSpenderRemoved(address(x));
        vm.expectEmit(true, true, false, true, address(tok));
        emit xPNTsV2Base.SuperPaymasterAddressUpdated(sp, address(x));
        vm.prank(owner_);
        IExt(address(tok)).emergencySwitchToStandby();
        Vm.Log[] memory all = vm.getRecordedLogs();
        bytes32[] memory t = new bytes32[](all.length);
        uint256 n;
        for (uint256 i; i < all.length; ++i) if (all[i].emitter == address(tok)) t[n++] = all[i].topics[0];
        assertEq(n, 2, "switch: the token emits exactly Removed + Updated");
        assertEq(t[0], xPNTsV2Base.AutoApprovedSpenderRemoved.selector, "first token log: spender removed");
        assertEq(t[1], xPNTsV2Base.SuperPaymasterAddressUpdated.selector, "second token log: SP updated");
        assertEq(tok.SUPERPAYMASTER_ADDRESS(), address(x));
        assertEq(tok.standbySP(), address(0), "standby consumed");

        _assertBanned(address(x), "as switched-in SP");
        _assertBanned(sp, "revoked previous SP");

        // ---- clear the emergency: the bans are not tied to emergencyDisabled
        vm.prank(owner_);
        IExt(address(tok)).unsetEmergencyDisabled();
        assertFalse(tok.emergencyDisabled());
        _assertBanned(address(x), "after emergency cleared");
        _assertBanned(sp, "previous SP after emergency cleared");

        // ---- rotate x OUT: sticky
        address y = address(0x5C);
        V2TokenDeployer.approveSP(st, y);
        _rotateTo(y);
        _assertBanned(address(x), "as historical SP");
        _assertBanned(sp, "revoked previous SP after rotation");
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, address(x)));
        IExt(address(tok)).proposeSpender(address(x));
    }

    function _assertBanned(address a, string memory when) internal {
        uint256 bal = tok.balanceOf(user);
        uint256 supply = tok.totalSupply();
        assertFalse(tok.autoApprovedSpenders(a), string.concat("removed from autoApprovedSpenders ", when));
        assertTrue(tok.historicalSP(a), string.concat("historicalSP ", when));
        assertEq(tok.allowance(user, a), 0, string.concat("allowance reads 0 ", when));
        vm.startPrank(a);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        tok.transferFrom(user, a, 1 ether);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        tok.transferFrom(user, address(0xDEAD), 1 ether);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        tok.burn(user, 1 ether);
        vm.stopPrank();
        assertEq(tok.balanceOf(user), bal, string.concat("user balance untouched ", when));
        assertEq(tok.totalSupply(), supply, string.concat("supply untouched ", when));
    }
}
