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
    address user = address(4);
    
    function setUp() public {
        vm.startPrank(owner);
        factory = new xPNTsFactory(mockSP, mockRegistry);
        vm.stopPrank();
    }
    
    function test_Constructor_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(xPNTsFactory.InvalidAddress.selector, address(0)));
        new xPNTsFactory(mockSP, address(0));
    }
    
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function test_Deployment_Success() public {
        vm.prank(user);
        // Mock hasRole to return true for user
        vm.mockCall(
            mockRegistry, 
            abi.encodeWithSelector(bytes4(keccak256("hasRole(bytes32,address)")), ROLE_COMMUNITY, user), 
            abi.encode(true)
        );
        
        address token = factory.deployxPNTsToken(
            "Test", "TEST", "TestComm", "test.eth", 1e18, address(0)
        );
        
        assertTrue(token != address(0));
        assertTrue(factory.hasToken(user));
        assertEq(factory.getTokenAddress(user), token);
        assertEq(factory.getDeployedCount(), 1);
        
        // AOA mode with specific paymaster
        address user2 = address(5);
        address mockPaymaster = address(6);
        vm.prank(user2);
        // Mock hasRole to return true for user2
        vm.mockCall(
            mockRegistry, 
            abi.encodeWithSelector(bytes4(keccak256("hasRole(bytes32,address)")), ROLE_COMMUNITY, user2), 
            abi.encode(true)
        );
        address token2 = factory.deployxPNTsToken(
            "Test2", "TEST2", "TestComm2", "test2.eth", 1e18, mockPaymaster
        );
        assertTrue(token2 != address(0));
        assertEq(factory.getDeployedCount(), 2);
    }

    function test_Deployment_RevertIf_NotCommunity() public {
        vm.prank(user);
        // Mock hasRole to return false
        vm.mockCall(
            mockRegistry, 
            abi.encodeWithSelector(bytes4(keccak256("hasRole(bytes32,address)")), ROLE_COMMUNITY, user), 
            abi.encode(false)
        );
        
        vm.expectRevert("Caller must be Community");
        factory.deployxPNTsToken("T", "T", "C", "C", 1e18, address(0));
    }
    
    function test_Deployment_SwitchModes() public {
        // Test without predefined SP
        vm.prank(owner);
        xPNTsFactory f2 = new xPNTsFactory(address(0), mockRegistry);
        
        vm.prank(user);
        // Mock hasRole check on the registry passed to this factory instance
        vm.mockCall(
            mockRegistry, 
            abi.encodeWithSelector(bytes4(keccak256("hasRole(bytes32,address)")), ROLE_COMMUNITY, user), 
            abi.encode(true)
        );
        address t1 = f2.deployxPNTsToken("T", "T", "C", "C", 1e18, address(0));
        assertTrue(t1 != address(0));
        
        // Set SP later
        vm.prank(owner);
        f2.setSuperPaymasterAddress(mockSP);
        assertEq(f2.SUPERPAYMASTER(), mockSP);
        
        vm.prank(address(5));
        // Mock hasRole check for address(5)
        vm.mockCall(
            mockRegistry, 
            abi.encodeWithSelector(bytes4(keccak256("hasRole(bytes32,address)")), ROLE_COMMUNITY, address(5)), 
            abi.encode(true)
        );
        address t2 = f2.deployxPNTsToken("T2", "T2", "C2", "C2", 1e18, address(0));
        assertTrue(t2 != address(0));
    }
    
    function test_Deployment_AlreadyDeployed() public {
        vm.startPrank(user);
        // Mock role success
        vm.mockCall(
            mockRegistry, 
            abi.encodeWithSelector(bytes4(keccak256("hasRole(bytes32,address)")), ROLE_COMMUNITY, user), 
            abi.encode(true)
        );

        factory.deployxPNTsToken("T", "T", "C", "C", 1e18, address(0));
        
        vm.expectRevert(abi.encodeWithSelector(xPNTsFactory.AlreadyDeployed.selector, user));
        factory.deployxPNTsToken("T", "T", "C", "C", 1e18, address(0));
        vm.stopPrank();
    }

    function test_Prediction_Update() public {
        address comm = address(5);
        
        // Test update with known industry
        vm.prank(comm);
        factory.updatePrediction(100, 1 gwei, "DeFi", 0);
        
        xPNTsFactory.PredictionParams memory p = factory.getPredictionParams(comm);
        assertEq(p.industryMultiplier, 2e18); // DeFi = 2.0
        assertEq(p.safetyFactor, 1.5 ether); // Default
        
        // Test update with unknown industry
        vm.prank(comm);
        factory.updatePrediction(100, 1 gwei, "Unknown", 0);
        p = factory.getPredictionParams(comm);
        assertEq(p.industryMultiplier, 1 ether); // Default 1.0
        
        // Test custom update
        vm.prank(comm);
        factory.updatePredictionCustom(100, 1 gwei, 3e18, 2e18);
        p = factory.getPredictionParams(comm);
        assertEq(p.industryMultiplier, 3e18);
        assertEq(p.safetyFactor, 2e18);
        
        // Custom with zero multiplier defaults to 1.0
        vm.prank(comm);
        factory.updatePredictionCustom(100, 1 gwei, 0, 0);
        p = factory.getPredictionParams(comm);
        assertEq(p.industryMultiplier, 1 ether);
        assertEq(p.safetyFactor, 1.5 ether);
    }
    
    function test_Prediction_Calculation() public {
        address comm = address(6);
        
        // Case 1: Minimal -> Returns MIN
        vm.prank(comm);
        factory.updatePrediction(1, 100, "Social", 0);
        uint256 predicted = factory.predictDepositAmount(comm);
        assertEq(predicted, 100 ether); // MIN_SUGGESTED_AMOUNT
        
        // Case 2: New community (0 tx) -> Returns MIN
        assertEq(factory.predictDepositAmount(address(7)), 100 ether);
        
        // Case 3: Large calculation
        // 1000 tx/day * 0.01 ether cost * 30 days * 2.0 (DeFi) * 1.5 (Safety)
        // 1000 * 1e16 wei = 1e19 wei daily
        // Monthly = 30e19 = 3e20
        // * 2.0 = 6e20
        // * 1.5 = 9e20
        vm.prank(comm);
        factory.updatePrediction(1000, 0.01 ether, "DeFi", 0);
        
        predicted = factory.predictDepositAmount(comm);
        assertEq(predicted, 900 ether); // Wait: 9e20 wei? 
        // Logic: monthly * mult * safety / 1e36?
        // Let's trace calculation in contract:
        // daily = 1000 * 1e16 = 1e19
        // monthly = 3e20
        // result = 3e20 * 2e18 * 1.5e18 / 1e36 = 9e20 * 1e36 / 1e36 = 9e20 (900 ether)
        // Correct.
        
        // Verify breakdown
        (uint256 daily, uint256 monthly, uint256 sugg, uint256 mUsed, uint256 sUsed) 
            = factory.getDepositBreakdown(comm);
        assertEq(daily, 1e19);
        assertEq(monthly, 3e20);
        assertEq(sugg, 900 ether);
        assertEq(mUsed, 2e18);
        assertEq(sUsed, 1.5 ether);
    }
    
    function test_Admin_Functions() public {
        vm.startPrank(owner);
        
        // setSuperPaymasterAddress
        factory.setSuperPaymasterAddress(address(99));
        assertEq(factory.SUPERPAYMASTER(), address(99));
        vm.expectRevert("Invalid address");
        factory.setSuperPaymasterAddress(address(0));
        
        // updateAPNTsPrice
        factory.updateAPNTsPrice(1 ether);
        assertEq(factory.getAPNTsPrice(), 1 ether);
        vm.expectRevert("Price must be positive");
        factory.updateAPNTsPrice(0);
        
        // setIndustryMultiplier
        factory.setIndustryMultiplier("Custom", 5 ether);
        assertEq(factory.getIndustryMultiplier("Custom"), 5 ether);
        
        vm.expectRevert("Invalid multiplier");
        factory.setIndustryMultiplier("Bad", 0);
        
        vm.expectRevert("Invalid multiplier");
        factory.setIndustryMultiplier("Bad", 11 ether);
        
        vm.stopPrank();
        
        // Access control
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        factory.updateAPNTsPrice(2 ether);
    }
    
    function test_View_Functions() public {
        vm.prank(user);
        // Mock role for view test
        vm.mockCall(
            mockRegistry, 
            abi.encodeWithSelector(bytes4(keccak256("hasRole(bytes32,address)")), ROLE_COMMUNITY, user), 
            abi.encode(true)
        );
        
        address t1 = factory.deployxPNTsToken("A", "A", "A", "A", 1e18, address(0));
        
        address[] memory all = factory.getAllTokens();
        assertEq(all.length, 1);
        assertEq(all[0], t1);
    }
}
