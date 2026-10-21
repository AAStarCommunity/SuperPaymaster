// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import { SuperPaymasterI9HalmosTest } from "./SuperPaymasterI9Halmos.t.sol";

/**
 * @title D5c-2 · I9 rc.2 TEST-ONLY extension (DSR CC-125 d030f6e8 item 2, audit 8b8fd5d8)
 * @dev   Extends `SuperPaymasterI9HalmosTest` WITHOUT touching it (the parent file stays
 *        byte-identical, so its archived evidence still names the same harness). Inheriting reuses
 *        the parent's setUp (symbolic SP storage, `protocolFeeBPS` pinned to 1000, ReentrancyGuard
 *        pinned to NOT_ENTERED), probes and `_snap` / `_callPostOp` helpers verbatim.
 *
 *        What the parent does not cover on rc.2 (v5.5.0-rc.2 = 1ac0e1c5):
 *          (1) the parent builds ONLY the 352-byte (5.5.0 legacy) context. rc.2's only encode site
 *              (`OpCtxOut`, SuperPaymaster.sol validatePaymasterUserOp) emits 384 bytes: the 11
 *              OpCtx words plus word 12 = GasParams snapshot (bits 0-127) | (feeBps + 1) << 128.
 *              postOp reads word 12 ONLY when length == 384: settle-gas bound from bits 32-63,
 *              buffer gas from bits 64-127, and the protocol fee from bits 128-255 (the validation-
 *              time fee) instead of live `protocolFeeBPS`. `check_I9_CF3ctx384_*` re-states CF-3
 *              with the parent's assertion bits UNCHANGED over that 384-byte path.
 *          (2) the parent's reachability witness does not constrain a0 > 0, so a model with
 *              a0 == 0 (charge clamped to 0: nothing settled) satisfies it. The two
 *              `check_witness_I9_posCharge*` witnesses require a0 > 0 AND a strictly positive
 *              charge observed at the probe, once per context length.
 *
 *        Word-12 value used for the 384 path (concrete, never symbolic — the same price-point
 *        rationale as the parent's §CF header): the GasParams DEFAULTS that `_gpRaw()` substitutes
 *        for an unset slot (MIN_POST_OP_GAS 200_000 | SETTLE_GAS_BOUND 160_000 << 32 |
 *        C_WRAP_GAS 5_000 << 64 | C_POSTOP_GAS 175_000 << 96), i.e. exactly what a fresh rc.2 proxy
 *        emits, with a fee snapshot of 500 bps (encoded 501 << 128) — deliberately DIFFERENT from the
 *        pinned live fee (1000) so the snapshot branch (`feeSnap - 1`), not the live-fee fallback,
 *        is the one exercised. That the snapshot fee is actually the one charged is asserted
 *        concretely (exact charge) by `contracts/test/v2/SuperPaymasterCtxLengthRc2.t.sol`.
 *
 *        `check_*` functions are Halmos-only; forge ignores them.
 */
