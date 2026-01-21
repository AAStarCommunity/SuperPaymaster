// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

/**
 * @title Emergency Functions Test Suite
 * @notice Tests for emergencyRevokePaymaster() and edge cases
 */
contract xPNTsEmergencyTest is Test {
    using Clones for address;
    
    xPNTsToken token;
    address admin = address(0x111);
    address user = address(0x222);
    address paymaster = address(0x333);
    address factory = address(0xABC);
    address attacker = address(0xBAD);

    function setUp() public {
        vm.startPrank(factory);
        address implementation = address(new xPNTsToken());
        token = xPNTsToken(implementation.clone());
        token.initialize("Emergency", "EMG", admin, "TestComm", "test.eth", 1e18);
        vm.stopPrank();
        
        vm.prank(admin);
        token.setSuperPaymasterAddress(paymaster);
    }

    // Test 1: Emergency revoke when paymaster is set
    function test_EmergencyRevoke_Success() public {
        // Verify paymaster is active
        assertTrue(token.autoApprovedSpenders(paymaster));
        
        // Admin calls emergency revoke
        vm.prank(admin);
        token.emergencyRevokePaymaster();
        
        // Verify paymaster is revoked
        assertFalse(token.autoApprovedSpenders(paymaster));
        
        // Verify paymaster can no longer transfer
        vm.prank(admin);
        token.mint(user, 1000 ether);
        
        vm.prank(paymaster);
        vm.expectRevert(); // No approval now
        token.transferFrom(user, paymaster, 100 ether);
    }

    // Test 2: Emergency revoke when paymaster not set
    function test_EmergencyRevoke_WhenNotSet() public {
        // Deploy fresh token without paymaster
        vm.startPrank(factory);
        address impl2 = address(new xPNTsToken());
        xPNTsToken token2 = xPNTsToken(impl2.clone());
        token2.initialize("Test2", "T2", admin, "Comm2", "test2.eth", 1e18);
        vm.stopPrank();
        
        // Should not revert, just do nothing
        vm.prank(admin);
        token2.emergencyRevokePaymaster(); // Should pass silently
    }

    // Test 3: Emergency revoke requires owner
    function test_EmergencyRevoke_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.Unauthorized.selector, attacker));
        token.emergencyRevokePaymaster();
    }

    // Test 4: Emergency revoke then normal setSuperPaymaster still works
    function test_EmergencyRevoke_ThenReset() public {
        vm.prank(admin);
        token.emergencyRevokePaymaster();
        
        address newPaymaster = address(0x999);
        vm.prank(admin);
        token.setSuperPaymasterAddress(newPaymaster);
        
        // New paymaster should be active
        assertTrue(token.autoApprovedSpenders(newPaymaster));
        assertFalse(token.autoApprovedSpenders(paymaster)); // Old still revoked
    }
}
