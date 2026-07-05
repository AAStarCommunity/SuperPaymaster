// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";

/// @notice Minimal Registry stub — BLSAggregator only needs it to be a valid
///         non-zero address in the constructor + the two consensus callbacks,
///         which these unit tests never reach (they revert earlier).
contract StubRegistry {
    fallback() external payable {}
}

/// @title  BLSAggregator slash-policy tests (2026-07-04 unified slash design)
/// @notice Covers the three additions that unify the DVT→SP slash consensus:
///         (1) per-severity slash threshold table (floor 2, governance-updatable),
///         (2) executeProposal target allowlist closing the H-1 generic-call hole,
///         (3) evidenceHash binding surface (signature accepts it).
contract BLSAggregator_SlashPolicyTest is Test {
    BLSAggregator bls;
    StubRegistry registry;
    address sp   = address(0x5050);
    address dvt  = address(0xD57);
    address owner = address(0x0BEE);
    address multisig = address(0xACC0);
    address attacker = address(0xBAD);

    function setUp() public {
        registry = new StubRegistry();
        vm.prank(owner);
        bls = new BLSAggregator(address(registry), sp, address(dvt));
    }

    // ---- (1) threshold table defaults + governance update ----

    function test_BootstrapThresholds_Are_2_3_3() public view {
        assertEq(bls.slashThresholds(0), 2, "WARNING");
        assertEq(bls.slashThresholds(1), 3, "MINOR");
        assertEq(bls.slashThresholds(2), 3, "MAJOR");
        assertEq(bls.SLASH_THRESHOLD_FLOOR(), 2);
    }

    function test_PolicyAdmin_CanRaiseThreshold() public {
        // Initial admin is the deployer (owner). Rotate to a multisig first.
        vm.prank(owner);
        bls.setSlashPolicyAdmin(multisig);
        assertEq(bls.slashPolicyAdmin(), multisig);

        // Multisig scales MAJOR up to 7 (e.g. after node set grows).
        vm.prank(multisig);
        bls.setSlashThreshold(2, 7);
        assertEq(bls.slashThresholds(2), 7);
    }

    function test_NonAdmin_CannotUpdateThreshold() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.NotSlashPolicyAdmin.selector, attacker));
        bls.setSlashThreshold(2, 5);
    }

    function test_CannotSetThresholdBelowFloor() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlashThresholdOutOfRange.selector, uint8(1)));
        bls.setSlashThreshold(2, 1); // below floor 2
    }

    function test_CannotSetThresholdAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlashThresholdOutOfRange.selector, uint8(14)));
        bls.setSlashThreshold(2, 14); // above MAX_VALIDATORS (13)
    }

    function test_CannotSetThresholdForInvalidLevel() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "slashLevel"));
        bls.setSlashThreshold(3, 3); // no such SlashLevel
    }

    function test_OnlyOwner_CanRotatePolicyAdmin() public {
        vm.prank(attacker);
        vm.expectRevert();
        bls.setSlashPolicyAdmin(attacker);
    }

    // ---- (2) H-1: executeProposal cannot invoke slash / consensus-marking selectors ----

    /// @notice queueSlash is blocked on the generic path — it has its own dedicated
    ///         quorum-gated entry (queueSlashWithConsensus). Routing it through
    ///         executeProposal would also consume the proposalId, breaking a later
    ///         verifyAndExecute for the same id.
    function test_ExecuteProposal_ForbidsQueueSlashSelector() public {
        bytes memory cd = abi.encodeWithSignature("queueSlash(address)", attacker);
        vm.prank(dvt);
        vm.expectRevert(abi.encodeWithSelector(
            BLSAggregator.ForbiddenGenericSelector.selector, bytes4(keccak256("queueSlash(address)"))));
        bls.executeProposal(1, sp, cd, 2, hex"00");
    }

    // ---- (3) queueSlashWithConsensus: dedicated quorum-gated pre-flag ----

    function test_QueueSlashWithConsensus_OnlyDvtOrOwner() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.UnauthorizedCaller.selector, attacker));
        bls.queueSlashWithConsensus(attacker, 2, 1, hex"00");
    }

    function test_QueueSlashWithConsensus_RejectsInvalidLevel() public {
        vm.prank(dvt);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "slashLevel"));
        bls.queueSlashWithConsensus(attacker, 3, 1, hex"00");
    }

    function test_QueueSlashWithConsensus_RejectsZeroOperator() public {
        vm.prank(dvt);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidTarget.selector, address(0)));
        bls.queueSlashWithConsensus(address(0), 2, 1, hex"00");
    }

    function test_ExecuteProposal_ForbidsExecuteSlashWithBLSSelector() public {
        bytes memory cd = abi.encodeWithSignature("executeSlashWithBLS(address,uint8,bytes)", attacker, uint8(2), hex"");
        vm.prank(dvt);
        vm.expectRevert(abi.encodeWithSelector(
            BLSAggregator.ForbiddenGenericSelector.selector, bytes4(keccak256("executeSlashWithBLS(address,uint8,bytes)"))));
        bls.executeProposal(1, sp, cd, 2, hex"00");
    }

    function test_ExecuteProposal_ForbidsMarkProposalExecutedSelector() public {
        bytes memory cd = abi.encodeWithSignature("markProposalExecuted(uint256)", uint256(7));
        vm.prank(dvt);
        vm.expectRevert(abi.encodeWithSelector(
            BLSAggregator.ForbiddenGenericSelector.selector, bytes4(keccak256("markProposalExecuted(uint256)"))));
        bls.executeProposal(1, address(registry), cd, 2, hex"00");
    }

    /// @notice Non-blocked selectors on a privileged target (e.g. Registry's
    ///         legitimate DVT-consensus blacklist action) are NOT rejected by the
    ///         selector guard — they proceed to threshold verification. Here the
    ///         threshold check (2 < minThreshold 3) is what stops this test call,
    ///         proving the selector guard let it through (no ForbiddenGenericSelector).
    function test_ExecuteProposal_AllowsBlacklistSelector_NotForbidden() public {
        bytes memory cd = abi.encodeWithSignature(
            "updateOperatorBlacklist(address,address[],bool[],bytes)",
            attacker, new address[](0), new bool[](0), hex"");
        vm.prank(dvt);
        // Reverts on the GENERIC floor (2 < minThreshold 3), NOT on the selector guard.
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Threshold below minimum"));
        bls.executeProposal(1, address(registry), cd, 2, hex"00");
    }
}
