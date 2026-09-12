// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import { Clones } from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsV2Base } from "src/tokens/v2/xPNTsV2Base.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";
import { MockRegistryV2 } from "./xPNTsTokenV2.t.sol";

/*
 * D3 "I layer" — stateful invariant suite for xPNTs v2 (spec 03 §4 I1–I7, §9 "I 不变量").
 *
 * HOW THE HARNESS MAPS TO TRANSACTIONS (measured on forge 1.7.1, not assumed):
 *   - Without `isolate`, every fuzzer call into the handler is its own transaction: a TSTORE
 *     written in handler call N reads 0 in call N+1 and in the invariant_ check that follows.
 *     Inside ONE handler call, transient storage persists across the handler's calls into the
 *     token. So "validate → execute → postOp" is modelled as ONE handler call (`bundle`), and
 *     every record still open when a handler call returns is, from the next call on, STALE.
 *   - With `forge-config: default.isolate = true`, the handler's own inner calls become separate
 *     transactions too (a TSTORE is gone before the next inner call), which would make every
 *     in-tx settle fail. This suite therefore must NOT run isolated.
 *   The harness proves its own premise every run: `bundle` requires each in-tx settle to succeed
 *   (would fail if calls were isolated), and `staleSettle` requires a settle of an open record
 *   from an earlier call to revert NotLive (would succeed if the campaign were one transaction).
 *
 * WHAT THE HANDLER DOES
 *   Every action PREDICTS the outcome from a ghost model written from the spec (it never reads
 *   token state to decide), performs the call, and compares. An unexpected SUCCESS is charged to
 *   the invariant the violated rule protects; an unexpected REVERT (token unchanged) is a
 *   conformance breach (slot 0) and the run continues. A breach that makes the token diverge from
 *   the ghost halts the handler (later calls are no-ops, every invariant_ then reports the first
 *   breach) so a campaign never reverts on an inconsistent ghost; a breach whose effect is fully
 *   observable (A-1: a balance moved) is charged and the ghost FOLLOWS the token, so I4 keeps
 *   judging the real state. `fail_on_revert = true` makes any handler revert a harness bug that
 *   fails loudly instead of being swallowed (verified by injecting a revert).
 *
 * WINDOWS USED FOR THE BOUNDS (spec wording → harness)
 *   - I2 "since the last legitimate reset": per cell, reset by a user renewal naming that spender
 *     (renewForSelf / R2 ACT_RENEW) or by an SP-relayed renewal (spRenew) of the SP's cell; the
 *     bound is the highest cap in force at any admission in the window. "Between two user-own
 *     actions" = between two user renewals (the only actions that reset autoRenewUsed).
 *   - I6 "since the last user reset": restarted at ANY user renewal — `_renew` clears
 *     autoRenewUsed whichever spender the user names, so renewing a non-SP spender re-arms the SP's
 *     K renewal (spec-ambiguity note in the D3 report). The harness also restarts at cap changes
 *     and SP rotation, with a base that still covers reservations admitted before the restart.
 *   - I6 xPNTs burn: asserted as Σ min(x0, ceil(c·x0/a0)) (§10.2, exact) and ≤ the §4 literal
 *     Σ ceil(c·rate/1e18) + 1 wei per settle (see test_I6_literalBurnBound_offByOneWei).
 *   - I6(ii) "new debt ≤ creditReservedOf at the moment of invalidation": invalidation moments
 *     are epoch switches (policy / tier source), revoke / re-request, approval changes, SP
 *     disable, and tier moves; debt from reservations admitted before the latest one is summed.
 */

interface IExtInv {
    function setSpenderDailyCap(uint256 newCap) external;
    function proposeSpender(address s) external;
    function activateSpender(address s) external;
    function actionDigest(address user, uint8 kind, bytes calldata params, uint256 nonce, uint256 deadline)
        external view returns (bytes32);
}

/// @dev Spender implementation (whitelisted by codehash; used through EIP-1167 clones).
contract InvSpender {
    function pull(address token, address from, uint256 amt) external {
        (bool ok, bytes memory r) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), amt));
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
    }

    function burnFrom(address token, address from, uint256 amt) external {
        (bool ok, bytes memory r) = token.call(abi.encodeWithSignature("burn(address,uint256)", from, amt));
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
    }
}

/// @dev ERC-1363 receiver for `transferAndCall`.
contract Sink1363 {
    function onTransferReceived(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onTransferReceived.selector;
    }
}

