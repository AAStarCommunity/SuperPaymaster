// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { Clones } from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { HalmosBase } from "./HalmosSVM.sol";
import { XPNTsV2Selectors } from "./XPNTsV2Selectors.sol";

/// @dev Typed view of the two SP entry points used for priming (enum results as uint8).
interface IxPNTsLock {
    function tryLockForGas(address user, bytes32 opHash, uint256 reserveAPNTs, bool spRenew)
        external returns (uint8, uint256);
    function tryReserveCredit(address user, bytes32 opHash, uint256 aPNTs) external returns (uint8);
}

/// @dev Minimal role source for the real-factory base case (every caller holds every role).
contract MockRegistryV2Lite {
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
    function getCreditLimit(address) external pure returns (uint256) { return 0; }
}

/// @dev Credit tier source whose answer is a symbolic storage value (every tier is possible).
contract SymTierSource {
    mapping(address => uint256) public t;

    function tierOf(address, address user) external view returns (uint256) {
        return t[user];
    }
}

/**
 * @title D5c-1 xPNTs v2 harness — shared set-up and the single symbolic step.
 * @dev   ONE STEP = (optional in-transaction priming by the current SP) + ONE arbitrary call.
 *
 *        Pre-state: every storage slot of the token clone, the protocol registry and the tier
 *        source is symbolic (`enableSymbolicStorage`). Only code and immutables are concrete
 *        (EIP-1167 clone -> xPNTsTokenV2 core -> fallback DELEGATECALL -> xPNTsTokenV2Ext, exactly
 *        the production routing). Well-formedness assumptions (each a reachable-state fact; listed
 *        with their justification in D5c-1-halmos.md §2.2):
 *          W1 the clone is initialised (the factory initialises it in the creating transaction);
 *          W2 exchangeRate != 0 (initialize writes > 0, updateExchangeRate rejects 0);
 *          W3 ERC20 conservation on the accounts the call can touch (victim, sender, first two ABI
 *             words as addresses): each balance <= totalSupply and every distinct pair's sum
 *             <= totalSupply (OZ's unchecked burn / receiver credit would wrap otherwise; such
 *             states are unreachable) — see _w3;
 *          W4 (credit-primed steps only) creditTierSource == the symbolic tier source (its answer
 *             is unconstrained, which includes the fail-closed 0 of a reverting/malformed source).
 *
 *        Transient storage: Halmos starts every test transaction with EMPTY transient storage, so
 *        without help no record would be "live" and every in-transaction settle path would be
 *        unreachable (a vacuous green). The harness therefore lets the CURRENT SP first run
 *        `tryLockForGas(v, h, ·)` (lock-primed checks) or `tryReserveCredit(v, h, ·)` (credit-primed
 *        checks) in the same transaction, with `h` = the opHash argument of the arbitrary call, and
 *        keeps only the priming paths that SUCCEED (a failed priming writes nothing — L-1 — so it
 *        is the un-primed case, which is explored separately). Priming is explored only when the
 *        arbitrary call is the matching settle function (see the comment in _step). The "before"
 *        snapshot is taken AFTER priming, so every assertion is about the arbitrary call alone.
 *
 *        Calldata: `svm.createCalldata(<ABI>)` over the CORE ABI (xPNTsTokenV2) or the EXTENSION
 *        ABI (xPNTsTokenV2Ext); both are sent to the clone, so extension selectors go through the
 *        real fallback DELEGATECALL. createCalldata also yields the empty calldata and a
 *        symbolic-selector 1024-byte input distinct from every selector of the named ABI (for the
 *        core ABI this reaches the extension's dispatcher with arbitrary bytes). View/pure
 *        functions are excluded (compiled without SSTORE).
 *
 *        Performance design: the snapshot reads raw storage with vm.load and every predicate is
 *        evaluated BRANCH-FREE (bitwise on 0/1 words, unchecked arithmetic guarded by the
 *        predicate itself); all predicates of one check are folded into a bitmask `bad` and a
 *        single `assert(bad == 0)`. Bit i set = predicate i violated (named in the check's NatSpec;
 *        `D5C1_BAD` is also emitted for the counterexample trace). The storage-slot formulas are
 *        cross-checked against the public getters in D5c1ReplayTest.test_D5c1_layout_*.
 *
 *        `check_*` functions are run by Halmos only; forge ignores them.
 */
