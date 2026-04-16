// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

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

        // Scheme B: Deploy Registry proxy first with placeholders
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));

        // Deploy Staking and MySBT with immutable Registry
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);

        // Wire into Registry
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));

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
            ticketPrice: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1000,
            isActive: true,
            minExitFee: 2 ether,
            description: "Custom Role",
            owner: roleOwner1,
            roleLockDuration: 0
        });

        registry.configureRole(ROLE_NEW_CUSTOM, config);

        // Verify role was created
        IRegistry.RoleConfig memory stored = registry.getRoleConfig(ROLE_NEW_CUSTOM);
        assertEq(stored.minStake, 50 ether);
        assertEq(stored.ticketPrice, 5 ether);
        assertEq(stored.exitFeePercent, 1000);
        assertEq(stored.minExitFee, 2 ether);
        assertTrue(stored.isActive);

        vm.stopPrank();
    }

    function test_CreateNewRole_OnlyOwner() public {
        vm.startPrank(roleOwner1);

        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 50 ether,
            ticketPrice: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1000,
            isActive: true,
            minExitFee: 2 ether,
            description: "Custom Role",
            owner: roleOwner1,
            roleLockDuration: 0
        });

        // New role (no existing owner) requires contract owner
        vm.expectRevert();
        registry.configureRole(ROLE_NEW_CUSTOM, config);

        vm.stopPrank();
    }

    function test_ConfigureRole_UpdateExistingSucceeds() public {
        vm.startPrank(owner);

        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 50 ether,
            ticketPrice: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1000,
            isActive: true,
            minExitFee: 2 ether,
            description: "Custom Role",
            owner: roleOwner1,
            roleLockDuration: 0
        });

        registry.configureRole(ROLE_NEW_CUSTOM, config);

        // configureRole on existing role updates it (does not revert)
        config.minStake = 100 ether;
        registry.configureRole(ROLE_NEW_CUSTOM, config);

        IRegistry.RoleConfig memory stored = registry.getRoleConfig(ROLE_NEW_CUSTOM);
        assertEq(stored.minStake, 100 ether);

        vm.stopPrank();
    }

    function test_CreateNewRole_SyncsExitFee() public {
        vm.startPrank(owner);

        IRegistry.RoleConfig memory config = IRegistry.RoleConfig({
            minStake: 50 ether,
            ticketPrice: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1500, // 15%
            isActive: true,
            minExitFee: 3 ether,
            description: "Custom Role",
            owner: roleOwner1,
            roleLockDuration: 0
        });

        registry.configureRole(ROLE_NEW_CUSTOM, config);

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
            ticketPrice: 0.05 ether,
            slashThreshold: 0,
            slashBase: 0,
            slashInc: 0,
            slashMax: 0,
            exitFeePercent: 1000,
            isActive: true,
            minExitFee: 0.05 ether,
            description: "MyTask Role",
            owner: roleOwner1,
            roleLockDuration: 7 days
        });

        registry.configureRole(ROLE_JURY, config);
        registry.configureRole(ROLE_PUBLISHER, config);
        registry.configureRole(ROLE_TASKER, config);
        registry.configureRole(ROLE_SUPPLIER, config);

        assertEq(registry.getRoleConfig(ROLE_JURY).owner, roleOwner1);
        assertEq(registry.getRoleConfig(ROLE_PUBLISHER).owner, roleOwner1);
        assertEq(registry.getRoleConfig(ROLE_TASKER).owner, roleOwner1);
        assertEq(registry.getRoleConfig(ROLE_SUPPLIER).owner, roleOwner1);

        IRegistry.RoleConfig memory juryConfig = registry.getRoleConfig(ROLE_JURY);
        assertEq(juryConfig.minStake, 0.3 ether);
        assertEq(juryConfig.ticketPrice, 0.05 ether);
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
        // ENDUSER is ticket-only (no stake to exit); exit fee fields are zero.
        IRegistry.RoleConfig memory config = registry.getRoleConfig(ROLE_ENDUSER);

        assertEq(config.exitFeePercent, 0, "EndUser is ticket-only, exit fee must be 0");
        assertEq(config.minExitFee, 0, "EndUser is ticket-only, min exit fee must be 0");
    }

    function test_ExitFeeConfiguration_AllRoles() public {
        bytes32[] memory operatorRoles = new bytes32[](4);
        operatorRoles[0] = keccak256("PAYMASTER_AOA");
        operatorRoles[1] = keccak256("PAYMASTER_SUPER");
        operatorRoles[2] = keccak256("ANODE");
        operatorRoles[3] = keccak256("KMS");

        for (uint i = 0; i < operatorRoles.length; i++) {
            IRegistry.RoleConfig memory config = registry.getRoleConfig(operatorRoles[i]);
            assertEq(config.exitFeePercent, 1000, "Operator exit fee should be 10%");
            assertTrue(config.minExitFee > 0, "Operator roles should have min exit fee");
        }

        // Ticket-only roles have no exit fee
        IRegistry.RoleConfig memory communityCfg = registry.getRoleConfig(ROLE_COMMUNITY);
        assertEq(communityCfg.exitFeePercent, 0, "COMMUNITY is ticket-only");
        assertEq(communityCfg.minExitFee, 0, "COMMUNITY has no min exit fee");

        IRegistry.RoleConfig memory enduserCfg = registry.getRoleConfig(ROLE_ENDUSER);
        assertEq(enduserCfg.exitFeePercent, 0, "ENDUSER is ticket-only");
        assertEq(enduserCfg.minExitFee, 0, "ENDUSER has no min exit fee");
    }

    function test_ConfigureRole_UpdatesExitFee() public {
        vm.startPrank(owner);

        // Get current config to preserve owner
        IRegistry.RoleConfig memory currentCfg = registry.getRoleConfig(ROLE_COMMUNITY);

        IRegistry.RoleConfig memory newConfig = IRegistry.RoleConfig({
            minStake: 20 ether,
            ticketPrice: 2 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashInc: 1,
            slashMax: 10,
            exitFeePercent: 2000, // 20%
            isActive: true,
            minExitFee: 1.5 ether,
            description: "Updated Community",
            owner: currentCfg.owner,
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
            ticketPrice: 5 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashInc: 5,
            slashMax: 100,
            exitFeePercent: 1000,
            isActive: true,
            minExitFee: 2 ether,
            description: "Custom Role",
            owner: roleOwner1,
            roleLockDuration: 0
        });
        registry.configureRole(ROLE_NEW_CUSTOM, config);
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
            ticketPrice: 2 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashInc: 1,
            slashMax: 10,
            exitFeePercent: 1000,
            isActive: true,
            minExitFee: 1 ether,
            description: "Hacked",
            owner: roleOwner1,
            roleLockDuration: 0
        });

        vm.expectRevert(Registry.Unauthorized.selector);
        registry.configureRole(ROLE_COMMUNITY, config);
        
        vm.stopPrank();
    }
}
