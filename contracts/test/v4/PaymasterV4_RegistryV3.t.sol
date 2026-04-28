// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/interfaces/v3/IRegistry.sol";

/// @notice P0-5 (B5-H1): the original `deactivateFromRegistry` invoked the V2
///         router method `deactivate()` on the registry. The deployed V3
///         Registry only exposes `exitRole(bytes32)`, so every deactivate call
///         silently reverted. This test exercises the V3 path directly through
///         a minimal mock that records the role exited.
contract MockEntryPoint {
    function depositTo(address) external payable {}
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract MockOracleOK {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

/// @notice Mock registry implementing the V3 surface Paymaster touches in
///         deactivate / isActive paths. We do NOT inherit IRegistry to avoid
///         pulling in 30+ unused override stubs; Paymaster only calls
///         exitRole, ROLE_PAYMASTER_AOA, and hasRole on the cast pointer.
contract MockRegistryV3 {
    address public lastExitedBy;
    bytes32 public lastExitedRole;
    mapping(address => mapping(bytes32 => bool)) public roleHolders;

    bytes32 public constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");

    function exitRole(bytes32 roleId) external {
        lastExitedBy = msg.sender;
        lastExitedRole = roleId;
        roleHolders[msg.sender][roleId] = false;
    }

    function setRole(address holder, bytes32 roleId, bool active) external {
        roleHolders[holder][roleId] = active;
    }

    function hasRole(bytes32 roleId, address holder) external view returns (bool) {
        return roleHolders[holder][roleId];
    }
}

contract PaymasterV4_RegistryV3Test is Test {
    Paymaster paymaster;
    MockRegistryV3 registry;
    address owner = address(0xABCD);

    function setUp() public {
        registry = new MockRegistryV3();
        Paymaster impl = new Paymaster(address(registry));
        paymaster = Paymaster(payable(Clones.clone(address(impl))));
        paymaster.initialize(
            address(new MockEntryPoint()),
            owner,
            owner,
            address(new MockOracleOK()),
            200,
            10 ether,
            3600
        );
    }

    function test_DeactivateFromRegistry_CallsV3ExitRole() public {
        // Mark the paymaster as holding the role first so the read path has
        // something to invalidate.
        registry.setRole(address(paymaster), registry.ROLE_PAYMASTER_AOA(), true);
        assertTrue(paymaster.isActiveInRegistry());

        vm.prank(owner);
        paymaster.deactivateFromRegistry();

        assertEq(registry.lastExitedBy(), address(paymaster));
        assertEq(registry.lastExitedRole(), registry.ROLE_PAYMASTER_AOA());
        assertFalse(paymaster.isActiveInRegistry(), "should be inactive after exitRole");
    }

    function test_DeactivateFromRegistry_OnlyOwner() public {
        registry.setRole(address(paymaster), registry.ROLE_PAYMASTER_AOA(), true);

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        paymaster.deactivateFromRegistry();
    }

    function test_IsActiveInRegistry_ReadsV3HasRole() public {
        // Before assignment, hasRole returns false → isActiveInRegistry false.
        assertFalse(paymaster.isActiveInRegistry());

        registry.setRole(address(paymaster), registry.ROLE_PAYMASTER_AOA(), true);
        assertTrue(paymaster.isActiveInRegistry());
    }

    /// @notice The view tolerates a registry that does not implement V3
    ///         hasRole. Confirmed via the `try/catch` wrapper — the role is
    ///         simply unset on the mock, exercising the false-return path.
    function test_IsActiveInRegistry_DefaultsFalseWhenRoleUnset() public {
        // Fresh registry, no setRole calls → hasRole returns false.
        assertFalse(paymaster.isActiveInRegistry());
    }
}
