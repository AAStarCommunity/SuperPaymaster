// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

/// @title  AUDIT H-2 (2026-06-11) — transferFrom firewall parity with burn path
/// @notice A compromised autoApproved spender could pull holder funds to itself
///         via transferFrom(victim, self, amount) — functionally identical to
///         burn(victim, amount) — yet the P0-7 emergency halt and P0-8 daily
///         rate limit were wired only into the burn path. The fix applies both
///         guards to the self-pull case. These tests lock that in and prove the
///         normal settle path (to == SuperPaymaster) is unaffected.
contract xPNTs_AuditH2_TransferFromFirewallTest is Test {
    xPNTsToken token;

    address community   = address(0xCAFE);   // communityOwner (emergency authority)
    address paymaster   = address(0xBABE);   // SUPERPAYMASTER_ADDRESS
    address facilitator = address(0xFAFA);   // autoApproved spender (simulated-compromised)
    address user        = address(0xA1);
    address user2       = address(0xA2);

    function setUp() public {
        xPNTsToken impl = new xPNTsToken();
        token = xPNTsToken(Clones.clone(address(impl)));
        // Test contract becomes FACTORY (msg.sender of initialize). rate = 1:1.
        token.initialize("Demo", "dPNTs", community, "Demo", "demo.eth", 1e18);
        token.setSuperPaymasterAddress(paymaster);

        token.mint(user,  1_000_000 ether);
        token.mint(user2, 1_000_000 ether);
        token.addAutoApprovedSpender(facilitator);
    }

    // --- P0-7 parity: emergency switch halts the self-pull drain path ---
    function test_TransferFromSelf_HaltedByEmergency() public {
        vm.prank(community);
        token.emergencyRevokePaymaster(); // emergencyDisabled = true

        vm.prank(facilitator);
        vm.expectRevert(xPNTsToken.EmergencyStop.selector);
        token.transferFrom(user, facilitator, 100 ether);
    }

    // --- AUDIT 2026-07-04 (H-2 kill-switch gap): a non-SP autoApproved spender
    //     could bypass the emergency halt by routing the pull to the SP address
    //     (`to == SP`), because the halt was keyed on destination, not caller.
    //     After the fix the halt applies to EVERY non-SP caller regardless of
    //     destination, so a compromised facilitator can no longer force-move
    //     holder funds into the SP contract once the kill switch is flipped. ---
    function test_TransferFromToSuperPaymaster_HaltedByEmergency() public {
        vm.prank(community);
        token.emergencyRevokePaymaster(); // emergencyDisabled = true

        vm.prank(facilitator);
        vm.expectRevert(xPNTsToken.EmergencyStop.selector);
        token.transferFrom(user, paymaster, 100 ether);
    }

    // --- P0-8 parity: cumulative self-pull is bounded by the daily cap ---
    function test_TransferFromSelf_BoundedByDailyCap() public {
        uint256 cap   = token.spenderDailyCapTokens(); // default 50_000 ether
        uint256 chunk = 5_000 ether;                   // == maxSingleTxLimit (rate 1:1)

        uint256 pulled;
        vm.startPrank(facilitator);
        while (pulled + chunk <= cap) {
            token.transferFrom(user, facilitator, chunk);
            pulled += chunk;
        }
        // The next chunk would push the rolling 24h total past the cap.
        vm.expectRevert(); // SpenderDailyCapExceeded
        token.transferFrom(user, facilitator, chunk);
        vm.stopPrank();

        assertEq(token.balanceOf(facilitator), cap, "self-pull drain bounded to daily cap");
    }

    // --- daily cap window rolls forward after 24h ---
    function test_TransferFromSelf_CapResetsAfter24h() public {
        vm.prank(facilitator);
        token.transferFrom(user, facilitator, 5_000 ether);

        vm.warp(block.timestamp + 1 days + 1);

        // Fresh window — another pull succeeds.
        vm.prank(facilitator);
        token.transferFrom(user, facilitator, 5_000 ether);
        assertEq(token.balanceOf(facilitator), 10_000 ether);
    }

    // --- no regression: normal self-pull within limits still works ---
    function test_TransferFromSelf_WithinLimits_Succeeds() public {
        vm.prank(facilitator);
        token.transferFrom(user, facilitator, 1_000 ether);
        assertEq(token.balanceOf(facilitator), 1_000 ether);
    }

    // --- settle path (to == SuperPaymaster) is exempt and unaffected ---
    function test_TransferFromToSuperPaymaster_StillWorks() public {
        vm.prank(facilitator);
        token.transferFrom(user, paymaster, 1_000 ether);
        assertEq(token.balanceOf(paymaster), 1_000 ether, "settle path unaffected");
    }

    // --- settle path does NOT consume the spender's daily burn cap ---
    function test_TransferFromToSuperPaymaster_DoesNotConsumeCap() public {
        // Pull a large amount to SP (settle); the daily cap must remain untouched
        // so legitimate settlement throughput is not throttled by this fix.
        vm.startPrank(facilitator);
        token.transferFrom(user, paymaster, 5_000 ether);
        token.transferFrom(user, paymaster, 5_000 ether);
        vm.stopPrank();

        // Self-pull of the full cap still available afterwards.
        uint256 cap = token.spenderDailyCapTokens();
        uint256 chunk = 5_000 ether;
        uint256 pulled;
        vm.startPrank(facilitator);
        while (pulled + chunk <= cap) {
            token.transferFrom(user2, facilitator, chunk);
            pulled += chunk;
        }
        vm.stopPrank();
        assertEq(token.balanceOf(facilitator), cap, "settle did not consume self-pull cap");
    }
}
