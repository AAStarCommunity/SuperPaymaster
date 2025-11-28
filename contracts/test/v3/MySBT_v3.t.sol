// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/tokens/MySBT_v3_0_0.sol";
import "../../src/paymasters/v2/core/GTokenStaking_v3_0_0.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/**
 * @title MySBT_v3_0_0 Test Suite
 * @notice 20+ test cases for SBT minting, burning, and reputation
 */

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {
        _mint(msg.sender, 10000 ether);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract MySBTv3Test is Test {
    MySBT mySBT;
    GTokenStaking gtStaking;
    MockGToken gtoken;

    address owner = makeAddr("owner");
    address dao = makeAddr("dao");
    address registry = makeAddr("registry");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    bytes32 ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        gtoken = new MockGToken();

        vm.prank(owner);
        gtStaking = new GTokenStaking(address(gtoken), makeAddr("treasury"));

        vm.prank(owner);
        mySBT = new MySBT(
            address(gtoken),
            address(gtStaking),
            registry,
            dao
        );

        // Authorize registry
        vm.prank(owner);
        mySBT.setAuthorization(registry, true);
    }

    // ====================================
    // Test Suite 1: Minting
    // ====================================

    function test_mintForRole() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        assertEq(tokenId, 1);
        assertEq(mySBT.ownerOf(tokenId), user1);
        assertTrue(mySBT.hasSBT(user1));
    }

    function test_mintForRole_recordsRoleId() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        MySBT.SBTData memory data = mySBT.getSBTData(tokenId);
        assertEq(data.roleId, ROLE_ENDUSER);
        assertEq(data.owner, user1);
        assertTrue(data.active);
    }

    function test_mintForRole_differentRoles() public {
        vm.prank(registry);
        uint256 tokenId1 = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(registry);
        uint256 tokenId2 = mySBT.mintForRole(user2, ROLE_COMMUNITY, "");

        assertTrue(tokenId1 != tokenId2);
        assertEq(mySBT.getSBTData(tokenId1).roleId, ROLE_ENDUSER);
        assertEq(mySBT.getSBTData(tokenId2).roleId, ROLE_COMMUNITY);
    }

    function test_mintForRole_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert();
        mySBT.mintForRole(user1, ROLE_ENDUSER, "");
    }

    function test_mintForRole_invalidAddress() public {
        vm.prank(registry);
        vm.expectRevert();
        mySBT.mintForRole(address(0), ROLE_ENDUSER, "");
    }

    function test_mintForRole_doubleRegistration() public {
        vm.prank(registry);
        mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        // Try to mint again
        vm.prank(registry);
        vm.expectRevert();
        mySBT.mintForRole(user1, ROLE_COMMUNITY, "");
    }

    // ====================================
    // Test Suite 2: Burn Recording
    // ====================================

    function test_recordBurn() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(registry);
        mySBT.recordBurn(user1, 0.1 ether);

        MySBT.SBTData memory data = mySBT.getSBTData(tokenId);
        assertEq(data.burnAmount, 0.1 ether);
    }

    function test_recordBurn_multiple() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(registry);
        mySBT.recordBurn(user1, 0.1 ether);

        vm.prank(registry);
        mySBT.recordBurn(user1, 0.05 ether);

        MySBT.SBTData memory data = mySBT.getSBTData(tokenId);
        assertEq(data.burnAmount, 0.15 ether, "Multiple burns should accumulate");
    }

    // ====================================
    // Test Suite 3: Burning/Exiting
    // ====================================

    function test_burnForRole() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(registry);
        mySBT.burnForRole(user1, ROLE_ENDUSER);

        // SBT should be burned
        vm.expectRevert();
        mySBT.ownerOf(tokenId);

        assertFalse(mySBT.hasSBT(user1));
    }

    function test_burnForRole_wrongRole() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        // Try to burn with wrong role
        vm.prank(registry);
        vm.expectRevert();
        mySBT.burnForRole(user1, ROLE_COMMUNITY);
    }

    function test_burnForRole_noSBT() public {
        vm.prank(registry);
        vm.expectRevert();
        mySBT.burnForRole(user1, ROLE_ENDUSER);
    }

    // ====================================
    // Test Suite 4: Reputation Calculation
    // ====================================

    function test_getReputation_base() public {
        vm.prank(registry);
        mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        uint256 rep = mySBT.getReputation(user1);
        assertEq(rep, 20, "Base reputation should be 20");
    }

    function test_getReputation_withBurn() public {
        vm.prank(registry);
        mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(registry);
        mySBT.recordBurn(user1, 0.1 ether);

        uint256 rep = mySBT.getReputation(user1);
        // 20 base + (0.1 / 0.01) = 20 + 10 = 30
        assertEq(rep, 30, "Reputation should include burn bonus");
    }

    function test_getReputation_noBurn() public {
        vm.prank(registry);
        mySBT.mintForRole(user1, ROLE_COMMUNITY, "");

        uint256 rep = mySBT.getReputation(user1);
        // Should be base (20) + (0 / 0.01) = 20
        assertTrue(rep >= 20, "Base reputation should be at least 20");
    }

    function test_getReputation_noSBT() public {
        uint256 rep = mySBT.getReputation(user1);
        assertEq(rep, 0, "No reputation without SBT");
    }

    function test_getReputation_afterBurn() public {
        vm.prank(registry);
        mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(registry);
        mySBT.recordBurn(user1, 0.1 ether);

        vm.prank(registry);
        mySBT.burnForRole(user1, ROLE_ENDUSER);

        uint256 rep = mySBT.getReputation(user1);
        assertEq(rep, 0, "No reputation after SBT burned");
    }

    // ====================================
    // Test Suite 5: View Functions
    // ====================================

    function test_hasSBT() public {
        assertFalse(mySBT.hasSBT(user1));

        vm.prank(registry);
        mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        assertTrue(mySBT.hasSBT(user1));
    }

    function test_getUserSBT() public {
        assertEq(mySBT.getUserSBT(user1), 0);

        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        assertEq(mySBT.getUserSBT(user1), tokenId);
    }

    function test_getSBTData() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "test metadata");

        MySBT.SBTData memory data = mySBT.getSBTData(tokenId);

        assertEq(data.owner, user1);
        assertEq(data.roleId, ROLE_ENDUSER);
        assertTrue(data.active);
    }

    function test_tokenURI() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "ipfs://metadata");

        string memory uri = mySBT.tokenURI(tokenId);
        assertEq(uri, "ipfs://metadata");
    }

    // ====================================
    // Test Suite 6: Soul Bound (Non-transferable)
    // ====================================

    function test_transferFrom_reverts() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(user1);
        vm.expectRevert("Soul Bound: No transfers");
        mySBT.transferFrom(user1, user2, tokenId);
    }

    function test_safeTransferFrom_reverts() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(user1);
        vm.expectRevert("Soul Bound: No transfers");
        mySBT.safeTransferFrom(user1, user2, tokenId);
    }

    // ====================================
    // Test Suite 7: Authorization Management
    // ====================================

    function test_setAuthorization() public {
        address newRegistry = makeAddr("newRegistry");

        vm.prank(owner);
        mySBT.setAuthorization(newRegistry, true);

        assertTrue(mySBT.authorizedRegistries(newRegistry));

        vm.prank(registry);
        vm.expectRevert();
        mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(newRegistry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        assertTrue(tokenId > 0);
    }

    function test_setRegistry() public {
        address newRegistry = makeAddr("newRegistry");

        vm.prank(owner);
        mySBT.setRegistry(newRegistry);

        assertEq(mySBT.REGISTRY(), newRegistry);
        assertTrue(mySBT.authorizedRegistries(newRegistry));
    }

    // ====================================
    // Test Suite 8: Admin Functions
    // ====================================

    function test_setDAO() public {
        address newDAO = makeAddr("newDAO");

        vm.prank(dao);
        mySBT.setDAO(newDAO);

        // Original DAO can no longer call onlyDAO functions
        vm.prank(dao);
        vm.expectRevert();
        mySBT.setDAO(makeAddr("another"));
    }

    function test_pause_unpause() public {
        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        vm.prank(dao);
        mySBT.pause();

        // Should not be able to mint while paused
        vm.prank(registry);
        vm.expectRevert();
        mySBT.mintForRole(user2, ROLE_COMMUNITY, "");

        vm.prank(dao);
        mySBT.unpause();

        // Should work again
        vm.prank(registry);
        uint256 tokenId2 = mySBT.mintForRole(user2, ROLE_COMMUNITY, "");

        assertTrue(tokenId2 > 0);
    }

    // ====================================
    // Test Suite 9: Sequential Operations
    // ====================================

    function test_mintBurnMint() public {
        // Mint
        vm.prank(registry);
        uint256 tokenId1 = mySBT.mintForRole(user1, ROLE_ENDUSER, "");

        // Burn
        vm.prank(registry);
        mySBT.burnForRole(user1, ROLE_ENDUSER);

        // Mint again with different role
        vm.prank(registry);
        uint256 tokenId2 = mySBT.mintForRole(user1, ROLE_COMMUNITY, "");

        assertTrue(tokenId2 > tokenId1);
        assertEq(mySBT.getSBTData(tokenId2).roleId, ROLE_COMMUNITY);
    }

    // ====================================
    // Test Suite 10: Edge Cases
    // ====================================

    function test_zeroRole() public {
        vm.prank(registry);
        vm.expectRevert();
        mySBT.mintForRole(user1, bytes32(0), "");
    }

    function test_largeMetadata() public {
        bytes memory largeData = new bytes(10000);

        vm.prank(registry);
        uint256 tokenId = mySBT.mintForRole(user1, ROLE_ENDUSER, largeData);

        assertTrue(tokenId > 0);
    }
}
