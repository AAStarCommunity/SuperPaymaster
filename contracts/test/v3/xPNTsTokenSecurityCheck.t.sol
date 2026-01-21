// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

contract xPNTsTokenSecurityCheck is Test {
    using Clones for address;
    xPNTsToken token;
    address admin = address(0x111);
    address user = address(0x222);
    address paymaster = address(0x333);

    function setUp() public {
        vm.startPrank(admin);
        address implementation = address(new xPNTsToken());
        token = xPNTsToken(implementation.clone());
        token.initialize("Points", "XP", admin, "Comm", "ens.eth", 1e18);
        vm.stopPrank();
        
        // Setup Paymaster as Auto-Approved
        vm.prank(admin);
        token.addAutoApprovedSpender(paymaster);
        
        // Setup User Balance
        vm.prank(admin);
        token.mint(user, 1000 ether);
        
        // Setup User Limit for Paymaster
        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);
    }

    function test_Security_TransferFrom_Bypasses_CumulativeSpent() public {
        // 1. Initial State
        assertEq(token.balanceOf(user), 1000 ether);
        assertEq(token.allowance(user, paymaster), 100 ether); // Limit (100) - Spent (0)
        
        // 2. Paymaster calls transferFrom to pull funds (Deposit)
        vm.prank(paymaster);
        token.transferFrom(user, paymaster, 50 ether);
        
        // 3. Check Balance - Should succeed
        assertEq(token.balanceOf(user), 950 ether);
        assertEq(token.balanceOf(paymaster), 50 ether);
        
        // 4. Check Cumulative Spent
        // CRITICAL CHECK: Does transferFrom increase cumulativeSpent?
        uint256 spent = token.cumulativeSpent(user, paymaster);
        console.log("Cumulative Spent after transferFrom:", spent);
        
        // 5. Check Allowance
        // If spent is 0, allowance is still 100 (Limit - 0)
        uint256 allowed = token.allowance(user, paymaster);
        console.log("Allowance remaining:", allowed);
        
        if (spent == 0) {
            console.log("VULNERABILITY CONFIRMED: Cumulative Spent not updated.");
            
            // 6. Prove Infinite Drain (up to limit per tx)
            // Paymaster can pull another 60, which exceeds the TOTAL limit of 100 (50+60=110),
            // but since spent is 0, it only checks against 100 per call.
            vm.prank(paymaster);
            token.transferFrom(user, paymaster, 60 ether);
            
            assertEq(token.balanceOf(user), 890 ether);
            console.log("Paymaster drained 110 total, limit was 100.");
        } else {
             console.log("SECURE: Cumulative Spent updated.");
        }
    }
}
