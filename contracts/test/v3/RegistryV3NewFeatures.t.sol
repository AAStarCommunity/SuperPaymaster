// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {
        _mint(msg.sender, 1000000 ether);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title RegistryV3NewFeaturesTest
 * @notice Comprehensive tests for Registry V3.1.1 new features
 */
contract RegistryV3NewFeaturesTest is Test {
    Registry registry;
    GTokenStaking staking;
    MySBT sbt;
    MockGToken gtoken;

    address owner = address(1);
    address dao = address(2);
    address treasury = address(3);
    address roleOwner1 = address(0x100);
    address roleOwner2 = address(0x200);

    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 constant ROLE_JURY = keccak256("JURY");
    bytes32 constant ROLE_PUBLISHER = keccak256("PUBLISHER");
    bytes32 constant ROLE_TASKER = keccak256("TASKER");
    bytes32 constant ROLE_SUPPLIER = keccak256("SUPPLIER");
    bytes32 constant ROLE_NEW_CUSTOM = keccak256("CUSTOM_ROLE");

    function setUp() public {
        vm.startPrank(owner);

        gtoken = new MockGToken();
        staking = new GTokenStaking(address(gtoken), treasury);
        
        registry = new Registry(address(gtoken), address(staking), address(0x1));
        staking.setRegistry(address(registry));
        
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);
        
        Registry newRegistry = new Registry(address(gtoken), address(staking), address(sbt));
        registry = newRegistry;
        staking.setRegistry(address(registry));
        
        vm.stopPrank();
        vm.startPrank(dao);
        sbt.setRegistry(address(registry));
        vm.stopPrank();
        
        vm.startPrank(owner);
        gtoken.mint(roleOwner1, 1000 ether);
        gtoken.mint(roleOwner2, 1000 ether);
        vm.stopPrank();
    }

    // ====================================
    // createNewRole() Tests
    // ====================================

    function test_CreateNewRole_Success() public {
        vm.startPrank(owner);
        
        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 50 ether,
            entryBurn: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1000,
            minExitFee: 2 ether,
            isActive: true,
            description: "Custom Role",
            owner: address(0), // Set by param
            roleLockDuration: 0
        });
        
        registry.createNewRole(ROLE_NEW_CUSTOM, config, roleOwner1);
        
        // Verify role was created
        IRegistry.RoleConfig memory stored = registry.getRoleConfig(ROLE_NEW_CUSTOM);
        assertEq(stored.minStake, 50 ether);
        assertEq(stored.entryBurn, 5 ether);
        assertEq(stored.exitFeePercent, 1000);
        assertEq(stored.minExitFee, 2 ether);
        assertTrue(stored.isActive);
        
        vm.stopPrank();
    }

    function test_CreateNewRole_OnlyOwner() public {
        vm.startPrank(roleOwner1);
        
        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 50 ether,
            entryBurn: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1000,
            minExitFee: 2 ether,
            isActive: true,
            description: "Custom Role",
            owner: address(0),
            roleLockDuration: 0
        });
        
        vm.expectRevert();
        registry.createNewRole(ROLE_NEW_CUSTOM, config, roleOwner1);
        
        vm.stopPrank();
    }

    function test_CreateNewRole_DuplicateReverts() public {
        vm.startPrank(owner);
        
        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 50 ether,
            entryBurn: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1000,
            minExitFee: 2 ether,
            isActive: true,
            description: "Custom Role",
            owner: address(0),
            roleLockDuration: 0
        });
        
        registry.createNewRole(ROLE_NEW_CUSTOM, config, roleOwner1);
        
        vm.expectRevert("Role already exists");
        registry.createNewRole(ROLE_NEW_CUSTOM, config, roleOwner1);
        
        vm.stopPrank();
    }

    function test_CreateNewRole_SyncsExitFee() public {
        vm.startPrank(owner);
        
        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 50 ether,
            entryBurn: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1500, // 15%
            minExitFee: 3 ether,
            isActive: true,
            description: "Custom Role",
            owner: address(0),
            roleLockDuration: 0
        });
        
        registry.createNewRole(ROLE_NEW_CUSTOM, config, roleOwner1);
        
        // Verify exit fee was synced to GTokenStaking
        (uint256 feePercent, uint256 minFee) = staking.roleExitConfigs(ROLE_NEW_CUSTOM);
        assertEq(feePercent, 1500);
        assertEq(minFee, 3 ether);
        
        vm.stopPrank();
    }

    function test_CreateMyTaskRoles_Success() public {
        vm.startPrank(owner);

        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 0.3 ether,
            entryBurn: 0.05 ether,
            slashThreshold: 0,
            slashBase: 0,
            slashInc: 0,
            slashMax: 0,
            exitFeePercent: 1000,
            minExitFee: 0.05 ether,
            isActive: true,
            description: "MyTask Role",
            owner: address(0),
            roleLockDuration: 7 days
        });

        registry.createNewRole(ROLE_JURY, config, roleOwner1);
        registry.createNewRole(ROLE_PUBLISHER, config, roleOwner1);
        registry.createNewRole(ROLE_TASKER, config, roleOwner1);
        registry.createNewRole(ROLE_SUPPLIER, config, roleOwner1);

        assertEq(registry.roleOwners(ROLE_JURY), roleOwner1);
        assertEq(registry.roleOwners(ROLE_PUBLISHER), roleOwner1);
        assertEq(registry.roleOwners(ROLE_TASKER), roleOwner1);
        assertEq(registry.roleOwners(ROLE_SUPPLIER), roleOwner1);

        IRegistry.RoleConfig memory juryConfig = registry.getRoleConfig(ROLE_JURY);
        assertEq(juryConfig.minStake, 0.3 ether);
        assertEq(juryConfig.entryBurn, 0.05 ether);
        assertEq(juryConfig.exitFeePercent, 1000);
        assertEq(juryConfig.minExitFee, 0.05 ether);
        assertTrue(juryConfig.isActive);
        assertEq(juryConfig.roleLockDuration, 7 days);

        (uint256 feePercent, uint256 minFee) = staking.roleExitConfigs(ROLE_JURY);
        assertEq(feePercent, 1000);
        assertEq(minFee, 0.05 ether);

        vm.stopPrank();
    }

    // ====================================
    // Exit Fee Configuration Tests
    // ====================================

    function test_ExitFeeConfiguration_InRoleConfig() public {
        IRegistry.RoleConfig memory config = registry.getRoleConfig(ROLE_ENDUSER);
        
        assertEq(config.exitFeePercent, 1000, "EndUser exit fee should be 10%");
        assertEq(config.minExitFee, 0.05 ether, "EndUser min exit fee should be 0.05 ether");
    }

    function test_ExitFeeConfiguration_AllRoles() public {
        bytes32[] memory roles = new bytes32[](6);
        roles[0] = keccak256("PAYMASTER_AOA");
        roles[1] = keccak256("PAYMASTER_SUPER");
        roles[2] = keccak256("ANODE");
        roles[3] = keccak256("KMS");
        roles[4] = ROLE_COMMUNITY;
        roles[5] = ROLE_ENDUSER;
        
        for (uint i = 0; i < roles.length; i++) {
            IRegistry.RoleConfig memory config = registry.getRoleConfig(roles[i]);
            uint256 expectedFee = roles[i] == ROLE_COMMUNITY ? 500 : 1000;
            assertEq(config.exitFeePercent, expectedFee, "Exit fee mismatch for role");
            assertTrue(config.minExitFee > 0, "All roles should have min exit fee");
        }
    }

    function test_ConfigureRole_UpdatesExitFee() public {
        vm.startPrank(owner);
        
        IRegistry.RoleConfig memory newConfig = IRegistry.RoleConfig({
            minStake: 20 ether,
            entryBurn: 2 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashInc: 1,
            slashMax: 10,
            exitFeePercent: 2000, // 20%
            minExitFee: 1.5 ether,
            isActive: true,
            description: "Updated Community",
            owner: address(0),
            roleLockDuration: 0
        });
        
        registry.configureRole(ROLE_COMMUNITY, newConfig);
        
        // Verify exit fee was updated in GTokenStaking
        (uint256 feePercent, uint256 minFee) = staking.roleExitConfigs(ROLE_COMMUNITY);
        assertEq(feePercent, 2000);
        assertEq(minFee, 1.5 ether);
        
        vm.stopPrank();
    }

    // ====================================
    // Role Owner Management Tests
    // ====================================

    function test_RoleOwner_CanConfigureOwnRole() public {
        // First create a role owned by roleOwner1
        vm.startPrank(owner);
        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 50 ether,
            entryBurn: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1000,
            minExitFee: 2 ether,
            isActive: true,
            description: "Custom Role",
            owner: address(0),
            roleLockDuration: 0
        });
        registry.createNewRole(ROLE_NEW_CUSTOM, config, roleOwner1);
        vm.stopPrank();
        
        // Role owner should be able to configure
        vm.startPrank(roleOwner1);
        config.minStake = 60 ether;
        registry.configureRole(ROLE_NEW_CUSTOM, config);
        
        IRegistry.RoleConfig memory updated = registry.getRoleConfig(ROLE_NEW_CUSTOM);
        assertEq(updated.minStake, 60 ether);
        vm.stopPrank();
    }

    function test_RoleOwner_CannotConfigureOthersRole() public {
        vm.startPrank(roleOwner1);
        
        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 20 ether,
            entryBurn: 2 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashInc: 1,
            slashMax: 10,
            exitFeePercent: 1000,
            minExitFee: 1 ether,
            isActive: true,
            description: "Hacked",
            owner: address(0),
            roleLockDuration: 0
        });
        
        vm.expectRevert("Unauthorized");
        registry.configureRole(ROLE_COMMUNITY, config);
        
        vm.stopPrank();
    }
}
