// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";

contract CreditSystemTest is Test {
    xPNTsToken public token;
    address public paymaster = address(0x999);
    address public admin = address(0x123);
    address public user = address(0x456);

    function setUp() public {
        vm.startPrank(admin);
        token = new xPNTsToken("xPNTs", "XP", admin, "Test", "test.eth", 1e18);
        token.setSuperPaymasterAddress(paymaster);
        vm.stopPrank();
    }

    function testDebtRecording() public {
        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);
        
        uint256 debt = token.getDebt(user);
        assertEq(debt, 10 ether, "Debt should be 10 ether");
    }

    function testAutoRepayment() public {
        // 1. Record Debt
        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);
        
        // 2. Mint xPNTs (Income) > Debt
        // Mint 15 ether. Expected: 10 burned for debt, 5 credited.
        vm.prank(admin);
        token.mint(user, 15 ether);
        
        uint256 debt = token.getDebt(user);
        uint256 balance = token.balanceOf(user);
        
        assertEq(debt, 0, "Debt should be fully repaid");
        assertEq(balance, 5 ether, "Balance should be 5 ether (15 - 10)");
    }

    function testPartialRepayment() public {
        // 1. Record Debt
        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);
        
        // 2. Mint xPNTs (Income) < Debt
        // Mint 4 ether. Expected: 4 burned, Debt becomes 6, Balance 0.
        vm.prank(admin);
        token.mint(user, 4 ether);
        
        uint256 debt = token.getDebt(user);
        uint256 balance = token.balanceOf(user);
        
        assertEq(debt, 6 ether, "Debt should be 6 ether (10 - 4)");
        assertEq(balance, 0, "Balance should be 0");
    }

    function testTransferRepayment() public {
        // Test repayment on peer-to-peer transfer
        address sender = address(0x777);
        vm.prank(admin);
        token.mint(sender, 20 ether);

        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);

        // Sender transfers 15 to user
        vm.prank(sender);
        token.transfer(user, 15 ether);

        uint256 debt = token.getDebt(user);
        uint256 balance = token.balanceOf(user);

        assertEq(debt, 0, "Debt should be cleared");
        assertEq(balance, 5 ether, "Balance should be 5");
    }
}
