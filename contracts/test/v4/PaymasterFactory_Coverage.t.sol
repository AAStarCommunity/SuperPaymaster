// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";

// =============================================================================
// Shared Mocks
// =============================================================================

/// @dev Minimal IEntryPoint stub satisfying the Paymaster constructor
contract MockEPForFactory is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32) {
        return keccak256(abi.encode(userOp));
    }
    function getNonce(address, uint192) external view returns (uint256) { return 0; }
    function balanceOf(address) external view returns (uint256) { return 0; }
    function incrementNonce(uint192) external {}
    function fail(bytes memory, uint256, uint256) external {}
    function delegateAndRevert(address, bytes calldata) external {}
    function getDepositInfo(address) external view returns (DepositInfo memory info) { return info; }
    function withdrawTo(address payable, uint256) external {}
}

/// @dev Chainlink oracle stub that returns a valid, fresh price
contract MockOracleForFactory {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

/// @dev A minimal Registry stub used by Paymaster.isActiveInRegistry()
contract MockRegistryForFactory {
    bytes32 public constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");
    mapping(bytes32 => mapping(address => bool)) private _roles;

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external {
        _roles[role][account] = true;
    }
}

// =============================================================================
// Test Suite — PaymasterFactory Coverage
// =============================================================================

/**
 * @title PaymasterFactory_CoverageTest
 * @notice Comprehensive coverage tests for PaymasterFactory.sol
 *
 * Coverage targets:
 *  A1 — constructor (owner initialisation)
 *  A2 — deployPaymaster() happy path
 *  A3 — deployPaymaster() failure paths (missing impl, duplicate)
 *  A4 — getPaymasterByOperator / getPaymasterList / getPaymasterCount view helpers
 *  A5 — addImplementation / upgradeImplementation / setDefaultVersion (owner-only)
 *  A6 — deployPaymasterDeterministic + predictPaymasterAddress (CREATE2)
 *  A7 — version(), hasImplementation(), hasPaymaster(), getPaymasterInfo(), getOperatorByPaymaster()
 */
contract PaymasterFactory_CoverageTest is Test {
    using Clones for address;

    PaymasterFactory factory;
    Paymaster impl;           // implementation contract
    Paymaster impl2;          // second implementation for upgrade tests

    MockEPForFactory entryPoint;
    MockOracleForFactory oracle;
    MockRegistryForFactory registry;

    address owner = address(0x1001);
    address operatorA = address(0x2001);
    address operatorB = address(0x2002);
    address nonOwner  = address(0x3001);

    string constant V1 = "v1.0";
    string constant V2 = "v2.0";

    // ------------------------------------------------------------------
    // setUp
    // ------------------------------------------------------------------

    function setUp() public {
        vm.warp(1_700_000_000); // stable timestamp baseline

        entryPoint = new MockEPForFactory();
        oracle     = new MockOracleForFactory();
        registry   = new MockRegistryForFactory();

        // Paymaster implementation requires a non-zero registry in constructor
        impl  = new Paymaster(address(registry));
        impl2 = new Paymaster(address(registry));

        // Deploy factory as owner
        vm.prank(owner);
        factory = new PaymasterFactory();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Build the ABI-encoded initialize call for a Paymaster proxy
    function _initData(address _owner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            Paymaster.initialize.selector,
            address(entryPoint), // _entryPoint
            _owner,              // _owner
            _owner,              // _treasury
            address(oracle),     // _ethUsdPriceFeed
            200,                 // _serviceFeeRate (2%)
            10 ether,            // _maxGasCostCap
            3600                 // _priceStalenessThreshold
        );
    }

    /// @dev Register V1 impl and return the factory (helper for repeated setup)
    function _registerV1() internal {
        vm.prank(owner);
        factory.addImplementation(V1, address(impl));
    }

    // ==========================================================================
    // A1 — Constructor / Initial State
    // ==========================================================================

    function test_A1_Constructor_OwnerIsSet() public view {
        assertEq(factory.owner(), owner, "owner should equal deployer");
    }

    function test_A1_Constructor_DefaultsEmpty() public view {
        assertEq(factory.totalDeployed(), 0);
        assertEq(factory.getPaymasterCount(), 0);
        assertEq(bytes(factory.defaultVersion()).length, 0);
    }

    // ==========================================================================
    // A2 — deployPaymaster() happy path
    // ==========================================================================

    function test_A2_DeployPaymaster_HappyPath() public {
        _registerV1();

        vm.prank(operatorA);
        address paymaster = factory.deployPaymaster(V1, _initData(operatorA));

        // Mappings updated
        assertEq(factory.paymasterByOperator(operatorA), paymaster);
        assertEq(factory.operatorByPaymaster(paymaster), operatorA);
        assertEq(factory.totalDeployed(), 1);
        assertEq(factory.getPaymasterCount(), 1);
        assertTrue(factory.hasPaymaster(operatorA));

        // Proxy owner must be operatorA
        assertEq(Paymaster(payable(paymaster)).owner(), operatorA);
    }

    function test_A2_DeployPaymaster_EmitsEvent() public {
        _registerV1();

        vm.expectEmit(true, false, false, true);
        emit PaymasterFactory.PaymasterDeployed(operatorA, address(0), V1, block.timestamp);

        vm.prank(operatorA);
        factory.deployPaymaster(V1, _initData(operatorA));
    }

    function test_A2_DeployPaymaster_MultipleOperators() public {
        _registerV1();

        vm.prank(operatorA);
        address pmA = factory.deployPaymaster(V1, _initData(operatorA));

        vm.prank(operatorB);
        address pmB = factory.deployPaymaster(V1, _initData(operatorB));

        assertEq(factory.totalDeployed(), 2);
        assertEq(factory.getPaymasterCount(), 2);
        assertTrue(pmA != pmB, "each operator gets a distinct proxy");
    }

    // ==========================================================================
    // A3 — deployPaymaster() failure paths
    // ==========================================================================

    function test_A3_DeployPaymaster_RevertIf_ImplementationNotFound() public {
        // No impl registered
        vm.prank(operatorA);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.ImplementationNotFound.selector, V1)
        );
        factory.deployPaymaster(V1, _initData(operatorA));
    }

    function test_A3_DeployPaymaster_RevertIf_DuplicateOperator() public {
        _registerV1();

        vm.prank(operatorA);
        factory.deployPaymaster(V1, _initData(operatorA));

        vm.prank(operatorA);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.OperatorAlreadyHasPaymaster.selector, operatorA)
        );
        factory.deployPaymaster(V1, _initData(operatorA));
    }

    function test_A3_DeployPaymaster_RevertIf_InitDataTooShort() public {
        _registerV1();

        vm.prank(operatorA);
        vm.expectRevert(PaymasterFactory.InvalidInitData.selector);
        factory.deployPaymaster(V1, hex"aabbcc"); // only 3 bytes — < 4 selector bytes
    }

    function test_A3_DeployPaymaster_RevertIf_InitFails() public {
        _registerV1();

        // Call a non-existent function selector → proxy call reverts (no matching function),
        // which triggers InitFailed(returnData). We catch any InitFailed revert regardless of
        // the returnData payload by checking the 4-byte selector prefix.
        bytes memory badData = abi.encodeWithSignature("nonExistentFunction()");

        vm.prank(operatorA);
        // InitFailed is: error InitFailed(bytes returnData)
        // We cannot predict the returnData, so match only on the 4-byte selector.
        bytes4 selector = PaymasterFactory.InitFailed.selector;
        vm.expectRevert(abi.encodeWithSelector(selector, hex""));
        factory.deployPaymaster(V1, badData);
    }

    function test_A3_DeployPaymaster_RevertIf_OwnerMismatch() public {
        _registerV1();

        // Initialize with operatorB as owner but caller is operatorA → OwnerMismatch
        vm.prank(operatorA);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.OwnerMismatch.selector, operatorA, operatorB)
        );
        factory.deployPaymaster(V1, _initData(operatorB));
    }

    // ==========================================================================
    // A4 — View helpers: getPaymasterByOperator / getPaymasterList / getPaymasterCount
    // ==========================================================================

    function test_A4_GetPaymasterByOperator_ReturnsZeroIfNone() public view {
        assertEq(factory.getPaymasterByOperator(operatorA), address(0));
    }

    function test_A4_GetPaymasterList_EmptyWhenNoneDeployed() public view {
        address[] memory list = factory.getPaymasterList(0, 10);
        assertEq(list.length, 0);
    }

    function test_A4_GetPaymasterList_Pagination() public {
        _registerV1();
        address[3] memory ops = [operatorA, operatorB, address(0x2003)];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(ops[i]);
            factory.deployPaymaster(V1, _initData(ops[i]));
        }
        assertEq(factory.getPaymasterCount(), 3);

        // First page of 2
        address[] memory page1 = factory.getPaymasterList(0, 2);
        assertEq(page1.length, 2);

        // Second page of 2 (only 1 remaining)
        address[] memory page2 = factory.getPaymasterList(2, 2);
        assertEq(page2.length, 1);

        // Offset past end → empty
        address[] memory beyond = factory.getPaymasterList(10, 5);
        assertEq(beyond.length, 0);
    }

    function test_A4_GetPaymasterCount_IncrementsOnDeploy() public {
        _registerV1();
        assertEq(factory.getPaymasterCount(), 0);

        vm.prank(operatorA);
        factory.deployPaymaster(V1, _initData(operatorA));
        assertEq(factory.getPaymasterCount(), 1);

        vm.prank(operatorB);
        factory.deployPaymaster(V1, _initData(operatorB));
        assertEq(factory.getPaymasterCount(), 2);
    }

    // ==========================================================================
    // A5 — Admin functions: addImplementation / upgradeImplementation / setDefaultVersion
    // ==========================================================================

    function test_A5_AddImplementation_HappyPath() public {
        _registerV1(); // sets defaultVersion to V1 (first impl)

        assertEq(factory.implementations(V1), address(impl));
        assertEq(factory.defaultVersion(), V1);
        assertTrue(factory.hasImplementation(V1));
    }

    function test_A5_AddImplementation_RevertIf_NonOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.addImplementation(V1, address(impl));
    }

    function test_A5_AddImplementation_RevertIf_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.InvalidImplementation.selector, address(0))
        );
        factory.addImplementation(V1, address(0));
    }

    function test_A5_AddImplementation_RevertIf_NoCode() public {
        address eoa = address(0xDEAD);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.InvalidImplementation.selector, eoa)
        );
        factory.addImplementation(V1, eoa);
    }

    function test_A5_AddImplementation_RevertIf_VersionAlreadyExists() public {
        _registerV1();

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.VersionAlreadyExists.selector, V1)
        );
        factory.addImplementation(V1, address(impl2));
    }

    function test_A5_AddSecondVersion_DoesNotChangeDefault() public {
        _registerV1();

        vm.prank(owner);
        factory.addImplementation(V2, address(impl2));

        // Default should still be V1 (first registered)
        assertEq(factory.defaultVersion(), V1);
        assertTrue(factory.hasImplementation(V2));
    }

    function test_A5_UpgradeImplementation_HappyPath() public {
        _registerV1();

        vm.expectEmit(true, true, true, false);
        emit PaymasterFactory.ImplementationUpgraded(V1, address(impl), address(impl2));

        vm.prank(owner);
        factory.upgradeImplementation(V1, address(impl2));

        assertEq(factory.implementations(V1), address(impl2));
    }

    function test_A5_UpgradeImplementation_RevertIf_NonOwner() public {
        _registerV1();
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.upgradeImplementation(V1, address(impl2));
    }

    function test_A5_UpgradeImplementation_RevertIf_VersionNotFound() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.ImplementationNotFound.selector, V1)
        );
        factory.upgradeImplementation(V1, address(impl2));
    }

    function test_A5_SetDefaultVersion_HappyPath() public {
        _registerV1();
        vm.prank(owner);
        factory.addImplementation(V2, address(impl2));

        vm.expectEmit(false, false, false, true);
        emit PaymasterFactory.DefaultVersionChanged(V1, V2);

        vm.prank(owner);
        factory.setDefaultVersion(V2);

        assertEq(factory.defaultVersion(), V2);
    }

    function test_A5_SetDefaultVersion_RevertIf_NonOwner() public {
        _registerV1();
        vm.prank(nonOwner);
        vm.expectRevert();
        factory.setDefaultVersion(V1);
    }

    function test_A5_SetDefaultVersion_RevertIf_NotFound() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.ImplementationNotFound.selector, "v99")
        );
        factory.setDefaultVersion("v99");
    }

    function test_A5_GetImplementation_RevertIf_NotFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.ImplementationNotFound.selector, V1)
        );
        factory.getImplementation(V1);
    }

    function test_A5_GetImplementation_HappyPath() public {
        _registerV1();
        assertEq(factory.getImplementation(V1), address(impl));
    }

    // ==========================================================================
    // A6 — deployPaymasterDeterministic + predictPaymasterAddress (CREATE2)
    // ==========================================================================

    function test_A6_PredictAddress_MatchesActualDeployment() public {
        _registerV1();

        bytes32 salt = keccak256("operator-a-salt");

        // Predict before deployment
        address predicted = factory.predictPaymasterAddress(V1, salt);

        vm.prank(operatorA);
        address actual = factory.deployPaymasterDeterministic(V1, salt, _initData(operatorA));

        assertEq(predicted, actual, "predicted address must match actual deployment");
    }

    function test_A6_DeterministicDeploy_MappingsUpdated() public {
        _registerV1();
        bytes32 salt = bytes32(uint256(42));

        vm.prank(operatorA);
        address paymaster = factory.deployPaymasterDeterministic(V1, salt, _initData(operatorA));

        assertEq(factory.paymasterByOperator(operatorA), paymaster);
        assertEq(factory.operatorByPaymaster(paymaster), operatorA);
        assertEq(factory.totalDeployed(), 1);
    }

    function test_A6_DeterministicDeploy_RevertIf_DuplicateOperator() public {
        _registerV1();
        bytes32 salt1 = bytes32(uint256(1));
        bytes32 salt2 = bytes32(uint256(2));

        vm.prank(operatorA);
        factory.deployPaymasterDeterministic(V1, salt1, _initData(operatorA));

        vm.prank(operatorA);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.OperatorAlreadyHasPaymaster.selector, operatorA)
        );
        factory.deployPaymasterDeterministic(V1, salt2, _initData(operatorA));
    }

    function test_A6_DeterministicDeploy_RevertIf_ImplNotFound() public {
        bytes32 salt = bytes32(uint256(99));

        vm.prank(operatorA);
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.ImplementationNotFound.selector, V1)
        );
        factory.deployPaymasterDeterministic(V1, salt, _initData(operatorA));
    }

    function test_A6_PredictAddress_RevertIf_ImplNotFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.ImplementationNotFound.selector, V1)
        );
        factory.predictPaymasterAddress(V1, bytes32(uint256(1)));
    }

    // ==========================================================================
    // A7 — Miscellaneous view helpers and edge-cases
    // ==========================================================================

    function test_A7_Version() public view {
        assertEq(factory.version(), "PaymasterFactory-1.0.2");
    }

    function test_A7_HasImplementation_FalseWhenEmpty() public view {
        assertFalse(factory.hasImplementation(V1));
    }

    function test_A7_HasPaymaster_FalseWhenNotDeployed() public view {
        assertFalse(factory.hasPaymaster(operatorA));
    }

    function test_A7_GetPaymasterInfo_ValidPaymaster() public {
        _registerV1();

        vm.prank(operatorA);
        address pm = factory.deployPaymaster(V1, _initData(operatorA));

        (address op, bool valid) = factory.getPaymasterInfo(pm);
        assertEq(op, operatorA);
        assertTrue(valid);
    }

    function test_A7_GetPaymasterInfo_InvalidPaymaster() public view {
        (address op, bool valid) = factory.getPaymasterInfo(address(0xDEAD));
        assertEq(op, address(0));
        assertFalse(valid);
    }

    function test_A7_GetOperatorByPaymaster_RevertIf_NotFound() public {
        vm.expectRevert(
            abi.encodeWithSelector(PaymasterFactory.PaymasterNotFound.selector, address(0xBAD))
        );
        factory.getOperatorByPaymaster(address(0xBAD));
    }

    function test_A7_GetOperatorByPaymaster_HappyPath() public {
        _registerV1();

        vm.prank(operatorA);
        address pm = factory.deployPaymaster(V1, _initData(operatorA));

        assertEq(factory.getOperatorByPaymaster(pm), operatorA);
    }

    // ==========================================================================
    // Additional edge-case: paymasterList public array accessor
    // ==========================================================================

    function test_PaymasterListPublicAccessor() public {
        _registerV1();

        vm.prank(operatorA);
        address pm = factory.deployPaymaster(V1, _initData(operatorA));

        assertEq(factory.paymasterList(0), pm);
    }

    // ==========================================================================
    // Fuzz: deploy with arbitrary (but unique) operators
    // ==========================================================================

    function testFuzz_DeployPaymaster_UniqueOperators(address op1, address op2) public {
        vm.assume(op1 != address(0) && op2 != address(0) && op1 != op2);
        vm.assume(op1 != address(this) && op2 != address(this));
        vm.assume(op1 != address(entryPoint) && op2 != address(entryPoint));
        vm.assume(op1 != address(oracle) && op2 != address(oracle));
        vm.assume(op1 != address(registry) && op2 != address(registry));
        vm.assume(op1 != address(impl) && op2 != address(impl));
        vm.assume(op1 != address(factory) && op2 != address(factory));

        _registerV1();

        vm.prank(op1);
        address pm1 = factory.deployPaymaster(V1, _initData(op1));

        vm.prank(op2);
        address pm2 = factory.deployPaymaster(V1, _initData(op2));

        assertEq(factory.totalDeployed(), 2);
        assertTrue(pm1 != pm2);
        assertEq(factory.paymasterByOperator(op1), pm1);
        assertEq(factory.paymasterByOperator(op2), pm2);
    }
}
