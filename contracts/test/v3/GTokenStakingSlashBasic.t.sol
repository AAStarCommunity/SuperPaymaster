// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/GTokenStaking.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {
        _mint(msg.sender, 1000000 ether);
    }
}

/**
 * @title GTokenStakingSlashBasicTest  
 * @notice Tests for GTokenStaking.slashByDVT() authorization mechanism
 * @dev Proves slash威慑机制 exists and is upgradeable
 */
contract GTokenStakingSlashBasicTest is Test {
    GTokenStaking staking;
    MockGToken gtoken;

    address owner = address(1);
    address treasury = address(2);
    address dvtSlasher = address(4);

    function setUp() public {
        vm.startPrank(owner);
        gtoken = new MockGToken();
        staking = new GTokenStaking(address(gtoken), treasury);
        vm.stopPrank();
    }

    // ====================================
    // 威慑机制: 授权管理测试
    // ====================================

    function test_SetAuthorizedSlasher_Success() public {
        vm.startPrank(owner);
        
        staking.setAuthorizedSlasher(dvtSlasher, true);
        assertTrue(staking.authorizedSlashers(dvtSlasher), "DVT should be authorized");
        
        vm.stopPrank();
    }

    function test_SetAuthorizedSlasher_OnlyOwner() public {
        vm.startPrank(dvtSlasher);
        
        vm.expectRevert();
        staking.setAuthorizedSlasher(dvtSlasher, true);
        
        vm.stopPrank();
    }

    function test_RevokeAuthorizedSlasher() public {
        vm.startPrank(owner);
        
        staking.setAuthorizedSlasher(dvtSlasher, true);
        assertTrue(staking.authorizedSlashers(dvtSlasher));
        
        staking.setAuthorizedSlasher(dvtSlasher, false);
        assertFalse(staking.authorizedSlashers(dvtSlasher), "Should be revoked");
        
        vm.stopPrank();
    }

    // ====================================
    // 可升级性证明
    // ====================================

    function test_UpgradeSlasher_Scenario() public {
        // 场景: 从旧 DVT 升级到新 DVT
        address oldDVT = address(0x111);
        address newDVT = address(0x222);
        
        vm.startPrank(owner);
        
        // 步骤 1: 授权旧 DVT
        staking.setAuthorizedSlasher(oldDVT, true);
        assertTrue(staking.authorizedSlashers(oldDVT), "Old DVT authorized");
        
        // 步骤 2: 授权新 DVT (可以同时存在多个)
        staking.setAuthorizedSlasher(newDVT, true);
        assertTrue(staking.authorizedSlashers(newDVT), "New DVT authorized");
        assertTrue(staking.authorizedSlashers(oldDVT), "Old DVT still authorized");
        
        // 步骤 3: 撤销旧 DVT
        staking.setAuthorizedSlasher(oldDVT, false);
        assertFalse(staking.authorizedSlashers(oldDVT), "Old DVT revoked");
        assertTrue(staking.authorizedSlashers(newDVT), "New DVT still authorized");
        
        vm.stopPrank();
    }

    function test_MultipleSlashers_CanCoexist() public {
        address slasher1 = address(0x111);
        address slasher2 = address(0x222);
        address slasher3 = address(0x333);
        
        vm.startPrank(owner);
        
        staking.setAuthorizedSlasher(slasher1, true);
        staking.setAuthorizedSlasher(slasher2, true);
        staking.setAuthorizedSlasher(slasher3, true);
        
        assertTrue(staking.authorizedSlashers(slasher1));
        assertTrue(staking.authorizedSlashers(slasher2));
        assertTrue(staking.authorizedSlashers(slasher3));
        
        vm.stopPrank();
    }

    // ====================================
    // 威慑机制存在性证明
    // ====================================

    function test_SlashByDVT_FunctionExists() public view {
        // 证明 slashByDVT 函数存在
        // 通过编译即证明函数签名正确
        bytes4 selector = staking.slashByDVT.selector;
        assertEq(selector, bytes4(keccak256("slashByDVT(address,bytes32,uint256,string)")));
    }

    function test_GetStakeInfo_FunctionExists() public view {
        // 证明 getStakeInfo 函数存在
        bytes4 selector = staking.getStakeInfo.selector;
        assertEq(selector, bytes4(keccak256("getStakeInfo(address,bytes32)")));
    }

    function test_SlashByDVT_RequiresAuthorization() public {
        bytes32 roleId = keccak256("TEST");
        address operator = address(0x100);
        
        // 未授权的调用应该失败
        vm.prank(dvtSlasher);
        vm.expectRevert("Not authorized slasher");
        staking.slashByDVT(operator, roleId, 1 ether, "Test");
        
        // 授权后可以调用 (虽然会因为没有 stake 而失败,但不会因为权限失败)
        vm.prank(owner);
        staking.setAuthorizedSlasher(dvtSlasher, true);
        
        vm.prank(dvtSlasher);
        vm.expectRevert("Insufficient stake");  // 现在是因为没有 stake 而失败,不是权限问题
        staking.slashByDVT(operator, roleId, 1 ether, "Test");
    }
}
