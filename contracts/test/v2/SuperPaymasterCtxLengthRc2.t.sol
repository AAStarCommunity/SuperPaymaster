// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import { I9SettleProbe } from "../halmos/SuperPaymasterI9Halmos.t.sol";

/**
 * @title rc.2 postOp context-length + 384-byte fee-snapshot regressions (DSR CC-125 d030f6e8)
 * @dev   Pins v5.5.0-rc.2's postOp context contract (SuperPaymaster.sol postOp):
 *          length 0           -> strict no-op return
 *          length 352 / 384   -> accepted (352 = legacy 5.5.0 rules, 384 = word-12 snapshot)
 *          any other length   -> revert InvalidContextLength(), BEFORE the gas guard and decode
 *        Neighbours 351/353/383/385 are asserted to hit exactly that selector; 352/384 are the
 *        positive controls (same harness, same probe, must settle) so a "rejects everything"
 *        regression cannot pass the negative half. Also: the full-domain fuzz substitute for
 *        `check_I9_CF3ctx384_settleCannotSilentlyFail`, and an exact-charge check proving the
 *        384 path charges the SNAPSHOT fee, not live `protocolFeeBPS`.
 */
contract SuperPaymasterCtxLengthRc2Test is Test {
    uint256 internal constant S_STATUS = 1;
    uint256 internal constant S_OPERATORS = 5;
    uint256 internal constant S_PROTOCOL_FEE_BPS = 13;
    uint256 internal constant S_SETTLED_DEBT_OPS = 33;
    uint256 internal constant NOT_ENTERED = 1;
    uint256 internal constant MAX_PROTOCOL_FEE = 2000;
    uint256 internal constant LIVE_FEE_BPS = 1000;
    uint256 internal constant SNAP_FEE_BPS = 500;
    uint256 internal constant GP_DEFAULTS =
        200_000 | (uint256(160_000) << 32) | (uint256(5_000) << 64) | (uint256(175_000) << 96);

    uint8 internal constant MODE_BALANCE = 1;
    int256 internal constant PRICE = 2000e8;
    uint8 internal constant DECIMALS = 8;
    uint256 internal constant A_PRICE_USD = 0.02 ether;

    address internal constant ENTRYPOINT_ADDR = address(0xE717070717070717070717070717070717070E);
    address internal constant DUMMY_REGISTRY = address(0xBEEF00000000000000000000000000000BEEF0);
    address internal constant DUMMY_FEED = address(0xFEED00000000000000000000000000000FEED0);
    address internal constant USER = address(0xA11CE);
    address internal constant OPERATOR = address(0x0FE7);

    SuperPaymaster internal sp;
    I9SettleProbe internal probeGood;
    I9SettleProbe internal probeBad;

    function setUp() public {
        sp = new SuperPaymaster(IEntryPoint(ENTRYPOINT_ADDR), IRegistry(DUMMY_REGISTRY), DUMMY_FEED);
        probeGood = new I9SettleProbe(false);
        probeBad = new I9SettleProbe(true);
        vm.store(address(sp), bytes32(S_STATUS), bytes32(NOT_ENTERED));
        vm.store(address(sp), bytes32(S_PROTOCOL_FEE_BPS), bytes32(LIVE_FEE_BPS));
    }

    function _settled(bytes32 opHash) internal view returns (bool) {
        return uint256(vm.load(address(sp), keccak256(abi.encode(opHash, S_SETTLED_DEBT_OPS)))) != 0;
    }

    function _ctx352(address token, uint256 a0, bytes32 opHash, uint8 mode, uint128 callGas, uint128 postOpGas)
        internal pure returns (bytes memory)
    {
        return abi.encode(token, USER, a0, opHash, OPERATOR, mode, callGas, postOpGas, PRICE, DECIMALS, A_PRICE_USD);
    }

    function _ctx384(address token, uint256 a0, bytes32 opHash, uint8 mode, uint128 callGas, uint128 postOpGas, uint256 feeSnapEnc)
        internal pure returns (bytes memory)
    {
        return bytes.concat(_ctx352(token, a0, opHash, mode, callGas, postOpGas), bytes32(GP_DEFAULTS | (feeSnapEnc << 128)));
    }

    /// @dev Resizes a well-formed context: truncate, or append zero bytes.
    function _resize(bytes memory ctx, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        uint256 n = ctx.length < len ? ctx.length : len;
        for (uint256 i; i < n; ++i) out[i] = ctx[i];
    }

    function _postOp(bytes memory ctx, uint256 gasCost, uint256 feePerGas) internal returns (bool ok, bytes memory ret) {
        vm.prank(ENTRYPOINT_ADDR);
        (ok, ret) = address(sp).call(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, gasCost, feePerGas))
        );
    }

    // ---------------------------------------------------------------- lengths ----

    function _assertRejected(uint256 len) internal {
        bytes32 opHash = keccak256(abi.encode("len", len));
        // derive from the 384 form so every byte up to min(len,384) is a valid, settleable context
        bytes memory ctx = _resize(_ctx384(address(probeGood), 1e18, opHash, MODE_BALANCE, 100_000, 100_000, SNAP_FEE_BPS + 1), len);
        assertEq(ctx.length, len, "fixture length");
        uint256 revBefore = sp.protocolRevenue();
        (bool ok, bytes memory ret) = _postOp(ctx, 1e12, 1 gwei);
        assertFalse(ok, "malformed length must revert");
        assertEq(ret, abi.encodeWithSelector(SuperPaymasterStorage.InvalidContextLength.selector), "exact error");
        assertFalse(probeGood.lockedCalled(opHash), "no settlement attempted");
        assertFalse(_settled(opHash), "not marked settled");
        assertEq(sp.protocolRevenue(), revBefore, "no revenue");
    }

    function _assertAccepted(bytes memory ctx, bytes32 opHash) internal {
        (bool ok, ) = _postOp(ctx, 1e12, 1 gwei);
        assertTrue(ok, "well-formed length must settle");
        assertTrue(probeGood.lockedCalled(opHash), "settlement reached");
        assertGt(probeGood.lockedCharge(opHash), 0, "positive charge");
        assertTrue(_settled(opHash), "marked settled");
    }

    function test_ctxLen351_rejected() public { _assertRejected(351); }
    function test_ctxLen353_rejected() public { _assertRejected(353); }
    function test_ctxLen383_rejected() public { _assertRejected(383); }
    function test_ctxLen385_rejected() public { _assertRejected(385); }

    function test_ctxLen352_accepted_positiveControl() public {
        bytes32 h = keccak256("352");
        _assertAccepted(_ctx352(address(probeGood), 1e18, h, MODE_BALANCE, 100_000, 100_000), h);
    }

    function test_ctxLen384_accepted_positiveControl() public {
        bytes32 h = keccak256("384");
        _assertAccepted(_ctx384(address(probeGood), 1e18, h, MODE_BALANCE, 100_000, 100_000, SNAP_FEE_BPS + 1), h);
    }

    function test_ctxLen0_noop() public {
        uint256 revBefore = sp.protocolRevenue();
        (bool ok, ) = _postOp("", 1e12, 1 gwei);
        assertTrue(ok);
        assertEq(sp.protocolRevenue(), revBefore);
    }

    /// @dev Every length in [1, 448] other than 352/384 is rejected with the exact selector.
    function testFuzz_ctxLen_onlyTwoAccepted(uint16 lenRaw) public {
        uint256 len = bound(uint256(lenRaw), 1, 448);
        vm.assume(len != 352 && len != 384);
        _assertRejected(len);
    }

    // ------------------------------------- witness counterexample replays ----
    // The halmos runs of check_witness_I9_posCharge{352,384}Reachable (archived under
    // docs/design/aoa-balance-mode/data/i9-rc2-testonly/) printed counterexamples before the 600 s
    // wall cap ended them; the RUN verdict stays INCONCLUSIVE. These tests replay the first model
    // each printed (all other params 0) on a concrete zero pre-state with the witness's exact
    // inputs (actualGasCost 1e12, fee 1 gwei, MODE_BALANCE, probeGood), and assert the witness's
    // negated predicate: postOp returns, settleLocked was reached, a0 > 0 and charge > 0.

    function _replayWitness(uint256 a0, bool ctx384) internal {
        bytes memory c = abi.encode(
            address(probeGood), address(0), a0, bytes32(0), address(0), MODE_BALANCE, uint128(0), uint128(0),
            PRICE, DECIMALS, A_PRICE_USD
        );
        if (ctx384) c = bytes.concat(c, bytes32(GP_DEFAULTS | ((SNAP_FEE_BPS + 1) << 128)));
        (bool ok, ) = _postOp(c, 1e12, 1 gwei);
        assertTrue(ok, "replay: postOp returned");
        assertTrue(probeGood.lockedCalled(bytes32(0)), "replay: settleLocked reached");
        assertGt(a0, 0, "replay: a0 > 0");
        assertGt(probeGood.lockedCharge(bytes32(0)), 0, "replay: charge > 0");
        assertLe(probeGood.lockedCharge(bytes32(0)), a0, "replay: clamp");
    }

    function test_replay_witness_posCharge352_halmosModel() public { _replayWitness(0x2000000000000000, false); }
    function test_replay_witness_posCharge384_halmosModel() public { _replayWitness(0x10000000000000000, true); }

    // ------------------------------------------------------- 384 fee snapshot ----

    /// @dev Exact charge, recomputed from rc.2's formula with the parameters each path must use.
    function _expectedCharge(uint256 a0, uint256 gasCost, uint256 feePerGas, uint128 callGas, uint128 postOpGas, bool snap, uint256 feeBps)
        internal pure returns (uint256 c)
    {
        uint256 bufGas = snap ? 175_000 + 5_000 : uint256(postOpGas) + 30_000;
        uint256 bufWei = (bufGas + Math.ceilDiv((uint256(callGas) + postOpGas) * 10, 100)) * feePerGas;
        uint256 aGas = Math.mulDiv((gasCost + bufWei) * uint256(PRICE), 1e18, (10 ** uint256(DECIMALS)) * A_PRICE_USD, Math.Rounding.Ceil);
        c = Math.mulDiv(aGas, 10_000 + feeBps, 10_000, Math.Rounding.Ceil);
        if (c > a0) c = a0;
    }

    function test_ctx384_chargesSnapshotFee_notLiveFee() public {
        bytes32 h384 = keccak256("fee384");
        bytes32 h352 = keccak256("fee352");
        uint256 a0 = 1e24;
        _postOp(_ctx384(address(probeGood), a0, h384, MODE_BALANCE, 100_000, 100_000, SNAP_FEE_BPS + 1), 1e12, 1 gwei);
        _postOp(_ctx352(address(probeGood), a0, h352, MODE_BALANCE, 100_000, 100_000), 1e12, 1 gwei);
        uint256 c384 = probeGood.lockedCharge(h384);
        uint256 c352 = probeGood.lockedCharge(h352);
        assertEq(c384, _expectedCharge(a0, 1e12, 1 gwei, 100_000, 100_000, true, SNAP_FEE_BPS), "384: snapshot fee + snapshot buffer");
        assertEq(c352, _expectedCharge(a0, 1e12, 1 gwei, 100_000, 100_000, false, LIVE_FEE_BPS), "352: live fee + legacy buffer");
        // discriminating control: the snapshot charge must differ from what the live fee would give
        assertTrue(c384 != _expectedCharge(a0, 1e12, 1 gwei, 100_000, 100_000, true, LIVE_FEE_BPS), "snapshot fee distinguishable");
    }

    /// @dev Word 12 with fee bits 0 (a 384-byte context emitted before the fee snapshot) -> live fee.
    function test_ctx384_zeroFeeBits_fallsBackToLiveFee() public {
        bytes32 h = keccak256("fee384zero");
        _postOp(_ctx384(address(probeGood), 1e24, h, MODE_BALANCE, 100_000, 100_000, 0), 1e12, 1 gwei);
        assertEq(probeGood.lockedCharge(h), _expectedCharge(1e24, 1e12, 1 gwei, 100_000, 100_000, true, LIVE_FEE_BPS));
    }

    /// @dev Full-domain fuzz substitute for check_I9_CF3ctx384_settleCannotSilentlyFail (no
    ///      W-GASBOUND; fee snapshot fuzzed over [0, MAX_PROTOCOL_FEE]; same assertions).
    function testFuzz_I9_CF3ctx384_settleCannotSilentlyFail(
        bool useBadToken, uint128 a0, bytes32 opHash, uint8 mode, uint128 callGas, uint128 postOpGas,
        uint256 actualGasCost, uint256 actualFeePerGas, uint128 startingBalance, uint16 feeSnapRaw
    ) external {
        uint256 feeSnap = bound(uint256(feeSnapRaw), 0, MAX_PROTOCOL_FEE);
        startingBalance = uint128(bound(uint256(startingBalance), 0, 1e30));
        vm.store(address(sp), keccak256(abi.encode(OPERATOR, S_OPERATORS)), bytes32(uint256(startingBalance)));
        address token = useBadToken ? address(probeBad) : address(probeGood);
        uint256 revBefore = sp.protocolRevenue();
        (uint128 balBefore, , , , , , , , ) = sp.operators(OPERATOR);
        assertEq(balBefore, startingBalance, "setup sanity");

        (bool ok, ) = _postOp(_ctx384(token, a0, opHash, mode, callGas, postOpGas, feeSnap + 1), actualGasCost, actualFeePerGas);
        if (useBadToken) {
            assertFalse(ok, "I9 (384): a reverting settlement must not let postOp succeed");
        } else if (ok) {
            bool reached = mode == MODE_BALANCE ? probeGood.lockedCalled(opHash) : probeGood.creditCalled(opHash);
            uint256 charge = mode == MODE_BALANCE ? probeGood.lockedCharge(opHash) : probeGood.creditCharge(opHash);
            assertTrue(reached, "I9 (384): success without reaching the token");
            assertLe(charge, a0, "L9-CLAMP (384)");
            (uint128 balAfter, , , , , , , , ) = sp.operators(OPERATOR);
            assertEq(uint256(balAfter), uint256(balBefore) + (uint256(a0) - charge), "I9 (384): refund a0 - charge");
            assertEq(sp.protocolRevenue(), revBefore + charge, "I9 (384): revenue += charge");
            assertTrue(_settled(opHash), "I9 (384): settled flag");
        }
    }
}
