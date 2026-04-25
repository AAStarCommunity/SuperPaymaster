// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/core/Registry.sol";
import "../../src/tokens/MySBT.sol";
import "../../src/tokens/GToken.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/interfaces/v3/IMySBT.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/**
 * @title Registry Multi-Community Test
 * @notice Test idempotent registerRole for multi-community joining
 */
contract RegistryMultiCommunityTest is Test {
    Registry public registry;
    MySBT public mysbt;
    GToken public gtoken;
    GTokenStaking public staking;
    
    address public deployer = address(0x1);
    address public communityA = address(0x100);
    address public communityB = address(0x101);
    address public communityC = address(0x102);
    address public user = address(0x200);
    
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 public constant ROLE_ENDUSER = keccak256("ENDUSER");
    
    function setUp() public {
        vm.startPrank(deployer);
        
        // Deploy GToken
        gtoken = new GToken(1_000_000 ether);
        gtoken.mint(deployer, 1_000_000 ether);

        // Scheme B: Deploy Registry proxy first with placeholders
        registry = UUPSDeployHelper.deployRegistryProxy(deployer, address(0), address(0));

        // Deploy Staking and MySBT with immutable Registry
        staking = new GTokenStaking(address(gtoken), deployer, address(registry));
        mysbt = new MySBT(address(gtoken), address(staking), address(registry), deployer);

        // Wire into Registry
        registry.setStaking(address(staking));
        registry.setMySBT(address(mysbt));
        
        // Fund user with GToken
        gtoken.transfer(user, 100 ether);
        
        // Fund communities
        gtoken.transfer(communityA, 100 ether);
        gtoken.transfer(communityB, 100 ether);
        gtoken.transfer(communityC, 100 ether);
        
        vm.stopPrank();
    }
    
    function _registerCommunity(address community, string memory name) internal {
        vm.startPrank(community);

        // Approve staking
        gtoken.approve(address(staking), 100 ether);

        // Prepare community data
        bytes memory communityData = abi.encode(
            Registry.CommunityRoleData(name, "", "", "", "", 30 ether)
        );

        // Register community
        registry.registerRole(ROLE_COMMUNITY, community, communityData);

        vm.stopPrank();
    }
    
    function _joinCommunity(address _user, address community) internal returns (uint256 sbtId) {
        vm.startPrank(_user);
        
        // Approve staking
        gtoken.approve(address(staking), 10 ether);
        
        // Prepare user data
        bytes memory userData = abi.encode(
            Registry.EndUserRoleData(community, "", "", 1 ether)
        );
        
        // Join community
        registry.registerRole(ROLE_ENDUSER, _user, userData);
        sbtId = mysbt.getUserSBT(_user);

        vm.stopPrank();
    }
    
    function testMultiCommunityRegistration() public {
        // Setup: Register 3 communities
        _registerCommunity(communityA, "CommunityA");
        _registerCommunity(communityB, "CommunityB");
        _registerCommunity(communityC, "CommunityC");
        
        // Test 1: User joins Community A (first time)
        uint256 sbtId1 = _joinCommunity(user, communityA);
        assertTrue(sbtId1 > 0, "SBT ID should be assigned");
        assertTrue(registry.hasRole(ROLE_ENDUSER, user), "User should have ENDUSER role");
        
        // Verify membership
        MySBT.CommunityMembership[] memory memberships1 = mysbt.getMemberships(sbtId1);
        assertEq(memberships1.length, 1, "Should have 1 membership");
        assertEq(memberships1[0].community, communityA, "First membership should be Community A");
        
        // Test 2: User joins Community B (idempotent call)
        uint256 sbtId2 = _joinCommunity(user, communityB);
        assertEq(sbtId2, sbtId1, "Should return same SBT ID");
        
        // Verify memberships
        MySBT.CommunityMembership[] memory memberships2 = mysbt.getMemberships(sbtId1);
        assertEq(memberships2.length, 2, "Should have 2 memberships");
        assertEq(memberships2[1].community, communityB, "Second membership should be Community B");
        
        // Test 3: User joins Community C (third community)
        uint256 sbtId3 = _joinCommunity(user, communityC);
        assertEq(sbtId3, sbtId1, "Should return same SBT ID");
        
        // Verify memberships
        MySBT.CommunityMembership[] memory memberships3 = mysbt.getMemberships(sbtId1);
        assertEq(memberships3.length, 3, "Should have 3 memberships");
        assertEq(memberships3[2].community, communityC, "Third membership should be Community C");
        
        // Verify all memberships are active
        for (uint256 i = 0; i < memberships3.length; i++) {
            assertTrue(memberships3[i].isActive, "All memberships should be active");
        }
    }
    
    function testIdempotentReregistration() public {
        // Setup
        _registerCommunity(communityA, "CommunityA");
        
        // First join
        uint256 sbtId1 = _joinCommunity(user, communityA);
        
        // Re-join same community (should be idempotent)
        uint256 sbtId2 = _joinCommunity(user, communityA);
        
        assertEq(sbtId2, sbtId1, "Should return same SBT ID");
        
        // Verify no duplicate membership
        MySBT.CommunityMembership[] memory memberships = mysbt.getMemberships(sbtId1);
        assertEq(memberships.length, 1, "Should still have only 1 membership (no duplicate)");
    }
    
    function testNoEntryBurnOnReregistration() public {
        // Setup
        _registerCommunity(communityA, "CommunityA");
        _registerCommunity(communityB, "CommunityB");

        // Record initial balance and treasury balance
        uint256 balanceBefore = gtoken.balanceOf(user);
        uint256 treasuryBefore = gtoken.balanceOf(deployer); // deployer is treasury in this test

        // First join (ticketPrice goes to treasury, no stake for non-operator)
        _joinCommunity(user, communityA);
        uint256 balanceAfterFirst = gtoken.balanceOf(user);

        // Calculate cost
        uint256 firstCost = balanceBefore - balanceAfterFirst;
        assertTrue(firstCost > 0, "First join should cost ticketPrice");

        // Second join (idempotent for ENDUSER, should NOT burn ticketPrice again)
        _joinCommunity(user, communityB);
        uint256 balanceAfterSecond = gtoken.balanceOf(user);

        // Calculate cost of second join
        uint256 secondCost = balanceAfterFirst - balanceAfterSecond;

        // Second join should cost less (no ticketPrice)
        assertTrue(secondCost < firstCost, "Second join should cost less (no ticketPrice)");
        assertEq(secondCost, 0, "Second join should not cost additional balance");
    }
    
    function testCommunityReregistrationReverts() public {
        // First registration
        _registerCommunity(communityA, "CommunityA");
        
        // Prepare second registration data
        bytes memory communityData = abi.encode(Registry.CommunityRoleData("CommunityA_Duplicate", "", "", "", "", 30 ether));
        
        // Second registration should revert (strictly non-idempotent for non-ENDUSER)
        vm.startPrank(communityA);
        gtoken.approve(address(staking), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Registry.RoleAlreadyGranted.selector, ROLE_COMMUNITY, communityA));
        registry.registerRole(ROLE_COMMUNITY, communityA, communityData);
        vm.stopPrank();
    }
}
