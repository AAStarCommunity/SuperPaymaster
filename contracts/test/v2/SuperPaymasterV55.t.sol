// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SuperPaymasterLens } from "src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";

import { V55Registry, V55PriceFeed, V55APNTs, V55Counter, IV2Ext } from "../helpers/V55TestFixtures.sol";

/// @notice SP 5.5.0 end-to-end through a real EntryPoint v0.7 (spec 03 §1, §10, §11).
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

    uint256 constant OWNER_PK = 0xA0A0;
    uint256 constant MIN_POST_OP_GAS = 200_000;
    address owner = address(0x0A11);
    address treasury = address(0x7EA);
    address operator = address(0x0BE);
    address beneficiary = address(0xBEEF);
    address accountOwner;
    address user;

    bytes32 constant POST_OP_REVERT_REASON_TOPIC = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");

    function setUp() public {
        accountOwner = vm.addr(OWNER_PK);
        vm.deal(owner, 10 ether);
        entryPoint = new EntryPoint();
        accountFactory = new SimpleAccountFactory(IEntryPoint(address(entryPoint)));
        user = address(accountFactory.createAccount(accountOwner, 0));

        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        apnts = new V55APNTs();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)), IRegistry(address(registry)), address(new V55PriceFeed()),
            owner, address(apnts), treasury, 3600
        );

        aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
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

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        IV2Ext(address(token)).mint(user, 10_000 ether);
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), treasury);
        sp.deposit(100_000 ether);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _op(uint256 nonce, uint256 postOpGas, uint8 flags, bytes memory callData)
        internal view returns (PackedUserOperation memory op)
    {
        op.sender = user;
        op.nonce = nonce;
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(350_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(700_000), uint128(postOpGas), operator, type(uint256).max, address(token), flags
        );
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _handle(PackedUserOperation memory op) internal returns (bool reverted, bool postOpFailed) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.recordLogs();
        try entryPoint.handleOps(ops, payable(beneficiary)) {} catch { reverted = true; }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == POST_OP_REVERT_REASON_TOPIC) postOpFailed = true;
        }
    }

    function _opBalance() internal view returns (uint128 b) { (b,,,,,,,,) = sp.operators(operator); }

    // ------------------------------------------------------------------
    // Balance mode happy path (I8, I9, R10-M1b accounting)
    // ------------------------------------------------------------------

    function test_balance_mode_end_to_end() public {
        uint256 userBefore = token.balanceOf(user);
        uint128 opBefore = _opBalance();
        uint256 revBefore = sp.protocolRevenue();
        PackedUserOperation memory op = _op(0, 300_000, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);

        (bool reverted, bool postOpFailed) = _handle(op);
        assertFalse(reverted, "handleOps");
        assertFalse(postOpFailed, "postOp");

        uint256 burned = userBefore - token.balanceOf(user);
        assertGt(burned, 0, "user paid in xPNTs");
        assertEq(token.lockedOf(user), 0, "escrow cleared");
        (address f, uint256 a0) = sp.inflightOf(h);
        assertEq(f, address(0)); assertEq(a0, 0, "in-flight cleared");
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
        (bool reverted, ) = _handle(_op(0, MIN_POST_OP_GAS - 1, 0, ""));
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
        (bytes memory ctx, ) = sp.validatePaymasterUserOp(op, h, 1e15);
        vm.prank(address(entryPoint));
        uint256 g0 = gasleft();
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
        uint256 used = g0 - gasleft();
        console.log("measured postOp gas (worst-ish, warm-in-test)", used);
        assertLe(used * 64 / 63 + 20_000, MIN_POST_OP_GAS, "MIN_POST_OP_GAS must cover postOp x 64/63 + margin");
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
        PackedUserOperation memory op = _op(0, 300_000, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        bytes memory ctx = abi.encode(SuperPaymaster.OpCtx(address(token), user, 1 ether, h, operator, 1, 0, 300_000, 2000e8, 8, 0.02 ether));
        vm.prank(address(entryPoint));
        vm.expectRevert(); // token.settleLocked -> NoLock bubbles up: postOp does not swallow it
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
    }

    /// forge-config: default.isolate = true
    function test_I10_stale_sponsorship_restores_operator() public {
        PackedUserOperation memory op = _op(0, 300_000, 0, "");
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
        PackedUserOperation memory op = _op(0, 300_000, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        sp.validatePaymasterUserOp(op, h, 1e15);
        vm.expectRevert(SuperPaymaster.SponsorshipInFlight.selector);
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

        PackedUserOperation memory op = _op(0, 300_000, 0, "");
        op.paymasterAndData = abi.encodePacked(address(sp), uint128(700_000), uint128(300_000), operator, type(uint256).max, address(otherToken), uint8(0));
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, bytes32(uint256(1)), 1e15);
        assertEq(vd & 1, 1, "sigFail bit set on token mismatch");
        assertEq(ctx.length, 0, "no context on sigFail");
        assertEq(otherToken.lockedOf(user), 0, "the other community's token was not touched");

        PackedUserOperation memory good = _op(0, 300_000, 0, "");
        vm.prank(address(entryPoint));
        (, uint256 vdGood) = sp.validatePaymasterUserOp(good, bytes32(uint256(2)), 1e15);
        assertEq(vdGood & 1, 0, "control: the configured token validates");
    }

    function test_both_renew_flags_rejected() public {
        PackedUserOperation memory op = _op(0, 300_000, 3, "");
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

        PackedUserOperation memory op = _op(0, 300_000, 0, "");
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
        vm.expectRevert(SuperPaymaster.InvalidXPNTsToken.selector); // factory binding
        sp.configureOperator(address(plain), treasury);
    }

    // ------------------------------------------------------------------
    // Lens (F1) — consistency with validation (D layer seed)
    // ------------------------------------------------------------------

    function test_lens_agrees_with_validation() public {
        PackedUserOperation memory op = _op(0, 300_000, 0, "");
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
        assertEq(sp.version(), "SuperPaymaster-5.5.0");
    }

    // ------------------------------------------------------------------
    // DSR D2 pre-review additions
    // ------------------------------------------------------------------

    /// @notice R10-M3: postOp charges at the VALIDATION-time price snapshot. The aPNTs USD price is
    ///         moved +10% between validate and postOp; the charge must equal the formula evaluated
    ///         with the snapshot. Mutation "postOp re-reads the live price" makes this red.
    function test_R10M3_charge_uses_validation_price_snapshot() public {
        PackedUserOperation memory op = _op(0, 300_000, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        (int256 pAtValidation, , , uint8 decAtValidation) = sp.cachedPrice();
        uint256 aAtValidation = sp.aPNTsPriceUSD();
        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = sp.validatePaymasterUserOp(op, h, 1e15);
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
        // exp/buffer: C_POSTOP 170k replaces postOpGasLimit; C_WRAP 5k
        uint256 bufWei = (170_000 + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100) + 5_000) * feePerGas;
        uint256 aGas = Math.mulDiv((actualGasCost + bufWei) * uint256(c.price), 1e18, (10 ** uint256(c.decimals)) * c.aPriceUSD, Math.Rounding.Ceil);
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
        PackedUserOperation memory op = _op(0, 300_000, 0, "");
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = sp.validatePaymasterUserOp(op, h, 1e15);
        vm.prank(address(entryPoint));
        vm.expectRevert(SuperPaymaster.PostOpGasTooLow.selector);
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
            for (uint256 g = 60_000; g <= 260_000; g += 500) {
                uint256 snap = vm.snapshot();
                vm.prank(address(entryPoint));
                (bool success, bytes memory ret) = address(sp).call{gas: g}(
                    abi.encodeCall(sp.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei))
                );
                if (success) {
                    // a successful return must mean a COMPLETE settlement (not an early return)
                    (address f, ) = sp.inflightOf(h);
                    assertEq(f, address(0), "success -> in-flight cleared");
                    assertEq(token.lockOf(h, sender).locker, address(0), "success -> lock settled");
                    assertEq(token.creditReservationOf(h, sender).locker, address(0), "success -> reservation settled");
                    assertTrue(token.usedOpHashes(h), "success -> token recorded the settlement");
                    vm.revertTo(snap);
                    ok++;
                    continue;
                }
                vm.revertTo(snap);
                assertEq(ret, abi.encodeWithSelector(SuperPaymaster.PostOpGasTooLow.selector),
                    "no OOG band: a postOp that passed the entry check must complete");
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
        bytes memory exec = abi.encodeWithSignature("execute(address,uint256,bytes)", address(counter), 0, abi.encodeCall(V55Counter.inc, ()));

        // control run: settlement works → execution kept, counter == 1
        (bool r0, bool pf0) = _handle(_op(0, 300_000, 0, exec));
        assertFalse(r0); assertFalse(pf0);
        assertEq(counter.n(), 1, "control: execution kept when settlement succeeds");

        // failing run
        uint256 userBal = token.balanceOf(user);
        uint128 opBefore = _opBalance();
        PackedUserOperation memory op = _op(1, 300_000, 0, exec);
        bytes32 h = entryPoint.getUserOpHash(op);
        vm.mockCallRevert(address(token), abi.encodeWithSelector(IxPNTsTokenV2.settleLocked.selector), "settle boom");
        (bool reverted, bool postOpFailed) = _handle(op);
        vm.clearMockedCalls();

        assertFalse(reverted, "bundle itself succeeds (postOpReverted path)");
        assertTrue(postOpFailed, "PostOpRevertReason emitted");
        assertEq(counter.n(), 1, "I8: user execution rolled back (counter NOT incremented)");
        assertEq(token.balanceOf(user), userBal, "user not charged");
        assertGt(token.lockedOf(user), 0, "escrow left behind until the transaction ends");
        (address f, ) = sp.inflightOf(h);
        assertEq(f, operator, "operator a0 still in flight");
        assertLt(_opBalance(), opBefore, "a0 debited while in flight");

        // next transactions: stale releases
        token.releaseStaleLock(user, h);
        assertEq(token.lockedOf(user), 0, "escrow fully released");
        sp.releaseStaleSponsorship(h);
        assertEq(_opBalance(), opBefore, "operator fully restored (I10)");
    }
}
