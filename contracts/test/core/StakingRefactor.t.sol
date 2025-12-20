// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/core/GTokenStaking.sol";
import "../../src/core/Registry.sol";
import "../../src/tokens/GToken.sol";
import "../../src/tokens/MySBT.sol";

contract StakingRefactorTest is Test {
    GTokenStaking staking;
    Registry registry;
    GToken gToken;
    MySBT mySBT;

    address owner = address(0x111);
    address user = address(0x222);
    address treasury = address(0x333);

    function setUp() public {
        vm.startPrank(owner);
        gToken = new GToken(1000000000 ether);
        staking = new GTokenStaking(address(gToken), treasury);
        
        // Deploy MySBT first with placeholder registry
        mySBT = new MySBT(address(gToken), address(staking), address(0), owner);
        
        // Deploy Registry with MySBT
        registry = new Registry(address(gToken), address(staking), address(mySBT));
        
        // Finalize linkage
        staking.setRegistry(address(registry));
        mySBT.setRegistry(address(registry));
        
        gToken.mint(user, 1000 ether);
        vm.stopPrank();
    }

    function test_SimplifiedBalanceModel() public {
        vm.startPrank(user);
        gToken.approve(address(staking), 100 ether);
        
        // Use Registry to lock stake (Community role requires 10 ether)
        bytes32 role = registry.ROLE_COMMUNITY();
        bytes memory data = abi.encode(Registry.CommunityRoleData("TestComm", "", "", "", "", 10 ether));
        registry.registerRole(role, user, data);
        
        // Verify balance is 10 ether (not 11 because 1 was burned)
        assertEq(staking.balanceOf(user), 10 ether);
        
        // Verify totalStaked
        assertEq(staking.totalStaked(), 10 ether);
        
        // Verify no shares functions exist (this would fail compilation if called, 
        // but here we just check consistency of the model)
        
        vm.stopPrank();
    }

    function test_SlashEffectOnBalance() public {
        // Setup community role
        vm.prank(user);
        gToken.approve(address(staking), 100 ether);
        vm.prank(user);
        registry.registerRole(registry.ROLE_COMMUNITY(), user, abi.encode(Registry.CommunityRoleData("TestComm", "", "", "", "", 10 ether)));

        // Authorize owner as slasher
        vm.prank(owner);
        staking.setAuthorizedSlasher(owner, true);
        
        // Double check authorization (for debugging if it fails)
        assertTrue(staking.authorizedSlashers(owner), "Owner should be authorized slasher");

        // Slash 2 ether
        vm.prank(owner);
        staking.slashByDVT(user, registry.ROLE_COMMUNITY(), 2 ether, "Testing");

        // Verify balance reduced
        assertEq(staking.balanceOf(user), 8 ether);
        assertEq(staking.totalStaked(), 8 ether);
    }
}
