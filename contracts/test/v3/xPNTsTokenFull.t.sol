// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "src/interfaces/IERC1363.sol";

contract MockReceiver is IERC1363Receiver {
    bool public received;
    bytes4 public constant SUCCESS_RETVAL = IERC1363Receiver.onTransferReceived.selector;

    function onTransferReceived(address, address, uint256, bytes memory) external override returns (bytes4) {
        received = true;
        return SUCCESS_RETVAL;
    }
}

contract xPNTsTokenFullTest is Test {
    using Clones for address;
    xPNTsToken token;
    address admin = address(0x111);
    address user = address(0x222);
    address paymaster = address(0x333);
    address other = address(0x444);

    function setUp() public {
        vm.startPrank(admin);
        address implementation = address(new xPNTsToken());
        token = xPNTsToken(implementation.clone());
        token.initialize("Points", "XP", admin, "Comm", "ens.eth", 1e18);
        vm.stopPrank();
        
        vm.prank(admin);
        token.setSuperPaymasterAddress(paymaster);
    }

    // 1. ERC1363 Tests
    function test_TransferAndCall() public {
        MockReceiver receiver = new MockReceiver();
        vm.prank(admin);
        token.mint(user, 100 ether);

        vm.prank(user);
        token.transferAndCall(address(receiver), 10 ether);
        
        assertTrue(receiver.received());
        assertEq(token.balanceOf(address(receiver)), 10 ether);
    }

    // 2. Pre-Authorization & Firewall
    function test_AllowanceOverride_AutoApproved() public {
        vm.prank(admin);
        token.addAutoApprovedSpender(other);
        
        // Default limit is 0, so allowance should be 0
        assertEq(token.allowance(user, other), 0);

        // Set limit
        vm.prank(user);
        token.setPaymasterLimit(other, 1000 ether);
        assertEq(token.allowance(user, other), 1000 ether);
    }

    function test_SuperPaymaster_Firewall_Reverts() public {
        vm.prank(admin);
        token.mint(user, 100 ether);
        
        vm.prank(user);
        token.approve(paymaster, 100 ether);
        
        // SuperPaymaster cannot use transferFrom
        vm.prank(paymaster);
        vm.expectRevert("SuperPaymaster Security: Can only pull funds to self");
        token.transferFrom(user, other, 10 ether);
    }

    // 3. burnFromWithOpHash
    function test_BurnFromWithOpHash_Success() public {
        vm.prank(admin);
        token.mint(user, 100 ether);
        
        bytes32 opHash = keccak256("op1");
        
        // Set spending limit
        vm.prank(user);
        token.setPaymasterLimit(paymaster, 50 ether);

        vm.prank(paymaster);
        token.burnFromWithOpHash(user, 10 ether, opHash);
        
        assertEq(token.balanceOf(user), 90 ether);
        assertTrue(token.usedOpHashes(opHash));
        
        // Replay attempt with same hash
        vm.prank(paymaster);
        vm.expectRevert(abi.encodeWithSelector(xPNTsToken.OperationAlreadyProcessed.selector, opHash));
        token.burnFromWithOpHash(user, 10 ether, opHash);
    }

    // 4. Update Logic Branches
    function test_Update_WithZeroValue() public {
        vm.prank(admin);
        token.mint(user, 0); // Should not revert, coverage for value > 0 branch
    }

    function test_Update_ToZeroAddress() public {
        vm.prank(admin);
        token.mint(user, 10 ether);
        
        vm.prank(user);
        token.burn(5 ether); // Coverage for to == address(0) branch
    }

    // 5. Management Functions
    function test_Management_Metadata_And_Access() public {
        (string memory n, , string memory cn, , address co) = token.getMetadata();
        assertEq(n, "Points");
        assertEq(cn, "Comm");
        assertEq(co, admin);

        vm.prank(admin);
        token.updateExchangeRate(2e18);
        assertEq(token.exchangeRate(), 2e18);

        vm.prank(admin);
        token.transferCommunityOwnership(other);
        assertEq(token.communityOwner(), other);
        
        assertTrue(token.needsApproval(user, address(0xdead), 1 ether));
    }

    function test_SpenderManagement() public {
        vm.prank(admin);
        token.addAutoApprovedSpender(other);
        assertTrue(token.autoApprovedSpenders(other));

        vm.prank(admin);
        token.removeAutoApprovedSpender(other);
        assertFalse(token.autoApprovedSpenders(other));
    }

    function test_StandardBurn() public {
        vm.prank(admin);
        token.mint(user, 10 ether);
        
        vm.prank(user);
        token.burn(2 ether);
        assertEq(token.balanceOf(user), 8 ether);
    }

    function test_AutoRepay_MintOnly() public {
        // 0. Set Limit
        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);

        // 1. Record Debt
        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);
        assertEq(token.getDebt(user), 10 ether);

        // 2. Mint (Airdrop/Income) - should trigger auto-repay
        vm.prank(admin);
        token.mint(user, 15 ether);
        
        // Debt should be 0, balance should be 5 ether (15 - 10)
        assertEq(token.getDebt(user), 0);
        assertEq(token.balanceOf(user), 5 ether);
    }

    function test_NoAutoRepay_OnTransfer() public {
        // 0. Set Limit
        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);

        // 1. Setup Debt
        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);
        
        // 2. Transfer from another user - should NOT trigger auto-repay
        vm.prank(admin);
        token.mint(other, 20 ether);
        
        vm.prank(other);
        token.transfer(user, 15 ether);
        
        // Debt should still be 10, balance should be 15
        assertEq(token.getDebt(user), 10 ether);
        assertEq(token.balanceOf(user), 15 ether);
    }

    function test_ManualRepayDebt() public {
        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);

        vm.prank(paymaster);
        token.recordDebt(user, 10 ether);
        
        // Give user some balance via transfer (so it doesn't auto-repay)
        vm.prank(admin);
        token.mint(other, 20 ether);
        vm.prank(other);
        token.transfer(user, 20 ether);
        
        assertEq(token.balanceOf(user), 20 ether);
        assertEq(token.getDebt(user), 10 ether);
        
        vm.prank(user);
        token.repayDebt(5 ether);
        
        assertEq(token.balanceOf(user), 15 ether);
        assertEq(token.getDebt(user), 5 ether);
    }

    function test_Security_TransferFrom_SpendingLimit() public {
        // 1. Setup user balance
        vm.prank(admin);
        token.mint(user, 1000 ether);

        // 2. Set spending limit for paymaster
        vm.prank(user);
        token.setPaymasterLimit(paymaster, 100 ether);

        // 3. First transfer (50) - should pass
        vm.prank(paymaster);
        token.transferFrom(user, paymaster, 50 ether);
        assertEq(token.cumulativeSpent(user, paymaster), 50 ether);

        // 4. Second transfer (60) - should REVERT (Total 110 > 100)
        vm.prank(paymaster);
        vm.expectRevert("Spending limit exceeded");
        token.transferFrom(user, paymaster, 60 ether);

        // 5. Verify the state hasn't changed
        assertEq(token.cumulativeSpent(user, paymaster), 50 ether);
        assertEq(token.balanceOf(user), 950 ether);
    }
}
