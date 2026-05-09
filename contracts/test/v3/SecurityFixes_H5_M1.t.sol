// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "src/paymasters/v4/Paymaster.sol";

// ============================================================
// Shared mocks (reused by both H-5 and M-1 test contracts)
// ============================================================

/// @dev Minimal IRegistry mock for MySBT
contract MockRegistrySF is IRegistry {
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external pure returns (bytes32) { return keccak256("KMS"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    mapping(bytes32 => mapping(address => bool)) private _roles;
    function hasRole(bytes32 role, address account) external view returns (bool) { return _roles[role][account]; }
    function setRole(bytes32 role, address account, bool val) external { _roles[role][account] = val; }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure returns (bytes32) { return keccak256("ENDUSER"); }
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
    function version() external pure returns (string memory) { return "MockV3"; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external pure returns (uint256) { return 0; }
}

contract MockEntryPointSF {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract MockOracleSF {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

// ============================================================
// H-5: PaymasterBase.initialize() must reject maxGasCostCap==0
// ============================================================

/**
 * @title H5_GasCostCapZeroTest
 * @notice Verify PaymasterBase._initializePaymasterBase reverts on maxGasCostCap == 0.
 */
contract H5_GasCostCapZeroTest is Test {
    Paymaster internal paymaster;
    MockEntryPointSF internal ep;
    MockOracleSF internal oracle;
    MockRegistrySF internal reg;

    address internal constant OWNER    = address(0xAA);
    address internal constant TREASURY = address(0xBB);

    function setUp() public {
        ep     = new MockEntryPointSF();
        oracle = new MockOracleSF();
        reg    = new MockRegistrySF();

        Paymaster impl = new Paymaster(address(reg));
        paymaster = Paymaster(payable(Clones.clone(address(impl))));
    }

    /// @notice initialize() with maxGasCostCap == 0 must revert
    function test_H5_InitializeRevertsOnZeroGasCostCap() public {
        vm.expectRevert(PaymasterBase.Paymaster__InvalidGasCostCap.selector);
        paymaster.initialize(
            address(ep),
            OWNER,
            TREASURY,
            address(oracle),
            100,       // serviceFeeRate
            0,         // <-- maxGasCostCap == 0  (must revert)
            3600
        );
    }

    /// @notice initialize() with maxGasCostCap > 100 ether must also revert
    function test_H5_InitializeRevertsOnExcessiveGasCostCap() public {
        vm.expectRevert(PaymasterBase.Paymaster__InvalidGasCostCap.selector);
        paymaster.initialize(
            address(ep),
            OWNER,
            TREASURY,
            address(oracle),
            100,
            101 ether, // <-- > 100 ether
            3600
        );
    }

    /// @notice Valid cap (1 ether) initializes successfully
    function test_H5_ValidGasCostCapSucceeds() public {
        paymaster.initialize(
            address(ep),
            OWNER,
            TREASURY,
            address(oracle),
            100,
            1 ether,  // valid
            3600
        );
        assertEq(paymaster.maxGasCostCap(), 1 ether);
    }
}

// ============================================================
// M-1: MySBT.recordActivity() must reject inactive memberships
// ============================================================

/**
 * @title M1_RecordActivityInactiveTest
 * @notice Verify MySBT.recordActivity() reverts when membership is deactivated.
 */
contract M1_RecordActivityInactiveTest is Test {
    MySBT internal mysbt;
    GToken internal gtoken;
    MockRegistrySF internal mockReg;

    address internal constant ADMIN    = address(0x1);
    address internal constant STAKING  = address(0x3);
    address internal constant COMMUNITY = address(0x4);
    address internal constant USER      = address(0x6);

    bytes32 internal constant ROLE_ENDUSER   = keccak256("ENDUSER");
    bytes32 internal constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(ADMIN);
        gtoken  = new GToken(21_000_000 ether);
        mockReg = new MockRegistrySF();
        mysbt   = new MySBT(address(gtoken), STAKING, address(mockReg), ADMIN);

        // Register community in registry
        mockReg.setRole(ROLE_COMMUNITY, COMMUNITY, true);
        vm.stopPrank();

        // Mint SBT for USER via Registry (impersonate registry)
        bytes memory roleData = abi.encode(COMMUNITY, "");
        vm.prank(address(mockReg));
        mysbt.mintForRole(USER, ROLE_ENDUSER, roleData);
    }

    /// @notice recordActivity succeeds when membership is active
    function test_M1_RecordActivitySucceedsWhenActive() public {
        vm.prank(COMMUNITY);
        mysbt.recordActivity(USER); // should not revert
    }

    /// @notice recordActivity reverts after membership is deactivated
    function test_M1_RecordActivityRevertsWhenInactive() public {
        // Deactivate USER's membership in COMMUNITY
        vm.prank(address(mockReg)); // only registry can call deactivateMembership
        mysbt.deactivateMembership(USER, COMMUNITY);

        // Now recordActivity must revert
        vm.expectRevert(MySBT.InactiveMembership.selector);
        vm.prank(COMMUNITY);
        mysbt.recordActivity(USER);
    }

    /// @notice After reactivation, recordActivity succeeds again
    function test_M1_RecordActivitySucceedsAfterReactivation() public {
        // Deactivate
        vm.prank(address(mockReg));
        mysbt.deactivateMembership(USER, COMMUNITY);

        // Reactivate via mintForRole (re-join path)
        bytes memory roleData = abi.encode(COMMUNITY, "");
        vm.prank(address(mockReg));
        mysbt.mintForRole(USER, ROLE_ENDUSER, roleData); // reactivates if inactive

        // Now activity should succeed
        vm.prank(COMMUNITY);
        mysbt.recordActivity(USER);
    }
}
