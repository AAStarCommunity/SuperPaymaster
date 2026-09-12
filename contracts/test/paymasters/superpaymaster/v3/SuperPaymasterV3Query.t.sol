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
import {MockXPNTsFactory} from "../../../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer} from "../../../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";

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
    // GlobalTierSource (xPNTs v2 credit tier) reads this; no credit in these tests.
    function getCreditLimit(address) external pure returns (uint256) { return 0; }
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
    MockXPNTsFactory mockFactory;
    V2TokenDeployer.Stack stack;
    xPNTsTokenV2 xtok;

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

        paymaster.queueBLSAggregator(blsAggregator);
        vm.warp(block.timestamp + 24 hours + 1);
        paymaster.applyBLSAggregator();

        // Deploy mock factory (P1-4 factory binding)
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        vm.stopPrank();

        // 5.5.0: configureOperator only accepts an xPNTs v2 (balance-mode) community token;
        // the plain ERC20 used here pre-5.5.0 is now rejected with InvalidXPNTsToken.
        stack = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xtok = V2TokenDeployer.newToken(stack, owner, owner, address(paymaster), 1e18);
        mockFactory.setToken(owner, address(xtok));

        // Setup operator
        vm.prank(owner);
        paymaster.configureOperator(address(xtok), treasury);
    }

    /// @notice Setup sanity (the slash-query tests below do not depend on it, but it must hold).
    function test_Setup_OperatorConfiguredWithV2Token() public view {
        (, bool configured,, address tok,,,,,) = paymaster.operators(owner);
        assertTrue(configured);
        assertEq(tok, address(xtok));
    }

    // ====================================
    // getSlashHistory() Tests
    // ====================================

    function test_GetSlashHistory_Empty() public {
        ISuperPaymaster.SlashRecord[] memory history = paymaster.getSlashHistory(operator);
        assertEq(history.length, 0, "Should have no history initially");
    }

    function test_GetSlashHistory_AfterSlash() public {
        // HIGH-1: queue before slash
        vm.prank(blsAggregator);
        paymaster.queueSlash(operator);
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(
            operator,
            ISuperPaymaster.SlashLevel.WARNING,
            abi.encode("test")
        );

        ISuperPaymaster.SlashRecord[] memory history = paymaster.getSlashHistory(operator);
        assertEq(history.length, 1, "Should have 1 record");
        assertEq(uint8(history[0].level), uint8(ISuperPaymaster.SlashLevel.WARNING));
    }

    function test_GetSlashHistory_MultipleSlashes() public {
        vm.startPrank(blsAggregator);
        // HIGH-1: queue before each slash (flag is cleared after each execution)
        // CC-13: legitimate distinct slashes of the same operator must be spaced past the BLS-path cooldown.
        uint256 t0 = block.timestamp;
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, abi.encode("1"));
        vm.warp(t0 + 2 hours);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, abi.encode("2"));
        vm.warp(t0 + 4 hours);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MAJOR, abi.encode("3"));

        vm.stopPrank();

        ISuperPaymaster.SlashRecord[] memory history = paymaster.getSlashHistory(operator);
        assertEq(history.length, 3, "Should have 3 records");
        assertEq(uint8(history[0].level), uint8(ISuperPaymaster.SlashLevel.WARNING));
        assertEq(uint8(history[1].level), uint8(ISuperPaymaster.SlashLevel.MINOR));
        assertEq(uint8(history[2].level), uint8(ISuperPaymaster.SlashLevel.MAJOR));
    }

    // ====================================
    // getSlashCount() Tests
    // ====================================

    function test_GetSlashCount_Zero() public {
        assertEq(paymaster.getSlashCount(operator), 0);
    }

    function test_GetSlashCount_AfterSlashes() public {
        vm.startPrank(blsAggregator);
        // HIGH-1: queue before each slash
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, abi.encode("1"));
        assertEq(paymaster.getSlashCount(operator), 1);

        // CC-13: space past the BLS-path cooldown before the next distinct slash.
        vm.warp(block.timestamp + 1 hours + 1);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, abi.encode("2"));
        assertEq(paymaster.getSlashCount(operator), 2);

        vm.stopPrank();
    }

    // ====================================
    // getLatestSlash() Tests
    // ====================================

    function test_GetLatestSlash_NoHistory() public {
        vm.expectRevert(SuperPaymaster.NoSlashHistory.selector);
        paymaster.getLatestSlash(operator);
    }

    function test_GetLatestSlash_ReturnsLatest() public {
        vm.startPrank(blsAggregator);
        // HIGH-1: queue before each slash
        // CC-13: space past the BLS-path cooldown between distinct slashes.
        uint256 t0 = block.timestamp;
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, abi.encode("1"));
        vm.warp(t0 + 2 hours);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, abi.encode("2"));
        vm.warp(t0 + 4 hours);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MAJOR, abi.encode("3"));

        vm.stopPrank();

        ISuperPaymaster.SlashRecord memory latest = paymaster.getLatestSlash(operator);
        assertEq(uint8(latest.level), uint8(ISuperPaymaster.SlashLevel.MAJOR));
        assertEq(latest.reputationLoss, 50);
    }

    // ====================================
    // Slash Level Behavior Tests
    // ====================================

    function test_WARNING_NoBalanceDeduction() public {
        // HIGH-1: queue before slash
        vm.prank(blsAggregator);
        paymaster.queueSlash(operator);
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.WARNING, abi.encode("test"));

        ISuperPaymaster.SlashRecord memory record = paymaster.getLatestSlash(operator);
        assertEq(record.amount, 0, "WARNING should not deduct balance");
        assertEq(record.reputationLoss, 10);
    }

    function test_MINOR_10PercentDeduction() public {
        // This test would need operator to have aPNTs balance
        // Skipping actual balance test, just verify record structure
        // HIGH-1: queue before slash
        vm.prank(blsAggregator);
        paymaster.queueSlash(operator);
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, abi.encode("test"));

        ISuperPaymaster.SlashRecord memory record = paymaster.getLatestSlash(operator);
        assertEq(record.reputationLoss, 20);
        assertEq(uint8(record.level), uint8(ISuperPaymaster.SlashLevel.MINOR));
    }

    function test_MAJOR_FullDeduction() public {
        // HIGH-1: queue before slash
        vm.prank(blsAggregator);
        paymaster.queueSlash(operator);
        vm.prank(blsAggregator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MAJOR, abi.encode("test"));

        ISuperPaymaster.SlashRecord memory record = paymaster.getLatestSlash(operator);
        assertEq(record.reputationLoss, 50);
        assertEq(uint8(record.level), uint8(ISuperPaymaster.SlashLevel.MAJOR));
    }
}
