// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../../../src/paymasters/v4/PaymasterV4_1.sol";
import "../src/MySBT.sol";
import "../src/GasTokenV2.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { ISuperPaymasterRegistry } from "../../../src/interfaces/ISuperPaymasterRegistry.sol";

/**
 * @title PaymasterV4_1Test
 * @notice Unit tests for PaymasterV4_1 - Registry management functionality
 * @dev Tests new Registry-related features while inheriting PaymasterV4 behavior
 */
contract PaymasterV4_1Test is Test {
    PaymasterV4_1 public paymaster;
    MySBT public sbt;
    GasTokenV2 public basePNT;
    GasTokenV2 public aPNT;
    MockRegistry public mockRegistry;

    address public owner;
    address public treasury;
    address public user;
    address public entryPoint;

    // Initial parameters
    uint256 constant INITIAL_GAS_TO_USD_RATE = 4500e18; // $4500/ETH
    uint256 constant INITIAL_PNT_PRICE_USD = 0.02e18; // $0.02/PNT
    uint256 constant INITIAL_SERVICE_FEE_RATE = 200; // 2%
    uint256 constant INITIAL_MAX_GAS_COST_CAP = 1e18; // 1 ETH
    uint256 constant INITIAL_MIN_TOKEN_BALANCE = 1000e18; // 1000 PNT

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        user = address(this);
        entryPoint = makeAddr("entryPoint");

        // Deploy contracts
        vm.startPrank(owner);

        sbt = new MySBT();

        // Deploy paymaster first
        paymaster = new PaymasterV4_1(
            entryPoint,
            owner,
            treasury,
            INITIAL_GAS_TO_USD_RATE,
            INITIAL_PNT_PRICE_USD,
            INITIAL_SERVICE_FEE_RATE,
            INITIAL_MAX_GAS_COST_CAP,
            INITIAL_MIN_TOKEN_BALANCE
        );

        // Deploy GasTokens with paymaster address
        basePNT = new GasTokenV2("Base PNT", "bPNT", address(paymaster), 1e18);
        aPNT = new GasTokenV2("Alpha PNT", "aPNT", address(paymaster), 1e18);

        // Add SBT and GasTokens to paymaster
        paymaster.addSBT(address(sbt));
        paymaster.addGasToken(address(basePNT));
        paymaster.addGasToken(address(aPNT));

        // Deploy mock Registry
        mockRegistry = new MockRegistry();

        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    BASIC FUNCTIONALITY                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Version() public view {
        string memory version = paymaster.version();
        assertEq(version, "PaymasterV4.1-Registry-v1.1.0");
    }

    function test_InitialRegistryNotSet() public view {
        assertFalse(paymaster.isRegistrySet());
        assertEq(address(paymaster.registry()), address(0));
    }

    function test_InitialNotActiveInRegistry() public view {
        assertFalse(paymaster.isActiveInRegistry());
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   REGISTRY CONFIGURATION                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_SetRegistry_Success() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PaymasterV4_1.RegistryUpdated(address(mockRegistry));
        paymaster.setRegistry(address(mockRegistry));

        assertTrue(paymaster.isRegistrySet());
        assertEq(address(paymaster.registry()), address(mockRegistry));
    }

    function test_SetRegistry_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterV4.PaymasterV4__ZeroAddress.selector);
        paymaster.setRegistry(address(0));
    }

    function test_SetRegistry_RevertNonOwner() public {
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.setRegistry(address(mockRegistry));
    }

    function test_SetRegistry_UpdateExisting() public {
        MockRegistry newRegistry = new MockRegistry();

        vm.startPrank(owner);

        // Set first registry
        paymaster.setRegistry(address(mockRegistry));
        assertEq(address(paymaster.registry()), address(mockRegistry));

        // Update to new registry
        vm.expectEmit(true, true, true, true);
        emit PaymasterV4_1.RegistryUpdated(address(newRegistry));
        paymaster.setRegistry(address(newRegistry));

        assertEq(address(paymaster.registry()), address(newRegistry));

        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  DEACTIVATE FUNCTIONALITY                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_DeactivateFromRegistry_Success() public {
        // Setup registry
        vm.prank(owner);
        paymaster.setRegistry(address(mockRegistry));

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

    function test_DeactivateFromRegistry_RevertRegistryNotSet() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterV4_1.PaymasterV4_1__RegistryNotSet.selector);
        paymaster.deactivateFromRegistry();
    }

    function test_DeactivateFromRegistry_RevertNonOwner() public {
        // Setup registry
        vm.prank(owner);
        paymaster.setRegistry(address(mockRegistry));

        // Try to deactivate as non-owner
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert();
        paymaster.deactivateFromRegistry();
    }

    function test_DeactivateFromRegistry_MultipleCallsAllowed() public {
        // Setup registry
        vm.prank(owner);
        paymaster.setRegistry(address(mockRegistry));

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
        vm.prank(owner);
        paymaster.setRegistry(address(mockRegistry));

        mockRegistry.registerPaymaster(address(paymaster));

        assertTrue(paymaster.isActiveInRegistry());
    }

    function test_IsActiveInRegistry_WhenInactive() public {
        vm.prank(owner);
        paymaster.setRegistry(address(mockRegistry));

        mockRegistry.registerPaymaster(address(paymaster));
        mockRegistry.setPaymasterActive(address(paymaster), false);

        assertFalse(paymaster.isActiveInRegistry());
    }

    function test_IsActiveInRegistry_WhenRegistryNotSet() public view {
        assertFalse(paymaster.isActiveInRegistry());
    }

    function test_IsActiveInRegistry_WhenNotRegistered() public {
        vm.prank(owner);
        paymaster.setRegistry(address(mockRegistry));

        // Paymaster not registered
        assertFalse(paymaster.isActiveInRegistry());
    }

    function test_IsActiveInRegistry_WithRevertingRegistry() public {
        RevertingRegistry revertingRegistry = new RevertingRegistry();

        vm.prank(owner);
        paymaster.setRegistry(address(revertingRegistry));

        // Should return false instead of reverting
        assertFalse(paymaster.isActiveInRegistry());
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   INHERITANCE VERIFICATION                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_InheritsPaymasterV4_BasicFunctions() public view {
        // Verify inherited state
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.treasury(), treasury);
        assertEq(paymaster.gasToUSDRate(), INITIAL_GAS_TO_USD_RATE);
        assertEq(paymaster.pntPriceUSD(), INITIAL_PNT_PRICE_USD);
        assertEq(paymaster.serviceFeeRate(), INITIAL_SERVICE_FEE_RATE);
        assertEq(paymaster.maxGasCostCap(), INITIAL_MAX_GAS_COST_CAP);
        assertEq(paymaster.minTokenBalance(), INITIAL_MIN_TOKEN_BALANCE);
        assertFalse(paymaster.paused());
    }

    function test_InheritsPaymasterV4_OwnerFunctions() public {
        uint256 newRate = 5000e18;

        vm.prank(owner);
        paymaster.setGasToUSDRate(newRate);

        assertEq(paymaster.gasToUSDRate(), newRate);
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
 * @notice Registry that always reverts on isPaymasterActive()
 * @dev Used to test try-catch in isActiveInRegistry()
 */
contract RevertingRegistry is ISuperPaymasterRegistry {
    function deactivate() external pure override {
        revert("Always reverts");
    }

    function activate() external pure override {
        revert("Always reverts");
    }

    function isPaymasterActive(address) external pure override returns (bool) {
        revert("Always reverts");
    }

    function getPaymasterInfo(address)
        external
        pure
        override
        returns (uint256, bool, uint256, uint256, string memory)
    {
        revert("Always reverts");
    }

    function getBestPaymaster() external pure override returns (address, uint256) {
        revert("Always reverts");
    }

    function getActivePaymasters() external pure override returns (address[] memory) {
        revert("Always reverts");
    }

    function getRouterStats() external pure override returns (uint256, uint256, uint256, uint256) {
        revert("Always reverts");
    }
}
