// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
import {SelectedGasFixtures as GasFixture} from "../helpers/SelectedGasFixtures.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SuperPaymasterLens} from "src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {AOAProtocolRegistry} from "src/tokens/v2/AOAProtocolRegistry.sol";
import {GlobalTierSource} from "src/tokens/v2/GlobalTierSource.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";
import {xPNTsTokenV2Ext} from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import {xPNTsFactoryV2} from "src/tokens/v2/xPNTsFactoryV2.sol";
import {IxPNTsTokenV2} from "src/tokens/v2/IxPNTsTokenV2.sol";
import {Ownable} from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import {Registry} from "src/core/Registry.sol";
import {MockAgentIdentityRegistry} from "src/mocks/MockAgentIdentityRegistry.sol";

import {V55Registry, V55PriceFeed, V55APNTs, V55Counter, IV2Ext} from "../helpers/V55TestFixtures.sol";

/// @dev Forge 1.7.1/nightly debug-step ABI. Kept local until forge-std exposes the cheatcodes.
struct V55DebugStep {
    bytes immediateBytes;
    bytes memoryInput;
    uint8 opcode;
    uint64 depth;
    bool isOutOfGas;
    address contractAddr;
}

/// @notice SP 5.5.1 end-to-end through a real EntryPoint v0.7 (spec 03 §1, §10, §11).
contract SuperPaymasterV55Test is Test {
    EntryPoint entryPoint;
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    SuperPaymasterLens lens;
    V55Registry registry;
    V55APNTs apnts;
    AOAProtocolRegistry aoa;
    xPNTsFactoryV2 factory;
    xPNTsTokenV2 token;
    GlobalTierSource tier;
    Registry productionRegistry;
    GlobalTierSource productionTier;
    address tracedIdentityRegistry;

    uint256 constant OWNER_PK = 0xA0A0;
    uint256 constant OWNER2_PK = 0xA0A1;
    uint256 MIN_POST_OP_GAS = GasFixture.MIN_POST();
    address owner = address(0x0A11);
    address treasury = address(0x7EA);
    address operator = address(0x0BE);
    address beneficiary = address(0xBEEF);
    address accountOwner;
    address user;
    address user2;

    bytes32 constant POST_OP_REVERT_REASON_TOPIC = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes4 constant START_DEBUG_TRACE = 0x419c8832;
    bytes4 constant STOP_DEBUG_TRACE = 0xced398a2;
    uint8 constant TRACE_TOKEN = 0;
    uint8 constant TRACE_AGENT = 1;
    uint8 constant TRACE_CREDIT = 2;

    function setUp() public {
        accountOwner = vm.addr(OWNER_PK);
        vm.deal(owner, 10 ether);
        entryPoint = new EntryPoint();
        accountFactory = new SimpleAccountFactory(IEntryPoint(address(entryPoint)));
        user = address(accountFactory.createAccount(accountOwner, 0));
        user2 = address(accountFactory.createAccount(vm.addr(OWNER2_PK), 1));

        vm.startPrank(owner);
        registry = new V55Registry();
        productionRegistry = UUPSDeployHelper.deployRegistryProxy(owner, address(0x5701), address(0x5B7));
        productionTier = new GlobalTierSource(address(productionRegistry));
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        apnts = new V55APNTs();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(new V55PriceFeed()),
            owner,
            address(apnts),
            treasury,
            3600
        );
        GasFixture.configure(sp);

        aoa = new AOAProtocolRegistry(owner);
        tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(productionTier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsTokenV2 impl = new xPNTsTokenV2(address(aoa), address(ext));
        factory = new xPNTsFactoryV2(address(sp), address(registry), address(impl), address(tier));
        sp.setXPNTsFactory(address(factory));
        lens = new SuperPaymasterLens();

        vm.warp(block.timestamp + 2 hours);
        sp.updatePrice();
        sp.deposit{value: 1 ether}();
        apnts.mint(operator, 1_000_000 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);
        vm.prank(address(registry));
        sp.updateSBTStatus(user2, true);

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        IV2Ext(address(token)).mint(user, 10_000 ether);
        IV2Ext(address(token)).mint(user2, 10_000 ether);
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), treasury);
        sp.deposit(100_000 ether);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _op(uint256 nonce, uint256 postOpGas, uint8 flags, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        return _opFor(user, OWNER_PK, nonce, postOpGas, flags, callData);
    }

    function _opFor(
        address sender,
        uint256 signerPk,
        uint256 nonce,
        uint256 postOpGas,
        uint8 flags,
        bytes memory callData
    ) internal view returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = nonce;
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(350_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp),
            uint128(GasFixture.PM_VERIFICATION),
            uint128(postOpGas),
            operator,
            type(uint256).max,
            address(token),
            flags
        );
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _handle(PackedUserOperation memory op) internal returns (bool reverted, bool postOpFailed) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.recordLogs();
        try entryPoint.handleOps(ops, payable(beneficiary)) {}
        catch {
            reverted = true;
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == POST_OP_REVERT_REASON_TOPIC) postOpFailed = true;
        }
    }

    function _opBalance() internal view returns (uint128 b) {
        (b,,,,,,,,) = sp.operators(operator);
    }

    function _opTotalSpent() internal view returns (uint256 spent) {
        (,,,,,,, spent,) = sp.operators(operator);
    }

    function _setOpBalance(uint128 balance) internal {
        bytes32 slot = keccak256(abi.encode(operator, uint256(5)));
        uint256 word = uint256(vm.load(address(sp), slot));
        vm.store(address(sp), slot, bytes32((word & ~uint256(type(uint128).max)) | balance));
    }

    function _prepareUint96ReservationBoundary() internal {
        _setOpBalance(type(uint128).max);
        vm.store(address(sp), bytes32(uint256(9)), bytes32(uint256(2000 ether)));
        vm.prank(owner);
        sp.setProtocolFee(0);
        vm.mockCall(
            address(token),
            abi.encodeWithSelector(IxPNTsTokenV2.tryLockForGas.selector),
            abi.encode(IxPNTsTokenV2.LockResult.OK, uint256(0))
        );
    }

    // ------------------------------------------------------------------
    // Balance mode happy path (I8, I9, R10-M1b accounting)
    // ------------------------------------------------------------------

    function test_balance_mode_end_to_end() public {
        uint256 userBefore = token.balanceOf(user);
        uint128 opBefore = _opBalance();
        uint256 revBefore = sp.protocolRevenue();
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);

        (bool reverted, bool postOpFailed) = _handle(op);
        assertFalse(reverted, "handleOps");
        assertFalse(postOpFailed, "postOp");

        uint256 burned = userBefore - token.balanceOf(user);
        assertGt(burned, 0, "user paid in xPNTs");
        assertEq(token.lockedOf(user), 0, "escrow cleared");
        (address f, uint256 a0) = sp.inflightOf(h);
        assertEq(f, address(0));
        assertEq(a0, 0, "in-flight cleared");
        uint256 charge = sp.protocolRevenue() - revBefore;
        assertEq(uint256(opBefore) - uint256(_opBalance()), charge, "operator net loss == revenue (no clamp)");
        assertEq(burned, charge, "rate 1:1: burned xPNTs == aPNTs charge");
        assertEq(token.debts(user), 0, "balance mode never creates debt (I3)");
    }

    // ------------------------------------------------------------------
    // T-R14-09 / R10-H1 — HARD GATE for D2
    // ------------------------------------------------------------------

    /// @notice An op allotting EXACTLY MIN_POST_OP_GAS must settle through EntryPoint on the worst
    ///         path: cold `lastTimestamp` write (minTxInterval > 0), cold token slots, and the
    ///         SP->token call subject to the second 63/64 forwarding rule.
    function test_TR1409_settles_at_MIN_POST_OP_GAS_worst_path() public {
        vm.prank(operator);
        sp.setOperatorLimits(60); // minTxInterval > 0 -> cold lastTimestamp SSTORE in postOp
        uint256 userBefore = token.balanceOf(user);

        (bool reverted, bool postOpFailed) = _handle(_op(0, MIN_POST_OP_GAS, 0, ""));
        assertFalse(reverted, "op at the floor must validate and execute");
        assertFalse(postOpFailed, "postOp must NOT fail at MIN_POST_OP_GAS");
        assertGt(userBefore - token.balanceOf(user), 0, "settlement actually happened (not a silent skip)");
        assertEq(token.lockedOf(user), 0);
    }

    /// @notice Positive control for the gate above: one gas unit below the floor is rejected at
    ///         validation, so the floor check is live (otherwise the gate test could pass vacuously).
    function test_TR1409_control_below_floor_rejected() public {
        (bool reverted,) = _handle(_op(0, MIN_POST_OP_GAS - 1, 0, ""));
        assertTrue(reverted, "below MIN_POST_OP_GAS must be rejected at validation");
    }

    /// @notice R10-H1 formula check with measured components: the whole postOp (called the way
    ///         EntryPoint calls it) must fit in MIN_POST_OP_GAS with the 64/63 forwarding factor.
    function test_G_min_post_op_gas_covers_measured_postOp() public {
        vm.prank(operator);
        sp.setOperatorLimits(60);
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        (bytes memory ctx,) = sp.validatePaymasterUserOp(op, h, 1e15);
        vm.prank(address(entryPoint));
        uint256 g0 = gasleft();
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
        uint256 used = g0 - gasleft();
        console.log("measured postOp gas (worst-ish, warm-in-test)", used);
        (SuperPaymaster.GasParams memory configured,) = sp.gasParams();
        assertLe(used * 64 / 63 + 20_000, configured.minPostOpGas, "MIN_POST_OP_GAS must cover postOp x 64/63 + margin");
    }

    // ------------------------------------------------------------------
    // B-1: no try/catch around settlement
    // ------------------------------------------------------------------

    /// @notice If settlement fails, postOp reverts -> EntryPoint rolls back the user's execution
    ///         and emits PostOpRevertReason; the user keeps their tokens (execution undone) and the
    ///         escrow is released after the transaction (I8/I10).
    /// @notice Direct-call unit check (no EntryPoint): postOp does not swallow a settlement failure.
    ///         The end-to-end I8 property is test_I8_settle_failure_rolls_back_user_execution_e2e.
    function test_B1_postOp_bubbles_settlement_revert_direct_call() public {
        // make settlement impossible: drop the lock record by releasing it in a prior step is not
        // possible within one tx, so instead exercise the SP guard directly: postOp with a context
        // whose lock does not exist must revert (no silent catch).
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        bytes memory ctx = abi.encode(
            SuperPaymaster.OpCtx(address(token), user, 1 ether, h, operator, 1, 0, 300_000, 2000e8, 8, 0.02 ether)
        );
        vm.prank(address(entryPoint));
        vm.expectRevert(); // token.settleLocked -> NoLock bubbles up: postOp does not swallow it
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
    }

    /// forge-config: default.isolate = true
    function test_I10_stale_sponsorship_restores_operator() public {
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        uint128 opBefore = _opBalance();
        vm.prank(address(entryPoint));
        sp.validatePaymasterUserOp(op, h, 1e15); // validation happens; postOp never runs
        uint128 opMid = _opBalance();
        assertLt(opMid, opBefore, "a0 debited while in flight");
        // new transaction: the in-flight marker is gone -> anyone can restore the operator
        sp.releaseStaleSponsorship(h);
        assertEq(_opBalance(), opBefore, "operator fully restored");
        token.releaseStaleLock(user, h);
        assertEq(token.lockedOf(user), 0, "user escrow released");
    }

    function test_I10_release_refused_while_in_flight() public {
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        sp.validatePaymasterUserOp(op, h, 1e15);
        vm.expectRevert(SuperPaymasterStorage.SponsorshipInFlight.selector);
        sp.releaseStaleSponsorship(h); // same transaction
    }

    // ------------------------------------------------------------------
    // Validation routing (R-2, R4-H1, token binding, flags)
    // ------------------------------------------------------------------

    /// @notice R4-H1. The mismatching token is a REAL, funded v2 token of another community, so
    ///         without the binding check validation would lock it and SUCCEED — the sigFail bit is
    ///         what fails (not an incidental revert). Positive control: same op with the right token.
    function test_token_mismatch_rejected() public {
        address other = address(0x0C2);
        registry.setRole(keccak256("COMMUNITY"), other, true);
        vm.prank(other);
        xPNTsTokenV2 otherToken = xPNTsTokenV2(factory.deployxPNTsToken("O", "xO", "O", "o.eth", 1 ether, address(0)));
        vm.prank(other);
        IV2Ext(address(otherToken)).mint(user, 10_000 ether);

        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        op.paymasterAndData = abi.encodePacked(
            address(sp),
            uint128(GasFixture.PM_VERIFICATION),
            uint128(MIN_POST_OP_GAS),
            operator,
            type(uint256).max,
            address(otherToken),
            uint8(0)
        );
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, bytes32(uint256(1)), 1e15);
        assertEq(vd & 1, 1, "sigFail bit set on token mismatch");
        assertEq(ctx.length, 0, "no context on sigFail");
        assertEq(otherToken.lockedOf(user), 0, "the other community's token was not touched");

        PackedUserOperation memory good = _op(0, MIN_POST_OP_GAS, 0, "");
        vm.prank(address(entryPoint));
        (, uint256 vdGood) = sp.validatePaymasterUserOp(good, bytes32(uint256(2)), 1e15);
        assertEq(vdGood & 1, 0, "control: the configured token validates");
    }

    function test_both_renew_flags_rejected() public {
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 3, "");
        vm.prank(address(entryPoint));
        (, uint256 vd) = sp.validatePaymasterUserOp(op, bytes32(uint256(2)), 1e15);
        assertEq(vd & 1, 1, "sigFail when both renew bits are set");
    }

    function test_credit_fallback_only_on_insufficient() public {
        // user with no balance, AUTO policy with a tier -> CREDIT; OFF -> rejected
        address poorOwner = vm.addr(0xB00B);
        address poor = address(accountFactory.createAccount(poorOwner, 0));
        vm.prank(address(registry));
        sp.updateSBTStatus(poor, true);
        registry.setCreditLimit(poor, 1_000 ether);

        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        op.sender = poor;
        vm.prank(address(entryPoint));
        (, uint256 vd) = sp.validatePaymasterUserOp(op, keccak256("p1"), 1e15);
        assertEq(vd & 1, 1, "credit OFF -> no sponsorship for an empty account");

        vm.prank(operator);
        IV2Ext(address(token)).queueCreditPolicy(2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IV2Ext(address(token)).executeCreditPolicy();
        vm.prank(owner); // refresh price staleness after the 48 h warp
        sp.updatePrice();
        vm.prank(poor);
        IV2Ext(address(token)).requestCredit(1_000 ether);

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd2) = sp.validatePaymasterUserOp(op, keccak256("p2"), 1e15);
        assertEq(vd2 & 1, 0, "AUTO + request + tier -> CREDIT");
        SuperPaymaster.OpCtx memory c = abi.decode(ctx, (SuperPaymaster.OpCtx));
        assertEq(c.mode, 2, "mode CREDIT");
        assertEq(token.creditReservedOf(poor), c.a0, "validation-time reservation");
    }

    /// @notice Factory binding (P1-4): a token not issued by the wired factory is refused. The
    ///         BALANCE_MODE_VERSION probe itself is covered by
    ///         SecurityFixes_M4_M5_M7.t.sol::test_M4_ConfigureOperatorRejectsNonBalanceModeTokens.
    function test_configureOperator_rejects_non_factory_token() public {
        address other = address(0x0F2);
        registry.setRole(keccak256("PAYMASTER_SUPER"), other, true);
        registry.setRole(keccak256("COMMUNITY"), other, true);
        V55APNTs plain = new V55APNTs();
        vm.prank(other);
        vm.expectRevert(SuperPaymasterStorage.InvalidXPNTsToken.selector); // factory binding
        sp.configureOperator(address(plain), treasury);
    }

    // ------------------------------------------------------------------
    // Lens (F1) — consistency with validation (D layer seed)
    // ------------------------------------------------------------------

    function test_lens_agrees_with_validation() public {
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        (bool ok, bytes32 reason) = lens.dryRunValidation(address(sp), op, 1e15);
        assertTrue(ok, string(abi.encodePacked(reason)));
        bytes32 h = entryPoint.getUserOpHash(op); // compute BEFORE prank (prank binds the next call)
        vm.prank(address(entryPoint));
        (, uint256 vd) = sp.validatePaymasterUserOp(op, h, 1e15);
        assertEq(vd & 1, 0, "validation agrees");

        PackedUserOperation memory bad = _op(1, MIN_POST_OP_GAS - 1, 0, "");
        (ok, reason) = lens.dryRunValidation(address(sp), bad, 1e15);
        assertFalse(ok);
        assertEq(reason, lens.DRYRUN_POSTOP_GAS_TOO_LOW());
    }

    function test_lens_version_mismatch_is_explicit() public {
        SuperPaymasterLens l2 = new SuperPaymasterLens();
        assertEq(l2.EXPECTED_SP_VERSION(), keccak256(bytes(sp.version())), "lens pinned to this SP");
    }

    function test_version() public view {
        assertEq(sp.version(), "SuperPaymaster-5.5.2");
    }

    // ------------------------------------------------------------------
    // DSR D2 pre-review additions
    // ------------------------------------------------------------------

    /// @notice R10-M3: postOp charges at the VALIDATION-time price snapshot. The aPNTs USD price is
    ///         moved +10% between validate and postOp; the charge must equal the formula evaluated
    ///         with the snapshot. Mutation "postOp re-reads the live price" makes this red.
    function test_R10M3_charge_uses_validation_price_snapshot() public {
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        (int256 pAtValidation,,, uint8 decAtValidation) = sp.cachedPrice();
        uint256 aAtValidation = sp.aPNTsPriceUSD();
        vm.prank(address(entryPoint));
        (bytes memory ctx,) = sp.validatePaymasterUserOp(op, h, 1e15);
        SuperPaymaster.OpCtx memory c = abi.decode(ctx, (SuperPaymaster.OpCtx));
        // DSR D2 Low-1: the snapshot must BE the validation-time state, not merely self-consistent
        // (M7a — writing a wrong price into the snapshot — otherwise survives this suite alone)
        assertEq(c.price, pAtValidation, "snapshot price == cachedPrice at validation");
        assertEq(c.decimals, decAtValidation, "snapshot decimals == cachedPrice at validation");
        assertEq(c.aPriceUSD, aAtValidation, "snapshot aPNTs price == aPNTsPriceUSD at validation");

        vm.prank(owner);
        sp.setAPNTSPrice(0.022 ether); // live price moves +10% after validation
        assertTrue(sp.aPNTsPriceUSD() != c.aPriceUSD, "precondition: live price differs from snapshot");

        uint256 actualGasCost = 1e14;
        uint256 feePerGas = 1 gwei;
        // exp/buffer: C_POSTOP replaces postOpGasLimit; use the queued deployment tuple
        uint256 bufWei =
            (GasFixture.POSTOP() + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100) + 5_000) * feePerGas;
        uint256 aGas = Math.mulDiv(
            (actualGasCost + bufWei) * uint256(c.price),
            1e18,
            (10 ** uint256(c.decimals)) * c.aPriceUSD,
            Math.Rounding.Ceil
        );
        uint256 expected = Math.mulDiv(aGas, 10_000 + sp.protocolFeeBPS(), 10_000, Math.Rounding.Ceil);
        assertLt(expected, c.a0, "precondition: charge below the reservation cap (cap cannot mask a wrong price)");

        uint256 revBefore = sp.protocolRevenue();
        vm.prank(address(entryPoint));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, actualGasCost, feePerGas);
        assertEq(sp.protocolRevenue() - revBefore, expected, "charge priced at the validation snapshot");
    }

    /// @notice B-1 §10.1 ③: postOp refuses to START a settlement below SETTLE_GAS_BOUND, with the
    ///         dedicated error. Mutation "delete the entry check" makes this red (it would then fail,
    ///         if at all, with an out-of-gas instead of PostOpGasTooLow).
    function test_B1_postOp_entry_gas_guard() public {
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        (bytes memory ctx,) = sp.validatePaymasterUserOp(op, h, 1e15);
        vm.prank(address(entryPoint));
        vm.expectRevert(SuperPaymasterStorage.PostOpGasTooLow.selector);
        sp.postOp{gas: 60_000}(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
        // control: the same call with ample gas settles
        vm.prank(address(entryPoint));
        sp.postOp{gas: 1_000_000}(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
        assertEq(token.lockedOf(user), 0, "control settles");
    }

    /// @notice B-1 §10.1 ③ (D3 finding): SETTLE_GAS_BOUND must cover everything postOp does after
    ///         the entry check, on the worst path (fresh rate-limit timestamp, fresh idempotency /
    ///         usedOpHash slots). Sweep the gas given to postOp: every call either fails the entry
    ///         check with PostOpGasTooLow or settles completely — there is no band where the check
    ///         passes and the settlement then runs out of gas. Both BALANCE and CREDIT modes.
    function test_B1_no_oog_band_above_entry_guard() public {
        vm.prank(operator);
        sp.setOperatorLimits(60); // worst path: fresh lastTimestamp SSTORE in postOp
        bytes memory ctxB = _validatedCtx(user, keccak256("band-b"));
        address poor = _creditUser();
        bytes memory ctxC = _validatedCtx(poor, keccak256("band-c"));
        assertEq(abi.decode(ctxB, (SuperPaymaster.OpCtx)).mode, 1, "precondition: BALANCE");
        assertEq(abi.decode(ctxC, (SuperPaymaster.OpCtx)).mode, 2, "precondition: CREDIT");
        for (uint256 m; m < 2; m++) {
            bytes memory ctx = m == 0 ? ctxB : ctxC;
            (address sender, bytes32 h) = m == 0 ? (user, keccak256("band-b")) : (poor, keccak256("band-c"));
            (uint256 guard, uint256 ok) = (0, 0);
            for (uint256 g = 60_000; g <= GasFixture.SWEEP_MAX(); g += 500) {
                uint256 snap = vm.snapshot();
                vm.prank(address(entryPoint));
                (bool success, bytes memory ret) = address(sp).call{gas: g}(
                    abi.encodeCall(sp.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei))
                );
                if (success) {
                    // a successful return must mean a COMPLETE settlement (not an early return)
                    (address f,) = sp.inflightOf(h);
                    assertEq(f, address(0), "success -> in-flight cleared");
                    assertEq(token.lockOf(h, sender).locker, address(0), "success -> lock settled");
                    assertEq(token.creditReservationOf(h, sender).locker, address(0), "success -> reservation settled");
                    assertTrue(token.usedOpHashes(h), "success -> token recorded the settlement");
                    vm.revertTo(snap);
                    ok++;
                    continue;
                }
                vm.revertTo(snap);
                assertEq(
                    ret,
                    abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector),
                    "no OOG band: a postOp that passed the entry check must complete"
                );
                assertEq(ok, 0, "no failure above a success (monotone)");
                guard++;
            }
            assertGt(guard, 0, "entry guard exercised");
            assertGt(ok, 0, "success region reached");
        }
    }

    function _validatedCtx(address sender, bytes32 h) internal returns (bytes memory ctx) {
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        op.sender = sender;
        vm.prank(address(entryPoint));
        uint256 vd;
        (ctx, vd) = sp.validatePaymasterUserOp(op, h, 1e15);
        assertEq(vd & 1, 0, "validated");
    }

    function _creditUser() internal returns (address poor) {
        poor = address(accountFactory.createAccount(vm.addr(0xB00B), 0));
        vm.prank(address(registry));
        sp.updateSBTStatus(poor, true);
        registry.setCreditLimit(poor, 1_000 ether);
        vm.prank(operator);
        IV2Ext(address(token)).queueCreditPolicy(2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IV2Ext(address(token)).executeCreditPolicy();
        vm.prank(owner);
        sp.updatePrice();
        vm.prank(poor);
        IV2Ext(address(token)).requestCredit(1_000 ether);
    }

    /// @notice I8 end-to-end through a real EntryPoint: the op's execution increments a counter;
    ///         settlement is forced to fail; the whole postOp reverts, EntryPoint rolls back the
    ///         execution (counter unchanged), the escrow stays until the transaction ends, and
    ///         after it both stale releases restore user and operator in full.
    /// forge-config: default.isolate = true
    function test_I8_settle_failure_rolls_back_user_execution_e2e() public {
        V55Counter counter = new V55Counter();
        bytes memory exec = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(counter), 0, abi.encodeCall(V55Counter.inc, ())
        );

        // control run: settlement works → execution kept, counter == 1
        (bool r0, bool pf0) = _handle(_op(0, MIN_POST_OP_GAS, 0, exec));
        assertFalse(r0);
        assertFalse(pf0);
        assertEq(counter.n(), 1, "control: execution kept when settlement succeeds");

        // failing run
        uint256 userBal = token.balanceOf(user);
        uint128 opBefore = _opBalance();
        PackedUserOperation memory op = _op(1, MIN_POST_OP_GAS, 0, exec);
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.mockCallRevert(address(token), abi.encodeWithSelector(IxPNTsTokenV2.settleLocked.selector), "settle boom");
        (bool reverted, bool postOpFailed) = _handle(op);
        vm.clearMockedCalls();

        assertFalse(reverted, "bundle itself succeeds (postOpReverted path)");
        assertTrue(postOpFailed, "PostOpRevertReason emitted");
        assertEq(counter.n(), 1, "I8: user execution rolled back (counter NOT incremented)");
        assertEq(token.balanceOf(user), userBal, "user not charged");
        assertGt(token.lockedOf(user), 0, "escrow left behind until the transaction ends");
        (address f,) = sp.inflightOf(h);
        assertEq(f, operator, "operator a0 still in flight");
        assertLt(_opBalance(), opBefore, "a0 debited while in flight");

        // next transactions: stale releases
        token.releaseStaleLock(user, h);
        assertEq(token.lockedOf(user), 0, "escrow fully released");
        sp.releaseStaleSponsorship(h);
        assertEq(_opBalance(), opBefore, "operator fully restored (I10)");
    }

    function test_B1_withdrawal_boundaries_and_expire_before_expiry_reverts() public {
        uint256 amount = 10_000 ether;
        assertEq(sp.OPERATOR_WITHDRAWAL_DELAY(), 48 hours, "DSR withdrawal delay");
        assertEq(sp.OPERATOR_WITHDRAWAL_WINDOW(), 24 hours, "DSR execution window");

        vm.prank(operator);
        sp.requestWithdraw(amount);
        (, uint48 readyAt) = sp.pendingWithdrawals(operator);
        uint48 expiresAt = readyAt + sp.OPERATOR_WITHDRAWAL_WINDOW();
        assertEq(readyAt, block.timestamp + sp.OPERATOR_WITHDRAWAL_DELAY());

        vm.warp(readyAt - 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.WithdrawalNotReady.selector, readyAt));
        sp.withdraw(amount);

        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.WithdrawalNotReady.selector, expiresAt));
        sp.expireWithdraw(operator);

        uint256 snap = vm.snapshot();
        vm.warp(readyAt);
        vm.prank(operator);
        sp.withdraw(amount);
        vm.revertTo(snap);

        vm.warp(expiresAt);
        vm.prank(operator);
        sp.withdraw(amount);
        vm.revertTo(snap);

        vm.warp(uint256(expiresAt) + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.WithdrawalExpired.selector, expiresAt));
        sp.withdraw(amount);
    }

    function test_B1_reviewer_PoC_expires_and_third_party_restores_escrow() public {
        uint256 amount = 90_000 ether;
        uint128 balanceBefore = _opBalance();
        uint256 trackedBefore = sp.totalTrackedBalance();
        uint48 expectedReadyAt = uint48(block.timestamp) + sp.OPERATOR_WITHDRAWAL_DELAY();
        uint48 expectedExpiresAt = expectedReadyAt + sp.OPERATOR_WITHDRAWAL_WINDOW();
        vm.expectEmit(true, false, false, true, address(sp));
        emit SuperPaymasterStorage.OperatorWithdrawalRequested(
            operator, amount, expectedReadyAt, expectedExpiresAt
        );
        vm.prank(operator);
        sp.requestWithdraw(amount);
        assertEq(_opBalance(), balanceBefore - amount, "request escrows immediately");

        (, uint48 readyAt) = sp.pendingWithdrawals(operator);
        uint48 expiresAt = readyAt + sp.OPERATOR_WITHDRAWAL_WINDOW();
        vm.warp(block.timestamp + 180 days);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.WithdrawalExpired.selector, expiresAt));
        sp.withdraw(amount);

        vm.expectEmit(true, false, false, true, address(sp));
        emit SuperPaymasterStorage.OperatorWithdrawalExpired(operator, amount);
        vm.prank(address(0xB1));
        sp.expireWithdraw(operator);
        assertEq(_opBalance(), balanceBefore, "permissionless expiry restores sponsorship balance");
        assertEq(sp.totalTrackedBalance(), trackedBefore, "expiry does not move funds out of SP");
    }

    function test_C1M01_queueSlash_freezes_mature_request_until_cancelled() public {
        vm.prank(operator);
        sp.requestWithdraw(1 ether);
        vm.warp(block.timestamp + sp.OPERATOR_WITHDRAWAL_DELAY());

        vm.prank(owner);
        sp.queueSlash(operator);
        vm.prank(operator);
        vm.expectRevert(SuperPaymasterStorage.SlashPending.selector);
        sp.withdraw(1 ether);

        vm.prank(owner);
        sp.cancelSlash(operator);
        vm.prank(operator);
        sp.withdraw(1 ether);
    }

    function test_B1_cancel_restores_escrow_and_tracked_balance_is_unchanged() public {
        uint128 balanceBefore = _opBalance();
        uint256 trackedBefore = sp.totalTrackedBalance();
        vm.prank(operator);
        sp.requestWithdraw(90_000 ether);
        assertEq(_opBalance(), balanceBefore - 90_000 ether);
        assertEq(sp.totalTrackedBalance(), trackedBefore);

        vm.prank(operator);
        sp.cancelWithdraw();
        (uint128 pendingAmount,) = sp.pendingWithdrawals(operator);
        assertEq(pendingAmount, 0);
        assertEq(_opBalance(), balanceBefore);
        assertEq(sp.totalTrackedBalance(), trackedBefore);
    }

    function test_B1_expireWithdraw_at_exactly_expiry_reverts_and_one_second_later_succeeds() public {
        vm.prank(operator);
        sp.requestWithdraw(90_000 ether);
        (, uint48 readyAt) = sp.pendingWithdrawals(operator);
        uint48 expiresAt = readyAt + sp.OPERATOR_WITHDRAWAL_WINDOW();

        vm.warp(expiresAt);
        vm.prank(address(0xCA11));
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.WithdrawalNotReady.selector, expiresAt));
        sp.expireWithdraw(operator);

        vm.warp(uint256(expiresAt) + 1);
        vm.prank(address(0xCA11));
        sp.expireWithdraw(operator);
        (uint128 pendingAmount,) = sp.pendingWithdrawals(operator);
        assertEq(pendingAmount, 0, "expired escrow is cleared");
    }

    function test_B1_deposit_cap_counts_withdrawal_escrow() public {
        vm.prank(operator);
        sp.requestWithdraw(90_000 ether);
        uint256 collateral = uint256(_opBalance()) + 90_000 ether;
        uint256 overflowing = uint256(type(uint128).max) - collateral + 1;
        // Fits beside the liquid balance alone, so only an escrow-aware cap rejects it.
        assertLe(uint256(_opBalance()) + overflowing, uint256(type(uint128).max));
        apnts.mint(operator, overflowing);

        vm.prank(operator);
        vm.expectRevert(SuperPaymasterStorage.AmountExceedsUint128.selector);
        sp.deposit(overflowing);

        vm.prank(operator);
        sp.deposit(overflowing - 1);
        vm.prank(operator);
        sp.cancelWithdraw();
        assertEq(uint256(_opBalance()), uint256(type(uint128).max), "cancel restores escrow without overflow");
    }

    function test_M01_understaked_operator_is_permissionlessly_paused() public {
        vm.expectRevert(SuperPaymasterStorage.OperatorNotConfigured.selector);
        sp.pauseUnderstakedOperator(address(0xBAD));

        vm.expectRevert(SuperPaymasterStorage.OperatorMeetsMinimumStake.selector);
        sp.pauseUnderstakedOperator(operator);

        registry.setStake(ROLE_PAYMASTER_SUPER, operator, 1 ether, 0);

        vm.prank(address(0xCA11));
        sp.pauseUnderstakedOperator(operator);
        vm.prank(address(0xCA11));
        (bool noOpOk, bytes memory noOpResult) =
            address(sp).call(abi.encodeCall(ISuperPaymaster.pauseUnderstakedOperator, (operator)));
        assertTrue(noOpOk, "already paused is an allowed no-op");
        assertEq(noOpResult.length, 0, "pause has no ambiguous success return");
        (,, bool isPaused,,,,,,) = sp.operators(operator);
        assertTrue(isPaused);

        vm.prank(operator);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.deposit(1 ether);

        (bool reverted,) = _handle(_op(0, MIN_POST_OP_GAS, 0, ""));
        assertTrue(reverted, "validation uses the local pause without a Registry read");

        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.setOperatorPaused(operator, false);

        registry.setStake(ROLE_PAYMASTER_SUPER, operator, 1 ether, 1 ether);
        vm.prank(operator);
        sp.configureOperator(address(token), treasury);
        (,, isPaused,,,,,,) = sp.operators(operator);
        assertTrue(isPaused, "reconfiguration must not clear pause");
        vm.prank(owner);
        sp.setOperatorPaused(operator, false);
    }

    function test_B1_escrow_is_excluded_from_real_entrypoint_validation_and_cancel_restores_it() public {
        uint128 initial = _opBalance();
        vm.prank(operator);
        sp.requestWithdraw(uint256(initial) - 50 ether);
        assertEq(_opBalance(), 50 ether, "only unescrowed balance sponsors");

        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        (bytes memory failedCtx, uint256 failedVd) = sp.validatePaymasterUserOp(op, h, 750_000_000_000_000);
        assertEq(failedVd & 1, 1, "insufficient unescrowed collateral is SIG_FAILURE");
        assertEq(failedCtx.length, 0);

        vm.prank(operator);
        sp.cancelWithdraw();
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, h, 750_000_000_000_000);
        assertEq(vd & 1, 0, "same op succeeds after escrow cancellation");
        assertGt(ctx.length, 0);
    }

    /// forge-config: default.isolate = true
    function test_SP55101_settlement_leaves_exact_escrow_and_readyAt() public {
        vm.prank(operator);
        sp.requestWithdraw(90_000 ether);
        (uint128 escrow, uint48 readyAt) = sp.pendingWithdrawals(operator);
        vm.warp(readyAt);
        vm.prank(owner);
        sp.updatePrice();

        uint128 balanceBefore = _opBalance();
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _op(0, MIN_POST_OP_GAS, 0, "");
        entryPoint.handleOps(ops, payable(beneficiary));

        (uint128 escrowAfter, uint48 readyAfter) = sp.pendingWithdrawals(operator);
        assertEq(escrowAfter, escrow, "settlement cannot resize exact escrow");
        assertEq(readyAfter, readyAt, "settlement cannot restart the window");
        assertLt(_opBalance(), balanceBefore, "only unescrowed collateral pays sponsorship");
    }

    /// forge-config: default.isolate = true
    function test_SP55101_real_entrypoint_bundle_leaves_exact_escrow() public {
        vm.prank(operator);
        sp.requestWithdraw(90_000 ether);
        (uint128 escrow, uint48 readyAt) = sp.pendingWithdrawals(operator);
        vm.warp(readyAt);
        vm.prank(owner);
        sp.updatePrice();

        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _opFor(user, OWNER_PK, 0, MIN_POST_OP_GAS, 0, "");
        ops[1] = _opFor(user2, OWNER2_PK, 0, MIN_POST_OP_GAS, 0, "");
        entryPoint.handleOps(ops, payable(beneficiary));

        (uint128 escrowAfter, uint48 readyAfter) = sp.pendingWithdrawals(operator);
        assertEq(escrowAfter, escrow, "bundle settlement cannot resize escrow");
        assertEq(readyAfter, readyAt);
        assertEq(sp.inflightReserved(operator), 0);
    }

    /// forge-config: default.isolate = true
    function test_SP55101_failed_postOp_stale_release_leaves_escrow_untouched() public {
        vm.prank(operator);
        sp.requestWithdraw(90_000 ether);
        (uint128 escrow, uint48 readyAt) = sp.pendingWithdrawals(operator);
        uint128 balanceBefore = _opBalance();

        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, h, 1e15);
        assertEq(vd & 1, 0);
        vm.mockCallRevert(address(token), abi.encodeWithSelector(IxPNTsTokenV2.settleLocked.selector), "settle boom");
        vm.prank(address(entryPoint));
        vm.expectRevert("settle boom");
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1, 1);
        vm.clearMockedCalls();

        sp.releaseStaleSponsorship(h);
        (uint128 escrowAfter, uint48 readyAfter) = sp.pendingWithdrawals(operator);
        assertEq(escrowAfter, escrow, "stale release cannot resize escrow");
        assertEq(readyAfter, readyAt);
        assertEq(_opBalance(), balanceBefore, "stale release restores only the reservation");
    }

    function test_B1_request_then_queueSlash_slashes_balance_before_escrow_on_total_collateral_cap() public {
        uint256 trackedBefore = sp.totalTrackedBalance();
        vm.prank(operator);
        sp.requestWithdraw(90_000 ether);
        (, uint48 readyAt) = sp.pendingWithdrawals(operator);
        vm.warp(readyAt);

        vm.prank(owner);
        sp.queueSlash(operator);
        vm.prank(operator);
        vm.expectRevert(SuperPaymasterStorage.SlashPending.selector);
        sp.withdraw(90_000 ether);

        vm.prank(owner);
        sp.slashOperator(operator, ISuperPaymaster.SlashLevel.MAJOR, 100_000 ether, "T-1");
        assertEq(_opBalance(), 0, "slash consumes unescrowed balance first");
        (uint128 pendingAmount,) = sp.pendingWithdrawals(operator);
        assertEq(pendingAmount, 70_000 ether, "remaining penalty comes from escrow");
        assertEq(sp.getLatestSlash(operator).amount, 30_000 ether, "30% cap uses balance plus escrow");
        assertEq(sp.totalTrackedBalance(), trackedBefore, "slash only moves collateral to revenue");
    }

    function test_B1_partial_withdraw_keeps_readyAt_and_expiry_and_tracks_only_payout() public {
        uint256 trackedBefore = sp.totalTrackedBalance();
        vm.prank(operator);
        sp.requestWithdraw(10_000 ether);
        (, uint48 readyAt) = sp.pendingWithdrawals(operator);
        vm.warp(readyAt);
        vm.prank(operator);
        sp.withdraw(4_000 ether);
        (uint128 remaining, uint48 readyAfter) = sp.pendingWithdrawals(operator);
        assertEq(remaining, 6_000 ether);
        assertEq(readyAfter, readyAt, "partial withdrawal keeps original expiry");
        assertEq(sp.totalTrackedBalance(), trackedBefore - 4_000 ether);

        uint48 expiresAt = readyAt + sp.OPERATOR_WITHDRAWAL_WINDOW();
        vm.warp(uint256(expiresAt) + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.WithdrawalExpired.selector, expiresAt));
        sp.withdraw(1 ether);
    }

    /// forge-config: default.isolate = true
    function test_SP55107_reserve_ninety_of_one_hundred_blocks_undercollection_then_full_slash() public {
        _setOpBalance(100 ether);
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        sp.validatePaymasterUserOp(op, h, 750_000_000_000_000);
        uint256 reserved = sp.inflightReserved(operator);
        assertEq(reserved, 90 ether, "reviewer scenario reserves 90 of 100");
        assertEq(_opBalance(), 10 ether, "only ten is liquid");

        vm.startPrank(owner);
        sp.queueSlash(operator);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.SlashBlockedByInflight.selector, 90 ether));
        sp.slashOperator(operator, ISuperPaymaster.SlashLevel.MAJOR, 100 ether, "live reservation");
        vm.stopPrank();

        bytes32[] memory stale = new bytes32[](1);
        stale[0] = h;
        vm.prank(owner);
        sp.slashOperatorAfterReleasing(operator, ISuperPaymaster.SlashLevel.MAJOR, 100 ether, "atomic release", stale);
        assertEq(sp.inflightReserved(operator), 0, "atomic route clears the stale aggregate");
        assertEq(sp.getLatestSlash(operator).amount, 30 ether, "full configured share collected");
        assertEq(_opBalance(), 70 ether, "slash uses the full collateral basis");
    }

    /// forge-config: default.isolate = true
    function test_B1_deposit_cap_counts_inflight_reservation_then_stale_release_and_slash() public {
        _setOpBalance(100 ether);
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        sp.validatePaymasterUserOp(op, h, 750_000_000_000_000);
        assertEq(sp.inflightReserved(operator), 90 ether, "validation reserves 90");

        uint256 collateral = uint256(_opBalance()) + sp.inflightReserved(operator);
        uint256 overflowing = uint256(type(uint128).max) - collateral + 1;
        // Fits beside the liquid balance alone, so only a reservation-aware cap rejects it.
        assertLe(uint256(_opBalance()) + overflowing, uint256(type(uint128).max));
        apnts.mint(operator, overflowing);

        vm.prank(operator);
        vm.expectRevert(SuperPaymasterStorage.AmountExceedsUint128.selector);
        sp.deposit(overflowing);

        vm.prank(operator);
        sp.deposit(overflowing - 1);

        bytes32[] memory stale = new bytes32[](1);
        stale[0] = h;
        vm.startPrank(owner);
        sp.queueSlash(operator);
        sp.slashOperatorAfterReleasing(operator, ISuperPaymaster.SlashLevel.MAJOR, 1 ether, "release after deposit", stale);
        vm.stopPrank();
        assertEq(sp.inflightReserved(operator), 0, "stale release restored without overflow");
        assertEq(uint256(_opBalance()), uint256(type(uint128).max) - 1 ether, "slash took the penalty after release");
    }

    function test_SP55107_pending_slash_does_not_read_time_or_block_admission() public {
        vm.prank(owner);
        sp.queueSlash(operator);
        uint128 balanceBefore = _opBalance();
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, h, 1e15);

        assertEq(vd & 1, 0, "slash provenance is not consulted during validation");
        assertGt(ctx.length, 0, "admitted validation returns settlement context");
        assertGt(sp.inflightReserved(operator), 0, "admission remains independent of slash state");
        assertLt(_opBalance(), balanceBefore, "admitted op reserves collateral");
    }

    /// forge-config: default.isolate = true
    function test_SP55107_bls_minor_uses_full_balance_after_permissionless_release() public {
        address bls = address(0xB15);
        vm.prank(owner);
        sp.initBLSAggregator(bls);
        _setOpBalance(100 ether);
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        sp.validatePaymasterUserOp(op, h, 750_000_000_000_000);
        vm.prank(owner);
        sp.queueSlash(operator);

        vm.prank(bls);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterStorage.SlashBlockedByInflight.selector, 90 ether));
        sp.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, "");

        vm.prank(address(0xCA11));
        sp.releaseStaleSponsorship(h);
        vm.prank(bls);
        sp.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, "");
        assertEq(sp.getLatestSlash(operator).amount, 10 ether, "BLS MINOR takes 10% of total collateral");
        assertEq(_opBalance(), 90 ether);
    }

    function test_B1_bls_minor_uses_balance_plus_withdrawal_escrow() public {
        address bls = address(0xB15);
        vm.prank(owner);
        sp.initBLSAggregator(bls);
        vm.prank(operator);
        sp.requestWithdraw(90_000 ether);
        vm.prank(owner);
        sp.queueSlash(operator);

        vm.prank(bls);
        sp.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, "");

        assertEq(sp.getLatestSlash(operator).amount, 10_000 ether, "BLS MINOR uses total collateral");
        assertEq(_opBalance(), 0, "liquid balance is consumed first");
        (uint128 escrow,) = sp.pendingWithdrawals(operator);
        assertEq(escrow, 90_000 ether, "exact ten percent was covered by liquid balance");
    }

    function test_SP_R4_H01_slash_after_releasing_is_owner_only() public {
        address bls = address(0xB15);
        vm.prank(owner);
        sp.initBLSAggregator(bls);
        bytes32[] memory none = new bytes32[](0);

        vm.prank(bls);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bls));
        sp.slashOperatorAfterReleasing(operator, ISuperPaymaster.SlashLevel.MINOR, 1, "bls denied", none);

        address stranger = address(0xBAD);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sp.slashOperatorAfterReleasing(operator, ISuperPaymaster.SlashLevel.MINOR, 1, "stranger denied", none);
    }

    function test_SP55108_legacy_release_does_not_decrement_new_aggregate() public {
        bytes32 legacyHash = keccak256("legacy-5.5.0-record");
        bytes32 legacySlot = keccak256(abi.encode(legacyHash, uint256(37)));
        vm.store(address(sp), legacySlot, bytes32(uint256(uint160(operator)) | (uint256(80 ether) << 160)));

        bytes32 newHash = keccak256("new-5.5.1-record");
        bytes32 newSlot = keccak256(abi.encode(newHash, uint256(37)));
        vm.store(address(sp), newSlot, bytes32(uint256(uint160(operator)) | (uint256(20 ether) << 160)));
        vm.store(address(sp), bytes32(uint256(newSlot) + 1), bytes32(uint256(1)));
        vm.store(address(sp), keccak256(abi.encode(operator, uint256(43))), bytes32(uint256(20 ether)));
        vm.prank(address(sp));
        token.tryLockForGas(user, newHash, 20 ether, false);
        assertEq(sp.inflightReserved(operator), 20 ether, "new reservation counted");

        vm.prank(address(0xCA11));
        sp.releaseStaleSponsorship(legacyHash);
        assertEq(sp.inflightReserved(operator), 20 ether, "legacy 80 leaves new 20 unchanged");

        bytes memory ctx = abi.encode(
            SuperPaymaster.OpCtx(
                address(token), user, 20 ether, newHash, operator, 1, 0, 300_000, 2000e8, 8, 0.02 ether
            )
        );
        vm.prank(address(entryPoint));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1, 1);
        assertEq(sp.inflightReserved(operator), 0, "new true provenance clears its own reservation");
    }

    function test_SP55109_totalSpent_counts_a0_at_validation_and_legacy_settlement_does_not_double_count() public {
        uint256 spentBefore = _opTotalSpent();
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        (bytes memory ctx,) = sp.validatePaymasterUserOp(op, h, 1e15);
        SuperPaymaster.OpCtx memory c = abi.decode(ctx, (SuperPaymaster.OpCtx));
        assertEq(_opTotalSpent() - spentBefore, c.a0, "5.5.0 totalSpent meaning is reserved a0");

        assembly { mstore(ctx, 352) }
        vm.prank(address(entryPoint));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1, 1);
        assertEq(_opTotalSpent() - spentBefore, c.a0, "legacy context settlement is not counted twice");
    }

    function test_SP_R6_M02_uint96_max_reservation_is_accepted_without_truncation() public {
        _prepareUint96ReservationBoundary();
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = keccak256("uint96-max");
        uint256 maxCost = 72_025_602_285_694_852_357_767_227_577;

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, h, maxCost);

        assertEq(vd & 1, 0, "uint96 max accepted");
        assertEq(abi.decode(ctx, (SuperPaymaster.OpCtx)).a0, type(uint96).max);
        (address storedOperator, uint256 storedA0) = sp.inflightOf(h);
        assertEq(storedOperator, operator);
        assertEq(storedA0, type(uint96).max, "stored a0 is exact");
        assertEq(sp.inflightReserved(operator), type(uint96).max, "aggregate matches stored a0");
    }

    function test_SP_R6_M02_uint96_max_plus_one_is_sigfail_without_business_writes() public {
        _prepareUint96ReservationBoundary();
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = keccak256("uint96-max-plus-one");
        uint256 maxCost = 72_025_602_285_694_852_357_767_227_578;
        uint128 balanceBefore = _opBalance();
        uint256 spentBefore = _opTotalSpent();
        vm.record();

        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, h, maxCost);

        (, bytes32[] memory tokenWrites) = vm.accesses(address(token));
        assertEq(vd & 1, 1, "oversized a0 returns signature failure");
        assertEq(ctx.length, 0, "rejection returns no settlement context");
        assertEq(tokenWrites.length, 0, "rejection occurs before token reservation");
        assertEq(_opBalance(), balanceBefore, "operator balance unchanged");
        assertEq(_opTotalSpent(), spentBefore, "totalSpent unchanged");
        assertEq(sp.inflightReserved(operator), 0, "aggregate unchanged");
        (address storedOperator, uint256 storedA0) = sp.inflightOf(h);
        assertEq(storedOperator, address(0));
        assertEq(storedA0, 0, "no inflight record written");
    }

    function test_guardian_slash_expires_at_seven_days_and_escrow_can_be_cancelled() public {
        address g = address(0x6A2D);
        vm.prank(owner);
        sp.setGuardian(g);
        vm.prank(operator);
        sp.requestWithdraw(1 ether);
        vm.prank(g);
        sp.queueSlash(operator);
        assertTrue(sp.isSlashPending(operator));

        vm.warp(block.timestamp + sp.GUARDIAN_SLASH_FREEZE() - 1);
        assertTrue(sp.isSlashPending(operator), "freeze remains through final second");
        vm.warp(block.timestamp + 1);
        assertFalse(sp.isSlashPending(operator), "expires exactly at seven days");
        vm.prank(operator);
        sp.cancelWithdraw();
    }

    function test_guardian_cannot_requeue_expired_unresolved_slash() public {
        address g = address(0x6A2D);
        vm.prank(owner);
        sp.setGuardian(g);
        vm.prank(g);
        sp.queueSlash(operator);
        vm.warp(block.timestamp + sp.GUARDIAN_SLASH_FREEZE());
        vm.prank(g);
        vm.expectRevert(SuperPaymasterStorage.GuardianSlashUnresolved.selector);
        sp.queueSlash(operator);
    }

    function test_guardian_cannot_execute_or_cancel_slash() public {
        address g = address(0x6A2D);
        vm.prank(owner);
        sp.setGuardian(g);
        vm.prank(g);
        sp.queueSlash(operator);

        vm.prank(g);
        vm.expectRevert();
        sp.slashOperator(operator, ISuperPaymaster.SlashLevel.WARNING, 0, "guardian");
        vm.prank(g);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, "");
        vm.prank(g);
        vm.expectRevert();
        sp.cancelSlash(operator);
    }

    function test_owner_confirmation_makes_guardian_freeze_non_expiring() public {
        address g = address(0x6A2D);
        vm.startPrank(owner);
        sp.setGuardian(g);
        vm.stopPrank();
        vm.prank(g);
        sp.queueSlash(operator);
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        sp.queueSlash(operator);
        vm.warp(block.timestamp + sp.GUARDIAN_SLASH_FREEZE());
        assertTrue(sp.isSlashPending(operator));
    }

    function test_bls_confirmation_makes_guardian_freeze_non_expiring() public {
        address g = address(0x6A2D);
        address bls = address(0xB15);
        vm.startPrank(owner);
        sp.setGuardian(g);
        sp.initBLSAggregator(bls);
        vm.stopPrank();
        vm.prank(g);
        sp.queueSlash(operator);
        vm.warp(block.timestamp + 1 days);
        vm.prank(bls);
        sp.queueSlash(operator);
        vm.warp(block.timestamp + sp.GUARDIAN_SLASH_FREEZE());
        assertTrue(sp.isSlashPending(operator));
    }

    function test_L01_residual_direct_handleOps_can_include_two_nonce_keys_and_charges_both() public {
        vm.prank(operator);
        sp.setOperatorLimits(60);
        V55Counter counter = new V55Counter();
        bytes memory exec = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(counter), 0, abi.encodeCall(V55Counter.inc, ())
        );
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _op(0, MIN_POST_OP_GAS, 0, exec);
        ops[1] = _op(1 << 64, MIN_POST_OP_GAS, 0, exec);

        uint256 userBefore = token.balanceOf(user);
        entryPoint.handleOps(ops, payable(beneficiary));
        assertEq(counter.n(), 2, "a direct/malicious bundler can include both nonce keys");
        assertLt(token.balanceOf(user), userBefore, "both admitted ops are still charged");
        assertEq(_opTotalSponsored(), 2, "both admitted ops settle");
    }

    function test_L01_interval_boundary_rejects_before_and_accepts_at_threshold() public {
        vm.prank(operator);
        sp.setOperatorLimits(60);
        (bool reverted,) = _handle(_op(0, MIN_POST_OP_GAS, 0, ""));
        assertFalse(reverted);

        vm.warp(block.timestamp + 59);
        (reverted,) = _handle(_op(1, MIN_POST_OP_GAS, 0, ""));
        assertTrue(reverted, "one second before threshold");

        vm.warp(block.timestamp + 1);
        (reverted,) = _handle(_op(1, MIN_POST_OP_GAS, 0, ""));
        assertFalse(reverted, "exact threshold");
    }

    /// forge-config: default.isolate = true
    function test_OP011_validation_trace_interval_zero() public {
        _assertValidationOpcodes(_op(0, MIN_POST_OP_GAS, 0, ""), TRACE_TOKEN, true);
    }

    /// forge-config: default.isolate = true
    function test_OP011_validation_trace_interval_nonzero() public {
        vm.prank(operator);
        sp.setOperatorLimits(60);
        _assertValidationOpcodes(_op(0, MIN_POST_OP_GAS, 0, ""), TRACE_TOKEN, true);
    }

    /// forge-config: default.isolate = true
    function test_OP011_validation_trace_pending_slash() public {
        vm.prank(owner);
        sp.queueSlash(operator);
        _assertValidationOpcodes(_op(0, MIN_POST_OP_GAS, 0, ""), TRACE_TOKEN, true);
    }

    /// forge-config: default.isolate = true
    function test_OP011_validation_trace_credit() public {
        address poor = _productionRegistryCreditUser();
        _assertValidationOpcodes(_opFor(poor, 0xB00B, 0, MIN_POST_OP_GAS, 0, ""), TRACE_CREDIT, true);
    }

    /// forge-config: default.isolate = true
    function test_OP011_validation_trace_agent_identity_sbt_false_agent_true() public {
        uint256 agentPk = 0xA6E17;
        address agent = address(accountFactory.createAccount(vm.addr(agentPk), 0));
        MockAgentIdentityRegistry identities = new MockAgentIdentityRegistry();
        identities.registerAgent(agent);
        tracedIdentityRegistry = address(identities);
        vm.prank(owner);
        sp.setAgentRegistries(tracedIdentityRegistry, address(0));
        vm.prank(operator);
        IV2Ext(address(token)).mint(agent, 10_000 ether);

        assertFalse(sp.sbtHolders(agent), "agent path control: SBT must be false");
        assertTrue(sp.isRegisteredAgent(agent), "agent path control: intended identity implementation returns true");
        _assertValidationOpcodes(_opFor(agent, agentPk, 0, MIN_POST_OP_GAS, 0, ""), TRACE_AGENT, true);
    }

    function test_OP011_release_tuple_has_verification_headroom_real_entrypoint() public {
        vm.prank(operator);
        sp.setOperatorLimits(60);
        PackedUserOperation memory op = _op(0, MIN_POST_OP_GAS, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);

        uint256 snap = vm.snapshot();
        vm.prank(address(entryPoint));
        uint256 g0 = gasleft();
        (, uint256 vd) = sp.validatePaymasterUserOp(op, h, 1e15);
        uint256 validationGas = g0 - gasleft();
        assertEq(vd & 1, 0);
        vm.revertTo(snap);

        (SuperPaymaster.GasParams memory gp,) = sp.gasParams();
        assertEq(gp.minPostOpGas, 500_000);
        assertEq(gp.settleGasBound, 450_000);
        assertEq(gp.cWrap, 5_000);
        assertEq(gp.cPostop, 450_000);
        assertGt(GasFixture.PM_VERIFICATION, validationGas, "verification budget headroom");
        console.log("OP-011 SP validation gas", validationGas);
        console.log("OP-011 PM verification limit", GasFixture.PM_VERIFICATION);
        console.log("OP-011 verification headroom", GasFixture.PM_VERIFICATION - validationGas);

        (bool reverted, bool postOpFailed) = _handle(op);
        assertFalse(reverted, "real EntryPoint v0.7 accepts release limits");
        assertFalse(postOpFailed, "real EntryPoint v0.7 settles release limits");
    }

    function _opTotalSponsored() internal view returns (uint256 sponsored) {
        (,,,,,,,, sponsored) = sp.operators(operator);
    }

    function _productionRegistryCreditUser() internal returns (address poor) {
        vm.startPrank(owner);
        productionRegistry.setCreditTier(2, 300 ether);
        productionRegistry.setCreditTier(1, 300 ether);
        vm.stopPrank();
        xPNTsFactoryV2 creditFactory =
            new xPNTsFactoryV2(address(sp), address(registry), factory.implementation(), address(productionTier));
        vm.prank(owner);
        sp.setXPNTsFactory(address(creditFactory));
        vm.startPrank(operator);
        token =
            xPNTsTokenV2(creditFactory.deployxPNTsToken("Credit", "xCR", "Credit", "credit.eth", 1 ether, address(0)));
        sp.configureOperator(address(token), treasury);
        IV2Ext(address(token)).queueCreditPolicy(2);
        vm.stopPrank();

        poor = address(accountFactory.createAccount(vm.addr(0xB00B), 0));
        vm.prank(address(registry));
        sp.updateSBTStatus(poor, true);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IV2Ext(address(token)).executeCreditPolicy();
        vm.prank(owner);
        sp.updatePrice();
        vm.prank(poor);
        IV2Ext(address(token)).requestCredit(300 ether);
        assertEq(productionRegistry.getCreditLimit(poor), 300 ether, "production Registry tier-1 credit");
    }

    function _assertValidationOpcodes(PackedUserOperation memory op, uint8 route, bool expectHandleOpsSuccess)
        internal
    {
        (bool tracing,) = address(vm).call(abi.encodePacked(START_DEBUG_TRACE));
        assertTrue(tracing, "debug tracing unavailable: opcode gate must not skip");

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        (bool handleOpsSuccess,) =
            address(entryPoint).call(abi.encodeCall(EntryPoint.handleOps, (ops, payable(beneficiary))));
        (bool stopped, bytes memory raw) = address(vm).call(abi.encodePacked(STOP_DEBUG_TRACE));
        assertTrue(stopped, "debug trace stop failed");
        V55DebugStep[] memory steps = abi.decode(raw, (V55DebugStep[]));

        uint256 start = type(uint256).max;
        uint64 validationDepth;
        for (uint256 i; i < steps.length; ++i) {
            if (steps[i].contractAddr == address(sp)) {
                start = i;
                validationDepth = steps[i].depth;
                break;
            }
        }
        assertNotEq(start, type(uint256).max, "SP validation frame absent from real EntryPoint trace");

        uint256 bannedCount;
        uint256 callCount;
        for (uint256 i = start; i < steps.length && steps[i].depth >= validationDepth; ++i) {
            uint8 opCode = steps[i].opcode;
            if (opCode == 0xf1 || opCode == 0xf2 || opCode == 0xf4 || opCode == 0xfa) {
                assertGe(steps[i].memoryInput.length, 4, "validation closure contains selectorless call frame");
                bytes4 selector;
                bytes memory input = steps[i].memoryInput;
                assembly { selector := mload(add(input, 32)) }
                (address expectedExecutor, bytes4 expectedSelector, uint8 expectedOpcode) =
                    _expectedValidationCall(route, callCount);
                assertEq(steps[i].contractAddr, expectedExecutor, "validation call-frame executor changed");
                assertEq(selector, expectedSelector, "validation call-frame selector changed");
                assertEq(opCode, expectedOpcode, "validation call-frame opcode changed");
                ++callCount;
            }
            bool banned = opCode == 0x31 || opCode == 0x32 || opCode == 0x3a || opCode == 0x40 || opCode == 0x41
                || opCode == 0x42 || opCode == 0x43 || opCode == 0x44 || opCode == 0x45 || opCode == 0x47
                || opCode == 0x48 || opCode == 0x49 || opCode == 0x4a || opCode == 0xf0 || opCode == 0xf5
                || opCode == 0xfe || opCode == 0xff;
            if (opCode == 0x5a && i + 1 < steps.length && steps[i + 1].depth == steps[i].depth) {
                uint8 next = steps[i + 1].opcode;
                banned = next != 0xf1 && next != 0xf2 && next != 0xf4 && next != 0xfa;
            } else if (opCode == 0x5a) {
                banned = true;
            }
            if (banned) {
                ++bannedCount;
                console.log("banned validation opcode", opCode);
                console.log("executing contract", steps[i].contractAddr);
            }
        }
        assertEq(
            callCount, route == TRACE_CREDIT ? 10 : (route == TRACE_AGENT ? 6 : 5), "validation closure size changed"
        );
        assertEq(bannedCount, 0, "ERC-7562 OP-011/OP-012 opcode in paymaster validation closure");
        if (expectHandleOpsSuccess) assertTrue(handleOpsSuccess, "real EntryPoint v0.7 handleOps failed");
    }

    function _expectedValidationCall(uint8 route, uint256 i)
        internal
        view
        returns (address executor, bytes4 selector, uint8 opcode)
    {
        if (i == 0) return (address(sp), bytes4(0x52b7512c), 0xf4); // proxy -> SP implementation
        if (route == TRACE_AGENT && i == 1) {
            return (address(sp), bytes4(keccak256("isRegisteredAgent(address)")), 0xfa);
        }
        uint256 j = route == TRACE_AGENT ? i - 1 : i;
        if (j == 1) return (address(sp), bytes4(keccak256("exchangeRate()")), 0xfa);
        if (j == 2) return (address(token), bytes4(keccak256("exchangeRate()")), 0xf4);
        if (j == 3) return (address(sp), bytes4(keccak256("tryLockForGas(address,bytes32,uint256,bool)")), 0xf1);
        if (j == 4) return (address(token), bytes4(keccak256("tryLockForGas(address,bytes32,uint256,bool)")), 0xf4);
        if (route == TRACE_CREDIT) {
            if (j == 5) return (address(sp), bytes4(keccak256("tryReserveCredit(address,bytes32,uint256)")), 0xf1);
            if (j == 6) return (address(token), bytes4(keccak256("tryReserveCredit(address,bytes32,uint256)")), 0xf4);
            if (j == 7) return (address(token), bytes4(keccak256("tierOf(address,address)")), 0xfa);
            if (j == 8) return (address(productionTier), bytes4(keccak256("getCreditLimit(address)")), 0xfa);
            if (j == 9) return (address(productionRegistry), bytes4(keccak256("getCreditLimit(address)")), 0xf4);
        }
        revert("unexpected validation call frame");
    }
}
