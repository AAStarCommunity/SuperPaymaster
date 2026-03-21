// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/mocks/MockBLSValidator.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/**
 * @title V3_DynamicLevelThresholds_Test
 * @notice 测试 Registry 的动态等级阈值系统
 */
contract V3_DynamicLevelThresholds_Test is Test {
    Registry public registry;
    
    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public user3 = address(0x4);
    
    function setUp() public {
        vm.startPrank(admin);
        
        address mockGToken = address(0x888);
        address mockStaking = address(0x999);
        address mockSBT = address(0x777);
        
        registry = UUPSDeployHelper.deployRegistryProxy(admin, mockStaking, mockSBT);
        
        // Authorize admin as reputation source
        registry.setReputationSource(admin, true);

        // Mock BLS precompile
        vm.mockCall(address(0x11), "", abi.encode(uint256(1)));
        
        // Set BLS Validator
        MockBLSValidator validator = new MockBLSValidator();
        registry.setBLSValidator(address(validator));
        
        vm.stopPrank();
    }
    
    // Helper to generate dummy proof
    function _dummyProof() internal pure returns (bytes memory) {
        return abi.encode(new bytes(96), new bytes(192), new bytes(192), uint256(0xF));
    }

    // ====================================
    // Level Thresholds Configuration Tests
    // ====================================

    function test_LevelThresholds_DefaultInitialization() public {
        // Verify default Fibonacci thresholds
        assertEq(registry.levelThresholds(0), 13);   // Level 2
        assertEq(registry.levelThresholds(1), 34);   // Level 3
        assertEq(registry.levelThresholds(2), 89);   // Level 4
        assertEq(registry.levelThresholds(3), 233);  // Level 5
        assertEq(registry.levelThresholds(4), 610);  // Level 6
    }

    function test_SetLevelThreshold_Success() public {
        vm.prank(admin);
        // Replace full array: change index 0 from 13 to 20
        uint256[] memory t = new uint256[](5);
        t[0] = 20; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 610;
        registry.setLevelThresholds(t);

        assertEq(registry.levelThresholds(0), 20);
    }

    function test_SetLevelThreshold_MustBeAscending() public {
        vm.startPrank(admin);

        // Try array with threshold[1]=10, which is < threshold[0]=13
        uint256[] memory t1 = new uint256[](5);
        t1[0] = 13; t1[1] = 10; t1[2] = 89; t1[3] = 233; t1[4] = 610;
        vm.expectRevert(Registry.ThreshNotAscending.selector);
        registry.setLevelThresholds(t1);

        // Try array with threshold[1]=100, which is > threshold[2]=89
        uint256[] memory t2 = new uint256[](5);
        t2[0] = 13; t2[1] = 100; t2[2] = 89; t2[3] = 233; t2[4] = 610;
        vm.expectRevert(Registry.ThreshNotAscending.selector);
        registry.setLevelThresholds(t2);

        vm.stopPrank();
    }

    function test_SetLevelThreshold_OnlyOwner() public {
        vm.prank(user1);
        uint256[] memory t = new uint256[](5);
        t[0] = 20; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 610;
        vm.expectRevert();
        registry.setLevelThresholds(t);
    }

    function test_AddLevelThreshold_Success() public {
        vm.prank(admin);
        // Add Level 7 by appending 1597 to existing thresholds
        uint256[] memory t = new uint256[](6);
        t[0] = 13; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 610; t[5] = 1597;
        registry.setLevelThresholds(t);

        assertEq(registry.levelThresholds(5), 1597);
    }

    function test_AddLevelThreshold_MustBeHigherThanLast() public {
        vm.prank(admin);
        // Try to append 500 which is < 610 (last threshold)
        uint256[] memory t = new uint256[](6);
        t[0] = 13; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 610; t[5] = 500;
        vm.expectRevert(Registry.ThreshNotAscending.selector);
        registry.setLevelThresholds(t);
    }

    function test_AddLevelThreshold_OnlyOwner() public {
        vm.prank(user1);
        uint256[] memory t = new uint256[](6);
        t[0] = 13; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 610; t[5] = 1597;
        vm.expectRevert();
        registry.setLevelThresholds(t);
    }

    // ====================================
    // Dynamic Level Lookup Tests
    // ====================================

    function test_GetCreditLimit_Level1() public {
        // User with rep < 13 should be Level 1
        vm.prank(admin);
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory scores = new uint256[](1);
        scores[0] = 10;
        registry.batchUpdateGlobalReputation(1, users, scores, 100, _dummyProof());
        
        uint256 creditLimit = registry.getCreditLimit(user1);
        assertEq(creditLimit, 0); // Level 1 has 0 credit
    }

    function test_GetCreditLimit_Level2() public {
        // User with rep >= 13 and < 34 should be Level 2
        vm.prank(admin);
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory scores = new uint256[](1);
        scores[0] = 20;
        registry.batchUpdateGlobalReputation(1, users, scores, 101, _dummyProof());
        
        uint256 creditLimit = registry.getCreditLimit(user1);
        assertEq(creditLimit, 100 ether); // Level 2 has 100 ether credit
    }

    function test_GetCreditLimit_Level6() public {
        // User with rep >= 610 should be Level 6
        // Note: maxChange=100, so we need multiple updates
        vm.startPrank(admin);
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory scores = new uint256[](1);
        
        // Update in steps of 100 to reach 1000
        for (uint256 i = 0; i < 10; i++) {
            scores[0] = (i + 1) * 100;
            registry.batchUpdateGlobalReputation(i + 102, users, scores, 102 + i, _dummyProof());
        }
        
        uint256 creditLimit = registry.getCreditLimit(user1);
        assertEq(creditLimit, 2000 ether); // Level 6 has 2000 ether credit
    }

    function test_GetCreditLimit_AfterThresholdChange() public {
        // Initial: user with rep=15 is Level 2
        vm.startPrank(admin);
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory scores = new uint256[](1);
        scores[0] = 15;
        registry.batchUpdateGlobalReputation(1, users, scores, 103, _dummyProof());
        assertEq(registry.getCreditLimit(user1), 100 ether); // Level 2
        
        // Change Level 2 threshold from 13 to 20
        uint256[] memory t = new uint256[](5);
        t[0] = 20; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 610;
        registry.setLevelThresholds(t);

        // Now user with rep=15 should be Level 1
        assertEq(registry.getCreditLimit(user1), 0); // Level 1
        
        vm.stopPrank();
    }

    function test_GetCreditLimit_AfterAddingNewLevel() public {
        vm.startPrank(admin);
        
        // Add Level 7 with threshold 1597
        uint256[] memory t = new uint256[](6);
        t[0] = 13; t[1] = 34; t[2] = 89; t[3] = 233; t[4] = 610; t[5] = 1597;
        registry.setLevelThresholds(t);
        registry.setCreditTier(7, 5000 ether);
        
        // User with rep=2000 should be Level 7
        // Update in steps to reach 2000
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory scores = new uint256[](1);
        
        for (uint256 i = 0; i < 20; i++) {
            scores[0] = (i + 1) * 100;
            registry.batchUpdateGlobalReputation(i + 104, users, scores, 104 + i, _dummyProof());
        }
        
        assertEq(registry.getCreditLimit(user1), 5000 ether); // Level 7
        
        vm.stopPrank();
    }

    function test_GetCreditLimit_BoundaryValues() public {
        vm.startPrank(admin);
        
        // Test exact threshold values with simple cases
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        uint256[] memory scores = new uint256[](2);
        scores[0] = 13;   // Exactly Level 2 threshold
        scores[1] = 12;   // Just below Level 2
        registry.batchUpdateGlobalReputation(1, users, scores, 105, _dummyProof());
        
        assertEq(registry.getCreditLimit(user1), 100 ether); // Level 2
        assertEq(registry.getCreditLimit(user2), 0); // Level 1
        
        vm.stopPrank();
    }

    // ====================================
    // Integration Tests
    // ====================================

    function test_DynamicLevelSystem_CompleteFlow() public {
        vm.startPrank(admin);
        
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory scores = new uint256[](1);
        
        // 1. Set initial reputation
        scores[0] = 50;
        registry.batchUpdateGlobalReputation(1, users, scores, 200, _dummyProof());
        assertEq(registry.getCreditLimit(user1), 300 ether); // Level 3
        
        // 2. Adjust threshold to make Level 3 harder to reach
        uint256[] memory t1 = new uint256[](5);
        t1[0] = 13; t1[1] = 60; t1[2] = 89; t1[3] = 233; t1[4] = 610;
        registry.setLevelThresholds(t1); // Level 3 now requires rep >= 60
        assertEq(registry.getCreditLimit(user1), 100 ether); // Downgraded to Level 2

        // 3. User improves reputation
        scores[0] = 70;
        registry.batchUpdateGlobalReputation(2, users, scores, 201, _dummyProof());
        assertEq(registry.getCreditLimit(user1), 300 ether); // Back to Level 3

        // 4. Add new high-tier level
        uint256[] memory t2 = new uint256[](6);
        t2[0] = 13; t2[1] = 60; t2[2] = 89; t2[3] = 233; t2[4] = 610; t2[5] = 1597;
        registry.setLevelThresholds(t2); // Level 7
        registry.setCreditTier(7, 10000 ether);
        
        // 5. User reaches top tier (need multiple updates to reach 2000)
        for (uint256 i = 0; i < 20; i++) {
            scores[0] = 70 + (i + 1) * 100;
            registry.batchUpdateGlobalReputation(i + 202, users, scores, 202 + i, _dummyProof());
        }
        assertEq(registry.getCreditLimit(user1), 10000 ether); // Level 7

        vm.stopPrank();
    }

    // ====================================
    // Boundary Condition Tests (Kimi audit)
    // ====================================

    function test_SetLevelThresholds_MaxLength20() public {
        vm.startPrank(admin);
        // Exactly 20 thresholds should succeed (max allowed)
        uint256[] memory t = new uint256[](20);
        for (uint256 i = 0; i < 20; i++) {
            t[i] = (i + 1) * 100;
        }
        registry.setLevelThresholds(t);
        assertEq(registry.levelThresholds(19), 2000);
        vm.stopPrank();
    }

    function test_SetLevelThresholds_Exceeds20_Reverts() public {
        vm.startPrank(admin);
        // 21 thresholds should revert
        uint256[] memory t = new uint256[](21);
        for (uint256 i = 0; i < 21; i++) {
            t[i] = (i + 1) * 100;
        }
        vm.expectRevert(Registry.TooManyLevels.selector);
        registry.setLevelThresholds(t);
        vm.stopPrank();
    }

    function test_BatchUpdateReputation_Max200() public {
        vm.startPrank(admin);
        // Exactly 200 users should succeed
        address[] memory users = new address[](200);
        uint256[] memory scores = new uint256[](200);
        for (uint256 i = 0; i < 200; i++) {
            users[i] = address(uint160(0x1000 + i));
            scores[i] = 10;
        }
        registry.batchUpdateGlobalReputation(1, users, scores, 300, _dummyProof());
        // Verify first and last
        assertEq(registry.globalReputation(users[0]), 10);
        assertEq(registry.globalReputation(users[199]), 10);
        vm.stopPrank();
    }

    function test_BatchUpdateReputation_Exceeds200_Reverts() public {
        vm.startPrank(admin);
        // 201 users should revert
        address[] memory users = new address[](201);
        uint256[] memory scores = new uint256[](201);
        for (uint256 i = 0; i < 201; i++) {
            users[i] = address(uint160(0x2000 + i));
            scores[i] = 10;
        }
        vm.expectRevert(Registry.BatchTooLarge.selector);
        registry.batchUpdateGlobalReputation(2, users, scores, 301, _dummyProof());
        vm.stopPrank();
    }
}
