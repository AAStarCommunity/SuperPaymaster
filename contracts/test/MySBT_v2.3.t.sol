// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/tokens/MySBT_v2.3.sol";
import "../../src/paymasters/v2/tokens/DefaultReputationCalculator.sol";
import "../../src/paymasters/v2/interfaces/IMySBT.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title MySBT v2.1 Test Suite
 * @notice Comprehensive tests for white-label SBT system
 */

// ====================================
// Mock Contracts
// ====================================

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {
        _mint(msg.sender, 1000000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract MockGTokenStaking {
    MockGToken public gtoken;

    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public locks;

    constructor(address _gtoken) {
        gtoken = MockGToken(_gtoken);
    }

    function stake(uint256 amount) external returns (uint256) {
        gtoken.transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
        return amount;
    }

    function lockStake(address user, uint256 amount, string memory /* purpose */) external {
        require(balances[user] >= locks[user][msg.sender] + amount, "Insufficient balance");
        locks[user][msg.sender] += amount;
    }

    function unlockStake(address user, uint256 amount) external returns (uint256) {
        require(locks[user][msg.sender] >= amount, "Insufficient lock");
        locks[user][msg.sender] -= amount;
        return amount;
    }

    function balanceOf(address user) external view returns (uint256) {
        return balances[user];
    }

    function getLockedStake(address user, address locker) external view returns (uint256) {
        return locks[user][locker];
    }
}

contract MockRegistry {
    mapping(address => bool) public registeredCommunities;

    function registerCommunity(address community) external {
        registeredCommunities[community] = true;
    }

    function isRegisteredCommunity(address community) external view returns (bool) {
        return registeredCommunities[community];
    }
}

contract MockNFT is ERC721 {
    uint256 private _tokenIdCounter;

    constructor() ERC721("MockNFT", "MNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _tokenIdCounter++;
        _mint(to, tokenId);
        return tokenId;
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "ipfs://mock-nft-uri";
    }
}

// ====================================
// Test Contract
// ====================================

contract MySBT_v2_3_Test is Test {
    MySBT_v2_3 public sbt;
    MockGToken public gtoken;
    MockGTokenStaking public staking;
    MockRegistry public registry;
    MockNFT public nft;
    DefaultReputationCalculator public repCalc;

    address public dao = address(0x1000);
    address public community1 = address(0x2001);
    address public community2 = address(0x2002);
    address public user1 = address(0x3001);
    address public user2 = address(0x3002);
    address public user3 = address(0x3003);

    event SBTMinted(
        address indexed user,
        uint256 indexed tokenId,
        address indexed firstCommunity,
        uint256 timestamp
    );

    event MembershipAdded(
        uint256 indexed tokenId,
        address indexed community,
        string metadata,
        uint256 timestamp
    );

    event NFTBound(
        uint256 indexed tokenId,
        address indexed community,
        address nftContract,
        uint256 nftTokenId,
        uint256 timestamp
    );

    event AvatarSet(
        uint256 indexed tokenId,
        address nftContract,
        uint256 nftTokenId,
        bool isCustom,
        uint256 timestamp
    );

    function setUp() public {
        // Deploy mock contracts
        gtoken = new MockGToken();
        staking = new MockGTokenStaking(address(gtoken));
        registry = new MockRegistry();
        nft = new MockNFT();

        // Deploy MySBT v2.1
        sbt = new MySBT_v2_3(
            address(gtoken),
            address(staking),
            address(registry),
            dao
        );

        // Deploy reputation calculator
        repCalc = new DefaultReputationCalculator(address(sbt));

        // Register communities
        registry.registerCommunity(community1);
        registry.registerCommunity(community2);

        // Setup users with GToken
        gtoken.mint(user1, 1000 ether);
        gtoken.mint(user2, 1000 ether);
        gtoken.mint(user3, 1000 ether);

        // Users stake GToken
        vm.startPrank(user1);
        gtoken.approve(address(staking), 1000 ether);
        staking.stake(100 ether);
        gtoken.approve(address(sbt), 1000 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        gtoken.approve(address(staking), 1000 ether);
        staking.stake(100 ether);
        gtoken.approve(address(sbt), 1000 ether);
        vm.stopPrank();

        vm.startPrank(user3);
        gtoken.approve(address(staking), 1000 ether);
        staking.stake(100 ether);
        gtoken.approve(address(sbt), 1000 ether);
        vm.stopPrank();
    }

    // ====================================
    // Test: Idempotent Mint
    // ====================================

    function test_FirstMint_CreatesSBT() public {
        vm.prank(community1);
        vm.expectEmit(true, true, true, false);
        emit SBTMinted(user1, 1, community1, block.timestamp);

        (uint256 tokenId, bool isNewMint) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        assertEq(tokenId, 1, "Token ID should be 1");
        assertTrue(isNewMint, "Should be new mint");
        assertEq(sbt.ownerOf(tokenId), user1, "User should own SBT");
        assertEq(sbt.getUserSBT(user1), tokenId, "User mapping should be set");

        // Check SBT data
        IMySBT.SBTData memory data = sbt.getSBTData(tokenId);
        assertEq(data.holder, user1, "Holder should be user1");
        assertEq(data.firstCommunity, community1, "First community should be community1");
        assertEq(data.totalCommunities, 1, "Should have 1 community");

        // Check stGToken locked
        assertEq(staking.getLockedStake(user1, address(sbt)), 0.3 ether, "Should lock 0.3 stGToken");
    }

    function test_SecondMint_AddsMembership() public {
        // First mint
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Second mint from different community
        vm.prank(community2);
        vm.expectEmit(true, true, false, false);
        emit MembershipAdded(tokenId, community2, "ipfs://metadata2", block.timestamp);

        (uint256 tokenId2, bool isNewMint) = sbt.mintOrAddMembership(user1, "ipfs://metadata2");

        assertEq(tokenId2, tokenId, "Token ID should be same");
        assertFalse(isNewMint, "Should not be new mint");

        // Check total communities
        IMySBT.SBTData memory data = sbt.getSBTData(tokenId);
        assertEq(data.totalCommunities, 2, "Should have 2 communities");

        // Check memberships
        IMySBT.CommunityMembership[] memory memberships = sbt.getMemberships(tokenId);
        assertEq(memberships.length, 2, "Should have 2 memberships");
        assertEq(memberships[0].community, community1, "First should be community1");
        assertEq(memberships[1].community, community2, "Second should be community2");
    }

    function test_RevertWhen_UnregisteredCommunityMints() public {
        address unregisteredCommunity = address(0x9999);

        vm.prank(unregisteredCommunity);
        vm.expectRevert();
        sbt.mintOrAddMembership(user1, "ipfs://metadata");
    }

    function test_RevertWhen_DuplicateMembership() public {
        // First mint
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Try to add same community again
        vm.prank(community1);
        vm.expectRevert();
        sbt.mintOrAddMembership(user1, "ipfs://metadata2");
    }

    // ====================================
    // Test: Community Membership Verification
    // ====================================

    function test_VerifyCommunityMembership_Success() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        bool isValid = sbt.verifyCommunityMembership(user1, community1);
        assertTrue(isValid, "Should verify membership");
    }

    function test_VerifyCommunityMembership_NoSBT() public {
        bool isValid = sbt.verifyCommunityMembership(user1, community1);
        assertFalse(isValid, "Should not verify without SBT");
    }

    function test_VerifyCommunityMembership_DifferentCommunity() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        bool isValid = sbt.verifyCommunityMembership(user1, community2);
        assertFalse(isValid, "Should not verify different community");
    }

    // ====================================
    // Test: NFT Binding
    // ====================================

    function test_BindNFT_Success() public {
        // Mint SBT
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Mint NFT to user1
        vm.prank(user1);
        uint256 nftId = nft.mint(user1);

        // Bind NFT
        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit NFTBound(tokenId, community1, address(nft), nftId, block.timestamp);

        sbt.bindCommunityNFT(community1, address(nft), nftId);

        // Verify binding
        IMySBT.NFTBinding memory binding = sbt.getNFTBinding(tokenId, community1);
        assertEq(binding.nftContract, address(nft), "NFT contract should match");
        assertEq(binding.nftTokenId, nftId, "NFT token ID should match");
        assertTrue(binding.isActive, "Binding should be active");
    }

    function test_BindNFT_AutoSetAvatar() public {
        // Mint SBT
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Mint NFT
        vm.prank(user1);
        uint256 nftId = nft.mint(user1);

        // Bind NFT (should auto-set as avatar)
        vm.prank(user1);
        sbt.bindCommunityNFT(community1, address(nft), nftId);

        // Check avatar was auto-set
        string memory avatarURI = sbt.getAvatarURI(tokenId);
        assertEq(avatarURI, "ipfs://mock-nft-uri", "Avatar should be NFT URI");
    }

    function test_RevertWhen_BindNFT_NotOwned() public {
        // Mint SBT
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Mint NFT to user2 (different user)
        vm.prank(user2);
        uint256 nftId = nft.mint(user2);

        // Try to bind NFT user1 doesn't own
        vm.prank(user1);
        vm.expectRevert();
        sbt.bindCommunityNFT(community1, address(nft), nftId);
    }

    function test_RevertWhen_BindNFT_AlreadyBound() public {
        // Setup: user1 binds NFT
        vm.prank(community1);
        (uint256 tokenId1,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        vm.prank(user1);
        uint256 nftId = nft.mint(user1);

        vm.prank(user1);
        sbt.bindCommunityNFT(community1, address(nft), nftId);

        // Setup: user2 tries to bind same NFT
        vm.prank(community1);
        sbt.mintOrAddMembership(user2, "ipfs://metadata2");

        // Transfer NFT to user2
        vm.prank(user1);
        nft.transferFrom(user1, user2, nftId);

        // Try to bind already-bound NFT
        vm.prank(user2);
        vm.expectRevert();
        sbt.bindCommunityNFT(community1, address(nft), nftId);
    }

    function test_UnbindNFT_Success() public {
        // Bind NFT
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        vm.prank(user1);
        uint256 nftId = nft.mint(user1);

        vm.prank(user1);
        sbt.bindCommunityNFT(community1, address(nft), nftId);

        // Unbind NFT
        vm.prank(user1);
        sbt.unbindCommunityNFT(community1);

        // Verify unbinding
        IMySBT.NFTBinding memory binding = sbt.getNFTBinding(tokenId, community1);
        assertFalse(binding.isActive, "Binding should be inactive");
    }

    // ====================================
    // Test: Avatar System
    // ====================================

    function test_Avatar_CommunityDefault() public {
        // Set community default avatar
        vm.prank(community1);
        sbt.setCommunityDefaultAvatar("ipfs://community1-avatar");

        // Mint SBT
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Check avatar defaults to community
        string memory avatarURI = sbt.getAvatarURI(tokenId);
        assertEq(avatarURI, "ipfs://community1-avatar", "Should use community default");
    }

    function test_Avatar_AutoFromNFT() public {
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        vm.prank(user1);
        uint256 nftId = nft.mint(user1);

        // Bind NFT (auto-sets avatar)
        vm.prank(user1);
        sbt.bindCommunityNFT(community1, address(nft), nftId);

        string memory avatarURI = sbt.getAvatarURI(tokenId);
        assertEq(avatarURI, "ipfs://mock-nft-uri", "Should use NFT URI");
    }

    function test_Avatar_CustomOverridesAuto() public {
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Mint two NFTs
        vm.prank(user1);
        uint256 nftId1 = nft.mint(user1);
        vm.prank(user1);
        uint256 nftId2 = nft.mint(user1);

        // Bind first NFT (auto-set)
        vm.prank(user1);
        sbt.bindCommunityNFT(community1, address(nft), nftId1);

        // Set custom avatar with second NFT
        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit AvatarSet(tokenId, address(nft), nftId2, true, block.timestamp);

        sbt.setAvatar(address(nft), nftId2);

        // Custom should override auto
        string memory avatarURI = sbt.getAvatarURI(tokenId);
        assertEq(avatarURI, "ipfs://mock-nft-uri", "Should use custom NFT");
    }

    function test_RevertWhen_SetAvatar_NotOwned() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Mint NFT to user2
        vm.prank(user2);
        uint256 nftId = nft.mint(user2);

        // user1 tries to set avatar with user2's NFT
        vm.prank(user1);
        vm.expectRevert();
        sbt.setAvatar(address(nft), nftId);
    }

    function test_DelegateAvatarUsage_Success() public {
        // user1 has SBT
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // user2 has NFT
        vm.prank(user2);
        uint256 nftId = nft.mint(user2);

        // user2 delegates to user1
        vm.prank(user2);
        sbt.delegateAvatarUsage(address(nft), nftId, user1);

        // user1 can now set avatar
        vm.prank(user1);
        sbt.setAvatar(address(nft), nftId);

        string memory avatarURI = sbt.getAvatarURI(tokenId);
        assertEq(avatarURI, "ipfs://mock-nft-uri", "Should use delegated NFT");
    }

    // ====================================
    // Test: Reputation System
    // ====================================

    function test_Reputation_BaseScore() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        uint256 score = sbt.getCommunityReputation(user1, community1);
        assertEq(score, 20, "Base score should be 20");
    }

    function test_Reputation_WithNFTBonus() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Bind NFT
        vm.prank(user1);
        uint256 nftId = nft.mint(user1);
        vm.prank(user1);
        sbt.bindCommunityNFT(community1, address(nft), nftId);

        uint256 score = sbt.getCommunityReputation(user1, community1);
        assertEq(score, 23, "Score should be 20 + 3 (NFT bonus)");
    }

    function test_Reputation_WithActivity() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Record activity (v2.2: event-only, no on-chain state change)
        vm.prank(community1);
        vm.expectEmit(true, true, false, false);
        emit IMySBT.ActivityRecorded(1, community1, block.timestamp / 1 weeks, block.timestamp);
        sbt.recordActivity(user1);

        // Default calculator no longer includes activity (event-driven)
        // Activity bonus only available via external calculator + The Graph
        uint256 score = sbt.getCommunityReputation(user1, community1);
        assertEq(score, 20, "Base score only (activity tracking is event-driven in v2.2)");
    }

    function test_Reputation_ExternalCalculator() public {
        // Set external calculator
        vm.prank(dao);
        sbt.setReputationCalculator(address(repCalc));

        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        uint256 score = sbt.getCommunityReputation(user1, community1);
        assertGt(score, 0, "External calculator should return score");
    }

    function test_Reputation_GlobalScore() public {
        // Mint from two communities
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        vm.prank(community2);
        sbt.mintOrAddMembership(user1, "ipfs://metadata2");

        uint256 globalScore = sbt.getGlobalReputation(user1);
        assertEq(globalScore, 40, "Global should be sum of both (20+20)");
    }

    function test_RecordActivity_OnlyRegisteredCommunity() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Unregistered community tries to record activity
        address unregistered = address(0x9999);
        vm.prank(unregistered);
        // ✅ v2.3: Now reverts instead of silent fail
        vm.expectRevert();
        sbt.recordActivity(user1);
    }

    // ====================================
    // Test: Transfer Restrictions
    // ====================================

    function test_RevertWhen_TransferSBT() public {
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Try to transfer SBT
        vm.prank(user1);
        vm.expectRevert();
        sbt.transferFrom(user1, user2, tokenId);
    }

    // ====================================
    // Test: Admin Functions
    // ====================================

    function test_SetMinLockAmount_OnlyDAO() public {
        vm.prank(dao);
        sbt.setMinLockAmount(0.5 ether);

        assertEq(sbt.minLockAmount(), 0.5 ether, "Should update min lock");
    }

    function test_RevertWhen_SetMinLockAmount_NotDAO() public {
        vm.prank(user1);
        vm.expectRevert();
        sbt.setMinLockAmount(0.5 ether);
    }

    function test_SetMintFee_OnlyDAO() public {
        vm.prank(dao);
        sbt.setMintFee(0.2 ether);

        assertEq(sbt.mintFee(), 0.2 ether, "Should update mint fee");
    }

    function test_SetReputationCalculator_OnlyDAO() public {
        vm.prank(dao);
        sbt.setReputationCalculator(address(repCalc));

        assertEq(sbt.reputationCalculator(), address(repCalc), "Should update calculator");
    }

    function test_SetDAOMultisig_OnlyDAO() public {
        address newDAO = address(0x2000);

        vm.prank(dao);
        sbt.setDAOMultisig(newDAO);

        assertEq(sbt.daoMultisig(), newDAO, "Should update DAO");
    }

    function test_SetRegistry_OnlyDAO() public {
        address newRegistry = address(0x3000);

        vm.prank(dao);
        sbt.setRegistry(newRegistry);

        assertEq(sbt.REGISTRY(), newRegistry, "Should update registry");
    }

    // ====================================
    // Test: Edge Cases
    // ====================================

    function test_GetMemberships_Empty() public {
        IMySBT.CommunityMembership[] memory memberships = sbt.getMemberships(999);
        assertEq(memberships.length, 0, "Should return empty array");
    }

    function test_GetSBTData_NonExistent() public {
        IMySBT.SBTData memory data = sbt.getSBTData(999);
        assertEq(data.holder, address(0), "Holder should be zero address");
    }

    function test_MultipleMints_DifferentUsers() public {
        // user1 mints
        vm.prank(community1);
        (uint256 tokenId1,) = sbt.mintOrAddMembership(user1, "ipfs://user1");

        // user2 mints
        vm.prank(community1);
        (uint256 tokenId2,) = sbt.mintOrAddMembership(user2, "ipfs://user2");

        // user3 mints
        vm.prank(community1);
        (uint256 tokenId3,) = sbt.mintOrAddMembership(user3, "ipfs://user3");

        assertEq(tokenId1, 1, "user1 should have token 1");
        assertEq(tokenId2, 2, "user2 should have token 2");
        assertEq(tokenId3, 3, "user3 should have token 3");
        assertEq(sbt.nextTokenId(), 4, "Next token ID should be 4");
    }

    // ====================================
    // v2.3 Security Tests
    // ====================================

    // H-1: Rate Limiting Tests
    function test_RecordActivity_RateLimiting() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // First activity - should succeed
        vm.prank(community1);
        sbt.recordActivity(user1);

        // Second activity immediately - should fail
        vm.prank(community1);
        vm.expectRevert();  // Just check that it reverts, don't check exact error params
        sbt.recordActivity(user1);

        // After 5 minutes - should succeed
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(community1);
        sbt.recordActivity(user1);
    }

    function test_RecordActivity_RateLimiting_MultiCommunity() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        vm.prank(community2);
        sbt.mintOrAddMembership(user1, "ipfs://metadata2");

        // Record activity in community1
        vm.prank(community1);
        sbt.recordActivity(user1);

        // Can record in community2 immediately (different community)
        vm.prank(community2);
        sbt.recordActivity(user1);

        // But community1 is still rate-limited
        vm.prank(community1);
        vm.expectRevert();
        sbt.recordActivity(user1);
    }

    // H-2: Real-time NFT Ownership Verification
    function test_Reputation_NFTTransferred() public {
        // Mint SBT and bind NFT
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        uint256 nftId = nft.mint(user1);
        vm.prank(user1);
        sbt.bindCommunityNFT(community1, address(nft), nftId);

        // Reputation with NFT = 20 + 3 = 23
        assertEq(sbt.getCommunityReputation(user1, community1), 23);

        // Transfer NFT away
        vm.prank(user1);
        nft.transferFrom(user1, user2, nftId);

        // Reputation without NFT = 20
        assertEq(sbt.getCommunityReputation(user1, community1), 20);
    }

    function test_Reputation_NFTTransferred_ThenBack() public {
        // Setup
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        uint256 nftId = nft.mint(user1);
        vm.prank(user1);
        sbt.bindCommunityNFT(community1, address(nft), nftId);

        // Initial reputation with NFT
        assertEq(sbt.getCommunityReputation(user1, community1), 23);

        // Transfer away
        vm.prank(user1);
        nft.transferFrom(user1, user2, nftId);
        assertEq(sbt.getCommunityReputation(user1, community1), 20);

        // Transfer back
        vm.prank(user2);
        nft.transferFrom(user2, user1, nftId);
        assertEq(sbt.getCommunityReputation(user1, community1), 23);
    }

    // M-1: Pausable Mechanism Tests
    function test_Pause_BlocksOperations() public {
        // Pause contract
        vm.prank(dao);
        sbt.pause();

        // Minting should fail
        vm.prank(community1);
        vm.expectRevert();
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");
    }

    function test_Pause_Unpause_ResumesOperations() public {
        // Pause
        vm.prank(dao);
        sbt.pause();

        // Unpause
        vm.prank(dao);
        sbt.unpause();

        // Minting should succeed
        vm.prank(community1);
        (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");
        assertEq(tokenId, 1);
    }

    function test_Pause_OnlyDAO() public {
        // Non-DAO cannot pause
        vm.prank(user1);
        vm.expectRevert();
        sbt.pause();

        // DAO can pause
        vm.prank(dao);
        sbt.pause();
    }

    function test_Pause_BlocksNFTBinding() public {
        // Setup
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");
        uint256 nftId = nft.mint(user1);

        // Pause
        vm.prank(dao);
        sbt.pause();

        // NFT binding should fail
        vm.prank(user1);
        vm.expectRevert();
        sbt.bindCommunityNFT(community1, address(nft), nftId);
    }

    function test_Pause_BlocksRecordActivity() public {
        // Setup
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        // Pause
        vm.prank(dao);
        sbt.pause();

        // Record activity should fail
        vm.prank(community1);
        vm.expectRevert();
        sbt.recordActivity(user1);
    }

    // M-4: Input Validation Tests
    function test_MintOrAddMembership_EmptyMetadata() public {
        vm.prank(community1);
        vm.expectRevert(abi.encodeWithSelector(MySBT_v2_3.InvalidParameter.selector, "metadata empty"));
        sbt.mintOrAddMembership(user1, "");
    }

    function test_MintOrAddMembership_MetadataTooLong() public {
        // Create metadata > 1024 bytes
        bytes memory longMetadata = new bytes(1025);
        for (uint i = 0; i < 1025; i++) {
            longMetadata[i] = "a";
        }

        vm.prank(community1);
        vm.expectRevert(abi.encodeWithSelector(MySBT_v2_3.InvalidParameter.selector, "metadata too long"));
        sbt.mintOrAddMembership(user1, string(longMetadata));
    }

    function test_BindCommunityNFT_InvalidCommunityAddress() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(MySBT_v2_3.InvalidAddress.selector, address(0)));
        sbt.bindCommunityNFT(address(0), address(nft), 1);
    }

    function test_BindCommunityNFT_InvalidNFTAddress() public {
        vm.prank(community1);
        sbt.mintOrAddMembership(user1, "ipfs://metadata1");

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(MySBT_v2_3.InvalidAddress.selector, address(0)));
        sbt.bindCommunityNFT(community1, address(0), 1);
    }

    // L-3: Admin Events Tests
    function test_SetMinLockAmount_EmitsEvent() public {
        vm.prank(dao);
        vm.expectEmit(true, true, true, true);
        emit IMySBT.MinLockAmountUpdated(0.3 ether, 1 ether, block.timestamp);
        sbt.setMinLockAmount(1 ether);
    }

    function test_SetMintFee_EmitsEvent() public {
        vm.prank(dao);
        vm.expectEmit(true, true, true, true);
        emit IMySBT.MintFeeUpdated(0.1 ether, 0.5 ether, block.timestamp);
        sbt.setMintFee(0.5 ether);
    }

    function test_SetRegistry_EmitsEvent() public {
        address newRegistry = address(0x123);
        vm.prank(dao);
        vm.expectEmit(true, true, true, true);
        emit IMySBT.RegistryUpdated(address(registry), newRegistry, block.timestamp);
        sbt.setRegistry(newRegistry);
    }

    function test_SetDAOMultisig_EmitsEvent() public {
        address newDAO = address(0x456);
        vm.prank(dao);
        vm.expectEmit(true, true, true, true);
        emit IMySBT.DAOMultisigUpdated(dao, newDAO, block.timestamp);
        sbt.setDAOMultisig(newDAO);
    }

    function test_Pause_EmitsEvent() public {
        vm.prank(dao);
        vm.expectEmit(true, true, true, true);
        emit IMySBT.ContractPaused(dao, block.timestamp);
        sbt.pause();
    }

    function test_Unpause_EmitsEvent() public {
        vm.prank(dao);
        sbt.pause();

        vm.prank(dao);
        vm.expectEmit(true, true, true, true);
        emit IMySBT.ContractUnpaused(dao, block.timestamp);
        sbt.unpause();
    }

    // Version Information Tests
    function test_Version() public {
        assertEq(sbt.VERSION(), "2.3.0");
        assertEq(sbt.VERSION_CODE(), 230);
    }
}
