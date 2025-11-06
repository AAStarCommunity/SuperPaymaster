// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { PaymasterV4 } from "../src/paymasters/v4/PaymasterV4.sol";

contract PaymasterV4ActivityTest is Test {
    PaymasterV4 public paymaster;
    
    address public owner = address(0x1);
    address public treasury = address(0x3);
    address public mockEntryPoint = address(0x4);
    address public mockPriceFeed = address(0x5);
    address public mockXPntsFactory = address(0x6);

    function setUp() public {
        // Deploy paymaster with correct constructor parameters
        paymaster = new PaymasterV4(
            mockEntryPoint,
            owner,
            treasury,
            mockPriceFeed,
            200, // 2% service fee
            1 ether, // max gas cost cap
            mockXPntsFactory
        );
    }

    function testAddActivitySBT() public {
        address sbt = address(0x7);
        
        vm.startPrank(owner);
        paymaster.transferOwnership(owner);
        
        // Test adding activity SBT
        paymaster.addActivitySBT(sbt);
        
        assertTrue(paymaster.isActivitySBT(sbt), "SBT should be added as activity SBT");
        
        vm.stopPrank();
    }

    function testAddSBTWithActivity() public {
        address sbt = address(0x8);
        
        vm.startPrank(owner);
        paymaster.transferOwnership(owner);
        
        // Test adding SBT with activity support
        paymaster.addSBTWithActivity(sbt);
        
        assertTrue(paymaster.isSBTSupported(sbt), "SBT should be supported");
        assertTrue(paymaster.isActivitySBT(sbt), "SBT should be activity SBT");
        
        vm.stopPrank();
    }
}