abstract contract XPNTsV2HalmosBase is Test, HalmosBase {
    // --- xPNTsV2Base storage layout (out/xPNTsTokenV2.sol/xPNTsTokenV2.json storageLayout) ---
    uint256 internal constant S_BAL = 0;        // _balances
    uint256 internal constant S_ALLOW = 1;      // _allowances
    uint256 internal constant S_SUPPLY = 2;     // _totalSupply
    uint256 internal constant S_RATE = 15;      // exchangeRate
    uint256 internal constant S_MAXTX = 17;     // maxSingleTxLimit
    uint256 internal constant S_SP = 19;        // SUPERPAYMASTER_ADDRESS
    uint256 internal constant S_HIST = 24;      // historicalSP
    uint256 internal constant S_AUTO = 31;      // _auto[spender][user] : Allow {u128 used; u120 cap; bool set}
    uint256 internal constant S_BUDGET = 32;    // _budget[user]
    uint256 internal constant S_RENEW = 33;     // autoRenewUsed (uint8)
    uint256 internal constant S_LOCKED = 36;    // lockedOf
    uint256 internal constant S_LOCKS = 37;     // _locks[opHash][user] : {u128 xLocked; u128 aReserved} | {address locker}
    uint256 internal constant S_DEBTS = 38;     // debts
    uint256 internal constant S_CREQ = 39;      // creditReq : {u112 requestedCap; u112 approvedCap; u32 epoch}
    uint256 internal constant S_RESERVED = 40;  // creditReservedOf
    uint256 internal constant S_CRES = 41;      // _creditRes[opHash][user] : {u128 amount} | {address locker}
    uint256 internal constant S_POLICY = 42;    // creditPolicy (u8 @0) | policyEpoch (u32 @1)
    uint256 internal constant S_TIER = 43;      // creditTierSource
    bytes32 internal constant INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    uint256 internal constant K = 1;
    uint256 internal constant RATE_MIN = 1e14;          // xPNTsV2Base._RATE_MIN (3c28ec21)
    uint256 internal constant RATE_MAX = 1e22;          // xPNTsV2Base._RATE_MAX
    uint256 internal constant MAXTX_CAP = 50_000 ether; // xPNTsTokenV2Ext.MAX_SINGLE_TX_LIMIT_CAP
    uint256 internal constant CEILING = 50_000 ether;
    uint256 internal constant SP_DEFAULT_CAP = 5_000 ether;
    uint256 internal constant USER_TOTAL_DEFAULT = 5_000 ether;

    uint256 internal constant M128 = type(uint128).max;
    uint256 internal constant M120 = type(uint120).max;
    uint256 internal constant M112 = type(uint112).max;
    uint256 internal constant M160 = type(uint160).max;

    bytes4 internal constant SEL_BURN_FROM = bytes4(keccak256("burn(address,uint256)"));

    AOAProtocolRegistry internal reg;
    xPNTsTokenV2Ext internal ext;
    xPNTsTokenV2 internal impl;
    xPNTsTokenV2 internal tok;
    SymTierSource internal tier;

    function setUp() public {
        reg = new AOAProtocolRegistry(address(0xA11CE));
        ext = new xPNTsTokenV2Ext(address(reg));
        impl = new xPNTsTokenV2(address(reg), address(ext));
        tok = xPNTsTokenV2(Clones.clone(address(impl)));
        tier = new SymTierSource();
    }

    // ------------------------------------------------------------------ raw storage

    function _ld(bytes32 slot) internal view returns (uint256) {
        return uint256(vm.load(address(tok), slot));
    }

    function _m1(address k, uint256 base) internal pure returns (bytes32) {
        return keccak256(abi.encode(k, base));
    }

    /// mapping(k1 => mapping(k2 => T)) at `base`
    function _m2(address k1, address k2, uint256 base) internal pure returns (bytes32) {
        return keccak256(abi.encode(k2, keccak256(abi.encode(k1, base))));
    }

    function _mh(bytes32 h, address u, uint256 base) internal pure returns (bytes32) {
        return keccak256(abi.encode(u, keccak256(abi.encode(h, base))));
    }

    // ------------------------------------------------------------------ branch-free helpers

    function _u(bool x) internal pure returns (uint256 r) {
        assembly { r := x }
    }

    /// x < y ? x : y without a JUMPI
    function _minBF(uint256 x, uint256 y) internal pure returns (uint256 r) {
        assembly {
            let m := sub(0, lt(x, y))
            r := or(and(x, m), and(y, not(m)))
        }
    }

    /// cond(0/1) ? x : y without a JUMPI
    function _sel01(uint256 cond, uint256 x, uint256 y) internal pure returns (uint256 r) {
        assembly {
            let m := sub(0, cond)
            r := or(and(x, m), and(y, not(m)))
        }
    }

    /// (p -> q) as 0/1
    function _imp(uint256 p, uint256 q) internal pure returns (uint256) {
        return (p ^ 1) | q;
    }

    // ------------------------------------------------------------------ snapshots

    struct S {
        uint256 bal;         // balanceOf(v)
        uint256 supply;
        uint256 locked;      // lockedOf(v)
        uint256 debt;        // debts(v)
        uint256 reserved;    // creditReservedOf(v)
        uint256 usedA;       // _auto[e][v].used
        uint256 capA;        // effective per-(e, v) cap (set ? cap : default(e))
        uint256 usedB;       // _budget[v].used
        uint256 capB;        // effective total cap
        uint256 renewUsed;   // autoRenewUsed(v)
        address sp;          // SUPERPAYMASTER_ADDRESS
        uint256 policy;
        uint256 epoch;
        uint256 reqCap;
        uint256 reqEpoch;
        uint256 lkX0;        // _locks[h][v]
        uint256 lkA0;
        address lkLocker;
        uint256 crAmount;    // _creditRes[h][v]
        address crLocker;
        uint256 explicitAllow; // raw ERC20 _allowances[v][sender]
    }

    struct Ctx {
        address v;       // victim / tracked user
        address e;       // tracked spender cell
        address sender;
        bytes32 h;       // opHash argument of the call (free symbol when the selector has none)
        bytes4 sel;
        bool ok;
        address userArg; // first ABI word as an address (user / from) where applicable
        uint256 w1;      // raw ABI words 1..3 of the arguments
        uint256 w2;
        uint256 w3;
    }

    function _word(bytes memory data, uint256 i) internal pure returns (uint256 w) {
        if (data.length < 4 + 32 * (i + 1)) return 0;
        assembly { w := mload(add(add(data, 36), mul(i, 32))) }
    }

    function _snap(Ctx memory c) internal view returns (S memory s) {
        s.bal = _ld(_m1(c.v, S_BAL));
        s.supply = _ld(bytes32(S_SUPPLY));
        s.locked = _ld(_m1(c.v, S_LOCKED));
        s.debt = _ld(_m1(c.v, S_DEBTS));
        s.reserved = _ld(_m1(c.v, S_RESERVED));
        s.sp = address(uint160(_ld(bytes32(S_SP))));
        uint256 wa = _ld(_m2(c.e, c.v, S_AUTO));
        uint256 wb = _ld(_m1(c.v, S_BUDGET));
        s.usedA = wa & M128;
        s.usedB = wb & M128;
        uint256 dflt = _sel01(_u(c.e == s.sp), SP_DEFAULT_CAP, 0);
        s.capA = _sel01(_u(((wa >> 248) & 0xff) != 0), (wa >> 128) & M120, dflt);
        s.capB = _sel01(_u(((wb >> 248) & 0xff) != 0), (wb >> 128) & M120, USER_TOTAL_DEFAULT);
        s.renewUsed = _ld(_m1(c.v, S_RENEW)) & 0xff;
        uint256 wp = _ld(bytes32(S_POLICY));
        s.policy = wp & 0xff;
        s.epoch = (wp >> 8) & 0xffffffff;
        uint256 wr = _ld(_m1(c.v, S_CREQ));
        s.reqCap = wr & M112;
        s.reqEpoch = (wr >> 224) & 0xffffffff;
        bytes32 lk = _mh(c.h, c.v, S_LOCKS);
        uint256 w0 = _ld(lk);
        s.lkX0 = w0 & M128;
        s.lkA0 = w0 >> 128;
        unchecked { s.lkLocker = address(uint160(_ld(bytes32(uint256(lk) + 1)))); }
        bytes32 cr = _mh(c.h, c.v, S_CRES);
        s.crAmount = _ld(cr) & M128;
        unchecked { s.crLocker = address(uint160(_ld(bytes32(uint256(cr) + 1)))); }
        s.explicitAllow = _ld(_m2(c.v, c.sender, S_ALLOW));
    }

    // ------------------------------------------------------------------ the step

    uint256 internal constant PRIME_NONE = 0;
    uint256 internal constant PRIME_LOCK = 1;
    uint256 internal constant PRIME_CREDIT = 2;

    /// @param extAbi   false: calldata over the CORE ABI; true: over the EXTENSION ABI
    /// @param spSender true: sender ∈ {current SP} ∪ historicalSP (A-3 threat model); else arbitrary
    /// @param prime    PRIME_LOCK / PRIME_CREDIT: optional successful in-tx priming of (v, h)
    /// @param useJ     impose the I6-J induction hypothesis (bound jB) on the call's pre-state
    function _step(bool extAbi, bool spSender, uint256 prime, bool useJ, uint256 jB)
        internal returns (S memory a, S memory b, Ctx memory c)
    {
        svm.enableSymbolicStorage(address(tok));
        svm.enableSymbolicStorage(address(reg));
        svm.enableSymbolicStorage(address(tier));

        c.v = svm.createAddress("victim");
        c.e = svm.createAddress("spenderCell");
        c.sender = svm.createAddress("sender");
        bytes memory data = extAbi
            ? svm.createCalldata("xPNTsTokenV2Ext")
            : svm.createCalldata("xPNTsTokenV2");
        c.sel = _sel(data);
        c.userArg = address(uint160(_word(data, 0)));
        c.w1 = _word(data, 1);
        c.w2 = _word(data, 2);
        c.w3 = _word(data, 3);
        // every selector whose opHash is argument #1: settleLocked/releaseStaleLock/settleCredit/
        // releaseStaleCredit/tryLockForGas/tryReserveCredit (user, opHash, ...) and
        // releaseAndDisable (spender, opHash); for all others h is a free symbol.
        c.h = svm.createBytes32("hFree");
        if (c.sel == xPNTsTokenV2.settleLocked.selector || c.sel == xPNTsTokenV2.releaseStaleLock.selector
            || c.sel == xPNTsTokenV2.settleCredit.selector || c.sel == xPNTsTokenV2.releaseStaleCredit.selector
            || c.sel == xPNTsTokenV2.tryLockForGas.selector || c.sel == xPNTsTokenV2.tryReserveCredit.selector
            || c.sel == xPNTsTokenV2Ext.releaseAndDisable.selector) {
            c.h = bytes32(c.w1);
        }
        _selectorFilter(c.sel);
        _partition(c.sel, data.length);

        // ---- well-formedness W1-W3 (branch-free predicates)
        vm.assume(uint64(_ld(INIT_SLOT)) != 0);
        vm.assume(_ld(bytes32(S_RATE)) != 0);
        _w3(c);
        _extraAssumptions(c);

        // ---- optional successful in-transaction priming by the current SP.
        // Only the settle functions can SUCCEED on a live record (settleLocked / settleCredit
        // require live == 1; the release paths revert StillLive on a live record, i.e. change
        // nothing), and no other function reads transient storage. So priming is explored only when
        // the arbitrary call is the matching settle function: for every other selector the primed
        // storage is just one more instance of the symbolic pre-state, and liveness is unobservable.
        address sp0 = address(uint160(_ld(bytes32(S_SP))));
        if (prime == PRIME_CREDIT) {
            vm.assume(address(uint160(_ld(bytes32(S_TIER)))) == address(tier)); // W4
        }
        if (prime == PRIME_LOCK && c.sel == xPNTsTokenV2.settleLocked.selector && svm.createBool("primeLock")) {
            _primeLock(c, sp0);
        }
        if (prime == PRIME_CREDIT && c.sel == xPNTsTokenV2.settleCredit.selector && svm.createBool("primeCredit")) {
            _primeCredit(c, sp0);
        }

        if (spSender) {
            uint256 isSp = _u(c.sender == sp0) | _u((_ld(_m1(c.sender, S_HIST)) & 0xff) != 0);
            vm.assume(isSp == 1);
        }

        a = _snap(c);
        if (useJ) {
            vm.assume(a.reqCap <= jB);
            vm.assume(a.debt <= jB);
            unchecked { vm.assume(a.reserved <= jB - a.debt); }
        }
        vm.prank(c.sender);
        (c.ok, ) = address(tok).call(data);
        b = _snap(c);
    }

    // ------------------------------------------------------------------ priming (see _step)
    //
    // Goal: the ARBITRARY symbolic pre-state plus exactly one live transient marker for (v, h).
    // Only the token itself can TSTORE its marker, so the current SP runs one real tryLockForGas /
    // tryReserveCredit. To keep that call to a single path, every slot it reads or writes is first
    // saved, overwritten with a fixed admissible configuration, the call is made (it must return OK),
    // and then EVERY saved slot is restored to its original symbolic value. Net effect on storage:
    // none; net effect on transient storage: the (v, h) marker is set. The record, lockedOf, the
    // counters, the balance... are therefore as arbitrary as in the un-primed case (strictly more
    // general than keeping the values the priming call wrote).

    function _swap(address target, bytes32[] memory slots, uint256[] memory vals)
        internal returns (uint256[] memory old)
    {
        old = new uint256[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            old[i] = uint256(vm.load(target, slots[i]));
            vm.store(target, slots[i], bytes32(vals[i]));
        }
    }

    function _restore(address target, bytes32[] memory slots, uint256[] memory old) internal {
        for (uint256 i = 0; i < slots.length; i++) vm.store(target, slots[i], bytes32(old[i]));
    }

    function _primeLock(Ctx memory c, address sp0) internal {
        vm.assume(sp0 != address(0));
        bytes32 rec = _mh(c.h, c.v, S_LOCKS);
        bytes32[] memory sl = new bytes32[](11);
        uint256[] memory va = new uint256[](11);
        unchecked {
            (sl[0], va[0]) = (bytes32(uint256(20)), 0);                 // emergencyDisabled & co
            (sl[1], va[1]) = (_m2(sp0, c.v, 35), 0);                      // spenderDisabled[sp0][v]
            (sl[2], va[2]) = (bytes32(S_MAXTX), 5_000 ether);
            (sl[3], va[3]) = (rec, 0);
            (sl[4], va[4]) = (bytes32(uint256(rec) + 1), 0);             // record.locker
            (sl[5], va[5]) = (_m1(c.v, S_LOCKED), 0);
            (sl[6], va[6]) = (_m2(sp0, c.v, S_AUTO), 0);
            (sl[7], va[7]) = (_m1(c.v, S_BUDGET), 0);
            (sl[8], va[8]) = (bytes32(S_RATE), 1 ether);
            (sl[9], va[9]) = (_m1(c.v, S_BAL), 1e22);
            (sl[10], va[10]) = (bytes32(S_SUPPLY), 1e22);
        }
        uint256[] memory old = _swap(address(tok), sl, va);
        vm.prank(sp0);
        (uint8 r, ) = IxPNTsLock(address(tok)).tryLockForGas(c.v, c.h, 1 ether, false);
        vm.assume(r == 0); // OK (the fixed configuration admits it; asserted by the replay test)
        _restore(address(tok), sl, old);
    }

    function _primeCredit(Ctx memory c, address sp0) internal {
        vm.assume(sp0 != address(0));
        bytes32 rec = _mh(c.h, c.v, S_CRES);
        bytes32[] memory sl = new bytes32[](11);
        uint256[] memory va = new uint256[](11);
        unchecked {
            (sl[0], va[0]) = (bytes32(uint256(20)), 0);
            (sl[1], va[1]) = (_m2(sp0, c.v, 35), 0);
            (sl[2], va[2]) = (bytes32(S_MAXTX), 5_000 ether);
            (sl[3], va[3]) = (rec, 0);
            (sl[4], va[4]) = (bytes32(uint256(rec) + 1), 0);
            (sl[5], va[5]) = (bytes32(S_POLICY), 2 | (uint256(1) << 8)); // AUTO, epoch 1
            (sl[6], va[6]) = (_m1(c.v, S_CREQ), 1 ether | (uint256(1) << 224)); // requested 1e18 @ epoch 1
            (sl[7], va[7]) = (bytes32(S_TIER), uint256(uint160(address(tier))));
            (sl[8], va[8]) = (_m1(c.v, S_DEBTS), 0);
            (sl[9], va[9]) = (_m1(c.v, S_RESERVED), 0);
            (sl[10], va[10]) = (bytes32(S_SP), uint256(uint160(sp0)));
        }
        uint256[] memory old = _swap(address(tok), sl, va);
        bytes32[] memory ts = new bytes32[](1);
        uint256[] memory tv = new uint256[](1);
        (ts[0], tv[0]) = (keccak256(abi.encode(c.v, uint256(0))), 1 ether); // SymTierSource.t[v]
        uint256[] memory told = _swap(address(tier), ts, tv);
        vm.prank(sp0);
        uint8 r = uint8(IxPNTsLock(address(tok)).tryReserveCredit(c.v, c.h, 1 ether));
        vm.assume(r == 0); // CreditResult.OK
        _restore(address(tier), ts, told);
        _restore(address(tok), sl, old);
    }

    function _word2(bytes memory ret, uint256 i) internal pure returns (uint256 w) {
        assembly { w := mload(add(add(ret, 32), mul(i, 32))) }
    }

    /// @dev W3 (ERC20 conservation, sum of balances == totalSupply): every balance the call can
    ///      touch is <= totalSupply, and every PAIR of distinct such accounts holds <= totalSupply.
    ///      The accounts are the victim, the sender, and the first two ABI words read as addresses
    ///      (transfer/transferFrom/burn/mint/transferAndCall move balances only between these).
    ///      Without the pair bound OZ's unchecked receiver credit can wrap in an unreachable state
    ///      (spurious counterexample replayed in D5c1ReplayTest.test_D5c1_replay_I2_transferFrom_*).
    function _w3(Ctx memory c) internal view {
        uint256 sup = _ld(bytes32(S_SUPPLY));
        address[4] memory who = [c.v, c.sender, c.userArg, address(uint160(c.w1))];
        uint256[4] memory bal;
        for (uint256 i = 0; i < 4; i++) {
            bal[i] = _ld(_m1(who[i], S_BAL));
            vm.assume(bal[i] <= sup);
        }
        for (uint256 i = 0; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                uint256 ok;
                unchecked { ok = _u(who[i] == who[j]) | _u(bal[i] <= sup - bal[j]); }
                vm.assume(ok == 1);
            }
        }
    }

    /// @dev Hook for additional, explicitly labelled pre-state assumptions (default: none).
    function _extraAssumptions(Ctx memory c) internal view virtual {}

    /// @dev Hook to restrict the explored selectors (default: none). Only for diagnostics or to
    ///      split one ABI into disjoint selector groups that together cover it.
    function _selectorFilter(bytes4 sel) internal virtual {}

    /// @dev Work partition for parallel runs (script/halmos/run-partitioned.py), read from the
    ///      environment: D5C1_PART unset/0 = no restriction; any selector value = exactly the ABI
    ///      function with that selector (well-formed calldata); 1 = "OTHER": the empty calldata, and
    ///      createCalldata's 1028-byte symbolic-selector input restricted to selectors that are NOT
    ///      in the core or the extension ABI (XPNTsV2Selectors, views included), i.e. unknown
    ///      selectors, which fall through the core fallback into the extension and revert. Known
    ///      selectors reached with arbitrary (non-canonical) argument bytes are NOT explored: Halmos
    ///      cannot execute symbolic ABI offsets (NotConcreteError); see D5c-1-halmos.md §2.5.
    ///      The driver runs part 1 plus one part per non-view selector of the named ABI; the parts
    ///      are disjoint (a partition restricts the calldata, never the pre-state).
    function _partition(bytes4 sel, uint256 len) internal view {
        uint256 part = vm.envOr("D5C1_PART", uint256(0));
        if (part == 0) return;
        if (part == 1) {
            vm.assume(len == 0 || len == 1028);
            if (len == 1028) vm.assume(XPNTsV2Selectors.isKnown(sel) == 0);
        } else {
            vm.assume(len != 1028);
            vm.assume(uint256(uint32(sel)) == part);
        }
    }

    function _isUserRenewal(Ctx memory c) internal pure returns (uint256) {
        return (_u(c.sel == xPNTsTokenV2.renewForSelf.selector) & _u(c.sender == c.v))
            | (_u(c.sel == xPNTsTokenV2Ext.executeBySig.selector) & _u(c.userArg == c.v));
    }

    // ------------------------------------------------------------------ predicate bitmasks
    // (shared with XPNTsV2HalmosProbe so a counterexample can be replayed concretely)

    function _a3bits(S memory a, S memory b, Ctx memory c) internal pure returns (uint256 bad) {
        unchecked {
            uint256 dec = a.bal - b.bal;
            uint256 dd = _u(c.v != c.sender) & _u(b.bal < a.bal);
            bad |= (_imp(_u(c.sel == xPNTsTokenV2.transferFrom.selector), _u(!c.ok)) ^ 1) << 0;
            bad |= (_imp(_u(c.sel == SEL_BURN_FROM) & _u(c.userArg != c.sender), _u(!c.ok)) ^ 1) << 1;
            bad |= (_imp(dd, _u(b.supply <= a.supply) & _u(a.supply - b.supply >= dec)) ^ 1) << 2;
            bad |= (_imp(dd, _u(c.sel == xPNTsTokenV2.settleLocked.selector) & _u(c.userArg == c.v)
                & _u(a.lkLocker == c.sender)) ^ 1) << 3;
            bad |= (_imp(dd, _u(dec <= a.lkX0)) ^ 1) << 4;
            bad |= (_imp(dd, _u(b.locked <= a.locked) & _u(a.locked - b.locked == a.lkX0)
                & _u(b.lkLocker == address(0))) ^ 1) << 5;
        }
    }

    function _a3xbits(S memory a, S memory b, Ctx memory c) internal pure returns (uint256 bad) {
        unchecked {
            uint256 dec = a.bal - b.bal;
            uint256 dd = _u(c.v != c.sender) & _u(b.bal < a.bal);
            uint256 charge = _minBF(c.w2, a.lkA0);
            // under dec <= x0 < 2^128 and charge <= a0 < 2^128 both products are exact
            uint256 exact = _u(dec <= a.lkX0)
                & (_u(dec == 0) | (_u(a.lkA0 != 0) & _u((dec - 1) * a.lkA0 < charge * a.lkX0)));
            bad |= (_imp(dd, exact) ^ 1) << 6;
        }
    }

    struct F {
        uint256 isSettle;
        uint256 consume;     // settleLocked | releaseStaleLock | releaseAndDisable(by v)
        uint256 spRenew;     // SP-relayed renewal lock for v by the current SP (autoRenewUsed < K)
        uint256 userRenew;   // renewForSelf by v | R2 executeBySig for v
        uint256 refundBound; // a0 - min(charge, a0) for settle, a0 for release
    }

    function _flags(S memory a, Ctx memory c) internal pure returns (F memory f) {
        unchecked {
            f.isSettle = _u(c.sel == xPNTsTokenV2.settleLocked.selector);
            uint256 isRelease = _u(c.sel == xPNTsTokenV2.releaseStaleLock.selector)
                | (_u(c.sel == xPNTsTokenV2Ext.releaseAndDisable.selector) & _u(c.sender == c.v));
            f.consume = f.isSettle | isRelease;
            f.spRenew = _u(c.sel == xPNTsTokenV2.tryLockForGas.selector) & _u(c.sender == a.sp)
                & _u(c.userArg == c.v) & _u(c.w3 == 1) & _u(a.renewUsed < K);
            f.userRenew = _isUserRenewal(c);
            f.refundBound = _sel01(f.isSettle, a.lkA0 - _minBF(c.w2, a.lkA0), a.lkA0);
        }
    }

    /// bits 0-5
    function _i2counters(S memory a, S memory b, Ctx memory c, F memory f) internal pure returns (uint256 bad) {
        unchecked {
            bad |= (_imp(_u(b.usedA > a.usedA), _u(b.usedA <= a.capA)) ^ 1) << 0;
            bad |= (_imp(_u(b.usedB > a.usedB), _u(b.usedB <= a.capB)) ^ 1) << 1;
            bad |= (_imp(_u(b.renewUsed > a.renewUsed), _u(b.renewUsed <= K) & f.spRenew) ^ 1) << 2;
            bad |= (_imp(_u(b.renewUsed < a.renewUsed), f.userRenew) ^ 1) << 3;
            uint256 refundA = f.consume & _u(a.lkLocker == c.e) & _u(a.usedA - b.usedA <= f.refundBound);
            bad |= (_imp(_u(b.usedA < a.usedA), f.userRenew | (f.spRenew & _u(c.e == a.sp)) | refundA) ^ 1) << 4;
            uint256 refundB = f.consume & _u(a.lkLocker != address(0)) & _u(a.usedB - b.usedB <= f.refundBound);
            bad |= (_imp(_u(b.usedB < a.usedB), f.userRenew | f.spRenew | refundB) ^ 1) << 5;
        }
    }

    /// bit 6
    function _i2pull(S memory a, S memory b, Ctx memory c, F memory f) internal pure returns (uint256 bad) {
        unchecked {
            uint256 pull = _u(c.sender != c.v) & _u(b.bal < a.bal) & (f.isSettle ^ 1) & _u(c.e == c.sender);
            uint256 meteredAuto = _u(b.usedA > a.usedA) & _u(b.usedA <= a.capA) & _u(b.usedB > a.usedB)
                & _u(b.usedB <= a.capB);
            uint256 metered = _u(a.explicitAllow >= a.bal - b.bal) | meteredAuto;
            uint256 viaPull = _u(c.sel == xPNTsTokenV2.transferFrom.selector) | _u(c.sel == SEL_BURN_FROM);
            bad |= (_imp(pull, viaPull & metered) ^ 1) << 6;
        }
    }

    /// bits 7-8
    function _i2create(S memory a, S memory b, Ctx memory c, F memory f) internal pure returns (uint256 bad) {
        unchecked {
            uint256 created = _u(a.lkLocker == address(0)) & _u(b.lkLocker != address(0));
            uint256 baseA = _sel01(f.spRenew, 0, a.usedA);
            uint256 baseB = _sel01(f.spRenew, 0, a.usedB);
            uint256 okc = _u(c.sel == xPNTsTokenV2.tryLockForGas.selector) & _u(b.lkLocker == c.sender)
                & _u(c.sender == a.sp);
            okc &= _u(c.e != b.lkLocker) | (_u(b.usedA >= baseA) & _u(b.usedA - baseA == b.lkA0));
            okc &= _u(b.usedB >= baseB) & _u(b.usedB - baseB == b.lkA0);
            okc &= _u(b.locked >= a.locked) & _u(b.locked - a.locked == b.lkX0);
            okc &= _u(b.lkA0 == 0) | _u(b.lkX0 != 0);
            bad |= (_imp(created, okc) ^ 1) << 7;
            uint256 same = _u(b.lkLocker == a.lkLocker) & _u(b.lkX0 == a.lkX0) & _u(b.lkA0 == a.lkA0);
            bad |= (_imp(_u(a.lkLocker != address(0)) & _u(b.lkLocker != address(0)), same) ^ 1) << 8;
        }
    }

    /// bits 9-10
    function _i2reset(S memory a, S memory b, F memory f) internal pure returns (uint256 bad) {
        unchecked {
            uint256 dec = _u(b.usedA < a.usedA) | _u(b.usedB < a.usedB) | _u(b.renewUsed < a.renewUsed);
            uint256 reset = dec & (f.userRenew | f.spRenew) & (f.consume ^ 1);
            bad |= (_imp(reset, _u(a.locked == 0) & _u(a.reserved == 0)) ^ 1) << 9;
            uint256 created = _u(a.lkLocker == address(0)) & _u(b.lkLocker != address(0))
                & _u(b.locked > a.locked) & _u(b.locked - a.locked == b.lkX0);
            uint256 deleted = _u(a.lkLocker != address(0)) & _u(b.lkLocker == address(0))
                & _u(b.locked < a.locked) & _u(a.locked - b.locked == a.lkX0);
            bad |= (_imp(_u(b.locked != a.locked), created | deleted) ^ 1) << 10;
        }
    }

    function _i6bits(S memory a, S memory b, Ctx memory c) internal pure returns (uint256 bad) {
        unchecked {
            uint256 lim = _minBF(a.reqCap, CEILING);
            bad |= (_imp(_u(b.reserved > a.reserved),
                _u(c.sel == xPNTsTokenV2.tryReserveCredit.selector) & _u(c.sender == a.sp) & _u(c.userArg == c.v)
                & _u(a.policy != 0) & _u(a.reqEpoch == a.epoch) & _u(b.debt == a.debt)
                & _u(b.reserved <= lim) & _u(a.debt <= lim - b.reserved)) ^ 1) << 0;
            bad |= (_imp(_u(b.debt > a.debt),
                _u(c.sel == xPNTsTokenV2.settleCredit.selector) & _u(c.userArg == c.v) & _u(a.crLocker == c.sender)
                & _u(b.debt - a.debt <= a.crAmount) & _u(b.reserved <= a.reserved)
                & _u(a.reserved - b.reserved == a.crAmount) & _u(b.crLocker == address(0))) ^ 1) << 1;
            uint256 created = _u(a.crLocker == address(0)) & _u(b.crLocker != address(0))
                & _u(b.reserved > a.reserved) & _u(b.reserved - a.reserved == b.crAmount);
            uint256 deleted = _u(a.crLocker != address(0)) & _u(b.crLocker == address(0))
                & _u(b.reserved < a.reserved) & _u(a.reserved - b.reserved == a.crAmount);
            bad |= (_imp(_u(b.reserved != a.reserved), created | deleted) ^ 1) << 2;
        }
    }

    function _i6jbits(S memory b, uint256 bnd) internal pure returns (uint256 bad) {
        unchecked {
            bad |= (_imp(_u(b.reqCap <= bnd), _u(b.debt <= bnd) & _u(b.reserved <= bnd - b.debt)) ^ 1) << 3;
        }
    }

    event D5C1_BAD(uint256 bad);

    function _report(uint256 bad) internal {
        emit D5C1_BAD(bad);
        assert(bad == 0);
    }
}

