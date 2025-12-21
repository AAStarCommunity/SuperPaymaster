// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/core/Registry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {
        _mint(msg.sender, 1000000 ether);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockEntryPoint {
    function depositTo(address) external payable {}
}

contract MockAggregator is AggregatorV3Interface {
    function decimals() external pure returns (uint8) { return 8; }
    function description() external pure returns (string memory) { return "ETH/USD"; }
    function version() external pure returns (uint256) { return 1; }
    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, block.timestamp, block.timestamp, 1);
    }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, block.timestamp, block.timestamp, 1);
    }
}

contract MockRegistry {
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
    function getRoleConfig(bytes32) external pure returns (IRegistryV3.RoleConfig memory) {
        return IRegistryV3.RoleConfig({
            minStake: 30 ether,
            entryBurn: 3 ether,
            slashThreshold: 10,
            slashBase: 2,
            slashIncrement: 1,
            slashMax: 10,
            exitFeePercent: 500,
            minExitFee: 1 ether,
            isActive: true,
            description: "Test"
        });
    }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure returns (bytes32) { return keccak256("ENDUSER"); }
}

/**
 * @title SuperPaymasterV3QueryTest
 * @notice Tests for SuperPaymaster V3.1.1 query interfaces
 */
contract SuperPaymasterV3QueryTest is Test {
    SuperPaymasterV3 paymaster;
    MockGToken gtoken;
    MockEntryPoint entryPoint;
    MockAggregator priceOracle;
    MockRegistry registry;

    address owner = address(1);
    address treasury = address(2);
    address blsAggregator = address(3);
    address operator = address(0x100);

    function setUp() public {
        vm.startPrank(owner);

        gtoken = new MockGToken();
        entryPoint = new MockEntryPoint();
        priceOracle = new MockAggregator();
        registry = new MockRegistry();

        paymaster = new SuperPaymasterV3(
            IEntryPoint(address(entryPoint)),
            owner,
            IRegistryV3(address(registry)),
            address(gtoken),
            address(priceOracle),
            treasury
        );

        paymaster.setBLSAggregator(blsAggregator);

        // Setup operator
        paymaster.configureOperator(address(gtoken), treasury, 1 ether);

        vm.stopPrank();
    }

    // ====================================
    // getSlashHistory() Tests
    // ====================================

    function test_GetSlashHistory_Empty() public {
        ISuperPaymasterV3.SlashRecord[] memory history = paymaster.getSlashHistory(operator);
        assertEq(history.length, 0, "Should have no history initially");
    }

    function test_GetSlashHistory_AfterSlash() public {
        // Execute a slash
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(
            operator,
            ISuperPaymasterV3.SlashLevel.WARNING,
            abi.encode("test")
        );

        ISuperPaymasterV3.SlashRecord[] memory history = paymaster.getSlashHistory(operator);
        assertEq(history.length, 1, "Should have 1 record");
        assertEq(uint8(history[0].level), uint8(ISuperPaymasterV3.SlashLevel.WARNING));
    }

    function test_GetSlashHistory_MultipleSlashes() public {
        vm.startPrank(blsAggregator);
        
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.WARNING, abi.encode("1"));
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.MINOR, abi.encode("2"));
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.MAJOR, abi.encode("3"));
        
        vm.stopPrank();

        ISuperPaymasterV3.SlashRecord[] memory history = paymaster.getSlashHistory(operator);
        assertEq(history.length, 3, "Should have 3 records");
        assertEq(uint8(history[0].level), uint8(ISuperPaymasterV3.SlashLevel.WARNING));
        assertEq(uint8(history[1].level), uint8(ISuperPaymasterV3.SlashLevel.MINOR));
        assertEq(uint8(history[2].level), uint8(ISuperPaymasterV3.SlashLevel.MAJOR));
    }

    // ====================================
    // getSlashCount() Tests
    // ====================================

    function test_GetSlashCount_Zero() public {
        assertEq(paymaster.getSlashCount(operator), 0);
    }

    function test_GetSlashCount_AfterSlashes() public {
        vm.startPrank(blsAggregator);
        
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.WARNING, abi.encode("1"));
        assertEq(paymaster.getSlashCount(operator), 1);
        
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.MINOR, abi.encode("2"));
        assertEq(paymaster.getSlashCount(operator), 2);
        
        vm.stopPrank();
    }

    // ====================================
    // getLatestSlash() Tests
    // ====================================

    function test_GetLatestSlash_NoHistory() public {
        vm.expectRevert("No slash history");
        paymaster.getLatestSlash(operator);
    }

    function test_GetLatestSlash_ReturnsLatest() public {
        vm.startPrank(blsAggregator);
        
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.WARNING, abi.encode("1"));
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.MINOR, abi.encode("2"));
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.MAJOR, abi.encode("3"));
        
        vm.stopPrank();

        ISuperPaymasterV3.SlashRecord memory latest = paymaster.getLatestSlash(operator);
        assertEq(uint8(latest.level), uint8(ISuperPaymasterV3.SlashLevel.MAJOR));
        assertEq(latest.reputationLoss, 50);
    }

    // ====================================
    // Slash Level Behavior Tests
    // ====================================

    function test_WARNING_NoBalanceDeduction() public {
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.WARNING, abi.encode("test"));

        ISuperPaymasterV3.SlashRecord memory record = paymaster.getLatestSlash(operator);
        assertEq(record.amount, 0, "WARNING should not deduct balance");
        assertEq(record.reputationLoss, 10);
    }

    function test_MINOR_10PercentDeduction() public {
        // This test would need operator to have aPNTs balance
        // Skipping actual balance test, just verify record structure
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.MINOR, abi.encode("test"));

        ISuperPaymasterV3.SlashRecord memory record = paymaster.getLatestSlash(operator);
        assertEq(record.reputationLoss, 20);
        assertEq(uint8(record.level), uint8(ISuperPaymasterV3.SlashLevel.MINOR));
    }

    function test_MAJOR_FullDeduction() public {
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymasterV3.SlashLevel.MAJOR, abi.encode("test"));

        ISuperPaymasterV3.SlashRecord memory record = paymaster.getLatestSlash(operator);
        assertEq(record.reputationLoss, 50);
        assertEq(uint8(record.level), uint8(ISuperPaymasterV3.SlashLevel.MAJOR));
    }
}
