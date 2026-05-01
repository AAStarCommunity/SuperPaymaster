// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

/// @title  xPNTs Spender Rate Limit (P0-8 / B4-H2 / D8)
/// @notice T-14: a compromised auto-approved spender (e.g. facilitator) could
///         iterate `burn(victim_i, MAX_SINGLE_TX_LIMIT)` across many holders
///         and drain unbounded value before the community detects + revokes.
///         D8 fixes this with a per-spender daily burn cap (default 15_000
///         ether xPNTs ≈ $300 @ $0.02/xPNTs). User burden remains 0:
///         autoApproved spenders still skip allowance gas, but their
///         cumulative burn-out is now bounded.
contract xPNTs_SpenderRateLimitTest is Test {
    xPNTsToken token;

    address community   = address(0xCAFE);
    address paymaster   = address(0xBABE);
    address facilitator = address(0xFAFA);   // autoApproved spender
    address attacker    = address(0xBADD);   // NOT autoApproved
    address otherFacil  = address(0xFEED);   // separate autoApproved spender
    address user        = address(0xA1);
    address user2       = address(0xA2);
    address user3       = address(0xA3);

    function setUp() public {
        xPNTsToken impl = new xPNTsToken();
        token = xPNTsToken(Clones.clone(address(impl)));

        // Test contract becomes FACTORY (msg.sender of initialize).
        token.initialize("Demo", "dPNTs", community, "Demo", "demo.eth", 1e18, 0);
        token.setSuperPaymasterAddress(paymaster);

        // Mint ample balances to the victims.
        token.mint(user,  1_000_000 ether);
        token.mint(user2, 1_000_000 ether);
        token.mint(user3, 1_000_000 ether);

        // Register two autoApproved facilitators.
        token.addAutoApprovedSpender(facilitator);
        token.addAutoApprovedSpender(otherFacil);
    }

    // ------------------------------------------------------------------
    // Default cap & getter
    // ------------------------------------------------------------------

    function test_DefaultDailyCap_Is15kEther() public {
        // P0-8 Option A: default changed from 50_000 ether to 15_000 ether (~$300 @ $0.02/xPNT)
        assertEq(token.spenderDailyCapTokens(), 15_000 ether, "default cap");
    }

    // ------------------------------------------------------------------
    // B4-H2 regression: non-autoApproved spender MUST have allowance even
    // when calling the burn(address,uint256) overload.
    // ------------------------------------------------------------------

    function test_BurnAddressUint_EnforcesAllowance() public {
        // attacker has no allowance from `user` and is NOT autoApproved.
        vm.prank(attacker);
        vm.expectRevert(xPNTsToken.BurnExceedsAllowance.selector);
        token.burn(user, 100 ether);

        // After user explicitly approves, the burn proceeds and consumes
        // the allowance like a standard ERC20 spender.
        vm.prank(user);
        token.approve(attacker, 200 ether);

        vm.prank(attacker);
        token.burn(user, 150 ether);

        assertEq(token.balanceOf(user), 1_000_000 ether - 150 ether);
        assertEq(token.allowance(user, attacker), 50 ether, "allowance must decrement");

        // Re-attempting beyond remaining allowance reverts.
        vm.prank(attacker);
        vm.expectRevert(xPNTsToken.BurnExceedsAllowance.selector);
        token.burn(user, 100 ether);
    }

    // ------------------------------------------------------------------
    // Daily cap: blocks autoApproved spender once total exceeds cap.
    // ------------------------------------------------------------------

    function test_SpenderDailyCap_BlocksWhenExceeded() public {
        // Tighten the cap to MAX_SINGLE_TX_LIMIT so we hit the wall in 1 tx.
        vm.prank(community);
        token.setSpenderDailyCap(5_000 ether); // == MAX_SINGLE_TX_LIMIT

        // First burn at the cap: succeeds (sums to exactly 5_000 ether)
        vm.prank(facilitator);
        token.burn(user, 5_000 ether);

        // Second burn — even of 1 wei — should bust the cap.
        vm.prank(facilitator);
        vm.expectRevert(
            abi.encodeWithSelector(
                xPNTsToken.SpenderDailyCapExceeded.selector,
                facilitator,
                1,
                0
            )
        );
        token.burn(user2, 1);
    }

    // ------------------------------------------------------------------
    // Window resets after 24h.
    // ------------------------------------------------------------------

    function test_SpenderDailyCap_ResetsAfter24h() public {
        vm.prank(community);
        token.setSpenderDailyCap(1_000 ether);

        vm.prank(facilitator);
        token.burn(user, 1_000 ether); // exhaust window

        // Immediately attempting more reverts.
        vm.prank(facilitator);
        vm.expectRevert();
        token.burn(user, 1);

        // Warp past the 1-day window — counter rolls over.
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(facilitator);
        token.burn(user, 1_000 ether); // OK in fresh window

        // Verify storage state reflects the new window.
        (uint128 dailyTotal, uint64 windowStart, ) = token.spenderRateLimit(facilitator);
        assertEq(dailyTotal, 1_000 ether, "fresh window total");
        assertEq(uint256(windowStart), block.timestamp);
    }

    // ------------------------------------------------------------------
    // Community owner can update the cap.
    // ------------------------------------------------------------------

    function test_SpenderDailyCap_ConfigurableByCommunity() public {
        // Non-community caller is rejected.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, attacker));
        token.setSpenderDailyCap(123);

        // Community owner succeeds.
        vm.prank(community);
        token.setSpenderDailyCap(123 ether);
        assertEq(token.spenderDailyCapTokens(), 123 ether);
    }

    // ------------------------------------------------------------------
    // Self-burn is NOT routed through the rate limit (user has full
    // custody of their own balance).
    // ------------------------------------------------------------------

    function test_SelfBurn_NotRateLimited() public {
        // Tighten cap to 1 wei — would immediately fail any third-party burn.
        vm.prank(community);
        token.setSpenderDailyCap(1);

        // Self-burn arbitrary amount: still fine.
        vm.prank(user);
        token.burn(100_000 ether);
        assertEq(token.balanceOf(user), 1_000_000 ether - 100_000 ether);

        // Spender mapping for `user` was NOT touched.
        (uint128 dailyTotal, uint64 windowStart, ) = token.spenderRateLimit(user);
        assertEq(dailyTotal, 0);
        assertEq(uint256(windowStart), 0);
    }

    // ------------------------------------------------------------------
    // Different spenders share NO state — each gets its own daily budget.
    // ------------------------------------------------------------------

    function test_DifferentSpenders_HaveIndependentCaps() public {
        vm.prank(community);
        token.setSpenderDailyCap(2_000 ether);

        // facilitator burns 2_000 ether — its window is exhausted.
        vm.prank(facilitator);
        token.burn(user, 2_000 ether);

        // facilitator can no longer burn.
        vm.prank(facilitator);
        vm.expectRevert();
        token.burn(user, 1);

        // BUT otherFacil (different spender) still has a fresh budget.
        vm.prank(otherFacil);
        token.burn(user2, 2_000 ether);

        (uint128 facTotal,,) = token.spenderRateLimit(facilitator);
        (uint128 otherTotal,,) = token.spenderRateLimit(otherFacil);
        assertEq(facTotal, 2_000 ether);
        assertEq(otherTotal, 2_000 ether);
    }

    // ------------------------------------------------------------------
    // Sanity: under default cap, autoApproved facilitator can still burn
    // a normal amount, and the counter accumulates correctly.
    // ------------------------------------------------------------------

    function test_AutoApproved_AccumulatesAcrossCalls() public {
        // Default cap = 15_000 ether. Burn 4_000 ether from each of 3 holders.
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(facilitator);
            address victim = i == 0 ? user : (i == 1 ? user2 : user3);
            token.burn(victim, 4_000 ether);
        }
        (uint128 total,,) = token.spenderRateLimit(facilitator);
        assertEq(total, 12_000 ether, "cumulative across holders");
    }

    // ------------------------------------------------------------------
    // Once cap hit, even an explicit-allowance non-autoApproved spender
    // is also bounded (the rate limit applies uniformly).
    // ------------------------------------------------------------------

    function test_RateLimit_AppliesToExplicitlyApprovedSpenders() public {
        vm.prank(community);
        token.setSpenderDailyCap(500 ether);

        // user explicitly approves attacker for plenty
        vm.prank(user);
        token.approve(attacker, 10_000 ether);

        vm.prank(attacker);
        token.burn(user, 500 ether); // exhaust attacker's window

        vm.prank(attacker);
        vm.expectRevert();
        token.burn(user, 1);
    }
}
