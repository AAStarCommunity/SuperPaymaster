// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "src/paymasters/v4/Paymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";

// -----------------------------------------------------------------------
// Shared mocks
// -----------------------------------------------------------------------

contract MockEntryPointFix {
    function depositTo(address) external payable {}
}

contract MockPriceFeedFix {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract MockAPNTsFix is ERC20 {
    constructor() ERC20("AAStar Points", "aPNTs") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockOracleV4 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

// -----------------------------------------------------------------------
// M-4: SuperPaymaster.configureOperator() exchangeRate uint96 overflow
// -----------------------------------------------------------------------

/**
 * @title M4_ExchangeRateOverflowTest
 * @notice configureOperator() must revert when exchangeRate > type(uint96).max.
 */
contract M4_ExchangeRateOverflowTest is Test {
    using stdStorage for StdStorage;

    SuperPaymaster internal paymaster;
    MockXPNTsFactory internal mockFactory;

    address internal constant OWNER     = address(0x1);
    address internal constant TREASURY  = address(0x2);
    address internal constant OPERATOR  = address(0x3);

    bytes32 internal constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 internal constant ROLE_COMMUNITY       = keccak256("COMMUNITY");

    address internal xpntsToken;

    function setUp() public {
        vm.startPrank(OWNER);

        GToken gtoken = new GToken(21_000_000 ether);
        MockEntryPointFix ep = new MockEntryPointFix();
        MockPriceFeedFix feed = new MockPriceFeedFix();
        MockAPNTsFix apnts = new MockAPNTsFix();
        mockFactory = new MockXPNTsFactory();

        Registry registry = UUPSDeployHelper.deployRegistryProxy(OWNER, address(0x999), address(0x888));
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(ep)),
            IRegistry(address(registry)),
            address(feed),
            OWNER,
            address(apnts),
            TREASURY,
            3600
        );

        // Deploy a dummy xPNTs token that the factory will recognise
        xpntsToken = address(new MockAPNTsFix());
        mockFactory.setToken(OPERATOR, xpntsToken);
        paymaster.setXPNTsFactory(address(mockFactory));

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // Grant OPERATOR both required roles via stdstore
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_PAYMASTER_SUPER).with_key(OPERATOR).checked_write(true);
        stdstore.target(address(registry)).sig("hasRole(bytes32,address)")
            .with_key(ROLE_COMMUNITY).with_key(OPERATOR).checked_write(true);

        vm.stopPrank();
    }

    /// @notice exchangeRate > type(uint96).max must revert with ExchangeRateOverflow
    function test_M4_ExchangeRateOverflowReverts() public {
        uint256 overflowRate = uint256(type(uint96).max) + 1;
        vm.prank(OPERATOR);
        vm.expectRevert(SuperPaymaster.ExchangeRateOverflow.selector);
        paymaster.configureOperator(xpntsToken, TREASURY, overflowRate);
    }

    /// @notice exchangeRate == type(uint96).max is the boundary — must succeed
    function test_M4_ExchangeRateAtMaxUint96Succeeds() public {
        uint256 maxRate = uint256(type(uint96).max);
        vm.prank(OPERATOR);
        paymaster.configureOperator(xpntsToken, TREASURY, maxRate);
        uint96 storedRate = _getConfigRate();
        assertEq(storedRate, uint96(maxRate), "rate stored correctly at max boundary");
    }

    function _getConfigRate() internal view returns (uint96 rate) {
        (, uint96 r,,,,,,,, ) = paymaster.operators(OPERATOR);
        rate = r;
    }
}

// -----------------------------------------------------------------------
// M-5: SuperPaymaster.initialize() must reject zero owner
// -----------------------------------------------------------------------

/**
 * @title M5_InitializeZeroOwnerTest
 * @notice initialize() with _owner == address(0) must revert with InvalidOwner().
 */
