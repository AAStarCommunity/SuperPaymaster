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
import { V55Registry, V55PriceFeed, V55APNTs } from "../helpers/V55TestFixtures.sol";
import { PostOpProbePaymaster, GasBurner } from "../helpers/V55GasProbes.sol";

interface IPBTok {
    function mint(address to, uint256 amount) external;
    function queueCreditPolicy(uint8 p) external;
    function executeCreditPolicy() external;
    function requestCredit(uint256 maxCap) external;
    function emergencyRevokePaymaster() external;
    function proposeSP(address sp) external;
    function activateSP() external;
}

interface IVmStatePB {
    function snapshotState() external returns (uint256);
    function revertToState(uint256 id) external returns (bool);
}

/**
 * @title SuperPaymasterV55PostOpBoundTest — exp/buffer G layer (buffer-tightening-eval §5.1)
 * @notice Rule: C_POSTOP >= W_postop x (1 + m), m = M_BPS / 10_000 (15%), where W_postop is MEASURED
 *         HERE (never copied) as the worst whole-frame postOp gas over the DSR path list:
 *           BALANCE / CREDIT; first-time user; cold rate-limit timestamp write; the (fixed-length,
 *           longest) real context; through the SP proxy's delegatecall; settlement during a token
 *           emergency (E-2); settlement by the OLD locker after SP rotation (L-3); plus two
 *           lighter controls (no rate limit; charge clamped at a0).
 *         Per path two quantities are measured:
 *           consumed — gas the postOp CALL costs its caller (callee frame + CALL overhead), with a
 *                      1M gas budget, measured around the call like EntryPoint's `preGas - gasleft()`.
 *                      This is what EntryPoint CHARGES for the frame (unused gas, incl. the 63/64
 *                      reserve of the SP→token call, is returned), so W_postop = max(consumed).
 *           minLimit — the smallest `{gas: g}` for which the call succeeds. It is NOT charged; on
 *                      every path it equals SETTLE_GAS_BOUND (160k) + the pre-check overhead, i.e. it
 *                      is set by the entry guard, and it is held against MIN_POST_OP_GAS instead.
 *         postOp is called exactly as EntryPoint v0.7 `_postExecution` calls it —
 *         `IPaymaster(paymaster).postOp{gas: limit}(mode, context, actualGasCost, gasPrice)` from the
 *         EntryPoint address, in the SAME transaction as the validation that produced the context
 *         (as in production: EIP-2929 warmth from validation is real, the transient live markers
 *         are set). The measurement is made on the proxy, so the delegatecall is included.
 * @dev exp/params: the parameters are read from SP's `gasParams()` getter, AND their sum is
 *      cross-checked against the charge SP actually applies (prices chosen so every rounding step
 *      is exact) — so the getter cannot drift from the value the charge really uses. `wrap`
 *      (EntryPoint's overhead around the call, D3 probe on the canonical bytecode) is held against
 *      the getter's C_WRAP, MIN_POST_OP_GAS against the entry-guard bound.
 */
