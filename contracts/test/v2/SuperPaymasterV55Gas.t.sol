// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { V55Registry, V55PriceFeed, V55APNTs, IV2Ext } from "../helpers/V55TestFixtures.sol";
import { PostOpProbePaymaster, GasBurner } from "../helpers/V55GasProbes.sol";

/**
 * @title SuperPaymasterV55GasTest — spec §9 "G gas" / §11 R10-M3: the C_WRAP bound, trace-derived
 *        on the CANONICAL EntryPoint v0.7 runtime bytecode (fetched from chain, codehash
 *        0x8db5ff69…fc58 — identical on Sepolia, OP Sepolia and OP mainnet).
 * @dev    EntryPoint v0.7 `_postExecution` charges the paymaster
 *           F = P + seg + penalty,   seg = wrap + postOpFrame,
 *         where P is the gas already counted when postOp is called (passed as actualGasCost),
 *         postOpFrame <= postOpGasLimit, penalty = 10% of unused (callGasLimit + postOpGasLimit).
 *         SP charges for P plus bufWei = (postOpGasLimit + ceil((callGas + postOpGas)·10/100)
 *         + C_WRAP) × fee, so C_WRAP must bound `wrap` — EntryPoint's own overhead around the
 *         postOp call (ABI-encoding the context, the CALL, return handling, bookkeeping).
 *         Part 1 measures wrap with a probe paymaster (upper bound: F − P − limit + BURN_FLOOR,
 *         penalty only inflates it). Part 2 checks the operational property on SP itself:
 *         the user's charge covers the final cost EntryPoint takes from SP's deposit.
 */
