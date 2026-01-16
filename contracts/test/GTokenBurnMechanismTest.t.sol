// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/tokens/GToken.sol";
import "../src/core/GTokenStaking.sol";
import "../src/core/Registry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title GTokenBurnMechanismTest
 * @notice Comprehensive tests for GToken v2.1.0 burn mechanism
 * @dev Tests true token destruction and dynamic CAP management
 */
contract GTokenBurnMechanismTest is Test {
    
    GToken public gToken;
    GTokenStaking public staking;
    
    address public admin = address(0x1);
    address public treasury = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    
    uint256 public constant CAP = 21_000_000 ether;
    uint256 public constant INITIAL_MINT = 10_000_000 ether;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event TokensBurned(address indexed user, bytes32 indexed roleId, uint256 amount, string reason);
    
    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy GToken with cap
        gToken = new GToken(CAP);
        
        // Deploy Staking
        staking = new GTokenStaking(address(gToken), treasury);
        
        // Initial mint
        gToken.mint(admin, INITIAL_MINT);
        
        vm.stopPrank();
    }
    
    // ====================================
    // Test 1: Basic Burnable Functionality
    // ====================================
    
    function testBurnReducesTotalSupply() public {
        uint256 burnAmount = 1000 ether;
        
        vm.startPrank(admin);
        uint256 totalSupplyBefore = gToken.totalSupply();
        
        // Execute burn
        gToken.burn(burnAmount);
        
        uint256 totalSupplyAfter = gToken.totalSupply();
        
        // Verify totalSupply decreased
        assertEq(totalSupplyAfter, totalSupplyBefore - burnAmount, "totalSupply should decrease");
        
        vm.stopPrank();
    }
    
    function testBurnEmitsTransferEvent() public {
        uint256 burnAmount = 500 ether;
        
        vm.startPrank(admin);
        
        // Expect Transfer event to zero address
        vm.expectEmit(true, true, false, true);
        emit Transfer(admin, address(0), burnAmount);
        
        gToken.burn(burnAmount);
        
        vm.stopPrank();
    }
    
    function testBurnFromWithAllowance() public {
        uint256 burnAmount = 200 ether;
        
        vm.prank(admin);
        gToken.transfer(user1, 1000 ether);
        
        // User1 approves user2 to burn
        vm.prank(user1);
        gToken.approve(user2, burnAmount);
        
        uint256 totalSupplyBefore = gToken.totalSupply();
        
        // User2 burns from user1
        vm.prank(user2);
        gToken.burnFrom(user1, burnAmount);
        
        assertEq(gToken.totalSupply(), totalSupplyBefore - burnAmount, "burnFrom should reduce totalSupply");
        assertEq(gToken.balanceOf(user1), 1000 ether - burnAmount, "User1 balance should decrease");
    }
    
    // ====================================
    // Test 2: RemainingMintableSupply
    // ====================================
    
    function testRemainingMintableSupplyInitial() public view {
        uint256 expected = CAP - INITIAL_MINT;
        assertEq(gToken.remainingMintableSupply(), expected, "Initial remaining should be CAP - totalSupply");
    }
    
    function testRemainingMintableSupplyIncreaseOnBurn() public {
        uint256 burnAmount = 1_000_000 ether;
        
        uint256 remainingBefore = gToken.remainingMintableSupply();
        
        vm.prank(admin);
        gToken.burn(burnAmount);
        
        uint256 remainingAfter = gToken.remainingMintableSupply();
        
        assertEq(remainingAfter, remainingBefore + burnAmount, "Remaining should increase by burn amount");
    }
    
    function testMintAfterBurnUsesCreatedCapacity() public {
        uint256 burnAmount = 500_000 ether;
        uint256 newMintAmount = 300_000 ether;
        
        vm.startPrank(admin);
        
        // Burn tokens
        gToken.burn(burnAmount);
        
        uint256 totalSupplyAfterBurn = gToken.totalSupply();
        uint256 remainingAfterBurn = gToken.remainingMintableSupply();
        
        // Mint new tokens using created capacity
        gToken.mint(user1, newMintAmount);
        
        assertEq(gToken.balanceOf(user1), newMintAmount, "User1 should receive minted tokens");
        assertEq(gToken.totalSupply(), totalSupplyAfterBurn + newMintAmount, "totalSupply should increase");
        assertEq(gToken.remainingMintableSupply(), remainingAfterBurn - newMintAmount, "Remaining should decrease");
        
        vm.stopPrank();
    }
    
    function testCannotMintBeyondCap() public {
        uint256 overCapAmount = CAP - gToken.totalSupply() + 1;
        
        vm.startPrank(admin);
        
        vm.expectRevert();
        gToken.mint(user1, overCapAmount);
        
        vm.stopPrank();
    }
    
    // ====================================
    // Test 3: GTokenStaking True Burn
    // ====================================
    
    function testStakingBurnReducesTotalSupply() public {
        // Setup: Create mock registry
        address mockRegistry = address(0x999);
        
        vm.prank(admin);
        staking.setRegistry(mockRegistry);
        
        // Fund user1
        vm.prank(admin);
        gToken.transfer(user1, 1000 ether);
        
        // User1 approves staking
        vm.prank(user1);
        gToken.approve(address(staking), 1000 ether);
        
        uint256 totalSupplyBefore = gToken.totalSupply();
        uint256 stakeAmount = 30 ether;
        uint256 entryBurn = 5 ether;
        bytes32 roleId = keccak256("COMMUNITY");
        
        // Registry calls lockStake (simulated)
        vm.prank(mockRegistry);
        staking.lockStake(user1, roleId, stakeAmount, entryBurn, user1);
        
        // Verify totalSupply decreased by entryBurn
        assertEq(gToken.totalSupply(), totalSupplyBefore - entryBurn, "Entry burn should reduce totalSupply");
    }
    
    function testStakingBurnCreatesRemintCapacity() public {
        address mockRegistry = address(0x999);
        
        vm.prank(admin);
        staking.setRegistry(mockRegistry);
        
        vm.prank(admin);
        gToken.transfer(user1, 1000 ether);
        
        vm.prank(user1);
        gToken.approve(address(staking), 1000 ether);
        
        uint256 remainingBefore = gToken.remainingMintableSupply();
        uint256 entryBurn = 10 ether;
        bytes32 roleId = keccak256("PAYMASTER_SUPER");
        
        vm.prank(mockRegistry);
        staking.lockStake(user1, roleId, 50 ether, entryBurn, user1);
        
        uint256 remainingAfter = gToken.remainingMintableSupply();
        
        assertEq(remainingAfter, remainingBefore + entryBurn, "Entry burn should create remint capacity");
    }
    
    // ====================================
    // Test 4: Burn vs Transfer to Dead
    // ====================================
    
    function testBurnVsTransferToDead() public {
        uint256 amount = 1000 ether;
        address deadAddress = 0x000000000000000000000000000000000000dEaD;
        
        vm.startPrank(admin);
        
        // Scenario 1: Transfer to dead (OLD WAY - WRONG)
        gToken.transfer(user1, amount);
        vm.stopPrank();
        
        vm.prank(user1);
        gToken.transfer(deadAddress, amount);
        
        uint256 totalSupplyAfterTransfer = gToken.totalSupply();
        assertEq(totalSupplyAfterTransfer, INITIAL_MINT, "Transfer to dead should NOT reduce totalSupply");
        assertEq(gToken.balanceOf(deadAddress), amount, "Dead address should hold tokens");
        
        // Scenario 2: True burn (NEW WAY - CORRECT)
        vm.prank(admin);
        gToken.transfer(user2, amount);
        
        vm.prank(user2);
        gToken.burn(amount);
        
        uint256 totalSupplyAfterBurn = gToken.totalSupply();
        assertEq(totalSupplyAfterBurn, INITIAL_MINT - amount, "Burn should reduce totalSupply");
        assertEq(gToken.balanceOf(user2), 0, "User2 balance should be zero");
    }
    
    // ====================================
    // Test 5: Edge Cases
    // ====================================
    
    function testCannotBurnMoreThanBalance() public {
        uint256 balance = gToken.balanceOf(admin);
        
        vm.startPrank(admin);
        
        vm.expectRevert();
        gToken.burn(balance + 1);
        
        vm.stopPrank();
    }
    
    function testFullCycleBurnAndRemint() public {
        vm.startPrank(admin);
        
        // 1. Initial state
        uint256 initialSupply = gToken.totalSupply();
        assertEq(initialSupply, INITIAL_MINT, "Initial supply should match");
        
        // 2. Burn half
        uint256 burnAmount = INITIAL_MINT / 2;
        gToken.burn(burnAmount);
        assertEq(gToken.totalSupply(), INITIAL_MINT - burnAmount, "After burn");
        
        // 3. Remint back to initial
        gToken.mint(admin, burnAmount);
        assertEq(gToken.totalSupply(), initialSupply, "Should return to initial supply");
        
        // 4. Verify cap still enforced
        uint256 remainingCap = gToken.remainingMintableSupply();
        assertEq(remainingCap, CAP - initialSupply, "Remaining cap should be original");
        
        vm.stopPrank();
    }
    
    function testRemainingSupplyNeverNegative() public {
        vm.startPrank(admin);
        
        // Mint to cap
        uint256 remaining = gToken.remainingMintableSupply();
        gToken.mint(user1, remaining);
        
        assertEq(gToken.totalSupply(), CAP, "Should reach cap");
        assertEq(gToken.remainingMintableSupply(), 0, "Remaining should be zero");
        
        // Cannot mint more
        vm.expectRevert();
        gToken.mint(user2, 1);
        
        vm.stopPrank();
    }
    
    // ====================================
    // Test 6: Gas Comparison
    // ====================================
    
    function testGasComparisonBurnVsTransfer() public {
        uint256 amount = 100 ether;
        address deadAddress = 0x000000000000000000000000000000000000dEaD;
        
        vm.startPrank(admin);
        
        // Measure transfer to dead
        uint256 gasBefore = gasleft();
        gToken.transfer(deadAddress, amount);
        uint256 gasTransfer = gasBefore - gasleft();
        
        // Measure true burn
        gasBefore = gasleft();
        gToken.burn(amount);
        uint256 gasBurn = gasBefore - gasleft();
        
        vm.stopPrank();
        
        // Burn should be slightly cheaper (no balance update for dead address)
        emit log_named_uint("Gas Transfer to Dead", gasTransfer);
        emit log_named_uint("Gas True Burn", gasBurn);
        
        assertTrue(gasBurn < gasTransfer + 5000, "Burn should be comparable or cheaper");
    }
}
