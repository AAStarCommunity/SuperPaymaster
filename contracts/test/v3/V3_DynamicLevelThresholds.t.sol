// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/mocks/MockBLSValidator.sol";

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
        
        registry = new Registry(mockGToken, mockStaking, mockSBT);
        
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
        registry.setLevelThreshold(0, 20); // Change Level 2 threshold from 13 to 20
        
        assertEq(registry.levelThresholds(0), 20);
    }

    function test_SetLevelThreshold_MustBeAscending() public {
        vm.startPrank(admin);
        
        // Try to set threshold[1] lower than threshold[0]
        vm.expectRevert("Thresholds must be ascending");
        registry.setLevelThreshold(1, 10); // 10 < 13 (threshold[0])
        
        // Try to set threshold[1] higher than threshold[2]
        vm.expectRevert("Thresholds must be ascending");
        registry.setLevelThreshold(1, 100); // 100 > 89 (threshold[2])
        
        vm.stopPrank();
    }

    function test_SetLevelThreshold_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        registry.setLevelThreshold(0, 20);
    }

    function test_AddLevelThreshold_Success() public {
        vm.prank(admin);
        registry.addLevelThreshold(1597); // Add Level 7 (Fibonacci 17)
        
        assertEq(registry.levelThresholds(5), 1597);
    }

    function test_AddLevelThreshold_MustBeHigherThanLast() public {
        vm.prank(admin);
        vm.expectRevert("Threshold must be higher than last");
        registry.addLevelThreshold(500); // 500 < 610 (last threshold)
    }

    function test_AddLevelThreshold_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        registry.addLevelThreshold(1597);
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
        registry.batchUpdateGlobalReputation(users, scores, 100, _dummyProof());
        
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
        registry.batchUpdateGlobalReputation(users, scores, 101, _dummyProof());
        
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
            registry.batchUpdateGlobalReputation(users, scores, 102 + i, _dummyProof());
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
        registry.batchUpdateGlobalReputation(users, scores, 103, _dummyProof());
        assertEq(registry.getCreditLimit(user1), 100 ether); // Level 2
        
        // Change Level 2 threshold from 13 to 20
        registry.setLevelThreshold(0, 20);
        
        // Now user with rep=15 should be Level 1
        assertEq(registry.getCreditLimit(user1), 0); // Level 1
        
        vm.stopPrank();
    }

    function test_GetCreditLimit_AfterAddingNewLevel() public {
        vm.startPrank(admin);
        
        // Add Level 7 with threshold 1597
        registry.addLevelThreshold(1597);
        registry.setCreditTier(7, 5000 ether);
        
        // User with rep=2000 should be Level 7
        // Update in steps to reach 2000
        address[] memory users = new address[](1);
        users[0] = user1;
        uint256[] memory scores = new uint256[](1);
        
        for (uint256 i = 0; i < 20; i++) {
            scores[0] = (i + 1) * 100;
            registry.batchUpdateGlobalReputation(users, scores, 104 + i, _dummyProof());
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
        registry.batchUpdateGlobalReputation(users, scores, 105, _dummyProof());
        
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
        registry.batchUpdateGlobalReputation(users, scores, 200, _dummyProof());
        assertEq(registry.getCreditLimit(user1), 300 ether); // Level 3
        
        // 2. Adjust threshold to make Level 3 harder to reach
        registry.setLevelThreshold(1, 60); // Level 3 now requires rep >= 60
        assertEq(registry.getCreditLimit(user1), 100 ether); // Downgraded to Level 2
        
        // 3. User improves reputation
        scores[0] = 70;
        registry.batchUpdateGlobalReputation(users, scores, 201, _dummyProof());
        assertEq(registry.getCreditLimit(user1), 300 ether); // Back to Level 3
        
        // 4. Add new high-tier level
        registry.addLevelThreshold(1597); // Level 7
        registry.setCreditTier(7, 10000 ether);
        
        // 5. User reaches top tier (need multiple updates to reach 2000)
        for (uint256 i = 0; i < 20; i++) {
            scores[0] = 70 + (i + 1) * 100;
            registry.batchUpdateGlobalReputation(users, scores, 202 + i, _dummyProof());
        }
        assertEq(registry.getCreditLimit(user1), 10000 ether); // Level 7
        
        vm.stopPrank();
    }
}
