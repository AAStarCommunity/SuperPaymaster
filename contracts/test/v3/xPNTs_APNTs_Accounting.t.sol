// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

/**
 * @title xPNTs_APNTs_Accounting
 * @notice Unit tests for the unified aPNTs-denominated accounting in xPNTsToken.
 *         Covers: burnFromWithOpHash (ceil conversion), recordDebtWithOpHash (cross-path
 *         replay protection), transferFrom single-tx limit at non-1:1 rates,
 *         _requireRate zero-guard, auto-repay at various rates, and repayDebt math.
 */
contract xPNTs_APNTs_Accounting_Test is Test {
    using Clones for address;
    using stdStorage for StdStorage;

    xPNTsToken token;
    address admin    = address(0xA1);
    address user     = address(0xA2);
    address paymaster = address(0xA3);
    address other    = address(0xA4);

    uint256 constant RATE_1X   = 1e18;   // 1 xPNT = 1 aPNT  (1:1)
    uint256 constant RATE_2X   = 2e18;   // cheap xPNTs: 1 aPNT costs 2 xPNTs  → 1 xPNT = 0.5 aPNTs
    uint256 constant RATE_HALF = 5e17;   // expensive xPNTs: 1 aPNT costs 0.5 xPNTs → 1 xPNT = 2 aPNTs
    uint256 constant RATE_MAX  = 1e22;   // absolute maximum allowed

    function setUp() public {
        vm.startPrank(admin);
        address impl = address(new xPNTsToken());
        token = xPNTsToken(impl.clone());
        token.initialize("Points", "XP", admin, "Comm", "ens.eth", RATE_1X);
        token.setSuperPaymasterAddress(paymaster);
        vm.stopPrank();
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _setRate(uint256 rate) internal {
        stdstore.target(address(token)).sig("exchangeRate()").checked_write(rate);
    }

    function _mintTransfer(address to, uint256 amount) internal {
        vm.prank(admin);
        token.mint(other, amount);
        vm.prank(other);
        token.transfer(to, amount);
    }

    // ─── burnFromWithOpHash: aPNTs → xPNTs ceil conversion ───────────────────

    // rate=2e18 (cheap xPNTs): 10 aPNTs → 10*2=20 xPNTs burned (exact, no rounding)
    // Tests correct burn amount at integer-multiple rate; ceil == floor here.
    function test_BurnFromWithOpHash_HighRate_ExactConversion() public {
        _setRate(RATE_2X);
        vm.prank(admin);
        token.mint(user, 50 ether);

        uint256 balBefore = token.balanceOf(user);
        vm.prank(paymaster);
        token.burnFromWithOpHash(user, 10 ether, bytes32("op1"));

        assertEq(token.balanceOf(user), balBefore - 20 ether, "10 aPNTs at 2x rate = 20 xPNTs burned");
    }

    // rate=15e17 (1.5 xPNTs per aPNT), 3 wei aPNTs → ceil(3*15e17/1e18) = ceil(4.5) = 5 wei xPNTs burned
    // floor would give 4; ceil gives 5 — protocol never under-collects at fractional high rates.
    function test_BurnFromWithOpHash_HighFractionalRate_CeilRounding() public {
        _setRate(15e17); // 1.5 xPNTs per aPNT — high rate, non-integer ratio
        vm.prank(admin);
        token.mint(user, 50 ether);

        vm.prank(paymaster);
        token.burnFromWithOpHash(user, 3, bytes32("op_hceil")); // 3 wei aPNTs

        // floor(3*15e17/1e18)=4, ceil=5: the extra 1 wei xPNT is burned to avoid under-collection
        assertEq(token.balanceOf(user), 50 ether - 5, "ceil(3*1.5)=5 wei xPNTs burned, not floor=4");
    }

    // rate=5e17, 3 wei aPNTs → ceil(3*5e17/1e18) = ceil(1.5) = 2 wei xPNTs burned
    // Uses wei-level amounts to observe ceiling: 3*5e17 = 1.5e18, not divisible at sub-wei
    function test_BurnFromWithOpHash_LowRate_CeilConversion() public {
        _setRate(RATE_HALF);
        vm.prank(admin);
        token.mint(user, 50 ether);

        vm.prank(paymaster);
        token.burnFromWithOpHash(user, 3, bytes32("op2")); // 3 wei aPNTs

        // xPNTsToBurn = ceil(3 * 5e17 / 1e18) = ceil(1.5) = 2 wei
        assertEq(token.balanceOf(user), 50 ether - 2, "ceil(3*0.5)=2 wei xPNTs must be burned");
    }

    // rate=5e17, 2 aPNTs → exact division ceil(2*5e17/1e18) = 1 xPNT (no rounding up)
    function test_BurnFromWithOpHash_ExactDivision_NoRoundUp() public {
        _setRate(RATE_HALF);
        vm.prank(admin);
        token.mint(user, 50 ether);

        vm.prank(paymaster);
        token.burnFromWithOpHash(user, 2 ether, bytes32("op3"));

        assertEq(token.balanceOf(user), 49 ether, "exact division: ceil(1.0)=1 xPNT");
    }

    // amountAPNTs > maxSingleTxLimit → SingleTxLimitExceeded
    function test_BurnFromWithOpHash_ExceedsMaxLimit_Reverts() public {
        vm.prank(admin);
        token.mint(user, 100_000 ether);

        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.SingleTxLimitExceeded.selector));
        token.burnFromWithOpHash(user, 5_001 ether, bytes32("op4"));
    }

    // ─── recordDebtWithOpHash ─────────────────────────────────────────────────

    function test_RecordDebtWithOpHash_Success() public {
        bytes32 opHash = bytes32("op10");
        vm.prank(paymaster);
        token.recordDebtWithOpHash(user, 100 ether, opHash);

        assertEq(token.getDebt(user), 100 ether, "Debt must be 100 aPNTs");
        assertTrue(token.usedDebtHashes(opHash), "opHash must be marked used");
    }

    // same opHash twice via recordDebtWithOpHash → DebtAlreadyRecorded
    function test_RecordDebtWithOpHash_ReplayPrevented() public {
        bytes32 opHash = bytes32("op11");
        vm.prank(paymaster);
        token.recordDebtWithOpHash(user, 5 ether, opHash);

        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.DebtAlreadyRecorded.selector, opHash));
        token.recordDebtWithOpHash(user, 5 ether, opHash);
    }

    // burn path used opHash → recordDebtWithOpHash must revert (cross-path protection)
    function test_CrossPath_BurnBlocksDebt() public {
        bytes32 opHash = bytes32("op12");
        vm.prank(admin);
        token.mint(user, 50 ether);

        vm.prank(paymaster);
        token.burnFromWithOpHash(user, 1 ether, opHash);

        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.DebtAlreadyRecorded.selector, opHash));
        token.recordDebtWithOpHash(user, 1 ether, opHash);
    }

    // debt path used opHash → burnFromWithOpHash must revert (cross-path protection)
    function test_CrossPath_DebtBlocksBurn() public {
        bytes32 opHash = bytes32("op13");
        vm.prank(admin);
        token.mint(user, 50 ether);

        vm.prank(paymaster);
        token.recordDebtWithOpHash(user, 1 ether, opHash);

        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.OperationAlreadyProcessed.selector, opHash));
        token.burnFromWithOpHash(user, 1 ether, opHash);
    }

    // ─── transferFrom: single-tx limit uses aPNTs after conversion ───────────

    // rate=5e17 means 1 xPNT = 1e18/5e17 = 2 aPNTs (expensive xPNTs).
    // transferFrom 3000 ether xPNTs → aPNT equiv = 3000e18*1e18/5e17 = 6000e18 > 5000e18 → revert
    function test_SingleTxLimit_ExpensiveXPNTs_Reverts() public {
        _setRate(RATE_HALF); // 1 xPNT = 2 aPNTs
        vm.prank(admin);
        token.mint(user, 10_000 ether);

        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.SingleTxLimitExceeded.selector));
        token.transferFrom(user, paymaster, 3_000 ether); // 6000 aPNTs equiv > 5000 limit
    }

    // rate=2e18 means 1 xPNT = 1e18/2e18 = 0.5 aPNTs (cheap xPNTs).
    // transferFrom 6000 ether xPNTs → aPNT equiv = 6000e18*1e18/2e18 = 3000e18 < 5000e18 → passes
    function test_SingleTxLimit_CheapXPNTs_Passes() public {
        _setRate(RATE_2X); // 1 xPNT = 0.5 aPNTs
        vm.prank(admin);
        token.mint(user, 10_000 ether);

        vm.prank(paymaster);
        token.transferFrom(user, paymaster, 6_000 ether); // 3000 aPNTs equiv < 5000 limit
        assertEq(token.balanceOf(paymaster), 6_000 ether, "6000 cheap xPNTs should transfer");
    }

    // ─── _requireRate(): zero rate reverts all callers ────────────────────────

    function test_RequireRate_Zero_BurnFromReverts() public {
        _setRate(0);
        vm.prank(admin);
        token.mint(user, 50 ether);

        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.ExchangeRateCannotBeZero.selector));
        token.burnFromWithOpHash(user, 1 ether, bytes32("op20"));
    }

    function test_RequireRate_Zero_RepayDebtReverts() public {
        _setRate(RATE_1X);
        vm.prank(paymaster);
        token.recordDebt(user, 5 ether);
        _mintTransfer(user, 10 ether);

        _setRate(0);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.ExchangeRateCannotBeZero.selector));
        token.repayDebt(1 ether);
    }

    function test_RequireRate_Zero_TransferFromReverts() public {
        vm.prank(admin);
        token.mint(user, 50 ether);
        _setRate(0);

        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.ExchangeRateCannotBeZero.selector));
        token.transferFrom(user, paymaster, 1 ether);
    }

    // rate=0 during mint to user who has debt → _requireRate() in _update reverts
    function test_RequireRate_Zero_MintWithDebtReverts() public {
        vm.prank(paymaster);
        token.recordDebt(user, 1 ether);
        _setRate(0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.ExchangeRateCannotBeZero.selector));
        token.mint(user, 1 ether);
    }

    // ─── Auto-repay (_update) at non-1:1 rates ────────────────────────────────

    // rate=2e18, debt=20 aPNTs, mint 8 xPNTs
    // mintedAPNTs = floor(8 * 1e18 / 2e18) = 4
    // repayAPNTs  = min(4, 20) = 4  → debt = 16
    // repayXPNTs  = ceil(4 * 2e18 / 1e18) = 8   → balance = 0
    function test_AutoRepay_HighRate_PartialMint() public {
        _setRate(RATE_2X);
        vm.prank(paymaster);
        token.recordDebt(user, 20 ether);

        vm.prank(admin);
        token.mint(user, 8 ether);

        assertEq(token.getDebt(user), 16 ether, "4 aPNTs repaid, 16 remaining");
        assertEq(token.balanceOf(user), 0, "all 8 minted xPNTs burned for repayment");
    }

    // rate=5e17 (expensive xPNTs): debt=5 wei aPNTs, mint=20 wei xPNTs
    // mintedAPNTs = floor(20 * 1e18 / 5e17) = 40 > debt(5) → repay all 5
    // repayXPNTs  = ceil(5 * 5e17 / 1e18) = ceil(2.5) = 3 wei xPNTs burned
    // balance = 20 - 3 = 17 wei
    function test_AutoRepay_LowRate_ExcessMint() public {
        _setRate(RATE_HALF);
        vm.prank(paymaster);
        token.recordDebt(user, 5); // 5 wei aPNTs

        vm.prank(admin);
        token.mint(user, 20); // 20 wei xPNTs

        assertEq(token.getDebt(user), 0, "debt fully repaid");
        assertEq(token.balanceOf(user), 17, "20 minted - 3 burned = 17 wei xPNTs");
    }

    // rate=1e22 (max): mintedAPNTs = floor(1 * 1e18 / 1e22) = 0 → no auto-repay
    function test_AutoRepay_MaxRate_SmallMint_NoRepay() public {
        _setRate(RATE_MAX);
        vm.prank(paymaster);
        token.recordDebt(user, 1);

        vm.prank(admin);
        token.mint(user, 1); // 1 wei xPNT → mintedAPNTs = 0

        assertEq(token.getDebt(user), 1, "debt unchanged: mintedAPNTs underflows to 0");
        assertEq(token.balanceOf(user), 1, "token not burned");
    }

    // ─── repayDebt: xPNTs → aPNTs floor conversion ───────────────────────────

    // rate=2e18 (cheap xPNTs): debt=10 wei aPNTs, repay 5 wei xPNTs
    // repaidAPNTs = floor(5 * 1e18 / 2e18) = floor(2.5) = 2 (floor drops 0.5)
    // debt = 10 - 2 = 8 wei aPNTs remaining; 5 wei xPNTs burned
    function test_RepayDebt_HighRate_FloorConversion() public {
        _setRate(RATE_2X);
        vm.prank(paymaster);
        token.recordDebt(user, 10); // 10 wei aPNTs
        _mintTransfer(user, 20);    // 20 wei xPNTs via transfer (no auto-repay)

        vm.prank(user);
        token.repayDebt(5); // 5 wei xPNTs → floor(2.5) = 2 aPNTs repaid

        assertEq(token.getDebt(user), 8, "5 wei xPNTs = 2 aPNTs repaid, 8 remaining");
        assertEq(token.balanceOf(user), 15, "5 wei xPNTs burned");
    }

    // repay more aPNTs than debt → RepayExceedsDebt
    function test_RepayDebt_ExceedsDebt_Reverts() public {
        _setRate(RATE_1X);
        vm.prank(paymaster);
        token.recordDebt(user, 3 ether);
        _mintTransfer(user, 10 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.RepayExceedsDebt.selector));
        token.repayDebt(5 ether); // 5 xPNTs = 5 aPNTs > 3 aPNTs debt
    }

    // ─── recordDebt: single-tx limit in aPNTs ────────────────────────────────

    function test_RecordDebt_ExceedsMaxLimit_Reverts() public {
        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.SingleTxLimitExceeded.selector));
        token.recordDebt(user, 5_001 ether);
    }

    function test_RecordDebtWithOpHash_ExceedsMaxLimit_Reverts() public {
        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.SingleTxLimitExceeded.selector));
        token.recordDebtWithOpHash(user, 5_001 ether, bytes32("op99"));
    }
}
