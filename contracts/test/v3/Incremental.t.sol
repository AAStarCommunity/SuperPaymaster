// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/interfaces/v3/IRegistryV3.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract IncrementalTest is Test {
    Registry registry;
    GTokenStaking staking;
    MySBT sbt;
    MockGToken gtoken;

    address owner = address(1);
    address dao = address(2);
    address treasury = address(3);
    address user = address(0x200);

    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(owner);

        gtoken = new MockGToken();
        staking = new GTokenStaking(address(gtoken), treasury);
        registry = new Registry(address(gtoken), address(staking), address(0x1));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);
        registry = new Registry(address(gtoken), address(staking), address(sbt));
        
        vm.stopPrank();
        vm.startPrank(dao);
        sbt.setRegistry(address(registry));
        vm.stopPrank();
        
        vm.startPrank(owner);
        staking.setRegistry(address(registry));
        gtoken.mint(user, 1000 ether);
        vm.stopPrank();
    }

    function test_Step1_ConfigureRole() public {
        vm.startPrank(owner);
        
        IRegistryV3.RoleConfig memory config = IRegistryV3.RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10,
            isActive: true,
            description: "Community"
        });
        registry.configureRole(ROLE_COMMUNITY, config);
        
        // Verify
        IRegistryV3.RoleConfig memory stored = registry.getRoleConfig(ROLE_COMMUNITY);
        assertEq(stored.minStake, 30 ether);
        assertTrue(stored.isActive);
        
        vm.stopPrank();
    }

    function test_Step2_ApproveTokens() public {
        vm.startPrank(user);
        
        gtoken.approve(address(staking), 33 ether);
        
        // Verify
        assertEq(gtoken.allowance(user, address(staking)), 33 ether);
        assertEq(gtoken.balanceOf(user), 1000 ether);
        
        vm.stopPrank();
    }

    function test_Step3_ValidateAndExtractStake() public view {
        // This tests the internal logic without actually calling it
        bytes memory roleData = abi.encode(
            Registry.CommunityRoleData({
                name: "TestDAO",
                ensName: "",
                website: "",
                description: "",
                logoURI: "",
                stakeAmount: 30 ether
            })
        );
        
        // Just verify encoding works
        Registry.CommunityRoleData memory decoded = abi.decode(roleData, (Registry.CommunityRoleData));
        assertEq(decoded.name, "TestDAO");
    }

    function test_Step4_FullRegister() public {
        // Configure role
        vm.startPrank(owner);
        IRegistryV3.RoleConfig memory config = IRegistryV3.RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10,
            isActive: true,
            description: "Community"
        });
        registry.configureRole(ROLE_COMMUNITY, config);
        vm.stopPrank();

        // User registers
        vm.startPrank(user);
        gtoken.approve(address(staking), 33 ether);
        
        bytes memory roleData = abi.encode(
            Registry.CommunityRoleData({
                name: "TestDAO",
                ensName: "",
                website: "",
                description: "",
                logoURI: "",
                stakeAmount: 30 ether
            })
        );
        
        registry.registerRole(ROLE_COMMUNITY, user, roleData);
        
        // Verify
        assertTrue(registry.hasRole(ROLE_COMMUNITY, user));
        vm.stopPrank();
    }
}
