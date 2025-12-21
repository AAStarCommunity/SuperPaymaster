// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/reputation/ReputationSystemV3.sol";
import "src/core/Registry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("MockNFT", "MNFT") {}
    function mint(address to, uint256 tokenId) external { _mint(to, tokenId); }
}

/**
 * @title ReputationSystemV3_Complete_Test
 * @notice 完整的 ReputationSystemV3 测试套件
 */
contract ReputationSystemV3_Complete_Test is Test {
    ReputationSystemV3 public repSystem;
    Registry public registry;
    MockNFT public nft1;
    MockNFT public nft2;
    
    address public admin = address(0x1);
    address public community1 = address(0x2);
    address public community2 = address(0x3);
    address public user1 = address(0x4);
    address public user2 = address(0x5);
    
    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy Registry
        address mockGToken = address(0x888);
        address mockStaking = address(0x999);
        address mockSBT = address(0x777);
        registry = new Registry(mockGToken, mockStaking, mockSBT);
        
        // Deploy ReputationSystemV3
        repSystem = new ReputationSystemV3(address(registry));
        
        // Deploy NFTs for boost testing
        nft1 = new MockNFT();
        nft2 = new MockNFT();
        
        // Authorize repSystem as reputation source
        registry.setReputationSource(address(repSystem), true);
        
        // Set community role owner
        registry.setRoleOwner(keccak256("COMMUNITY"), community1);
        
        vm.stopPrank();
    }

    // ====================================
    // Entropy Factor Tests
    // ====================================

    function test_SetEntropyFactor_Success() public {
        vm.prank(admin);
        repSystem.setEntropyFactor(community1, 0.5e18); // 0.5x multiplier
        
        assertEq(repSystem.entropyFactors(community1), 0.5e18);
    }

    function test_SetEntropyFactor_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        repSystem.setEntropyFactor(community1, 0.5e18);
    }

    function test_SetEntropyFactor_MultipleCommunities() public {
        vm.startPrank(admin);
        repSystem.setEntropyFactor(community1, 0.8e18);
        repSystem.setEntropyFactor(community2, 1.2e18);
        vm.stopPrank();
        
        assertEq(repSystem.entropyFactors(community1), 0.8e18);
        assertEq(repSystem.entropyFactors(community2), 1.2e18);
    }

    // ====================================
    // Rule Setting Tests
    // ====================================

    function test_SetRule_ByCommunityOwner() public {
        vm.prank(community1);
        repSystem.setRule(keccak256("ACTIVE_MEMBER"), 20, 2, 200, "Active Member");
        
        (uint256 base, uint256 bonus, uint256 max, string memory desc) = 
            repSystem.communityRules(community1, keccak256("ACTIVE_MEMBER"));
        
        assertEq(base, 20);
        assertEq(bonus, 2);
        assertEq(max, 200);
        assertEq(desc, "Active Member");
    }

    function test_SetRule_ByAdmin() public {
        vm.prank(admin);
        repSystem.setRule(keccak256("CONTRIBUTOR"), 15, 3, 150, "Contributor");
        
        (uint256 base,,,) = repSystem.communityRules(admin, keccak256("CONTRIBUTOR"));
        assertEq(base, 15);
    }

    function test_SetRule_Unauthorized() public {
        vm.prank(user1);
        vm.expectRevert("Not Authorized");
        repSystem.setRule(keccak256("TEST"), 10, 1, 100, "Test");
    }

    function test_SetRule_MultipleRules() public {
        vm.startPrank(community1);
        repSystem.setRule(keccak256("RULE1"), 10, 1, 100, "Rule 1");
        repSystem.setRule(keccak256("RULE2"), 20, 2, 200, "Rule 2");
        repSystem.setRule(keccak256("RULE3"), 30, 3, 300, "Rule 3");
        vm.stopPrank();
        
        // Verify rules are set correctly
        (uint256 base1,,,) = repSystem.communityRules(community1, keccak256("RULE1"));
        (uint256 base2,,,) = repSystem.communityRules(community1, keccak256("RULE2"));
        (uint256 base3,,,) = repSystem.communityRules(community1, keccak256("RULE3"));
        
        assertEq(base1, 10);
        assertEq(base2, 20);
        assertEq(base3, 30);
    }

    // ====================================
    // NFT Boost Tests
    // ====================================

    function test_SetNFTBoost_Success() public {
        vm.prank(admin);
        repSystem.setNFTBoost(address(nft1), 50);
        
        assertEq(repSystem.nftCollectionBoost(address(nft1)), 50);
        assertEq(repSystem.boostedCollections(0), address(nft1));
    }

    function test_SetNFTBoost_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        repSystem.setNFTBoost(address(nft1), 50);
    }

    function test_SetNFTBoost_MultipleCollections() public {
        vm.startPrank(admin);
        repSystem.setNFTBoost(address(nft1), 50);
        repSystem.setNFTBoost(address(nft2), 100);
        vm.stopPrank();
        
        assertEq(repSystem.boostedCollections(0), address(nft1));
        assertEq(repSystem.boostedCollections(1), address(nft2));
    }

    function test_SetNFTBoost_UpdateExisting() public {
        vm.startPrank(admin);
        repSystem.setNFTBoost(address(nft1), 50);
        repSystem.setNFTBoost(address(nft1), 100); // Update
        vm.stopPrank();
        
        assertEq(repSystem.nftCollectionBoost(address(nft1)), 100);
        // Should not add duplicate to boostedCollections
        assertEq(repSystem.boostedCollections(0), address(nft1));
    }

    // ====================================
    // Compute Score Tests
    // ====================================

    function test_ComputeScore_DefaultRule() public {
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("DEFAULT");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 5; // 5 activities
        
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // Default rule: base=10, bonus=1 per activity, max=100
        // Score = 10 + min(5*1, 100) = 15
        assertEq(score, 15);
    }

    function test_ComputeScore_CustomRule() public {
        // Set custom rule
        vm.prank(community1);
        repSystem.setRule(keccak256("CUSTOM"), 20, 3, 150, "Custom");
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("CUSTOM");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 10; // 10 activities
        
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // Custom rule: base=20, bonus=3 per activity, max=150
        // Score = 20 + min(10*3, 150) = 20 + 30 = 50
        assertEq(score, 50);
    }

    function test_ComputeScore_WithEntropyFactor() public {
        // Set entropy factor to 0.5 (halves the score)
        vm.prank(admin);
        repSystem.setEntropyFactor(community1, 0.5e18);
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("DEFAULT");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 10;
        
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // Default: 10 + 10 = 20, with 0.5x factor = 10
        assertEq(score, 10);
    }

    function test_ComputeScore_MultipleRules() public {
        vm.startPrank(community1);
        repSystem.setRule(keccak256("RULE1"), 10, 1, 50, "Rule 1");
        repSystem.setRule(keccak256("RULE2"), 20, 2, 100, "Rule 2");
        vm.stopPrank();
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](2);
        ruleIds[0][0] = keccak256("RULE1");
        ruleIds[0][1] = keccak256("RULE2");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](2);
        activities[0][0] = 5;
        activities[0][1] = 10;
        
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // RULE1: 10 + 5*1 = 15
        // RULE2: 20 + 10*2 = 40
        // Total: 55
        assertEq(score, 55);
    }

    function test_ComputeScore_MultipleCommunities() public {
        vm.prank(community1);
        repSystem.setRule(keccak256("RULE1"), 10, 1, 50, "Rule 1");
        
        vm.prank(admin);
        repSystem.setRule(keccak256("RULE2"), 20, 2, 100, "Rule 2");
        
        address[] memory communities = new address[](2);
        communities[0] = community1;
        communities[1] = admin;
        
        bytes32[][] memory ruleIds = new bytes32[][](2);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("RULE1");
        ruleIds[1] = new bytes32[](1);
        ruleIds[1][0] = keccak256("RULE2");
        
        uint256[][] memory activities = new uint256[][](2);
        activities[0] = new uint256[](1);
        activities[0][0] = 5;
        activities[1] = new uint256[](1);
        activities[1][0] = 10;
        
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // Community1: 10 + 5 = 15
        // Admin: 20 + 20 = 40
        // Total: 55
        assertEq(score, 55);
    }

    function test_ComputeScore_WithNFTBoost() public {
        // Set NFT boost
        vm.prank(admin);
        repSystem.setNFTBoost(address(nft1), 50);
        
        // Mint NFT to user
        nft1.mint(user1, 1);
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("DEFAULT");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 5;
        
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // Base score: 15, NFT boost: 50, Total: 65
        assertEq(score, 65);
    }

    function test_ComputeScore_WithMultipleNFTBoosts() public {
        vm.startPrank(admin);
        repSystem.setNFTBoost(address(nft1), 50);
        repSystem.setNFTBoost(address(nft2), 100);
        vm.stopPrank();
        
        // Mint both NFTs to user
        nft1.mint(user1, 1);
        nft2.mint(user1, 1);
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("DEFAULT");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 5;
        
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // Base: 15, NFT1: 50, NFT2: 100, Total: 165
        assertEq(score, 165);
    }

    function test_ComputeScore_MaxBonusCap() public {
        vm.prank(community1);
        repSystem.setRule(keccak256("CAPPED"), 10, 5, 20, "Capped Rule");
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("CAPPED");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 100; // Very high activity
        
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // Base: 10, Bonus: min(100*5, 20) = 20, Total: 30
        assertEq(score, 30);
    }

    // ====================================
    // Sync to Registry Tests
    // ====================================

    function test_SyncToRegistry_Success() public {
        vm.prank(admin);
        repSystem.setEntropyFactor(community1, 1e18);
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("DEFAULT");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 5;
        
        vm.prank(address(repSystem));
        repSystem.syncToRegistry(user1, communities, ruleIds, activities, 1);
        
        assertEq(registry.globalReputation(user1), 15);
    }

    function test_SyncToRegistry_ComplexScore() public {
        vm.startPrank(admin);
        repSystem.setEntropyFactor(community1, 1.5e18); // 1.5x multiplier
        repSystem.setNFTBoost(address(nft1), 25);
        vm.stopPrank();
        
        nft1.mint(user1, 1);
        
        vm.prank(community1);
        repSystem.setRule(keccak256("PREMIUM"), 30, 4, 200, "Premium");
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("PREMIUM");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 10;
        
        vm.prank(address(repSystem));
        repSystem.syncToRegistry(user1, communities, ruleIds, activities, 2);
        
        // Computed: Base: 30 + 10*4 = 70, with 1.5x = 105, NFT: 25, Total: 130
        // But maxChange=100 limits the update to 100
        assertEq(registry.globalReputation(user1), 100);
    }

    // ====================================
    // Integration Tests
    // ====================================

    function test_CompleteReputationFlow() public {
        // 1. Admin sets up system
        vm.startPrank(admin);
        repSystem.setEntropyFactor(community1, 1.2e18);
        repSystem.setNFTBoost(address(nft1), 30);
        vm.stopPrank();
        
        // 2. Community sets rules
        vm.prank(community1);
        repSystem.setRule(keccak256("ACTIVE"), 15, 2, 100, "Active Member");
        
        // 3. User earns NFT
        nft1.mint(user1, 1);
        
        // 4. Compute and sync reputation
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("ACTIVE");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 20;
        
        vm.prank(address(repSystem));
        repSystem.syncToRegistry(user1, communities, ruleIds, activities, 3);
        
        // Base: 15 + 20*2 = 55, with 1.2x = 66, NFT: 30, Total: 96
        assertEq(registry.globalReputation(user1), 96);
    }
}
