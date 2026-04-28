// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

/// @notice P0-7 (B4-H1): the original `emergencyRevokePaymaster` only cleared
///         `autoApprovedSpenders[currentSP]`, leaving `burnFromWithOpHash` and
///         `recordDebt` reachable. A compromised SP could continue burning
///         holder balances at MAX_SINGLE_TX_LIMIT per call. The new
///         `emergencyDisabled` flag closes all dangerous paths, and a separate
///         `unsetEmergencyDisabled` clears it after rotating the SP.
contract MockRegistry {
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
}

contract xPNTs_EmergencyDisabledTest is Test {
    xPNTsToken token;

    address community = address(0xCAFE);
    address paymaster = address(0xBABE);
    address facilitator = address(0xFAFA);
    address user = address(0xA1);

    function setUp() public {
        // Deploy through the factory clone path so `_initializeXPNTs` runs the
        // way it does in production. Using deployxPNTsToken would require a
        // full registry mock; instead we clone the implementation and call
        // initialize directly with the community as caller.
        xPNTsToken impl = new xPNTsToken();
        token = xPNTsToken(Clones.clone(address(impl)));

        // FACTORY is set to msg.sender of `initialize`. The test contract acts
        // as factory so it can mint balances during setup.
        token.initialize(
            "DemoPoints",
            "dPNTs",
            community,
            "Demo",
            "demo.eth",
            1e18
        );

        // Test contract is FACTORY → can call setSuperPaymasterAddress.
        token.setSuperPaymasterAddress(paymaster);

        // Mint a balance to user so burn paths have something to consume.
        token.mint(user, 1000 ether);
    }

    // -----------------------------------------------------------------------
    // Pre-revoke state — the SP-only burn paths still work as expected.
    // -----------------------------------------------------------------------

    function test_BurnFromWithOpHash_WorksBeforeRevoke() public {
        bytes32 opHash = keccak256("op-1");
        vm.prank(paymaster);
        token.burnFromWithOpHash(user, 100 ether, opHash);
        assertEq(token.balanceOf(user), 900 ether);
    }

    function test_RecordDebt_WorksBeforeRevoke() public {
        vm.prank(paymaster);
        token.recordDebt(user, 50 ether);
        assertEq(token.getDebt(user), 50 ether);
    }

    // -----------------------------------------------------------------------
    // emergencyRevokePaymaster sets the flag and emits the new event.
    // -----------------------------------------------------------------------

    function test_EmergencyRevoke_SetsFlag() public {
        assertFalse(token.emergencyDisabled());
        vm.prank(community);
        token.emergencyRevokePaymaster();
        assertTrue(token.emergencyDisabled());
    }

    function test_EmergencyRevoke_OnlyCommunity() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, address(0xBAD)));
        token.emergencyRevokePaymaster();
    }

    // -----------------------------------------------------------------------
    // After revoke, every dangerous burn path reverts with EmergencyStop.
    // -----------------------------------------------------------------------

    function test_BurnFromWithOpHash_BlockedAfterRevoke() public {
        vm.prank(community);
        token.emergencyRevokePaymaster();

        bytes32 opHash = keccak256("op-1");
        vm.prank(paymaster);
        vm.expectRevert(xPNTsToken.EmergencyStop.selector);
        token.burnFromWithOpHash(user, 100 ether, opHash);
    }

    function test_RecordDebt_BlockedAfterRevoke() public {
        vm.prank(community);
        token.emergencyRevokePaymaster();

        vm.prank(paymaster);
        vm.expectRevert(xPNTsToken.EmergencyStop.selector);
        token.recordDebt(user, 50 ether);
    }

    function test_AutoApprovedBurn_BlockedAfterRevoke() public {
        // Either factory or community owner can add an autoApproved spender.
        token.addAutoApprovedSpender(facilitator);

        vm.prank(community);
        token.emergencyRevokePaymaster();

        // autoApproved spender path goes through `burn(address, uint256)` with
        // `msg.sender != from` — that branch is the one P0-7 closes.
        // Even though the spender is autoApproved, an explicit allowance is
        // still needed because `burn(address, uint256)` checks `_spendAllowance`.
        // Set one so the test isolates the EmergencyStop revert from the
        // BurnExceedsAllowance revert that would otherwise fire first.
        vm.prank(user);
        token.approve(facilitator, type(uint256).max);

        vm.prank(facilitator);
        vm.expectRevert(xPNTsToken.EmergencyStop.selector);
        token.burn(user, 100 ether);
    }

    /// @notice Self-burn must remain available so users keep custody of their
    ///         own balance during a community-level emergency.
    function test_SelfBurn_AllowedAfterRevoke() public {
        vm.prank(community);
        token.emergencyRevokePaymaster();

        vm.prank(user);
        token.burn(50 ether);
        assertEq(token.balanceOf(user), 950 ether);
    }

    // -----------------------------------------------------------------------
    // Recovery path: setSuperPaymasterAddress + unsetEmergencyDisabled.
    // -----------------------------------------------------------------------

    function test_UnsetEmergencyDisabled_ClearsFlag() public {
        vm.prank(community);
        token.emergencyRevokePaymaster();
        assertTrue(token.emergencyDisabled());

        vm.prank(community);
        token.unsetEmergencyDisabled();
        assertFalse(token.emergencyDisabled());
    }

    function test_UnsetEmergencyDisabled_OnlyCommunity() public {
        vm.prank(community);
        token.emergencyRevokePaymaster();

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, address(0xBAD)));
        token.unsetEmergencyDisabled();
    }

    function test_FullRecoveryFlow() public {
        // 1. Compromise: revoke
        vm.prank(community);
        token.emergencyRevokePaymaster();
        assertTrue(token.emergencyDisabled());

        // 2. Rotate SP to a new address
        address newPaymaster = address(0x9999);
        vm.prank(community);
        token.setSuperPaymasterAddress(newPaymaster);

        // 3. Clear the flag
        vm.prank(community);
        token.unsetEmergencyDisabled();
        assertFalse(token.emergencyDisabled());

        // 4. New SP can resume burning
        bytes32 opHash = keccak256("op-after-recovery");
        vm.prank(newPaymaster);
        token.burnFromWithOpHash(user, 100 ether, opHash);
        assertEq(token.balanceOf(user), 900 ether);
    }
}
