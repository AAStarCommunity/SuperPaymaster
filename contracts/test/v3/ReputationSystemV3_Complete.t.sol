// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/reputation/ReputationSystem.sol";
import "src/core/Registry.sol";
import "src/mocks/MockBLSAggregator.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import "src/interfaces/v3/IRegistry.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("MockNFT", "MNFT") {}
    function mint(address to, uint256 tokenId) external { _mint(to, tokenId); }
}

/// @dev Mock that reverts on balanceOf — used to exercise the try/catch
///      path in ReputationSystem when the boosted collection is misbehaving.
contract BuggyNFT {
    function balanceOf(address) external pure returns (uint256) {
        revert("BuggyNFT: balanceOf disabled");
    }
}

/**
 * @title ReputationSystem_Complete_Test
 * @notice 完整的 ReputationSystem 测试套件
 */
contract ReputationSystem_Complete_Test is Test {
    ReputationSystem public repSystem;
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
        registry = UUPSDeployHelper.deployRegistryProxy(admin, mockStaking, mockSBT);
        
        // Deploy ReputationSystem
        repSystem = new ReputationSystem(address(registry));
        
        // Deploy NFTs for boost testing
        nft1 = new MockNFT();
        nft2 = new MockNFT();
        
        // Authorize repSystem as reputation source
        registry.setReputationSource(address(repSystem), true);

        // Mock staking setRoleExitFee (mockStaking is not a real contract)
        vm.mockCall(mockStaking, abi.encodeWithSignature("setRoleExitFee(bytes32,uint256,uint256)"), "");

        // Set community role owner
        IRegistry.RoleConfig memory commCfg = registry.getRoleConfig(keccak256("COMMUNITY"));
        commCfg.owner = community1;
        registry.configureRole(keccak256("COMMUNITY"), commCfg);
        
        // Mock hasRole to return true for community1 (avoids complex storage manipulation)
        // Mock hasRole to return true for community1 (avoids complex storage manipulation)
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(registry.hasRole.selector, keccak256("COMMUNITY"), community1),
            abi.encode(true)
        );

        // P0-1: Registry routes BLS verification through the aggregator now.
        MockBLSAggregator aggregator = new MockBLSAggregator();
        registry.setBLSAggregator(address(aggregator));

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
        vm.expectRevert(abi.encodeWithSelector(ReputationSystem.NotAuthorized.selector));
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
        vm.prank(user1);
        repSystem.updateNFTHoldStart(address(nft1));
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("DEFAULT");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 5;
        
        vm.warp(block.timestamp + 8 days);
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // Base score: 15 (base 10 + 5 bonus), NFT boost: 50, Total: 65
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
        vm.startPrank(user1);
        repSystem.updateNFTHoldStart(address(nft1));
        repSystem.updateNFTHoldStart(address(nft2));
        vm.stopPrank();
        
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("DEFAULT");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 5;
        
        vm.warp(block.timestamp + 8 days);
        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        
        // Base: 15 (base 10 + 5 bonus), NFT1: 50, NFT2: 100, Total: 165
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
        
        // Mock BLS precompile
        vm.mockCall(address(0x11), "", abi.encode(uint256(1)));
        // P0-1: Registry routes through aggregator → proof now is (signerMask, sigG2).
        bytes memory proof = abi.encode(uint256(0x7F), new bytes(256));

        vm.prank(address(repSystem));
        repSystem.syncToRegistry(user1, communities, ruleIds, activities, 1, proof);
        
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
        
        // Mock BLS
        vm.mockCall(address(0x11), "", abi.encode(uint256(1)));
        // P0-1: Registry routes through aggregator → proof now is (signerMask, sigG2).
        bytes memory proof = abi.encode(uint256(0x7F), new bytes(256));

        vm.prank(address(repSystem));
        repSystem.syncToRegistry(user1, communities, ruleIds, activities, 2, proof);
        
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
        vm.prank(user1);
        repSystem.updateNFTHoldStart(address(nft1));
        
        // 4. Compute and sync reputation
        address[] memory communities = new address[](1);
        communities[0] = community1;
        
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("ACTIVE");
        
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 20;
        
        // Mock BLS
        vm.mockCall(address(0x11), "", abi.encode(uint256(1)));
        // P0-1: Registry routes through aggregator → proof now is (signerMask, sigG2).
        bytes memory proof = abi.encode(uint256(0x7F), new bytes(256));

        vm.prank(address(repSystem));
        vm.warp(block.timestamp + 8 days);
        repSystem.syncToRegistry(user1, communities, ruleIds, activities, 3, proof);

        // Base: 15 + 20*2 = 55, with 1.2x = 66, NFT: 30, Total: 96
        assertEq(registry.globalReputation(user1), 96);
    }

    // ====================================================================
    // Coverage Boost — v5.4 (target ≥85%)
    // ====================================================================

    // ---- setCommunityReputation ----

    /// @notice Owner can set arbitrary community reputation
    function test_SetCommunityReputation_OwnerCanSet() public {
        vm.prank(admin);
        repSystem.setCommunityReputation(community1, user1, 42);
        assertEq(repSystem.communityReputations(community1, user1), 42);
    }

    /// @notice Reputation source (whitelisted in Registry) can set
    function test_SetCommunityReputation_ReputationSourceCanSet() public {
        // repSystem itself is whitelisted in setUp; verify via direct call as
        // any other authorized source — use admin to whitelist a new address.
        address dvtNode = address(0xD0D0);
        vm.prank(admin);
        registry.setReputationSource(dvtNode, true);

        vm.prank(dvtNode);
        repSystem.setCommunityReputation(community1, user1, 77);
        assertEq(repSystem.communityReputations(community1, user1), 77);
    }

    /// @notice Random caller is rejected
    function test_SetCommunityReputation_Unauthorized_Reverts() public {
        vm.expectRevert(ReputationSystem.Unauthorized.selector);
        vm.prank(user1);
        repSystem.setCommunityReputation(community1, user2, 10);
    }

    /// @notice Update emits CommunityReputationUpdated event
    function test_SetCommunityReputation_EmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(repSystem));
        emit ReputationSystem.CommunityReputationUpdated(community1, user1, 99);
        vm.prank(admin);
        repSystem.setCommunityReputation(community1, user1, 99);
    }

    // ---- setRule bound checks (P1-X audit fix) ----

    function test_SetRule_BaseTooHigh_Reverts() public {
        vm.expectRevert(ReputationSystem.InvalidInput.selector);
        vm.prank(community1);
        repSystem.setRule(keccak256("R"), 10_001, 1, 100, "over-base");
    }

    function test_SetRule_BonusTooHigh_Reverts() public {
        vm.expectRevert(ReputationSystem.InvalidInput.selector);
        vm.prank(community1);
        repSystem.setRule(keccak256("R"), 1, 10_001, 100, "over-bonus");
    }

    function test_SetRule_MaxTooHigh_Reverts() public {
        vm.expectRevert(ReputationSystem.InvalidInput.selector);
        vm.prank(community1);
        repSystem.setRule(keccak256("R"), 1, 1, 100_001, "over-max");
    }

    /// @notice Updating an existing rule does NOT push a duplicate into communityActiveRules
    function test_SetRule_UpdateExistingDoesNotDuplicate() public {
        bytes32 rid = keccak256("STABLE");
        vm.startPrank(community1);
        repSystem.setRule(rid, 10, 1, 100, "v1");
        repSystem.setRule(rid, 20, 2, 200, "v2");
        repSystem.setRule(rid, 30, 3, 300, "v3");
        vm.stopPrank();

        bytes32[] memory active = repSystem.getActiveRules(community1);
        assertEq(active.length, 1, "rule pushed only once even with multiple updates");
        assertEq(active[0], rid);
    }

    // ---- setNFTBoost bound checks ----

    function test_SetNFTBoost_ZeroAddress_Reverts() public {
        vm.expectRevert(ReputationSystem.InvalidAddress.selector);
        vm.prank(admin);
        repSystem.setNFTBoost(address(0), 10);
    }

    function test_SetNFTBoost_UpdateExistingDoesNotPush() public {
        vm.startPrank(admin);
        repSystem.setNFTBoost(address(nft1), 10);
        repSystem.setNFTBoost(address(nft1), 50);  // update
        repSystem.setNFTBoost(address(nft1), 99);  // update again
        vm.stopPrank();

        // boostedCollections should have exactly 1 entry for nft1
        assertEq(repSystem.boostedCollections(0), address(nft1));
        // Cannot directly query length; expect revert on index 1
        vm.expectRevert();
        repSystem.boostedCollections(1);
    }

    function test_SetNFTBoost_MaxCollectionsReached_Reverts() public {
        vm.startPrank(admin);
        // Fill up to MAX_BOOSTED_COLLECTIONS (50). Use unique addresses.
        for (uint160 i = 1; i <= 50; i++) {
            repSystem.setNFTBoost(address(uint160(0x1000) + i), 1);
        }
        // 51st should revert
        vm.expectRevert(ReputationSystem.MaxBoostedReached.selector);
        repSystem.setNFTBoost(address(uint160(0x1000 + 51)), 1);
        vm.stopPrank();
    }

    // ---- computeScore branches ----

    function test_ComputeScore_InvalidInput_RuleIdsLengthMismatch() public {
        address[] memory communities = new address[](2);
        communities[0] = community1; communities[1] = community2;
        bytes32[][] memory ruleIds = new bytes32[][](1); // wrong length
        ruleIds[0] = new bytes32[](0);
        uint256[][] memory activities = new uint256[][](2);
        activities[0] = new uint256[](0);
        activities[1] = new uint256[](0);

        vm.expectRevert(ReputationSystem.InvalidInput.selector);
        repSystem.computeScore(user1, communities, ruleIds, activities);
    }

    function test_ComputeScore_InvalidInput_ActivitiesLengthMismatch() public {
        address[] memory communities = new address[](2);
        communities[0] = community1; communities[1] = community2;
        bytes32[][] memory ruleIds = new bytes32[][](2);
        ruleIds[0] = new bytes32[](0);
        ruleIds[1] = new bytes32[](0);
        uint256[][] memory activities = new uint256[][](1);  // wrong length
        activities[0] = new uint256[](0);

        vm.expectRevert(ReputationSystem.InvalidInput.selector);
        repSystem.computeScore(user1, communities, ruleIds, activities);
    }

    /// @notice NFT boost ignored if user has not called updateNFTHoldStart
    function test_ComputeScore_NFTBoostIgnored_NoHoldStart() public {
        vm.prank(admin);
        repSystem.setNFTBoost(address(nft1), 50);
        nft1.mint(user1, 1);
        // user1 has NFT but did NOT call updateNFTHoldStart → no boost

        address[] memory communities = new address[](1);
        communities[0] = community1;
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("ANY");
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);

        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        // baseScore=10 (default) + activities[0]=0*1=0; no NFT boost (holdStart=0)
        assertEq(score, 10);
    }

    /// @notice NFT boost ignored if held for < 7 days
    function test_ComputeScore_NFTBoostIgnored_HoldUnder7Days() public {
        vm.prank(admin);
        repSystem.setNFTBoost(address(nft1), 50);
        nft1.mint(user1, 1);
        vm.prank(user1);
        repSystem.updateNFTHoldStart(address(nft1));

        // Only 5 days elapsed
        vm.warp(block.timestamp + 5 days);

        address[] memory communities = new address[](1);
        communities[0] = community1;
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("ANY");
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);

        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        // No NFT boost yet (< 7 days)
        assertEq(score, 10);
    }

    /// @notice NFT boost ignored if user no longer holds the NFT (balance == 0)
    function test_ComputeScore_NFTBoostIgnored_BalanceZero() public {
        vm.prank(admin);
        repSystem.setNFTBoost(address(nft1), 50);
        nft1.mint(user1, 1);
        vm.prank(user1);
        repSystem.updateNFTHoldStart(address(nft1));

        vm.warp(block.timestamp + 8 days);

        // user1 transfers NFT away
        vm.prank(user1);
        nft1.transferFrom(user1, user2, 1);

        address[] memory communities = new address[](1);
        communities[0] = community1;
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("ANY");
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);

        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        // balance==0 → no boost
        assertEq(score, 10);
    }

    /// @notice Bonus capped at maxBonus
    function test_ComputeScore_BonusCappedAtMax() public {
        vm.prank(community1);
        repSystem.setRule(keccak256("CAP"), 10, 5, 30, "cap-test");

        address[] memory communities = new address[](1);
        communities[0] = community1;
        bytes32[][] memory ruleIds = new bytes32[][](1);
        ruleIds[0] = new bytes32[](1);
        ruleIds[0][0] = keccak256("CAP");
        uint256[][] memory activities = new uint256[][](1);
        activities[0] = new uint256[](1);
        activities[0][0] = 100;  // 100 * 5 = 500, capped to 30

        uint256 score = repSystem.computeScore(user1, communities, ruleIds, activities);
        // base 10 + capped bonus 30 = 40
        assertEq(score, 40);
    }

    // ---- calculateReputation (IReputationCalculator impl) ----

    function test_CalculateReputation_NoActiveRules_ReturnsFromDefault() public {
        // community2 has no rules set
        (uint256 communityScore, uint256 globalScore) = repSystem.calculateReputation(user1, community2, 0);
        // With no rules, score should be 0 (loop doesn't iterate)
        assertEq(communityScore, 0);
        assertEq(globalScore, 0);
    }

    function test_CalculateReputation_WithActiveRules() public {
        vm.startPrank(community1);
        repSystem.setRule(keccak256("R1"), 10, 0, 0, "r1");
        repSystem.setRule(keccak256("R2"), 20, 0, 0, "r2");
        vm.stopPrank();

        (uint256 communityScore, uint256 globalScore) = repSystem.calculateReputation(user1, community1, 0);
        assertEq(communityScore, 30);
        assertEq(globalScore, 30);  // simplification: global == community
    }

    // ---- getReputationBreakdown ----

    function test_GetReputationBreakdown_NoRules_UsesDefault() public {
        (uint256 defBase, uint256 defActivity, , ) = repSystem.defaultRule();

        (uint256 baseScore, uint256 nftBonus, uint256 activityBonus, uint256 multiplier) =
            repSystem.getReputationBreakdown(user1, community2, 0);
        assertEq(baseScore, defBase, "default base");
        assertEq(activityBonus, defActivity, "default activity");
        assertEq(multiplier, 1e18, "default multiplier 1.0");
        assertEq(nftBonus, 0, "no NFT held");
    }

    function test_GetReputationBreakdown_WithRulesAndEntropy() public {
        vm.prank(community1);
        repSystem.setRule(keccak256("PRIMARY"), 50, 5, 1000, "primary");
        vm.prank(admin);
        repSystem.setEntropyFactor(community1, 1.5e18);

        (uint256 baseScore, , uint256 activityBonus, uint256 multiplier) =
            repSystem.getReputationBreakdown(user1, community1, 0);
        assertEq(baseScore, 50);
        assertEq(activityBonus, 5);
        assertEq(multiplier, 1.5e18);
    }

    function test_GetReputationBreakdown_NFTBonusAccumulates() public {
        vm.startPrank(admin);
        repSystem.setNFTBoost(address(nft1), 30);
        repSystem.setNFTBoost(address(nft2), 70);
        vm.stopPrank();
        nft1.mint(user1, 1);
        nft2.mint(user1, 2);

        (, uint256 nftBonus, , ) = repSystem.getReputationBreakdown(user1, community1, 0);
        // 30 + 70 = 100
        assertEq(nftBonus, 100);
    }

    function test_GetReputationBreakdown_BuggyNFT_IsCaught() public {
        // Whitelist a collection whose balanceOf reverts; try/catch in
        // getReputationBreakdown should swallow the failure and skip its boost.
        BuggyNFT buggy = new BuggyNFT();
        vm.prank(admin);
        repSystem.setNFTBoost(address(buggy), 50);

        (, uint256 nftBonus, , ) = repSystem.getReputationBreakdown(user1, community1, 0);
        // Buggy NFT contributed 0 (catch branch hit)
        assertEq(nftBonus, 0);
    }

    // ---- getActiveRules ----

    function test_GetActiveRules_EmptyForNewCommunity() public {
        bytes32[] memory rules = repSystem.getActiveRules(community2);
        assertEq(rules.length, 0);
    }

    function test_GetActiveRules_ReflectsInsertion() public {
        vm.startPrank(community1);
        repSystem.setRule(keccak256("A"), 5, 0, 0, "a");
        repSystem.setRule(keccak256("B"), 7, 0, 0, "b");
        vm.stopPrank();

        bytes32[] memory rules = repSystem.getActiveRules(community1);
        assertEq(rules.length, 2);
        assertEq(rules[0], keccak256("A"));
        assertEq(rules[1], keccak256("B"));
    }

    // ---- updateNFTHoldStart ----

    function test_UpdateNFTHoldStart_DoesNotHoldNFT_Reverts() public {
        vm.expectRevert(ReputationSystem.DoesNotHoldNFT.selector);
        vm.prank(user1);
        repSystem.updateNFTHoldStart(address(nft1));
    }

    function test_UpdateNFTHoldStart_FirstTimeRecords() public {
        nft1.mint(user1, 1);
        uint256 t0 = block.timestamp;
        vm.prank(user1);
        repSystem.updateNFTHoldStart(address(nft1));
        assertEq(repSystem.nftHoldStart(user1, address(nft1)), t0);
    }

    function test_UpdateNFTHoldStart_SubsequentCallsDoNotOverwrite() public {
        nft1.mint(user1, 1);

        // First call records block.timestamp at the time of call.
        vm.prank(user1);
        repSystem.updateNFTHoldStart(address(nft1));
        uint256 firstWrite = repSystem.nftHoldStart(user1, address(nft1));
        assertGt(firstWrite, 0, "first write recorded");

        // 30 days later, call again — must NOT overwrite, regardless of new timestamp.
        vm.warp(block.timestamp + 30 days);
        vm.prank(user1);
        repSystem.updateNFTHoldStart(address(nft1));

        assertEq(
            repSystem.nftHoldStart(user1, address(nft1)),
            firstWrite,
            "anti-reset: subsequent call must not overwrite earlier holdStart"
        );
    }

    function test_UpdateNFTHoldStart_InvalidCollection_Reverts() public {
        // BuggyNFT.balanceOf reverts → try/catch path goes to `revert InvalidCollection()`
        BuggyNFT buggy = new BuggyNFT();
        vm.expectRevert(ReputationSystem.InvalidCollection.selector);
        vm.prank(user1);
        repSystem.updateNFTHoldStart(address(buggy));
    }
}
