// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

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

        // 2. Deploy Registry proxy first (Scheme B: placeholder initialize)
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));

        // 3. Deploy Staking and MySBT with immutable Registry reference
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);

        // 4. Wire staking and MySBT into Registry
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));

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
        IRegistry.RoleConfig memory endUserConfig = registry.getRoleConfig(ROLE_ENDUSER);
        endUserConfig.minStake = 0.3 ether;
        endUserConfig.entryBurn = 0.05 ether;
        endUserConfig.slashThreshold = 5;
        endUserConfig.slashBase = 10;
        endUserConfig.slashInc = 5;
        endUserConfig.slashMax = 50;
        endUserConfig.exitFeePercent = 1000;
        endUserConfig.minExitFee = 0.05 ether;
        endUserConfig.isActive = true;
        endUserConfig.description = "End User";
        endUserConfig.roleLockDuration = 0;
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
        
        // ✅ Verify TRUE BURN: blackhole should be empty (no longer used)
        assertEq(gtoken.balanceOf(0x000000000000000000000000000000000000dEaD), 0, "Blackhole should be empty");
        
        vm.stopPrank();
    }
    
    function test_RegisterCommunity() public {
        vm.startPrank(owner);
        
        IRegistry.RoleConfig memory communityConfig = registry.getRoleConfig(ROLE_COMMUNITY);
        communityConfig.minStake = 30 ether;
        communityConfig.entryBurn = 3 ether;
        communityConfig.slashThreshold = 10;
        communityConfig.slashBase = 2;
        communityConfig.slashInc = 1;
        communityConfig.slashMax = 10;
        communityConfig.exitFeePercent = 500;
        communityConfig.minExitFee = 1 ether;
        communityConfig.isActive = true;
        communityConfig.description = "Community";
        communityConfig.roleLockDuration = 0;
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
        vm.stopPrank();
        vm.startPrank(owner);
        IRegistry.RoleConfig memory cfg = registry.getRoleConfig(ROLE_ENDUSER);
        cfg.roleLockDuration = 0;
        registry.configureRole(ROLE_ENDUSER, cfg);
        vm.stopPrank();
        vm.startPrank(user);
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
