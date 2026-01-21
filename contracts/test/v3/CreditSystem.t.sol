// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

contract CreditSystemTest is Test {
    using Clones for address;
    xPNTsToken public token;
    address public paymaster = address(0x999);
    address public admin = address(0x123);
    address public user = address(0x456);

    function setUp() public {
        vm.startPrank(admin);
        address implementation = address(new xPNTsToken());
        token = xPNTsToken(implementation.clone());
        token.initialize("xPNTs", "XP", admin, "Test", "test.eth", 1e18);
        token.setSuperPaymasterAddress(paymaster);
        vm.stopPrank();
    }

    function testDebtRecording() public {
        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);

        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);
        
        uint256 debt = token.getDebt(user);
        assertEq(debt, 10 ether, "Debt should be 10 ether");

        // Accumulate debt
        vm.prank(paymaster);
        token.recordDebt(user, 5 ether);
        assertEq(token.getDebt(user), 15 ether, "Debt should accumulate");
    }

    function testUnauthorizedDebtRecording() public {
        vm.prank(address(0xbad));
        vm.expectRevert(); // BasePaymaster/xPNTs usually has OnlyPaymaster or similar
        token.recordDebt(user, 10 ether);
    }

    function testAutoRepayment() public {
        // 0. Set Limit
        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);

        // 1. Record Debt
        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);
        
        // 2. Mint xPNTs (Income) > Debt
        vm.prank(admin);
        token.mint(user, 15 ether);
        
        uint256 debt = token.getDebt(user);
        uint256 balance = token.balanceOf(user);
        
        assertEq(debt, 0, "Debt should be fully repaid");
        assertEq(balance, 5 ether, "Balance should be 5 ether (15 - 10)");
    }

    function testPartialRepayment() public {
        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);

        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);
        
        vm.prank(admin);
        token.mint(user, 4 ether);
        
        assertEq(token.getDebt(user), 6 ether);
        assertEq(token.balanceOf(user), 0);
    }

    function testTransferRepayment() public {
        address sender = address(0x777);
        vm.prank(admin);
        token.mint(sender, 20 ether);

        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);

        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);

        vm.prank(sender);
        token.transfer(user, 15 ether);

        // Feature change: transfers no longer auto-repay.
        // Debt should still be 10, balance should be 15
        assertEq(token.getDebt(user), 10 ether);
        assertEq(token.balanceOf(user), 15 ether);
    }

    function testTransferFromRepayment() public {
        address sender = address(0x777);
        address spender = address(0x888);
        
        vm.prank(admin);
        token.mint(sender, 20 ether);

        vm.prank(sender);
        token.approve(spender, 20 ether);

        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);

        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);

        // Spender moves funds to user
        vm.prank(spender);
        token.transferFrom(sender, user, 15 ether);

        // Feature change: transfers no longer auto-repay.
        // Debt should still be 10, balance should be 15
        assertEq(token.getDebt(user), 10 ether);
        assertEq(token.balanceOf(user), 15 ether);
    }

    function testMintToMultipleUsers() public {
        address user2 = address(0x999);
        vm.startPrank(admin);
        token.mint(user, 10 ether);
        token.mint(user2, 10 ether);
        vm.stopPrank();
        
        assertEq(token.balanceOf(user), 10 ether);
        assertEq(token.balanceOf(user2), 10 ether);
    }

    function testSetSuperPaymasterUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        token.setSuperPaymasterAddress(address(0));
    }
}
