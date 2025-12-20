// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/core/Registry.sol";
import "../src/tokens/GToken.sol";
import "../src/core/GTokenStaking.sol";

contract DebugPhase5 is Test {
    Registry registry;
    GToken gtoken;
    GTokenStaking staking;

    address REGISTRY_ADDR = 0x1c85638e118b37167e9298c2268758e058DdfDA0;
    address GTOKEN_ADDR = 0x46b142DD1E924FAb83eCc3c08e4D46E82f005e0E;
    address STAKING_ADDR = 0xC9a43158891282A2B1475592D5719c001986Aaec;
    address BREAD_DAO = 0x2546BcD3c84621e976D8185a91A922aE77ECEc30; // From logs

    address admin = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // Anvil #0
    address dave = 0xB0De20A2C9adEeb5Aea4DAd763A4Bd6be6c68095; // From logs (or fresh)

    bytes32 ROLE_ENDUSER = keccak256("ENDUSER");

    function setUp() public {
        // Fork local anvil
        vm.createSelectFork("http://127.0.0.1:8545");

        registry = Registry(REGISTRY_ADDR);
        gtoken = GToken(GTOKEN_ADDR);
        staking = GTokenStaking(STAKING_ADDR);
    }

    function testDebugRegister() public {
        // 1. Setup Dave (Fresh)
        dave = makeAddr("dave_debug");
        vm.deal(dave, 1 ether);
        
        // 2. Fund Dave GToken
        vm.prank(admin);
        gtoken.mint(dave, 500);
        
        // 3. Approve Staking
        vm.prank(dave);
        gtoken.approve(address(staking), 500);

        // Check allowance
        uint256 all = gtoken.allowance(dave, address(staking));
        console.log("Allowance:", all);
        require(all >= 500, "Allowance failed");

        // 4. Register
        Registry.EndUserRoleData memory data = Registry.EndUserRoleData({
            account: dave,
            community: BREAD_DAO,
            avatarURI: "ipfs://dave",
            ensName: "dave.c",
            stakeAmount: 500
        });

        bytes memory roleData = abi.encode(data);

        vm.prank(dave);
        registry.registerRoleSelf(ROLE_ENDUSER, roleData);
    }
}