contract V2InvHandler is Test {
    // ---------------------------------------------------------------------------------
    // Spec constants — mirrored from 03 §2.1 / Ext, deliberately NOT read from the token
    // ---------------------------------------------------------------------------------
    uint256 internal constant K = 1;
    uint256 internal constant SP_DEFAULT_CAP = 5_000 ether;
    uint256 internal constant SP_CAP_FLOOR = 250 ether;
    uint256 internal constant USER_TOTAL_DEFAULT = 5_000 ether;
    uint256 internal constant PROTOCOL_MAX_CAP = 50_000 ether;
    uint256 internal constant CREDIT_CEILING = 50_000 ether;
    uint256 internal constant MAX_SINGLE = 5_000 ether;
    uint256 internal constant TIMELOCK = 48 hours;

    uint256 internal constant V_CONF = 0; // slots 1..7 = I1..I7

    // coverage counters (hits[i])
    uint256 internal constant H_LOCK_OK = 0;
    uint256 internal constant H_SETTLE = 1;
    uint256 internal constant H_CREDIT_OK = 2;
    uint256 internal constant H_CREDIT_SETTLE = 3;
    uint256 internal constant H_SPRENEW_OK = 4;
    uint256 internal constant H_SPRENEW_REJ = 5;
    uint256 internal constant H_STALE_NOTLIVE = 6;
    uint256 internal constant H_STALE_RELEASE = 7;
    uint256 internal constant H_INTX_STILLLIVE = 8;
    uint256 internal constant H_RENEW_A = 9;
    uint256 internal constant H_RENEW_B = 10;
    uint256 internal constant H_PULL_AUTO = 11;
    uint256 internal constant H_PULL_EXPLICIT = 12;
    uint256 internal constant H_BURN_AUTO = 13;
    uint256 internal constant H_A1_BLOCK = 14;
    uint256 internal constant H_MINT_REPAY = 15;
    uint256 internal constant H_POLICY = 16;
    uint256 internal constant H_TIERSRC = 17;
    uint256 internal constant H_APPROVE = 18;
    uint256 internal constant H_EMERGENCY = 19;
    uint256 internal constant H_STANDBY_SWITCH = 20;
    uint256 internal constant H_ROTATE = 21;
    uint256 internal constant H_RAD = 22;
    uint256 internal constant H_RATE = 23;
    uint256 internal constant H_REPAY = 24;
    uint256 internal constant H_EXCEEDS_CAP = 25;
    uint256 internal constant H_FORBIDDEN = 26;
    uint256 internal constant H_OLD_DEBT = 27;
    uint256 internal constant H_MID_ROTATE = 28;
    uint256 internal constant H_LOCK_INSUFF = 29;
    uint256 internal constant H_TAC = 30;
    uint256 internal constant N_HITS = 31;

    // ---------------------------------------------------------------------------------
    // Environment
    // ---------------------------------------------------------------------------------
    struct Env {
        xPNTsTokenV2 token;
        address community;
        address factory;
        MockRegistryV2 reg1;
        MockRegistryV2 reg2;
        address src1;
        address src2;
        address sa;
        address sb;
        address sink;
        address sp0;
        address sp1;
        address sp2;
    }

    xPNTsTokenV2 public t;
    address public community;
    address public factory;
    MockRegistryV2 public reg1;
    MockRegistryV2 public reg2;
    address public src1;
    address public src2;
    address public SA;
    address public SB;
    address public sink;
    address[3] public users;
    uint256[3] internal pks;
    address[3] public sps;
    address[5] internal cellAddrs;

    // ---------------------------------------------------------------------------------
    // Violations / halting / coverage
    // ---------------------------------------------------------------------------------
    uint256[8] public viol;
    string[8] internal whyOf;
    string public lastWhy;
    bool public halted;
    uint256[N_HITS] public hits;

    // ---------------------------------------------------------------------------------
    // Ghost model
    // ---------------------------------------------------------------------------------
    mapping(address => uint256) public gBal;
    mapping(address => uint256) public gDebt;
    mapping(address => mapping(address => uint256)) internal gExplicit; // owner => spender

    /// @dev `used` mirrors the token counter; `open` = aPNTs of still-open lock reservations in
    ///      the cell; `consumed`/`capHW` = I2 window (since the cell's last legitimate reset);
    ///      `i6*` = I6 window (since the user's last renewal or a cap change on the cell).
    struct Cell {
        uint256 used;
        uint256 cap;
        bool set;
        uint256 open;
        uint256 consumed;
        uint256 capHW;
        uint256 i6Base;
        uint256 i6Cap;
        uint256 i6Settled;
    }
    mapping(address => mapping(address => Cell)) internal cell; // spender => user => cell
    mapping(address => Cell) internal bud;                       // user => total budget

    mapping(address => uint256) public gAutoRenewUsed;
    mapping(address => uint256) public gSpRenewsSinceUser; // counted from the TOKEN's OK answers
    mapping(address => uint8) public gMode;
    mapping(address => mapping(address => bool)) public gDisabled; // spender => user

    struct GLock { address user; bytes32 op; uint256 x; uint256 a; address locker; uint256 rate; bool open; }
    struct GRes { address user; bytes32 op; uint256 amt; address locker; uint256 invalAtAdmit; bool open; }
    GLock[] internal locks;
    GRes[] internal ress;
    mapping(bytes32 => mapping(address => uint256)) internal lockIdx; // idx+1 while open
    mapping(bytes32 => mapping(address => uint256)) internal resIdx;  // idx+1 while open
    mapping(address => uint256) public gLocked;
    mapping(address => uint256) public gReserved;

    struct Req { uint256 requested; uint256 approved; uint32 epoch; }
    mapping(address => Req) internal gReq;
    uint8 public gPolicy;
    uint32 public gEpoch;
    address public gSource;
    // I6(ii): per-user "invalidation moments" (epoch/policy/source switch, revoke, disable, tier move)
    mapping(address => uint256) internal gInval;
    mapping(address => uint256) internal resAtInval;
    mapping(address => uint256) internal oldDebtSinceInval;

    // I6 burn accounting (lock path)
    mapping(address => uint256) internal xBurned;
    mapping(address => uint256) internal xBurnFormula; // Σ min(x0, ceil(c·x0/a0)) (§10.2)
    mapping(address => uint256) internal xBurnLiteral; // Σ ceil(c·rate_i/1e18) (§4 I6 wording)
    mapping(address => uint256) internal nSettles;

    address public gCurSP;
    bool public gEmergency;
    address public gRevoked;
    address public gStandby;
    mapping(address => bool) public gHistorical;

    uint256 public gRate;
    uint256 public gRateUpdatedAt;
    uint256 internal opCounter;

    constructor(Env memory e, uint256[3] memory keys) {
        t = e.token;
        community = e.community;
        factory = e.factory;
        reg1 = e.reg1;
        reg2 = e.reg2;
        src1 = e.src1;
        src2 = e.src2;
        SA = e.sa;
        SB = e.sb;
        sink = e.sink;
        sps = [e.sp0, e.sp1, e.sp2];
        for (uint256 i; i < 3; i++) {
            pks[i] = keys[i];
            users[i] = vm.addr(keys[i]);
        }
        cellAddrs = [e.sp0, e.sp1, e.sp2, e.sa, e.sb];
        gRate = 1 ether;
        gCurSP = e.sp0;
        gHistorical[e.sp0] = true;
        gSource = e.src1;
    }

    /// @notice One-time state seeding through the same modelled paths the fuzzer uses.
    function init() external {
        _mintCore(users[0], 10_000 ether);
        _mintCore(users[1], 3_000 ether);
        _mintCore(users[2], 300 ether);
        (bool ok, ) = _call(community, abi.encodeWithSignature("setSpenderDailyCap(uint256)", uint256(type(uint128).max)));
        require(ok, "daily cap");
        require(_policyCore(POLICY_AUTO_SEED), "policy");
        reg1.setCreditLimit(users[0], 1_500 ether);
        reg1.setCreditLimit(users[1], 5_000 ether);
        reg1.setCreditLimit(users[2], 800 ether);
        _requestCore(users[0], 2_000 ether, false, false, false);
        _requestCore(users[1], 1_000 ether, false, false, false);
        _requestCore(users[2], 500 ether, false, false, false);
        _allowanceCore(users[0], SA, 1_000 ether, false, false);
        _allowanceCore(users[1], SB, 2_000 ether, false, false);
        _allowanceCore(users[2], SA, 300 ether, false, false);
        for (uint256 i; i < 3; i++) _i6RestartAllForUser(users[i]);
        require(!halted, string.concat("init: ", lastWhy));
    }

    uint256 internal constant POLICY_AUTO_SEED = 2; // p = 2 (AUTO), no cancel

    // =================================================================================
    // Helpers
    // =================================================================================

    /// @dev Safety breach (or any outcome that makes the token diverge from the ghost): charge
    ///      it to `slot` and HALT the handler — the ghost is no longer a faithful model.
    function _v(uint256 slot, string memory why) internal {
        viol[slot] += 1;
        if (bytes(whyOf[slot]).length == 0) whyOf[slot] = why;
        if (!halted) lastWhy = why;
        halted = true;
    }

    /// @dev Safety breach after which the ghost is made to FOLLOW the token (the effect is fully
    ///      observable, e.g. a balance moved): charged to `slot`, no halt, so the other
    ///      invariants (I4 solvency in particular) keep evaluating the real state.
    function _vFollow(uint256 slot, string memory why) internal {
        viol[slot] += 1;
        if (bytes(whyOf[slot]).length == 0) whyOf[slot] = why;
    }

    /// @dev Conformance breach whose failing call left the token UNCHANGED (a revert or a
    ///      typed rejection): record it, but keep running — ghost and token still agree, so the
    ///      named invariants keep watching instead of being masked by an early halt.
    function _c(string memory why) internal {
        viol[V_CONF] += 1;
        if (bytes(whyOf[V_CONF]).length == 0) whyOf[V_CONF] = why;
    }

    /// @dev Outcome vs prediction. Unexpected success → invariant `slot` (halts); unexpected
    ///      revert → conformance (slot 0, no halt). Returns true iff they agree.
    function _check(bool predicted, bool ok, uint256 slot, string memory what) internal returns (bool) {
        if (ok == predicted) return true;
        if (ok) _v(slot, string.concat("unexpected success: ", what));
        else _c(string.concat("unexpected revert: ", what));
        return false;
    }

    function _call(address from, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(from);
        (ok, ret) = address(t).call(data);
    }

    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) s = bytes4(ret);
    }

    function _now() internal view returns (uint256) { return vm.getBlockTimestamp(); }
    function _warp(uint256 dt) internal { vm.warp(_now() + dt); }
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) { return a == 0 ? 0 : (a - 1) / b + 1; }
    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
    function _user(uint256 s) internal view returns (address) { return users[s % 3]; }

    function _isUser(address a) internal view returns (bool) {
        return a == users[0] || a == users[1] || a == users[2];
    }

    function _userIndex(address u) internal view returns (uint256) {
        return u == users[0] ? 0 : u == users[1] ? 1 : 2;
    }

    /// @dev Any cell address (current SP first, then spenders, then every SP candidate).
    function _anySpender(uint256 s) internal view returns (address) {
        uint256 k = s % 6;
        if (k == 0) return gCurSP;
        if (k == 1) return SA;
        if (k == 2) return SB;
        return sps[k - 3];
    }

    function _ctlSpender(uint256 s) internal view returns (address) {
        uint256 k = s % 3;
        return k == 0 ? gCurSP : k == 1 ? SA : SB;
    }

    function _newOp() internal returns (bytes32) { return keccak256(abi.encode("inv-op", ++opCounter)); }

    function _cellCap(address s, address u) internal view returns (uint256) {
        Cell storage c = cell[s][u];
        return c.set ? c.cap : (s == gCurSP ? SP_DEFAULT_CAP : 0);
    }

    function _budCap(address u) internal view returns (uint256) {
        Cell storage b = bud[u];
        return b.set ? b.cap : USER_TOTAL_DEFAULT;
    }

    function _rem(address s, address u, uint256 usedA, uint256 usedB) internal view returns (uint256) {
        uint256 ca = _cellCap(s, u);
        uint256 cb = _budCap(u);
        uint256 r1 = ca > usedA ? ca - usedA : 0;
        uint256 r2 = cb > usedB ? cb - usedB : 0;
        return _min(r1, r2);
    }

    function _canMove(address u, uint256 amt) internal view returns (bool) {
        return amt <= gBal[u] && gBal[u] - amt >= gLocked[u];
    }

    /// @dev Raise the I2 high-water marks to the caps in force at an admission.
    function _admit(address s, address u) internal {
        Cell storage c = cell[s][u];
        uint256 ca = _cellCap(s, u);
        if (ca > c.capHW) c.capHW = ca;
        Cell storage b = bud[u];
        uint256 cb = _budCap(u);
        if (cb > b.capHW) b.capHW = cb;
    }

    /// @dev Realised consumption (settled charge or auto-allowance pull).
    function _consume(address s, address u, uint256 a) internal {
        Cell storage c = cell[s][u];
        c.consumed += a;
        c.i6Settled += a;
        Cell storage b = bud[u];
        b.consumed += a;
        b.i6Settled += a;
    }

    function _resetI2Cell(address s, address u) internal {
        Cell storage c = cell[s][u];
        c.consumed = 0;
        c.capHW = _cellCap(s, u);
    }

    function _resetI2Bud(address u) internal {
        Cell storage b = bud[u];
        b.consumed = 0;
        b.capHW = _budCap(u);
    }

    /// @dev I6 window restart. At a user renewal nothing is outstanding and the base is exactly
    ///      the spec's "remaining cap". The harness also restarts at cap changes / SP rotation;
    ///      there, reservations admitted BEFORE the restart may still settle, so the base is
    ///      max(remaining-after-consumption, still-open reservations): with no admission after
    ///      the restart only the open ones can settle; with one, the last admission bounds all.
    function _i6Base(uint256 cap, uint256 used, uint256 open) internal pure returns (uint256) {
        uint256 part = used - open;
        uint256 rem = cap > part ? cap - part : 0;
        return rem > open ? rem : open;
    }

    function _i6RestartCell(address s, address u) internal {
        Cell storage c = cell[s][u];
        uint256 cap = _cellCap(s, u);
        c.i6Cap = cap;
        c.i6Base = _i6Base(cap, c.used, c.open);
        c.i6Settled = 0;
    }

    function _i6RestartBud(address u) internal {
        Cell storage b = bud[u];
        uint256 cap = _budCap(u);
        b.i6Cap = cap;
        b.i6Base = _i6Base(cap, b.used, b.open);
        b.i6Settled = 0;
    }

    function _i6RestartAllForUser(address u) internal {
        for (uint256 i; i < 5; i++) _i6RestartCell(cellAddrs[i], u);
        _i6RestartBud(u);
    }

    function _invalidate(address u) internal {
        gInval[u] += 1;
        resAtInval[u] = gReserved[u];
        oldDebtSinceInval[u] = 0;
    }

    function _invalidateAll() internal {
        for (uint256 i; i < 3; i++) _invalidate(users[i]);
    }

    /// @notice C-0 written independently of the token (tier comes from the environment mock).
    function ghostEffCap(address u) public view returns (uint256) {
        if (gPolicy == 0) return 0;
        if (gDisabled[gCurSP][u]) return 0;
        Req memory r = gReq[u];
        if (r.epoch != gEpoch || r.requested == 0) return 0;
        uint256 cap = _min(r.requested, CREDIT_CEILING);
        MockRegistryV2 reg = gSource == src1 ? reg1 : reg2;
        cap = _min(cap, reg.creditLimit(u));
        if (gPolicy == 1) cap = _min(cap, r.approved);
        return cap;
    }

    function _reserveAmt(uint256 seed) internal pure returns (uint256) {
        uint256 k = seed % 10;
        if (k == 0) return 0;
        if (k == 1) return 1 + (seed >> 8) % 1_000;                                // wei-scale rounding
        if (k == 2) return MAX_SINGLE + 1 + (seed >> 8) % 1_000 ether;             // SINGLE_TX_LIMIT
        return 1 ether + (seed >> 8) % 2_500 ether;
    }

    function _chargeFor(uint256 seed, uint256 a) internal pure returns (uint256) {
        uint256 k = seed % 4;
        if (k == 0) return 0;
        if (k == 1) return a;
        if (k == 2) return a + 1 + (seed >> 8) % (a / 2 + 1);                     // over-charge (capped)
        return a == 0 ? 0 : (seed >> 8) % (a + 1);
    }

    function _capAmt(uint256 seed) internal pure returns (uint256) {
        uint256 k = seed % 6;
        if (k == 0) return (seed >> 8) % SP_CAP_FLOOR;                            // below the floor
        if (k == 1) return PROTOCOL_MAX_CAP + 1 + (seed >> 8) % 1_000 ether;      // above the ceiling
        return SP_CAP_FLOOR + (seed >> 8) % 12_000 ether;
    }

    function _creditAmt(uint256 seed) internal pure returns (uint256) {
        uint256 k = seed % 5;
        if (k == 0) return CREDIT_CEILING + 1 + (seed >> 8) % 1_000 ether;        // above the ceiling
        return 1 ether + (seed >> 8) % 6_000 ether;
    }

    // =================================================================================
    // Plain ERC20 movement by the user (A-1 / I1)
    // =================================================================================

    function _moveCore(address from, address to, uint256 amt, uint256 kind) internal returns (bool) {
        bool pred = _canMove(from, amt);
        bytes memory data = kind == 0
            ? abi.encodeWithSignature("transfer(address,uint256)", to, amt)
            : kind == 1
                ? abi.encodeWithSignature("transferAndCall(address,uint256)", to, amt)
                : abi.encodeWithSignature("burn(uint256)", amt);
        (bool ok, ) = _call(from, data);
        if (ok && !pred) {
            _vFollow(1, "I1: user movement beyond balance - lockedOf succeeded (A-1)");
            gBal[from] -= amt;
            if (kind != 2 && _isUser(to)) gBal[to] += amt;
            return false;
        }
        if (!_check(pred, ok, 1, "A-1: outgoing movement beyond balance - lockedOf")) return false;
        if (!ok) {
            if (amt <= gBal[from]) hits[H_A1_BLOCK]++;
            return true;
        }
        gBal[from] -= amt;
        if (kind != 2 && _isUser(to)) gBal[to] += amt;
        if (kind == 1) hits[H_TAC]++;
        return true;
    }

    function transfer(uint256 f, uint256 to, uint256 amt, bool toSink) external {
        if (halted) return;
        address from = _user(f);
        _moveCore(from, toSink ? sink : _user(to), _bound(amt, 0, gBal[from]), 0);
    }

    function transferAndCall(uint256 f, uint256 to, uint256 amt, bool toSink) external {
        if (halted) return;
        address from = _user(f);
        _moveCore(from, toSink ? sink : _user(to), _bound(amt, 0, gBal[from]), 1);
    }

    function burnSelf(uint256 f, uint256 amt) external {
        if (halted) return;
        address from = _user(f);
        _moveCore(from, address(0), _bound(amt, 0, gBal[from]), 2);
    }

    // =================================================================================
    // Mint (incl. auto-repay of debt)
    // =================================================================================

    function _mintCore(address u, uint256 amt) internal returns (bool) {
        (bool ok, ) = _call(community, abi.encodeWithSignature("mint(address,uint256)", u, amt));
        if (!_check(true, ok, 1, "mint")) return false;
        gBal[u] += amt;
        uint256 debt = gDebt[u];
        if (debt > 0 && amt > 0) {
            uint256 mintedA = amt * 1e18 / gRate;
            if (mintedA > 0) {
                uint256 repayA = mintedA > debt ? debt : mintedA;
                uint256 repayX = _ceilDiv(repayA * gRate, 1e18);
                gDebt[u] = debt - repayA;
                gBal[u] -= repayX;
                hits[H_MINT_REPAY]++;
            }
        }
        return true;
    }

    function mint(uint256 u_, uint256 amt) external {
        if (halted) return;
        _mintCore(_user(u_), _bound(amt, 0, 5_000 ether));
    }

    // =================================================================================
    // Third-party spending: transferFrom / burn(from) by a listed spender (A-2, I1, I2)
    // =================================================================================

    function _predictSpend(address u, address s, uint256 value)
        internal view returns (bool ok, bool explicitOnly, uint256 a)
    {
        if (s == gCurSP || gHistorical[s]) return (false, false, 0);
        uint256 e = gExplicit[u][s];
        if (e >= value) return (true, true, 0);
        if (gEmergency || gDisabled[s][u]) return (false, false, 0);
        a = _ceilDiv((value - e) * 1e18, gRate);
        if (a > MAX_SINGLE) return (false, false, 0);
        if (_rem(s, u, cell[s][u].used, bud[u].used) < a) return (false, false, 0);
        return (true, false, a);
    }

    function spenderPull(uint256 u_, uint256 s_, uint256 amt, uint256 ap, bool burnIt) external {
        if (halted) return;
        address u = _user(u_);
        address s = s_ % 2 == 0 ? SA : SB;
        if (ap % 3 == 0) {
            // explicit approval path (the user's own transaction)
            uint256 e = ap % 5 == 0 ? type(uint256).max : _bound(ap, 0, 3_000 ether);
            (bool okA, ) = _call(u, abi.encodeWithSignature("approve(address,uint256)", s, e));
            if (!_check(true, okA, 1, "approve")) return;
            gExplicit[u][s] = e;
        }
        amt = _bound(amt, 0, gBal[u]);
        (bool pOk, bool explicitOnly, uint256 a) = _predictSpend(u, s, amt);
        bool pred = pOk && _canMove(u, amt);
        (bool ok, ) = burnIt
            ? s.call(abi.encodeCall(InvSpender.burnFrom, (address(t), u, amt)))
            : s.call(abi.encodeCall(InvSpender.pull, (address(t), u, amt)));
        if (ok && !pred && pOk) _vFollow(1, "I1: spender moved locked balance (A-1)"); // ghost follows below
        else if (!_check(pred, ok, 2, "I2: spender pulled beyond explicit approval + bounded auto-allowance")) return;
        if (!ok) return;
        uint256 e0 = gExplicit[u][s];
        if (explicitOnly) {
            if (e0 != type(uint256).max) gExplicit[u][s] = e0 - amt;
            hits[H_PULL_EXPLICIT]++;
        } else {
            if (e0 != 0) gExplicit[u][s] = 0;
            _admit(s, u);
            cell[s][u].used += a;
            bud[u].used += a;
            _consume(s, u, a);
            hits[burnIt ? H_BURN_AUTO : H_PULL_AUTO]++;
        }
        gBal[u] -= amt;
    }

    /// @notice A-3 / A-9: a (historical) SP — even with an explicit approval — and the factory
    ///         can never move user funds.
    function forbiddenPull(uint256 u_, uint256 w, uint256 amt) external {
        if (halted) return;
        address u = _user(u_);
        uint256 k = w % 4;
        address who = k == 3 ? factory : sps[k];
        if (who != factory && !gHistorical[who]) return;
        amt = _bound(amt, 1, gBal[u] == 0 ? 1 : gBal[u]);
        if (who != factory) {
            (bool okA, ) = _call(u, abi.encodeWithSignature("approve(address,uint256)", who, type(uint256).max));
            if (!_check(true, okA, 1, "approve SP")) return;
            gExplicit[u][who] = type(uint256).max;
        }
        (bool ok1, ) = _call(who, abi.encodeWithSignature("transferFrom(address,address,uint256)", u, who, amt));
        (bool ok2, ) = _call(who, abi.encodeWithSignature("burn(address,uint256)", u, amt));
        if (ok1 || ok2) {
            _v(1, "I1: an SP / historical SP / the factory moved user funds (A-3 / A-9)");
            return;
        }
        hits[H_FORBIDDEN]++;
    }

    // =================================================================================
    // SP escrow: lock / credit reservation / settle (L-*, A-4, A-5, C-1, C-2)
    // =================================================================================

    function _predictLock(address u, bytes32 op, uint256 reserve, bool spRenew)
        internal view returns (IxPNTsTokenV2.LockResult r, uint256 xAmt, bool balShort)
    {
        address s = gCurSP;
        if (gEmergency) return (IxPNTsTokenV2.LockResult.EMERGENCY, 0, false);
        if (gDisabled[s][u]) return (IxPNTsTokenV2.LockResult.DISABLED, 0, false);
        if (reserve > MAX_SINGLE) return (IxPNTsTokenV2.LockResult.SINGLE_TX_LIMIT, 0, false);
        if (lockIdx[op][u] != 0) return (IxPNTsTokenV2.LockResult.CONFLICTING_LOCK, 0, false);
        if (spRenew && (gMode[u] != 0 || gAutoRenewUsed[u] >= K || gLocked[u] != 0 || gReserved[u] != 0)) {
            return (IxPNTsTokenV2.LockResult.INVALID_RENEWAL, 0, false);
        }
        uint256 usedA = spRenew ? 0 : cell[s][u].used;
        uint256 usedB = spRenew ? 0 : bud[u].used;
        if (_rem(s, u, usedA, usedB) < reserve) return (IxPNTsTokenV2.LockResult.INSUFFICIENT, 0, false);
        xAmt = _ceilDiv(reserve * gRate, 1e18);
        if (gBal[u] < gLocked[u] || gBal[u] - gLocked[u] < xAmt) {
            return (IxPNTsTokenV2.LockResult.INSUFFICIENT, 0, true);
        }
        return (IxPNTsTokenV2.LockResult.OK, xAmt, false);
    }

    /// @return st 0 = breach recorded (abort), 1 = OK, 2 = INSUFFICIENT, 3 = other rejection
    function _doLock(address u, bytes32 op, uint256 reserve, bool spRenew) internal returns (uint8 st) {
        (IxPNTsTokenV2.LockResult pr, uint256 px, bool balShort) = _predictLock(u, op, reserve, spRenew);
        address s = gCurSP;
        (IxPNTsTokenV2.LockResult vr, ) = t.previewLock(s, u, op, reserve, spRenew);
        vm.prank(s);
        try t.tryLockForGas(u, op, reserve, spRenew) returns (IxPNTsTokenV2.LockResult ar, uint256 ax) {
            if (spRenew && ar == IxPNTsTokenV2.LockResult.OK) gSpRenewsSinceUser[u] += 1;
            if (ar != pr) {
                if (ar == IxPNTsTokenV2.LockResult.OK) {
                    if (pr == IxPNTsTokenV2.LockResult.INVALID_RENEWAL) {
                        _v(2, "I2: SP-relayed renewal admitted with K used / outstanding lock or credit (A-5)");
                    } else if (pr == IxPNTsTokenV2.LockResult.INSUFFICIENT && !balShort) {
                        _v(2, "I2: lock admitted beyond the per-spender cap or the user total (A-4)");
                    } else if (pr == IxPNTsTokenV2.LockResult.INSUFFICIENT) {
                        _v(4, "I4: lock admitted beyond balance - lockedOf");
                    } else {
                        _v(2, "I2: lock admitted while emergency / disabled / over single-tx limit / conflicting (E-1)");
                    }
                } else {
                    _c("tryLockForGas result differs from the spec prediction");
                }
                return 0;
            }
            if (vr != ar) _c("previewLock != tryLockForGas (dryRun mirror)");
            if (ar == IxPNTsTokenV2.LockResult.INSUFFICIENT) { hits[H_LOCK_INSUFF]++; return 2; }
            if (ar == IxPNTsTokenV2.LockResult.INVALID_RENEWAL) hits[H_SPRENEW_REJ]++;
            if (ar != IxPNTsTokenV2.LockResult.OK) return 3;
            if (ax != px) { _v(6, "I6: xLocked != ceil(reserve * rate / 1e18)"); return 0; }
            if (spRenew) {
                gAutoRenewUsed[u] += 1;
                cell[s][u].used = 0;
                bud[u].used = 0;
                _resetI2Cell(s, u);
                _resetI2Bud(u);
                hits[H_SPRENEW_OK]++;
            }
            _admit(s, u);
            cell[s][u].used += reserve;
            cell[s][u].open += reserve;
            bud[u].used += reserve;
            bud[u].open += reserve;
            gLocked[u] += px;
            locks.push(GLock(u, op, px, reserve, s, gRate, true));
            lockIdx[op][u] = locks.length;
            hits[H_LOCK_OK]++;
            return 1;
        } catch {
            _c("tryLockForGas reverted (must return a typed result)");
            return 0;
        }
    }

    function _predictCredit(address u, bytes32 op, uint256 amt) internal view returns (IxPNTsTokenV2.CreditResult) {
        if (gEmergency) return IxPNTsTokenV2.CreditResult.EMERGENCY;
        if (gDisabled[gCurSP][u]) return IxPNTsTokenV2.CreditResult.DISABLED;
        if (amt > MAX_SINGLE) return IxPNTsTokenV2.CreditResult.SINGLE_TX_LIMIT;
        if (resIdx[op][u] != 0) return IxPNTsTokenV2.CreditResult.CONFLICTING;
        uint256 cap = ghostEffCap(u);
        if (cap == 0) return IxPNTsTokenV2.CreditResult.NO_CREDIT;
        if (gDebt[u] + gReserved[u] + amt > cap) return IxPNTsTokenV2.CreditResult.EXCEEDS_CAP;
        return IxPNTsTokenV2.CreditResult.OK;
    }

    /// @return st 0 = breach recorded (abort), 1 = OK, 3 = rejection
    function _doReserve(address u, bytes32 op, uint256 amt) internal returns (uint8 st) {
        IxPNTsTokenV2.CreditResult pr = _predictCredit(u, op, amt);
        uint256 gcap = ghostEffCap(u);
        // I7: evaluated JUST BEFORE the reservation, through the one canonical view
        uint256 tcap = t.effectiveCreditCap(u);
        uint256 debtB = t.debts(u);
        uint256 resB = t.creditReservedOf(u);
        address s = gCurSP;
        IxPNTsTokenV2.CreditResult vr = t.previewCredit(s, u, op, amt);
        vm.prank(s);
        try t.tryReserveCredit(u, op, amt) returns (IxPNTsTokenV2.CreditResult ar) {
            bool bad;
            if (tcap != gcap) { _v(7, "I7: effectiveCreditCap differs from the C-0 computation"); bad = true; }
            if (ar == IxPNTsTokenV2.CreditResult.OK) {
                if (debtB + resB + amt > tcap) {
                    _v(7, "I7: reservation OK although debts + reserved + amt > effectiveCreditCap (C-1)");
                    bad = true;
                }
                if (gDebt[u] + gReserved[u] + amt > gcap) {
                    _v(3, "I3: admitted reservation does not satisfy C-1 at admission");
                    bad = true;
                }
                Req memory rq = gReq[u];
                uint256 lim = _min(rq.requested, CREDIT_CEILING);
                if (rq.epoch != gEpoch || gDebt[u] + gReserved[u] + amt > lim) {
                    _v(6, "I6(i): reservation outside the current-epoch min(requestedCap, CEILING) - debts - reserved");
                    bad = true;
                }
            }
            if (bad) return 0;
            if (ar != pr) {
                if (ar == IxPNTsTokenV2.CreditResult.OK) {
                    _v(3, "I3: reservation admitted in a state that forbids new ones (OFF / no current request / revoked / disabled / emergency / conflict / limit)");
                } else {
                    _c("tryReserveCredit result differs from the spec prediction");
                }
                return 0;
            }
            if (vr != ar) _c("previewCredit != tryReserveCredit (dryRun mirror)");
            if (ar == IxPNTsTokenV2.CreditResult.EXCEEDS_CAP) hits[H_EXCEEDS_CAP]++;
            if (ar != IxPNTsTokenV2.CreditResult.OK) return 3;
            gReserved[u] += amt;
            ress.push(GRes(u, op, amt, s, gInval[u], true));
            resIdx[op][u] = ress.length;
            hits[H_CREDIT_OK]++;
            return 1;
        } catch {
            _c("tryReserveCredit reverted (must return a typed result)");
            return 0;
        }
    }

    function _settleLock(uint256 i, uint256 charge) internal returns (bool) {
        GLock storage L = locks[i];
        address u = L.user;
        uint256 c = charge > L.a ? L.a : charge;
        uint256 xb = L.a == 0 ? 0 : _ceilDiv(c * L.x, L.a);
        if (xb > L.x) xb = L.x;
        vm.prank(L.locker);
        try t.settleLocked(u, L.op, charge) returns (uint256 got) {
            if (got != xb) {
                _v(got > xb ? 6 : V_CONF, "I6: xBurned != min(x0, ceil(c * x0 / a0)) (section 10.2)");
                return false;
            }
        } catch {
            _c("settleLocked failed inside the original transaction (B-1 / E-2 / L-5)");
            return false;
        }
        L.open = false;
        lockIdx[L.op][u] = 0;
        gLocked[u] -= L.x;
        Cell storage cc = cell[L.locker][u];
        cc.used -= L.a - c; // A-4: refund lands on the ORIGINATING locker's cell
        cc.open -= L.a;
        Cell storage b = bud[u];
        b.used -= L.a - c;
        b.open -= L.a;
        _consume(L.locker, u, c);
        gBal[u] -= xb;
        xBurned[u] += xb;
        xBurnFormula[u] += xb;
        xBurnLiteral[u] += _ceilDiv(c * L.rate, 1e18);
        nSettles[u] += 1;
        hits[H_SETTLE]++;
        return true;
    }

    function _settleCredit(uint256 i, uint256 charge) internal returns (bool) {
        GRes storage R = ress[i];
        address u = R.user;
        uint256 d = charge > R.amt ? R.amt : charge;
        vm.prank(R.locker);
        try t.settleCredit(u, R.op, charge) returns (uint256 got) {
            if (got != d) {
                if (got > d) {
                    _v(3, "I3: debtAdded exceeds the admitted reservation (C-2)");
                    _v(6, "I6(ii): new debt exceeds the reservation it consumed");
                } else {
                    _v(V_CONF, "settleCredit debtAdded < min(charge, amount)");
                }
                return false;
            }
        } catch {
            _c("settleCredit failed inside the original transaction (C-3 / C-4 / E-2)");
            return false;
        }
        R.open = false;
        resIdx[R.op][u] = 0;
        gReserved[u] -= R.amt;
        gDebt[u] += d;
        if (R.invalAtAdmit < gInval[u]) {
            oldDebtSinceInval[u] += d;
            hits[H_OLD_DEBT]++;
        }
        hits[H_CREDIT_SETTLE]++;
        return true;
    }

    /// @notice One bundle = one transaction: validation of n ops (lock, INSUFFICIENT → credit per
    ///         §1, or a direct credit reservation), an execution-phase event, then postOp settles.
    function bundle(uint256 u_, uint256 nSeed, uint256 rSeed, uint256 cSeed, uint256 flags, uint256 mid) external {
        _bundle(u_, nSeed, rSeed, cSeed, flags, mid);
    }

    function bundleAgain(uint256 u_, uint256 nSeed, uint256 rSeed, uint256 cSeed, uint256 flags, uint256 mid) external {
        _bundle(u_, nSeed, rSeed, cSeed, flags, mid);
    }

    function bundleOnceMore(uint256 u_, uint256 nSeed, uint256 rSeed, uint256 cSeed, uint256 flags, uint256 mid) external {
        _bundle(u_, nSeed, rSeed, cSeed, flags, mid);
    }

    function _bundle(uint256 u_, uint256 nSeed, uint256 rSeed, uint256 cSeed, uint256 flags, uint256 mid) internal {
        if (halted) return;
        address u = _user(u_);
        uint256 n = _bound(nSeed, 1, 3);
        uint256[] memory lk = new uint256[](n);
        uint256[] memory cr = new uint256[](n);
        for (uint256 i; i < n; i++) {
            bytes32 op = _newOp();
            uint256 reserve = _reserveAmt(uint256(keccak256(abi.encode(rSeed, i))));
            bool spRenew = ((flags >> i) & 1) == 1 && (flags >> 8) % 3 == 0;
            bool directCredit = ((flags >> (4 + i)) & 1) == 1 && (flags >> 12) % 4 == 0;
            uint8 st = directCredit ? 2 : _doLock(u, op, reserve, spRenew);
            if (st == 0) return;
            if (st == 1) { lk[i] = locks.length; continue; }
            if (st == 2) {
                uint8 cs = _doReserve(u, op, reserve);
                if (cs == 0) return;
                if (cs == 1) cr[i] = ress.length;
            }
        }
        if (!_midEvent(u, mid, uint256(keccak256(abi.encode(mid, rSeed))))) return;
        for (uint256 i; i < n; i++) {
            uint256 cs = uint256(keccak256(abi.encode(cSeed, i)));
            if (lk[i] != 0 && !_settleLock(lk[i] - 1, _chargeFor(cs, locks[lk[i] - 1].a))) return;
            if (cr[i] != 0 && !_settleCredit(cr[i] - 1, _chargeFor(cs, ress[cr[i] - 1].amt))) return;
        }
        if (mid % 12 == 7 && (mid >> 4) % 2 == 0) _recoverCore(mid >> 8); // after the E-2 settles
    }

    /// @dev Something that happens between validation and postOp (the user's execution, or
    ///      governance / reputation moving in the same transaction). Settles must still succeed.
    function _midEvent(address u, uint256 kind, uint256 seed) internal returns (bool) {
        kind %= 12;
        if (kind == 1) return _moveCore(u, _user(seed), _bound(seed, 0, gBal[u]), 0);
        if (kind == 2) return _moveCore(u, address(0), _bound(seed, 0, gBal[u]), 2);
        if (kind == 3) { _setTierCore(u, seed % 2 == 0, _bound(seed >> 8, 0, 3_000 ether)); return true; }
        if (kind == 4) return _requestCore(u, 0, true, false, false);          // C-4 revoke
        if (kind == 5) return _toggleCore(u, gCurSP, true, false, false);      // E-2 disable mid-flight
        if (kind == 6) return _policyCore(seed);                               // C-3 epoch switch
        if (kind == 7) return _emergencyCore();                                // E-2 emergency
        if (kind == 8) return _rateCore(seed, true);                           // D-12 rate move
        if (kind == 9) return _renewCore(u, _ctlSpender(seed), seed % 2 == 0, false); // must be RenewBlocked
        if (kind == 10) {                                                      // L-5 rotation mid-flight
            bool okR = _rotateCore(seed);
            if (okR) hits[H_MID_ROTATE]++;
            return okR;
        }
        if (kind == 11) return _tierSourceCore(false);                         // C-5 source switch
        return true;
    }

    /// @notice A validation that is never followed by a settle (postOp reverted): the record
    ///         stays behind. Also checks, in the SAME transaction, that it cannot be released.
    function abandon(uint256 u_, uint256 rSeed, uint256 flags) external { _abandon(u_, rSeed, flags); }
    function abandonAgain(uint256 u_, uint256 rSeed, uint256 flags) external { _abandon(u_, rSeed, flags); }

    function _abandon(uint256 u_, uint256 rSeed, uint256 flags) internal {
        if (halted) return;
        address u = _user(u_);
        bytes32 op = _newOp();
        uint256 reserve = _reserveAmt(rSeed);
        bool spRenew = (flags & 1) == 1 && (flags >> 8) % 3 == 0;
        uint8 st = (flags & 16) != 0 ? 2 : _doLock(u, op, reserve, spRenew);
        if (st == 0) return;
        bool created = st == 1;
        if (st == 2) {
            uint8 cs = _doReserve(u, op, reserve);
            if (cs == 0) return;
            created = cs == 1;
        }
        if (!created) return;
        // L-4: while live, a release must revert StillLive
        (bool ok, bytes memory err) = address(t).call(
            (flags & 2) != 0
                ? abi.encodeWithSignature("releaseStaleLock(address,bytes32)", u, op)
                : abi.encodeWithSignature("releaseStaleCredit(address,bytes32)", u, op)
        );
        bool recExists = (flags & 2) != 0 ? lockIdx[op][u] != 0 : resIdx[op][u] != 0;
        if (recExists) {
            if (ok) { _v(5, "I5/L-4: a live record was released inside its original transaction"); return; }
            if (_sel(err) != xPNTsV2Base.StillLive.selector) { _c("in-tx release: expected StillLive"); return; }
            hits[H_INTX_STILLLIVE]++;
        } else if (!ok) {
            _c("release of a non-existent record must be an idempotent no-op");
            return;
        }
        // E-4: releaseAndDisable on a live record reverts as a whole (the disable included)
        if ((flags & 4) != 0) {
            address s = gCurSP;
            (ok, err) = _call(u, abi.encodeWithSignature("releaseAndDisable(address,bytes32)", s, op));
            if (ok) { _v(5, "E-4: releaseAndDisable succeeded on a live record"); return; }
            if (_sel(err) != xPNTsV2Base.StillLive.selector) { _c("in-tx releaseAndDisable: expected StillLive"); return; }
            if (t.spenderDisabled(s, u) != gDisabled[s][u]) { _v(V_CONF, "E-4: disable not rolled back"); return; }
        }
        // L-3: only the recorded locker may settle
        if ((flags & 8) != 0 && lockIdx[op][u] != 0) {
            (ok, ) = address(t).call(abi.encodeWithSignature("settleLocked(address,bytes32,uint256)", u, op, uint256(0)));
            if (ok) { _v(1, "I1: a non-locker settled (burned) a user's lock"); return; }
        }
    }

    function _findOpenLock(uint256 seed) internal view returns (bool, uint256) {
        uint256 len = locks.length;
        if (len == 0) return (false, 0);
        uint256 start = seed % len;
        for (uint256 k; k < len; k++) {
            uint256 i = (start + k) % len;
            if (locks[i].open) return (true, i);
        }
        return (false, 0);
    }

    function _findOpenRes(uint256 seed) internal view returns (bool, uint256) {
        uint256 len = ress.length;
        if (len == 0) return (false, 0);
        uint256 start = seed % len;
        for (uint256 k; k < len; k++) {
            uint256 i = (start + k) % len;
            if (ress[i].open) return (true, i);
        }
        return (false, 0);
    }

    /// @notice I5: a record whose transaction has ended can never be settled again.
    function staleSettle(uint256 idx, uint256 charge, bool credit) external { _staleSettle(idx, charge, credit); }
    function staleSettleAgain(uint256 idx, uint256 charge, bool credit) external { _staleSettle(idx, charge, credit); }

    function _staleSettle(uint256 idx, uint256 charge, bool credit) internal {
        if (halted) return;
        bytes memory err;
        if (!credit) {
            (bool found, uint256 i) = _findOpenLock(idx);
            if (!found) return;
            GLock storage L = locks[i];
            vm.prank(L.locker);
            try t.settleLocked(L.user, L.op, charge) returns (uint256) {
                _v(5, "I5: a lock was settled after its original transaction");
                return;
            } catch (bytes memory e) { err = e; }
        } else {
            (bool found, uint256 i) = _findOpenRes(idx);
            if (!found) return;
            GRes storage R = ress[i];
            vm.prank(R.locker);
            try t.settleCredit(R.user, R.op, charge) returns (uint256) {
                _v(5, "I5: a credit reservation was settled after its original transaction");
                return;
            } catch (bytes memory e) { err = e; }
        }
        if (_sel(err) != xPNTsV2Base.NotLive.selector) { _c("stale settle: expected NotLive"); return; }
        hits[H_STALE_NOTLIVE]++;
    }

    function _gReleaseLock(uint256 i) internal {
        GLock storage L = locks[i];
        L.open = false;
        lockIdx[L.op][L.user] = 0;
        gLocked[L.user] -= L.x;
        Cell storage c = cell[L.locker][L.user];
        c.used -= L.a; // L-4: full refund to the originating locker's cell
        c.open -= L.a;
        Cell storage b = bud[L.user];
        b.used -= L.a;
        b.open -= L.a;
    }

    function _gReleaseRes(uint256 i) internal {
        GRes storage R = ress[i];
        R.open = false;
        resIdx[R.op][R.user] = 0;
        gReserved[R.user] -= R.amt;
    }

    /// @notice L-4: anyone releases a stale lock / reservation; releasing nothing is a no-op.
    function releaseStale(uint256 idx, uint256 kind) external {
        if (halted) return;
        kind %= 3;
        if (kind == 2) {
            bytes32 op = keccak256(abi.encode("never-locked", idx));
            address u = _user(idx);
            (bool ok1, ) = address(t).call(abi.encodeWithSignature("releaseStaleLock(address,bytes32)", u, op));
            (bool ok2, ) = address(t).call(abi.encodeWithSignature("releaseStaleCredit(address,bytes32)", u, op));
            _check(true, ok1 && ok2, V_CONF, "idempotent release of a non-existent record");
            return;
        }
        if (kind == 0) {
            (bool found, uint256 i) = _findOpenLock(idx);
            if (!found) return;
            (bool ok, ) = address(t).call(abi.encodeWithSignature("releaseStaleLock(address,bytes32)", locks[i].user, locks[i].op));
            if (!_check(true, ok, V_CONF, "releaseStaleLock of a stale lock")) return;
            _gReleaseLock(i);
        } else {
            (bool found, uint256 i) = _findOpenRes(idx);
            if (!found) return;
            (bool ok, ) = address(t).call(abi.encodeWithSignature("releaseStaleCredit(address,bytes32)", ress[i].user, ress[i].op));
            if (!_check(true, ok, V_CONF, "releaseStaleCredit of a stale reservation")) return;
            _gReleaseRes(i);
        }
        hits[H_STALE_RELEASE]++;
    }

    /// @notice E-4 across transactions: disable, then release this opHash's stale lock AND credit.
    function releaseAndDisable(uint256 idx, uint256 sSeed, bool credit) external {
        if (halted) return;
        address u;
        bytes32 op;
        address locker;
        if (!credit) {
            (bool found, uint256 i) = _findOpenLock(idx);
            if (!found) return;
            (u, op, locker) = (locks[i].user, locks[i].op, locks[i].locker);
        } else {
            (bool found, uint256 i) = _findOpenRes(idx);
            if (!found) return;
            (u, op, locker) = (ress[i].user, ress[i].op, ress[i].locker);
        }
        uint256 k = sSeed % 3;
        address s = k == 0 ? gCurSP : k == 1 ? SA : locker;
        (bool ok, ) = _call(u, abi.encodeWithSignature("releaseAndDisable(address,bytes32)", s, op));
        if (!_check(true, ok, V_CONF, "releaseAndDisable on stale records")) return;
        _gSetDisabled(u, s, true);
        uint256 li = lockIdx[op][u];
        if (li != 0) _gReleaseLock(li - 1);
        uint256 ri = resIdx[op][u];
        if (ri != 0) _gReleaseRes(ri - 1);
        hits[H_RAD]++;
    }

    // =================================================================================
    // User settings — direct, or relayed with an R2 signature (executeBySig)
    // =================================================================================

    function _r2(address u, uint8 kind, bytes memory params, bool badSig) internal returns (bool ok) {
        uint256 deadline = _now() + 1 hours;
        uint256 nonce = t.actionNonce(u);
        bytes32 digest = IExtInv(address(t)).actionDigest(u, kind, params, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badSig ? uint256(0xBAD5EED) : pks[_userIndex(u)], digest);
        (ok, ) = address(t).call(
            abi.encodeWithSignature(
                "executeBySig(address,uint8,bytes,uint256,bytes)", u, kind, params, deadline, abi.encodePacked(r, s, v)
            )
        );
    }

    function _gRenew(address u, address s) internal {
        cell[s][u].used = 0;
        bud[u].used = 0;
        gAutoRenewUsed[u] = 0;
        gSpRenewsSinceUser[u] = 0;
        _resetI2Cell(s, u);
        _resetI2Bud(u);
        _i6RestartAllForUser(u);
    }

    function _renewCore(address u, address s, bool bySig, bool badSig) internal returns (bool) {
        bool pred = !badSig && gLocked[u] == 0 && gReserved[u] == 0;
        bool ok;
        if (bySig) ok = _r2(u, 1, abi.encode(s), badSig);
        else (ok, ) = _call(u, abi.encodeWithSignature("renewForSelf(address)", s));
        if (!_check(pred, ok, 2, bySig
            ? "I2: R2 renewal with outstanding lock/credit or a foreign signature (A-6)"
            : "I2: renewForSelf with an outstanding lock/credit (A-6)")) return false;
        if (ok) {
            _gRenew(u, s);
            hits[bySig ? H_RENEW_B : H_RENEW_A]++;
        }
        return true;
    }

    function _allowanceCore(address u, address s, uint256 cap, bool bySig, bool badSig) internal returns (bool) {
        bool pred = !badSig && cap <= PROTOCOL_MAX_CAP && !(s == gCurSP && cap < SP_CAP_FLOOR);
        bool ok;
        if (bySig) ok = _r2(u, 2, abi.encode(s, cap), badSig);
        else (ok, ) = _call(u, abi.encodeWithSignature("setAutoAllowance(address,uint256)", s, cap));
        if (!_check(pred, ok, 2, "I2: setAutoAllowance outside floor/ceiling or with a foreign signature (A-8)")) return false;
        if (ok) {
            Cell storage c = cell[s][u];
            c.set = true;
            c.cap = cap;
            _i6RestartCell(s, u);
        }
        return true;
    }

    function _totalCore(address u, uint256 cap, bool bySig, bool badSig) internal returns (bool) {
        bool pred = !badSig && cap <= PROTOCOL_MAX_CAP && cap >= SP_CAP_FLOOR;
        bool ok;
        if (bySig) ok = _r2(u, 3, abi.encode(cap), badSig);
        else (ok, ) = _call(u, abi.encodeWithSignature("setUserTotalCap(uint256)", cap));
        if (!_check(pred, ok, 2, "I2: setUserTotalCap outside floor/ceiling or with a foreign signature")) return false;
        if (ok) {
            Cell storage b = bud[u];
            b.set = true;
            b.cap = cap;
            _i6RestartBud(u);
        }
        return true;
    }

    function _modeCore(address u, uint8 mode, bool bySig, bool badSig) internal returns (bool) {
        bool pred = !badSig && mode <= 1;
        bool ok;
        if (bySig) ok = _r2(u, 4, abi.encode(mode), badSig);
        else (ok, ) = _call(u, abi.encodeWithSignature("setRenewalMode(uint8)", mode));
        if (!_check(pred, ok, 2, "I2: setRenewalMode invalid mode or a foreign signature")) return false;
        if (ok) gMode[u] = mode;
        return true;
    }

    function _gSetDisabled(address u, address s, bool on) internal {
        gDisabled[s][u] = on;
        if (s == gCurSP) _invalidate(u);
    }

    function _toggleCore(address u, address s, bool disable, bool bySig, bool badSig) internal returns (bool) {
        bool pred = !badSig;
        bool ok;
        if (bySig) ok = _r2(u, disable ? 5 : 6, abi.encode(s), badSig);
        else (ok, ) = _call(u, abi.encodeWithSignature(disable ? "disableSpenderForSelf(address)" : "enableSpenderForSelf(address)", s));
        if (!_check(pred, ok, 2, "I2: spender disable/enable with a foreign signature")) return false;
        if (ok) _gSetDisabled(u, s, disable);
        return true;
    }

    function _requestCore(address u, uint256 cap, bool revoke, bool bySig, bool badSig) internal returns (bool) {
        bool pred = !badSig && cap <= CREDIT_CEILING;
        bool ok;
        if (bySig) ok = revoke ? _r2(u, 8, "", badSig) : _r2(u, 7, abi.encode(cap), badSig);
        else if (revoke) (ok, ) = _call(u, abi.encodeWithSignature("revokeCredit()"));
        else (ok, ) = _call(u, abi.encodeWithSignature("requestCredit(uint256)", cap));
        if (!_check(pred, ok, 3, "I3: credit request above the ceiling or with a foreign signature")) return false;
        if (ok) {
            gReq[u] = Req(revoke ? 0 : cap, 0, gEpoch);
            _invalidate(u);
        }
        return true;
    }

    function renewA(uint256 u_, uint256 s_) external {
        if (halted) return;
        _renewCore(_user(u_), _anySpender(s_), false, false);
    }

    function setRenewalMode(uint256 u_, uint8 mode) external {
        if (halted) return;
        _modeCore(_user(u_), uint8(mode % 3), false, false);
    }

    function setAutoAllowance(uint256 u_, uint256 s_, uint256 capSeed) external {
        if (halted) return;
        _allowanceCore(_user(u_), _anySpender(s_), _capAmt(capSeed), false, false);
    }

    function setUserTotalCap(uint256 u_, uint256 capSeed) external {
        if (halted) return;
        _totalCore(_user(u_), _capAmt(capSeed), false, false);
    }

    function toggleSpender(uint256 u_, uint256 s_, uint256 d) external {
        if (halted) return;
        _toggleCore(_user(u_), _ctlSpender(s_), d % 3 == 0, false, false); // biased to enable (disable is sticky)
    }

    function requestCredit(uint256 u_, uint256 capSeed, bool revoke) external {
        if (halted) return;
        _requestCore(_user(u_), revoke ? 0 : _creditAmt(capSeed), revoke, false, false);
    }

    /// @notice R2 relay of every action kind (ACT_RENEW weighted), incl. foreign signatures.
    function relayed(uint256 u_, uint256 kind_, uint256 p1, uint256 p2, bool bad) external {
        if (halted) return;
        address u = _user(u_);
        bool badSig = bad && p2 % 4 == 0;
        uint256 k = kind_ % 10;
        if (k <= 2) _renewCore(u, _anySpender(p1), true, badSig);
        else if (k == 3) _allowanceCore(u, _anySpender(p1), _capAmt(p2), true, badSig);
        else if (k == 4) _totalCore(u, _capAmt(p2), true, badSig);
        else if (k == 5) _modeCore(u, uint8(p1 % 3), true, badSig);
        else if (k == 6 || k == 7) _toggleCore(u, _ctlSpender(p1), k == 6, true, badSig);
        else if (k == 8) _requestCore(u, _creditAmt(p2), false, true, badSig);
        else _requestCore(u, 0, true, true, badSig);
    }

    // =================================================================================
    // Credit governance (C-3, C-5, MANUAL approval) and reputation
    // =================================================================================

    function approveCredit(uint256 u_, uint256 cap) external {
        if (halted) return;
        address u = _user(u_);
        cap = _bound(cap, 0, 8_000 ether);
        Req storage r = gReq[u];
        bool pred = r.epoch == gEpoch && r.requested != 0;
        (bool ok, ) = _call(community, abi.encodeWithSignature("approveCredit(address,uint256)", u, cap));
        if (!_check(pred, ok, 3, "I3: approveCredit without a current-epoch request")) return;
        if (ok) {
            r.approved = _min(cap, r.requested);
            _invalidate(u);
            hits[H_APPROVE]++;
        }
    }

    function _policyCore(uint256 seed) internal returns (bool) {
        uint8 p = uint8(seed % 3);
        bool cancel = (seed >> 8) % 5 == 4;
        (bool ok, ) = _call(community, abi.encodeWithSignature("queueCreditPolicy(uint8)", p));
        if (!_check(p != gPolicy, ok, 3, "queueCreditPolicy no-op switch (section 9 epoch rule)")) return false;
        if (!ok) return true;
        if (cancel) {
            (ok, ) = _call(community, abi.encodeWithSignature("cancelCreditPolicy()"));
            return _check(true, ok, V_CONF, "cancelCreditPolicy");
        }
        (ok, ) = address(t).call(abi.encodeWithSignature("executeCreditPolicy()"));
        if (!_check(false, ok, 3, "I3: executeCreditPolicy before the 48 h timelock (C-3)")) return false;
        _warp(TIMELOCK);
        (ok, ) = address(t).call(abi.encodeWithSignature("executeCreditPolicy()"));
        if (!_check(true, ok, V_CONF, "executeCreditPolicy after the timelock")) return false;
        gPolicy = p;
        gEpoch += 1;
        _invalidateAll();
        hits[H_POLICY]++;
        return _reRequest(seed);
    }

    function switchPolicy(uint256 seed) external {
        if (halted) return;
        _policyCore(seed);
    }

    function _tierSourceCore(bool) internal returns (bool) {
        address target = gSource == src1 ? src2 : src1;
        (bool ok, ) = _call(community, abi.encodeWithSignature("queueTierSource(address)", target));
        if (!_check(true, ok, V_CONF, "queueTierSource")) return false;
        (ok, ) = address(t).call(abi.encodeWithSignature("executeTierSource()"));
        if (!_check(false, ok, 3, "I3: executeTierSource before the 48 h timelock (C-5)")) return false;
        _warp(TIMELOCK);
        (ok, ) = address(t).call(abi.encodeWithSignature("executeTierSource()"));
        if (!_check(true, ok, V_CONF, "executeTierSource after the timelock")) return false;
        gSource = target;
        gEpoch += 1;
        _invalidateAll();
        hits[H_TIERSRC]++;
        return _reRequest(uint256(keccak256(abi.encode(target, gEpoch))));
    }

    function switchTierSource() external {
        if (halted) return;
        _tierSourceCore(false);
    }

    /// @dev C-3: after an epoch switch every earlier request is void. AUTO users re-consent (the
    ///      SDK re-signs `requestCredit` at the next op); model that for most users so the credit
    ///      paths stay reachable instead of dying after the first switch.
    function _reRequest(uint256 seed) internal returns (bool) {
        for (uint256 i; i < 3; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            if (r % 4 == 0) continue;
            if (!_requestCore(users[i], 200 ether + (r >> 8) % 4_000 ether, false, false, false)) return false;
        }
        return true;
    }

    function _setTierCore(address u, bool second, uint256 v) internal {
        (second ? reg2 : reg1).setCreditLimit(u, v);
        _invalidate(u);
    }

    function setTier(uint256 u_, bool second, uint256 v) external {
        if (halted) return;
        _setTierCore(_user(u_), second, _bound(v, 0, 8_000 ether));
    }

    function repayDebt(uint256 u_, uint256 amt) external {
        if (halted) return;
        address u = _user(u_);
        amt = _bound(amt, 0, _ceilDiv(gDebt[u] * gRate, 1e18) + 2);
        bool pred;
        uint256 repaid;
        bool noop;
        if (amt == 0) { pred = true; noop = true; }
        else if (gDebt[u] == 0 || gBal[u] < amt) { pred = false; }
        else {
            repaid = amt * 1e18 / gRate;
            if (repaid == 0) { pred = true; noop = true; }
            else pred = repaid <= gDebt[u] && _canMove(u, amt);
        }
        (bool ok, ) = _call(u, abi.encodeWithSignature("repayDebt(uint256)", amt));
        if (!_check(pred, ok, 3, "I3: repayDebt outside its rules (over-repay / locked balance)")) return;
        if (ok && !noop) {
            gDebt[u] -= repaid;
            gBal[u] -= amt;
            hits[H_REPAY]++;
        }
    }

    function _rateCore(uint256 seed, bool warpFirst) internal returns (bool) {
        if (warpFirst) _warp(1 hours + 1);
        uint256 lower = gRate * 8000 / 10000;
        uint256 upper = gRate * 12000 / 10000;
        uint256 nr = _bound(seed, lower - lower / 10, upper + upper / 10);
        bool cooldown = gRateUpdatedAt != 0 && _now() < gRateUpdatedAt + 1 hours;
        bool pred = nr >= 1e14 && nr <= 1e22 && !cooldown && nr >= lower && nr <= upper;
        (bool ok, ) = _call(community, abi.encodeWithSignature("updateExchangeRate(uint256)", nr));
        if (!_check(pred, ok, V_CONF, "updateExchangeRate outside cooldown / delta / range")) return false;
        if (ok) {
            gRate = nr;
            gRateUpdatedAt = _now();
            hits[H_RATE]++;
        }
        return true;
    }

    function updateExchangeRate(uint256 seed, bool warpFirst) external {
        if (halted) return;
        _rateCore(seed, warpFirst);
    }

    // =================================================================================
    // SP address state machine (§2.5): emergency, standby, rotation
    // =================================================================================

    function _onRotate(address newSP) internal {
        gCurSP = newSP;
        gHistorical[newSP] = true;
        // default caps moved with the current SP → restart every I6 cell window
        for (uint256 i; i < 3; i++) {
            for (uint256 j; j < 5; j++) _i6RestartCell(cellAddrs[j], users[i]);
        }
    }

    function _emergencyCore() internal returns (bool) {
        (bool ok, ) = _call(community, abi.encodeWithSignature("emergencyRevokePaymaster()"));
        if (!_check(true, ok, V_CONF, "emergencyRevokePaymaster")) return false;
        if (!gEmergency) {
            gEmergency = true;
            gRevoked = gCurSP;
            hits[H_EMERGENCY]++;
        }
        return true;
    }

    /// @notice S-4; three times in four the community also recovers in the same call (S-6 to a
    ///         designated standby, else S-3 rotation, then S-7) — an unrecovered emergency is
    ///         absorbing and would starve every lock/credit path for the rest of the run.
    function emergency(uint256 seed) external {
        if (halted) return;
        if (!_emergencyCore()) return;
        if (seed % 4 != 0) _recoverCore(seed >> 2);
    }

    function _recoverCore(uint256 seed) internal returns (bool) {
        if (!gEmergency) return true;
        if (gStandby != address(0) && gStandby != gRevoked) {
            address s = gStandby;
            (bool ok, ) = _call(community, abi.encodeWithSignature("emergencySwitchToStandby()"));
            if (!_check(true, ok, V_CONF, "emergencySwitchToStandby (S-6)")) return false;
            gStandby = address(0);
            _onRotate(s);
            hits[H_STANDBY_SWITCH]++;
        } else if (gCurSP == gRevoked) {
            // pick a candidate that is neither current nor revoked
            uint256 k = seed % 3;
            if (sps[k] == gCurSP || sps[k] == gRevoked) k = (k + 1) % 3;
            if (sps[k] == gCurSP || sps[k] == gRevoked) k = (k + 1) % 3;
            if (!_rotateCore(k)) return false;
        }
        (bool ok2, ) = _call(community, abi.encodeWithSignature("unsetEmergencyDisabled()"));
        if (!_check(true, ok2, V_CONF, "unsetEmergencyDisabled after recovery (S-7)")) return false;
        gEmergency = false;
        return true;
    }

    function recover(uint256 seed) external {
        if (halted) return;
        _recoverCore(seed);
    }

    function designateStandby(uint256 seed) external {
        if (halted) return;
        address c = sps[seed % 3];
        bool pred = c != gCurSP && c != gRevoked;
        (bool ok, ) = _call(community, abi.encodeWithSignature("proposeStandby(address)", c));
        if (!_check(pred, ok, V_CONF, "proposeStandby (S-5)")) return;
        if (!ok) return;
        (ok, ) = address(t).call(abi.encodeWithSignature("activateStandbyDesignation()"));
        if (!_check(false, ok, V_CONF, "activateStandbyDesignation before 48 h")) return;
        _warp(TIMELOCK);
        (ok, ) = address(t).call(abi.encodeWithSignature("activateStandbyDesignation()"));
        if (!_check(true, ok, V_CONF, "activateStandbyDesignation")) return;
        gStandby = c;
    }

    function switchToStandby() external {
        if (halted) return;
        address s = gStandby;
        bool pred = gEmergency && s != address(0) && s != gRevoked;
        (bool ok, ) = _call(community, abi.encodeWithSignature("emergencySwitchToStandby()"));
        if (!_check(pred, ok, V_CONF, "emergencySwitchToStandby (S-6)")) return;
        if (!ok) return;
        gStandby = address(0);
        _onRotate(s);
        hits[H_STANDBY_SWITCH]++;
    }

    function unsetEmergency() external {
        if (halted) return;
        bool pred = !gEmergency || gCurSP != gRevoked;
        (bool ok, ) = _call(community, abi.encodeWithSignature("unsetEmergencyDisabled()"));
        if (!_check(pred, ok, V_CONF, "unsetEmergencyDisabled (S-7)")) return;
        if (ok) gEmergency = false;
    }

    function _rotateCore(uint256 seed) internal returns (bool) {
        address c = sps[seed % 3];
        bool pred = c != gCurSP && c != gRevoked;
        (bool ok, ) = _call(community, abi.encodeWithSignature("proposeSP(address)", c));
        if (!_check(pred, ok, V_CONF, "proposeSP (S-1)")) return false;
        if (!ok) return true;
        (ok, ) = address(t).call(abi.encodeWithSignature("activateSP()"));
        if (!_check(false, ok, V_CONF, "activateSP before the 48 h timelock (S-3)")) return false;
        _warp(TIMELOCK);
        (ok, ) = address(t).call(abi.encodeWithSignature("activateSP()"));
        if (!_check(true, ok, V_CONF, "activateSP (S-3)")) return false;
        _onRotate(c);
        hits[H_ROTATE]++;
        return true;
    }

    function rotateSP(uint256 seed) external {
        if (halted) return;
        _rotateCore(seed);
    }

    function warp(uint256 dt) external {
        if (halted) return;
        _warp(_bound(dt, 0, 3 days));
    }

    // =================================================================================
    // Invariant evaluation (view; called by the invariant_ functions)
    // =================================================================================

    function checkI1() external view returns (bool, string memory) {
        if (viol[1] != 0) return (false, whyOf[1]);
        if (halted) return (false, string.concat("handler halted by an earlier breach: ", lastWhy));
        for (uint256 i; i < 3; i++) {
            address u = users[i];
            if (t.balanceOf(u) != gBal[u]) return (false, "I1: balance moved outside the legitimate paths");
        }
                return (true, "");
    }

    function checkI2() external view returns (bool, string memory) {
        if (viol[2] != 0) return (false, whyOf[2]);
        if (halted) return (false, string.concat("handler halted by an earlier breach: ", lastWhy));
        for (uint256 i; i < 3; i++) {
            address u = users[i];
            for (uint256 j; j < 5; j++) {
                address s = cellAddrs[j];
                Cell storage c = cell[s][u];
                (uint256 tc, uint256 tu) = t.autoAllowance(u, s);
                if (tu != c.used) return (false, "I2: token used[spender][user] != ghost (A-4 refund / charge accounting)");
                if (tc != _cellCap(s, u)) return (false, "I2: token cap[spender][user] != ghost");
                if (c.consumed > c.capHW) return (false, "I2: per-(user, spender) consumption since reset > cap");
            }
            Cell storage b = bud[u];
            (uint256 bc, uint256 bu) = t.userTotal(u);
            if (bu != b.used) return (false, "I2: token user-total used != ghost");
            if (bc != _budCap(u)) return (false, "I2: token user-total cap != ghost");
            if (b.consumed > b.capHW) return (false, "I2: consumption across spenders since reset > user total");
            if (t.autoRenewUsed(u) != gAutoRenewUsed[u]) return (false, "I2: autoRenewUsed != ghost");
            if (gSpRenewsSinceUser[u] > K) return (false, "I2: more than K SP-relayed renewals between two user renewals");
        }
                return (true, "");
    }

    function checkI3() external view returns (bool, string memory) {
        if (viol[3] != 0) return (false, whyOf[3]);
        if (halted) return (false, string.concat("handler halted by an earlier breach: ", lastWhy));
        for (uint256 i; i < 3; i++) {
            address u = users[i];
            if (t.debts(u) != gDebt[u]) return (false, "I3: debts moved outside settleCredit / repay / mint auto-repay");
        }
                return (true, "");
    }

    function checkI4() external view returns (bool, string memory) {
        if (viol[4] != 0) return (false, whyOf[4]);
        if (halted) return (false, string.concat("handler halted by an earlier breach: ", lastWhy));
        uint256[3] memory sumL;
        uint256[3] memory sumR;
        for (uint256 i; i < locks.length; i++) {
            GLock storage L = locks[i];
            xPNTsV2Base.LockRec memory r = t.lockOf(L.op, L.user);
            if (L.open) {
                if (r.locker != L.locker || r.xLocked != L.x || r.aReserved != L.a) {
                    return (false, "I4: open lock record differs from ghost");
                }
            } else if (r.locker != address(0)) {
                return (false, "I4: closed lock record still present");
            }
            sumL[_userIndex(L.user)] += r.xLocked;
        }
        for (uint256 i; i < ress.length; i++) {
            GRes storage R = ress[i];
            xPNTsV2Base.CreditRes memory r = t.creditReservationOf(R.op, R.user);
            if (R.open) {
                if (r.locker != R.locker || r.amount != R.amt) return (false, "I4: open reservation differs from ghost");
            } else if (r.locker != address(0)) {
                return (false, "I4: closed reservation still present");
            }
            sumR[_userIndex(R.user)] += r.amount;
        }
        for (uint256 i; i < 3; i++) {
            address u = users[i];
            uint256 lo = t.lockedOf(u);
            if (lo != sumL[i] || lo != gLocked[u]) return (false, "I4: lockedOf != sum of open lock records");
            uint256 cr = t.creditReservedOf(u);
            if (cr != sumR[i] || cr != gReserved[u]) return (false, "I4: creditReservedOf != sum of open reservations");
            if (t.balanceOf(u) < lo) return (false, "I4: balanceOf < lockedOf");
        }
                return (true, "");
    }

    function checkI5() external view returns (bool, string memory) {
        if (viol[5] != 0) return (false, whyOf[5]);
        if (halted) return (false, string.concat("handler halted by an earlier breach: ", lastWhy));
                return (true, "");
    }

    function checkI6() external view returns (bool, string memory) {
        if (viol[6] != 0) return (false, whyOf[6]);
        if (halted) return (false, string.concat("handler halted by an earlier breach: ", lastWhy));
        for (uint256 i; i < 3; i++) {
            address u = users[i];
            for (uint256 j; j < 5; j++) {
                Cell storage c = cell[cellAddrs[j]][u];
                if (c.i6Settled > c.i6Base + K * c.i6Cap) {
                    return (false, "I6: settled > remaining spender cap + K * cap since the user's last renewal");
                }
            }
            Cell storage b = bud[u];
            if (b.i6Settled > b.i6Base + K * b.i6Cap) {
                return (false, "I6: consumed > remaining user total + K * total since the user's last renewal");
            }
            if (xBurned[u] != xBurnFormula[u]) return (false, "I6: xBurned != sum of min(x0, ceil(c*x0/a0))");
            // §4 literal bound sum(ceil(c_i*rate_i/1e18)) — the §10.2 proportional formula can exceed
            // it by <= 1 wei per settle (see test_I6_literalBurnBound_offByOneWei); slack stated here.
            if (xBurned[u] > xBurnLiteral[u] + nSettles[u]) return (false, "I6: xBurned > sum ceil(c*rate/1e18) + 1 wei/settle");
            if (oldDebtSinceInval[u] > resAtInval[u]) {
                return (false, "I6(ii): debt from pre-invalidation reservations > creditReservedOf at invalidation");
            }
        }
                return (true, "");
    }

    function checkI7() external view returns (bool, string memory) {
        if (viol[7] != 0) return (false, whyOf[7]);
        if (halted) return (false, string.concat("handler halted by an earlier breach: ", lastWhy));
        for (uint256 i; i < 3; i++) {
            address u = users[i];
            if (t.effectiveCreditCap(u) != ghostEffCap(u)) return (false, "I7: effectiveCreditCap != C-0 computation");
        }
                return (true, "");
    }

    function checkConformance() external view returns (bool, string memory) {
        if (viol[0] != 0) return (false, whyOf[0]);
        if (halted) return (false, string.concat("handler halted by an earlier breach: ", lastWhy));
        if (t.SUPERPAYMASTER_ADDRESS() != gCurSP) return (false, "S-*: current SP != ghost");
        if (t.emergencyDisabled() != gEmergency) return (false, "S-4/S-7: emergency flag != ghost");
        if (t.standbySP() != gStandby) return (false, "S-5/S-6: standby != ghost");
        for (uint256 i; i < 3; i++) {
            if (t.historicalSP(sps[i]) != gHistorical[sps[i]]) return (false, "L-5: historicalSP != ghost");
        }
        if (t.exchangeRate() != gRate) return (false, "rate != ghost");
        if (t.creditPolicy() != gPolicy || t.policyEpoch() != gEpoch) return (false, "C-3: policy/epoch != ghost");
        if (t.creditTierSource() != gSource) return (false, "C-5: tier source != ghost");
                return (true, "");
    }

    function hitsAll() external view returns (uint256[N_HITS] memory) { return hits; }
}

