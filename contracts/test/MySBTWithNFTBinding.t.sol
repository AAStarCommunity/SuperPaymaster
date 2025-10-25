// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/tokens/MySBTWithNFTBinding.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title MySBTWithNFTBinding Test Suite
 * @notice Tests for MySBT burn fee distribution and NFT unbind protection
 */
contract MySBTWithNFTBindingTest is Test {
    MySBTWithNFTBinding public sbt;
    GTokenStaking public staking;
    MockERC20 public gtoken;

    address public treasury = makeAddr("treasury");
    address public alice = makeAddr("alice");
    address public community = makeAddr("community");

    // Mock NFT contract for testing
    MockERC721 public mockNFT;

    function setUp() public {
        // Deploy GToken (MockERC20)
        gtoken = new MockERC20("GToken", "GT", 18);

        // Deploy GTokenStaking
        staking = new GTokenStaking(address(gtoken));
        staking.setTreasury(treasury);

        // Deploy MySBT
        sbt = new MySBTWithNFTBinding(address(gtoken), address(staking));

        // Configure MySBT as authorized locker with 0.1 stGT exit fee
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);
        staking.configureLocker(
            address(sbt),
            true,                    // authorized
            0.1 ether,               // baseExitFee = 0.1 stGT
            emptyTiers,
            emptyFees,
            address(0)               // use default treasury
        );

        // Deploy mock NFT
        mockNFT = new MockERC721();

        // Mint GToken to alice
        gtoken.mint(alice, 100 ether);

        // Alice stakes 1 GToken
        vm.startPrank(alice);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(1 ether);
        vm.stopPrank();
    }

    /**
     * @notice Test 9: Verify burn SBT stGToken distribution (0.1 treasury, 0.2 user)
     */
    function test_BurnSBT_FeeDistribution() public {
        // === Step 1: Alice mints SBT (locks 0.3 stGT, burns 0.1 GT) ===
        vm.startPrank(alice);
        gtoken.approve(address(sbt), 0.1 ether);
        uint256 tokenId = sbt.mintSBT(community);
        vm.stopPrank();

        // Verify lock
        (uint256 lockedAmount,,,) = staking.locks(alice, address(sbt));
        assertEq(lockedAmount, 0.3 ether, "Should lock 0.3 stGT");

        // Record balances before burn
        uint256 treasuryBefore = gtoken.balanceOf(treasury);
        uint256 aliceStakedBefore = staking.balanceOf(alice);

        // === Step 2: Alice burns SBT ===
        vm.prank(alice);
        sbt.burnSBT(tokenId);

        // === Step 3: Verify fee distribution ===
        uint256 treasuryAfter = gtoken.balanceOf(treasury);
        uint256 aliceStakedAfter = staking.balanceOf(alice);

        // Treasury receives 0.1 stGT exit fee
        assertEq(
            treasuryAfter - treasuryBefore,
            0.1 ether,
            "Treasury should receive 0.1 stGT exit fee"
        );

        // Alice lock reduced by 0.3 stGT, but 0.1 went to treasury
        // Net change in Alice's staking balance = -0.3 (unlocked) + 0.3 (returned) - 0.1 (fee to treasury)
        // = -0.1 stGT
        assertEq(
            aliceStakedBefore - aliceStakedAfter,
            0.1 ether,
            "Alice's staked balance should decrease by 0.1 stGT (the fee)"
        );

        // Verify lock is removed
        (uint256 lockedAfter,,,) = staking.locks(alice, address(sbt));
        assertEq(lockedAfter, 0, "Lock should be removed after burn");

        emit log_named_uint("Treasury received (stGT)", treasuryAfter - treasuryBefore);
        emit log_named_uint("Alice net loss (stGT)", aliceStakedBefore - aliceStakedAfter);
    }

    /**
     * @notice Test 10: Verify NFTs must be unbound before burn
     */
    function test_BurnSBT_RequiresNFTUnbind() public {
        // === Step 1: Alice mints SBT ===
        vm.startPrank(alice);
        gtoken.approve(address(sbt), 0.1 ether);
        uint256 tokenId = sbt.mintSBT(community);
        vm.stopPrank();

        // === Step 2: Mint NFT to Alice and bind to SBT (CUSTODIAL mode) ===
        mockNFT.mint(alice, 1);

        vm.startPrank(alice);
        mockNFT.approve(address(sbt), 1);
        sbt.bindNFT(
            tokenId,
            community,
            address(mockNFT),
            1,
            MySBTWithNFTBinding.NFTBindingMode.CUSTODIAL
        );
        vm.stopPrank();

        // Verify NFT transferred to SBT contract
        assertEq(mockNFT.ownerOf(1), address(sbt), "NFT should be in SBT contract");

        // === Step 3: Try to burn SBT (should fail) ===
        vm.prank(alice);
        vm.expectRevert();
        sbt.burnSBT(tokenId);

        // === Step 4: Request unbind ===
        vm.prank(alice);
        sbt.requestUnbind(tokenId, community);

        // Fast forward 7 days
        vm.warp(block.timestamp + 7 days);

        // === Step 5: Execute unbind ===
        vm.prank(alice);
        sbt.executeUnbind(tokenId, community);

        // Verify NFT returned to Alice
        assertEq(mockNFT.ownerOf(1), alice, "NFT should be returned to Alice");

        // === Step 6: Now burn should succeed ===
        vm.prank(alice);
        sbt.burnSBT(tokenId);

        emit log("Successfully burned SBT after unbinding NFT");
    }

    /**
     * @notice Test 10b: Verify NFTs transferred before burn (NON_CUSTODIAL mode)
     */
    function test_BurnSBT_NonCustodialNFT() public {
        // === Step 1: Alice mints SBT ===
        vm.startPrank(alice);
        gtoken.approve(address(sbt), 0.1 ether);
        uint256 tokenId = sbt.mintSBT(community);
        vm.stopPrank();

        // === Step 2: Mint NFT to Alice and bind to SBT (NON_CUSTODIAL mode) ===
        mockNFT.mint(alice, 1);

        vm.startPrank(alice);
        mockNFT.setApprovalForAll(address(sbt), true);
        sbt.bindNFT(
            tokenId,
            community,
            address(mockNFT),
            1,
            MySBTWithNFTBinding.NFTBindingMode.NON_CUSTODIAL
        );
        vm.stopPrank();

        // Verify NFT still with Alice (non-custodial)
        assertEq(mockNFT.ownerOf(1), alice, "NFT should stay with Alice (non-custodial)");

        // === Step 3: Try to burn SBT (should still fail due to active binding) ===
        vm.prank(alice);
        vm.expectRevert();
        sbt.burnSBT(tokenId);

        // === Step 4: Request unbind ===
        vm.prank(alice);
        sbt.requestUnbind(tokenId, community);

        // Fast forward 7 days
        vm.warp(block.timestamp + 7 days);

        // === Step 5: Execute unbind ===
        vm.prank(alice);
        sbt.executeUnbind(tokenId, community);

        // NFT still with Alice (non-custodial unbind doesn't transfer)
        assertEq(mockNFT.ownerOf(1), alice, "NFT still with Alice");

        // === Step 6: Now burn should succeed ===
        vm.prank(alice);
        sbt.burnSBT(tokenId);

        emit log("Successfully burned SBT after unbinding non-custodial NFT");
    }
}

/**
 * @notice Mock ERC20 for testing
 */
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    string public name;
    string public symbol;
    uint8 public decimals;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

/**
 * @notice Mock ERC721 for testing
 */
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => address) public getApproved;
    uint256 public nextTokenId = 0;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function approve(address spender, uint256 tokenId) external {
        require(ownerOf[tokenId] == msg.sender, "Not owner");
        getApproved[tokenId] = spender;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        require(
            msg.sender == from ||
            getApproved[tokenId] == msg.sender ||
            isApprovedForAll[from][msg.sender],
            "Not approved"
        );

        ownerOf[tokenId] = to;
        delete getApproved[tokenId];
    }
}
