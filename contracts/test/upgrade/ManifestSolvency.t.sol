// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../tokens/APNTsCappedSPIntegration.t.sol";

/// Exercises the real proxy, extension, token, slash and withdrawal revert paths.
contract ManifestSolvencyTest is APNTsCappedSPIntegrationTest {
    using SuperPaymasterAdminCalls for SuperPaymaster;

    function prepareSwap(bool backed) internal {
        vm.startPrank(operator);
        apnts.approve(address(sp), 1 ether);
        sp.deposit(1 ether);
        vm.stopPrank();
        vm.prank(operator);
        sp.requestWithdraw(0.9 ether);
        vm.warp(block.timestamp + sp.OPERATOR_WITHDRAWAL_DELAY());
        vm.startPrank(owner);
        sp.queueSlash(operator);
        sp.slashOperator(operator, ISuperPaymaster.SlashLevel.WARNING, 0.1 ether, "buffer fixture");
        vm.stopPrank();
        vm.prank(operator);
        sp.withdraw(0.9 ether);
        APNTsCapped next = new APNTsCapped("New", "NEW", CAP, owner, minter, owner);
        vm.prank(owner);
        sp.setAPNTsToken(address(next));
        vm.warp(block.timestamp + 7 days);
        if (backed) {
            vm.prank(minter);
            next.mint(address(sp), 0.1 ether);
        }
        vm.prank(owner);
        sp.executeAPNTsTokenChange();
        assertEq(apnts.balanceOf(address(sp)), 0.1 ether, "old token stranded");
        apnts = next;
    }

    function test_manifest_buffer_deposit_accrual_withdrawal() public {
        prepareSwap(true);
        _assertBacked("swap");
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.InsufficientRevenue.selector);
        sp.withdrawProtocolRevenue(treasury, 0.1 ether);
        vm.prank(minter);
        apnts.mint(operator, 1 ether);
        vm.startPrank(operator);
        apnts.approve(address(sp), 1 ether);
        sp.deposit(1 ether);
        vm.stopPrank();
        _assertBacked("first deposit");
        vm.startPrank(owner);
        sp.queueSlash(operator);
        sp.slashOperator(operator, ISuperPaymaster.SlashLevel.WARNING, 0.1 ether, "revenue fixture");
        assertEq(sp.protocolRevenue(), 0.2 ether);
        sp.withdrawProtocolRevenue(treasury, 0.1 ether);
        vm.stopPrank();
        _assertBacked("revenue withdrawal");
    }

    function test_manifest_without_B2a_is_insolvent() public {
        prepareSwap(false);
        assertEq(apnts.balanceOf(address(sp)), 0);
        assertEq(sp.totalTrackedBalance(), 0.1 ether);
        vm.prank(owner);
        vm.expectRevert(SuperPaymasterStorage.InsufficientRevenue.selector);
        sp.withdrawProtocolRevenue(treasury, 0.1 ether);
    }
}
