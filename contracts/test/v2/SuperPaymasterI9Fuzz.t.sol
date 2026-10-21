// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import { I9SettleProbe } from "../halmos/SuperPaymasterI9Halmos.t.sol";

/**
 * @title D5c-2 · I9 fuzz substitute — the unbounded-uint256 tail of check_I9_CF3_settleCannotSilentlyFail
 * @dev   `contracts/test/halmos/SuperPaymasterI9Halmos.t.sol`'s Halmos proof bounds
 *        `actualGasCost` / `actualUserOpFeePerGas` to <= 1e24 (W-GASBOUND) because postOp's chained
 *        `Math.mulDiv`/`ceilDiv` over fully-symbolic ~2^256-wide operands does not resolve for the
 *        solver in reasonable time even with price/decimals/aPriceUSD/protocolFeeBPS concrete. This
 *        file is the named fuzz substitute for that bound (D5c-1 §2.6 "BOUNDED + fuzz" convention):
 *        it re-asserts the SAME CF3 properties over the FULL uint256 domain (plus a fuzzed, not
 *        pinned, `protocolFeeBPS` within its real enforced range [0, MAX_PROTOCOL_FEE] — strictly
 *        more general than the Halmos harness's single concrete price point on that one dimension).
 *        Not a Halmos harness: this is a plain forge fuzz test (`forge test`), reusing
 *        `I9SettleProbe` from the Halmos file for the exact same settle-outcome mocking.
 */
contract SuperPaymasterI9FuzzTest is Test {
    uint256 internal constant S_STATUS = 1;
    uint256 internal constant S_OPERATORS = 5;
    uint256 internal constant S_PROTOCOL_FEE_BPS = 13;
    uint256 internal constant S_SETTLED_DEBT_OPS = 33;
    uint256 internal constant NOT_ENTERED = 1;
    uint256 internal constant MAX_PROTOCOL_FEE = 2000;

    uint8 internal constant MODE_BALANCE = 1;
    int256 internal constant PRICE = 2000e8;
    uint8 internal constant DECIMALS = 8;
    uint256 internal constant A_PRICE_USD = 0.02 ether;

    address internal constant ENTRYPOINT_ADDR = address(0xE717070717070717070717070717070717070E);
    address internal constant DUMMY_REGISTRY = address(0xBEEF00000000000000000000000000000BEEF0);
    address internal constant DUMMY_FEED = address(0xFEED00000000000000000000000000000FEED0);

    SuperPaymaster internal sp;
    I9SettleProbe internal probeGood;
    I9SettleProbe internal probeBad;

    function setUp() public {
        sp = new SuperPaymaster(IEntryPoint(ENTRYPOINT_ADDR), IRegistry(DUMMY_REGISTRY), DUMMY_FEED);
        probeGood = new I9SettleProbe(false);
        probeBad = new I9SettleProbe(true);
        vm.store(address(sp), bytes32(S_STATUS), bytes32(NOT_ENTERED));
    }

    function _settledSlot(bytes32 opHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(opHash, S_SETTLED_DEBT_OPS));
    }

    function _isSettled(bytes32 opHash) internal view returns (bool) {
        return uint256(vm.load(address(sp), _settledSlot(opHash))) != 0;
    }

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

    /// @dev Mirrors `check_I9_CF3_settleCannotSilentlyFail`'s bit 0 (the I9 property proper) and,
    ///      on the good-token side, bits 3-7, over the FULL uint256 `actualGasCost` /
    ///      `actualUserOpFeePerGas` domain (no W-GASBOUND) plus a fuzzed `protocolFeeBPS` within its
    ///      real enforced range (no W-CF pin). `a0` stays bounded to `uint128` (fuzzer-enforced by
    ///      the parameter type) — that bound is W-A0 itself (a real invariant, not a convenience;
    ///      see the Halmos file), not something this test is substituting for.
    function testFuzz_I9_CF3_settleCannotSilentlyFail(
        bool useBadToken, address user, uint128 a0, bytes32 opHash, address operator, uint8 mode,
        uint128 callGas, uint128 postOpGas, uint256 actualGasCost, uint256 actualFeePerGas,
        uint128 startingBalance, uint16 feeBpsRaw
    ) external {
        vm.assume(operator != address(0) && operator != address(sp));
        uint256 feeBps = bound(uint256(feeBpsRaw), 0, MAX_PROTOCOL_FEE);
        vm.store(address(sp), bytes32(S_PROTOCOL_FEE_BPS), bytes32(feeBps));
        // Give the operator a starting aPNTsBalance well clear of uint128 overflow when refunded
        // (a0 - charge) — the overflow-revert path is a different, already-covered property (the
        // checked-arithmetic revert itself is safe; it is not a silent failure), not what this test
        // is targeting.
        startingBalance = uint128(bound(uint256(startingBalance), 0, 1e30));
        bytes32 opSlot = keccak256(abi.encode(operator, S_OPERATORS));
        vm.store(address(sp), opSlot, bytes32(uint256(startingBalance))); // slot0: aPNTsBalance|isConfigured|isPaused, rest 0
        vm.store(address(sp), _settledSlot(opHash), bytes32(uint256(0))); // fresh op

        address token = useBadToken ? address(probeBad) : address(probeGood);
        uint256 revBefore = sp.protocolRevenue();
        (uint128 balBefore, , , , , , , , ) = sp.operators(operator);
        assertEq(balBefore, startingBalance, "setup sanity: aPNTsBalance slot write landed where expected");

        bytes memory ctx = _context(token, user, a0, opHash, operator, mode, callGas, postOpGas);
        bool ok = _callPostOp(ctx, actualGasCost, actualFeePerGas);

        if (useBadToken) {
            assertFalse(ok, "I9 (fuzz): a reverting settlement call must not let postOp succeed");
        } else if (ok) {
            bool reachedProbe = mode == MODE_BALANCE
                ? probeGood.lockedCalled(opHash)
                : probeGood.creditCalled(opHash);
            uint256 probeCharge = mode == MODE_BALANCE
                ? probeGood.lockedCharge(opHash)
                : probeGood.creditCharge(opHash);
            assertTrue(reachedProbe, "I9 (fuzz): postOp succeeded without observably reaching the token");
            assertLe(probeCharge, a0, "L9-CLAMP (fuzz): charge passed to settlement must never exceed a0");
            (uint128 balAfter, , , , , , , , ) = sp.operators(operator);
            assertEq(
                uint256(balAfter), uint256(balBefore) + (uint256(a0) - probeCharge),
                "I9 (fuzz): operator refund must equal exactly a0 - charge"
            );
            assertEq(
                sp.protocolRevenue(), revBefore + probeCharge,
                "I9 (fuzz): protocolRevenue must increase by exactly the charge passed to settlement"
            );
            assertTrue(_isSettled(opHash), "I9 (fuzz): a completed fresh settlement must flip the settled flag");
        }
        // ok == false && !useBadToken: the W-GAS carve-out (an unrelated gas-guard revert, or here
        // also a uint128 accounting overflow at an extreme startingBalance/a0 combination) — no
        // assertion, exactly mirroring the Halmos harness's documented scope.
    }
}
