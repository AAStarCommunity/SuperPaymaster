// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import { HalmosBase } from "./HalmosSVM.sol";

/**
 * @title D5c-2 · I9 harness — "settle cannot silently fail" (unit level, no EntryPoint)
 * @dev   03-final-spec.md RDR-2: I9 ("no unbacked sponsorship") is discharged here as a
 *        structural property of `SuperPaymaster.postOp` in isolation, split per the spec's own
 *        framing into an ARITHMETIC LEMMA (the code's `if (charge > c.a0) charge = c.a0;` clamp,
 *        §3 L9-CLAMP below) plus CONTROL FLOW AT CONCRETE PRICE POINTS (§3 CF-*): postOp's `price`
 *        / `decimals` / `aPriceUSD` are context fields the harness itself constructs (never
 *        storage), so they are fixed to one concrete point (2000e8 / 8 / 0.02e18, the same
 *        constants used elsewhere in this repo's fixtures — V55MutablePriceFeed,
 *        `SuperPaymaster.initialize`'s default aPNTsPriceUSD) and `protocolFeeBPS` (real SP
 *        storage, otherwise symbolic under `enableSymbolicStorage`) is pinned to the SP default
 *        1000 by a direct `vm.store` after enabling symbolic storage. This removes the
 *        symbol-times-symbol `Math.mulDiv` chain that timed out analogous arithmetic in D5c-1
 *        (§2.5 "mint" partition, lemma M) while leaving every CONTROL-FLOW-relevant quantity —
 *        a0, actualGasCost, actualUserOpFeePerGas, callGas, postOpGas, mode, operator, user,
 *        opHash, and (crucially) whether the settlement call itself succeeds or reverts — fully
 *        symbolic. `charge`'s concrete numeric correctness is a DIFFERENT, already-covered
 *        property (D5-traceability.md §1.1 R10-M3 exact-charge comparison against EntryPoint's
 *        real postOp calldata, G2 fuzz); this harness only ties postOp's OBSERVABLE ACCOUNTING
 *        EFFECTS to whether the settlement external call actually succeeded.
 *
 *        Trust boundary W-CTX (documented, not proven here — see D5c-2-halmos.md §2): `context`
 *        is assumed to be exactly what THIS SP's own `validatePaymasterUserOp` could have
 *        returned for some reachable pre-state, in particular `token` a real registered xPNTs
 *        token and `mode ∈ {MODE_BALANCE, MODE_CREDIT}`. Justification: `postOp` is
 *        `onlyEntryPoint`; a canonical, codehash-pinned ERC-4337 v0.7 EntryPoint (the same
 *        assumption D5-plan.md's G2 EntryPoint-level fuzz makes, and verifies against real
 *        EntryPoint bytecode) always relays back exactly the context bytes ITS OWN validation
 *        call produced for that userOp, in the same transaction — never attacker-supplied.
 *        Feeding postOp a context whose `token` field is a garbage / uncontrolled address (so the
 *        "settlement" call trivially succeeds against an empty account) is EXCLUDED by
 *        construction: the harness forces the decoded `token` to be one of exactly two deployed
 *        probes (§1), not a free symbolic address. This is a deliberate, honest scope boundary,
 *        not a gap papered over — see D5c-2-halmos.md §2 for why it is out of scope for a unit
 *        harness and where the corresponding real-world guarantee (context authenticity) is
 *        covered instead.
 *
 *        `check_*` functions are run by Halmos only; forge ignores them (only `test*` /
 *        `invariant*` run under `forge test`).
 */

