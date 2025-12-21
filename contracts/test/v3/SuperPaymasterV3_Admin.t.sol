// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/**
 * @title Mock EntryPoint
 */
contract MockEntryPoint {
    function depositTo(address) external payable {}
}

/**
 * @title Mock Price Feed
 */
contract MockPriceFeed {
    int256 public price = 2000 * 1e8;
    
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

/**
 * @title Mock aPNTs Token
 */
contract MockAPNTs is ERC20 {
    constructor() ERC20("AAStar Points", "aPNTs") {}
    
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title SuperPaymasterV3_Admin_Test
 */
contract SuperPaymasterV3_Admin_Test is Test {
    using stdStorage for StdStorage;
    
    SuperPaymasterV3 public paymaster;
    Registry public registry;
    GToken public gtoken;
    MockEntryPoint public entryPoint;
    MockPriceFeed public priceFeed;
    MockAPNTs public apnts;
    
    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public operator1 = address(0x3);
    address public user1 = address(0x5);
    
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    
    function setUp() public {
        vm.startPrank(owner);
        
        gtoken = new GToken(21_000_000 ether);
        entryPoint = new MockEntryPoint();
        priceFeed = new MockPriceFeed();
        apnts = new MockAPNTs();
        
        address mockStaking = address(0x999);
        address mockSBT = address(0x888);
        registry = new Registry(address(gtoken), mockStaking, mockSBT);
        
        paymaster = new SuperPaymasterV3(
            IEntryPoint(address(entryPoint)),
            owner,
            IRegistryV3(address(registry)),
            address(apnts),
            address(priceFeed),
            treasury
        );
        
        // Use stdstore to set hasRole[ROLE_COMMUNITY][operator1] = true
        stdstore
            .target(address(registry))
            .sig("hasRole(bytes32,address)")
            .with_key(ROLE_COMMUNITY)
            .with_key(operator1)
            .checked_write(true);
        
        apnts.mint(operator1, 10000 ether);
        
        vm.stopPrank();
        
        vm.prank(operator1);
        apnts.approve(address(paymaster), type(uint256).max);
    }

    // ====================================
    // Debug Test - Verify hasRole
    // ====================================

    function test_VerifyHasRole() public {
        bool hasRoleValue = registry.hasRole(ROLE_COMMUNITY, operator1);
        assertTrue(hasRoleValue, "operator1 should have COMMUNITY role");
    }

    // ====================================
    // Admin Functions Tests
    // ====================================

    function test_SetAPNTsToken() public {
        address newToken = address(0x777);
        
        vm.prank(owner);
        paymaster.setAPNTsToken(newToken);
        
        assertEq(paymaster.APNTS_TOKEN(), newToken);
    }

    function test_SetAPNTsToken_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.setAPNTsToken(address(0x777));
    }

    function test_SetAPNTSPrice() public {
        vm.prank(owner);
        paymaster.setAPNTSPrice(100 * 1e18);
        
        assertEq(paymaster.aPNTsPriceUSD(), 100 * 1e18);
    }

    function test_SetAPNTSPrice_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.setAPNTSPrice(100 * 1e18);
    }

    function test_SetProtocolFee() public {
        vm.prank(owner);
        paymaster.setProtocolFee(500);
        
        assertEq(paymaster.protocolFeeBPS(), 500);
    }

    function test_SetProtocolFee_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.setProtocolFee(500);
    }

    function test_SetTreasury() public {
        address newTreasury = address(0x666);
        
        vm.prank(owner);
        paymaster.setTreasury(newTreasury);
        
        assertEq(paymaster.treasury(), newTreasury);
    }

    function test_SetTreasury_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.setTreasury(address(0x666));
    }

    function test_SetOperatorPaused() public {
        vm.prank(owner);
        paymaster.setOperatorPaused(operator1, true);
        
        (, bool isConfigured, bool isPaused,,,,,,) = paymaster.operators(operator1);
        assertTrue(isPaused);
    }

    function test_SetOperatorPaused_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.setOperatorPaused(operator1, true);
    }

    function test_SetOperatorPause() public {
        vm.prank(owner);
        paymaster.setOperatorPause(operator1, true);
        
        (, bool isConfigured, bool isPaused,,,,,,) = paymaster.operators(operator1);
        assertTrue(isPaused);
    }

    function test_SetOperatorPause_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.setOperatorPause(operator1, true);
    }

    // ====================================
    // Operator Configuration Tests
    // ====================================

    function test_ConfigureOperator_Success() public {
        address xPNTsToken = address(0x555);
        address opTreasury = address(0x444);
        uint256 exchangeRate = 1.5 ether;
        
        vm.prank(operator1);
        paymaster.configureOperator(xPNTsToken, opTreasury, exchangeRate);
        
        (address token, bool isConfigured, bool isPaused, address treas, uint96 rate,,,,) = paymaster.operators(operator1);
        assertTrue(isConfigured);
        assertEq(token, xPNTsToken);
        assertEq(treas, opTreasury);
        assertEq(rate, exchangeRate);
    }

    function test_ConfigureOperator_NotRegistered() public {
        vm.prank(user1);
        vm.expectRevert("Operator not registered");
        paymaster.configureOperator(address(0x555), address(0x444), 1 ether);
    }

    // ====================================
    // Deposit/Withdraw Tests
    // ====================================

    function test_Deposit_Success() public {
        uint256 depositAmount = 100 ether;
        
        vm.prank(operator1);
        paymaster.deposit(depositAmount);
        
        (,,,,, uint256 aPNTsBalance,,,) = paymaster.operators(operator1);
        assertEq(aPNTsBalance, depositAmount);
    }

    function test_Deposit_NotRegistered() public {
        vm.prank(user1);
        vm.expectRevert("Operator not registered");
        paymaster.deposit(100 ether);
    }

    function test_Withdraw_Success() public {
        vm.prank(operator1);
        paymaster.deposit(100 ether);
        
        uint256 balanceBefore = apnts.balanceOf(operator1);
        
        vm.prank(operator1);
        paymaster.withdraw(50 ether);
        
        uint256 balanceAfter = apnts.balanceOf(operator1);
        assertEq(balanceAfter - balanceBefore, 50 ether);
        
        (,,,,, uint256 aPNTsBalance,,,) = paymaster.operators(operator1);
        assertEq(aPNTsBalance, 50 ether);
    }

    function test_Withdraw_InsufficientBalance() public {
        vm.prank(operator1);
        paymaster.deposit(100 ether);
        
        vm.prank(operator1);
        vm.expectRevert("Insufficient balance");
        paymaster.withdraw(200 ether);
    }

    // ====================================
    // Reputation Management Tests
    // ====================================

    function test_UpdateReputation() public {
        vm.prank(owner);
        paymaster.updateReputation(operator1, 500);
        
        (,,,,,,,, uint256 reputation) = paymaster.operators(operator1);
        assertEq(reputation, 500);
    }

    function test_UpdateReputation_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.updateReputation(operator1, 500);
    }

    // ====================================
    // Slash Tests
    // ====================================

    function test_SlashOperator_Minor() public {
        vm.prank(operator1);
        paymaster.deposit(1000 ether);
        
        vm.prank(owner);
        paymaster.slashOperator(
            operator1,
            ISuperPaymasterV3.SlashLevel.MINOR,
            10 ether,
            "Test slash"
        );
        
        (,,,,, uint256 aPNTsBalance,,,) = paymaster.operators(operator1);
        assertEq(aPNTsBalance, 990 ether);
        
        assertEq(paymaster.getSlashCount(operator1), 1);
    }

    function test_SlashOperator_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.slashOperator(
            operator1,
            ISuperPaymasterV3.SlashLevel.MINOR,
            10 ether,
            "Test"
        );
    }

    // ====================================
    // View Functions Tests
    // ====================================

    function test_GetSlashHistory() public {
        vm.prank(operator1);
        paymaster.deposit(1000 ether);
        
        vm.prank(owner);
        paymaster.slashOperator(
            operator1,
            ISuperPaymasterV3.SlashLevel.MINOR,
            10 ether,
            "First slash"
        );
        
        ISuperPaymasterV3.SlashRecord[] memory history = paymaster.getSlashHistory(operator1);
        assertEq(history.length, 1);
        assertEq(history[0].amount, 10 ether);
    }

    function test_GetSlashCount() public {
        assertEq(paymaster.getSlashCount(operator1), 0);
        
        vm.prank(operator1);
        paymaster.deposit(1000 ether);
        
        vm.prank(owner);
        paymaster.slashOperator(
            operator1,
            ISuperPaymasterV3.SlashLevel.MINOR,
            10 ether,
            "Test"
        );
        
        assertEq(paymaster.getSlashCount(operator1), 1);
    }

    function test_GetLatestSlash() public {
        vm.prank(operator1);
        paymaster.deposit(1000 ether);
        
        vm.prank(owner);
        paymaster.slashOperator(
            operator1,
            ISuperPaymasterV3.SlashLevel.MINOR,
            10 ether,
            "Latest slash"
        );
        
        ISuperPaymasterV3.SlashRecord memory latest = paymaster.getLatestSlash(operator1);
        assertEq(latest.amount, 10 ether);
        assertEq(latest.reason, "Latest slash");
    }

    function test_WithdrawProtocolRevenue_OnlyOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.withdrawProtocolRevenue(treasury, 50 ether);
    }
}