contract SuperPaymasterV55GasTest is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;
    bytes32 constant USEROP_EVENT = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    /// @dev SuperPaymaster.C_WRAP_GAS is internal; its value (exp/buffer: 5_000) is pinned by
    ///      SuperPaymasterV55Test.test_R10M3_charge_uses_validation_price_snapshot (exact charge).
    uint256 constant C_WRAP = 5_000;
    uint256 constant BURN_FLOOR = 300;      // == PostOpProbePaymaster.BURN_FLOOR
    uint256 constant MIN_POST_OP_GAS = 200_000;
    uint256 constant OWNER_PK = 0xA0A0;

    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    address accountOwner;
    address beneficiary = address(0xBEEF);

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.readFile("contracts/test/fixtures/sendercreator-v0.7.runtime.hex")));
        assertEq(EP.codehash, EP_CODEHASH, "canonical EntryPoint v0.7 bytecode");
        accountOwner = vm.addr(OWNER_PK);
        accountFactory = new SimpleAccountFactory(entryPoint);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _account(uint256 salt) internal returns (address) {
        return address(accountFactory.createAccount(accountOwner, salt));
    }

    function _sign(PackedUserOperation memory op) internal view {
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _baseOp(address sender, uint256 nonce, uint128 callGas, bytes memory callData)
        internal pure returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.nonce = nonce;
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), callGas));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
    }

    /// @return finals actualGasUsed (F) of each UserOperationEvent, in bundle order
    function _run(PackedUserOperation[] memory ops) internal returns (uint256[] memory finals, uint256[] memory costs) {
        vm.recordLogs();
        entryPoint.handleOps(ops, payable(beneficiary));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        finals = new uint256[](ops.length);
        costs = new uint256[](ops.length);
        uint256 k;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == EP && logs[i].topics[0] == USEROP_EVENT) {
                (, , uint256 cost, uint256 used) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                costs[k] = cost;
                finals[k++] = used;
            }
        }
        assertEq(k, ops.length, "one UserOperationEvent per op");
    }

    // ==================================================================
    // Part 1 — wrap overhead on the canonical EntryPoint (probe paymaster)
    // ==================================================================

    PostOpProbePaymaster probe;

    function _probeOp(address sender, uint256 nonce, uint128 callGas, bytes memory callData, uint128 postOpGas)
        internal view returns (PackedUserOperation memory op)
    {
        op = _baseOp(sender, nonce, callGas, callData);
        op.paymasterAndData = abi.encodePacked(address(probe), uint128(100_000), postOpGas);
        _sign(op);
    }

    function _wrapUpper(PackedUserOperation memory op, uint256 finalGas, uint256 passedGas) internal pure returns (uint256) {
        uint256 postOpGas = uint128(bytes16(_slice16(op.paymasterAndData, 36)));
        // F − P = wrap + postOpFrame + penalty, postOpFrame >= limit − BURN_FLOOR, penalty >= 0
        return finalGas + BURN_FLOOR - passedGas - postOpGas;
    }

    function _slice16(bytes memory b, uint256 off) internal pure returns (bytes16 r) {
        assembly { r := mload(add(add(b, 32), off)) }
    }

    function _probeSingle(uint128 callGas, bytes memory callData, uint128 postOpGas) internal returns (uint256 wrapUpper) {
        address a = _account(uint256(keccak256(abi.encode(callGas, callData, postOpGas))));
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _probeOp(a, 0, callGas, callData, postOpGas);
        (uint256[] memory f, ) = _run(ops);
        wrapUpper = _wrapUpper(ops[0], f[0], probe.lastPassedGas());
    }

    function _deployProbe() internal {
        probe = new PostOpProbePaymaster();
        vm.deal(address(this), 100 ether);
        entryPoint.depositTo{value: 10 ether}(address(probe));
    }

    function test_G_wrap_bound_canonical_entrypoint_single_ops() public {
        _deployProbe();
        GasBurner burner = new GasBurner();
        bytes memory burnCall = abi.encodeCall(SimpleAccount.execute, (address(burner), 0, abi.encodeCall(GasBurner.burn, ())));

        uint256 w1 = _probeSingle(0, "", uint128(MIN_POST_OP_GAS));          // opSucceeded, no call
        uint256 w2 = _probeSingle(0, "", 1_000_000);                         // large postOp limit
        uint256 w3 = _probeSingle(50_000, burnCall, uint128(MIN_POST_OP_GAS)); // opReverted (call OOG)
        uint256 w4 = _probeSingle(3_000_000, "", uint128(MIN_POST_OP_GAS));    // big unused callGas → penalty
        console.log("wrap upper bound: succeeded/200k", w1);
        console.log("wrap upper bound: succeeded/1M  ", w2);
        console.log("wrap upper bound: reverted/200k ", w3);
        console.log("wrap upper bound (+penalty 10% of 3M unused callGas)", w4);
        assertEq(probe.calls(), 4, "postOp really ran in every scenario");

        uint256 w = Math.max(Math.max(w1, w2), w3);
        assertGt(w, 0, "positive control: measurement is live");
        assertLe(w, C_WRAP, "C_WRAP bounds EntryPoint's postOp wrapping overhead");
        assertLe(w * 2, C_WRAP, "C_WRAP keeps >= 2x headroom over the measured overhead (exp/buffer: 5k vs ~1.7k)");
        // the postOp limit does not leak into the estimate (the frame really burned to its limit)
        assertApproxEqAbs(w1, w2, 2_000, "estimate independent of postOpGasLimit");
        // the penalty inflates only the conservative estimate, never masks it
        assertGt(w4, w1 + 250_000, "penalty scenario is visibly larger (estimate is an upper bound)");
    }

    function test_G_wrap_bound_canonical_entrypoint_bundle_positions() public {
        _deployProbe();
        uint256 n = 4;
        PackedUserOperation[] memory ops = new PackedUserOperation[](n);
        address a = _account(777);
        for (uint256 i; i < n; i++) ops[i] = _probeOp(a, i, 0, "", uint128(MIN_POST_OP_GAS));
        // the probe records only the last P; run the bundle with a per-op P capture instead
        uint256[] memory passed = new uint256[](n);
        uint256 maxW;
        for (uint256 i; i < n; i++) {
            // replay the prefix up to op i so each op's P is observable (state identical otherwise)
            uint256 snap = vm.snapshot();
            PackedUserOperation[] memory prefix = new PackedUserOperation[](i + 1);
            for (uint256 j; j <= i; j++) prefix[j] = ops[j];
            (uint256[] memory f, ) = _run(prefix);
            passed[i] = probe.lastPassedGas();
            uint256 w = _wrapUpper(ops[i], f[i], passed[i]);
            console.log("bundle position", i, "wrap upper bound", w);
            if (w > maxW) maxW = w;
            vm.revertTo(snap);
        }
        assertLe(maxW, C_WRAP, "C_WRAP bounds the overhead at every bundle position");
    }

    // ==================================================================
    // Part 2 — SP on the canonical EntryPoint: the charge covers the final cost
    // ==================================================================

    SuperPaymaster sp;
    xPNTsTokenV2 token;
    V55Registry registry;
    address owner = address(0x0A11);
    address operator = address(0x0BE);
    address treasury = address(0x7EA);

    function _deploySP() internal returns (address user) {
        user = _account(1);
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            entryPoint, IRegistry(address(registry)), address(new V55PriceFeed()), owner, address(apnts), treasury, 3600
        );
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsTokenV2 impl = new xPNTsTokenV2(address(aoa), address(ext));
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(address(sp), address(registry), address(impl), address(tier));
        sp.setXPNTsFactory(address(factory));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        sp.updatePrice();
        sp.deposit{value: 5 ether}();
        apnts.mint(operator, 1_000_000 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        IV2Ext(address(token)).mint(user, 10_000 ether);
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), treasury);
        sp.deposit(100_000 ether);
        sp.setOperatorLimits(60); // worst postOp path: cold lastTimestamp write
        vm.stopPrank();
    }

    function _spOp(address user, uint256 nonce, uint128 callGas, bytes memory callData, uint128 postOpGas)
        internal view returns (PackedUserOperation memory op)
    {
        op = _baseOp(user, nonce, callGas, callData);
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(700_000), postOpGas, operator, type(uint256).max, address(token), uint8(0)
        );
        _sign(op);
    }

    /// @dev The charge the operator would need to be made whole for `finalCostWei` at the
    ///      validation snapshot (same rounding as SP's postOp).
    function _fullCostCharge(uint256 finalCostWei) internal view returns (uint256) {
        (int256 price, , , uint8 dec) = sp.cachedPrice();
        uint256 a = Math.mulDiv(finalCostWei * uint256(price), 1e18, (10 ** uint256(dec)) * sp.aPNTsPriceUSD(), Math.Rounding.Ceil);
        return Math.mulDiv(a, 10_000 + sp.protocolFeeBPS(), 10_000, Math.Rounding.Ceil);
    }

    function _spCase(uint128 callGas, bytes memory callData, uint128 postOpGas) internal {
        address user = _deploySP();
        PackedUserOperation memory op = _spOp(user, 0, callGas, callData, postOpGas);
        // a0 (the clamp) from the same validation, discarded afterwards
        uint256 snap = vm.snapshot();
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(EP);
        (bytes memory ctx, ) = sp.validatePaymasterUserOp(op, h, 1e16);
        uint256 a0 = abi.decode(ctx, (SuperPaymaster.OpCtx)).a0;
        vm.revertTo(snap);

        uint256 revBefore = sp.protocolRevenue();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        (, uint256[] memory costs) = _run(ops);
        uint256 charge = sp.protocolRevenue() - revBefore;
        uint256 need = _fullCostCharge(costs[0]);
        console.log("final cost wei", costs[0]);
        console.log("charge / need (aPNTs wei)", charge, need);
        assertGt(charge, 0, "settled");
        assertLt(charge, a0, "precondition: not clamped at a0 (clamp cannot mask an undercharge)");
        assertGe(charge, need, "user charge covers EntryPoint's final cost to SP (C_WRAP + buffer sufficient)");
    }

    function test_G_sp_charge_covers_final_cost_worst_postOp_at_floor() public {
        _spCase(0, "", uint128(MIN_POST_OP_GAS));
    }

    function test_G_sp_charge_covers_final_cost_large_limits() public {
        _spCase(1_000_000, "", 1_000_000);
    }

    function test_G_sp_charge_covers_final_cost_user_call_reverts() public {
        GasBurner burner = new GasBurner();
        _spCase(50_000, abi.encodeCall(SimpleAccount.execute, (address(burner), 0, abi.encodeCall(GasBurner.burn, ()))),
            uint128(MIN_POST_OP_GAS));
    }
}