/// @dev §1: the two settlement outcomes postOp's `token` call can have. Selectors match
///      IxPNTsTokenV2.settleLocked / settleCredit exactly, so `IxPNTsTokenV2(token).settleLocked(...)`
///      in the real postOp code routes here when Halmos aliases the symbolic `token` field to one
///      of these two deployed addresses (§2.4 forces exactly this aliasing; see W-CTX above for why
///      the "aliased to an address with no code" branch is out of scope here).
contract I9SettleProbe {
    bool public immutable REVERTS;

    mapping(bytes32 => bool) public lockedCalled;
    mapping(bytes32 => uint256) public lockedCharge;
    mapping(bytes32 => bool) public creditCalled;
    mapping(bytes32 => uint256) public creditCharge;

    constructor(bool reverts_) {
        REVERTS = reverts_;
    }

    function settleLocked(address, bytes32 opHash, uint256 chargeAPNTs) external returns (uint256) {
        if (REVERTS) revert("I9Probe: settleLocked reverts");
        lockedCalled[opHash] = true;
        lockedCharge[opHash] = chargeAPNTs;
        return chargeAPNTs;
    }

    function settleCredit(address, bytes32 opHash, uint256 chargeAPNTs) external returns (uint256) {
        if (REVERTS) revert("I9Probe: settleCredit reverts");
        creditCalled[opHash] = true;
        creditCharge[opHash] = chargeAPNTs;
        return chargeAPNTs;
    }
}