// =====================================================================================
// A-3 (+ the balance half of I6): a current or historical SP can only DESTROY the victim's tokens,
// only through settleLocked of the victim's own record that it holds, at most xc.
//   bit 0  A3-1  transferFrom never succeeds for the SP / a historical SP
//   bit 1  A3-2  burn(from != sender, ·) never succeeds for the SP / a historical SP
//   bit 2  A3-3  victim loss  ==>  totalSupply falls by at least the loss (destroy, not transfer)
//   bit 3  A3-4  victim loss  ==>  selector == settleLocked, user == victim, record.locker == sender
//   bit 4  A3-5  victim loss <= x0 (the escrowed xLocked of that record)
//   bit 5  A3-6  victim loss  ==>  lockedOf falls by exactly x0 and the record is deleted
//   (exact ceil bound, bit 6, lives in check_A3x_*: non-linear, kept apart)
// =====================================================================================
contract XPNTsV2A3HalmosTest is XPNTsV2HalmosBase {
    function _a3(bool extAbi) internal {
        (S memory a, S memory b, Ctx memory c) = _step(extAbi, true, PRIME_LOCK, false, 0);
        _report(_a3bits(a, b, c));
    }

    function check_A3_coreAbi() public { _a3(false); }

    function check_A3_extAbi() public { _a3(true); }
}

