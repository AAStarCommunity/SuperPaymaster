// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsToken.sol";
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
    xPNTsToken token;
    address admin = address(0x111);
    address user = address(0x222);
    address paymaster = address(0x333);
    address other = address(0x444);

    function setUp() public {
        vm.prank(admin);
        token = new xPNTsToken("Points", "XP", admin, "Comm", "ens.eth", 1e18);
        
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
        
        assertEq(token.allowance(user, other), type(uint256).max);
    }

    function test_SuperPaymaster_Firewall_Reverts() public {
        vm.prank(admin);
        token.mint(user, 100 ether);
        
        vm.prank(user);
        token.approve(paymaster, 100 ether);
        
        // SuperPaymaster cannot use transferFrom
        vm.prank(paymaster);
        vm.expectRevert("SuperPaymaster cannot use transferFrom; must use burnFromWithOpHash()");
        token.transferFrom(user, other, 10 ether);
    }

    // 3. burnFromWithOpHash
    function test_BurnFromWithOpHash_Success() public {
        vm.prank(admin);
        token.mint(user, 100 ether);
        
        bytes32 opHash = keccak256("op1");
        vm.prank(paymaster);
        token.burnFromWithOpHash(user, 10 ether, opHash);
        
        assertEq(token.balanceOf(user), 90 ether);
        assertTrue(token.usedOpHashes(opHash));
        
        // Replay attempt
        vm.prank(paymaster);
        vm.expectRevert(); // OperationAlreadyProcessed
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
}
