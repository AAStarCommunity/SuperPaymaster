// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/interfaces/v3/IRegistryV3.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {
        _mint(msg.sender, 1000000 ether);
    }
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RegistrySimpleTest is Test {
    Registry registry;
    GTokenStaking staking;
    MySBT sbt;
    MockGToken gtoken;

    address owner = address(1);
    address dao = address(2);
    address treasury = address(3);
    address communityUser = address(0x200);

    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy
        gtoken = new MockGToken();
        staking = new GTokenStaking(address(gtoken), treasury);
        
        // Temp Registry for MySBT
        registry = new Registry(address(gtoken), address(staking), address(0x1));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);
        
        // Re-deploy Registry with real MySBT
        registry = new Registry(address(gtoken), address(staking), address(sbt));
        
        // Wire up
        vm.stopPrank();
        vm.startPrank(dao);
        sbt.setRegistry(address(registry));
        vm.stopPrank();
        
        vm.startPrank(owner);
        staking.setRegistry(address(registry));
        
        // Mint tokens
        gtoken.mint(communityUser, 1000 ether);
        
        vm.stopPrank();
    }

    function test_RegisterCommunitySimple() public {
        vm.startPrank(owner);
        
        // Configure COMMUNITY role
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
        
        vm.startPrank(communityUser);
        
        // Approve tokens
        gtoken.approve(address(staking), 33 ether);
        
        // Full CommunityRoleData as expected by Registry
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
        
        registry.registerRole(ROLE_COMMUNITY, communityUser, roleData);
        
        // Verify
        assertTrue(registry.hasRole(ROLE_COMMUNITY, communityUser));
        assertEq(staking.getLockedStake(communityUser, ROLE_COMMUNITY), 30 ether);
        
        vm.stopPrank();
    }
}
