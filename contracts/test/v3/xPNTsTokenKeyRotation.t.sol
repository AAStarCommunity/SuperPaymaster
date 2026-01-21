// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

contract xPNTsTokenKeyRotationCheck is Test {
    using Clones for address;
    xPNTsToken token;
    address admin = address(0x111);
    address user = address(0x222);
    address oldPaymaster = address(uint160(0x888));
    address newPaymaster = address(uint160(0x999));
    address attacker = address(uint160(0xBAD));

    function setUp() public {
        vm.startPrank(admin);
        address implementation = address(new xPNTsToken());
        token = xPNTsToken(implementation.clone());
        token.initialize("Points", "XP", admin, "Comm", "ens.eth", 1e18);
        
        // 1. Setup Old Paymaster
        token.setSuperPaymasterAddress(oldPaymaster);
        token.addAutoApprovedSpender(oldPaymaster);
        
        // 2. Mint tokens to user
        token.mint(user, 1000 ether);
        vm.stopPrank();

        // 3. User sets limit for Old Paymaster (expecting it to be the system)
        vm.prank(user);
        token.setPaymasterLimit(oldPaymaster, 1000 ether);
    }

    function test_Security_OldPaymaster_Retains_Privileges() public {
        // Scenario: Community upgrades Paymaster to V2 (new address)
        // Admin calls setSuperPaymasterAddress, BUT forgets to remove auto-approve for old one.
        
        vm.startPrank(admin);
        token.setSuperPaymasterAddress(newPaymaster);
        token.addAutoApprovedSpender(newPaymaster);
        // OOPS: Forgot to remove oldPaymaster
        vm.stopPrank();
        
        // Verify New Paymaster works
        assertEq(token.SUPERPAYMASTER_ADDRESS(), newPaymaster);
        
        // CRITICAL CHECK: Can Old Paymaster still transfer funds?
        // And more importantly, does it bypass the "Pull to Self" check?
        // Since SUPERPAYMASTER_ADDRESS is now newPaymaster, msg.sender (oldPaymaster) != SUPERPAYMASTER_ADDRESS.
        // So it skips the first security block in transferFrom.
        // But it IS in autoApprovedSpenders, so it skips the allowance check (if we didn't fix the accounting bug).
        // Even with the accounting bug fix, it still has the `limit` (1000 ether) authorized by the user.
        
        // Old Paymaster (now potentially compromised or malicious) tries to steal funds to an attacker
        vm.prank(oldPaymaster);
        token.transferFrom(user, attacker, 500 ether);
        
        // If this succeeds, it means the Old Paymaster can send user funds ANYWHERE, 
        // whereas previously it could ONLY send to itself.
        assertEq(token.balanceOf(attacker), 500 ether);
        
        console.log("VULNERABILITY CONFIRMED: Old Paymaster retained transfer privileges and lost 'Self-Only' constraint.");
    }
}
