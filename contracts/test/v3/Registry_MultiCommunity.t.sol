// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/core/Registry.sol";
import "../../src/tokens/MySBT.sol";
import "../../src/tokens/GToken.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/interfaces/v3/IMySBT.sol";

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
        
        // Deploy Staking
        staking = new GTokenStaking(address(gtoken), deployer);
        
        // Deploy MySBT (placeholder)
        mysbt = new MySBT(address(gtoken), address(staking), address(0), deployer);
        
        // Deploy Registry
        registry = new Registry(address(gtoken), address(staking), address(mysbt));
        
        // Wire up contracts
        staking.setRegistry(address(registry));
        mysbt.setRegistry(address(registry));
        
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
            name,      // name
            "",        // ensName
            "",        // website
            "",        // description
            "",        // logoURI
            30 ether   // stakeAmount
        );
        
        // Register community
        registry.registerRoleSelf(ROLE_COMMUNITY, communityData);
        
        vm.stopPrank();
    }
    
    function _joinCommunity(address _user, address community) internal returns (uint256 sbtId) {
        vm.startPrank(_user);
        
        // Approve staking
        gtoken.approve(address(staking), 10 ether);
        
        // Prepare user data
        bytes memory userData = abi.encode(
            _user,      // account
            community,  // community
            "",         // avatarURI
            "",         // ensName
            1 ether     // stakeAmount
        );
        
        // Join community
        sbtId = registry.registerRoleSelf(ROLE_ENDUSER, userData);
        
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
        
        // Record initial balance
        uint256 balanceBefore = gtoken.balanceOf(user);
        
        // First join (should burn entryBurn)
        _joinCommunity(user, communityA);
        uint256 balanceAfterFirst = gtoken.balanceOf(user);
        
        // Calculate burn amount
        uint256 firstBurn = balanceBefore - balanceAfterFirst;
        assertTrue(firstBurn > 1 ether, "First join should burn entry fee + stake");
        
        // Second join (should NOT burn entryBurn, only additional stake if needed)
        _joinCommunity(user, communityB);
        uint256 balanceAfterSecond = gtoken.balanceOf(user);
        
        // Calculate cost of second join
        uint256 secondCost = balanceAfterFirst - balanceAfterSecond;
        
        // Second join should cost less (no entryBurn)
        assertTrue(secondCost < firstBurn, "Second join should cost less (no entryBurn)");
        assertEq(secondCost, 0, "Second join should not cost additional balance if stake is same");
    }
    
    function testCommunityReregistrationReverts() public {
        // First registration
        _registerCommunity(communityA, "CommunityA");
        
        // Prepare second registration data
        bytes memory communityData = abi.encode("CommunityA_Duplicate", "", "", "", "", 30 ether);
        
        // Second registration should revert (strictly non-idempotent for non-ENDUSER)
        vm.startPrank(communityA);
        gtoken.approve(address(staking), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Registry.RoleAlreadyGranted.selector, ROLE_COMMUNITY, communityA));
        registry.registerRoleSelf(ROLE_COMMUNITY, communityData);
        vm.stopPrank();
    }
}