contract SuperPaymasterI9Rc2HalmosTest is SuperPaymasterI9HalmosTest {
    uint256 internal constant SNAP_FEE_BPS = 500; // != pinned live PROTOCOL_FEE_BPS (1000)
    uint256 internal constant GAS_SNAP_WORD =
        200_000 | (uint256(160_000) << 32) | (uint256(5_000) << 64) | (uint256(175_000) << 96)
            | ((SNAP_FEE_BPS + 1) << 128);

    /// @dev rc.2's emitted shape: the parent's 352-byte context ‖ word 12.
    function _context384(
        address token, address user, uint256 a0, bytes32 opHash, address operator, uint8 mode,
        uint128 callGas, uint128 postOpGas
    ) internal pure returns (bytes memory) {
        return bytes.concat(_context(token, user, a0, opHash, operator, mode, callGas, postOpGas), bytes32(GAS_SNAP_WORD));
    }

    // =========================================================================================
    // CF-3 over the 384-byte fee-snapshot context. Body = parent's check_I9_CF3_settleCannotSilentlyFail
    // with ONLY the context builder swapped (_context -> _context384); same W-A0 / W-GASBOUND
    // preconditions, same W-GAS carve-out, same bits 0/3/4/5/6/7. Expected: PASS.
    // =========================================================================================
    function check_I9_CF3ctx384_settleCannotSilentlyFail(
        bool useBadToken, address user, uint256 a0, bytes32 opHash, address operator, uint8 mode,
        uint128 callGas, uint128 postOpGas, uint256 actualGasCost, uint256 actualFeePerGas
    ) external {
        require(a0 <= type(uint128).max); // W-A0
        require(actualGasCost <= 1e24 && actualFeePerGas <= 1e24); // W-GASBOUND
        _setSettled(opHash, false); // precondition: fresh op
        address token = useBadToken ? address(probeBad) : address(probeGood);
        OpSnap memory before = _snap(operator, user, opHash);

        bytes memory ctx = _context384(token, user, a0, opHash, operator, mode, callGas, postOpGas);
        bool ok = _callPostOp(ctx, actualGasCost, actualFeePerGas);

        uint256 bad;
        if (useBadToken) {
            if (ok) bad |= 1 << 0; // CF3-a: a reverting settlement must revert postOp
        } else {
            if (!ok) return; // W-GAS carve-out (see parent)
            bool reachedProbe = mode == MODE_BALANCE ? probeGood.lockedCalled(opHash) : probeGood.creditCalled(opHash);
            uint256 probeCharge = mode == MODE_BALANCE ? probeGood.lockedCharge(opHash) : probeGood.creditCharge(opHash);
            if (!reachedProbe) bad |= 1 << 3; // CF3-d
            if (probeCharge > a0) bad |= 1 << 4; // L9-CLAMP
            OpSnap memory aft = _snap(operator, user, opHash);
            if (uint256(aft.aPNTsBalance) != uint256(before.aPNTsBalance) + (a0 - probeCharge)) bad |= 1 << 5;
            if (aft.protocolRevenue != before.protocolRevenue + probeCharge) bad |= 1 << 6;
            if (!aft.settled) bad |= 1 << 7;
        }
        emit log_named_uint("CF3ctx384_bad", bad);
        assert(bad == 0);
    }

    // =========================================================================================
    // Positive-amount reachability witnesses (expected: FAIL with a counterexample). Each proves
    // the CF-3 "good settle" branch is reachable with something actually settled: postOp returns,
    // the probe's settleLocked was called, a0 > 0 and the charge it received is > 0. Inputs:
    // a0 / user / opHash / operator / callGas / postOpGas symbolic; actualGasCost and
    // actualUserOpFeePerGas CONCRETE (1e12 wei, 1 gwei) — a witness needs one model, and pinning
    // the two multiplicands removes the symbolic mulDiv chain that made the parent witness spend
    // 2864 s of its 2881 s in model generation (data/halmos-i9/all-checks-final.log). With these
    // values the unclamped charge is strictly positive, so `charge > 0` is decided by a0 alone.
    // =========================================================================================
    uint256 internal constant W_GAS_COST = 1e12;
    uint256 internal constant W_FEE_PER_GAS = 1 gwei;

    function check_witness_I9_posCharge352Reachable(
        address user, uint256 a0, bytes32 opHash, address operator, uint128 callGas, uint128 postOpGas
    ) external {
        require(a0 > 0 && a0 <= type(uint128).max); // positive amount + W-A0
        require(callGas <= 1e7 && postOpGas <= 1e7); // realistic uint32-range gas limits
        _setSettled(opHash, false);
        bytes memory ctx = _context(address(probeGood), user, a0, opHash, operator, MODE_BALANCE, callGas, postOpGas);
        bool ok = _callPostOp(ctx, W_GAS_COST, W_FEE_PER_GAS);
        assert(!(ok && probeGood.lockedCalled(opHash) && probeGood.lockedCharge(opHash) > 0));
    }

    function check_witness_I9_posCharge384Reachable(
        address user, uint256 a0, bytes32 opHash, address operator, uint128 callGas, uint128 postOpGas
    ) external {
        require(a0 > 0 && a0 <= type(uint128).max);
        require(callGas <= 1e7 && postOpGas <= 1e7);
        _setSettled(opHash, false);
        bytes memory ctx = _context384(address(probeGood), user, a0, opHash, operator, MODE_BALANCE, callGas, postOpGas);
        bool ok = _callPostOp(ctx, W_GAS_COST, W_FEE_PER_GAS);
        assert(!(ok && probeGood.lockedCalled(opHash) && probeGood.lockedCharge(opHash) > 0));
    }
}