contract M5_InitializeZeroOwnerTest is Test {
    function test_M5_InitializeRevertsOnZeroOwner() public {
        MockEntryPointFix ep   = new MockEntryPointFix();
        MockPriceFeedFix  feed = new MockPriceFeedFix();
        // Need a real (stub) registry
        Registry regImpl = new Registry();
        bytes memory regInit = abi.encodeCall(Registry.initialize, (address(this), address(0x10), address(0x11)));
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        IRegistry registry = IRegistry(address(regProxy));

        SuperPaymaster impl = new SuperPaymaster(IEntryPoint(address(ep)), registry, address(feed));
        bytes memory initData = abi.encodeCall(
            SuperPaymaster.initialize,
            (address(0), address(0x10), address(0x20), 3600) // owner == address(0)
        );
        vm.expectRevert(SuperPaymaster.InvalidOwner.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_M5_InitializeSucceedsWithValidOwner() public {
        MockEntryPointFix ep   = new MockEntryPointFix();
        MockPriceFeedFix  feed = new MockPriceFeedFix();
        Registry regImpl = new Registry();
        bytes memory regInit = abi.encodeCall(Registry.initialize, (address(this), address(0x10), address(0x11)));
        ERC1967Proxy regProxy = new ERC1967Proxy(address(regImpl), regInit);
        IRegistry registry = IRegistry(address(regProxy));

        SuperPaymaster impl = new SuperPaymaster(IEntryPoint(address(ep)), registry, address(feed));
        bytes memory initData = abi.encodeCall(
            SuperPaymaster.initialize,
            (address(0x42), address(0), address(0x20), 3600) // valid owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        assertEq(SuperPaymaster(payable(address(proxy))).owner(), address(0x42));
    }
}

// -----------------------------------------------------------------------
// M-7: PaymasterFactory.deployPaymaster() requires ROLE_COMMUNITY
// -----------------------------------------------------------------------

contract MockRegistryForFactory is IRegistry {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    function hasRole(bytes32 role, address account) external view returns (bool) { return _roles[role][account]; }
    function setRole(bytes32 role, address account, bool val) external { _roles[role][account] = val; }

    function ROLE_COMMUNITY()       external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER()         external pure returns (bytes32) { return keccak256("ENDUSER"); }
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA()   external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS()             external pure returns (bytes32) { return keccak256("KMS"); }
    function ROLE_DVT()             external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE()           external pure returns (bytes32) { return keccak256("ANODE"); }
    function configureRole(bytes32, RoleConfig calldata) external {}
    function exitRole(bytes32) external {}
    function getRoleConfig(bytes32) external pure returns (RoleConfig memory) {
        return RoleConfig(0,0,0,0,0,0,0,false,0,"",address(0),0);
    }
    function getRoleUserCount(bytes32) external pure returns (uint256) { return 0; }
    function getUserRoles(address) external pure returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external {}
    function safeMintForRole(bytes32, address, bytes calldata) external returns (uint256) { return 0; }
    function setReputationSource(address, bool) external {}
    function markProposalExecuted(uint256) external {}
    function setCreditTier(uint256, uint256) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function getCreditLimit(address) external pure returns (uint256) { return 0; }
    function isReputationSource(address) external pure returns (bool) { return false; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function version() external pure returns (string memory) { return "MockFactoryReg"; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external pure returns (uint256) { return 0; }
}

/**
 * @title M7_PaymasterFactoryRoleCheckTest
 * @notice deployPaymaster() must revert with NotRegisteredCommunity when caller
 *         lacks ROLE_COMMUNITY in the configured Registry.
 */
contract M7_PaymasterFactoryRoleCheckTest is Test {
    PaymasterFactory internal factory;
    MockRegistryForFactory internal reg;

    address internal constant OWNER     = address(0xAA);
    address internal constant COMMUNITY = address(0xBB); // has role
    address internal constant STRANGER  = address(0xCC); // no role
    address internal constant TREASURY  = address(0xDD);

    bytes32 internal constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    /// @dev A real Paymaster implementation for the factory to clone
    address internal paymasterImpl;
    address internal ep;
    address internal oracle;

    function setUp() public {
        vm.startPrank(OWNER);
        factory = new PaymasterFactory();
        reg     = new MockRegistryForFactory();

        // Grant COMMUNITY and PAYMASTER_AOA roles to COMMUNITY address
        // (PAYMASTER_AOA is required so isActiveInRegistry() returns true post-deploy)
        reg.setRole(ROLE_COMMUNITY, COMMUNITY, true);
        reg.setRole(keccak256("PAYMASTER_AOA"), COMMUNITY, true);

        // Wire registry into factory
        factory.setRegistry(address(reg));

        // Deploy a real implementation to register
        ep     = address(new MockEntryPointFix());
        oracle = address(new MockOracleV4());
        Paymaster impl = new Paymaster(address(reg));
        paymasterImpl = address(impl);

        // Register implementation in factory
        factory.addImplementation("v1.0", paymasterImpl);

        vm.stopPrank();
    }

    /// @notice Caller without ROLE_COMMUNITY reverts
    function test_M7_DeployRevertsWithoutCommunityRole() public {
        bytes memory initData = _buildInitData(STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(PaymasterFactory.NotRegisteredCommunity.selector);
        factory.deployPaymaster("v1.0", initData);
    }

    /// @notice Caller with ROLE_COMMUNITY but missing ROLE_PAYMASTER_AOA reverts —
    ///         an immediately-inactive paymaster would be deployed otherwise.
    function test_M7_DeployRevertsWithCommunityButNoAOARole() public {
        address communityNoAoa = address(0xCC2);
        reg.setRole(ROLE_COMMUNITY, communityNoAoa, true);
        // ROLE_PAYMASTER_AOA intentionally NOT granted
        bytes memory initData = _buildInitData(communityNoAoa);
        vm.prank(communityNoAoa);
        vm.expectRevert(PaymasterFactory.NotRegisteredPaymasterAOA.selector);
        factory.deployPaymaster("v1.0", initData);
    }

    /// @notice Caller with ROLE_COMMUNITY deploys successfully
    function test_M7_DeploySucceedsWithCommunityRole() public {
        bytes memory initData = _buildInitData(COMMUNITY);
        vm.prank(COMMUNITY);
        address pm = factory.deployPaymaster("v1.0", initData);
        assertTrue(pm != address(0), "paymaster deployed");
        assertEq(factory.paymasterByOperator(COMMUNITY), pm, "operator to paymaster mapping");
    }

    /// @notice When registry is address(0) (not set), anyone can deploy (backward compat)
    function test_M7_DeploySucceedsWhenNoRegistrySet() public {
        // Deploy a fresh factory with no registry set
        vm.prank(OWNER);
        PaymasterFactory freshFactory = new PaymasterFactory();
        vm.prank(OWNER);
        freshFactory.addImplementation("v1.0", paymasterImpl);
        // registry == address(0) → check is skipped

        bytes memory initData = _buildInitData(STRANGER);
        vm.prank(STRANGER);
        address pm = freshFactory.deployPaymaster("v1.0", initData);
        assertTrue(pm != address(0), "no-registry deploy succeeds");
    }

    /// @notice deterministic deploy also enforces the role check
    function test_M7_DeterministicDeployRevertsWithoutRole() public {
        bytes memory initData = _buildInitData(STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(PaymasterFactory.NotRegisteredCommunity.selector);
        factory.deployPaymasterDeterministic("v1.0", bytes32(uint256(42)), initData);
    }

    function _buildInitData(address operator) internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256,uint256,uint256)",
            ep,
            operator,
            TREASURY,
            oracle,
            100,       // serviceFeeRate (1%)
            1 ether,   // maxGasCostCap
            3600       // staleness
        );
    }
}
