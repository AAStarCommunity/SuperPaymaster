// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SuperPaymasterLens } from "src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { V55Registry, V55PriceFeed, V55APNTs, IV2Ext } from "../helpers/V55TestFixtures.sol";

/**
 * @title SuperPaymasterV55GasParamsTest — exp/params: the four gas parameters as owner-settable,
 *        48 h-timelocked storage (one slot) with hard bounds checked at queue AND execute.
 */
contract SuperPaymasterV55GasParamsTest is Test {
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
            IEntryPoint(EP), IRegistry(address(registry)), address(new V55PriceFeed()), owner, address(apnts), owner, 3600
        );
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(address(sp), address(registry), address(new xPNTsTokenV2(address(aoa), address(ext))), address(tier));
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
        (c, ) = sp.gasParams();
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
        assertEq(c.minPostOpGas, 200_000);
        assertEq(c.settleGasBound, 160_000);
        assertEq(c.cWrap, 5_000);
        assertEq(c.cPostop, 175_000);
        assertEq(_pend().eta, 0, "nothing pending");
        assertEq(vm.load(address(sp), bytes32(GAS_PARAMS_SLOT)), bytes32(0), "slot 38 zero = defaults (upgrade-safe)");
        assertEq(sp.version(), "SuperPaymaster-5.5.1-exp");
    }

    function test_packed_in_one_slot_at_38_pending_at_39() public {
        vm.prank(owner);
        sp.queueGasParams(250_000, 170_000, 6_000, 180_000);
        uint64 eta = uint64(vm.getBlockTimestamp() + 48 hours);
        bytes32 pend = vm.load(address(sp), bytes32(GAS_PARAMS_SLOT + 1));
        assertEq(pend, bytes32(uint256(250_000) | (uint256(170_000) << 32) | (uint256(6_000) << 64) | (uint256(180_000) << 96) | (uint256(eta) << 128)), "pending + eta in slot 39");
        vm.warp(eta);
        vm.prank(owner);
        sp.executeGasParams();
        bytes32 cur = vm.load(address(sp), bytes32(GAS_PARAMS_SLOT));
        assertEq(cur, bytes32(uint256(250_000) | (uint256(170_000) << 32) | (uint256(6_000) << 64) | (uint256(180_000) << 96)), "params in slot 38");
        assertEq(vm.load(address(sp), bytes32(GAS_PARAMS_SLOT + 1)), bytes32(0), "pending cleared");
    }

    // ------------------------------------------------------------------ timelock

    function test_queue_execute_cancel_timelock_and_events() public {
        vm.prank(stranger);
        vm.expectRevert();
        sp.queueGasParams(250_000, 170_000, 6_000, 180_000);

        vm.expectEmit(address(sp));
        emit SuperPaymaster.GasParamsQueued(250_000, 170_000, 6_000, 180_000, uint64(vm.getBlockTimestamp() + 48 hours));
        vm.prank(owner);
        sp.queueGasParams(250_000, 170_000, 6_000, 180_000);

        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.GasParamsTimelock.selector);
        sp.executeGasParams();
        assertEq(_cur().minPostOpGas, 200_000, "not effective before the timelock");

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(stranger);
        vm.expectRevert();
        sp.executeGasParams(); // owner-only (mid-bundle execution guard)

        vm.expectEmit(address(sp));
        emit SuperPaymaster.GasParamsExecuted(250_000, 170_000, 6_000, 180_000);
        vm.prank(owner);
        sp.executeGasParams();
        assertEq(_cur().minPostOpGas, 250_000);
        assertEq(_cur().cPostop, 180_000);

        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.GasParamsTimelock.selector);
        sp.executeGasParams(); // nothing pending

        vm.prank(owner);
        sp.queueGasParams(300_000, 200_000, 7_000, 190_000);
        vm.expectEmit(address(sp));
        emit SuperPaymaster.GasParamsCancelled();
        vm.prank(owner);
        sp.cancelGasParams();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.GasParamsTimelock.selector);
        sp.executeGasParams();
        assertEq(_cur().minPostOpGas, 250_000, "cancelled proposal never takes effect");
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.GasParamsTimelock.selector);
        sp.cancelGasParams();
    }

    /// @notice A re-queue replaces the pending proposal AND restarts the 48 h clock.
    function test_requeue_restarts_timelock() public {
        vm.prank(owner);
        sp.queueGasParams(250_000, 170_000, 6_000, 180_000);
        vm.warp(vm.getBlockTimestamp() + 47 hours);
        vm.prank(owner);
        sp.queueGasParams(260_000, 170_000, 6_000, 180_000);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.GasParamsTimelock.selector);
        sp.executeGasParams();
    }

    // ------------------------------------------------------------------ bounds

    function _expectBad(uint32 minPost, uint32 settle, uint32 cWrap, uint32 cPostop) internal {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        sp.queueGasParams(minPost, settle, cWrap, cPostop);
    }

    function test_bounds_checked_at_queue() public {
        // positive control: every edge value accepted
        vm.prank(owner);
        sp.queueGasParams(175_000, 155_000, 5_000, 175_000);
        vm.prank(owner);
        sp.queueGasParams(2_000_000, 1_000_000, 50_000, 2_000_000);
        vm.prank(owner);
        sp.queueGasParams(200_000, 160_000, 5_000, 175_000);
        // SETTLE in [155k, 1M]
        _expectBad(200_000, 154_999, 5_000, 175_000);
        _expectBad(2_000_000, 1_000_001, 5_000, 175_000);
        // MIN in [SETTLE + 20k, 2M]
        _expectBad(179_999, 160_000, 5_000, 175_000);
        _expectBad(2_000_001, 160_000, 5_000, 175_000);
        // C_POSTOP in [175k, MIN]
        _expectBad(200_000, 160_000, 5_000, 174_999);
        _expectBad(200_000, 160_000, 5_000, 200_001);
        // C_WRAP in [5k, 50k]
        _expectBad(200_000, 160_000, 4_999, 175_000);
        _expectBad(200_000, 160_000, 50_001, 175_000);
    }

    /// @notice Execute re-checks the bounds: a pending value that no longer satisfies them (only
    ///         reachable by corrupting storage, e.g. a bad upgrade) is refused.
    function test_bounds_rechecked_at_execute() public {
        vm.prank(owner);
        sp.queueGasParams(200_000, 160_000, 5_000, 175_000);
        uint64 eta = uint64(vm.getBlockTimestamp() + 48 hours);
        // corrupt the pending cPostop to 100k (below the 150k floor)
        vm.store(address(sp), bytes32(GAS_PARAMS_SLOT + 1),
            bytes32(uint256(200_000) | (uint256(160_000) << 32) | (uint256(5_000) << 64) | (uint256(100_000) << 96) | (uint256(eta) << 128)));
        vm.warp(eta);
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        sp.executeGasParams();
    }

    // ------------------------------------------------------------------ effects

    function test_min_post_op_gas_parameter_drives_validation_and_lens() public {
        _set(250_000, 160_000, 5_000, 175_000);
        (bool ok, ) = _validates(249_999, keccak256("a"));
        assertFalse(ok, "below the new MIN: sigFail");
        (ok, ) = _validates(250_000, keccak256("b"));
        assertTrue(ok, "at the new MIN: validates");
        (bool lok, bytes32 reason) = lens.dryRunValidation(address(sp), _op(249_999), 1e16);
        assertFalse(lok);
        assertEq(reason, lens.DRYRUN_POSTOP_GAS_TOO_LOW(), "lens reads MIN from SP");
        (lok, ) = lens.dryRunValidation(address(sp), _op(250_000), 1e16);
        assertTrue(lok, "lens agrees at the new MIN");
    }

    function test_settle_gas_bound_parameter_drives_postOp_guard() public {
        _set(320_000, 300_000, 5_000, 175_000);
        (bool ok, bytes memory ctx) = _validates(320_000, keccak256("s"));
        assertTrue(ok);
        vm.prank(EP);
        (bool s, bytes memory ret) = address(sp).call{gas: 250_000}(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei)));
        assertFalse(s, "250k < new SETTLE_GAS_BOUND 300k: refused");
        assertEq(ret, abi.encodeWithSelector(SuperPaymaster.PostOpGasTooLow.selector));
        vm.prank(EP);
        (s, ) = address(sp).call{gas: 400_000}(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei)));
        assertTrue(s, "control: enough gas settles");
    }

    /// @notice The SETTLE_GAS_BOUND floor must itself keep B-1 §10.1 ③ (no OOG band above the entry
    ///         guard): with the floor value configured, sweep the gas given to postOp on the worst
    ///         path (CREDIT, first debt, cold lastTimestamp): every call is PostOpGasTooLow or a
    ///         complete settlement.
    function test_settle_floor_keeps_no_oog_band() public {
        vm.prank(operator);
        sp.setOperatorLimits(60);
        _set(175_000, 155_000, 5_000, 175_000); // all-floor tuple (SETTLE, MIN, C_POSTOP, C_WRAP)
        address poor = address(0xC0FFEE);
        vm.prank(address(registry));
        sp.updateSBTStatus(poor, true);
        registry.setCreditLimit(poor, 50_000 ether);
        vm.prank(operator);
        IV2Ext(address(token)).queueCreditPolicy(2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IV2Ext(address(token)).executeCreditPolicy();
        sp.updatePrice();
        vm.prank(poor);
        IV2Ext(address(token)).requestCredit(50_000 ether);
        PackedUserOperation memory op = _op(175_000); // the op's limit at the floor MIN
        op.sender = poor;
        vm.prank(EP);
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, keccak256("floor"), 1e16);
        assertEq(vd & 1, 0);
        assertEq(abi.decode(ctx, (SuperPaymaster.OpCtx)).mode, 2, "precondition: CREDIT (worst path)");
        bytes memory cd = abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei));
        uint256 guard;
        uint256 okN;
        for (uint256 g = 140_000; g <= 200_000; g += 100) {
            uint256 snap = vm.snapshot();
            vm.prank(EP);
            (bool s, bytes memory ret) = address(sp).call{gas: g}(cd);
            vm.revertTo(snap);
            if (s) { okN++; continue; }
            assertEq(ret, abi.encodeWithSelector(SuperPaymaster.PostOpGasTooLow.selector),
                "SETTLE floor: no OOG band above the entry guard");
            assertEq(okN, 0, "monotone");
            guard++;
        }
        assertGt(guard, 0);
        assertGt(okN, 0);
    }

    function _charge(bytes32 h) internal returns (uint256) {
        (bool ok, bytes memory ctx) = _validates(200_000, h);
        assertTrue(ok);
        uint256 r0 = sp.protocolRevenue();
        vm.prank(EP);
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
        return sp.protocolRevenue() - r0;
    }

    function _expected(uint256 cPostop, uint256 cWrap) internal pure returns (uint256) {
        uint256 bufWei = (cPostop + Math.ceilDiv(uint256(400_000) * 10, 100) + cWrap) * 1 gwei;
        uint256 aGas = Math.mulDiv((1e14 + bufWei) * 2000e8, 1e18, 1e8 * 0.02 ether, Math.Rounding.Ceil);
        return Math.mulDiv(aGas, 11_000, 10_000, Math.Rounding.Ceil);
    }

    function test_c_postop_and_c_wrap_parameters_drive_the_charge() public {
        assertEq(_charge(keccak256("c0")), _expected(175_000, 5_000), "defaults");
        _set(200_000, 160_000, 9_000, 190_000);
        assertEq(_charge(keccak256("c1")), _expected(190_000, 9_000), "new C_POSTOP / C_WRAP");
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
