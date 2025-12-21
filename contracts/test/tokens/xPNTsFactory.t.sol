// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/tokens/xPNTsToken.sol";

contract xPNTsFactoryTest is Test {
    xPNTsFactory factory;
    address owner = address(1);
    address mockSP = address(2);
    address mockRegistry = address(3);
    
    function setUp() public {
        vm.startPrank(owner);
        factory = new xPNTsFactory(mockSP, mockRegistry);
        vm.stopPrank();
    }
    
    function test_Deployment() public {
        vm.prank(address(4)); // Community
        address token = factory.deployxPNTsToken(
            "Test", "TEST", "TestComm", "test.eth", 1e18, address(0)
        );
        
        assertTrue(token != address(0));
        assertTrue(factory.hasToken(address(4)));
        assertEq(factory.getDeployedCount(), 1);
        
        xPNTsToken t = xPNTsToken(token);
        assertEq(t.name(), "Test");
    }
    
    function test_Prediction() public {
        address comm = address(5);
        
        vm.prank(comm);
        factory.updatePrediction(100, 1 gwei, "DeFi", 0);
        
        uint256 suggested = factory.predictDepositAmount(comm);
        // Calc: 100 * 1e9 * 30 = 3000e9 = 3e12 wei monthly cost
        // Multiplier DeFi = 2.0 (2e18). Safety = 1.5 (1.5e18).
        // 3e12 * 2e18 * 1.5e18 / 1e36 = 3e12 * 3 = 9e12
        // Wait, price is not involved in predictDepositAmount?
        // Reading source:
        // dailyCost = tx * gasCost
        // monthly = daily * 30
        // result = monthly * mult * safety / 1e36
        // 100 * 1 gwei = 100 gwei = 1e11 wei.
        // Monthly = 30e11 = 3e12 wei.
        // 3e12 * 2 * 1.5 = 9e12.
        // MIN_SUGGESTED is 100 ether (100e18).
        // 9e12 is tiny. So currently expecting MIN.
        
        assertEq(suggested, 100 ether); // Min threshold hit
        
        // Let's try larger numbers to exceed min
        // 10000 tx/day. 1e7 gwei average cost (oops, 1e16 wei = 0.01 eth)
        // 10000 * 0.01 eth = 100 eth daily.
        // 3000 eth monthly.
        // * 3 = 9000 eth.
        
        vm.prank(comm);
        factory.updatePrediction(10000, 0.01 ether, "DeFi", 0);
        suggested = factory.predictDepositAmount(comm);
        assertEq(suggested, 9000 ether);
    }
    
    function test_Admin() public {
        vm.startPrank(owner);
        factory.updateAPNTsPrice(1 ether);
        assertEq(factory.getAPNTsPrice(), 1 ether);
        
        factory.setIndustryMultiplier("New", 5 ether);
        assertEq(factory.getIndustryMultiplier("New"), 5 ether);
        vm.stopPrank();
    }
}
