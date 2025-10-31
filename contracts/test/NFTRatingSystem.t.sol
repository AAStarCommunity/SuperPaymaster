// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/reputation/NFTRatingRegistry.sol";
import "../../src/paymasters/v2/reputation/WeightedReputationCalculator.sol";
import "../../src/paymasters/v2/tokens/MySBT_v2.4.0.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/core/Registry.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Mock GToken for testing
contract GToken is ERC20, Ownable {
    constructor(address initialOwner) ERC20("GToken", "GT") Ownable(initialOwner) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

/// @notice Mock NFT for testing
contract MockNFT is ERC721 {
    uint256 private _nextTokenId = 1;

    constructor() ERC721("MockNFT", "MNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

/// @notice Mock high-quality NFT (e.g., BAYC equivalent)
contract PremiumNFT is ERC721 {
    uint256 private _nextTokenId = 1;

    constructor() ERC721("PremiumNFT", "PNFT") {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _mint(to, tokenId);
        return tokenId;
    }
}

contract NFTRatingSystemTest is Test {
    NFTRatingRegistry public ratingRegistry;
    WeightedReputationCalculator public calculator;
    MySBT_v2_4_0 public mysbt;
    GTokenStaking public staking;
    GToken public gtoken;
    Registry public registry;
    MockNFT public mockNFT;
    PremiumNFT public premiumNFT;

    address public dao = makeAddr("dao");
    address public treasury = makeAddr("treasury");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public community1 = makeAddr("community1");
    address public community2 = makeAddr("community2");
    address public community3 = makeAddr("community3");

    function setUp() public {
        // Deploy core contracts
        vm.startPrank(dao);

        gtoken = new GToken(dao);
        staking = new GTokenStaking(address(gtoken));
        registry = new Registry(address(staking));

        mysbt = new MySBT_v2_4_0(
            address(gtoken),
            address(staking),
            address(registry),
            dao
        );

        // Deploy rating system
        ratingRegistry = new NFTRatingRegistry(address(registry), dao);
        calculator = new WeightedReputationCalculator(address(mysbt), address(ratingRegistry));

        // Configure staking
        staking.setTreasury(treasury);
        uint256[] memory emptyTiers = new uint256[](0);
        staking.configureLocker(
            address(mysbt),
            true,
            0.1 ether,
            emptyTiers,
            emptyTiers,
            address(0)
        );

        vm.stopPrank();

        // Deploy NFTs
        mockNFT = new MockNFT();
        premiumNFT = new PremiumNFT();

        // Setup users with GT
        vm.startPrank(dao);
        gtoken.mint(user1, 100 ether);
        gtoken.mint(user2, 100 ether);
        vm.stopPrank();

        // Users stake and approve
        vm.startPrank(user1);
        gtoken.approve(address(staking), 50 ether);
        staking.stake(50 ether);
        gtoken.approve(address(mysbt), 1 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        gtoken.approve(address(staking), 50 ether);
        staking.stake(50 ether);
        gtoken.approve(address(mysbt), 1 ether);
        vm.stopPrank();

        // Mock Registry.isRegisteredCommunity for all communities
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(Registry.isRegisteredCommunity.selector, community1),
            abi.encode(true)
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(Registry.isRegisteredCommunity.selector, community2),
            abi.encode(true)
        );
        vm.mockCall(
            address(registry),
            abi.encodeWithSelector(Registry.isRegisteredCommunity.selector, community3),
            abi.encode(true)
        );
    }

    // ====================================
    // NFT Rating Registry Tests
    // ====================================

    function test_UnverifiedNFT_DefaultMultiplier() public {
        // Unverified NFT should have 0.1x multiplier (100 basis points)
        uint256 multiplier = ratingRegistry.getMultiplier(address(mockNFT));
        assertEq(multiplier, 100); // 0.1x
    }

    function test_VoteForRating_Success() public {
        // Community1 votes for mockNFT with 1.0x rating (1000 basis points)
        vm.prank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        // Check vote recorded
        (uint256 voteMultiplier, uint256 weight, uint256 timestamp) =
            ratingRegistry.getVote(address(mockNFT), community1);
        assertEq(voteMultiplier, 1000);
        assertEq(weight, 1);
        assertGt(timestamp, 0);
    }

    function test_VoteForRating_BelowThreshold() public {
        // Single vote (< 3 threshold) should not verify NFT
        vm.prank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        (uint256 totalVotes, uint256 currentMultiplier, bool isVerified) =
            ratingRegistry.getRating(address(mockNFT));

        assertEq(totalVotes, 1);
        assertEq(currentMultiplier, 100); // Still unverified (0.1x)
        assertFalse(isVerified);
    }

    function test_VoteForRating_ReachThreshold() public {
        // 3 votes should verify NFT
        vm.prank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        vm.prank(community2);
        ratingRegistry.voteForRating(address(mockNFT), 1100);

        vm.prank(community3);
        ratingRegistry.voteForRating(address(mockNFT), 900);

        (uint256 totalVotes, uint256 currentMultiplier, bool isVerified) =
            ratingRegistry.getRating(address(mockNFT));

        assertEq(totalVotes, 3);
        // Weighted average: (1000 + 1100 + 900) / 3 = 1000
        assertEq(currentMultiplier, 1000); // 1.0x
        assertTrue(isVerified);
    }

    function test_VoteForRating_RevertIfUnauthorized() public {
        // Non-community address should fail
        vm.prank(user1);
        vm.expectRevert();
        ratingRegistry.voteForRating(address(mockNFT), 1000);
    }

    function test_VoteForRating_RevertIfOutOfRange() public {
        // Multiplier below 700 should fail
        vm.prank(community1);
        vm.expectRevert();
        ratingRegistry.voteForRating(address(mockNFT), 600);

        // Multiplier above 1300 should fail
        vm.prank(community1);
        vm.expectRevert();
        ratingRegistry.voteForRating(address(mockNFT), 1400);
    }

    function test_VoteForRating_RevertIfAlreadyVoted() public {
        vm.startPrank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        // Try to vote again
        vm.expectRevert();
        ratingRegistry.voteForRating(address(mockNFT), 1100);
        vm.stopPrank();
    }

    function test_GetAllRatedNFTs() public {
        // Vote for 2 NFTs
        vm.prank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        vm.prank(community1);
        ratingRegistry.voteForRating(address(premiumNFT), 1200);

        address[] memory ratedNFTs = ratingRegistry.getAllRatedNFTs();
        assertEq(ratedNFTs.length, 2);
        assertEq(ratedNFTs[0], address(mockNFT));
        assertEq(ratedNFTs[1], address(premiumNFT));
    }

    // ====================================
    // Weighted Reputation Calculator Tests
    // ====================================

    function test_Calculator_NoMembership() public {
        // User without SBT should have 0 reputation
        (uint256 communityScore, uint256 globalScore) =
            calculator.calculateReputation(user1, community1, 0);

        assertEq(communityScore, 0);
        assertEq(globalScore, 0);
    }

    function test_Calculator_BaseReputation() public {
        // Mint SBT for user1
        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        // Check base reputation (20 points, no NFTs)
        (uint256 communityScore, uint256 globalScore) =
            calculator.calculateReputation(user1, community1, tokenId);

        assertEq(communityScore, 20); // BASE_REPUTATION
        assertEq(globalScore, 20);
    }

    function test_Calculator_UnverifiedNFT_Bonus() public {
        // 1. Mint SBT
        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        // 2. Bind unverified NFT
        uint256 nftTokenId = mockNFT.mint(user1);
        vm.prank(user1);
        mysbt.bindNFT(address(mockNFT), nftTokenId);

        // 3. Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        // 4. Check reputation
        // Time weight: 6 months = 6 points
        // Multiplier: 0.1x (100 basis points, unverified)
        // NFT bonus: 6 × 100 / 1000 = 0.6 points (truncated to 0)
        // Total: 20 (base) + 0 (NFT) = 20
        (uint256 communityScore,) = calculator.calculateReputation(user1, community1, tokenId);
        assertEq(communityScore, 20);
    }

    function test_Calculator_VerifiedNFT_Bonus() public {
        // 1. Vote to verify mockNFT (1.0x rating)
        vm.prank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community2);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community3);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        // 2. Mint SBT and bind NFT
        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        uint256 nftTokenId = mockNFT.mint(user1);
        vm.prank(user1);
        mysbt.bindNFT(address(mockNFT), nftTokenId);

        // 3. Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        // 4. Check reputation
        // Time weight: 6 months = 6 points
        // Multiplier: 1.0x (1000 basis points)
        // NFT bonus: 6 × 1000 / 1000 = 6 points
        // Total: 20 (base) + 6 (NFT) = 26
        (uint256 communityScore,) = calculator.calculateReputation(user1, community1, tokenId);
        assertEq(communityScore, 26);
    }

    function test_Calculator_PremiumNFT_HigherRating() public {
        // 1. Vote for premiumNFT with 1.3x rating (max)
        vm.prank(community1);
        ratingRegistry.voteForRating(address(premiumNFT), 1300);
        vm.prank(community2);
        ratingRegistry.voteForRating(address(premiumNFT), 1300);
        vm.prank(community3);
        ratingRegistry.voteForRating(address(premiumNFT), 1300);

        // 2. Mint SBT and bind premium NFT
        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        uint256 nftTokenId = premiumNFT.mint(user1);
        vm.prank(user1);
        mysbt.bindNFT(address(premiumNFT), nftTokenId);

        // 3. Fast forward 12 months (max time weight)
        vm.warp(block.timestamp + 360 days);

        // 4. Check reputation
        // Time weight: 12 months (max)
        // Multiplier: 1.3x (1300 basis points)
        // NFT bonus: 12 × 1300 / 1000 = 15.6 points (15 after truncation)
        // Total: 20 (base) + 15 (NFT) = 35
        (uint256 communityScore,) = calculator.calculateReputation(user1, community1, tokenId);
        assertEq(communityScore, 35);
    }

    function test_Calculator_MultipleNFTs() public {
        // 1. Verify both NFTs
        vm.prank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community2);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community3);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        vm.prank(community1);
        ratingRegistry.voteForRating(address(premiumNFT), 1300);
        vm.prank(community2);
        ratingRegistry.voteForRating(address(premiumNFT), 1300);
        vm.prank(community3);
        ratingRegistry.voteForRating(address(premiumNFT), 1300);

        // 2. Mint SBT and bind 2 NFTs
        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        vm.startPrank(user1);
        uint256 nft1 = mockNFT.mint(user1);
        uint256 nft2 = premiumNFT.mint(user1);
        mysbt.bindNFT(address(mockNFT), nft1);
        mysbt.bindNFT(address(premiumNFT), nft2);
        vm.stopPrank();

        // 3. Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        // 4. Check reputation
        // mockNFT: 6 × 1000 / 1000 = 6 points
        // premiumNFT: 6 × 1300 / 1000 = 7.8 → 7 points
        // Total: 20 (base) + 6 + 7 = 33
        (uint256 communityScore,) = calculator.calculateReputation(user1, community1, tokenId);
        assertEq(communityScore, 33);
    }

    function test_Calculator_NFTTransferAway() public {
        // 1. Verify NFT
        vm.prank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community2);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community3);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        // 2. Mint SBT and bind NFT
        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        uint256 nftTokenId = mockNFT.mint(user1);
        vm.prank(user1);
        mysbt.bindNFT(address(mockNFT), nftTokenId);

        // 3. Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        // 4. Check reputation before transfer
        (uint256 scoreBefore,) = calculator.calculateReputation(user1, community1, tokenId);
        assertEq(scoreBefore, 26); // 20 + 6

        // 5. Transfer NFT away
        vm.prank(user1);
        mockNFT.transferFrom(user1, user2, nftTokenId);

        // 6. Check reputation after transfer (query-time verification)
        (uint256 scoreAfter,) = calculator.calculateReputation(user1, community1, tokenId);
        assertEq(scoreAfter, 20); // NFT bonus removed
    }

    function test_Calculator_GetReputationBreakdown() public {
        // 1. Verify NFT
        vm.prank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community2);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community3);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        // 2. Mint SBT and bind NFT
        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        uint256 nftTokenId = mockNFT.mint(user1);
        vm.prank(user1);
        mysbt.bindNFT(address(mockNFT), nftTokenId);

        // 3. Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        // 4. Check breakdown
        (uint256 baseScore, uint256 nftBonus, uint256 activityBonus, uint256 multiplier) =
            calculator.getReputationBreakdown(user1, community1, tokenId);

        assertEq(baseScore, 20);
        assertEq(nftBonus, 6);
        assertEq(activityBonus, 0);
        assertEq(multiplier, 100); // 1.0x community multiplier
    }

    function test_Calculator_GetNFTBonusBreakdown() public {
        // 1. Verify both NFTs
        vm.prank(community1);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community2);
        ratingRegistry.voteForRating(address(mockNFT), 1000);
        vm.prank(community3);
        ratingRegistry.voteForRating(address(mockNFT), 1000);

        vm.prank(community1);
        ratingRegistry.voteForRating(address(premiumNFT), 1300);
        vm.prank(community2);
        ratingRegistry.voteForRating(address(premiumNFT), 1300);
        vm.prank(community3);
        ratingRegistry.voteForRating(address(premiumNFT), 1300);

        // 2. Mint SBT and bind 2 NFTs
        vm.prank(community1);
        (uint256 tokenId,) = mysbt.mintOrAddMembership(user1, "ipfs://metadata");

        vm.startPrank(user1);
        uint256 nft1 = mockNFT.mint(user1);
        uint256 nft2 = premiumNFT.mint(user1);
        mysbt.bindNFT(address(mockNFT), nft1);
        mysbt.bindNFT(address(premiumNFT), nft2);
        vm.stopPrank();

        // 3. Fast forward 6 months
        vm.warp(block.timestamp + 180 days);

        // 4. Get detailed breakdown
        (
            address[] memory nftContracts,
            uint256[] memory nftTokenIds,
            uint256[] memory timeWeights,
            uint256[] memory multipliers,
            uint256[] memory bonuses
        ) = calculator.getNFTBonusBreakdown(tokenId, user1);

        assertEq(nftContracts.length, 2);
        assertEq(nftContracts[0], address(mockNFT));
        assertEq(nftContracts[1], address(premiumNFT));

        assertEq(timeWeights[0], 6); // 6 months
        assertEq(timeWeights[1], 6);

        assertEq(multipliers[0], 1000); // 1.0x
        assertEq(multipliers[1], 1300); // 1.3x

        assertEq(bonuses[0], 6);  // 6 × 1000 / 1000
        assertEq(bonuses[1], 7);  // 6 × 1300 / 1000 = 7.8 → 7
    }
}
