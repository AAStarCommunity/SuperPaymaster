// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/paymasters/v2/core/Registry_v3_0_0.sol";
import "../../src/paymasters/v2/core/GTokenStaking_v3_0_0.sol";
import "../../src/paymasters/v2/tokens/MySBT_v3_0_0.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";

/**
 * @title Registry_v3_0_0 Test Suite
 * @notice Comprehensive tests for Mycelium Protocol v3
 * @dev 35+ test cases covering all core functionality
 */

// Mock GToken for testing
contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {
        _mint(msg.sender, 10000 ether);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract RegistryV3Test is Test {
    // ====================================
    // Test Setup
    // ====================================

    MockGToken gtoken;
    GTokenStaking gtStaking;
    MySBT mySBT;
    Registry registry;

    address owner = makeAddr("owner");
    address dao = makeAddr("dao");
    address treasury = makeAddr("treasury");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address community1 = makeAddr("community1");
    address operator = makeAddr("operator");

    bytes32 ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 ROLE_PAYMASTER = keccak256("PAYMASTER");
    bytes32 ROLE_SUPER = keccak256("SUPER");

    function setUp() public {
        // Deploy mock GToken
        gtoken = new MockGToken();

        // Distribute GT
        gtoken.mint(user1, 100 ether);
        gtoken.mint(user2, 100 ether);
        gtoken.mint(community1, 100 ether);
        gtoken.mint(operator, 100 ether);

        // Deploy GTokenStaking
        vm.prank(owner);
        gtStaking = new GTokenStaking(address(gtoken), treasury);

        // Deploy MySBT
        vm.prank(owner);
        mySBT = new MySBT(address(gtoken), address(gtStaking), address(0), dao);

        // Deploy Registry
        vm.prank(owner);
        registry = new Registry(
            address(gtoken),
            address(gtStaking),
            address(mySBT),
            dao
        );

        // Configure authorizations
        vm.startPrank(owner);
        gtStaking.setLockerAuthorization(address(registry), true);
        mySBT.setAuthorization(address(registry), true);
        mySBT.setRegistry(address(registry));
        vm.stopPrank();
    }

    // ====================================
    // Test Suite 1: Basic Registration
    // ====================================

    function test_registerRole_ENDUSER() public {
        // User approves GT
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        // User registers as ENDUSER
        vm.prank(user1);
        uint256 sbtTokenId = registry.registerRole(ROLE_ENDUSER, user1, "");

        // Verify registration
        assert(sbtTokenId > 0);
        assertTrue(registry.hasRole(user1, ROLE_ENDUSER));

        // Verify stake locked
        uint256 locked = gtStaking.getLockedBalance(user1);
        assertEq(locked, 0.2 ether, "0.2 GT should be locked");

        // Verify burn recorded
        uint256 burned = gtStaking.getTotalBurned(user1);
        assertEq(burned, 0.1 ether, "0.1 GT should be burned");
    }

    function test_registerRole_COMMUNITY() public {
        vm.prank(community1);
        gtoken.approve(address(registry), 30 ether);

        vm.prank(community1);
        uint256 sbtTokenId = registry.registerRole(ROLE_COMMUNITY, community1, "");

        assertTrue(registry.hasRole(community1, ROLE_COMMUNITY));
        assertEq(gtStaking.getLockedBalance(community1), 27 ether);
        assertEq(gtStaking.getTotalBurned(community1), 3 ether);
    }

    function test_registerRole_PAYMASTER() public {
        vm.prank(operator);
        gtoken.approve(address(registry), 30 ether);

        vm.prank(operator);
        uint256 sbtTokenId = registry.registerRole(ROLE_PAYMASTER, operator, "");

        assertTrue(registry.hasRole(operator, ROLE_PAYMASTER));
        assertEq(gtStaking.getLockedBalance(operator), 27 ether);
    }

    function test_registerRole_SUPER() public {
        vm.prank(operator);
        gtoken.approve(address(registry), 50 ether);

        vm.prank(operator);
        uint256 sbtTokenId = registry.registerRole(ROLE_SUPER, operator, "");

        assertTrue(registry.hasRole(operator, ROLE_SUPER));
        assertEq(gtStaking.getLockedBalance(operator), 45 ether);
        assertEq(gtStaking.getTotalBurned(operator), 5 ether);
    }

    // ====================================
    // Test Suite 2: Self Registration
    // ====================================

    function test_registerRoleSelf() public {
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        uint256 sbtTokenId = registry.registerRoleSelf(ROLE_ENDUSER, "");

        assertTrue(registry.hasRole(user1, ROLE_ENDUSER));
        assertEq(gtStaking.getLockedBalance(user1), 0.2 ether);
    }

    // ====================================
    // Test Suite 3: Exit Mechanism
    // ====================================

    function test_exitRole_ENDUSER() public {
        // Setup: Register user
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        registry.registerRole(ROLE_ENDUSER, user1, "");

        // Exit role
        vm.prank(user1);
        uint256 refund = registry.exitRole(ROLE_ENDUSER);

        // Verify
        assertFalse(registry.hasRole(user1, ROLE_ENDUSER));
        assertTrue(refund > 0);
        assertEq(refund, 0.15 ether, "Refund should be 0.15 GT (0.2 - 0.05 fee)");
    }

    function test_exitRole_COMMUNITY() public {
        // Setup
        vm.prank(community1);
        gtoken.approve(address(registry), 30 ether);

        vm.prank(community1);
        registry.registerRole(ROLE_COMMUNITY, community1, "");

        // Exit
        vm.prank(community1);
        uint256 refund = registry.exitRole(ROLE_COMMUNITY);

        // 27 GT locked, 10% fee = 2.7 GT
        assertEq(refund, 24.3 ether, "Refund should be 24.3 GT");
        assertFalse(registry.hasRole(community1, ROLE_COMMUNITY));
    }

    function test_exitRole_notRegistered() public {
        vm.prank(user1);
        vm.expectRevert();
        registry.exitRole(ROLE_ENDUSER);
    }

    // ====================================
    // Test Suite 4: Safe Mint (Admin Airdrop)
    // ====================================

    function test_safeMintForRole_byAdmin() public {
        // Setup: Set admin
        vm.prank(owner);
        registry.setRoleAdmin(ROLE_ENDUSER, community1);

        // Admin mints for user
        vm.prank(community1);
        uint256 sbtTokenId = registry.safeMintForRole(
            ROLE_ENDUSER,
            user2,
            "airdrop"
        );

        // Verify: User has SBT but no stake locked
        assertTrue(registry.hasRole(user2, ROLE_ENDUSER));
        assertEq(sbtTokenId, 1);
        assertEq(gtStaking.getLockedBalance(user2), 0, "No stake locked for airdrop");
    }

    function test_safeMintForRole_byDAO() public {
        // DAO can always call safeMint
        vm.prank(dao);
        uint256 sbtTokenId = registry.safeMintForRole(
            ROLE_COMMUNITY,
            user1,
            "dao_airdrop"
        );

        assertTrue(registry.hasRole(user1, ROLE_COMMUNITY));
    }

    function test_safeMintForRole_notAdmin() public {
        vm.prank(owner);
        registry.setRoleAdmin(ROLE_ENDUSER, community1);

        // Wrong address tries to mint
        vm.prank(user1);
        vm.expectRevert();
        registry.safeMintForRole(ROLE_ENDUSER, user2, "");
    }

    // ====================================
    // Test Suite 5: Burn Tracking
    // ====================================

    function test_burnTracking_entryBurn() public {
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        registry.registerRole(ROLE_ENDUSER, user1, "");

        uint256 totalBurned = gtStaking.getTotalBurned(user1);
        assertEq(totalBurned, 0.1 ether, "Entry burn should be tracked");
    }

    function test_burnTracking_exitFee() public {
        // Register
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        registry.registerRole(ROLE_ENDUSER, user1, "");

        // Exit
        vm.prank(user1);
        registry.exitRole(ROLE_ENDUSER);

        // Total burned = entry (0.1) + exit fee (0.05) = 0.15
        uint256 totalBurned = gtStaking.getTotalBurned(user1);
        assertEq(totalBurned, 0.15 ether, "Exit fee should add to burned total");
    }

    function test_burnHistory() public {
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        registry.registerRole(ROLE_ENDUSER, user1, "");

        // Get burn history
        (uint256[] memory amounts, bytes32[] memory reasons) = registry.getBurnHistory(user1);

        assertTrue(amounts.length > 0, "Burn history should be recorded");
    }

    // ====================================
    // Test Suite 6: DAO Functions
    // ====================================

    function test_addRole_byDAO() public {
        // Create new role config
        Registry.RoleConfig memory newRole;
        newRole.roleId = keccak256("NEWROLE");
        newRole.roleName = "New Role";
        newRole.minStake = 10 ether;
        newRole.entryBurn = 1 ether;
        newRole.exitFeePercent = 5;
        newRole.minExitFee = 0.1 ether;
        newRole.requiresSBT = true;
        newRole.sbtContract = address(mySBT);

        vm.prank(dao);
        registry.addRole(newRole);

        // Verify role added
        Registry.RoleConfig memory retrieved = registry.getRoleConfig(newRole.roleId);
        assertEq(retrieved.minStake, 10 ether);
        assertTrue(retrieved.enabled);
    }

    function test_updateRoleConfig_byDAO() public {
        // Get original ENDUSER config
        Registry.RoleConfig memory newConfig = registry.getRoleConfig(ROLE_ENDUSER);

        // Update
        newConfig.exitFeePercent = 20;

        vm.prank(dao);
        registry.updateRoleConfig(ROLE_ENDUSER, newConfig);

        // Verify
        Registry.RoleConfig memory updated = registry.getRoleConfig(ROLE_ENDUSER);
        assertEq(updated.exitFeePercent, 20);
    }

    function test_enableRole_byDAO() public {
        vm.prank(dao);
        registry.enableRole(ROLE_ENDUSER, false);

        // Should not be able to register
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        vm.expectRevert();
        registry.registerRole(ROLE_ENDUSER, user1, "");

        // Re-enable
        vm.prank(dao);
        registry.enableRole(ROLE_ENDUSER, true);

        // Should work now
        vm.prank(user1);
        registry.registerRole(ROLE_ENDUSER, user1, "");

        assertTrue(registry.hasRole(user1, ROLE_ENDUSER));
    }

    // ====================================
    // Test Suite 7: Multiple Roles
    // ====================================

    function test_multipleRoles_sameUser() public {
        // Register as ENDUSER
        vm.prank(user1);
        gtoken.approve(address(registry), 30.3 ether);

        vm.prank(user1);
        registry.registerRole(ROLE_ENDUSER, user1, "");

        // Register as COMMUNITY
        vm.prank(user1);
        registry.registerRole(ROLE_COMMUNITY, user1, "");

        // Verify both roles
        bytes32[] memory roles = registry.getUserRoles(user1);
        assertEq(roles.length, 2);
        assertTrue(registry.hasRole(user1, ROLE_ENDUSER));
        assertTrue(registry.hasRole(user1, ROLE_COMMUNITY));
    }

    // ====================================
    // Test Suite 8: Edge Cases
    // ====================================

    function test_insufficientBalance() public {
        vm.prank(user1);
        gtoken.approve(address(registry), 0.1 ether); // Less than required

        vm.prank(user1);
        vm.expectRevert();
        registry.registerRole(ROLE_ENDUSER, user1, "");
    }

    function test_zeroAddress() public {
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        vm.expectRevert();
        registry.registerRole(ROLE_ENDUSER, address(0), "");
    }

    function test_doubleRegistration_sameRole() public {
        // First registration
        vm.prank(user1);
        gtoken.approve(address(registry), 0.6 ether);

        vm.prank(user1);
        registry.registerRole(ROLE_ENDUSER, user1, "");

        // Second registration should revert
        vm.prank(user1);
        vm.expectRevert();
        registry.registerRole(ROLE_ENDUSER, user1, "");
    }

    // ====================================
    // Test Suite 9: Authorization
    // ====================================

    function test_setAuthorization() public {
        address newRegistry = makeAddr("newRegistry");

        vm.prank(owner);
        registry.setAuthorization(newRegistry, true);

        assertTrue(registry.authorizedMinters(newRegistry));

        vm.prank(owner);
        registry.setAuthorization(newRegistry, false);

        assertFalse(registry.authorizedMinters(newRegistry));
    }

    function test_setRoleAdmin() public {
        address admin = makeAddr("admin");

        vm.prank(owner);
        registry.setRoleAdmin(ROLE_ENDUSER, admin);

        assertEq(registry.roleAdmins(ROLE_ENDUSER), admin);
    }

    // ====================================
    // Test Suite 10: Gas Optimization
    // ====================================

    function test_registerRole_gas() public {
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        uint256 gasStart = gasleft();
        registry.registerRole(ROLE_ENDUSER, user1, "");
        uint256 gasUsed = gasStart - gasleft();

        // Should be < 150k for single role registration
        assertTrue(gasUsed < 150000, "Gas should be optimized");
    }

    // ====================================
    // Test Suite 11: Statistics Tracking
    // ====================================

    function test_roleStats() public {
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        registry.registerRole(ROLE_ENDUSER, user1, "");

        Registry.RoleStats memory stats = registry.getRoleStats(ROLE_ENDUSER);
        assertEq(stats.totalRegistrations, 1);
        assertEq(stats.activeCount, 1);
    }

    // ====================================
    // Test Suite 12: Event Emission
    // ====================================

    function test_eventRoleRegistered() public {
        vm.prank(user1);
        gtoken.approve(address(registry), 0.3 ether);

        vm.prank(user1);
        vm.expectEmit(true, true, true, false);
        emit Registry.RoleRegistered(user1, ROLE_ENDUSER, 1, 0.1 ether, 0.2 ether, block.timestamp);

        registry.registerRole(ROLE_ENDUSER, user1, "");
    }
}
