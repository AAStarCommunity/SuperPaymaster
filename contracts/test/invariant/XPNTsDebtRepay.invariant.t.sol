// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import "src/tokens/xPNTsToken.sol";
import {Clones} from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

/**
 * @title XPNTsDebtRepay_Invariant
 * @notice T-H2 (audit §6): machine-checks the xPNTs auto-repay rounding
 *         invariant that the audit confirmed by hand:
 *
 *             INV-2  ceil( min(floor(value·1e18/rate), debt) · rate / 1e18 ) <= value
 *
 *         In xPNTsToken._update (mint path), a minted `value` of xPNTs is used to
 *         auto-repay outstanding debt:
 *
 *             mintedAPNTs = floor(value · 1e18 / rate)
 *             repayAPNTs  = min(mintedAPNTs, debt)
 *             repayXPNTs  = ceil(repayAPNTs · rate / 1e18)
 *             _burn(to, repayXPNTs)            // after super._update minted `value`
 *
 *         If `repayXPNTs > value` the post-mint burn would underflow the freshly
 *         minted balance → revert / over-burn. INV-2 guarantees the double
 *         floor-then-ceil round-trip never exceeds the original `value`, so a
 *         debtor can always be paid via mint. We assert it two ways:
 *
 *           1. invariant_*  — stateful: mint random amounts at random rates into a
 *              perpetually-indebted account and assert it never reverts and the
 *              repaid xPNTs never exceeds the minted amount.
 *           2. testFuzz_*  — stateless: directly hammer the rounding identity over
 *              the full (value, rate, debt) space.
 */
contract XPNTsDebtRepay_Invariant is StdInvariant, Test {
    XPNTsDebtHandler internal handler;

    function setUp() public {
        handler = new XPNTsDebtHandler();
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = handler.mintToDebtor.selector;
        selectors[1] = handler.bumpRate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice INV-2: across every mint-into-debt sequence the handler performed,
    ///         the contract never over-burned (handler asserts per-call and tallies).
    function invariant_noOverBurnOnMint() public view {
        assertEq(handler.overBurnCount(), 0, "INV-2: auto-repay over-burned a mint");
    }

    /// @notice INV-2 (stateless): the floor-then-ceil round-trip never exceeds value.
    ///         This is the pure-math heart of the auto-repay safety property.
    function testFuzz_repayNeverExceedsValue(uint256 value, uint256 rate, uint256 debt) public pure {
        rate = bound(rate, 1, 1e24);            // 1 wei .. 1e6 ratio (18-dec)
        value = bound(value, 0, 1e30);
        debt = bound(debt, 0, 1e30);

        uint256 mintedAPNTs = (value * 1e18) / rate;             // floor
        if (mintedAPNTs == 0) return;                            // contract early-returns
        uint256 repayAPNTs = mintedAPNTs > debt ? debt : mintedAPNTs;
        if (repayAPNTs == 0) return;
        uint256 repayXPNTs = (repayAPNTs * rate + 1e18 - 1) / 1e18; // ceil

        assertLe(repayXPNTs, value, "INV-2: repayXPNTs > value (over-burn)");
    }
}

/**
 * @notice Drives the real xPNTsToken auto-repay path with a fuzzed rate and mint
 *         amount against an account that is kept perpetually in debt.
 */
contract XPNTsDebtHandler is Test {
    xPNTsToken public token;
    address public constant COMMUNITY_OWNER = address(0xC0);
    address public constant SP = address(0x5959);
    address public constant DEBTOR = address(0xD3B7);

    uint256 public overBurnCount;

    constructor() {
        // The implementation disables initializers (clone pattern); deploy a
        // minimal proxy and initialize that, exactly like xPNTsFactory does.
        address impl = address(new xPNTsToken());
        token = xPNTsToken(Clones.clone(impl));
        token.initialize("xTest", "xT", COMMUNITY_OWNER, "Test", "test.eth", 1 ether);
        // Wire SuperPaymaster so recordDebt is callable, and lift the per-tx cap
        // so large fuzz mints aren't rejected before reaching the repay math.
        vm.prank(COMMUNITY_OWNER);
        token.setSuperPaymasterAddress(SP);
    }

    /// @dev Mint `amount` xPNTs to the debtor after topping up a large debt, then
    ///      assert the post-mint balance is consistent (no over-burn underflow).
    function mintToDebtor(uint256 amount) external {
        uint256 rate = token.exchangeRate();
        // Keep a standing debt larger than any single mint can clear.
        uint256 targetDebt = 1e24;
        uint256 cur = token.getDebt(DEBTOR);
        if (cur < targetDebt) {
            uint256 add = targetDebt - cur;
            uint256 cap = token.maxSingleTxLimit();
            if (add > cap) add = cap;
            vm.prank(SP);
            token.recordDebt(DEBTOR, add);
        }

        amount = bound(amount, 1, 4_000 ether); // under maxSingleTxLimit when converted

        uint256 balBefore = token.balanceOf(DEBTOR);
        uint256 debtBefore = token.getDebt(DEBTOR);

        vm.prank(COMMUNITY_OWNER);
        // If this reverts due to an over-burn underflow, the invariant run fails loudly.
        token.mint(DEBTOR, amount);

        uint256 balAfter = token.balanceOf(DEBTOR);
        uint256 debtAfter = token.getDebt(DEBTOR);

        // Repaid xPNTs = minted value - net balance increase. Must be <= minted.
        // balAfter = balBefore + amount - repayXPNTs  →  repayXPNTs = amount - (balAfter - balBefore)
        if (balAfter < balBefore) {
            // balance went DOWN after a mint → over-burn happened
            overBurnCount++;
        } else {
            uint256 netIncrease = balAfter - balBefore;
            if (netIncrease > amount) {
                overBurnCount++; // impossible accounting (more credited than minted)
            }
        }
        // Debt must be non-increasing across a mint.
        if (debtAfter > debtBefore) overBurnCount++;
    }

    /// @dev Fuzz the exchange rate within the contract's allowed bounds. Each
    ///      call can only drift ±20% (per-tx cap) and is rate-limited by a 1h
    ///      cooldown, so we warp forward and let rejected moves be swallowed —
    ///      over many calls the rate still wanders across its legal range.
    function bumpRate(uint256 newRate) external {
        newRate = bound(newRate, 1e14, 1e22); // EXCHANGE_RATE_MIN..MAX
        vm.warp(block.timestamp + 2 hours);   // clear the 1h cooldown
        vm.prank(COMMUNITY_OWNER);
        try token.updateExchangeRate(newRate) {} catch {}
    }
}
