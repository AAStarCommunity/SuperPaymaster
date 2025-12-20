// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistryV3.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
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

        // 3. Deploy Registry先 (with temporary MySBT placeholder)
        // We'll create a temporary MySBT address then update Registry later
        address tempMySBT = address(0x1); // Temporary non-zero placeholder
        registry = new Registry(
            address(gtoken),
            address(staking),
            tempMySBT
        );

        // 4. Deploy MySBT (now we can pass Registry address)
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);

        // 5. Update Registry with real MySBT address
        // Registry needs to be updated to use the real MySBT
        // Since Registry doesn't have a setMySBT function, we need to deploy Registry again
        vm.stopPrank();
        vm.startPrank(owner);
        
        // Re-deploy Registry with correct MySBT
        registry = new Registry(
            address(gtoken),
            address(staking),
            address(sbt)
        );

        // 6. Configuration Wiring
        
        // Update MySBT registry to point to final Registry
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
        // First register a community
        test_RegisterCommunity();
        
        vm.startPrank(owner);
        
        // Configure ENDUSER
        IRegistryV3.RoleConfig memory endUserConfig = IRegistryV3.RoleConfig({
            minStake: 0.3 ether,
            entryBurn: 0.05 ether,
            slashThreshold: 5,
            slashBase: 10,
            slashIncrement: 5,
            slashMax: 50,
            exitFeePercent: 1000,
            minExitFee: 0.05 ether,
            isActive: true,
            description: "End User"
        });
        registry.configureRole(ROLE_ENDUSER, endUserConfig);
        
        vm.stopPrank();
        vm.startPrank(user);
        
        // 2. Register with proper approvals
        uint256 required = 0.3 ether + 0.05 ether;
        gtoken.approve(address(staking), required); 
        
        // Preparing Role Data - use registered community
        bytes memory roleData = abi.encode(
            Registry.EndUserRoleData({
                account: address(0x123),
                community: communityUser, // Use the registered community
                avatarURI: "ipfs://avatar",
                ensName: "user.eth",
                stakeAmount: 0 // use min
            })
        );
        
        registry.registerRole(ROLE_ENDUSER, user, roleData);
        
        // Asserts
        assertTrue(registry.hasRole(ROLE_ENDUSER, user));
        assertEq(staking.getLockedStake(user, ROLE_ENDUSER), 0.3 ether);
        // Community burned 3 ether + user burned 0.05 ether = 3.05 ether total
        assertEq(gtoken.balanceOf(0x000000000000000000000000000000000000dEaD), 3.05 ether);
        
        vm.stopPrank();
    }
    
    function test_RegisterCommunity() public {
        vm.startPrank(owner);
        
        IRegistryV3.RoleConfig memory communityConfig = IRegistryV3.RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10,
            exitFeePercent: 500,
            minExitFee: 1 ether,
            isActive: true,
            description: "Community"
        });
        registry.configureRole(ROLE_COMMUNITY, communityConfig);
        vm.stopPrank();
        
        vm.startPrank(communityUser);
        
        gtoken.approve(address(staking), 33 ether);
        
        bytes memory roleData = abi.encode(
            Registry.CommunityRoleData({
                name: "MyDAO",
                ensName: "mydao.eth",
                website: "https://dao.com",
                description: "Best DAO",
                logoURI: "ipfs://logo",
                stakeAmount: 30 ether // Explicitly set stake amount
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
        uint256 stakedAmount = staking.getLockedStake(user, ROLE_ENDUSER);
        
        // Exit
        registry.exitRole(ROLE_ENDUSER);
        
        assertFalse(registry.hasRole(ROLE_ENDUSER, user));
        assertEq(staking.getLockedStake(user, ROLE_ENDUSER), 0);
        
        // Check refund (actual refund after exit fee)
        uint256 afterBalance = gtoken.balanceOf(user);
        uint256 refunded = afterBalance - beforeBalance;
        
        // Verify refund amount (may include min fee protection)
        assertTrue(refunded > 0, "Should receive some refund");
        assertTrue(refunded < stakedAmount, "Should deduct exit fee");
        
        vm.stopPrank();
    }
}