/**
 * @title xPNTsTokenV2InvariantTest
 * @notice I1–I7 over the handler above. Runs/depth are inline so the v2 folder stays fast;
 *         `fail_on_revert = true` is deliberate: the handler never reverts by design (every
 *         token call is try/caught or low-level), so a revert is a harness bug to surface.
 */
contract xPNTsTokenV2InvariantTest is StdInvariant, Test {
    V2InvHandler internal h;
    xPNTsFactoryV2 internal factory;

    address internal governance = address(0xA11CE);
    address internal community = address(0xC0);
    address internal sp0 = address(0x5B);
    address internal sp1 = address(0x5B2);
    address internal sp2 = address(0x5B3);

    function setUp() public {
        AOAProtocolRegistry reg = new AOAProtocolRegistry(governance);
        MockRegistryV2 r1 = new MockRegistryV2();
        MockRegistryV2 r2 = new MockRegistryV2();
        GlobalTierSource s1 = new GlobalTierSource(address(r1));
        GlobalTierSource s2 = new GlobalTierSource(address(r2));
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(reg));
        xPNTsTokenV2 impl = new xPNTsTokenV2(address(reg), address(ext));
        InvSpender spImpl = new InvSpender();
        address sa = Clones.clone(address(spImpl));
        address sb = Clones.clone(address(spImpl));

        uint8 kSP = reg.KIND_SP();
        uint8 kTier = reg.KIND_TIER_SOURCE();
        uint8 kSpender = reg.KIND_SPENDER();
        vm.startPrank(governance);
        reg.bootstrapApprove(kSP, reg.spKey(sp0));
        reg.bootstrapApprove(kSP, reg.spKey(sp1));
        reg.bootstrapApprove(kSP, reg.spKey(sp2));
        reg.bootstrapApprove(kTier, address(s1).codehash);
        reg.bootstrapApprove(kTier, address(s2).codehash);
        reg.bootstrapApprove(kSpender, address(spImpl).codehash);
        reg.seal();
        vm.stopPrank();

        factory = new xPNTsFactoryV2(sp0, address(r1), address(impl), address(s1));
        vm.prank(community);
        // A-10 ②: SA is the genesis spender (EIP-1167 clone resolved to its whitelisted impl)
        xPNTsTokenV2 t = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "comm.eth", 1 ether, sa));

        // SB: X4 path — propose, 48 h, activate
        vm.prank(community);
        IExtInv(address(t)).proposeSpender(sb);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IExtInv(address(t)).activateSpender(sb);

        V2InvHandler.Env memory e = V2InvHandler.Env({
            token: t,
            community: community,
            factory: address(factory),
            reg1: r1,
            reg2: r2,
            src1: address(s1),
            src2: address(s2),
            sa: sa,
            sb: sb,
            sink: address(new Sink1363()),
            sp0: sp0,
            sp1: sp1,
            sp2: sp2
        });
        h = new V2InvHandler(e, [uint256(0xA1), uint256(0xB2), uint256(0xC3)]);
        h.init();

        bytes4[] memory sel = new bytes4[](35);
        sel[0] = V2InvHandler.transfer.selector;
        sel[1] = V2InvHandler.transferAndCall.selector;
        sel[2] = V2InvHandler.burnSelf.selector;
        sel[3] = V2InvHandler.mint.selector;
        sel[4] = V2InvHandler.spenderPull.selector;
        sel[5] = V2InvHandler.forbiddenPull.selector;
        sel[6] = V2InvHandler.bundle.selector;
        sel[7] = V2InvHandler.abandon.selector;
        sel[8] = V2InvHandler.staleSettle.selector;
        sel[9] = V2InvHandler.releaseStale.selector;
        sel[10] = V2InvHandler.releaseAndDisable.selector;
        sel[11] = V2InvHandler.renewA.selector;
        sel[12] = V2InvHandler.relayed.selector;
        sel[13] = V2InvHandler.setRenewalMode.selector;
        sel[14] = V2InvHandler.setAutoAllowance.selector;
        sel[15] = V2InvHandler.setUserTotalCap.selector;
        sel[16] = V2InvHandler.toggleSpender.selector;
        sel[17] = V2InvHandler.requestCredit.selector;
        sel[18] = V2InvHandler.approveCredit.selector;
        sel[19] = V2InvHandler.switchPolicy.selector;
        sel[20] = V2InvHandler.switchTierSource.selector;
        sel[21] = V2InvHandler.setTier.selector;
        sel[22] = V2InvHandler.repayDebt.selector;
        sel[23] = V2InvHandler.updateExchangeRate.selector;
        sel[24] = V2InvHandler.emergency.selector;
        sel[34] = V2InvHandler.recover.selector;
        sel[25] = V2InvHandler.designateStandby.selector;
        sel[26] = V2InvHandler.switchToStandby.selector;
        sel[27] = V2InvHandler.unsetEmergency.selector;
        sel[28] = V2InvHandler.rotateSP.selector;
        sel[29] = V2InvHandler.warp.selector;
        // `bundle` / `abandon` / `staleSettle` carry the escrow logic: aliases weight them up
        sel[30] = V2InvHandler.bundleAgain.selector;
        sel[31] = V2InvHandler.bundleOnceMore.selector;
        sel[32] = V2InvHandler.abandonAgain.selector;
        sel[33] = V2InvHandler.staleSettleAgain.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
        targetContract(address(h));
    }

    function _assert(bool ok, string memory why) internal pure {
        if (!ok) revert(why);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I1_balanceMovesOnlyOnLegitimatePaths() public view {
        (bool ok, string memory why) = h.checkI1();
        _assert(ok, why);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I2_autoAllowanceBoundsAndK() public view {
        (bool ok, string memory why) = h.checkI2();
        _assert(ok, why);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I3_debtOnlyFromAdmittedReservations() public view {
        (bool ok, string memory why) = h.checkI3();
        _assert(ok, why);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I4_escrowSumsAndSolvencyAtTxEnd() public view {
        (bool ok, string memory why) = h.checkI4();
        _assert(ok, why);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I5_staleRecordsOnlyReleasable() public view {
        (bool ok, string memory why) = h.checkI5();
        _assert(ok, why);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I6_maliciousSPTokenSideBound() public view {
        (bool ok, string memory why) = h.checkI6();
        _assert(ok, why);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_I7_effectiveCreditCapIsTheOnlySource() public view {
        (bool ok, string memory why) = h.checkI7();
        _assert(ok, why);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conformance_specPredictionsAndStateMachine() public view {
        (bool ok, string memory why) = h.checkConformance();
        _assert(ok, why);
    }

    /// @notice Documents a §4-vs-§10.2 wording gap found by I6: §4 bounds the xPNTs burned by
    ///         Σ ceil(aCharge·rate/1e18), but settleLocked burns min(x0, ceil(c·x0/a0)) with
    ///         x0 = ceil(a0·rate/1e18) (§10.2), which can exceed the literal bound by 1 wei per settle.
    function test_I6_literalBurnBound_offByOneWei() public {
        address comm2 = address(0xC2);
        address u = address(0xB0B);
        bytes32 op = keccak256("rounding");
        vm.prank(comm2);
        xPNTsTokenV2 t2 = xPNTsTokenV2(factory.deployxPNTsToken("C2", "x2", "C2", "c2.eth", 0.15 ether, address(0)));
        vm.prank(comm2);
        (bool ok, ) = address(t2).call(abi.encodeWithSignature("mint(address,uint256)", u, 1 ether));
        assertTrue(ok);
        vm.prank(sp0);
        (IxPNTsTokenV2.LockResult r, uint256 x0) = t2.tryLockForGas(u, op, 10, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.OK));
        assertEq(x0, 2, "x0 = ceil(10 * 0.15) = 2 wei");
        vm.prank(sp0);
        uint256 burned = t2.settleLocked(u, op, 6);
        assertEq(burned, 2, "section 10.2: min(x0, ceil(6 * 2 / 10)) = 2 wei");
        uint256 charge = 6;
        uint256 rate = 0.15 ether;
        assertEq((charge * rate + 1e18 - 1) / 1e18, 1, "section 4 I6 literal: ceil(6 * 0.15) = 1 wei");
    }

    /// @dev Per-run coverage dump (INV_V2_STATS=true) — evidence that the paths the invariants
    ///      depend on are actually reached, not just that nothing failed.
    function afterInvariant() public {
        if (!vm.envOr("INV_V2_STATS", false)) return;
        uint256[31] memory hs = h.hitsAll();
        string memory line = "HITS";
        for (uint256 i; i < 31; i++) line = string.concat(line, " ", vm.toString(hs[i]));
        vm.writeLine(vm.envString("INV_V2_STATS_FILE"), line);
    }
}
