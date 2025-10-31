// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../src/paymasters/v4/PaymasterV4_1.sol";
import "./mocks/MockSBT.sol";
import "../../src/paymasters/v2/tokens/xPNTsToken.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { ISuperPaymasterRegistry } from "../../src/interfaces/ISuperPaymasterRegistry.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title PaymasterV4_1Test
 * @notice Unit tests for PaymasterV4_1 - Registry management functionality
 * @dev Tests new Registry-related features while inheriting PaymasterV4 behavior
 */
contract PaymasterV4_1Test is Test {
    PaymasterV4_1 public paymaster;
    MockSBT public sbt;
    xPNTsToken public basePNT;
    xPNTsToken public aPNT;
    MockRegistry public mockRegistry;
    MockChainlinkPriceFeed public ethUsdPriceFeed;

    address public owner;
    address public treasury;
    address public user;
    address public entryPoint;

    // Initial parameters
    uint256 constant INITIAL_SERVICE_FEE_RATE = 200; // 2%
    uint256 constant INITIAL_MAX_GAS_COST_CAP = 1e18; // 1 ETH
    uint256 constant INITIAL_PNT_PRICE_USD = 0.02e18; // $0.02/PNT

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        user = address(this);
        entryPoint = makeAddr("entryPoint");

        // Deploy contracts
        vm.startPrank(owner);

        sbt = new MockSBT();
        mockRegistry = new MockRegistry();

        // Deploy Chainlink price feed mock (ETH/USD = $4500)
        ethUsdPriceFeed = new MockChainlinkPriceFeed(8, 4500e8); // 8 decimals, $4500

        // Deploy mock xPNTsFactory (temporary address for testing)
        address mockXPNTsFactory = makeAddr("mockXPNTsFactory");

        // Deploy paymaster first
        paymaster = new PaymasterV4_1(
            entryPoint,
            owner,
            treasury,
            address(ethUsdPriceFeed),  // Chainlink ETH/USD price feed
            INITIAL_SERVICE_FEE_RATE,
            INITIAL_MAX_GAS_COST_CAP,
            mockXPNTsFactory,          // xPNTs Factory (for aPNTs price)
            address(sbt),              // Initial SBT
            address(0),                // Initial GasToken (will be added later)
            address(mockRegistry)      // Registry (immutable)
        );

        // Deploy xPNTs tokens for testing
        // basePNT: base community token, exchangeRate = 1e18 (1:1 with aPNT)
        basePNT = new xPNTsToken("Base PNT", "bPNT", owner, "Base Community", "base.eth", 1e18);
        // aPNT: alpha community token, exchangeRate = 1e18 (1:1 with aPNT)
        aPNT = new xPNTsToken("Alpha PNT", "aPNT", owner, "Alpha Community", "alpha.eth", 1e18);

        // Add paymaster as auto-approved spender (replaces GasTokenV2's _update hook)
        basePNT.addAutoApprovedSpender(address(paymaster));
        aPNT.addAutoApprovedSpender(address(paymaster));

        // Add GasTokens to paymaster (SBT already added in constructor)
        paymaster.addGasToken(address(basePNT));
        paymaster.addGasToken(address(aPNT));

        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    BASIC FUNCTIONALITY                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Version() public view {
        string memory version = paymaster.version();
        assertEq(version, "PaymasterV4.1-Registry-v1.1.0");
    }

    function test_InitialRegistrySet() public view {
        assertTrue(paymaster.isRegistrySet());
        assertEq(address(paymaster.registry()), address(mockRegistry));
    }

    function test_InitialNotActiveInRegistry() public view {
        // Not registered yet, so not active
        assertFalse(paymaster.isActiveInRegistry());
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  DEACTIVATE FUNCTIONALITY                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_DeactivateFromRegistry_Success() public {
        // Register paymaster in mock registry
        mockRegistry.registerPaymaster(address(paymaster));
        assertTrue(mockRegistry.isPaymasterActive(address(paymaster)));

        // Deactivate
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PaymasterV4_1.DeactivatedFromRegistry(address(paymaster));
        paymaster.deactivateFromRegistry();

        // Verify deactivated
        assertFalse(mockRegistry.isPaymasterActive(address(paymaster)));
        assertFalse(paymaster.isActiveInRegistry());
    }

    function test_DeactivateFromRegistry_RevertNonOwner() public {
        // Try to deactivate as non-owner
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.deactivateFromRegistry();
    }

    function test_DeactivateFromRegistry_MultipleCallsAllowed() public {
        mockRegistry.registerPaymaster(address(paymaster));

        // Deactivate twice
        vm.startPrank(owner);
        paymaster.deactivateFromRegistry();
        assertFalse(paymaster.isActiveInRegistry());

        // Second deactivate should succeed (idempotent)
        paymaster.deactivateFromRegistry();
        assertFalse(paymaster.isActiveInRegistry());
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      VIEW FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_IsActiveInRegistry_WhenActive() public {
        mockRegistry.registerPaymaster(address(paymaster));
        assertTrue(paymaster.isActiveInRegistry());
    }

    function test_IsActiveInRegistry_WhenInactive() public {
        mockRegistry.registerPaymaster(address(paymaster));
        mockRegistry.setPaymasterActive(address(paymaster), false);
        assertFalse(paymaster.isActiveInRegistry());
    }

    function test_IsActiveInRegistry_WhenNotRegistered() public view {
        // Paymaster not registered
        assertFalse(paymaster.isActiveInRegistry());
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   INHERITANCE VERIFICATION                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_InheritsPaymasterV4_BasicFunctions() public view {
        // Verify inherited state
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.treasury(), treasury);
        assertEq(address(paymaster.ethUsdPriceFeed()), address(ethUsdPriceFeed));
        assertEq(paymaster.serviceFeeRate(), INITIAL_SERVICE_FEE_RATE);
        assertEq(paymaster.maxGasCostCap(), INITIAL_MAX_GAS_COST_CAP);
        assertFalse(paymaster.paused());
    }

    // Helper to implement ERC721Receiver
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       MOCK CONTRACTS                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @notice Mock Registry for testing
 * @dev Simplified implementation of ISuperPaymasterRegistry
 */
contract MockRegistry is ISuperPaymasterRegistry {
    struct PaymasterInfo {
        bool isRegistered;
        bool isActive;
        uint256 feeRate;
        string name;
    }

    mapping(address => PaymasterInfo) public paymasters;

    function registerPaymaster(address paymaster) external {
        paymasters[paymaster] = PaymasterInfo({
            isRegistered: true,
            isActive: true,
            feeRate: 200,
            name: "Test Paymaster"
        });
    }

    function setPaymasterActive(address paymaster, bool active) external {
        paymasters[paymaster].isActive = active;
    }

    function deactivate() external override {
        require(paymasters[msg.sender].isRegistered, "Not registered");
        paymasters[msg.sender].isActive = false;
    }

    function activate() external override {
        require(paymasters[msg.sender].isRegistered, "Not registered");
        paymasters[msg.sender].isActive = true;
    }

    function isPaymasterActive(address paymaster) external view override returns (bool) {
        return paymasters[paymaster].isRegistered && paymasters[paymaster].isActive;
    }

    function getPaymasterInfo(address paymaster)
        external
        view
        override
        returns (uint256 feeRate, bool isActive, uint256 successCount, uint256 totalAttempts, string memory name)
    {
        PaymasterInfo memory info = paymasters[paymaster];
        return (info.feeRate, info.isActive, 0, 0, info.name);
    }

    function getBestPaymaster() external pure override returns (address paymaster, uint256 feeRate) {
        return (address(0), 0);
    }

    function getActivePaymasters() external pure override returns (address[] memory activePaymasters) {
        return new address[](0);
    }

    function getRouterStats()
        external
        pure
        override
        returns (uint256 totalPaymasters, uint256 activePaymasters, uint256 totalSuccessfulRoutes, uint256 totalRoutes)
    {
        return (0, 0, 0, 0);
    }
}

/**
 * @notice Mock Chainlink Price Feed for testing
 * @dev Simplified implementation of AggregatorV3Interface
 */
contract MockChainlinkPriceFeed is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _price;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 initialPrice) {
        _decimals = decimals_;
        _price = initialPrice;
        _updatedAt = block.timestamp;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock ETH/USD Price Feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80)
        external
        pure
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        revert("Not implemented");
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _price, block.timestamp, _updatedAt, 1);
    }

    // Helper function for testing: update price
    function updatePrice(int256 newPrice) external {
        _price = newPrice;
        _updatedAt = block.timestamp;
    }

    // Helper function for testing: set stale data
    function setStale(uint256 timestamp) external {
        _updatedAt = timestamp;
    }
}