/// A-3 exact bound (§10.2): victim loss <= xc = min(x0, ceil(c·x0/a0)), c = min(charge, a0),
/// written as  loss <= x0  AND  (loss == 0 OR (loss-1)·a0 < c·x0)   (bit 6). Non-linear, so it is
/// its own check; the settle is the only path that can lose (A3-4), so only settleLocked is explored.
contract XPNTsV2A3xHalmosTest is XPNTsV2HalmosBase {
    function _selectorFilter(bytes4 sel) internal pure override {
        vm.assume(sel == xPNTsTokenV2.settleLocked.selector);
    }

    function check_A3x_exactCeilBound() public {
        (S memory a, S memory b, Ctx memory c) = _step(false, true, PRIME_LOCK, false, 0);
        _report(_a3xbits(a, b, c));
    }
}

// =====================================================================================
// I2 step lemmas (arbitrary sender; lock-primed):
//   bit 0  I2-1  _auto[e][v].used grows            ==>  used' <= cap in force
//   bit 1  I2-2  _budget[v].used grows             ==>  used' <= total cap in force
//   bit 2  I2-3  autoRenewUsed grows               ==>  <= K, and only via the SP's spRenew lock
//   bit 3  I2-4  autoRenewUsed shrinks             ==>  a user renewal (renewForSelf by v / R2 for v)
//   bit 4  I2-5  _auto[e][v].used shrinks          ==>  user renewal | SP renewal of the SP cell |
//                                                     refund of the consumed (v,h) record held by e,
//                                                     by at most a0 - charge (settle) or a0 (release)
//   bit 5  I2-6  _budget[v].used shrinks           ==>  same, for any record holder
//   bit 6  I2-7  third-party pull by e              ==>  transferFrom/burn(from) covered by explicit
//                                                     approval or metered in e's cell+total within caps
//   bit 7  I2-8  a (v,h) lock record is created     ==>  only by tryLockForGas of the current SP, and
//                                                     metered exactly (+a0 on used, +x0 on lockedOf),
//                                                     a0 > 0 => x0 > 0
//   bit 8  I2-8b an existing record is never overwritten
//   bit 9  I2-9  a counter reset (user or SP renewal) happens only with lockedOf == reserved == 0
//   bit 10 I4-L  lockedOf(v) changes only by the x0 of the (v,h) record created/deleted by the call
// =====================================================================================
contract XPNTsV2I2HalmosTest is XPNTsV2HalmosBase {
    /// Pre-state assumes the PROVEN invariant R (XPNTsV2RateHalmosTest) — not a free assumption.
    function _extraAssumptions(Ctx memory) internal view virtual override {
        uint256 rate = _ld(bytes32(S_RATE));
        uint256 mx = _ld(bytes32(S_MAXTX));
        vm.assume(rate >= RATE_MIN);
        vm.assume(rate <= RATE_MAX);
        vm.assume(mx != 0);
        vm.assume(mx <= MAXTX_CAP);
    }

    function _i2(bool extAbi) internal {
        (S memory a, S memory b, Ctx memory c) = _step(extAbi, false, PRIME_LOCK, false, 0);
        F memory f = _flags(a, c);
        uint256 bad = _i2counters(a, b, c, f) | _i2pull(a, b, c, f) | _i2create(a, b, c, f) | _i2reset(a, b, f);
        _report(bad);
    }

    function check_I2_coreAbi() public { _i2(false); }

    function check_I2_extAbi() public { _i2(true); }
}

