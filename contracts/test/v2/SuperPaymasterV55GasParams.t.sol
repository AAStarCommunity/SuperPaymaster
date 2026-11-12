// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SuperPaymasterLens} from "src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import {Math} from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {AOAProtocolRegistry} from "src/tokens/v2/AOAProtocolRegistry.sol";
import {GlobalTierSource} from "src/tokens/v2/GlobalTierSource.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";
import {xPNTsTokenV2Ext} from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import {xPNTsFactoryV2} from "src/tokens/v2/xPNTsFactoryV2.sol";
import {V55Registry, V55PriceFeed, V55APNTs, IV2Ext} from "../helpers/V55TestFixtures.sol";

/**
 * @title SuperPaymasterV55GasParamsTest — exp/params: the four gas parameters as owner-settable,
 *        48 h-timelocked storage (one slot) with hard bounds checked at queue AND execute.
 */
contract SuperPaymasterV55GasParamsTest is Test {
    error FloorProbeResult(uint8 kind);
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    SuperPaymaster sp;
    SuperPaymasterLens lens;
    xPNTsTokenV2 token;
    V55Registry registry;
    address owner = address(0x0A11);
    address operator = address(0x0BE);
    address user = address(0xA11CE);
    address stranger = address(0xBAD);

    uint256 constant GAS_PARAMS_SLOT = 38; // appended after `_inflight` (slot 37)

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(EP),
            IRegistry(address(registry)),
            address(new V55PriceFeed()),
            owner,
            address(apnts),
            owner,
            3600
        );
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(
            address(sp), address(registry), address(new xPNTsTokenV2(address(aoa), address(ext))), address(tier)
        );
        sp.setXPNTsFactory(address(factory));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        sp.updatePrice();
        apnts.mint(operator, 1_000_000 ether);
        vm.stopPrank();
        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), owner);
        sp.deposit(100_000 ether);
        IV2Ext(address(token)).mint(user, 10_000 ether);
        vm.stopPrank();
        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);
        lens = new SuperPaymasterLens();
    }

    // ------------------------------------------------------------------ helpers

    function _cur() internal view returns (SuperPaymaster.GasParams memory c) {
        (c,) = sp.gasParams();
    }

    function _pend() internal view returns (SuperPaymaster.PendingGasParams memory p) {
        (, p) = sp.gasParams();
    }

    function _set(uint32 minPost, uint32 settle, uint32 cWrap, uint32 cPostop) internal {
        vm.prank(owner);
        sp.queueGasParams(minPost, settle, cWrap, cPostop);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(owner);
        sp.executeGasParams();
        sp.updatePrice();
    }

    function _op(uint128 postOpGas) internal view returns (PackedUserOperation memory op) {
        op.sender = user;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(700_000), postOpGas, operator, type(uint256).max, address(token), uint8(0)
        );
    }

    function _validates(uint128 postOpGas, bytes32 h) internal returns (bool ok, bytes memory ctx) {
        PackedUserOperation memory op = _op(postOpGas);
        vm.prank(EP);
        uint256 vd;
        (ctx, vd) = sp.validatePaymasterUserOp(op, h, 1e16);
        ok = vd & 1 == 0;
    }

    // ------------------------------------------------------------------ defaults / storage

    function test_defaults_when_never_set_and_slot_position() public view {
        SuperPaymaster.GasParams memory c = _cur();
        assertEq(c.minPostOpGas, 500_000);
        assertEq(c.settleGasBound, 450_000);
        assertEq(c.cWrap, 5_000);
        assertEq(c.cPostop, 450_000);
        assertEq(_pend().eta, 0, "nothing pending");
        assertEq(vm.load(address(sp), bytes32(GAS_PARAMS_SLOT)), bytes32(0), "slot 38 zero = defaults (upgrade-safe)");
        assertEq(sp.version(), "SuperPaymaster-5.5.1");
    }

    function test_unset_defaults_drive_validation_and_match_explicit_release_tuple_in_lens() public {
        assertEq(vm.load(address(sp), bytes32(GAS_PARAMS_SLOT)), bytes32(0), "precondition: unset slot");
        (bool belowOk, bytes memory belowCtx) = _validates(499_999, keccak256("unset-below"));
        assertFalse(belowOk, "unset default rejects below 500k");
        assertEq(belowCtx.length, 0, "validation rejection has no context");
        (bool atOk, bytes memory atCtx) = _validates(500_000, keccak256("unset-at"));
        assertTrue(atOk, "unset default admits 500k");
        uint256 snap;
        assembly ("memory-safe") { snap := mload(add(atCtx, 384)) }
        assertEq(uint32(snap), 500_000, "context snapshots default MIN");
        assertEq(uint32(snap >> 32), 450_000, "context snapshots default SETTLE");
        assertEq(uint32(snap >> 64), 5_000, "context snapshots default C_WRAP");
        assertEq(uint32(snap >> 96), 450_000, "context snapshots default C_POSTOP");

        (bool unsetBelow, bytes32 unsetReason) = lens.dryRunValidation(address(sp), _op(499_999), 1e16);
        (bool unsetAt, bytes32 unsetAtReason) = lens.dryRunValidation(address(sp), _op(500_000), 1e16);
        assertFalse(unsetBelow);
        assertEq(unsetReason, lens.DRYRUN_POSTOP_GAS_TOO_LOW());
        assertTrue(unsetAt);
        assertEq(unsetAtReason, lens.DRYRUN_OK());

        _set(500_000, 450_000, 5_000, 450_000);
        (bool explicitBelow, bytes32 explicitReason) = lens.dryRunValidation(address(sp), _op(499_999), 1e16);
        (bool explicitAt, bytes32 explicitAtReason) = lens.dryRunValidation(address(sp), _op(500_000), 1e16);
        assertEq(explicitBelow, unsetBelow, "Lens below-floor result matches explicit tuple");
        assertEq(explicitReason, unsetReason, "Lens below-floor reason matches explicit tuple");
        assertEq(explicitAt, unsetAt, "Lens at-floor result matches explicit tuple");
        assertEq(explicitAtReason, unsetAtReason, "Lens at-floor reason matches explicit tuple");
    }

    function test_packed_in_one_slot_at_38_pending_at_39() public {
        vm.prank(owner);
        sp.queueGasParams(550_000, 460_000, 6_000, 450_000);
        uint64 eta = uint64(vm.getBlockTimestamp() + 48 hours);
        bytes32 pend = vm.load(address(sp), bytes32(GAS_PARAMS_SLOT + 1));
        assertEq(
            pend,
            bytes32(
                uint256(550_000) | (uint256(460_000) << 32) | (uint256(6_000) << 64) | (uint256(450_000) << 96)
                    | (uint256(eta) << 128)
            ),
            "pending + eta in slot 39"
        );
        vm.warp(eta);
        vm.prank(owner);
        sp.executeGasParams();
        bytes32 cur = vm.load(address(sp), bytes32(GAS_PARAMS_SLOT));
        assertEq(
            cur,
            bytes32(uint256(550_000) | (uint256(460_000) << 32) | (uint256(6_000) << 64) | (uint256(450_000) << 96)),
            "params in slot 38"
        );
        assertEq(vm.load(address(sp), bytes32(GAS_PARAMS_SLOT + 1)), bytes32(0), "pending cleared");
    }

    // ------------------------------------------------------------------ timelock

    function test_queue_execute_cancel_timelock_and_events() public {
        vm.prank(stranger);
        vm.expectRevert();
        sp.queueGasParams(550_000, 460_000, 6_000, 450_000);

        vm.expectEmit(address(sp));
        emit SuperPaymasterStorage.GasParamsQueued(
            550_000, 460_000, 6_000, 450_000, uint64(vm.getBlockTimestamp() + 48 hours)
        );
        vm.prank(owner);
        sp.queueGasParams(550_000, 460_000, 6_000, 450_000);

        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.GasParamsTimelock.selector);
        sp.executeGasParams();
        assertEq(_cur().minPostOpGas, 500_000, "not effective before the timelock");

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(stranger);
        vm.expectRevert();
        sp.executeGasParams(); // owner-only (mid-bundle execution guard)

        vm.expectEmit(address(sp));
        emit SuperPaymasterStorage.GasParamsExecuted(550_000, 460_000, 6_000, 450_000);
        vm.prank(owner);
        sp.executeGasParams();
        assertEq(_cur().minPostOpGas, 550_000);
        assertEq(_cur().cPostop, 450_000);

        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.GasParamsTimelock.selector);
        sp.executeGasParams(); // nothing pending

        vm.prank(owner);
        sp.queueGasParams(570_000, 480_000, 7_000, 490_000);
        vm.expectEmit(address(sp));
        emit SuperPaymasterStorage.GasParamsCancelled();
        vm.prank(owner);
        sp.cancelGasParams();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.GasParamsTimelock.selector);
        sp.executeGasParams();
        assertEq(_cur().minPostOpGas, 550_000, "cancelled proposal never takes effect");
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.GasParamsTimelock.selector);
        sp.cancelGasParams();
    }

    /// @notice A re-queue replaces the pending proposal AND restarts the 48 h clock.
    function test_requeue_restarts_timelock() public {
        vm.prank(owner);
        sp.queueGasParams(550_000, 460_000, 6_000, 450_000);
        vm.warp(vm.getBlockTimestamp() + 47 hours);
        vm.prank(owner);
        sp.queueGasParams(560_000, 460_000, 6_000, 450_000);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.GasParamsTimelock.selector);
        sp.executeGasParams();
    }

    // ------------------------------------------------------------------ bounds

    function _expectBad(uint32 minPost, uint32 settle, uint32 cWrap, uint32 cPostop) internal {
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.InvalidConfiguration.selector);
        sp.queueGasParams(minPost, settle, cWrap, cPostop);
    }

    function test_bounds_checked_at_queue() public {
        // Positive controls: release floors and upper edges.
        vm.prank(owner);
        sp.queueGasParams(500_000, 450_000, 5_000, 450_000);
        vm.prank(owner);
        sp.queueGasParams(2_000_000, 1_000_000, 50_000, 2_000_000);
        _expectBad(375_000, 355_000, 5_000, 370_000); // old floor tuple
        _expectBad(499_999, 450_000, 5_000, 450_000);
        _expectBad(500_000, 449_999, 5_000, 450_000);
        _expectBad(500_000, 450_000, 5_000, 449_999);
        _expectBad(2_000_000, 1_000_001, 5_000, 450_000);
        // Integer division rounds down; test both sides of the relative spacing boundary.
        uint32[3] memory bounds = [uint32(500_000), uint32(600_000), uint32(1_000_000)];
        for (uint256 i; i < bounds.length; ++i) {
            uint32 minimum = bounds[i] + bounds[i] / 63 + 20_000;
            vm.prank(owner);
            sp.queueGasParams(minimum, bounds[i], 5_000, 450_000);
            _expectBad(minimum - 1, bounds[i], 5_000, 450_000);
        }
        _expectBad(2_000_001, 450_000, 5_000, 450_000);
        _expectBad(500_000, 450_000, 5_000, 500_001);
        _expectBad(500_000, 450_000, 4_999, 450_000);
        _expectBad(500_000, 450_000, 50_001, 450_000);
    }

    /// @notice Execute re-checks the bounds: a pending value that no longer satisfies them (only
    ///         reachable by corrupting storage, e.g. a bad upgrade) is refused.
    function test_bounds_rechecked_at_execute() public {
        vm.prank(owner);
        sp.queueGasParams(550_000, 460_000, 5_000, 450_000);
        uint64 eta = uint64(vm.getBlockTimestamp() + 48 hours);
        // corrupt the pending cPostop to 100k (below the 450k floor)
        vm.store(
            address(sp),
            bytes32(GAS_PARAMS_SLOT + 1),
            bytes32(
                uint256(550_000) | (uint256(460_000) << 32) | (uint256(5_000) << 64) | (uint256(100_000) << 96)
                    | (uint256(eta) << 128)
            )
        );
        vm.warp(eta);
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.InvalidConfiguration.selector);
        sp.executeGasParams();
    }

    // The same boundary table is exercised at both entry points. For upper bounds,
    // the invalid neighbour is max + 1 (max - 1 is valid).
    function _boundary(uint256 i, bool invalid) internal pure returns (SuperPaymaster.GasParams memory g) {
        g = SuperPaymasterStorage.GasParams(500_000, 450_000, 5_000, 450_000);
        if (i == 0) g.settleGasBound = invalid ? 449_999 : 450_000;
        if (i == 1) { g.minPostOpGas = 2_000_000; g.settleGasBound = invalid ? 1_000_001 : 1_000_000; }
        if (i == 2) { g.settleGasBound = 600_000; g.minPostOpGas = uint32(600_000) + uint32(600_000) / 63 + 20_000 - (invalid ? 1 : 0); }
        if (i == 3) g.minPostOpGas = invalid ? 499_999 : 500_000;
        if (i == 4) g.minPostOpGas = invalid ? 2_000_001 : 2_000_000;
        if (i == 5) g.cPostop = invalid ? 449_999 : 450_000;
        if (i == 6) g.cPostop = invalid ? 500_001 : 500_000;
        if (i == 7) g.cWrap = invalid ? 4_999 : 5_000;
        if (i == 8) g.cWrap = invalid ? 50_001 : 50_000;
    }

    function _assertTuple(SuperPaymaster.GasParams memory g) internal view {
        SuperPaymaster.GasParams memory actual = _cur();
        assertEq(abi.encode(actual), abi.encode(g));
    }

    function test_all_boundaries_queue_and_execute() public {
        for (uint256 i; i < 9; ++i) {
            SuperPaymaster.GasParams memory g = _boundary(i, false);
            _set(g.minPostOpGas, g.settleGasBound, g.cWrap, g.cPostop);
            _assertTuple(g);
            g = _boundary(i, true);
            _expectBad(g.minPostOpGas, g.settleGasBound, g.cWrap, g.cPostop);
        }
    }

    function _pendingTuple(SuperPaymaster.GasParams memory g) internal {
        vm.store(address(sp), bytes32(GAS_PARAMS_SLOT + 1), bytes32(
            uint256(g.minPostOpGas) | (uint256(g.settleGasBound) << 32) |
            (uint256(g.cWrap) << 64) | (uint256(g.cPostop) << 96) |
            (uint256(uint64(vm.getBlockTimestamp())) << 128)
        ));
    }

    function test_all_boundaries_rechecked_at_execute() public {
        for (uint256 i; i < 9; ++i) {
            SuperPaymaster.GasParams memory g = _boundary(i, false);
            _pendingTuple(g);
            vm.prank(owner);
            sp.executeGasParams();
            _assertTuple(g);
            _pendingTuple(_boundary(i, true));
            vm.prank(owner);
            vm.expectRevert(SuperPaymasterStorage.InvalidConfiguration.selector);
            sp.executeGasParams();
            _assertTuple(g);
        }
    }

    function test_preupgrade_pending_all_boundaries_rechecked_after_upgrade() public {
        SuperPaymaster next = new SuperPaymaster(IEntryPoint(EP), IRegistry(address(registry)), address(sp.ETH_USD_PRICE_FEED()));
        for (uint256 i; i < 9; ++i) {
            SuperPaymaster.GasParams memory g = _boundary(i, false);
            vm.prank(owner);
            sp.queueGasParams(g.minPostOpGas, g.settleGasBound, g.cWrap, g.cPostop);
            vm.prank(owner);
            sp.upgradeToAndCall(address(next), bytes(""));
            vm.warp(vm.getBlockTimestamp() + 48 hours);
            vm.prank(owner);
            sp.executeGasParams();
            _assertTuple(g);
            // Model a predecessor whose queue admitted a now-invalid tuple. The
            // actual UUPS upgrade must preserve it and the new executor reject it.
            _pendingTuple(_boundary(i, true));
            bytes32 beforePending = vm.load(address(sp), bytes32(GAS_PARAMS_SLOT + 1));
            vm.prank(owner);
            sp.upgradeToAndCall(address(next), bytes(""));
            assertEq(vm.load(address(sp), bytes32(GAS_PARAMS_SLOT + 1)), beforePending);
            vm.prank(owner);
            vm.expectRevert(SuperPaymasterStorage.InvalidConfiguration.selector);
            sp.executeGasParams();
            _assertTuple(g);
        }
    }

    function test_upgrade_preserves_zero_slot_and_explicit_tuple() public {
        SuperPaymaster next = new SuperPaymaster(IEntryPoint(EP), IRegistry(address(registry)), address(sp.ETH_USD_PRICE_FEED()));
        vm.prank(owner);
        sp.upgradeToAndCall(address(next), bytes(""));
        assertEq(vm.load(address(sp), bytes32(GAS_PARAMS_SLOT)), bytes32(0));
        _assertTuple(_boundary(0, false));
        _set(550_000, 460_000, 6_000, 450_000);
        vm.prank(owner);
        sp.upgradeToAndCall(address(next), bytes(""));
        _assertTuple(SuperPaymasterStorage.GasParams(550_000, 460_000, 6_000, 450_000));
    }

    // ------------------------------------------------------------------ effects

    function test_min_post_op_gas_parameter_drives_validation_and_lens() public {
        _set(550_000, 460_000, 5_000, 450_000);
        (bool ok,) = _validates(549_999, keccak256("a"));
        assertFalse(ok, "below the new MIN: sigFail");
        (ok,) = _validates(550_000, keccak256("b"));
        assertTrue(ok, "at the new MIN: validates");
        (bool lok, bytes32 reason) = lens.dryRunValidation(address(sp), _op(549_999), 1e16);
        assertFalse(lok);
        assertEq(reason, lens.DRYRUN_POSTOP_GAS_TOO_LOW(), "lens reads MIN from SP");
        (lok,) = lens.dryRunValidation(address(sp), _op(550_000), 1e16);
        assertTrue(lok, "lens agrees at the new MIN");
    }

    function test_settle_gas_bound_parameter_drives_postOp_guard() public {
        _set(550_000, 480_000, 5_000, 450_000);
        (bool ok, bytes memory ctx) = _validates(550_000, keccak256("s"));
        assertTrue(ok);
        vm.prank(EP);
        (bool s, bytes memory ret) = address(sp).call{gas: 350_000}(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei))
        );
        assertFalse(s, "350k < new SETTLE_GAS_BOUND 480k: refused");
        assertEq(ret, abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector));
        vm.prank(EP);
        (s,) = address(sp).call{gas: 500_000}(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei))
        );
        assertTrue(s, "control: enough gas settles");
    }

    /// @notice The zero-slot release tuple keeps B-1 §10.1 ③: the Amsterdam worst-workload
    ///         boundary remains behind the entry guard, while the first validation-reachable postOp
    ///         limit completes. Therefore there is no OOG band above the entry guard.
    function test_unset_release_tuple_keeps_no_oog_band() public {
        // The old Amsterdam-unsafe SETTLE floor must not remain bounds-valid. This premise makes
        // the no-OOG regression mutation-sensitive to lowering GP_SETTLE_MIN back to 155k.
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.InvalidConfiguration.selector);
        sp.queueGasParams(500_000, 155_000, 5_000, 450_000);
        vm.prank(operator);
        sp.setOperatorLimits(60);
        assertEq(vm.load(address(sp), bytes32(GAS_PARAMS_SLOT)), bytes32(0), "precondition: unset slot");
        address balanceUser = address(0xC0FFEE);
        vm.prank(address(registry));
        sp.updateSBTStatus(balanceUser, true);
        vm.prank(operator);
        IV2Ext(address(token)).mint(balanceUser, 10_000 ether);
        // Bisected worst workload: ceil(379,828 * 1.15) = 436,803.
        assertTrue(
            _classifyFloorProbe(balanceUser, 436_803) != 1,
            "worst-workload boundary is guarded or completes, never OOG"
        );
        assertEq(
            _classifyFloorProbe(balanceUser, 500_000),
            2,
            "release MIN completes the default worst path"
        );
    }

    /// @dev A fresh opHash plus an outer revert keeps every Amsterdam sample independent without
    ///      relying on snapshot/revert restoration of transient or state-gas bookkeeping.
    function floorProbeAndRollback(address balanceUser, uint256 gasBudget) external {
        PackedUserOperation memory op = _op(500_000); // the op's limit at the zero-slot release MIN
        op.sender = balanceUser;
        bytes32 hash = keccak256(abi.encode("floor", gasBudget));
        vm.prank(EP);
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, hash, 1e16);
        assertEq(vd & 1, 0);
        assertEq(abi.decode(ctx, (SuperPaymaster.OpCtx)).mode, 1, "precondition: Amsterdam worst BALANCE path");
        vm.prank(EP);
        (bool ok, bytes memory ret) = address(sp).call{gas: gasBudget}(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei))
        );
        if (ok) revert FloorProbeResult(2);
        if (keccak256(ret) == keccak256(abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector))) {
            revert FloorProbeResult(0);
        }
        revert FloorProbeResult(1);
    }

    function _classifyFloorProbe(address balanceUser, uint256 gasBudget) internal returns (uint8 kind) {
        (bool outerOk, bytes memory result) = address(this).call(
            abi.encodeCall(this.floorProbeAndRollback, (balanceUser, gasBudget))
        );
        assertFalse(outerOk, "floor probe must roll back");
        assertEq(bytes4(result), FloorProbeResult.selector, "floor probe classification");
        assembly ("memory-safe") { kind := mload(add(result, 36)) }
    }

    function _charge(bytes32 h) internal returns (uint256) {
        (bool ok, bytes memory ctx) = _validates(_cur().minPostOpGas, h);
        assertTrue(ok);
        uint256 r0 = sp.protocolRevenue();
        vm.prank(EP);
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
        return sp.protocolRevenue() - r0;
    }

    function _expected(uint256 minPost, uint256 cPostop, uint256 cWrap) internal pure returns (uint256) {
        uint256 bufWei = (cPostop + Math.ceilDiv(uint256(200_000 + minPost) * 10, 100) + cWrap) * 1 gwei;
        uint256 aGas = Math.mulDiv((1e14 + bufWei) * 2000e8, 1e18, 1e8 * 0.02 ether, Math.Rounding.Ceil);
        return Math.mulDiv(aGas, 11_000, 10_000, Math.Rounding.Ceil);
    }

    function test_c_postop_and_c_wrap_parameters_drive_the_charge() public {
        assertEq(_charge(keccak256("c0")), _expected(500_000, 450_000, 5_000), "defaults");
        _set(550_000, 460_000, 9_000, 490_000);
        assertEq(_charge(keccak256("c1")), _expected(550_000, 490_000, 9_000), "new C_POSTOP / C_WRAP");
    }

    /// @notice Trust surface: whatever the parameters, the charge never exceeds a0 (SP postOp
    ///         `if (charge > c.a0) charge = c.a0`).
    function test_charge_capped_at_a0_even_at_max_parameters() public {
        _set(2_000_000, 1_000_000, 50_000, 2_000_000);
        PackedUserOperation memory op = _op(2_000_000);
        vm.prank(EP);
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, keccak256("cap"), 1e15);
        assertEq(vd & 1, 0);
        uint256 a0 = abi.decode(ctx, (SuperPaymaster.OpCtx)).a0;
        uint256 r0 = sp.protocolRevenue();
        vm.prank(EP);
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
        assertEq(sp.protocolRevenue() - r0, a0, "max parameters: charge clamps to a0, never above");
    }
}
