// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/GToken.sol";

/**
 * @title Mock Registry for MySBT Testing
 */
contract MockRegistry is IRegistry {
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external view override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external view override returns (bytes32) { return keccak256("KMS"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    
    function setRole(bytes32 role, address account, bool value) external {
        hasRole[role][account] = value;
    }

    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }

    // Stubs
    function calculateExitFee(bytes32, uint256) external pure override returns (uint256) { return 0; }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function createNewRole(bytes32, RoleConfig calldata, address) external override {}
    function exitRole(bytes32) external override {}
    function setRoleLockDuration(bytes32, uint256) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,0,0,false,"stub"); 
    }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function registerRoleSelf(bytes32, bytes calldata) external override returns (uint256) { return 0; }
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function adminConfigureRole(bytes32, uint256, uint256, uint256, uint256) external override {}
    function setReputationSource(address, bool) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function setRoleOwner(bytes32, address) external override {}
    function batchUpdateGlobalReputation(address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function roleOwners(bytes32) external view override returns (address) { return address(0); }
    function getCreditLimit(address) external view override returns (uint256) { return 100 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external view override returns (string memory) { return "MockRegistryV3"; }
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
        vm.expectRevert("Only Registry");
        mysbt.mintForRole(user1, ROLE_ENDUSER, roleData);
    }

    function test_MintForRole_InvalidUser() public {
        bytes memory roleData = abi.encode(community1);
        
        vm.prank(address(mockRegistry));
        vm.expectRevert("Invalid user");
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
        vm.expectRevert("Only Registry");
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
        vm.expectRevert("Only DAO");
        mysbt.setMinLockAmount(5 ether);
    }

    function test_SetMintFee() public {
        vm.prank(admin);
        mysbt.setMintFee(0.5 ether);
        
        assertEq(mysbt.mintFee(), 0.5 ether);
    }

    function test_SetMintFee_OnlyDAO() public {
        vm.prank(user1);
        vm.expectRevert("Only DAO");
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
        vm.expectRevert("Only DAO");
        mysbt.setReputationCalculator(address(0x999));
    }

    function test_SetRegistry() public {
        address newRegistry = address(0x888);
        
        vm.prank(admin);
        mysbt.setRegistry(newRegistry);
        
        assertEq(mysbt.REGISTRY(), newRegistry);
    }

    function test_SetRegistry_OnlyDAO() public {
        vm.prank(user1);
        vm.expectRevert("Only DAO");
        mysbt.setRegistry(address(0x888));
    }

    function test_SetDAOMultisig() public {
        address newDAO = address(0x777);
        
        vm.prank(admin);
        mysbt.setDAOMultisig(newDAO);
        
        assertEq(mysbt.daoMultisig(), newDAO);
    }

    function test_SetDAOMultisig_OnlyDAO() public {
        vm.prank(user1);
        vm.expectRevert("Only DAO");
        mysbt.setDAOMultisig(address(0x777));
    }

    function test_Pause() public {
        vm.prank(admin);
        mysbt.pause();
        
        assertTrue(mysbt.paused());
    }

    function test_Pause_OnlyDAO() public {
        vm.prank(user1);
        vm.expectRevert("Only DAO");
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
        vm.expectRevert("Only DAO");
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
        assertEq(mysbt.version(), "MySBT-3.1.2");
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
}