/// I2 WITHOUT the invariant R (only W1-W3). Expected to FAIL on bits 7 / 10: with an
/// out-of-range exchangeRate a lock's x can exceed 2^128 and `uint128(x)` truncates the record —
/// the symbolic face of finding F-D5c1-1 (D5c-1-halmos.md §F). Kept as the reason R is needed.
contract XPNTsV2I2NoRHalmosTest is XPNTsV2I2HalmosTest {
    function _extraAssumptions(Ctx memory) internal pure override {}
}

/// The `mint` partition, split on the victim's debt. With debts(v) == 0 a mint to v performs no
/// auto-repay, so the step is linear and Halmos closes it; the debts(v) > 0 case reduces to the
/// arithmetic lemma M (repayX <= m, MintRepayLemma.t.sol), on which Halmos times out, so it is
/// discharged by a paper proof + a fuzz test on the real code path (D5c-1-halmos.md §3.2).
contract XPNTsV2A3MintNoDebtHalmosTest is XPNTsV2A3HalmosTest {
    function _extraAssumptions(Ctx memory c) internal view override {
        vm.assume(_ld(_m1(c.v, S_DEBTS)) == 0);
    }
}

contract XPNTsV2I2MintNoDebtHalmosTest is XPNTsV2I2HalmosTest {
    function _extraAssumptions(Ctx memory c) internal view override {
        super._extraAssumptions(c);
        vm.assume(_ld(_m1(c.v, S_DEBTS)) == 0);
    }
}

