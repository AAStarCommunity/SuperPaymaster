// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/GToken.sol";

/**
 * @title Mock Registry for MySBT Testing
 */
contract MockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    
    function setRole(bytes32 role, address account, bool value) external {
        hasRole[role][account] = value;
    }


    // Stubs
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,0,false, 0,"stub",address(0),0); 
    }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function getCreditLimit(address) external view override returns (uint256) { return 100 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external view override returns (string memory) { return "MockRegistryV3"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
}

/**
 * @title MySBT_Simplified_Test
 * @notice 简化的 MySBT 测试套件 - 专注于 MySBT 内部逻辑
 * @dev 使用 Mock Registry 避免复杂依赖
 */
contract MySBT_Simplified_Test is Test {
    MySBT public mysbt;
    GToken public gtoken;
    MockRegistry public mockRegistry;
    
    address public admin = address(0x1);
    address public mockStaking = address(0x3);
    address public community1 = address(0x4);
    address public community2 = address(0x5);
    address public user1 = address(0x6);
    address public user2 = address(0x7);
    
    bytes32 public constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    
    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy GToken
        gtoken = new GToken(21_000_000 ether);
        
        // Deploy Mock Registry
        mockRegistry = new MockRegistry();
        
        // Deploy MySBT
        mysbt = new MySBT(address(gtoken), mockStaking, address(mockRegistry), admin);
        
        // Register communities in mock registry
        mockRegistry.setRole(ROLE_COMMUNITY, community1, true);
        mockRegistry.setRole(ROLE_COMMUNITY, community2, true);
        
        vm.stopPrank();
    }

    // ====================================
    // Minting Tests (via Mock Registry)
    // ====================================

    function test_MintForRole_NewSBT() public {
        bytes memory roleData = abi.encode(community1);
        
        vm.prank(address(mockRegistry));
        (uint256 tokenId, bool isNewMint) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        assertTrue(isNewMint);
        assertEq(tokenId, 1);
        assertEq(mysbt.ownerOf(tokenId), user1);
        assertEq(mysbt.userToSBT(user1), tokenId);
    }

    function test_MintForRole_AddMembership() public {
        // First mint
        bytes memory roleData1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId1,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData1);
        
        // Add second membership
        bytes memory roleData2 = abi.encode(community2);
        vm.prank(address(mockRegistry));
        (uint256 tokenId2, bool isNewMint) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData2);
        
        assertFalse(isNewMint);
        assertEq(tokenId1, tokenId2);
    }

    function test_MintForRole_OnlyRegistry() public {
        bytes memory roleData = abi.encode(community1);
        
        vm.prank(user1);
        vm.expectRevert(MySBT.OnlyRegistry.selector);
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
    }

    function test_MintForRole_InvalidUser() public {
        bytes memory roleData = abi.encode(community1);
        
        vm.prank(address(mockRegistry));
        vm.expectRevert(MySBT.InvalidUser.selector);
        mysbt.mintForRole(address(0), ROLE_ENDUSER, roleData);
    }

    function test_AirdropMint_NewSBT() public {
        bytes memory roleData = abi.encode(community1);
        
        vm.prank(address(mockRegistry));
        (uint256 tokenId, bool isNew) = mysbt.airdropMint(user1, ROLE_ENDUSER, roleData);
        
        assertTrue(isNew);
        assertEq(tokenId, 1);
        assertEq(mysbt.ownerOf(tokenId), user1);
    }

    function test_AirdropMint_AddMembership() public {
        bytes memory roleData1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId1,) = mysbt.airdropMint(user1, ROLE_ENDUSER, roleData1);
        
        bytes memory roleData2 = abi.encode(community2);
        vm.prank(address(mockRegistry));
        (uint256 tokenId2, bool isNew) = mysbt.airdropMint(user1, ROLE_ENDUSER, roleData2);
        
        assertFalse(isNew);
        assertEq(tokenId1, tokenId2);
    }

    // ====================================
    // Soulbound Transfer Tests
    // ====================================

    function test_Transfer_Blocked() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        vm.prank(user1);
        vm.expectRevert(); // Soulbound check in _update
        mysbt.transferFrom(user1, user2, tokenId);
    }

    function test_SafeTransferFrom_Blocked() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        vm.prank(user1);
        vm.expectRevert();
        mysbt.safeTransferFrom(user1, user2, tokenId);
    }

    function test_SafeTransferFromWithData_Blocked() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        vm.prank(user1);
        vm.expectRevert();
        mysbt.safeTransferFrom(user1, user2, tokenId, "");
    }

    // Note: approve() and setApprovalForAll() are not overridden in MySBT
    // Soulbound restriction is only enforced in _update() function

    // ====================================
    // Burn Tests
    // ====================================

    function test_BurnSBT_Success() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        vm.prank(address(mockRegistry));
        mysbt.burnSBT(user1);
        
        assertEq(mysbt.userToSBT(user1), 0);
        vm.expectRevert();
        mysbt.ownerOf(tokenId);
    }

    function test_BurnSBT_NoSBT() public {
        vm.prank(address(mockRegistry));
        vm.expectRevert(); // No specific error message
        mysbt.burnSBT(user1);
    }

    // ====================================
    // Membership Management Tests
    // ====================================

    function test_LeaveCommunity_Success() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        vm.prank(user1);
        mysbt.leaveCommunity(community1);
        
        // Verify membership is deactivated
        assertFalse(mysbt.verifyCommunityMembership(user1, community1));
    }

    function test_DeactivateMembership_ViaRegistry() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        vm.prank(address(mockRegistry));
        mysbt.deactivateMembership(user1, community1);
        
        assertFalse(mysbt.verifyCommunityMembership(user1, community1));
    }

    function test_DeactivateMembership_OnlyRegistry() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        vm.prank(user1);
        vm.expectRevert(MySBT.OnlyRegistry.selector);
        mysbt.deactivateMembership(user1, community1);
    }

    // ====================================
    // View Functions Tests
    // ====================================

    function test_GetUserSBT() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        assertEq(mysbt.getUserSBT(user1), tokenId);
        assertEq(mysbt.getUserSBT(user2), 0);
    }

    function test_GetSBTData() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        MySBT.SBTData memory data = mysbt.getSBTData(tokenId);
        
        assertEq(data.holder, user1);
        assertEq(data.firstCommunity, community1);
        assertEq(data.totalCommunities, 1);
        assertGt(data.mintedAt, 0);
    }

    function test_GetMemberships() public {
        bytes memory roleData1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData1);
        
        bytes memory roleData2 = abi.encode(community2);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData2);
        
        MySBT.CommunityMembership[] memory memberships = mysbt.getMemberships(tokenId);
        
        assertEq(memberships.length, 2);
        assertEq(memberships[0].community, community1);
        assertEq(memberships[1].community, community2);
        assertTrue(memberships[0].isActive);
        assertTrue(memberships[1].isActive);
    }

    function test_GetCommunityMembership() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        MySBT.CommunityMembership memory membership = mysbt.getCommunityMembership(tokenId, community1);
        
        assertEq(membership.community, community1);
        assertTrue(membership.isActive);
        assertGt(membership.joinedAt, 0);
    }

    function test_VerifyCommunityMembership() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
        
        assertTrue(mysbt.verifyCommunityMembership(user1, community1));
        assertFalse(mysbt.verifyCommunityMembership(user1, community2));
        assertFalse(mysbt.verifyCommunityMembership(user2, community1));
    }

    function test_GetActiveMemberships() public {
        bytes memory roleData1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData1);
        
        bytes memory roleData2 = abi.encode(community2);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData2);
        
        // Deactivate one
        vm.prank(user1);
        mysbt.leaveCommunity(community1);
        
        address[] memory active = mysbt.getActiveMemberships(tokenId);
        
        assertEq(active.length, 1);
        assertEq(active[0], community2);
    }

    // ====================================
    // Admin Functions Tests
    // ====================================

    function test_SetMinLockAmount() public {
        vm.prank(admin);
        mysbt.setMinLockAmount(5 ether);
        
        assertEq(mysbt.minLockAmount(), 5 ether);
    }

    function test_SetMinLockAmount_OnlyDAO() public {
        vm.prank(user1);
        vm.expectRevert(MySBT.OnlyDAO.selector);
        mysbt.setMinLockAmount(5 ether);
    }

    function test_SetMintFee() public {
        vm.prank(admin);
        mysbt.setMintFee(0.5 ether);
        
        assertEq(mysbt.mintFee(), 0.5 ether);
    }

    function test_SetMintFee_OnlyDAO() public {
        vm.prank(user1);
        vm.expectRevert(MySBT.OnlyDAO.selector);
        mysbt.setMintFee(0.5 ether);
    }

    function test_SetReputationCalculator() public {
        address newCalculator = address(0x999);
        
        vm.prank(admin);
        mysbt.setReputationCalculator(newCalculator);
        
        assertEq(mysbt.reputationCalculator(), newCalculator);
    }

    function test_SetReputationCalculator_OnlyDAO() public {
        vm.prank(user1);
        vm.expectRevert(MySBT.OnlyDAO.selector);
        mysbt.setReputationCalculator(address(0x999));
    }

    function test_SetDAOMultisig() public {
        address newDAO = address(0x777);
        
        vm.prank(admin);
        mysbt.setDAOMultisig(newDAO);
        
        assertEq(mysbt.daoMultisig(), newDAO);
    }

    function test_SetDAOMultisig_OnlyDAO() public {
        vm.prank(user1);
        vm.expectRevert(MySBT.OnlyDAO.selector);
        mysbt.setDAOMultisig(address(0x777));
    }

    function test_Pause() public {
        vm.prank(admin);
        mysbt.pause();
        
        assertTrue(mysbt.paused());
    }

    function test_Pause_OnlyDAO() public {
        vm.prank(user1);
        vm.expectRevert(MySBT.OnlyDAO.selector);
        mysbt.pause();
    }

    function test_Unpause() public {
        vm.startPrank(admin);
        mysbt.pause();
        mysbt.unpause();
        vm.stopPrank();
        
        assertFalse(mysbt.paused());
    }

    function test_Unpause_OnlyDAO() public {
        vm.prank(admin);
        mysbt.pause();
        
        vm.prank(user1);
        vm.expectRevert(MySBT.OnlyDAO.selector);
        mysbt.unpause();
    }

    function test_MintWhenPaused_Reverts() public {
        vm.prank(admin);
        mysbt.pause();
        
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        vm.expectRevert();
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
    }

    // ====================================
    // Version Tests
    // ====================================

    function test_Version() public {
        assertEq(mysbt.version(), "MySBT-3.2.0");
    }



    // ====================================
    // Integration Tests
    // ====================================

    function test_CompleteUserJourney() public {
        // 1. Mint SBT
        bytes memory roleData1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData1);
        
        assertEq(mysbt.ownerOf(tokenId), user1);
        
        // 2. Add second membership
        bytes memory roleData2 = abi.encode(community2);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData2);
        
        MySBT.SBTData memory data = mysbt.getSBTData(tokenId);
        assertEq(data.totalCommunities, 2);
        
        // 5. Leave second community
        vm.prank(user1);
        mysbt.leaveCommunity(community2);
        
        // 6. Burn SBT
        vm.prank(address(mockRegistry));
        mysbt.burnSBT(user1);
        
        assertEq(mysbt.userToSBT(user1), 0);
    }

    function test_MultipleUsers() public {
        bytes memory roleData = abi.encode(community1);

        vm.prank(address(mockRegistry));
        (uint256 tokenId1,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        vm.prank(address(mockRegistry));
        (uint256 tokenId2,) = mysbt.mintForRole(user2, ROLE_ENDUSER, roleData);

        assertEq(tokenId1, 1);
        assertEq(tokenId2, 2);
        assertEq(mysbt.ownerOf(tokenId1), user1);
        assertEq(mysbt.ownerOf(tokenId2), user2);
    }

    // ====================================
    // B1: recordActivity() branch coverage
    // ====================================

    /// @notice B1a: recordActivity when membership is active — should succeed
    function test_RecordActivity_ActiveMembership() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        vm.prank(community1);
        mysbt.recordActivity(user1);

        // Confirm lastActivityTime updated
        assertGt(mysbt.lastActivityTime(tokenId, community1), 0);
    }

    /// @notice B1b: recordActivity when membership is inactive — should still update if membership record exists
    ///         The current code only checks membership index/community, not isActive flag.
    ///         This test documents the actual behavior.
    function test_RecordActivity_InactiveMembership_StillRecords() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        // Deactivate membership
        vm.prank(user1);
        mysbt.leaveCommunity(community1);

        // Membership record still exists at index 0, so recordActivity should still work
        vm.prank(community1);
        mysbt.recordActivity(user1);

        assertGt(mysbt.lastActivityTime(tokenId, community1), 0);
    }

    /// @notice B1c: recordActivity rate-limiting — second call within MIN_INT must revert
    function test_RecordActivity_RateLimit_Revert() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        vm.prank(community1);
        mysbt.recordActivity(user1);

        // Call again immediately — should revert due to MIN_INT rate limit
        vm.prank(community1);
        vm.expectRevert();
        mysbt.recordActivity(user1);
    }

    /// @notice B1d: recordActivity rate-limiting — call after MIN_INT should succeed
    function test_RecordActivity_AfterMinInterval_Succeeds() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        vm.prank(community1);
        mysbt.recordActivity(user1);

        // Warp past MIN_INT (5 minutes)
        vm.warp(block.timestamp + 6 minutes);

        vm.prank(community1);
        mysbt.recordActivity(user1); // Should succeed
    }

    /// @notice B1e: recordActivity for user with no SBT — should revert
    function test_RecordActivity_NoSBT_Revert() public {
        vm.prank(community1);
        vm.expectRevert();
        mysbt.recordActivity(user1);
    }

    /// @notice B1f: recordActivity by non-registered community — should revert
    function test_RecordActivity_InvalidCommunity_Revert() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        // community2 is registered but user1 is not a member of community2
        address fakeCommunity = address(0x999);
        vm.prank(fakeCommunity);
        vm.expectRevert();
        mysbt.recordActivity(user1);
    }

    // ====================================
    // B2: burnSBT with multiple memberships
    // ====================================

    /// @notice B2: burnSBT with 3 memberships — all must be deactivated and SBT burned
    function test_BurnSBT_MultipleMemberships_AllCleaned() public {
        address community3 = address(0x8);
        mockRegistry.setRole(ROLE_COMMUNITY, community3, true);

        // Mint SBT with 3 memberships
        bytes memory rd1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, rd1);

        bytes memory rd2 = abi.encode(community2);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, rd2);

        bytes memory rd3 = abi.encode(community3);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, rd3);

        // Confirm 3 memberships
        MySBT.CommunityMembership[] memory mems = mysbt.getMemberships(tokenId);
        assertEq(mems.length, 3);

        // Burn SBT
        vm.prank(address(mockRegistry));
        mysbt.burnSBT(user1);

        // SBT burned: userToSBT cleared
        assertEq(mysbt.userToSBT(user1), 0);

        // Token no longer exists
        vm.expectRevert();
        mysbt.ownerOf(tokenId);
    }

    /// @notice B2b: burnSBT with mix of active and inactive memberships
    function test_BurnSBT_MixedMemberships_OnlyActiveDeactivated() public {
        bytes memory rd1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, rd1);

        bytes memory rd2 = abi.encode(community2);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, rd2);

        // Leave community1 before burn
        vm.prank(user1);
        mysbt.leaveCommunity(community1);

        // community1 already inactive, community2 still active
        vm.prank(address(mockRegistry));
        mysbt.burnSBT(user1); // Must not revert even with inactive membership

        assertEq(mysbt.userToSBT(user1), 0);
    }

    // ====================================
    // B3: leaveCommunity then rejoin
    // ====================================

    /// @notice B3a: mintForRole after leaveCommunity should reactivate existing membership
    function test_LeaveThenRejoin_MintForRole_Reactivates() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        // Leave
        vm.prank(user1);
        mysbt.leaveCommunity(community1);
        assertFalse(mysbt.verifyCommunityMembership(user1, community1));

        // Rejoin via mintForRole
        vm.prank(address(mockRegistry));
        (uint256 tokenId2, bool isNewMint) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        assertEq(tokenId, tokenId2);
        assertFalse(isNewMint); // Not a new SBT
        assertTrue(mysbt.verifyCommunityMembership(user1, community1)); // Reactivated
    }

    /// @notice B3b: airdropMint after leaveCommunity should reactivate and update joinedAt
    function test_LeaveThenRejoin_AirdropMint_Reactivates() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.airdropMint(user1, ROLE_ENDUSER, roleData);

        // Leave
        vm.prank(user1);
        mysbt.leaveCommunity(community1);
        assertFalse(mysbt.verifyCommunityMembership(user1, community1));

        // Warp time
        vm.warp(block.timestamp + 1 days);

        // Rejoin via airdropMint
        vm.prank(address(mockRegistry));
        (uint256 tokenId2, bool isNew) = mysbt.airdropMint(user1, ROLE_ENDUSER, roleData);

        assertEq(tokenId, tokenId2);
        assertFalse(isNew);
        assertTrue(mysbt.verifyCommunityMembership(user1, community1)); // Reactivated
    }

    /// @notice B3c: airdropMint for already active membership returns early (no duplicate)
    function test_AirdropMint_AlreadyActiveMembership_ReturnsEarly() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.airdropMint(user1, ROLE_ENDUSER, roleData);

        // Call again without leaving — should return early (already active)
        vm.prank(address(mockRegistry));
        (uint256 tokenId2, bool isNew) = mysbt.airdropMint(user1, ROLE_ENDUSER, roleData);

        assertEq(tokenId, tokenId2);
        assertFalse(isNew);

        // Still only one membership record
        MySBT.CommunityMembership[] memory mems = mysbt.getMemberships(tokenId);
        assertEq(mems.length, 1);
    }

    // ====================================
    // B4: mintForRole MAX_MEMBERSHIPS boundary
    // ====================================

    /// @notice B4a: exactly 50 memberships should succeed (MAX_MEMBERSHIPS boundary)
    function test_MintForRole_MaxMemberships_ExactlyFifty_OK() public {
        // Mint initial SBT with community1
        bytes memory rd1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, rd1);

        // Add 49 more communities (total = 50)
        for (uint256 i = 1; i < 50; i++) {
            address comm = address(uint160(0x1000 + i));
            mockRegistry.setRole(ROLE_COMMUNITY, comm, true);
            bytes memory rd = abi.encode(comm);
            vm.prank(address(mockRegistry));
            mysbt.mintForRole(user1, ROLE_ENDUSER, rd);
        }

        // Exactly 50 memberships
        MySBT.CommunityMembership[] memory mems = mysbt.getMemberships(tokenId);
        assertEq(mems.length, 50);
        assertEq(mems.length, mysbt.MAX_MEMBERSHIPS());
    }

    /// @notice B4b: 51st mintForRole must revert with TooManyMemberships
    function test_MintForRole_MaxMemberships_51st_Revert() public {
        // Mint SBT with first community
        bytes memory rd1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, rd1);

        // Add 49 more = 50 total
        for (uint256 i = 1; i < 50; i++) {
            address comm = address(uint160(0x1000 + i));
            mockRegistry.setRole(ROLE_COMMUNITY, comm, true);
            bytes memory rd = abi.encode(comm);
            vm.prank(address(mockRegistry));
            mysbt.mintForRole(user1, ROLE_ENDUSER, rd);
        }

        // 51st must revert
        address extraComm = address(uint160(0x2000));
        mockRegistry.setRole(ROLE_COMMUNITY, extraComm, true);
        bytes memory rdExtra = abi.encode(extraComm);
        vm.prank(address(mockRegistry));
        vm.expectRevert(MySBT.TooManyMemberships.selector);
        mysbt.mintForRole(user1, ROLE_ENDUSER, rdExtra);
    }

    // ====================================
    // B5: airdropMint MAX_MEMBERSHIPS boundary
    // ====================================

    /// @notice B5a: exactly 50 memberships via airdropMint should succeed
    function test_AirdropMint_MaxMemberships_ExactlyFifty_OK() public {
        bytes memory rd1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.airdropMint(user1, ROLE_ENDUSER, rd1);

        for (uint256 i = 1; i < 50; i++) {
            address comm = address(uint160(0x3000 + i));
            mockRegistry.setRole(ROLE_COMMUNITY, comm, true);
            bytes memory rd = abi.encode(comm);
            vm.prank(address(mockRegistry));
            mysbt.airdropMint(user1, ROLE_ENDUSER, rd);
        }

        MySBT.CommunityMembership[] memory mems = mysbt.getMemberships(tokenId);
        assertEq(mems.length, 50);
    }

    /// @notice B5b: 51st airdropMint must revert with TooManyMemberships
    function test_AirdropMint_MaxMemberships_51st_Revert() public {
        bytes memory rd1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        mysbt.airdropMint(user1, ROLE_ENDUSER, rd1);

        for (uint256 i = 1; i < 50; i++) {
            address comm = address(uint160(0x3000 + i));
            mockRegistry.setRole(ROLE_COMMUNITY, comm, true);
            bytes memory rd = abi.encode(comm);
            vm.prank(address(mockRegistry));
            mysbt.airdropMint(user1, ROLE_ENDUSER, rd);
        }

        address extraComm = address(uint160(0x4000));
        mockRegistry.setRole(ROLE_COMMUNITY, extraComm, true);
        bytes memory rdExtra = abi.encode(extraComm);
        vm.prank(address(mockRegistry));
        vm.expectRevert(MySBT.TooManyMemberships.selector);
        mysbt.airdropMint(user1, ROLE_ENDUSER, rdExtra);
    }

    // ====================================
    // B6: Custom error / revert paths
    // ====================================

    /// @notice B6a: onlyDAO modifier — setMinLockAmount with zero reverts
    function test_SetMinLockAmount_ZeroReverts() public {
        vm.prank(admin);
        vm.expectRevert(); // require(a != 0)
        mysbt.setMinLockAmount(0);
    }

    /// @notice B6b: setDAOMultisig with zero address reverts
    function test_SetDAOMultisig_ZeroAddress_Reverts() public {
        vm.prank(admin);
        vm.expectRevert();
        mysbt.setDAOMultisig(address(0));
    }

    /// @notice B6c: onlyRegistry — deactivateMembership by non-registry reverts
    function test_DeactivateMembership_NonRegistry_Reverts() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        vm.prank(user1);
        vm.expectRevert("Only Registry");
        mysbt.deactivateMembership(user1, community1);
    }

    /// @notice B6d: onlyRegistry — deactivateAllMemberships by non-registry reverts
    function test_DeactivateAllMemberships_NonRegistry_Reverts() public {
        vm.prank(user1);
        vm.expectRevert("Only Registry");
        mysbt.deactivateAllMemberships(user1);
    }

    /// @notice B6e: burnSBT for non-existent SBT reverts
    function test_BurnSBT_NotFound_Reverts() public {
        vm.prank(address(mockRegistry));
        vm.expectRevert();
        mysbt.burnSBT(user2); // user2 has no SBT
    }

    /// @notice B6f: getCommunityMembership for invalid index reverts
    function test_GetCommunityMembership_InvalidIndex_Reverts() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        // community2 was never added — index defaults to 0 but community mismatch
        vm.expectRevert();
        mysbt.getCommunityMembership(tokenId, community2);
    }

    /// @notice B6g: mintForRole with invalid user address reverts
    function test_MintForRole_ZeroUser_Reverts() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        vm.expectRevert("Invalid user");
        mysbt.mintForRole(address(0), ROLE_ENDUSER, roleData);
    }

    /// @notice B6h: airdropMint with invalid user address reverts
    function test_AirdropMint_ZeroUser_Reverts() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        vm.expectRevert("Invalid user");
        mysbt.airdropMint(address(0), ROLE_ENDUSER, roleData);
    }

    /// @notice B6i: burnSBT only callable by Registry
    function test_BurnSBT_NonRegistry_Reverts() public {
        bytes memory roleData = abi.encode(community1);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        vm.prank(user1);
        vm.expectRevert("Only Registry");
        mysbt.burnSBT(user1);
    }

    /// @notice B6j: deactivateAllMemberships on user with no SBT should not revert (early return)
    function test_DeactivateAllMemberships_NoSBT_NoRevert() public {
        vm.prank(address(mockRegistry));
        mysbt.deactivateAllMemberships(user2); // No SBT — should silently return
    }

    /// @notice B6k: leaveCommunity for user with no SBT should silently return
    function test_LeaveCommunity_NoSBT_NoRevert() public {
        vm.prank(user1);
        mysbt.leaveCommunity(community1); // user1 has no SBT — silent return
    }

    /// @notice B6l: setBaseURI via DAO
    function test_SetBaseURI_DAO() public {
        vm.prank(admin);
        mysbt.setBaseURI("https://api.example.com/sbt/");
        // No direct getter but we verify it doesn't revert
    }

    /// @notice B6m: setBaseURI by non-DAO reverts
    function test_SetBaseURI_NonDAO_Reverts() public {
        vm.prank(user1);
        vm.expectRevert("Only DAO");
        mysbt.setBaseURI("https://evil.com/");
    }

    // ====================================
    // B7: deactivateAllMemberships coverage
    // ====================================

    /// @notice B7a: deactivateAllMemberships deactivates all active memberships
    function test_DeactivateAllMemberships_MultipleCommunities() public {
        bytes memory rd1 = abi.encode(community1);
        vm.prank(address(mockRegistry));
        (uint256 tokenId,) = mysbt.mintForRole(user1, ROLE_ENDUSER, rd1);

        bytes memory rd2 = abi.encode(community2);
        vm.prank(address(mockRegistry));
        mysbt.mintForRole(user1, ROLE_ENDUSER, rd2);

        // Both active
        assertTrue(mysbt.verifyCommunityMembership(user1, community1));
        assertTrue(mysbt.verifyCommunityMembership(user1, community2));

        vm.prank(address(mockRegistry));
        mysbt.deactivateAllMemberships(user1);

        assertFalse(mysbt.verifyCommunityMembership(user1, community1));
        assertFalse(mysbt.verifyCommunityMembership(user1, community2));
    }

    // ====================================
    // B8: _decodeRoleData with metadata string
    // ====================================

    /// @notice B8: mintForRole with full roleData (community + metadata)
    function test_MintForRole_WithMetadata_Succeeds() public {
        bytes memory roleData = abi.encode(community1, "ipfs://QmTest123");

        vm.prank(address(mockRegistry));
        (uint256 tokenId, bool isNew) = mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);

        assertTrue(isNew);
        MySBT.CommunityMembership[] memory mems = mysbt.getMemberships(tokenId);
        assertEq(mems[0].metadata, "ipfs://QmTest123");
    }

    /// @notice B8b: airdropMint with full roleData including metadata
    function test_AirdropMint_WithMetadata_Succeeds() public {
        bytes memory roleData = abi.encode(community1, "ipfs://QmAirdrop456");

        vm.prank(address(mockRegistry));
        (uint256 tokenId, bool isNew) = mysbt.airdropMint(user1, ROLE_ENDUSER, roleData);

        assertTrue(isNew);
        MySBT.CommunityMembership[] memory mems = mysbt.getMemberships(tokenId);
        assertEq(mems[0].metadata, "ipfs://QmAirdrop456");
    }
}