contract SuperPaymasterV55PostOpBoundTest is Test {
    IVmStatePB constant vmx = IVmStatePB(address(uint160(uint256(keccak256("hevm cheat code")))));

    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;

    /// @notice m of the rule C_POSTOP >= W_postop x (1 + m) (DSR: >= 15%; author decides).
    uint256 constant M_BPS = 1_500;
    uint256 constant MIN_POST_OP_GAS = 200_000; // the op's postOpGasLimit in these scenarios (== default)
    uint256 constant OWNER_PK = 0xA0A0;
    uint256 constant CALL_GAS = 200_000;
    uint256 constant P_WEI = 1e14;

    uint8 constant BAL_FIRST = 0;
    uint8 constant CRED_FIRST = 1;
    uint8 constant BAL_EMERGENCY = 2;
    uint8 constant CRED_EMERGENCY = 3;
    uint8 constant BAL_ROTATED = 4;
    uint8 constant CRED_ROTATED = 5;
    uint8 constant BAL_NO_RATELIMIT = 6;
    uint8 constant BAL_CLAMPED = 7;
    uint8 constant N_PATHS = 8;

    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    SuperPaymaster sp2;
    V55Registry registry;
    xPNTsTokenV2 token;
    address owner = address(0x0A11);
    address operator = address(0x0BE);
    address treasury = address(0x7EA);
    address beneficiary = address(0xBEEF);

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.readFile("contracts/test/fixtures/sendercreator-v0.7.runtime.hex")));
        assertEq(EP.codehash, EP_CODEHASH, "canonical EntryPoint v0.7 bytecode");
        accountFactory = new SimpleAccountFactory(entryPoint);

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        address feed = address(new V55PriceFeed()); // ETH/USD 2000, 8 decimals
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(entryPoint, IRegistry(address(registry)), feed, owner, address(apnts), treasury, 3600);
        sp2 = UUPSDeployHelper.deploySuperPaymasterProxy(entryPoint, IRegistry(address(registry)), feed, owner, address(apnts), treasury, 3600);
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp2)));
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

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), treasury);
        sp.deposit(100_000 ether);
        sp.setOperatorLimits(60); // postOp writes lastTimestamp
        IPBTok(address(token)).queueCreditPolicy(2);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        IPBTok(address(token)).executeCreditPolicy();
        sp.updatePrice();
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _freshUser(uint256 salt, bool credit) internal returns (address u) {
        u = address(accountFactory.createAccount(vm.addr(OWNER_PK), salt));
        vm.prank(address(registry));
        sp.updateSBTStatus(u, true);
        if (credit) {
            registry.setCreditLimit(u, 50_000 ether);
            vm.prank(u);
            IPBTok(address(token)).requestCredit(50_000 ether);
        } else {
            vm.prank(operator);
            IPBTok(address(token)).mint(u, 10_000 ether);
        }
    }

    function _validate(address u, bytes32 h, uint256 maxCost, uint8 wantMode) internal returns (bytes memory ctx) {
        PackedUserOperation memory op;
        op.sender = u;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(CALL_GAS)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(700_000), uint128(MIN_POST_OP_GAS), operator, type(uint256).max, address(token), uint8(0)
        );
        vm.prank(EP);
        uint256 vd;
        (ctx, vd) = sp.validatePaymasterUserOp(op, h, maxCost);
        assertEq(vd & 1, 0, "validated");
        assertEq(abi.decode(ctx, (SuperPaymaster.OpCtx)).mode, wantMode, "precondition: mode");
        // every context is 11 ABI-canonical 5.5.0 words + 1 snapshot word: this IS the longest real context
        assertEq(ctx.length, 12 * 32, "context length is fixed (384 B)");
    }

    /// @dev Path setup + validation + the between-phase event; returns the postOp calldata.
    function _prepare(uint8 path) internal returns (bytes memory cd, bytes32 h, address u) {
        bool credit = path == CRED_FIRST || path == CRED_EMERGENCY || path == CRED_ROTATED;
        u = _freshUser(1000 + path, credit);
        if (path == BAL_NO_RATELIMIT) {
            vm.prank(operator);
            sp.setOperatorLimits(0);
        }
        h = keccak256(abi.encode("postop-bound", path));
        bytes memory ctx = _validate(u, h, path == BAL_CLAMPED ? 1e15 : 1e16, credit ? 2 : 1);
        if (path == BAL_EMERGENCY || path == CRED_EMERGENCY) {
            vm.prank(operator);
            IPBTok(address(token)).emergencyRevokePaymaster(); // E-2: admitted records still settle
            assertTrue(token.emergencyDisabled(), "precondition: emergency");
        }
        if (path == BAL_ROTATED || path == CRED_ROTATED) {
            vm.prank(operator);
            IPBTok(address(token)).proposeSP(address(sp2));
            vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
            IPBTok(address(token)).activateSP(); // L-3: the old locker still settles its own record
            assertEq(token.SUPERPAYMASTER_ADDRESS(), address(sp2), "precondition: SP rotated");
        }
        // clamped path: actualGasCost so large that charge == a0 (no refund branch)
        uint256 P = path == BAL_CLAMPED ? 1e17 : P_WEI;
        cd = abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, P, 1 gwei));
    }

    function _call(bytes memory cd, uint256 g) internal returns (bool ok) {
        vm.prank(EP);
        (ok, ) = address(sp).call{gas: g}(cd);
    }

    /// @return consumed gas the postOp CALL cost its caller at a 1M budget
    /// @return minLimit smallest gas limit for which postOp completes
    function _measure(uint8 path) internal returns (uint256 consumed, uint256 minLimit) {
        (bytes memory cd, bytes32 h, address u) = _prepare(path);

        uint256 sid = vmx.snapshotState();
        vm.prank(EP);
        uint256 g0 = gasleft();
        (bool ok, ) = address(sp).call{gas: 1_000_000}(cd);
        consumed = g0 - gasleft();
        assertTrue(ok, "postOp completes with 1M gas");
        assertTrue(token.usedOpHashes(h), "positive control: the measured call really settled");
        assertEq(token.lockedOf(u) + token.creditReservedOf(u), 0, "positive control: record consumed");
        vmx.revertToState(sid);

        uint256 lo = 50_000;
        uint256 hi = 1_000_000;
        sid = vmx.snapshotState();
        assertFalse(_call(cd, lo), "search bracket: fails at 50k");
        vmx.revertToState(sid);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            bool s = _call(cd, mid);
            vmx.revertToState(sid);
            if (s) hi = mid;
            else lo = mid;
        }
        minLimit = hi;
    }

    function _pathName(uint8 p) internal pure returns (string memory) {
        return p == BAL_FIRST ? "BALANCE first-time user, cold lastTimestamp"
            : p == CRED_FIRST ? "CREDIT  first-time user, cold lastTimestamp, first debt"
            : p == BAL_EMERGENCY ? "BALANCE during token emergency (E-2)"
            : p == CRED_EMERGENCY ? "CREDIT  during token emergency (E-2)"
            : p == BAL_ROTATED ? "BALANCE old locker after SP rotation (L-3)"
            : p == CRED_ROTATED ? "CREDIT  old locker after SP rotation (L-3)"
            : p == BAL_NO_RATELIMIT ? "BALANCE no rate-limit write (control)"
            : "BALANCE charge clamped at a0 (control)";
    }

    /// @notice W_postop over every path (each from the same fresh state).
    function _wPostop() internal returns (uint256 W, uint256 maxMinLimit) {
        for (uint8 p; p < N_PATHS; p++) {
            uint256 sid = vmx.snapshotState();
            (uint256 consumed, uint256 minLimit) = _measure(p);
            vmx.revertToState(sid);
            console.log(_pathName(p));
            console.log("    consumed (W_postop candidate) / minLimit", consumed, minLimit);
            if (consumed > W) W = consumed;
            if (minLimit > maxMinLimit) maxMinLimit = minLimit;
        }
    }

    /// @notice C_POSTOP + C_WRAP as SP actually charges it: with ETH/USD 2000 (8 dec), aPNTs 0.02,
    ///         fee 10%, feePerGas 1 gwei, every rounding step of the charge is exact, so the buffer
    ///         gas is recovered exactly from the revenue delta.
    function _observedConstSum() internal returns (uint256) {
        uint256 sid = vmx.snapshotState();
        address u = _freshUser(9_999, false);
        bytes32 h = keccak256("observe-constants");
        bytes memory ctx = _validate(u, h, 1e16, 1);
        uint256 rev0 = sp.protocolRevenue();
        vm.prank(EP);
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, P_WEI, 1 gwei);
        uint256 charge = sp.protocolRevenue() - rev0;
        assertLt(charge, abi.decode(ctx, (SuperPaymaster.OpCtx)).a0, "precondition: not clamped at a0");
        vmx.revertToState(sid);
        // charge = aGas x 11/10, aGas = (P + bufWei) x 1e5 (exact for these prices)
        assertEq(charge % 11, 0, "exact rounding (fee)");
        uint256 aGas = charge / 11 * 10;
        assertEq(aGas % 1e5, 0, "exact rounding (price)");
        uint256 bufWei = aGas / 1e5 - P_WEI;
        assertEq(bufWei % 1 gwei, 0, "exact rounding (feePerGas)");
        uint256 bufGas = bufWei / 1 gwei;
        return bufGas - Math.ceilDiv((CALL_GAS + MIN_POST_OP_GAS) * 10, 100);
    }

    /// @notice EntryPoint's own overhead around the postOp call (D3 probe, canonical bytecode).
    function _wrapUpper() internal returns (uint256 maxW) {
        PostOpProbePaymaster probe = new PostOpProbePaymaster();
        vm.deal(address(this), 10 ether);
        entryPoint.depositTo{value: 1 ether}(address(probe));
        GasBurner burner = new GasBurner();
        bytes memory burnCall = abi.encodeCall(SimpleAccount.execute, (address(burner), 0, abi.encodeCall(GasBurner.burn, ())));
        uint128[3] memory callGas = [uint128(0), 0, 50_000];
        uint128[3] memory postGas = [uint128(MIN_POST_OP_GAS), 1_000_000, uint128(MIN_POST_OP_GAS)];
        for (uint256 k; k < 3; k++) {
            address a = address(accountFactory.createAccount(vm.addr(OWNER_PK), 5_000 + k));
            PackedUserOperation memory op;
            op.sender = a;
            op.callData = k == 2 ? burnCall : bytes("");
            op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), callGas[k]));
            op.preVerificationGas = 50_000;
            op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
            op.paymasterAndData = abi.encodePacked(address(probe), uint128(100_000), postGas[k]);
            bytes32 oh = entryPoint.getUserOpHash(op);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, MessageHashUtils.toEthSignedMessageHash(oh));
            op.signature = abi.encodePacked(r, s, v);
            PackedUserOperation[] memory ops = new PackedUserOperation[](1);
            ops[0] = op;
            vm.recordLogs();
            entryPoint.handleOps(ops, payable(beneficiary));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 F;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].emitter == EP && logs[i].topics[0]
                    == keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")) {
                    (, , , F) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                }
            }
            // F − P = wrap + postOpFrame + penalty, postOpFrame >= limit − BURN_FLOOR, penalty >= 0
            uint256 w = F + probe.BURN_FLOOR() - probe.lastPassedGas() - postGas[k];
            if (w > maxW) maxW = w;
        }
        assertEq(probe.calls(), 3, "probe postOp ran in every scenario");
    }

    // ------------------------------------------------------------------
    // tests
    // ------------------------------------------------------------------

    /// @notice The rule. Mutation: lowering C_POSTOP_GAS (or C_WRAP_GAS) in the source below the
    ///         bound turns the named assertion red.
    function test_rule_C_POSTOP_ge_W_postop_times_1_plus_m() public {
        _assertRule();
    }

    /// @notice Codex B-HIGH-2: the rule must hold for EVERY bounds-valid configuration, so the
    ///         all-floor tuple (MIN 175k, SETTLE 155k, C_WRAP 5k, C_POSTOP 175k) is configured
    ///         through SP's queue/execute and the whole rule is re-run on it.
    function test_rule_under_all_floor_params() public {
        vm.prank(owner);
        sp.queueGasParams(175_000, 155_000, 5_000, 175_000);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(owner);
        sp.executeGasParams();
        sp.updatePrice();
        (SuperPaymaster.GasParams memory g, ) = sp.gasParams();
        assertEq(g.settleGasBound, 155_000, "precondition: floor tuple active");
        _assertRule();
    }

    function _assertRule() internal {
        (uint256 W, uint256 maxMinLimit) = _wPostop();
        uint256 sum = _observedConstSum();
        (SuperPaymaster.GasParams memory g, ) = sp.gasParams();
        assertEq(sum, uint256(g.cPostop) + g.cWrap, "getter == what the charge really uses (C_POSTOP + C_WRAP)");
        uint256 cPostop = g.cPostop;
        uint256 wrap = _wrapUpper();
        uint256 need = Math.mulDiv(W, 10_000 + M_BPS, 10_000, Math.Rounding.Ceil);
        console.log("W_postop (max over paths)", W);
        console.log("observed C_POSTOP + C_WRAP / C_POSTOP_obs", sum, cPostop);
        console.log("W_postop x (1 + m), m bps", need, M_BPS);
        console.log("margin of C_POSTOP over W_postop (bps)", (cPostop - W) * 10_000 / W);
        console.log("EntryPoint wrap upper bound / C_WRAP", wrap, g.cWrap);
        assertGt(W, 100_000, "positive control: the measurement is live (a real settlement)");
        assertGe(cPostop, need, "rule: C_POSTOP >= W_postop x (1 + m)");
        assertLe(wrap, g.cWrap, "rule: EntryPoint wrap <= C_WRAP");
        // C_POSTOP replaces postOpGasLimit only because MIN_POST_OP_GAS >= C_POSTOP
        assertLe(cPostop, g.minPostOpGas, "MIN_POST_OP_GAS >= C_POSTOP (min(limit, C_POSTOP) == C_POSTOP)");
        // the non-charged requirement: a postOp given MIN_POST_OP_GAS completes on every path
        console.log("max minLimit (entry-guard bound) / MIN_POST_OP_GAS", maxMinLimit, g.minPostOpGas);
        assertGe(g.minPostOpGas, maxMinLimit, "MIN_POST_OP_GAS >= smallest completing postOp gas limit (T-R14-09)");
    }

    /// @notice Per-path report (and each path must also individually satisfy the rule).
    function test_each_path_within_C_POSTOP() public {
        (SuperPaymaster.GasParams memory g, ) = sp.gasParams();
        assertEq(_observedConstSum(), uint256(g.cPostop) + g.cWrap, "getter == charge");
        uint256 cPostop = g.cPostop;
        for (uint8 p; p < N_PATHS; p++) {
            uint256 sid = vmx.snapshotState();
            (uint256 consumed, ) = _measure(p);
            vmx.revertToState(sid);
            assertGe(cPostop * 10_000, consumed * (10_000 + M_BPS), string.concat("rule per path: ", _pathName(p)));
        }
    }
}