// =====================================================================================
// R — the rate / single-tx-limit range, proven INDUCTIVE (so the I2 check may assume it):
//   R := 1e14 <= exchangeRate <= 1e22  AND  0 < maxSingleTxLimit <= 50,000e18
//   base: initialize (fresh clone, symbolic rate) establishes R or reverts        (bit 0)
//   step: R before  ==>  R after, for one arbitrary call (core ABI / ext ABI), any sender (bit 1)
// Together with reserveAPNTs <= maxSingleTxLimit this bounds every escrow x <= 5e26 < 2^128.
// =====================================================================================
contract XPNTsV2RateHalmosTest is XPNTsV2HalmosBase {
    function _r() internal view returns (uint256) {
        uint256 rate = _ld(bytes32(S_RATE));
        uint256 mx = _ld(bytes32(S_MAXTX));
        return _u(rate >= RATE_MIN) & _u(rate <= RATE_MAX) & _u(mx != 0) & _u(mx <= MAXTX_CAP);
    }

    /// Base case on the real clone created in setUp (never initialised, concrete empty storage).
    /// SP / spender / tier source are left 0: each would only add a revert path.
    function check_RATE_base_initialize() public {
        xPNTsTokenV2.InitConfig memory cfg = xPNTsTokenV2.InitConfig({
            name: "n", symbol: "s", communityOwner: address(0xC0), community: address(0xC1),
            communityName: "c", communityENS: "e", exchangeRate: svm.createUint256("initRate"),
            superPaymaster: address(0), genesisSpender: address(0), tierSource: address(0)
        });
        (bool ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.initialize, (cfg)));
        _report((_imp(_u(ok), _r()) ^ 1) << 0);
    }

    /// Base case through the REAL deployment path (DSR request after F-D5c1-1): the initial rate is
    /// symbolic over the FULL uint256 domain and goes through xPNTsFactoryV2.deployxPNTsToken
    /// (clone + initialize with the factory's genesis SP and default tier source). Claim: the
    /// deployment reverts, or the new token satisfies R.                                  (bit 2)
    function check_RATE_base_realFactory() public {
        AOAProtocolRegistry r2 = new AOAProtocolRegistry(address(this));
        MockRegistryV2Lite roles = new MockRegistryV2Lite();
        GlobalTierSource ts = new GlobalTierSource(address(roles));
        address sp = address(0x5B);
        r2.bootstrapApprove(r2.KIND_SP(), r2.spKey(sp));
        r2.bootstrapApprove(r2.KIND_TIER_SOURCE(), address(ts).codehash);
        xPNTsTokenV2Ext e2 = new xPNTsTokenV2Ext(address(r2));
        xPNTsTokenV2 i2 = new xPNTsTokenV2(address(r2), address(e2));
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(sp, address(roles), address(i2), address(ts));
        uint256 rate = svm.createUint256("deployRate");
        vm.prank(address(0xC0));
        (bool ok, bytes memory ret) = address(factory).call(abi.encodeCall(
            xPNTsFactoryV2.deployxPNTsToken, ("C", "xC", "C", "c.eth", rate, address(0))
        ));
        uint256 good = 1;
        if (ok) {
            address t = abi.decode(ret, (address));
            uint256 tr = uint256(vm.load(t, bytes32(S_RATE)));
            uint256 tm = uint256(vm.load(t, bytes32(S_MAXTX)));
            good = _u(tr >= RATE_MIN) & _u(tr <= RATE_MAX) & _u(tm != 0) & _u(tm <= MAXTX_CAP);
        }
        _report((good ^ 1) << 2);
    }

    function _step1(bool extAbi) internal {
        svm.enableSymbolicStorage(address(tok));
        svm.enableSymbolicStorage(address(reg));
        address sender = svm.createAddress("sender");
        bytes memory data = extAbi ? svm.createCalldata("xPNTsTokenV2Ext") : svm.createCalldata("xPNTsTokenV2");
        _partition(_sel(data), data.length);
        vm.assume(uint64(_ld(INIT_SLOT)) != 0); // W1
        vm.assume(_r() == 1);                   // induction hypothesis
        vm.prank(sender);
        (bool ok, ) = address(tok).call(data);
        ok;
        _report((_r() ^ 1) << 1);
    }

    function check_RATE_step_coreAbi() public { _step1(false); }

    function check_RATE_step_extAbi() public { _step1(true); }
}

