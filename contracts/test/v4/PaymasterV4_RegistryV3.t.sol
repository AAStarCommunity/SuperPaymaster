// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/interfaces/v3/IRegistry.sol";

/// @notice P0-5 (B5-H1 + reviewer CRITICAL): two bugs fixed together.
///
///   Bug 1 (original P0-5): deactivateFromRegistry called V2 `deactivate()`
///   which no longer exists on V3 Registry → every call reverted.
///
///   Bug 2 (reviewer CRITICAL): the replacement called exitRole(ROLE_PAYMASTER_AOA)
///   from address(this), but the role is held by the operator EOA/multisig
///   (owner()), not the contract itself → still always reverted.
///
///   Final fix (user decision): deactivate = listing notification only.
///   ROLE_PAYMASTER_AOA stays on the operator EOA so the operator can re-
///   activate later. paused=true is the authoritative "not accepting UserOps"
///   signal. isActiveInRegistry() requires BOTH !paused AND hasRole(owner).
///   activateInRegistry() re-lists the paymaster without any exitRole.
///   Registry stores zero new state — the AOA discovery listing is derived
///   from existing state: operator role + paymaster paused flag.

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

/// @notice Mock registry that records calls and lets tests configure role state.
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

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event DeactivatedFromRegistry(address indexed paymaster);
    event ActivatedInRegistry(address indexed paymaster);

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

    // ── deactivateFromRegistry ───────────────────────────────────────────────

    function test_Deactivate_PausesContractAndEmits() public {
        assertFalse(paymaster.paused());

        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        vm.expectEmit(true, false, false, false);
        emit DeactivatedFromRegistry(address(paymaster));

        vm.prank(owner);
        paymaster.deactivateFromRegistry();

        assertTrue(paymaster.paused(), "contract must be paused after deactivate");
    }

    function test_Deactivate_Idempotent() public {
        vm.startPrank(owner);
        paymaster.deactivateFromRegistry();
        assertTrue(paymaster.paused());
        // Second call must not revert and must not emit extra events.
        paymaster.deactivateFromRegistry();
        assertTrue(paymaster.paused(), "still paused after double deactivate");
        vm.stopPrank();
    }

    function test_Deactivate_DoesNotCallExitRole() public {
        // The contract must NOT call registry.exitRole — that would revert
        // because address(paymaster) does not hold the role. Verify by
        // checking lastExitedBy is still zero after the call.
        vm.prank(owner);
        paymaster.deactivateFromRegistry();

        assertEq(registry.lastExitedBy(), address(0),
            "deactivateFromRegistry must not call registry.exitRole");
    }

    function test_Deactivate_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        paymaster.deactivateFromRegistry();
    }

    // ── isActiveInRegistry — queries !paused AND hasRole(owner) ────────────

    function test_IsActive_TrueWhenOwnerHoldsRoleAndNotPaused() public {
        registry.setRole(owner, registry.ROLE_PAYMASTER_AOA(), true);
        assertFalse(paymaster.paused());
        assertTrue(paymaster.isActiveInRegistry());
    }

    function test_IsActive_FalseWhenOwnerLacksRole() public {
        // No role assigned → false even if not paused.
        assertFalse(paymaster.isActiveInRegistry());
    }

    function test_IsActive_FalseWhenContractHoldsRole() public {
        // Role on address(paymaster) — the old (wrong) holder — must NOT affect
        // the view; correct holder is owner().
        registry.setRole(address(paymaster), registry.ROLE_PAYMASTER_AOA(), true);
        assertFalse(paymaster.isActiveInRegistry(),
            "contract-address role must not influence isActiveInRegistry");
    }

    function test_IsActive_FalseWhenPaused() public {
        // Operator has role but paymaster is paused → not in active listing.
        registry.setRole(owner, registry.ROLE_PAYMASTER_AOA(), true);
        vm.prank(owner);
        paymaster.deactivateFromRegistry();
        assertFalse(paymaster.isActiveInRegistry(),
            "isActiveInRegistry must be false when paused, even if owner has role");
    }

    function test_IsActive_FalseAfterOwnerExitsRole() public {
        // Simulate operator calling registry.exitRole from their EOA (full exit,
        // not just a listing pause). isActiveInRegistry must reflect role loss.
        registry.setRole(owner, registry.ROLE_PAYMASTER_AOA(), true);
        assertTrue(paymaster.isActiveInRegistry());

        bytes32 role = registry.ROLE_PAYMASTER_AOA();
        vm.prank(owner);
        registry.exitRole(role);

        assertFalse(paymaster.isActiveInRegistry(),
            "isActiveInRegistry must be false after owner exits the role");
    }

    // ── activateInRegistry — re-list after deactivate ───────────────────────

    function test_Activate_EmitsAndUnpauses() public {
        registry.setRole(owner, registry.ROLE_PAYMASTER_AOA(), true);
        vm.prank(owner);
        paymaster.deactivateFromRegistry();
        assertTrue(paymaster.paused());
        assertFalse(paymaster.isActiveInRegistry());

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);
        vm.expectEmit(true, false, false, false);
        emit ActivatedInRegistry(address(paymaster));

        vm.prank(owner);
        paymaster.activateInRegistry();

        assertFalse(paymaster.paused(), "must be unpaused after activate");
        assertTrue(paymaster.isActiveInRegistry(), "must be active again after activate");
    }

    function test_Activate_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        paymaster.activateInRegistry();
    }

    function test_Activate_Idempotent() public {
        // Already not paused — calling activate again must not revert.
        assertFalse(paymaster.paused());
        vm.prank(owner);
        paymaster.activateInRegistry();
        assertFalse(paymaster.paused(), "still active after redundant activate");
    }

    /// @dev Note: after P0-6 (fix/p0-6-v4-pause) merges, PaymasterBase will gain
    ///      pause()/unpause() that operate the same paused flag. deactivateFromRegistry
    ///      and activateInRegistry should then delegate to those rather than setting
    ///      paused directly, to avoid 4 functions for 2 operations.
    function test_Activate_RoleStaysOnEOA() public {
        // Core design invariant: deactivate/activate cycle must NOT touch the
        // registry role — ROLE_PAYMASTER_AOA remains on the operator EOA.
        registry.setRole(owner, registry.ROLE_PAYMASTER_AOA(), true);

        vm.prank(owner);
        paymaster.deactivateFromRegistry();
        // Role still present on EOA after deactivate.
        assertTrue(registry.roleHolders(owner, registry.ROLE_PAYMASTER_AOA()),
            "deactivate must not remove ROLE_PAYMASTER_AOA from operator EOA");

        vm.prank(owner);
        paymaster.activateInRegistry();
        // Role still present after re-activate.
        assertTrue(registry.roleHolders(owner, registry.ROLE_PAYMASTER_AOA()),
            "activate must not modify ROLE_PAYMASTER_AOA");
    }
}
