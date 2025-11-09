// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/paymasters/v2/tokens/MySBT_v2.3.3.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";
import "../src/paymasters/v2/core/GToken.sol";
import "../src/paymasters/v2/core/Registry.sol";

contract MySBT_v2_3_3_Test is Test {
    MySBT_v2_3_3 public mysbt;
    GTokenStaking public staking;
    GToken public gtoken;
    Registry public registry;

    address public dao = makeAddr("dao");
    address public treasury = makeAddr("treasury");
    address public user1 = makeAddr("user1");
    address public community1 = makeAddr("community1");

    function setUp() public {
        // Deploy contracts
        gtoken = new GToken(dao);
        staking = new GTokenStaking(address(gtoken), treasury);

        // Deploy minimal Registry for testing
        registry = new Registry(
            address(gtoken),
            address(staking),
            address(0), // superPaymaster
            address(0), // mysbt (will set later)
            dao
        );

        mysbt = new MySBT_v2_3_3(
            address(gtoken),
            address(staking),
            address(registry),
            dao
        );

        // Configure MySBT as locker with 0.1 ether exitFee
        uint256[] memory emptyTiers = new uint256[](0);
        vm.prank(dao);
        staking.configureLocker(
            address(mysbt),
            true,           // authorized
            0.1 ether,      // baseExitFee
            emptyTiers,     // timeTiers
            emptyTiers,     // tierFees
            address(0)      // feeRecipient (use default treasury)
        );

        // Setup: Give user1 GT and stake
        vm.startPrank(dao);
        gtoken.mint(user1, 100 ether);
        vm.stopPrank();

        vm.startPrank(user1);
        gtoken.approve(address(staking), 50 ether);
        staking.stake(50 ether);
        vm.stopPrank();

        // Register community1
        vm.startPrank(community1);
        gtoken.approve(address(staking), 50 ether);
        // Note: In real Registry, need to register properly
        // For this test, we'll mock isRegisteredCommunity
        vm.stopPrank();

        // Mock Registry.isRegisteredCommunity for community1
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(Registry.isRegisteredCommunity.selector, community1),
            abi.encode(true)
        );
    }

    function test_BurnSBT_Success() public {
        // 1. Mint SBT as community1
        vm.prank(community1);
        (uint256 tokenId, bool isNewMint) = mysbt.mintOrAddMembership(user1, "");

        assertEq(isNewMint, true);
        assertEq(tokenId, 1);
        assertEq(mysbt.getUserSBT(user1), 1);

        // Check state before burn
        uint256 user1StakedBefore = staking.balanceOf(user1);
        uint256 treasuryBalanceBefore = gtoken.balanceOf(treasury);
        uint256 user1GTBefore = gtoken.balanceOf(user1);

        console.log("Before burn:");
        console.log("  User stGT:", user1StakedBefore);
        console.log("  Treasury GT:", treasuryBalanceBefore);
        console.log("  User GT:", user1GTBefore);

        // 2. Burn SBT
        vm.prank(user1);
        uint256 netAmount = mysbt.burnSBT();

        // Check state after burn
        uint256 user1StakedAfter = staking.balanceOf(user1);
        uint256 treasuryBalanceAfter = gtoken.balanceOf(treasury);
        uint256 user1GTAfter = gtoken.balanceOf(user1);

        console.log("\nAfter burn:");
        console.log("  User stGT:", user1StakedAfter);
        console.log("  Treasury GT:", treasuryBalanceAfter);
        console.log("  User GT:", user1GTAfter);
        console.log("  Net returned:", netAmount);

        // 3. Verify results
        assertEq(mysbt.getUserSBT(user1), 0, "SBT should be burned");

        // User should receive 0.2 GT (0.3 - 0.1 exitFee)
        assertEq(user1GTAfter - user1GTBefore, 0.2 ether, "User should receive 0.2 GT");

        // Treasury should receive 0.1 GT exitFee
        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, 0.1 ether, "Treasury should receive 0.1 GT");

        // Net amount should be 0.2 ether
        assertEq(netAmount, 0.2 ether, "Net amount should be 0.2 ether");

        // Verify SBT was actually burned (should revert on ownerOf)
        vm.expectRevert();
        mysbt.ownerOf(tokenId);
    }

    function test_BurnSBT_NoSBT() public {
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(string)", "No SBT to burn"));
        mysbt.burnSBT();
    }

    function test_BurnSBT_NotOwner() public {
        // Mint SBT for user1
        vm.prank(community1);
        mysbt.mintOrAddMembership(user1, "");

        // Try to burn as different user
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("InvalidParameter(string)", "No SBT to burn"));
        mysbt.burnSBT();
    }

    function test_BurnSBT_MultipleMemberships() public {
        address community2 = makeAddr("community2");

        // Mock community2 as registered
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(Registry.isRegisteredCommunity.selector, community2),
            abi.encode(true)
        );

        // Mint SBT with first community
        vm.prank(community1);
        (uint256 tokenId, ) = mysbt.mintOrAddMembership(user1, "metadata1");

        // Add second community membership
        vm.prank(community2);
        mysbt.mintOrAddMembership(user1, "metadata2");

        // Verify 2 memberships
        MySBT_v2_3_3.CommunityMembership[] memory memberships = mysbt.getMemberships(tokenId);
        assertEq(memberships.length, 2);
        assertEq(memberships[0].isActive, true);
        assertEq(memberships[1].isActive, true);

        // Burn SBT
        vm.prank(user1);
        uint256 netAmount = mysbt.burnSBT();

        // Verify all memberships deactivated
        memberships = mysbt.getMemberships(tokenId);
        for (uint256 i = 0; i < memberships.length; i++) {
            assertEq(memberships[i].isActive, false, "All memberships should be deactivated");
        }

        // Verify exit flow worked
        assertEq(netAmount, 0.2 ether);
    }
}