// =====================================================================================
// I6 step lemmas (credit half; arbitrary sender; credit-primed):
//   bit 0  I6-1  creditReservedOf(v) grows  ==>  tryReserveCredit by the current SP for v, policy != OFF,
//                                              request epoch == policy epoch, debts unchanged and
//                                              debts + reserved' <= min(requestedCap, CEILING)
//   bit 1  I6-2  debts(v) grows              ==>  settleCredit of the (v,h) reservation held by the sender,
//                                              debt increase <= its amount, reserved falls by exactly
//                                              the amount and the reservation is deleted
//   bit 2  I4-C  creditReservedOf(v) changes only by the amount of the (v,h) reservation created/deleted
// I6-J (cumulative, fully inductive):  J(B) := debts(v) + creditReservedOf(v) <= B,
//   preserved by ANY call whenever requestedCap(v) <= B before and after   (bit 3)
// =====================================================================================
contract XPNTsV2I6HalmosTest is XPNTsV2HalmosBase {
    function _i6(bool extAbi) internal {
        (S memory a, S memory b, Ctx memory c) = _step(extAbi, false, PRIME_CREDIT, false, 0);
        _report(_i6bits(a, b, c));
    }

    function check_I6_coreAbi() public { _i6(false); }

    function check_I6_extAbi() public { _i6(true); }

    function _i6j(bool extAbi) internal {
        uint256 bnd = svm.createUint256("B");
        (, S memory b, ) = _step(extAbi, false, PRIME_CREDIT, true, bnd);
        _report(_i6jbits(b, bnd));
    }

    function check_I6J_coreAbi() public { _i6j(false); }

    function check_I6J_extAbi() public { _i6j(true); }
}

