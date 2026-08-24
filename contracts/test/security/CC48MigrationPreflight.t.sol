// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {BLSKeyScanLib} from "../../script/checks/BLSKeyScanLib.sol";

/// @notice The 4.3.0/4.1.0 shape, reduced to what the capability probe looks at: the
///         key-table surface exists, the guardian-slash surface does not, and there is
///         NO fallback — so every guardian-slash selector reverts, exactly as it does
///         on the aggregators deployed on Sepolia today.
contract LegacySurfaceStub {
    function MAX_VALIDATORS() external pure returns (uint256) {
        return 13;
    }

    function validatorAtSlot(uint8) external pure returns (address) {
        return address(0);
    }

    function version() external pure returns (string memory) {
        return "BLSAggregator-4.3.0";
    }
}

/// @notice A 4.7.0+ shape: `pendingGuardianSlashCount` answers, so nothing is skipped.
contract ModernSurfaceStub {
    mapping(address => uint256) public pendingGuardianSlashCount;

    function setPending(address guardian, uint256 n) external {
        pendingGuardianSlashCount[guardian] = n;
    }

    function MAX_VALIDATORS() external pure returns (uint256) {
        return 2;
    }

    function validatorAtSlot(uint8 slot) external pure returns (address) {
        return slot == 1 ? address(0xA11CE) : address(0);
    }

    function version() external pure returns (string memory) {
        return "BLSAggregator-4.9.0";
    }
}

/// @notice The shape the probe must REFUSE to classify: a catch-all fallback answers
///         every probe with empty returndata, so "the selector is missing" and "the
///         contract swallowed my call" become indistinguishable. Silence must never be
///         read as "this contract cannot hold a guardian-slash case".
contract FallbackAggregatorStub {
    fallback() external {}
}

/// @notice A HALF-migrated shape: `guardianSlashCases` exists, `pendingGuardianSlashCount`
///         does not. Nothing real should look like this, which is exactly why the
///         preflight must stop instead of guessing.
contract PartialGuardianSurfaceStub {
    function guardianSlashCases(uint256)
        external
        pure
        returns (bytes32, bytes32, uint64, uint8, uint16, uint16, address)
    {
        return (bytes32(0), bytes32(0), 0, 0, 0, 0, address(0));
    }

    function version() external pure returns (string memory) {
        return "BLSAggregator-4.5.0-frankenstein";
    }
}

contract RegistryWiringStub {
    address public blsAggregator;

    function setBLSAggregator(address a) external {
        blsAggregator = a;
    }
}

/**
 * @title CC48MigrationPreflight
 * @notice CC-48 round-5 HIGH-1. Two gates that were, respectively, un-runnable and
 *         unenforced:
 *
 *           1. `requireNoPendingCases` called a selector that does not exist on ANY
 *              aggregator deployed today, so pointing the migration at the real
 *              predecessor reverted the whole preflight — and the only way to make the
 *              script run (`OLD_BLS_AGGREGATOR=0`) ALSO skipped
 *              `requireNoTaintedKeyCarriedOver`, the sole on-chain gate stopping the
 *              experiment stack's publicly-known keys from being re-onboarded.
 *
 *           2. `OLD_BLS_AGGREGATOR` was required but never checked, so 0 doubled as both
 *              "there is no predecessor" and "make the preflight be quiet".
 *
 *         These tests run under Cancun on purpose: the capability probe and the
 *         predecessor binding are pure ABI/staticcall properties with no BLS in them, so
 *         they must not be reachable only through the Prague-gated suite (which is how
 *         the legacy shape went uncovered in the first place). The end-to-end
 *         legacy-predecessor regression, which needs the real weak-key scan, lives in
 *         `contracts/test/paper7/CC48KeyScanPreflight.t.sol`.
 */
