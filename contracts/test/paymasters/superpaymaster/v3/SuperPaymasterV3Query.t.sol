// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "src/interfaces/v3/IRegistry.sol";
import {UUPSDeployHelper} from "../../../helpers/UUPSDeployHelper.sol";

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
    function getRoleConfig(bytes32) external pure returns (IRegistry.RoleConfig memory) {
        return IRegistry.RoleConfig({
            minStake: 0,
            ticketPrice: 0,
            slashThreshold: 0,
            slashBase: 0,
            slashInc: 0,
            slashMax: 0,
            exitFeePercent: 0,
            isActive: false,
            minExitFee: 0,
            description: "stub",
            owner: address(0),
            roleLockDuration: 0
        });
    }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_ENDUSER() external pure returns (bytes32) { return keccak256("ENDUSER"); }
}

/**
 * @title SuperPaymasterQueryTest
 * @notice Tests for SuperPaymaster V3.1.1 query interfaces
 */
contract SuperPaymasterQueryTest is Test {
    SuperPaymaster paymaster;
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

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceOracle),
            owner,
            address(gtoken),
            treasury,
            3600
        );

        paymaster.setBLSAggregator(blsAggregator);

        // Setup operator
        paymaster.configureOperator(address(gtoken), treasury, 1 ether);

        vm.stopPrank();
    }

    // ====================================
    // getSlashHistory() — REMOVED from ABI.
    // Use OperatorSlashed events (The Graph / eth_getLogs) off-chain.
    // Individual records accessible via slashHistory(operator, index).
    // ====================================

    function test_SlashHistory_EmptyInitially() public {
        assertEq(paymaster.getSlashCount(operator), 0, "no history initially");
    }

    function test_SlashHistory_AfterSlash_CountAndRecord() public {
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, abi.encode("test"));

        assertEq(paymaster.getSlashCount(operator), 1);
        ISuperPaymaster.SlashRecord memory r = paymaster.getSlashRecord(operator, 0);
        assertEq(uint8(r.level), uint8(ISuperPaymaster.SlashLevel.WARNING));
    }

    function test_SlashHistory_MultipleSlashes_CountAndOrder() public {
        vm.startPrank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, abi.encode("1"));
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR,   abi.encode("2"));
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MAJOR,   abi.encode("3"));
        vm.stopPrank();

        assertEq(paymaster.getSlashCount(operator), 3);
        ISuperPaymaster.SlashRecord memory r0 = paymaster.getSlashRecord(operator, 0);
        ISuperPaymaster.SlashRecord memory r1 = paymaster.getSlashRecord(operator, 1);
        ISuperPaymaster.SlashRecord memory r2 = paymaster.getSlashRecord(operator, 2);
        assertEq(uint8(r0.level), uint8(ISuperPaymaster.SlashLevel.WARNING));
        assertEq(uint8(r1.level), uint8(ISuperPaymaster.SlashLevel.MINOR));
        assertEq(uint8(r2.level), uint8(ISuperPaymaster.SlashLevel.MAJOR));
    }

    // ====================================
    // getSlashCount() Tests
    // ====================================

    function test_GetSlashCount_Zero() public {
        assertEq(paymaster.getSlashCount(operator), 0);
    }

    function test_GetSlashCount_AfterSlashes() public {
        vm.startPrank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, abi.encode("1"));
        assertEq(paymaster.getSlashCount(operator), 1);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, abi.encode("2"));
        assertEq(paymaster.getSlashCount(operator), 2);
        vm.stopPrank();
    }

    // ====================================
    // getLatestSlash() — REMOVED from ABI.
    // Read last record via slashHistory(operator, getSlashCount(operator) - 1).
    // ====================================

    function test_LatestSlash_ViaIndexAccess() public {
        vm.startPrank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, abi.encode("1"));
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR,   abi.encode("2"));
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MAJOR,   abi.encode("3"));
        vm.stopPrank();

        uint256 count = paymaster.getSlashCount(operator);
        ISuperPaymaster.SlashRecord memory latest = paymaster.getSlashRecord(operator, count - 1);
        assertEq(uint8(latest.level), uint8(ISuperPaymaster.SlashLevel.MAJOR));
        assertEq(latest.reputationLoss, 50);
    }

    // ====================================
    // Slash Level Behavior Tests
    // ====================================

    function test_WARNING_NoBalanceDeduction() public {
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, abi.encode("test"));

        ISuperPaymaster.SlashRecord memory record = paymaster.getSlashRecord(operator, 0);
        assertEq(record.amount, 0, "WARNING should not deduct balance");
        assertEq(record.reputationLoss, 10);
    }

    function test_MINOR_10PercentDeduction() public {
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, abi.encode("test"));

        ISuperPaymaster.SlashRecord memory record = paymaster.getSlashRecord(operator, 0);
        assertEq(record.reputationLoss, 20);
        assertEq(uint8(record.level), uint8(ISuperPaymaster.SlashLevel.MINOR));
    }

    function test_MAJOR_FullDeduction() public {
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MAJOR, abi.encode("test"));

        ISuperPaymaster.SlashRecord memory record = paymaster.getSlashRecord(operator, 0);
        assertEq(record.reputationLoss, 50);
        assertEq(uint8(record.level), uint8(ISuperPaymaster.SlashLevel.MAJOR));
    }
}