// =====================================================================================
// Reachability witnesses (positive controls). Each claims an antecedent used above is UNREACHABLE
// in this very harness; Halmos is EXPECTED to refute it (counterexample). A green witness would
// mean the matching check is vacuous. Witness counterexamples are replayed in D5c1Replay.t.sol.
// =====================================================================================
contract XPNTsV2WitnessHalmosTest is XPNTsV2HalmosBase {
    /// A-3: an SP settle really burns the victim's balance (priming made the record live).
    function check_witness_A3_spSettleBurnsVictim() public {
        (S memory a, S memory b, Ctx memory c) = _step(false, true, PRIME_LOCK, false, 0);
        assert((_u(c.ok) & _u(c.sel == xPNTsTokenV2.settleLocked.selector) & _u(c.v != c.sender)
            & _u(b.bal < a.bal)) == 0);
    }

    /// I2-3: the SP-relayed renewal really increments autoRenewUsed.
    function check_witness_I2_spRenewIncrements() public {
        (S memory a, S memory b, ) = _step(false, false, PRIME_LOCK, false, 0);
        assert(_u(b.renewUsed > a.renewUsed) == 0);
    }

    /// I2-7: a third-party pull metered by the auto-allowance really happens.
    function check_witness_I2_meteredPull() public {
        (S memory a, S memory b, Ctx memory c) = _step(false, false, PRIME_LOCK, false, 0);
        assert((_u(c.ok) & _u(c.sender != c.v) & _u(c.e == c.sender) & _u(b.bal < a.bal)
            & _u(b.usedA > a.usedA)) == 0);
    }

    /// I6-2: debt really grows through settleCredit.
    function check_witness_I6_debtGrows() public {
        (S memory a, S memory b, ) = _step(false, false, PRIME_CREDIT, false, 0);
        assert(_u(b.debt > a.debt) == 0);
    }

    /// I6-1: a new reservation is really admitted.
    function check_witness_I6_reservationAdmitted() public {
        (S memory a, S memory b, ) = _step(false, false, PRIME_CREDIT, false, 0);
        assert(_u(b.reserved > a.reserved) == 0);
    }
}

/// I6 on the `mint` partition with debts(v) == 0 (see XPNTsV2A3MintNoDebtHalmosTest).
contract XPNTsV2I6MintNoDebtHalmosTest is XPNTsV2I6HalmosTest {
    function _extraAssumptions(Ctx memory c) internal view override {
        vm.assume(_ld(_m1(c.v, S_DEBTS)) == 0);
    }
}
