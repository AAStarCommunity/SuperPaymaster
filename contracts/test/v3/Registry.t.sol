// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/v3/core/Registry.sol";
import "src/paymasters/v3/core/GTokenStaking.sol";
import "src/paymasters/v3/tokens/MySBT.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

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

contract RegistryTest is Test {
    Registry registry;
    GTokenStaking staking;
    MySBT sbt;
    MockGToken gtoken;

    address owner = address(1);
    address dao = address(2);
    address treasury = address(3);
    address user = address(0x100);
    address communityUser = address(0x200);

    bytes32 constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(owner);

        // 1. Deploy Tokens
        gtoken = new MockGToken();

        // 2. Deploy Staking
        staking = new GTokenStaking(address(gtoken), treasury);

        // 3. Deploy MySBT
        sbt = new MySBT(address(gtoken), address(staking), address(0), dao);

        // 4. Deploy Registry
        registry = new Registry(
            address(gtoken),
            address(staking),
            address(sbt)
        );

        // 5. Configuration Wiring
        
        // Update MySBT registry
        vm.stopPrank();
        vm.startPrank(dao);
        sbt.setRegistry(address(registry));
        vm.stopPrank();

        // Update Staking Registry
        vm.startPrank(owner);
        staking.setRegistry(address(registry));
        
        // Setup initial balances
        gtoken.mint(user, 1000 ether);
        gtoken.mint(communityUser, 1000 ether);
        
        vm.stopPrank();
    }

    function test_RegisterEndUser() public {
        vm.startPrank(user);
        
        vm.stopPrank();
        vm.startPrank(owner);
        
        // Configure ENDUSER
        Registry.RoleConfig memory endUserConfig = Registry.RoleConfig({
            minStake: 0.3 ether,
            entryBurn: 0.1 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashIncrement: 5,
            slashMax: 50,
            isActive: true,
            description: "End User"
        });
        registry.configureRole(ROLE_ENDUSER, endUserConfig);
        
        // Configure COMMUNITY
        Registry.RoleConfig memory communityConfig = Registry.RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10,
            isActive: true,
            description: "Community"
        });
        registry.configureRole(ROLE_COMMUNITY, communityConfig);
        
        vm.stopPrank();
        vm.startPrank(user);
        
        // 2. Register
        uint256 required = 0.3 ether + 0.1 ether;
        gtoken.approve(address(staking), required); 
        
        // Preparing Role Data
        bytes memory roleData = abi.encode(
            Registry.EndUserRoleData({
                account: address(0x123),
                community: address(0x456),
                avatarURI: "ipfs://avatar",
                ensName: "user.eth",
                stakeAmount: 0 // use min
            })
        );
        
        registry.registerRole(ROLE_ENDUSER, user, roleData);
        
        // Asserts
        assertTrue(registry.hasRole(ROLE_ENDUSER, user));
        assertEq(staking.getLockedStake(user, ROLE_ENDUSER), 0.3 ether);
        assertEq(gtoken.balanceOf(registry.BURN_ADDRESS()), 0.1 ether);
        
        vm.stopPrank();
    }
    
    function test_RegisterCommunity() public {
        vm.startPrank(communityUser);
        
        vm.stopPrank();
        vm.startPrank(owner);
        
        Registry.RoleConfig memory communityConfig = Registry.RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10,
            isActive: true,
            description: "Community"
        });
        registry.configureRole(ROLE_COMMUNITY, communityConfig);
        vm.stopPrank();
        
        vm.startPrank(communityUser);
        
        uint256 required = 30 ether + 3 ether;
        gtoken.approve(address(staking), required);
        
        bytes memory roleData = abi.encode(
            Registry.CommunityRoleData({
                name: "MyDAO",
                ensName: "mydao.eth",
                website: "https://dao.com",
                description: "Best DAO",
                logoURI: "ipfs://logo",
                stakeAmount: 0
            })
        );
        
        registry.registerRole(ROLE_COMMUNITY, communityUser, roleData);
        
        assertTrue(registry.hasRole(ROLE_COMMUNITY, communityUser));
        assertEq(staking.getLockedStake(communityUser, ROLE_COMMUNITY), 30 ether);
        
        vm.stopPrank();
    }
    
    function test_ExitRole() public {
        // Setup EndUser
        test_RegisterEndUser();
        
        vm.startPrank(user);
        
        uint256 beforeBalance = gtoken.balanceOf(user);
        
        // Exit
        registry.exitRole(ROLE_ENDUSER);
        
        assertFalse(registry.hasRole(ROLE_ENDUSER, user));
        assertEq(staking.getLockedStake(user, ROLE_ENDUSER), 0);
        
        // Check refund
        uint256 afterBalance = gtoken.balanceOf(user);
        assertEq(afterBalance, beforeBalance + 0.3 ether);
        
        vm.stopPrank();
    }
}