contract CC48MigrationPreflight is Test {
    // =================================================================
    // Capability probe
    // =================================================================

    /// The legacy shape is classified from its ABI surface alone — no version string is
    /// trusted, no allow-list is consulted.
    function test_LegacyShapeIsProvablyIncapableOfHoldingACase() public {
        LegacySurfaceStub legacy = new LegacySurfaceStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(legacy))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Absent)
        );
        // ...and the pending check steps aside instead of reverting on a missing selector.
        this.callRequireNoPendingCases(address(legacy));
    }

    /// A predecessor that HAS the feature is scanned in full — the skip is proven per
    /// contract, not granted to everything that predates a version number.
    function test_ModernShapeIsScannedNotSkipped() public {
        ModernSurfaceStub modern = new ModernSurfaceStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(modern))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Present)
        );
        this.callRequireNoPendingCases(address(modern)); // clean today

        modern.setPending(address(0xA11CE), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PendingCaseOnOldAggregator.selector,
                address(modern),
                address(0xA11CE),
                uint256(1)
            )
        );
        this.callRequireNoPendingCases(address(modern));
    }

    /// The failure mode a naive "selector missing ⇒ feature absent" probe would have:
    /// a contract with a catch-all fallback answers everything with empty returndata and
    /// would be waved through as "cannot hold a case".
    function test_AFallbackContractIsAmbiguousNotAbsent() public {
        FallbackAggregatorStub swallower = new FallbackAggregatorStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(swallower))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.AmbiguousGuardianSlashCapability.selector, address(swallower)
            )
        );
        this.callRequireNoPendingCases(address(swallower));
    }

    /// A partial guardian-slash surface is an unrecognised build. Stop, do not guess.
    function test_APartialGuardianSurfaceIsAmbiguous() public {
        PartialGuardianSurfaceStub partialStub = new PartialGuardianSurfaceStub();
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(partialStub))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.AmbiguousGuardianSlashCapability.selector, address(partialStub)
            )
        );
        this.callRequireNoPendingCases(address(partialStub));
    }

    /// An address with no code at all cannot be reasoned about either.
    function test_AnEmptyAddressIsAmbiguous() public view {
        assertEq(
            uint256(BLSKeyScanLib.guardianSlashCapability(address(0xDEAD))),
            uint256(BLSKeyScanLib.GuardianSlashCapability.Ambiguous)
        );
    }

    // =================================================================
    // Predecessor binding: OLD_BLS_AGGREGATOR must match the live wiring
    // =================================================================

    /// THE round-5 HIGH-1 bypass, closed: on a Registry that already has an aggregator
    /// wired, declaring "first-ever deployment" is rejected. That declaration was the
    /// one operation that switched the tainted-key gate off while printing a line that
    /// read like a normal, successful path.
    function test_DeclaringFirstEverOnALiveRegistryIsRejected() public {
        RegistryWiringStub registry = new RegistryWiringStub();
        registry.setBLSAggregator(address(0x174b60bB));

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PredecessorMismatch.selector,
                address(registry),
                address(0),
                address(0x174b60bB)
            )
        );
        this.callRequireDeclaredPredecessor(address(registry), address(0));
    }

    /// A stale or typo'd predecessor scans the WRONG contract for tainted keys and
    /// reports clean. Caught for the same reason and by the same check.
    function test_DeclaringTheWrongPredecessorIsRejected() public {
        RegistryWiringStub registry = new RegistryWiringStub();
        registry.setBLSAggregator(address(0x174b60bB));

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PredecessorMismatch.selector,
                address(registry),
                address(0xF51c0298),
                address(0x174b60bB)
            )
        );
        this.callRequireDeclaredPredecessor(address(registry), address(0xF51c0298));
    }

    /// The honest declaration passes, and returns the wiring it verified against.
    function test_TheLivePredecessorIsAccepted() public {
        RegistryWiringStub registry = new RegistryWiringStub();
        registry.setBLSAggregator(address(0x174b60bB));
        assertEq(
            BLSKeyScanLib.requireDeclaredPredecessor(address(registry), address(0x174b60bB)),
            address(0x174b60bB)
        );
    }

    /// A genuine first-ever deployment still works — but only because the live Registry
    /// says so, not because the operator typed 0.
    function test_FirstEverIsAcceptedOnlyWhenRegistryHasNoAggregatorWired() public {
        RegistryWiringStub registry = new RegistryWiringStub();
        assertEq(BLSKeyScanLib.requireDeclaredPredecessor(address(registry), address(0)), address(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSKeyScanLib.PredecessorMismatch.selector,
                address(registry),
                address(0xBEEF),
                address(0)
            )
        );
        this.callRequireDeclaredPredecessor(address(registry), address(0xBEEF));
    }

    // =================================================================
    // External wrappers — `vm.expectRevert` needs a real CALL boundary for a
    // library's internal function to revert across.
    // =================================================================

    function callRequireNoPendingCases(address agg) external view {
        BLSKeyScanLib.requireNoPendingCases(agg);
    }

    function callRequireDeclaredPredecessor(address registry, address declared) external view {
        BLSKeyScanLib.requireDeclaredPredecessor(registry, declared);
    }
}
