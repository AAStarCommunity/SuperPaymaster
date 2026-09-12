// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import { Clones } from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsV2Base } from "src/tokens/v2/xPNTsV2Base.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";
import { xPNTsToken } from "src/tokens/xPNTsToken.sol";
import { V55PriceFeed, V55APNTs, V55Counter } from "./SuperPaymasterV55.t.sol";
import { DummySpender } from "./xPNTsTokenV2.t.sol";

/// @dev Registry stand-in. `setBlocked` plays the DVT/BLS blacklist sync (Registry → SP), so a
///      UserOp's execution can write the blacklist between validation and postOp (T-R14-03).
/// @dev Bound-token stand-in with no exchangeRate() (and no fallback).
contract NoExchangeRate {}

contract AdvRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    mapping(address => uint256) public creditLimit;
    function setRole(bytes32 role, address a, bool v) external { roles[role][a] = v; }
    function hasRole(bytes32 role, address a) external view returns (bool) { return roles[role][a]; }
    function getCreditLimit(address u) external view returns (uint256) { return creditLimit[u]; }
    function setCreditLimit(address u, uint256 v) external { creditLimit[u] = v; }
    function setBlocked(address sp, address operator, address user, bool b) external {
        address[] memory us = new address[](1);
        us[0] = user;
        bool[] memory bs = new bool[](1);
        bs[0] = b;
        SuperPaymaster(sp).updateBlockedStatus(operator, us, bs);
    }
}

contract AdvReverter {
    function boom() external pure { revert("boom"); }
}

/// @dev Typed view of the xPNTs v2 extension (reached through the core's fallback).
interface IAdv {
    function mint(address to, uint256 amount) external;
    function queueCreditPolicy(uint8 p) external;
    function executeCreditPolicy() external;
    function requestCredit(uint256 maxCap) external;
    function setAutoAllowance(address spender, uint256 capAPNTs) external;
    function setUserTotalCap(uint256 capAPNTs) external;
    function setRenewalMode(uint8 mode) external;
    function disableSpenderForSelf(address spender) external;
    function enableSpenderForSelf(address spender) external;
    function proposeSpender(address spender) external;
    function activateSpender(address spender) external;
    function proposeSP(address sp) external;
    function activateSP() external;
    function proposeStandby(address s) external;
    function queueTierSource(address s) external;
    function emergencyRevokePaymaster() external;
    function updateExchangeRate(uint256 newRate) external;
}

/// @dev forge ≥1.0 state-snapshot cheatcodes (the vendored forge-std Vm predates the rename).
///      Verified before use: revertToState restores storage AND transient storage, and a
///      snapshot id can be reverted to repeatedly.
interface IVmState {
    function snapshotState() external returns (uint256);
    function revertToState(uint256 id) external returns (bool);
}

/**
 * @title SuperPaymasterV55AdversarialTest — D3 "A layer" (spec 03 §8, §9 A, §10.1, §10.6)
 * @notice Adversarial SP-level suite for SuperPaymaster 5.5.0 + xPNTs v2 through a real
 *         EntryPoint v0.7. Row → test map is in the D3 report; test names carry the row id.
 */