contract SuperPaymasterI9HalmosTest is Test, HalmosBase {
    // --- SuperPaymasterStorage layout (out/SuperPaymaster.sol/SuperPaymaster.json storageLayout) ---
    uint256 internal constant S_STATUS = 1; // ReentrancyGuard._status (OZ v5.0.2, persistent, not transient)
    uint256 internal constant S_OPERATORS = 5;
    uint256 internal constant S_PROTOCOL_FEE_BPS = 13;
    uint256 internal constant S_PROTOCOL_REVENUE = 16;
    uint256 internal constant S_SETTLED_DEBT_OPS = 33;
    uint256 internal constant NOT_ENTERED = 1;

    uint8 internal constant MODE_BALANCE = 1;

    // §CF concrete price point (context fields the harness constructs; never storage).
    int256 internal constant PRICE = 2000e8;
    uint8 internal constant DECIMALS = 8;
    uint256 internal constant A_PRICE_USD = 0.02 ether;
    uint256 internal constant PROTOCOL_FEE_BPS = 1000; // pinned SP-storage default (SP.initialize)

    address internal constant ENTRYPOINT_ADDR = address(0xE717070717070717070717070717070717070E);
    address internal constant DUMMY_REGISTRY = address(0xBEEF00000000000000000000000000000BEEF0);
    address internal constant DUMMY_FEED = address(0xFEED00000000000000000000000000000FEED0);

    SuperPaymaster internal sp;
    I9SettleProbe internal probeGood; // REVERTS = false
    I9SettleProbe internal probeBad;  // REVERTS = true

    function setUp() public {
        sp = new SuperPaymaster(IEntryPoint(ENTRYPOINT_ADDR), IRegistry(DUMMY_REGISTRY), DUMMY_FEED);
        probeGood = new I9SettleProbe(false);
        probeBad = new I9SettleProbe(true);

        // Arbitrary pre-state (D5c-1 §2.1's inductive step: full symbolic storage, no assumed
        // history). `protocolFeeBPS` is then pinned per the file header's concrete-price-point
        // rationale (§CF); every other slot — including `operators[...]`, `_settledDebtOps[...]`,
        // `protocolRevenue`, `userOpState[...]` for the symbolic operator/user/opHash this check
        // uses — stays a fully free symbol.
        svm.enableSymbolicStorage(address(sp));
        vm.store(address(sp), bytes32(S_PROTOCOL_FEE_BPS), bytes32(PROTOCOL_FEE_BPS));
        // W-REENTRANT: `postOp` is `nonReentrant`; an arbitrary pre-state can leave OZ
        // ReentrancyGuard's `_status` symbolically equal to its own ENTERED sentinel (a state that
        // is unreachable at the START of a fresh external call — the guard always unlocks again
        // before the call that set it returns), which would make the `nonReentrant` modifier
        // revert for EVERY input and drown every real counterexample in a vacuous one. Pin it to
        // NOT_ENTERED, mirroring D5c-1's W1 (initialized clone) style well-formedness assumptions.
        vm.store(address(sp), bytes32(S_STATUS), bytes32(NOT_ENTERED));
    }

    // ---- storage-slot helpers. `_settledSlot`'s base slot (33) was read directly from
    //      `forge inspect SuperPaymaster storageLayout --json` (D5c-2-halmos.md §1 records the
    //      exact command and the full slot table used throughout this file); every OTHER field
    //      this harness reads goes through `sp.operators(...)` / `sp.userOpState(...)` /
    //      `sp.protocolRevenue()` — the real public getters, not a hand-rolled slot formula, so
    //      only `_settledDebtOps` (internal, no getter) needed the layout cross-check at all. ----

    function _settledSlot(bytes32 opHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(opHash, S_SETTLED_DEBT_OPS));
    }

    function _isSettled(bytes32 opHash) internal view returns (bool) {
        return uint256(vm.load(address(sp), _settledSlot(opHash))) != 0;
    }

    function _setSettled(bytes32 opHash, bool v) internal {
        vm.store(address(sp), _settledSlot(opHash), bytes32(uint256(v ? 1 : 0)));
    }

    struct OpSnap {
        uint128 aPNTsBalance;
        bool isConfigured;
        bool isPaused;
        address xPNTsToken;
        uint32 reputation;
        uint48 minTxInterval;
        address treasury;
        uint256 totalSpent;
        uint256 totalTxSponsored;
        uint256 protocolRevenue;
        uint48 lastTimestamp;
        bool isBlocked;
        bool settled;
    }

    function _snap(address operator, address user, bytes32 opHash) internal view returns (OpSnap memory s) {
        (
            s.aPNTsBalance, s.isConfigured, s.isPaused, s.xPNTsToken, s.reputation, s.minTxInterval,
            s.treasury, s.totalSpent, s.totalTxSponsored
        ) = sp.operators(operator);
        s.protocolRevenue = sp.protocolRevenue();
        (s.lastTimestamp, s.isBlocked) = sp.userOpState(operator, user);
        s.settled = _isSettled(opHash);
    }

    /// @dev Builds a legacy (5.5.0-shaped) 352-byte context: `abi.encode(OpCtx)`'s 11 words, no
    ///      trailing GasParams snapshot word. `postOp` then falls back to `LEGACY_SETTLE_GAS_BOUND`
    ///      / `LEGACY_C_WRAP_GAS` (both fixed constants), which is exactly what lets §CF avoid also
    ///      having to construct a valid packed GasParams word — an orthogonal concern (GOV-5,
    ///      already covered by D5b-design.md's own gates) that this harness does not re-prove.
    function _context(
        address token, address user, uint256 a0, bytes32 opHash, address operator, uint8 mode,
        uint128 callGas, uint128 postOpGas
    ) internal pure returns (bytes memory) {
        return abi.encode(token, user, a0, opHash, operator, mode, callGas, postOpGas, PRICE, DECIMALS, A_PRICE_USD);
    }

    function _callPostOp(bytes memory context, uint256 actualGasCost, uint256 actualFeePerGas)
        internal returns (bool ok)
    {
        vm.prank(ENTRYPOINT_ADDR);
        (ok, ) = address(sp).call(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, context, actualGasCost, actualFeePerGas))
        );
    }

    // =========================================================================================
    // CF-1: context.length == 0 must be a strict no-op (the very first line of postOp).
    // =========================================================================================
    function check_I9_CF1_emptyContext(address operator, address user, bytes32 opHash) external {
        OpSnap memory before = _snap(operator, user, opHash);

        bool ok = _callPostOp("", 0, 0);

        OpSnap memory aft = _snap(operator, user, opHash);
        uint256 bad;
        if (!ok) bad |= 1 << 0; // CF1-a: an empty context must not revert
        if (aft.aPNTsBalance != before.aPNTsBalance) bad |= 1 << 1;
        if (aft.totalTxSponsored != before.totalTxSponsored) bad |= 1 << 2;
        if (aft.totalSpent != before.totalSpent) bad |= 1 << 3;
        if (aft.protocolRevenue != before.protocolRevenue) bad |= 1 << 4;
        if (aft.lastTimestamp != before.lastTimestamp) bad |= 1 << 5;
        if (aft.settled != before.settled) bad |= 1 << 6;
        if (aft.isConfigured != before.isConfigured || aft.isPaused != before.isPaused
            || aft.xPNTsToken != before.xPNTsToken || aft.reputation != before.reputation
            || aft.minTxInterval != before.minTxInterval || aft.treasury != before.treasury) bad |= 1 << 7;
        emit log_named_uint("CF1_bad", bad);
        assert(bad == 0);
    }

    // =========================================================================================
    // CF-2: the P1-17 idempotency guard — a context whose opHash was already settled must be a
    //       no-op EXCEPT the unconditional rate-limit timestamp write (postOp.sol:393-396, which
    //       intentionally runs BEFORE the idempotency check "ALWAYS, even if the op reverted").
    // =========================================================================================
    function check_I9_CF2_idempotentNoOp(
        address token, address user, uint256 a0, bytes32 opHash, address operator, uint8 mode,
        uint128 callGas, uint128 postOpGas, uint256 actualGasCost, uint256 actualFeePerGas
    ) external {
        _setSettled(opHash, true); // precondition: this op was already settled by a prior postOp
        OpSnap memory before = _snap(operator, user, opHash);

        bytes memory ctx = _context(token, user, a0, opHash, operator, mode, callGas, postOpGas);
        bool ok = _callPostOp(ctx, actualGasCost, actualFeePerGas);
        // W-GAS (documented boundary, mirrors W-CTX): postOp's entry guard (line 389, "never START
        // a settlement that could run out of gas half-way") can revert ANY op, including this
        // already-settled replay, if the caller supplies less than LEGACY_SETTLE_GAS_BOUND gas.
        // Under Halmos `gasleft()` at that check is a free symbol (no CLI/cheatcode pins it, and an
        // explicit `{gas: N}` stipend on the outer `.call` empirically does not either — confirmed
        // by running this check both with and without one, D5c-2-halmos.md §2), so this branch is
        // always satisfiable and is NOT part of I9 (it is EntryPoint's admission-time obligation,
        // C-04 / MIN_POST_OP_GAS in validatePaymasterUserOp, already covered elsewhere). We only
        // assert about the "the call actually completed" case; reachability of that case is proven
        // by the paired witness below.
        if (!ok) return;

        OpSnap memory aft = _snap(operator, user, opHash);
        uint256 bad;
        if (aft.aPNTsBalance != before.aPNTsBalance) bad |= 1 << 1; // CF2-b: no second refund
        if (aft.totalTxSponsored != before.totalTxSponsored) bad |= 1 << 2; // CF2-c: no double count
        if (aft.protocolRevenue != before.protocolRevenue) bad |= 1 << 3; // CF2-d: no double revenue
        if (!aft.settled) bad |= 1 << 4; // CF2-e: stays settled
        emit log_named_uint("CF2_bad", bad);
        assert(bad == 0);
    }

    /// @dev Expected to FAIL: proves the "gas was sufficient, replay actually returns" case of
    ///      CF-2 is reachable (not vacuously true because the gas guard always fires).
    function check_witness_I9_CF2_idempotentSucceedsWithEnoughGas(
        address token, address user, uint256 a0, bytes32 opHash, address operator, uint8 mode,
        uint128 callGas, uint128 postOpGas, uint256 actualGasCost, uint256 actualFeePerGas
    ) external {
        _setSettled(opHash, true);
        bytes memory ctx = _context(token, user, a0, opHash, operator, mode, callGas, postOpGas);
        bool ok = _callPostOp(ctx, actualGasCost, actualFeePerGas);
        assert(!ok); // real code: reachable -> witness FAILs
    }

    // =========================================================================================
    // CF-3 (the I9 property proper): "settle cannot silently fail". A FRESH op (not yet settled)
    //      whose settlement call reverts must make the WHOLE postOp revert (bit 0, no gas-guard
    //      carve-out needed — see inline comment). A fresh op whose settlement call succeeds must
    //      (a) actually have observably reached the token (bit 3 — else this check would be
    //      vacuously true, the D5c-1 "reachability witness" concern, §4), (b) respect the clamp
    //      lemma L9-CLAMP (bit 4), and (c) the SP-side accounting delta must equal EXACTLY the
    //      charge the probe recorded (bits 5-6: this is what ties "postOp completed" to
    //      "settlement really happened", not just "postOp returned"), and (d) the op flips to
    //      settled (bit 7). Reachability of both branches is proven by the two witnesses below.
    // =========================================================================================
    function check_I9_CF3_settleCannotSilentlyFail(
        bool useBadToken, address user, uint256 a0, bytes32 opHash, address operator, uint8 mode,
        uint128 callGas, uint128 postOpGas, uint256 actualGasCost, uint256 actualFeePerGas
    ) external {
        // W-A0 (justified bound, not a solver convenience hack): any op admitted by
        // `validatePaymasterUserOp` has `a0 == aPNTsAmount`, checked there against
        // `config.aPNTsBalance` (`ISuperPaymaster.OperatorConfig.aPNTsBalance` is `uint128`) BEFORE
        // the reservation is created — `a0` cannot exceed `type(uint128).max` in any reachable
        // postOp call. Same class of assumption as D5c-1's W1-W4 (§2.2 of that report).
        require(a0 <= type(uint128).max);
        // W-GASBOUND (documented, not silently narrowed): postOp's charge computation chains
        // several `Math.mulDiv`/`ceilDiv` calls; even with `price`/`decimals`/`aPriceUSD`/
        // `protocolFeeBPS` pinned concrete (file header §CF), multiplying two ~2^256-wide symbolic
        // operands is expensive bit-blasting for the solver regardless of divisor concreteness —
        // this is what stalled the unbounded version for 20+ minutes without resolving (see
        // D5c-2-halmos.md §2 for the timing). Bounding to 1e24 wei is far beyond any economically
        // plausible `actualGasCost` / `actualUserOpFeePerGas` (1e24 wei at even a nonsensical 1e15
        // wei/gas rate is 1e9 gas — three orders of magnitude past any real block gas limit). The
        // full unbounded uint256 domain is covered by the companion fuzz test
        // `SuperPaymasterI9Fuzz.t.sol#testFuzz_I9_CF3_settleCannotSilentlyFail` (10,000 runs),
        // exactly D5c-1's "BOUNDED + named fuzz substitute" pattern (§2.6 of that report).
        require(actualGasCost <= 1e24 && actualFeePerGas <= 1e24);
        _setSettled(opHash, false); // precondition: fresh op
        address token = useBadToken ? address(probeBad) : address(probeGood);
        OpSnap memory before = _snap(operator, user, opHash);

        bytes memory ctx = _context(token, user, a0, opHash, operator, mode, callGas, postOpGas);
        bool ok = _callPostOp(ctx, actualGasCost, actualFeePerGas);

        uint256 bad;
        if (useBadToken) {
            // CF3-a (the I9 property proper): the token's settlement call reverted -> postOp as a
            // whole MUST revert. Unlike CF3-c below, this needs NO gas-guard carve-out: a revert
            // bubbling up from `settleLocked`/`settleCredit` and a revert from the earlier entry
            // guard both make `ok == false` — either way `ok == true` here is a genuine violation,
            // because it would mean the settlement's revert was somehow swallowed.
            if (ok) bad |= 1 << 0;
        } else {
            // W-GAS (see CF-2's comment): the entry guard can revert this op for a reason that has
            // nothing to do with settlement (insufficient caller-supplied gas). Only assert about
            // the case that actually completed; reachability is proven by
            // check_witness_I9_freshBalanceSettlementReachable below.
            if (!ok) return;
            bool reachedProbe = mode == MODE_BALANCE
                ? probeGood.lockedCalled(opHash)
                : probeGood.creditCalled(opHash);
            uint256 probeCharge = mode == MODE_BALANCE
                ? probeGood.lockedCharge(opHash)
                : probeGood.creditCharge(opHash);
            // CF3-d: the settlement call must have OBSERVABLY reached the token (not a vacuous
            // "ok==true because nothing happened" reading).
            if (!reachedProbe) bad |= 1 << 3;
            // L9-CLAMP (the arithmetic lemma RDR-2 asks for): postOp's own `if (charge > a0)
            // charge = a0;` clamp — checked here against the value ACTUALLY passed to settlement,
            // not re-derived independently.
            if (probeCharge > a0) bad |= 1 << 4;
            // CF3-e: SP's own bookkeeping must move by EXACTLY the probe-observed charge —
            // operator refund a0-charge, protocol revenue +charge — tying "postOp completed" to
            // "the token really burned/debited this amount", the crux of I9.
            OpSnap memory aft = _snap(operator, user, opHash);
            if (uint256(aft.aPNTsBalance) != uint256(before.aPNTsBalance) + (a0 - probeCharge)) bad |= 1 << 5;
            if (aft.protocolRevenue != before.protocolRevenue + probeCharge) bad |= 1 << 6;
            if (!aft.settled) bad |= 1 << 7;
        }
        emit log_named_uint("CF3_bad", bad);
        assert(bad == 0);
    }

    // =========================================================================================
    // Below: one genuine PASS-expected cross-check (bit 0 alone, restated), then two genuine
    // reachability witnesses (D5c-1 §4 convention: each must FAIL with a counterexample, proving
    // a branch of CF-2/CF-3 is not vacuously satisfied).
    // =========================================================================================

    /// @dev NOT a reachability witness, despite the name (kept as-is so the archived .log's
    ///      `Running` line still matches; see D5c-2-halmos.md §3 for the corrected description).
    ///      This is an independent restatement of CF3-a/bit 0 ALONE, same W-A0/W-GASBOUND
    ///      preconditions as CF-3: `assert(!ok)` is expected to PASS (provable) on the real code —
    ///      a reverting settlement call can never let postOp return successfully. It is cheaper
    ///      than CF-3 (seconds, not tens of seconds) because this assertion never inspects
    ///      `charge`'s concrete value or compares it to anything: `probeBad` reverts
    ///      unconditionally regardless of the charge argument, so the solver never has to pin down
    ///      postOp's `Math.mulDiv`/`ceilDiv` chain to prove `!ok` — only CF-3's "good settle"
    ///      accounting-equality bits (3-7) actually need that chain resolved.
    function check_witness_I9_settleRevertsButCallerObservesSuccess(
        address user, uint256 a0, bytes32 opHash, address operator, uint8 mode,
        uint128 callGas, uint128 postOpGas, uint256 actualGasCost, uint256 actualFeePerGas
    ) external {
        require(a0 <= type(uint128).max); // W-A0, see check_I9_CF3_settleCannotSilentlyFail
        require(actualGasCost <= 1e24 && actualFeePerGas <= 1e24); // W-GASBOUND, ditto
        _setSettled(opHash, false);
        bytes memory ctx = _context(address(probeBad), user, a0, opHash, operator, mode, callGas, postOpGas);
        bool ok = _callPostOp(ctx, actualGasCost, actualFeePerGas);
        assert(!ok); // I9 proper, bounded: PASS (provable) -- see docstring above, this is not a witness
    }

    /// @dev Expected to FAIL: exhibits a fresh op that genuinely settles (probeGood, mode ==
    ///      MODE_BALANCE) to prove the "fresh settlement" branch of CF-3 is reachable at all.
    function check_witness_I9_freshBalanceSettlementReachable(
        address user, uint256 a0, bytes32 opHash, address operator, uint128 callGas, uint128 postOpGas,
        uint256 actualGasCost, uint256 actualFeePerGas
    ) external {
        require(a0 <= type(uint128).max); // W-A0, see check_I9_CF3_settleCannotSilentlyFail
        require(actualGasCost <= 1e24 && actualFeePerGas <= 1e24); // W-GASBOUND, ditto
        _setSettled(opHash, false);
        bytes memory ctx = _context(address(probeGood), user, a0, opHash, operator, MODE_BALANCE, callGas, postOpGas);
        bool ok = _callPostOp(ctx, actualGasCost, actualFeePerGas);
        assert(!(ok && probeGood.lockedCalled(opHash))); // real code: reachable -> witness FAILs
    }
}