contract SuperPaymasterV55AdversarialTest is Test {
    IVmState constant vmx = IVmState(address(uint160(uint256(keccak256("hevm cheat code")))));

    EntryPoint entryPoint;
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    SuperPaymaster sp2;
    AdvRegistry registry;
    V55APNTs apnts;
    AOAProtocolRegistry aoa;
    GlobalTierSource tier;
    GlobalTierSource tier2;
    xPNTsFactoryV2 factory;
    xPNTsTokenV2 token;
    DummySpender spenderA;
    DummySpender spenderB;

    address owner = address(0x0A11);
    address treasury = address(0x7EA);
    address operator = address(0x0BE);
    address beneficiary = address(0xBEEF);
    address SP3 = address(0x5B3); // approved SP address used only as a pending/standby target
    address victim = address(0x71C7);
    address attacker = address(0xA77A);
    address prober;

    uint256 constant PK_PROBER = 0xB0B0;
    uint256 constant PK_U = 0xC0C0;
    uint256 constant PK_P = 0xD0D0;
    uint256 constant PK_T = 0xE0E0;

    uint256 constant MIN_POST_OP_GAS = 200_000;  // SuperPaymaster.MIN_POST_OP_GAS
    uint256 constant SETTLE_GAS_BOUND = 160_000; // SuperPaymaster.SETTLE_GAS_BOUND
    uint256 constant VERIF_GAS = 350_000;
    uint256 constant CALL_GAS = 200_000;
    uint256 constant PM_VERIF_GAS = 700_000;
    uint256 constant PVG = 50_000;
    uint256 constant POST = 300_000;

    bytes32 constant POST_OP_REVERT_REASON = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant USER_OP_EVENT = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");

    bytes32 constant H_LOCK = keccak256("adv.live.lock");
    bytes32 constant H_CREDIT = keccak256("adv.live.credit");
    bytes32 constant H_FRESH = keccak256("adv.fresh");

    string constant ABI_PATH = "abis/xPNTsTokenV2.full.json";
    string constant CORE_ARTIFACT = "out/xPNTsTokenV2.sol/xPNTsTokenV2.json";
    string constant EXT_ARTIFACT = "out/xPNTsTokenV2Ext.sol/xPNTsTokenV2Ext.json";
    string constant INIT_TUPLE = "(string,string,address,address,string,string,uint256,address,address,address)";

    function setUp() public {
        vm.deal(owner, 20 ether);
        entryPoint = new EntryPoint();
        accountFactory = new SimpleAccountFactory(IEntryPoint(address(entryPoint)));

        vm.startPrank(owner);
        registry = new AdvRegistry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        apnts = new V55APNTs();
        address feed = address(new V55PriceFeed());
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)), IRegistry(address(registry)), feed, owner, address(apnts), treasury, 3600
        );
        sp2 = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)), IRegistry(address(registry)), feed, owner, address(apnts), treasury, 3600
        );

        aoa = new AOAProtocolRegistry(owner);
        tier = new GlobalTierSource(address(registry));
        tier2 = new GlobalTierSource(address(registry)); // same codehash, different address
        spenderA = new DummySpender();
        spenderB = new DummySpender();
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp2)));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(SP3));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.bootstrapApprove(aoa.KIND_SPENDER(), address(spenderA).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsTokenV2 impl = new xPNTsTokenV2(address(aoa), address(ext));
        factory = new xPNTsFactoryV2(address(sp), address(registry), address(impl), address(tier));
        sp.setXPNTsFactory(address(factory));

        vm.warp(block.timestamp + 2 hours);
        sp.updatePrice();
        sp.deposit{value: 5 ether}();
        apnts.mint(operator, 1_000_000 ether);
        vm.stopPrank();

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), treasury);
        sp.deposit(100_000 ether);
        vm.stopPrank();

        prober = _mkUser(PK_PROBER, 100_000 ether);
    }

    // =====================================================================
    // helpers — accounts, ops, bundles
    // =====================================================================

    function _mkUser(uint256 pk, uint256 bal) internal returns (address u) {
        u = address(accountFactory.createAccount(vm.addr(pk), 0));
        vm.prank(address(registry));
        sp.updateSBTStatus(u, true);
        if (bal > 0) {
            vm.prank(operator);
            IAdv(address(token)).mint(u, bal);
        }
    }

    function _opFull(
        address sender, uint256 pk, uint256 nonce, uint256 postOpGas, uint8 flags, bytes memory callData,
        uint256 maxFee, uint256 maxRate, address tok
    ) internal view returns (PackedUserOperation memory op) {
        op.sender = sender;
        op.nonce = nonce;
        op.callData = callData;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(VERIF_GAS), uint128(CALL_GAS)));
        op.preVerificationGas = PVG;
        op.gasFees = bytes32(abi.encodePacked(uint128(maxFee), uint128(maxFee)));
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(PM_VERIF_GAS), uint128(postOpGas), operator, maxRate, tok, flags
        );
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _op(address sender, uint256 pk, uint256 nonce, uint256 postOpGas, uint8 flags, bytes memory callData, uint256 maxFee)
        internal view returns (PackedUserOperation memory)
    {
        return _opFull(sender, pk, nonce, postOpGas, flags, callData, maxFee, type(uint256).max, address(token));
    }

    function _exec(address target, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("execute(address,uint256,bytes)", target, 0, data);
    }

    function _maxCost(uint256 postOpGas, uint256 maxFee) internal pure returns (uint256) {
        return (VERIF_GAS + CALL_GAS + PM_VERIF_GAS + postOpGas + PVG) * maxFee;
    }

    function _bundle(PackedUserOperation[] memory ops) internal returns (bool ok, bytes memory err, Vm.Log[] memory logs) {
        vm.recordLogs();
        try entryPoint.handleOps(ops, payable(beneficiary)) { ok = true; } catch (bytes memory e) { err = e; }
        logs = vm.getRecordedLogs();
    }

    function _bundle1(PackedUserOperation memory op) internal returns (bool ok, bytes memory err, Vm.Log[] memory logs) {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        return _bundle(ops);
    }

    function _aa34(uint256 i) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IEntryPoint.FailedOp.selector, i, "AA34 signature error");
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) n++;
        }
    }

    /// @dev (found, success flag, actualGasCost) of the UserOperationEvent for `h`
    function _opEvent(Vm.Log[] memory logs, bytes32 h) internal pure returns (bool found, bool success, uint256 cost) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 1 && logs[i].topics[0] == USER_OP_EVENT && logs[i].topics[1] == h) {
                (, success, cost, ) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                return (true, success, cost);
            }
        }
    }

    function _opBal() internal view returns (uint128 b) { (b,,,,,,,,) = sp.operators(operator); }

    /// @dev a0 for an op with these gas parameters, measured on SP's own validation (not re-derived).
    function _a0(uint256 postOpGas, uint256 maxFee) internal returns (uint256 a0) {
        PackedUserOperation memory op = _op(prober, PK_PROBER, 0, postOpGas, 0, "", maxFee);
        uint256 maxCost = _maxCost(postOpGas, maxFee);
        uint256 sid = vmx.snapshotState();
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, keccak256("a0-probe"), maxCost);
        require(vd & 1 == 0 && ctx.length > 0, "a0 probe must validate");
        a0 = abi.decode(ctx, (SuperPaymaster.OpCtx)).a0;
        vmx.revertToState(sid);
    }

    function _enableAuto() internal {
        vm.prank(operator);
        IAdv(address(token)).queueCreditPolicy(2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IAdv(address(token)).executeCreditPolicy();
        vm.prank(owner);
        sp.updatePrice(); // refresh price staleness after the 48 h warp
    }

    // =====================================================================
    // T-R14-01 — Sybil
    // =====================================================================

    /// @notice T-R14-01 (I2, I9): N accounts under one controller, each funded with exactly its own
    ///         max-cost lock x0, all in ONE bundle. Every account pays from its own lock, every
    ///         admitted op settles, the operator's net loss equals what the users paid (unbacked
    ///         sponsorship = 0) for N = 1, 3, 6 — flat in N. An account 1 wei short is rejected.
    function test_TR1401_sybil_each_account_pays_own_lock_unbacked_zero_flat_in_N() public {
        uint256 x0 = _a0(POST, 1 gwei); // rate 1:1 → x0 == a0
        uint256[3] memory Ns = [uint256(1), 3, 6];
        uint256 pk = 0x5000;
        for (uint256 r; r < Ns.length; r++) {
            uint256 n = Ns[r];
            PackedUserOperation[] memory ops = new PackedUserOperation[](n);
            address[] memory us = new address[](n);
            for (uint256 i; i < n; i++) {
                us[i] = _mkUser(pk, x0);
                ops[i] = _op(us[i], pk, 0, POST, 0, "", 1 gwei);
                pk++;
            }
            uint128 opb0 = _opBal();
            uint256 rev0 = sp.protocolRevenue();
            (bool ok, , Vm.Log[] memory logs) = _bundle(ops);
            assertTrue(ok, "T-R14-01: bundle of funded Sybils executes");
            assertEq(_count(logs, POST_OP_REVERT_REASON), 0, "no postOp revert");
            uint256 paid;
            for (uint256 i; i < n; i++) {
                uint256 p = x0 - token.balanceOf(us[i]);
                assertGt(p, 0, "T-R14-01: every Sybil paid from its own lock");
                assertLe(p, x0, "no account paid more than its own lock");
                assertEq(token.lockedOf(us[i]), 0, "every lock settled");
                paid += p;
            }
            uint256 opLoss = uint256(opb0) - _opBal();
            assertEq(opLoss, sp.protocolRevenue() - rev0, "operator loss == revenue (no hidden leak)");
            assertEq(opLoss, paid, "T-R14-01 / I9: unbacked sponsorship (operator loss - user paid) == 0 for every N");
        }

        // An under-funded Sybil (x0 - 1) is rejected at its index; the bundle carries nothing unbacked.
        address thin = _mkUser(pk, x0 - 1);
        address fat = _mkUser(pk + 1, x0);
        PackedUserOperation[] memory mixed = new PackedUserOperation[](2);
        mixed[0] = _op(fat, pk + 1, 0, POST, 0, "", 1 gwei);
        mixed[1] = _op(thin, pk, 0, POST, 0, "", 1 gwei);
        (, bytes memory err, ) = _bundle(mixed);
        assertEq(err, _aa34(1), "T-R14-01: under-funded Sybil rejected at validation (no sponsorship without backing)");
    }

    // =====================================================================
    // T-R14-02 — same account, many max-cost ops, several nonce keys (Route A: same bundle,
    //            multiple nonce keys)
    // =====================================================================

    /// @notice T-R14-02 (I4, I9): k = 4 max-cost ops of ONE account on four nonce keys in one bundle,
    ///         free balance 4·x0 − 1 → the 4th is rejected at validation (AA34, index 3) because
    ///         balance − lockedOf < x0. Control: +1 wei admits all four. The three admitted ops all
    ///         settle and the user pays exactly the charges.
    function test_TR1402_same_account_multi_nonce_keys_kth_rejected_when_free_balance_below_x0() public {
        uint256 x0 = _a0(POST, 1 gwei);
        address u = _mkUser(PK_U, 3 * x0 + (x0 - 1));
        PackedUserOperation[] memory four = new PackedUserOperation[](4);
        for (uint256 k; k < 4; k++) four[k] = _op(u, PK_U, k << 64, POST, 0, "", 1 gwei);

        (bool ok, bytes memory err, ) = _bundle(four);
        assertEq(err, _aa34(3), "T-R14-02: 4th op rejected at validation (balance - lockedOf < x0)");

        uint256 sid = vmx.snapshotState();
        vm.prank(operator);
        IAdv(address(token)).mint(u, 1);
        (ok, err, ) = _bundle(four);
        assertTrue(ok, "control: with exactly 4*x0 free, the 4th op is admitted (rejection was the balance check)");
        vmx.revertToState(sid);

        PackedUserOperation[] memory three = new PackedUserOperation[](3);
        for (uint256 k; k < 3; k++) three[k] = four[k];
        uint256 bal0 = token.balanceOf(u);
        uint256 rev0 = sp.protocolRevenue();
        uint128 opb0 = _opBal();
        Vm.Log[] memory logs;
        (ok, , logs) = _bundle(three);
        assertTrue(ok);
        assertEq(_count(logs, POST_OP_REVERT_REASON), 0);
        for (uint256 k; k < 3; k++) {
            (bool found, bool success, ) = _opEvent(logs, entryPoint.getUserOpHash(three[k]));
            assertTrue(found && success, "every admitted op executed");
        }
        assertEq(token.lockedOf(u), 0, "T-R14-02 / I4: every admitted op settled (no residual escrow)");
        uint256 paid = bal0 - token.balanceOf(u);
        assertEq(paid, sp.protocolRevenue() - rev0, "user paid exactly the three charges");
        assertEq(uint256(opb0) - _opBal(), paid, "I9: unbacked = 0");
        assertLe(paid, 3 * x0);
    }

    // =====================================================================
    // T-R14-03 — stale blacklist
    // =====================================================================

    /// @notice T-R14-03 (I8, I9): op0's own execution makes the Registry write `isBlocked` for the
    ///         sender — after both ops of the bundle were validated. Both admitted ops settle; a new
    ///         op is rejected (AA34). Control: unblocking admits the same op.
    function test_TR1403_stale_blacklist_admitted_ops_settle_new_op_rejected() public {
        address u = _mkUser(PK_U, 10_000 ether);
        bytes memory blockSelf = _exec(address(registry), abi.encodeCall(AdvRegistry.setBlocked, (address(sp), operator, u, true)));
        PackedUserOperation[] memory ops = new PackedUserOperation[](2);
        ops[0] = _op(u, PK_U, 0, POST, 0, blockSelf, 1 gwei);
        ops[1] = _op(u, PK_U, 1 << 64, POST, 0, "", 1 gwei);
        uint256 bal0 = token.balanceOf(u);
        uint256 rev0 = sp.protocolRevenue();

        (bool ok, , Vm.Log[] memory logs) = _bundle(ops);
        assertTrue(ok);
        (, bool blocked) = sp.userOpState(operator, u);
        assertTrue(blocked, "precondition: blacklist written inside the bundle, after both validations");
        (bool f0, bool s0, ) = _opEvent(logs, entryPoint.getUserOpHash(ops[0]));
        (bool f1, bool s1, ) = _opEvent(logs, entryPoint.getUserOpHash(ops[1]));
        assertTrue(f0 && s0 && f1 && s1, "both admitted ops executed");
        assertEq(token.lockedOf(u), 0, "T-R14-03: both admitted ops settled");
        assertEq(bal0 - token.balanceOf(u), sp.protocolRevenue() - rev0, "user paid both charges (I9)");
        assertGt(bal0 - token.balanceOf(u), 0);

        PackedUserOperation memory fresh = _op(u, PK_U, 2 << 64, POST, 0, "", 1 gwei);
        bytes memory err;
        (ok, err, ) = _bundle1(fresh);
        assertEq(err, _aa34(0), "T-R14-03: new op after the blacklist write is rejected at validation");

        registry.setBlocked(address(sp), operator, u, false);
        (ok, , ) = _bundle1(fresh);
        assertTrue(ok, "control: same op admitted once unblocked (the rejection was isBlocked)");
    }

    // =====================================================================
    // T-R14-04 — user execution reverts (opReverted)
    // =====================================================================

    /// @notice T-R14-04 (I8): the user's call reverts; EntryPoint reports success=false, postOp runs
    ///         in opReverted mode, the user still pays (xc burned) and the lock is cleared.
    function test_TR1404_user_execution_revert_still_pays_and_clears_lock() public {
        AdvReverter rv = new AdvReverter();
        address u = _mkUser(PK_U, 10_000 ether);
        PackedUserOperation memory op = _op(u, PK_U, 0, POST, 0, _exec(address(rv), abi.encodeCall(AdvReverter.boom, ())), 1 gwei);
        bytes32 h = entryPoint.getUserOpHash(op);
        uint256 bal0 = token.balanceOf(u);
        uint256 rev0 = sp.protocolRevenue();

        (bool ok, , Vm.Log[] memory logs) = _bundle1(op);
        assertTrue(ok);
        (bool found, bool success, ) = _opEvent(logs, h);
        assertTrue(found, "op processed");
        assertFalse(success, "precondition: user execution reverted (opReverted, not postOp revert)");
        assertEq(_count(logs, POST_OP_REVERT_REASON), 0, "postOp itself did not revert");
        uint256 paid = bal0 - token.balanceOf(u);
        assertGt(paid, 0, "T-R14-04: user still pays for gas when its execution reverts");
        assertEq(paid, sp.protocolRevenue() - rev0, "charge == burned xPNTs (rate 1:1)");
        assertEq(token.lockedOf(u), 0, "T-R14-04: lock cleared");
        assertEq(token.lockOf(h, u).locker, address(0), "lock record deleted");
        (address f, ) = sp.inflightOf(h);
        assertEq(f, address(0), "in-flight cleared");
        assertEq(token.debts(u), 0);
    }

    // =====================================================================
    // T-R14-05 — postOp revert (Route A: postOp revert incl. EntryPoint penalty)
    // =====================================================================

    /// @notice T-R14-05 (I10): settlement forced to revert. Execution undone, user token balance
    ///         untouched (attacker gain 0), escrow and the operator's a0 stay until the transaction
    ///         ends (operator loss == a0 while in flight, never more), protocolRevenue NOT inflated;
    ///         the EntryPoint gas incl. the unused-gas penalty is taken from SP's ETH deposit, never
    ///         from the sender. After the tx both stale releases restore user and operator in full.
    /// forge-config: default.isolate = true
    function test_TR1405_postOp_revert_undoes_execution_operator_loss_le_a0_attacker_gain_zero() public {
        V55Counter counter = new V55Counter();
        address u = _mkUser(PK_U, 10_000 ether);
        PackedUserOperation memory op = _op(u, PK_U, 0, POST, 0, _exec(address(counter), abi.encodeCall(V55Counter.inc, ())), 1 gwei);
        bytes32 h = entryPoint.getUserOpHash(op);
        uint256 bal0 = token.balanceOf(u);
        uint128 opb0 = _opBal();
        uint256 rev0 = sp.protocolRevenue();
        uint256 dep0 = entryPoint.balanceOf(address(sp));
        uint256 senderDep0 = entryPoint.balanceOf(u);

        vm.mockCallRevert(address(token), abi.encodeWithSelector(IxPNTsTokenV2.settleLocked.selector), "settle boom");
        (bool ok, , Vm.Log[] memory logs) = _bundle1(op);
        vm.clearMockedCalls();

        assertEq(counter.n(), 0, "T-R14-05 / I8: failed settlement must undo the user's execution");
        assertEq(token.balanceOf(u), bal0, "T-R14-05: user not charged -> attacker gain 0 (got nothing, paid nothing)");
        assertTrue(ok, "bundle succeeds (postOpReverted path)");
        assertEq(_count(logs, POST_OP_REVERT_REASON), 1, "postOp revert surfaced as PostOpRevertReason");
        (bool found, bool success, uint256 cost) = _opEvent(logs, h);
        assertTrue(found);
        assertFalse(success);
        (address f, uint256 a0) = sp.inflightOf(h);
        assertEq(f, operator);
        assertEq(uint256(opb0) - _opBal(), a0, "T-R14-05: operator loss while in flight == a0 (<= a0)");
        assertEq(sp.protocolRevenue(), rev0, "R10-M1b: protocolRevenue not inflated by a failed op");
        assertEq(dep0 - entryPoint.balanceOf(address(sp)), cost, "EntryPoint gas + penalty taken from SP's ETH deposit");
        assertEq(entryPoint.balanceOf(u), senderDep0, "sender's EntryPoint deposit untouched");
        assertGt(token.lockedOf(u), 0, "escrow stays until the transaction ends");

        token.releaseStaleLock(u, h);
        sp.releaseStaleSponsorship(h);
        assertEq(token.lockedOf(u), 0, "escrow released in full");
        assertEq(token.balanceOf(u), bal0);
        assertEq(_opBal(), opb0, "T-R14-05: operator loss after release == 0");
        assertEq(counter.n(), 0);
    }

    // =====================================================================
    // T-R14-06 — creditPolicy OFF: debts never increase
    // =====================================================================

    /// @notice T-R14-06 (I3): with the AOA community's policy OFF (read back at start and end), every
    ///         path — empty account, under-funded account, funded op, reverted op, a user credit
    ///         request with a big tier, and a malicious SP calling the credit entry points directly —
    ///         leaves debts at 0.
    function test_TR1406_credit_off_debts_never_increase_on_any_path() public {
        assertEq(token.creditPolicy(), 0, "measurement start: OFF");
        AdvReverter rv = new AdvReverter();
        address rich = _mkUser(PK_U, 10_000 ether);
        address poor = _mkUser(PK_P, 0);
        address thin = _mkUser(PK_T, 1 ether); // below x0
        registry.setCreditLimit(poor, 1_000 ether);
        registry.setCreditLimit(thin, 1_000 ether);
        vm.prank(poor);
        IAdv(address(token)).requestCredit(1_000 ether);
        vm.prank(thin);
        IAdv(address(token)).requestCredit(1_000 ether);
        assertEq(token.effectiveCreditCap(poor), 0, "OFF -> cap 0 despite request + tier");

        (bool ok, bytes memory err, ) = _bundle1(_op(poor, PK_P, 0, POST, 0, "", 1 gwei));
        assertEq(err, _aa34(0), "empty account rejected");
        (ok, err, ) = _bundle1(_op(thin, PK_T, 0, POST, 0, "", 1 gwei));
        assertEq(err, _aa34(0), "under-funded account: INSUFFICIENT does not fall back to credit under OFF");
        (ok, , ) = _bundle1(_op(rich, PK_U, 0, POST, 0, "", 1 gwei));
        assertTrue(ok, "funded op sponsored in balance mode");
        (ok, , ) = _bundle1(_op(rich, PK_U, 1, POST, 0, _exec(address(rv), abi.encodeCall(AdvReverter.boom, ())), 1 gwei));
        assertTrue(ok, "reverted op still settles in balance mode");

        vm.prank(address(sp));
        IxPNTsTokenV2.CreditResult cr = token.tryReserveCredit(poor, H_FRESH, 1 ether);
        assertEq(uint8(cr), uint8(IxPNTsTokenV2.CreditResult.NO_CREDIT), "malicious SP: no reservation under OFF");
        vm.prank(address(sp));
        vm.expectRevert(xPNTsV2Base.NoLock.selector);
        token.settleCredit(poor, H_FRESH, 1 ether);

        assertEq(token.debts(rich), 0, "T-R14-06: rich debts 0");
        assertEq(token.debts(poor), 0, "T-R14-06: poor debts 0");
        assertEq(token.debts(thin), 0, "T-R14-06: thin debts 0");
        assertEq(token.creditReservedOf(poor), 0);
        assertEq(token.creditPolicy(), 0, "measurement end: OFF");
    }

    // =====================================================================
    // T-R14-07 — attacker-tuned gas cannot keep an unpaid execution
    // =====================================================================

    /// @notice T-R14-07 (I9), axis 1: the attacker picks paymasterPostOpGasLimit. Sweep around the
    ///         floor: below MIN_POST_OP_GAS → rejected at validation; at and above → executed AND
    ///         settled. "Execution kept, settlement failed" never occurs.
    function test_TR1407_postOpGasLimit_sweep_via_entrypoint() public {
        V55Counter counter = new V55Counter();
        address u = _mkUser(PK_U, 10_000 ether);
        bytes memory exec = _exec(address(counter), abi.encodeCall(V55Counter.inc, ()));
        uint256[9] memory limits = [
            MIN_POST_OP_GAS - 10_000, MIN_POST_OP_GAS - 1, MIN_POST_OP_GAS, MIN_POST_OP_GAS + 1,
            MIN_POST_OP_GAS + 1_000, MIN_POST_OP_GAS + 20_000, 260_000, 400_000, 1_000_000
        ];
        uint256 settled;
        for (uint256 i; i < limits.length; i++) {
            uint256 sid = vmx.snapshotState();
            PackedUserOperation memory op = _op(u, PK_U, 0, limits[i], 0, exec, 1 gwei);
            uint256 bal0 = token.balanceOf(u);
            (bool ok, bytes memory err, Vm.Log[] memory logs) = _bundle1(op);
            bool executed = counter.n() == 1;
            bool paid = token.balanceOf(u) < bal0 && token.lockedOf(u) == 0;
            assertFalse(executed && !paid, "T-R14-07: execution kept without settlement");
            if (limits[i] < MIN_POST_OP_GAS) {
                assertEq(err, _aa34(0), "below the floor: rejected at validation");
            } else {
                assertTrue(ok && executed && paid, "at/above the floor: executed and settled");
                assertEq(_count(logs, POST_OP_REVERT_REASON), 0);
                settled++;
            }
            vmx.revertToState(sid);
        }
        assertEq(settled, 7);
    }

    /// @notice T-R14-07 axis 2: the attacker is the bundler and tunes handleOps' gas. Every outcome
    ///         is either a whole-bundle revert or "executed and settled" (a postOp revert would undo
    ///         the execution); the sweep is shown to cross the boundary (both outcomes occur).
    function test_TR1407_bundler_gas_sweep_never_keeps_unpaid_execution() public {
        V55Counter counter = new V55Counter();
        address u = _mkUser(PK_U, 10_000 ether);
        PackedUserOperation memory op =
            _op(u, PK_U, 0, MIN_POST_OP_GAS, 0, _exec(address(counter), abi.encodeCall(V55Counter.inc, ())), 1 gwei);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        uint256 reverted;
        uint256 settledOk;
        uint256 undone;
        for (uint256 g = 300_000; g <= 1_600_000; g += 10_000) {
            uint256 sid = vmx.snapshotState();
            uint256 bal0 = token.balanceOf(u);
            vm.recordLogs();
            bool ok;
            try entryPoint.handleOps{gas: g}(ops, payable(beneficiary)) { ok = true; } catch {}
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool executed = counter.n() == 1;
            bool paid = token.balanceOf(u) < bal0 && token.lockedOf(u) == 0;
            assertFalse(executed && !paid, "T-R14-07: execution kept without settlement");
            if (!ok) reverted++;
            else if (executed) settledOk++;
            else {
                assertEq(_count(logs, POST_OP_REVERT_REASON), 1, "a processed-but-not-executed op must be a postOp revert");
                assertEq(token.balanceOf(u), bal0, "undone op charges nothing");
                undone++;
            }
            vmx.revertToState(sid);
        }
        console.log("bundler gas sweep: reverted / executed+settled / postOp-undone", reverted, settledOk, undone);
        assertGt(reverted, 0, "sweep reaches the starved region");
        assertGt(settledOk, 0, "sweep reaches the sufficient region");
    }

    /// @notice T-R14-07 axis 3 (below EntryPoint's granularity): postOp called with a hand-tuned gas
    ///         amount across [guard − ε, full cost]. postOp RETURNS only when the settlement happened;
    ///         every other outcome is a whole revert that leaves the escrow for stale release. The
    ///         smallest successful gas stays below MIN_POST_OP_GAS, so the floor admits no OOG band.
    function test_TR1407_direct_postOp_gas_sweep_returns_only_when_settled() public {
        address u = _mkUser(PK_U, 10_000 ether);
        PackedUserOperation memory op = _op(u, PK_U, 0, MIN_POST_OP_GAS, 0, "", 1 gwei);
        uint256 maxCost = _maxCost(MIN_POST_OP_GAS, 1 gwei);
        uint256 guard;
        uint256 oog;
        uint256 okN;
        uint256 minOk;
        for (uint256 g = SETTLE_GAS_BOUND - 10_000; g <= 240_000; g += 1_000) {
            uint256 sid = vmx.snapshotState();
            bytes32 h = keccak256(abi.encode("sweep", g));
            vm.prank(address(entryPoint));
            (bytes memory ctx, ) = sp.validatePaymasterUserOp(op, h, maxCost);
            uint256 bal0 = token.balanceOf(u);
            vm.prank(address(entryPoint));
            try sp.postOp{gas: g}(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei) {
                okN++;
                if (minOk == 0) minOk = g;
                assertEq(token.lockedOf(u), 0, "T-R14-07: postOp returned -> escrow settled");
                assertGt(bal0 - token.balanceOf(u), 0, "T-R14-07: postOp returned -> user charged");
                (address f, ) = sp.inflightOf(h);
                assertEq(f, address(0), "postOp returned -> in-flight cleared");
            } catch (bytes memory e) {
                if (e.length >= 4 && bytes4(e) == SuperPaymaster.PostOpGasTooLow.selector) guard++;
                else oog++;
                assertGt(token.lockedOf(u), 0, "failed postOp leaves the escrow (nothing half-settled)");
                assertEq(token.balanceOf(u), bal0, "failed postOp charges nothing");
            }
            vmx.revertToState(sid);
        }
        console.log("direct postOp sweep: guard / other-revert / ok / min ok gas", guard, oog, okN);
        console.log("min successful postOp gas", minOk);
        assertGt(guard, 0, "entry guard exercised");
        assertGt(okN, 0, "success region reached");
        assertEq(oog, 0, "no OOG band: every call past the entry guard settles (SETTLE_GAS_BOUND covers the rest of postOp)");
        assertLe(minOk, MIN_POST_OP_GAS, "floor covers the whole settle path (no reachable OOG band)");
    }

    // =====================================================================
    // T-R14-08 — N credit ops in one bundle over the cap
    // =====================================================================

    /// @notice T-R14-08 (I3, C-1): an empty account on AUTO credit with cap 4·a0 − 1 sends four
    ///         max-cost ops in one bundle → the 4th is rejected at validation (EXCEEDS_CAP → AA34).
    ///         Control: cap 4·a0 admits all four. The three admitted ops settle into debt ≤ cap.
    function test_TR1408_credit_bundle_over_cap_kth_rejected_at_validation() public {
        _enableAuto();
        uint256 a0 = _a0(POST, 1 gwei);
        address poor = _mkUser(PK_P, 0);
        vm.prank(poor);
        IAdv(address(token)).requestCredit(10_000 ether);
        registry.setCreditLimit(poor, 4 * a0 - 1); // tier is the binding cap
        assertEq(token.effectiveCreditCap(poor), 4 * a0 - 1, "precondition: effective cap");

        PackedUserOperation[] memory four = new PackedUserOperation[](4);
        for (uint256 k; k < 4; k++) four[k] = _op(poor, PK_P, k << 64, POST, 0, "", 1 gwei);
        (bool ok, bytes memory err, ) = _bundle(four);
        assertEq(err, _aa34(3), "T-R14-08: 4th credit op rejected at validation (debts + reserved + a0 > cap)");

        uint256 sid = vmx.snapshotState();
        registry.setCreditLimit(poor, 4 * a0);
        (ok, , ) = _bundle(four);
        assertTrue(ok, "control: cap == 4*a0 admits all four (rejection was EXCEEDS_CAP)");
        vmx.revertToState(sid);

        PackedUserOperation[] memory three = new PackedUserOperation[](3);
        for (uint256 k; k < 3; k++) three[k] = four[k];
        uint256 rev0 = sp.protocolRevenue();
        (ok, , ) = _bundle(three);
        assertTrue(ok);
        assertEq(token.creditReservedOf(poor), 0, "every admitted reservation consumed");
        assertEq(token.debts(poor), sp.protocolRevenue() - rev0, "debt == charges (I3: only via settleCredit)");
        assertLe(token.debts(poor), 4 * a0 - 1, "C-1: debt within the cap");
        assertGt(token.debts(poor), 0);
    }

    // =====================================================================
    // Route A (§9 A layer) — self-drain, maxCost above the cap
    //   same bundle → T-R14-01/02; multiple nonce keys → T-R14-02; postOp revert → T-R14-05
    // =====================================================================

    /// @notice Route A self-drain: the op's own execution tries to move the WHOLE balance out while
    ///         its escrow is held → A-1 blocks the transfer, the execution reverts, the user still
    ///         pays. Control: moving balance − x0 succeeds and the escrow still settles.
    function test_RouteA_self_drain_blocked_by_escrow_user_still_pays() public {
        address u = _mkUser(PK_U, 1_000 ether);
        address sink = address(0x5111);
        uint256 x0 = _a0(POST, 1 gwei);

        PackedUserOperation memory drain = _op(u, PK_U, 0, POST, 0, _exec(address(token), abi.encodeCall(IERC20.transfer, (sink, 1_000 ether))), 1 gwei);
        bytes32 h = entryPoint.getUserOpHash(drain);
        (bool ok, , Vm.Log[] memory logs) = _bundle1(drain);
        assertTrue(ok);
        (, bool success, ) = _opEvent(logs, h);
        assertFalse(success, "Route A self-drain: the drain transfer reverts (BalanceLocked)");
        assertEq(token.balanceOf(sink), 0, "Route A self-drain: nothing left the account");
        assertGt(1_000 ether - token.balanceOf(u), 0, "Route A self-drain: user still paid");
        assertEq(token.lockedOf(u), 0);

        uint256 bal = token.balanceOf(u);
        PackedUserOperation memory partial_ = _op(u, PK_U, 1, POST, 0, _exec(address(token), abi.encodeCall(IERC20.transfer, (sink, bal - x0))), 1 gwei);
        h = entryPoint.getUserOpHash(partial_);
        (ok, , logs) = _bundle1(partial_);
        (, success, ) = _opEvent(logs, h);
        assertTrue(ok && success, "control: moving balance - x0 is allowed");
        assertEq(token.balanceOf(sink), bal - x0);
        assertLt(token.balanceOf(u), x0, "the escrowed x0 still paid the charge");
        assertEq(token.lockedOf(u), 0);

        // same-bundle variant: op0 drains while op1's escrow is also held; both still settle
        address v = _mkUser(PK_T, 1_000 ether);
        PackedUserOperation[] memory two = new PackedUserOperation[](2);
        two[0] = _op(v, PK_T, 0, POST, 0, _exec(address(token), abi.encodeCall(IERC20.transfer, (sink, 1_000 ether - x0))), 1 gwei);
        two[1] = _op(v, PK_T, 1 << 64, POST, 0, "", 1 gwei);
        uint256 sink0 = token.balanceOf(sink);
        (ok, , logs) = _bundle(two);
        assertTrue(ok);
        (, success, ) = _opEvent(logs, entryPoint.getUserOpHash(two[0]));
        assertFalse(success, "Route A same-bundle drain: blocked by the sibling op's escrow (2*x0 locked)");
        assertEq(token.balanceOf(sink), sink0, "nothing drained");
        assertEq(token.lockedOf(v), 0, "both ops settled");
        assertGt(1_000 ether - token.balanceOf(v), 0);
    }

    /// @notice Route A maxCost above the cap (single-tx limit): a0 > maxSingleTxLimit → validation
    ///         fails (SINGLE_TX_LIMIT, never truncated to the limit), nothing is written. Control at 1 gwei.
    function test_RouteA_maxCost_above_single_tx_limit_rejected_not_truncated() public {
        address u = _mkUser(PK_U, 40_000 ether); // balance is NOT the limiting factor
        vm.prank(u);
        IAdv(address(token)).setAutoAllowance(address(sp), 50_000 ether);
        vm.prank(u);
        IAdv(address(token)).setUserTotalCap(50_000 ether);
        uint256 fee = 40 gwei;
        // a0 is linear in maxCost (two ceilings → ≤ 2 wei-units of slack per gwei step); the probe
        // itself cannot run at 40 gwei (it would hit the very limit under test)
        assertGt(_a0(POST, 1 gwei) * 40 - 100, token.maxSingleTxLimit(), "precondition: a0 exceeds the single-tx limit");

        (bool ok, bytes memory err, ) = _bundle1(_op(u, PK_U, 0, POST, 0, "", fee));
        assertEq(err, _aa34(0), "Route A: maxCost above the single-tx limit rejected (no truncation)");
        assertEq(token.lockedOf(u), 0, "nothing escrowed");
        (, uint256 used) = token.autoAllowance(u, address(sp));
        assertEq(used, 0, "no allowance consumed");

        (ok, , ) = _bundle1(_op(u, PK_U, 0, POST, 0, "", 1 gwei));
        assertTrue(ok, "control: same account at normal maxCost");
    }

    /// @notice Route A maxCost above the cap (auto-allowance): a0 > the user's SP cap (≥ floor) →
    ///         INSUFFICIENT; with credit OFF, validation fails — the reserve is never clipped to the
    ///         remaining cap. Control: an op whose a0 fits the cap.
    function test_RouteA_maxCost_above_auto_cap_rejected_not_truncated() public {
        address u = _mkUser(PK_U, 10_000 ether);
        vm.prank(u);
        IAdv(address(token)).setAutoAllowance(address(sp), 300 ether);
        uint256 a0Big = _a0(POST, 2 gwei);
        uint256 a0Small = _a0(POST, 1 gwei);
        assertGt(a0Big, 300 ether, "precondition: a0 above the SP cap");
        assertLe(a0Small, 300 ether, "precondition: control fits");

        (bool ok, bytes memory err, ) = _bundle1(_op(u, PK_U, 0, POST, 0, "", 2 gwei));
        assertEq(err, _aa34(0), "Route A: maxCost above the auto cap rejected (no truncation)");
        assertEq(token.lockedOf(u), 0);
        (, uint256 used) = token.autoAllowance(u, address(sp));
        assertEq(used, 0);
        (ok, , ) = _bundle1(_op(u, PK_U, 0, POST, 0, "", 1 gwei));
        assertTrue(ok, "control: a0 within the cap");
    }

    // =====================================================================
    // R-2 routing: only INSUFFICIENT falls back to credit
    // =====================================================================

    /// @notice A lock result other than INSUFFICIENT (here INVALID_RENEWAL, A-5) must fail the whole
    ///         validation even though credit WOULD be available. Control: the same account without
    ///         the renew flag is sponsored in CREDIT mode.
    function test_routing_invalid_renewal_never_falls_back_to_credit() public {
        _enableAuto();
        address poor = _mkUser(PK_P, 0);
        registry.setCreditLimit(poor, 1_000 ether);
        vm.startPrank(poor);
        IAdv(address(token)).requestCredit(1_000 ether);
        IAdv(address(token)).setRenewalMode(1); // ACCOUNT_ONLY → SP_RENEW is INVALID_RENEWAL
        vm.stopPrank();
        uint256 maxCost = _maxCost(POST, 1 gwei);

        PackedUserOperation memory renew = _op(poor, PK_P, 0, POST, 1, "", 1 gwei);
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(renew, keccak256("r1"), maxCost);
        assertEq(vd & 1, 1, "A-5: INVALID_RENEWAL fails validation, no credit fallback");
        assertEq(ctx.length, 0);
        assertEq(token.creditReservedOf(poor), 0, "no reservation written");

        PackedUserOperation memory plain = _op(poor, PK_P, 0, POST, 0, "", 1 gwei);
        vm.prank(address(entryPoint));
        (ctx, vd) = sp.validatePaymasterUserOp(plain, keccak256("r2"), maxCost);
        assertEq(vd & 1, 0, "control: credit is available to this account");
        assertEq(abi.decode(ctx, (SuperPaymaster.OpCtx)).mode, 2, "control: CREDIT mode");
    }

    // =====================================================================
    // §8 migration — operator still bound to a 3.x token gets sigFail (AA34), not AA33
    // =====================================================================

    /// @dev Overwrite operators[op].xPNTsToken in the SP proxy (simulates a pre-upgrade config).
    function _setOperatorToken(address op, address newTok) internal {
        address cur = address(token);
        for (uint256 s; s < 256; s++) {
            bytes32 base = keccak256(abi.encode(op, s));
            for (uint256 w; w < 4; w++) {
                bytes32 slot = bytes32(uint256(base) + w);
                uint256 word = uint256(vm.load(address(sp), slot));
                if (address(uint160(word)) == cur) {
                    vm.store(address(sp), slot, bytes32((word & ~uint256(type(uint160).max)) | uint256(uint160(newTok))));
                    return;
                }
            }
        }
        revert("operators[op].xPNTsToken slot not found");
    }

    function test_migration_legacy3x_token_operator_gets_sigFail_AA34_not_AA33() public {
        address u = _mkUser(PK_U, 10_000 ether);
        xPNTsToken legacy = xPNTsToken(Clones.clone(address(new xPNTsToken())));
        legacy.initialize("Legacy", "LGC", operator, "C", "c.eth", 1 ether);
        legacy.mint(u, 10_000 ether); // this test is the legacy token's FACTORY
        _setOperatorToken(operator, address(legacy));
        (, bool configured, , address tokNow, , , , , ) = sp.operators(operator);
        assertEq(tokNow, address(legacy), "precondition: operator stored with a 3.x token");
        assertTrue(configured, "precondition: still configured (not paused)");

        PackedUserOperation memory op = _opFull(u, PK_U, 0, POST, 0, "", 1 gwei, type(uint256).max, address(legacy));
        (bool ok, bytes memory err, ) = _bundle1(op);
        assertEq(err, _aa34(0), "3.x token via EntryPoint: AA34 signature error, NOT AA33 reverted");

        uint256 maxCost = _maxCost(POST, 1 gwei);
        vm.prank(address(entryPoint));
        try sp.validatePaymasterUserOp(op, keccak256("legacy"), maxCost) returns (bytes memory ctx, uint256 vd) {
            assertEq(vd & 1, 1, "3.x token: validation returns SIG_FAILURE");
            assertEq(ctx.length, 0);
        } catch {
            assertTrue(false, "3.x token: validation reverted (the AA33 path the spec forbids)");
        }
        assertEq(legacy.balanceOf(u), 10_000 ether, "legacy token untouched");
        assertEq(legacy.debts(u), 0, "no legacy debt written");

        // control: the same operator with its v2 token validates
        _setOperatorToken2(operator, address(legacy), address(token));
        (ok, , ) = _bundle1(_op(u, PK_U, 0, POST, 0, "", 1 gwei));
        assertTrue(ok, "control: v2 token path sponsors");
    }

    /// @notice §3.3 (D3 finding): the rate-commitment read is try/catch'd like every other token
    ///         call — a bound token that cannot answer `exchangeRate()` yields SIG_FAILURE (AA34),
    ///         never a validation revert (AA33).
    function test_token_without_exchangeRate_gets_sigFail_not_revert() public {
        address u = _mkUser(PK_U, 10_000 ether);
        address bogus = address(new NoExchangeRate());
        _setOperatorToken2(operator, address(token), bogus);
        PackedUserOperation memory op = _opFull(u, PK_U, 0, POST, 0, "", 1 gwei, type(uint256).max, bogus);
        uint256 maxCost = _maxCost(POST, 1 gwei);
        vm.prank(address(entryPoint));
        try sp.validatePaymasterUserOp(op, keccak256("norate"), maxCost) returns (bytes memory ctx, uint256 vd) {
            assertEq(vd & 1, 1, "no exchangeRate(): SIG_FAILURE");
            assertEq(ctx.length, 0);
        } catch {
            assertTrue(false, "no exchangeRate(): validation reverted (AA33 path)");
        }
        (, bytes memory err, ) = _bundle1(op);
        assertEq(err, _aa34(0), "via EntryPoint: AA34, not AA33");
    }

    function _setOperatorToken2(address op, address from, address to) internal {
        for (uint256 s; s < 256; s++) {
            bytes32 base = keccak256(abi.encode(op, s));
            for (uint256 w; w < 4; w++) {
                bytes32 slot = bytes32(uint256(base) + w);
                uint256 word = uint256(vm.load(address(sp), slot));
                if (address(uint160(word)) == from) {
                    vm.store(address(sp), slot, bytes32((word & ~uint256(type(uint160).max)) | uint256(uint160(to))));
                    return;
                }
            }
        }
        revert("slot not found");
    }

    // =====================================================================
    // R1-3 six classes (§9): gaps filled here; the rest are pointed to in the D3 report
    // =====================================================================

    /// @notice R1-3 stolen owner: the community-owner key (here the operator) cannot pull or burn a
    ///         user's tokens, cannot install a spender faster than 48 h, an installed spender has
    ///         default cap 0, and a rate rug-pull is refused by the user's signed maxRate.
    function test_R13_stolen_owner_cannot_take_user_funds() public {
        address u = _mkUser(PK_U, 10_000 ether);
        vm.startPrank(operator);
        vm.expectRevert(xPNTsV2Base.BurnExceedsAllowance.selector);
        token.transferFrom(u, operator, 1 ether);
        vm.expectRevert(xPNTsV2Base.BurnExceedsAllowance.selector);
        token.burn(u, 1 ether);
        IAdv(address(token)).proposeSpender(address(spenderA));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert();
        IAdv(address(token)).activateSpender(address(spenderA));
        vm.warp(vm.getBlockTimestamp() + 1);
        IAdv(address(token)).activateSpender(address(spenderA));
        vm.expectRevert(xPNTsV2Base.AutoAllowanceExceeded.selector);
        spenderA.pull(address(token), u, 1 ether);

        vm.prank(owner);
        sp.updatePrice();
        vm.prank(operator);
        IAdv(address(token)).updateExchangeRate(1.2 ether);
        (bool ok, bytes memory err, ) = _bundle1(_opFull(u, PK_U, 0, POST, 0, "", 1 gwei, 1 ether, address(token)));
        assertEq(err, _aa34(0), "raised rate > user's signed maxRate -> rejected");
        (ok, , ) = _bundle1(_opFull(u, PK_U, 0, POST, 0, "", 1 gwei, 1.2 ether, address(token)));
        assertTrue(ok, "control: an op committing to the new rate is sponsored");
        assertGe(token.balanceOf(u), 10_000 ether - _a0(POST, 1 gwei) * 12 / 10 - 1, "user lost at most one op's charge");
    }

    /// @notice R1-3 repeated transfer: two activated spenders pull again and again; the total taken
    ///         equals the user's total cap (I2: Σ spenders ≤ total), each spender stays within its cap.
    function test_R13_repeated_pulls_bounded_by_caps() public {
        address u = address(0x1313);
        vm.prank(operator);
        IAdv(address(token)).mint(u, 10_000 ether);
        vm.startPrank(operator);
        IAdv(address(token)).proposeSpender(address(spenderA));
        IAdv(address(token)).proposeSpender(address(spenderB));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IAdv(address(token)).activateSpender(address(spenderA));
        IAdv(address(token)).activateSpender(address(spenderB));
        vm.startPrank(u);
        IAdv(address(token)).setAutoAllowance(address(spenderA), 200 ether);
        IAdv(address(token)).setAutoAllowance(address(spenderB), 200 ether);
        IAdv(address(token)).setUserTotalCap(250 ether);
        vm.stopPrank();

        uint256 pulled;
        for (uint256 i; i < 80; i++) {
            DummySpender s = i % 2 == 0 ? spenderA : spenderB;
            try s.pull(address(token), u, 10 ether) { pulled += 10 ether; } catch {}
        }
        assertEq(pulled, 250 ether, "R1-3 repeated transfer: total pulled == user total cap");
        assertLe(token.balanceOf(address(spenderA)), 200 ether, "per-spender cap");
        assertLe(token.balanceOf(address(spenderB)), 200 ether, "per-spender cap");
        assertEq(token.balanceOf(u), 10_000 ether - 250 ether);
    }

    /// @notice R1-3 SP replacement at the SP level: while sp2 is only PENDING it cannot lock and the
    ///         current SP still sponsors; after activation the old SP's validation for this token
    ///         fails closed (tryLockForGas Unauthorized → caught → AA34), never AA33.
    function test_R13_sp_replacement_pending_cannot_lock_old_sp_fails_closed() public {
        address u = _mkUser(PK_U, 10_000 ether);
        vm.prank(operator);
        IAdv(address(token)).proposeSP(address(sp2));
        vm.prank(address(sp2));
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, address(sp2)));
        token.tryLockForGas(u, H_FRESH, 1 ether, false);
        (bool ok, bytes memory err, ) = _bundle1(_op(u, PK_U, 0, POST, 0, "", 1 gwei));
        assertTrue(ok, "during the 48 h window the current SP keeps working");

        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IAdv(address(token)).activateSP();
        vm.prank(owner);
        sp.updatePrice();
        (ok, err, ) = _bundle1(_op(u, PK_U, 1, POST, 0, "", 1 gwei));
        assertEq(err, _aa34(0), "old SP after rotation: AA34 (fail closed), not AA33");
        assertTrue(token.historicalSP(address(sp)), "old SP is historical");
    }

    /// @notice R1-3 revocation at the SP level: the user's emergency disable (E-1) and the
    ///         community's emergency revoke (S-4) both reject new ops through EntryPoint; re-enable
    ///         restores (control).
    function test_R13_revocation_user_disable_and_emergency_reject_via_entrypoint() public {
        address u = _mkUser(PK_U, 10_000 ether);
        vm.prank(u);
        IAdv(address(token)).disableSpenderForSelf(address(sp));
        (bool ok, bytes memory err, ) = _bundle1(_op(u, PK_U, 0, POST, 0, "", 1 gwei));
        assertEq(err, _aa34(0), "E-1: user-disabled SP cannot sponsor");
        vm.prank(u);
        IAdv(address(token)).enableSpenderForSelf(address(sp));
        (ok, , ) = _bundle1(_op(u, PK_U, 0, POST, 0, "", 1 gwei));
        assertTrue(ok, "control: re-enabled");
        vm.prank(operator);
        IAdv(address(token)).emergencyRevokePaymaster();
        (ok, err, ) = _bundle1(_op(u, PK_U, 1, POST, 0, "", 1 gwei));
        assertEq(err, _aa34(0), "S-4: emergency revoke rejects new ops");
    }

    // =====================================================================
    // §8 / §9 — malicious SP calls EVERY selector of the combined token ABI
    // =====================================================================

    uint8 constant C_VIEW = 0;
    uint8 constant C_PRIV = 1;  // the four SP entry points (bounded by I6)
    uint8 constant C_ANY = 2;   // permissionless (timelock execution / stale release)
    uint8 constant C_SELF = 3;  // acts on msg.sender's own cells only
    uint8 constant C_SIG = 4;   // needs the victim's signature
    uint8 constant C_ADMIN = 5; // communityOwner / factory / initializer
    uint8 constant C_PULL = 6;  // third-party spend (A-3)
    uint8 constant C_NONE = 255;
    uint256 constant MAX_COMBOS = 96;

    struct AbiFn { string sig; string[] types; bool isView; }

    /// @dev Every NON-view function of the combined ABI, classified. A function added to the ABI
    ///      and missing here makes the sweep fail ("unclassified"); an entry here missing from the
    ///      ABI fails too ("stale table").
    function _nonViewTable() internal pure returns (string[53] memory s, uint8[53] memory c) {
        s = [
            "tryLockForGas(address,bytes32,uint256,bool)", "settleLocked(address,bytes32,uint256)",
            "tryReserveCredit(address,bytes32,uint256)", "settleCredit(address,bytes32,uint256)",
            "releaseStaleLock(address,bytes32)", "releaseStaleCredit(address,bytes32)", "executeCreditPolicy()",
            "executeTierSource()", "activateSP()", "activateSpender(address)", "activateStandbyDesignation()",
            "approve(address,uint256)", "transfer(address,uint256)", "burn(uint256)", "renewForSelf(address)",
            "setAutoAllowance(address,uint256)", "setUserTotalCap(uint256)", "setRenewalMode(uint8)",
            "disableSpenderForSelf(address)", "enableSpenderForSelf(address)", "releaseAndDisable(address,bytes32)",
            "requestCredit(uint256)", "revokeCredit()", "repayDebt(uint256)", "transferAndCall(address,uint256)",
            "transferAndCall(address,uint256,bytes)",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)", "executeBySig(address,uint8,bytes,uint256,bytes)",
            string.concat("initialize(", INIT_TUPLE, ")"), "mint(address,uint256)", "updateExchangeRate(uint256)",
            "setMaxSingleTxLimit(uint256)", "setSpenderDailyCap(uint256)", "setSpenderDailyCapFor(address,uint256)",
            "addApprovedFacilitator(address)", "removeApprovedFacilitator(address)", "renounceFactory()",
            "transferCommunityOwnership(address)", "setIssuanceCap(uint256)", "approveCredit(address,uint256)",
            "queueCreditPolicy(uint8)", "cancelCreditPolicy()", "queueTierSource(address)", "proposeSP(address)",
            "cancelSP()", "emergencyRevokePaymaster()", "proposeStandby(address)", "emergencySwitchToStandby()",
            "unsetEmergencyDisabled()", "proposeSpender(address)", "removeAutoApprovedSpender(address)",
            "transferFrom(address,address,uint256)", "burn(address,uint256)"
        ];
        c = [
            C_PRIV, C_PRIV, C_PRIV, C_PRIV,
            C_ANY, C_ANY, C_ANY, C_ANY, C_ANY, C_ANY, C_ANY,
            C_SELF, C_SELF, C_SELF, C_SELF, C_SELF, C_SELF, C_SELF, C_SELF, C_SELF, C_SELF, C_SELF, C_SELF, C_SELF,
            C_SELF, C_SELF,
            C_SIG, C_SIG,
            C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN,
            C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN, C_ADMIN,
            C_ADMIN,
            C_PULL, C_PULL
        ];
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _idx(string memory base, uint256 i) internal pure returns (string memory) {
        return string.concat(base, "[", vm.toString(i), "]");
    }

    function _loadAbi() internal view returns (AbiFn[] memory out) {
        string memory json = vm.readFile(ABI_PATH);
        uint256 n;
        while (vm.keyExistsJson(json, _idx(".abi", n))) n++;
        out = new AbiFn[](n);
        uint256 m;
        for (uint256 i; i < n; i++) {
            string memory b = _idx(".abi", i);
            if (!_eq(vm.parseJsonString(json, string.concat(b, ".type")), "function")) continue;
            out[m++] = _fnAt(json, b);
        }
        assembly ("memory-safe") { mstore(out, m) }
    }

    function _fnAt(string memory json, string memory b) internal view returns (AbiFn memory f) {
        string memory inputs = string.concat(b, ".inputs");
        uint256 k;
        while (vm.keyExistsJson(json, _idx(inputs, k))) k++;
        f.types = new string[](k);
        string memory sig = string.concat(vm.parseJsonString(json, string.concat(b, ".name")), "(");
        for (uint256 j; j < k; j++) {
            f.types[j] = _inputType(json, _idx(inputs, j));
            sig = string.concat(sig, j == 0 ? "" : ",", f.types[j]);
        }
        f.sig = string.concat(sig, ")");
        string memory mut = vm.parseJsonString(json, string.concat(b, ".stateMutability"));
        f.isView = _eq(mut, "view") || _eq(mut, "pure");
    }

    function _inputType(string memory json, string memory ib) internal view returns (string memory t) {
        t = vm.parseJsonString(json, string.concat(ib, ".type"));
        if (!_eq(t, "tuple")) return t;
        string memory comps = string.concat(ib, ".components");
        t = "(";
        for (uint256 q; vm.keyExistsJson(json, _idx(comps, q)); q++) {
            t = string.concat(t, q == 0 ? "" : ",", vm.parseJsonString(json, string.concat(_idx(comps, q), ".type")));
        }
        t = string.concat(t, ")");
    }

    function _category(AbiFn memory f) internal pure returns (uint8) {
        (string[53] memory s, uint8[53] memory c) = _nonViewTable();
        for (uint256 i; i < 53; i++) if (_eq(s[i], f.sig)) return f.isView ? C_NONE : c[i];
        return f.isView ? C_VIEW : C_NONE;
    }

    // --- argument variants per ABI type ---

    function _nVariants(string memory t) internal pure returns (uint256) {
        if (_eq(t, "address")) return 5;
        if (_eq(t, "uint256")) return 5;
        if (_eq(t, "uint8")) return 4;
        if (_eq(t, "bool")) return 2;
        if (_eq(t, "bytes32")) return 3;
        if (_eq(t, "bytes")) return 3;
        if (_eq(t, INIT_TUPLE)) return 1;
        return 0;
    }

    function _tail(bytes memory e) internal pure returns (bytes memory r) {
        r = new bytes(e.length - 32);
        for (uint256 i; i < r.length; i++) r[i] = e[i + 32];
    }

    function _variant(string memory t, uint256 v, address caller) internal view returns (bool dyn, bytes memory enc) {
        if (_eq(t, "address")) {
            // spenderB has a pending (not yet due) proposal → activateSpender(spenderB) is probed
            address[5] memory a = [victim, caller, address(0), attacker, address(spenderB)];
            return (false, abi.encode(a[v]));
        }
        if (_eq(t, "uint256")) {
            uint256[5] memory u = [uint256(0), 1, 1 ether, 150 ether, type(uint256).max];
            return (false, abi.encode(u[v]));
        }
        if (_eq(t, "uint8")) {
            uint256[4] memory u8 = [uint256(0), 1, 2, 255];
            return (false, abi.encode(u8[v]));
        }
        if (_eq(t, "bool")) return (false, abi.encode(v == 1));
        if (_eq(t, "bytes32")) {
            bytes32[3] memory h = [H_LOCK, H_CREDIT, H_FRESH];
            return (false, abi.encode(h[v]));
        }
        if (_eq(t, "bytes")) {
            bytes memory b = v == 0 ? bytes("") : v == 1 ? abi.encode(victim) : abi.encodePacked(bytes32(uint256(0x11)), bytes32(uint256(0x22)), uint8(27));
            return (true, _tail(abi.encode(b)));
        }
        // INIT_TUPLE: a VALID config naming the caller as SP (re-initialisation attempt)
        xPNTsTokenV2.InitConfig memory cfg = xPNTsTokenV2.InitConfig({
            name: "Evil", symbol: "EVL", communityOwner: caller, community: caller, communityName: "E",
            communityENS: "e.eth", exchangeRate: 1 ether, superPaymaster: caller, genesisSpender: address(0),
            tierSource: address(tier)
        });
        return (true, _tail(abi.encode(cfg)));
    }

    function _combos(AbiFn memory f) internal pure returns (uint256 total) {
        total = 1;
        for (uint256 i; i < f.types.length; i++) {
            uint256 c = _nVariants(f.types[i]);
            require(c != 0, string.concat("unsupported ABI type in ", f.sig, ": ", f.types[i]));
            total *= c;
        }
    }

    function _encodeCall(AbiFn memory f, uint256 idx, address caller) internal view returns (bytes memory) {
        uint256 n = f.types.length;
        bytes memory head;
        bytes memory tail;
        bytes[] memory parts = new bytes[](n);
        bool[] memory dyn = new bool[](n);
        for (uint256 i; i < n; i++) {
            uint256 c = _nVariants(f.types[i]);
            (dyn[i], parts[i]) = _variant(f.types[i], idx % c, caller);
            idx /= c;
        }
        for (uint256 i; i < n; i++) {
            if (dyn[i]) {
                head = bytes.concat(head, abi.encode(32 * n + tail.length));
                tail = bytes.concat(tail, parts[i]);
            } else {
                head = bytes.concat(head, parts[i]);
            }
        }
        return bytes.concat(bytes4(keccak256(bytes(f.sig))), head, tail);
    }

    // --- observation ---

    struct VS {
        uint256 bal; uint256 locked; uint256 debts; uint256 reserved; uint256 usedSP; uint256 capSP;
        uint256 totUsed; uint256 totCap; uint256 renewUsed; uint256 supply; uint256 effCap; uint256 others;
    }

    function _vs(address caller) internal view returns (VS memory s) {
        s.bal = token.balanceOf(victim);
        s.locked = token.lockedOf(victim);
        s.debts = token.debts(victim);
        s.reserved = token.creditReservedOf(victim);
        (s.capSP, s.usedSP) = token.autoAllowance(victim, caller);
        (s.totCap, s.totUsed) = token.userTotal(victim);
        s.renewUsed = token.autoRenewUsed(victim);
        s.supply = token.totalSupply();
        s.effCap = token.effectiveCreditCap(victim);
        s.others = token.balanceOf(address(sp)) + token.balanceOf(address(sp2)) + token.balanceOf(attacker)
            + token.balanceOf(address(spenderA));
    }

    function _allowanceSlot(address o, address s) internal pure returns (bytes32) {
        return keccak256(abi.encode(s, keccak256(abi.encode(o, uint256(1)))));
    }

    function _victimDigest() internal view returns (bytes32) {
        (uint256 c1, uint256 u1) = token.autoAllowance(victim, address(sp));
        (uint256 c2, uint256 u2) = token.autoAllowance(victim, address(sp2));
        (uint256 c3, uint256 u3) = token.autoAllowance(victim, address(spenderA));
        (uint256 tc, uint256 tu) = token.userTotal(victim);
        (uint112 rq, uint112 ap, uint32 ep) = token.creditReq(victim);
        bytes memory a = abi.encode(token.balanceOf(victim), token.lockedOf(victim), token.debts(victim),
            token.creditReservedOf(victim), c1, u1, c2, u2, c3, u3, tc, tu);
        bytes memory b = abi.encode(rq, ap, ep, token.autoRenewUsed(victim), token.renewalMode(victim),
            token.spenderDisabled(address(sp), victim), token.spenderDisabled(address(sp2), victim),
            token.spenderDisabled(address(spenderA), victim), token.actionNonce(victim), token.nonces(victim));
        xPNTsV2Base.LockRec memory l = token.lockOf(H_LOCK, victim);
        xPNTsV2Base.CreditRes memory r = token.creditReservationOf(H_CREDIT, victim);
        bytes memory c = abi.encode(token.allowance(victim, attacker), token.allowance(victim, address(spenderA)),
            vm.load(address(token), _allowanceSlot(victim, address(sp))), l.xLocked, l.aReserved, l.locker,
            r.amount, r.locker, token.effectiveCreditCap(victim));
        return keccak256(abi.encode(a, b, c));
    }

    function _communityDigest() internal view returns (bytes32) {
        bytes memory a = abi.encode(token.communityOwner(), token.FACTORY(), token.community(),
            token.SUPERPAYMASTER_ADDRESS(), token.pendingSP(), token.pendingSPEta(), token.pendingSPByFactory(),
            token.emergencyDisabled(), token.emergencyRevokedAddress(), token.standbySP(), token.pendingStandby(),
            token.pendingStandbyEta());
        bytes memory b = abi.encode(token.exchangeRate(), token.exchangeRateUpdatedAt(), token.maxSingleTxLimit(),
            token.issuanceCap(), token.spenderDailyCapTokens(), token.creditPolicy(), token.policyEpoch(),
            token.pendingPolicy(), token.hasPendingPolicy(), token.pendingPolicyEta(), token.creditTierSource(),
            token.pendingTierSource(), token.pendingTierSourceEta());
        bytes memory c = abi.encode(token.autoApprovedSpenders(address(spenderA)), token.autoApprovedSpenders(address(spenderB)),
            token.spenderActivatesAt(address(spenderB)), token.approvedFacilitators(attacker), token.historicalSP(attacker),
            token.historicalSP(address(sp2)), token.historicalSP(SP3), token.name(), token.symbol(), token.communityName());
        return keccak256(abi.encode(a, b, c));
    }

    function _checkI6(VS memory a, VS memory b, string memory tag) internal {
        assertLe(b.bal, a.bal, string.concat(tag, ": victim balance rose"));
        uint256 burned = a.bal - b.bal;
        assertLe(burned, a.locked, string.concat(tag, ": I6 burn exceeds the escrow held"));
        assertEq(a.supply - b.supply, burned, string.concat(tag, ": I6 value moved, not burned"));
        assertEq(b.others, a.others, string.concat(tag, ": I6 transferred amount != 0"));
        if (b.debts > a.debts) {
            assertLe(b.debts - a.debts, a.reserved, string.concat(tag, ": I6(ii) new debt exceeds admitted reservations"));
        }
        if (b.reserved > a.reserved) {
            assertLe(b.debts + b.reserved, a.effCap, string.concat(tag, ": I6(i)/C-1 reservation above effectiveCreditCap"));
        }
        assertLe(b.locked, b.bal, string.concat(tag, ": I4 lockedOf > balance"));
        assertLe(b.usedSP, a.usedSP > a.capSP ? a.usedSP : a.capSP, string.concat(tag, ": A-4 per-SP used above cap"));
        assertLe(b.totUsed, a.totUsed > a.totCap ? a.totUsed : a.totCap, string.concat(tag, ": I2 total used above cap"));
        assertLe(b.renewUsed, 1, string.concat(tag, ": K exceeded"));
    }

    /// @dev One call as `caller`, isolated by a state snapshot. Returns (call succeeded, token storage
    ///      changed). The raw detector compares every written slot's value before/after.
    function _probe(AbiFn memory f, uint8 cat, address caller, bytes memory cd) internal returns (bool ok, bool changed) {
        // semantic digests only where storage writes are legitimate (self-scoped / privileged);
        // everywhere else the raw detector is strictly stronger (no slot may change at all)
        bool semantic = cat == C_PRIV || cat == C_SELF;
        VS memory pre;
        bytes32 vPre;
        bytes32 cPre;
        if (semantic) {
            pre = _vs(caller);
            vPre = _victimDigest();
            cPre = _communityDigest();
        }
        uint256 sid = vmx.snapshotState();
        vm.record();
        vm.prank(caller);
        (ok, ) = address(token).call(cd);
        (, bytes32[] memory writes) = vm.accesses(address(token));
        bytes32[] memory post = new bytes32[](writes.length);
        for (uint256 i; i < writes.length; i++) post[i] = vm.load(address(token), writes[i]);
        VS memory aft;
        bytes32 vPost;
        bytes32 cPost;
        if (semantic) {
            aft = _vs(caller);
            vPost = _victimDigest();
            cPost = _communityDigest();
        }
        vmx.revertToState(sid);
        for (uint256 i; i < writes.length; i++) {
            if (vm.load(address(token), writes[i]) != post[i]) changed = true;
        }
        string memory tag = f.sig;
        if (cat == C_PRIV) {
            _checkI6(pre, aft, tag);
            assertEq(cPost, cPre, string.concat(tag, ": privileged entry point changed community config"));
        } else if (cat == C_SELF) {
            assertEq(vPost, vPre, string.concat(tag, ": self-scoped call changed the victim's state"));
            assertEq(cPost, cPre, string.concat(tag, ": self-scoped call changed community config"));
            assertEq(aft.supply, pre.supply, string.concat(tag, ": supply changed"));
        } else {
            assertFalse(changed, string.concat(tag, ": call by the SP changed token storage"));
            if (cat == C_ADMIN || cat == C_SIG) assertFalse(ok, string.concat(tag, ": SP-callable admin/signature entry"));
        }
    }

    function probeExt(AbiFn memory f, uint8 cat, address caller, uint256 idx) external returns (bool changed) {
        require(msg.sender == address(this), "self only");
        (, changed) = _probe(f, cat, caller, _encodeCall(f, idx, caller));
    }

    /// @dev Victim + community state that makes the sweep bite: balance, an explicit approval TO the
    ///      SP (phishing), an opted-in third-party spender, AUTO credit, a LIVE escrow and a LIVE credit
    ///      reservation held by `sp`, and pending-but-not-due governance items (an unconditional
    ///      activate/execute would show up as a change).
    function _prepareVictim(bool rotate) internal {
        vm.startPrank(operator);
        IAdv(address(token)).mint(victim, 10_000 ether);
        IAdv(address(token)).proposeSpender(address(spenderA));
        IAdv(address(token)).queueCreditPolicy(2);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IAdv(address(token)).activateSpender(address(spenderA));
        IAdv(address(token)).executeCreditPolicy();
        registry.setCreditLimit(victim, 1_000 ether);
        vm.startPrank(victim);
        token.approve(address(sp), type(uint256).max);
        token.approve(attacker, 5 ether);
        IAdv(address(token)).setAutoAllowance(address(spenderA), 100 ether);
        IAdv(address(token)).requestCredit(1_000 ether);
        vm.stopPrank();
        assertEq(uint256(vm.load(address(token), _allowanceSlot(victim, address(sp)))), type(uint256).max,
            "instrument: raw allowance slot located");

        vm.startPrank(address(sp));
        (IxPNTsTokenV2.LockResult lr, ) = token.tryLockForGas(victim, H_LOCK, 200 ether, false);
        IxPNTsTokenV2.CreditResult cr = token.tryReserveCredit(victim, H_CREDIT, 100 ether);
        vm.stopPrank();
        assertEq(uint8(lr), 0, "live escrow");
        assertEq(uint8(cr), 0, "live reservation");

        if (rotate) {
            vm.prank(operator);
            IAdv(address(token)).proposeSP(address(sp2));
            vm.warp(vm.getBlockTimestamp() + 48 hours);
            IAdv(address(token)).activateSP();
            assertEq(token.SUPERPAYMASTER_ADDRESS(), address(sp2));
            assertTrue(token.historicalSP(address(sp)));
        }
        vm.startPrank(operator);
        IAdv(address(token)).queueCreditPolicy(1);
        IAdv(address(token)).proposeStandby(SP3);
        IAdv(address(token)).proposeSpender(address(spenderB));
        IAdv(address(token)).queueTierSource(address(tier2));
        IAdv(address(token)).proposeSP(rotate ? SP3 : address(sp2));
        vm.stopPrank();
    }

    function _sweep(address caller, bool isCurrent) internal {
        AbiFn[] memory fns = _loadAbi();
        (string[53] memory table, ) = _nonViewTable();
        for (uint256 i; i < 53; i++) {
            bool found;
            for (uint256 j; j < fns.length; j++) if (_eq(fns[j].sig, table[i])) found = true;
            assertTrue(found, string.concat("stale classification table entry (not in ABI): ", table[i]));
        }

        // instrument controls: the detectors must fire on a real change
        {
            uint256 sid = vmx.snapshotState();
            vm.record();
            vm.prank(victim);
            (bool okc, ) = address(token).call(abi.encodeCall(IERC20.approve, (attacker, 7 ether)));
            (, bytes32[] memory w) = vm.accesses(address(token));
            bytes32 vAfter = _victimDigest();
            vmx.revertToState(sid);
            assertTrue(okc && w.length > 0, "instrument: raw write detector sees a write");
            assertTrue(vAfter != _victimDigest(), "instrument: victim digest sees the victim's approval");
        }

        uint256[4] memory privChanged;
        uint256 probes;
        // non-privileged first, privileged last (a successful settle must not precede the others)
        for (uint256 pass; pass < 2; pass++) {
            for (uint256 i; i < fns.length; i++) {
                uint8 cat = _category(fns[i]);
                assertTrue(cat != C_NONE, string.concat("unclassified / mis-classified token function: ", fns[i].sig));
                if ((pass == 0) == (cat == C_PRIV)) continue;
                uint256 total = _combos(fns[i]);
                uint256 runs = total < MAX_COMBOS ? total : MAX_COMBOS;
                for (uint256 k; k < runs; k++) {
                    uint256 idx = total <= MAX_COMBOS ? k : (k * 7919) % total;
                    // each probe runs in its own call frame so memory does not accumulate
                    (bool s, bytes memory r) = address(this).call(abi.encodeCall(this.probeExt, (fns[i], cat, caller, idx)));
                    if (!s) assembly ("memory-safe") { revert(add(r, 32), mload(r)) }
                    bool changed = abi.decode(r, (bool));
                    probes++;
                    if (cat == C_PRIV && changed) {
                        bytes32 h = keccak256(bytes(fns[i].sig));
                        if (h == keccak256("tryLockForGas(address,bytes32,uint256,bool)")) privChanged[0]++;
                        else if (h == keccak256("settleLocked(address,bytes32,uint256)")) privChanged[1]++;
                        else if (h == keccak256("tryReserveCredit(address,bytes32,uint256)")) privChanged[2]++;
                        else privChanged[3]++;
                    }
                }
            }
        }
        console.log("functions in ABI", fns.length);
        console.log("probes", probes);
        if (isCurrent) {
            assertGt(privChanged[0], 0, "non-vacuity: current SP can lock (bound check exercised)");
            assertGt(privChanged[2], 0, "non-vacuity: current SP can reserve credit");
        } else {
            assertEq(privChanged[0], 0, "L-5: historical SP cannot lock");
            assertEq(privChanged[2], 0, "L-5: historical SP cannot reserve credit");
        }
        assertGt(privChanged[1], 0, "non-vacuity: the locker settles its own live escrow");
        assertGt(privChanged[3], 0, "non-vacuity: the locker settles its own live reservation");
    }

    /// @notice §8/§9 malicious SP (impl replaced, no UserOp): the CURRENT SP calls every function of
    ///         the combined token ABI with real argument variants. Only the four entry points change
    ///         the victim's state, and only within I6; everything else leaves victim + community state
    ///         (and, for admin/signature/pull/permissionless/view, every token storage slot) unchanged.
    function test_maliciousSP_current_calls_every_selector() public {
        _prepareVictim(false);
        _sweep(address(sp), true);
    }

    /// @notice Same sweep with a HISTORICAL SP after rotation (S-3): it keeps only the settlement
    ///         right over its own live records (L-5) and cannot lock, reserve, pull or administer.
    function test_maliciousSP_historical_calls_every_selector() public {
        _prepareVictim(true);
        _sweep(address(sp), false);
    }

    /// @notice §8 "reserve → record debt directly → settle": v2 has no recordDebt /
    ///         recordDebtWithOpHash / burnFromWithOpHash — the selectors revert on the token (fallback →
    ///         extension → no match) and write nothing; the reservation then turns into AT MOST its own
    ///         amount of debt, exactly once.
    function test_maliciousSP_reserve_then_direct_debt_then_settle() public {
        _prepareVictim(false);
        bytes32 h = keccak256("adv.debt-path");
        vm.prank(address(sp));
        assertEq(uint8(token.tryReserveCredit(victim, h, 50 ether)), 0);
        uint256 d0 = token.debts(victim);
        uint256 bal0 = token.balanceOf(victim);

        bytes[3] memory dead = [
            abi.encodeWithSignature("recordDebt(address,uint256)", victim, 1_000_000 ether),
            abi.encodeWithSignature("recordDebtWithOpHash(address,uint256,bytes32)", victim, 1_000_000 ether, h),
            abi.encodeWithSignature("burnFromWithOpHash(address,uint256,bytes32)", victim, 1_000 ether, h)
        ];
        for (uint256 i; i < 3; i++) {
            vm.record();
            vm.prank(address(sp));
            (bool ok, ) = address(token).call(dead[i]);
            (, bytes32[] memory w) = vm.accesses(address(token));
            assertFalse(ok, "3.x debt/burn selector must not exist on v2");
            assertEq(w.length, 0, "3.x selector wrote token storage");
        }
        assertEq(token.debts(victim), d0, "no direct debt");
        assertEq(token.balanceOf(victim), bal0, "no direct burn");

        vm.prank(address(sp));
        token.settleCredit(victim, h, type(uint256).max);
        assertEq(token.debts(victim) - d0, 50 ether, "settle converts at most the reserved amount");
        vm.prank(address(sp));
        vm.expectRevert(xPNTsV2Base.NoLock.selector);
        token.settleCredit(victim, h, 1);
    }

    /// @notice The ABI fixture used by the sweep is the COMPILED token: combined ABI ==
    ///         methodIdentifiers(core) ∪ methodIdentifiers(extension), and none of the deleted 3.x
    ///         selectors is present in either.
    function test_abi_fixture_matches_compiled_token_and_has_no_3x_debt_selectors() public view {
        AbiFn[] memory fns = _loadAbi();
        string[] memory core = vm.parseJsonKeys(vm.readFile(CORE_ARTIFACT), ".methodIdentifiers");
        string[] memory ext = vm.parseJsonKeys(vm.readFile(EXT_ARTIFACT), ".methodIdentifiers");
        for (uint256 i; i < core.length + ext.length; i++) {
            string memory s = i < core.length ? core[i] : ext[i - core.length];
            bool found;
            for (uint256 j; j < fns.length; j++) if (_eq(fns[j].sig, s)) found = true;
            assertTrue(found, string.concat("compiled selector missing from the ABI fixture: ", s));
        }
        for (uint256 j; j < fns.length; j++) {
            bool found;
            for (uint256 i; i < core.length; i++) if (_eq(core[i], fns[j].sig)) found = true;
            for (uint256 i; i < ext.length; i++) if (_eq(ext[i], fns[j].sig)) found = true;
            assertTrue(found, string.concat("ABI fixture function not in the compiled token: ", fns[j].sig));
            assertFalse(_eq(fns[j].sig, "recordDebt(address,uint256)"));
            assertFalse(_eq(fns[j].sig, "recordDebtWithOpHash(address,uint256,bytes32)"));
            assertFalse(_eq(fns[j].sig, "burnFromWithOpHash(address,uint256,bytes32)"));
        }
    }

    /// @notice Instrument control for the sweep's generic encoder: it produces byte-identical calldata
    ///         to the compiler for static, dynamic-bytes and dynamic-tuple signatures.
    function test_sweep_encoder_matches_abi_encode() public view {
        AbiFn[] memory fns = _loadAbi();
        address c = address(sp);
        for (uint256 j; j < fns.length; j++) {
            string memory s = fns[j].sig;
            if (_eq(s, "transferAndCall(address,uint256,bytes)")) {
                // idx: address v=1 (caller), uint v=2 (1 ether), bytes v=1 (abi.encode(victim))
                uint256 idx = 1 + 5 * (2 + 5 * 1);
                assertEq(_encodeCall(fns[j], idx, c), abi.encodeWithSignature(s, c, 1 ether, abi.encode(victim)));
            } else if (_eq(s, "executeBySig(address,uint8,bytes,uint256,bytes)")) {
                // victim, uint8 2, bytes "", uint 150 ether, bytes 65-byte blob
                uint256 idx = 0 + 5 * (2 + 4 * (0 + 3 * (3 + 5 * 2)));
                bytes memory blob = abi.encodePacked(bytes32(uint256(0x11)), bytes32(uint256(0x22)), uint8(27));
                assertEq(_encodeCall(fns[j], idx, c), abi.encodeWithSignature(s, victim, uint8(2), bytes(""), 150 ether, blob));
            } else if (_eq(s, string.concat("initialize(", INIT_TUPLE, ")"))) {
                xPNTsTokenV2.InitConfig memory cfg = xPNTsTokenV2.InitConfig({
                    name: "Evil", symbol: "EVL", communityOwner: c, community: c, communityName: "E",
                    communityENS: "e.eth", exchangeRate: 1 ether, superPaymaster: c, genesisSpender: address(0),
                    tierSource: address(tier)
                });
                assertEq(_encodeCall(fns[j], 0, c), abi.encodeCall(xPNTsTokenV2.initialize, (cfg)));
            } else if (_eq(s, "tryLockForGas(address,bytes32,uint256,bool)")) {
                uint256 idx = 0 + 5 * (2 + 3 * (3 + 5 * 1));
                assertEq(_encodeCall(fns[j], idx, c), abi.encodeCall(xPNTsTokenV2.tryLockForGas, (victim, H_FRESH, 150 ether, true)));
            }
        }
    }
}
