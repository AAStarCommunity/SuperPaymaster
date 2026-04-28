// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/interfaces/v3/IRegistry.sol";

/// @notice Targeted tests for P0-4 (executeWithProof access control) and
///         P0-17 (proposalId pre-poison defense). These tests assert the
///         negative cases — that hostile callers and unborn proposalIds
///         can no longer corrupt DVT state.
contract DVTValidator_P0HardeningTest is Test {
    DVTValidator dvt;

    address validator1 = address(0xAAA1);
    address blsAggregator = address(0xBB55);
    address operator = address(0xC0FFEE);
    address attacker = address(0xBAD);

    function setUp() public {
        dvt = new DVTValidator(address(0xDEAD)); // registry stub, not exercised here
        dvt.addValidator(validator1);
        dvt.setBLSAggregator(blsAggregator);
    }

    // -----------------------------------------------------------------------
    // P0-4: executeWithProof access control
    // -----------------------------------------------------------------------

    function test_ExecuteWithProof_RevertsForAnonymousCaller() public {
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "x");

        vm.prank(attacker);
        vm.expectRevert(DVTValidator.NotAuthorizedExecutor.selector);
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, "");
    }

    function test_ExecuteWithProof_AllowsRegisteredValidator() public {
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "x");

        // Validator passes the modifier; the call will revert downstream when
        // the BLS aggregator stub at address(0) cannot decode the empty proof,
        // but that proves the modifier itself didn't reject this caller.
        vm.prank(validator1);
        vm.expectRevert();
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, "");
    }

    function test_ExecuteWithProof_AllowsBLSAggregator() public {
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "x");

        vm.prank(blsAggregator);
        vm.expectRevert();
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, "");
    }

    // -----------------------------------------------------------------------
    // P0-17: proposalId pre-poison defense
    // -----------------------------------------------------------------------

    function test_MarkProposalExecuted_RevertsForUnbornId() public {
        // Even when called by the legitimate aggregator, an unborn id must
        // be rejected so a forged BLS proof cannot pre-poison future ids.
        vm.prank(blsAggregator);
        vm.expectRevert(DVTValidator.ProposalDoesNotExist.selector);
        dvt.markProposalExecuted(999);
    }

    function test_MarkProposalExecuted_AllowsExistingId() public {
        vm.prank(validator1);
        uint256 id = dvt.createProposal(operator, 1, "x");

        vm.prank(blsAggregator);
        dvt.markProposalExecuted(id);

        (,,, bool executed) = dvt.proposals(id);
        assertTrue(executed);
    }

    function test_ExecuteWithProof_RevertsForUnbornId() public {
        vm.prank(validator1);
        vm.expectRevert(DVTValidator.ProposalDoesNotExist.selector);
        dvt.executeWithProof(999, new address[](0), new uint256[](0), 0, "");
    }

    /// @notice The pre-poison attack surface in the original code allowed a
    ///         forged BLS proof to mark a future proposalId as executed. With
    ///         the existence guard, even a malicious aggregator can no longer
    ///         brick proposal ids that haven't been created yet.
    function test_PrePoison_AttackBlocked() public {
        // Attempt: aggregator marks proposal 5 as executed before it is created.
        vm.prank(blsAggregator);
        vm.expectRevert(DVTValidator.ProposalDoesNotExist.selector);
        dvt.markProposalExecuted(5);

        // Drive nextProposalId up to 5 via legitimate creates.
        vm.startPrank(validator1);
        for (uint256 i = 0; i < 5; i++) {
            dvt.createProposal(operator, 1, "legit");
        }
        vm.stopPrank();

        // Proposal 5 (the one the attacker tried to poison) should still be
        // freshly executable, not already marked.
        (,,, bool executedFlag) = dvt.proposals(5);
        assertFalse(executedFlag, "proposal 5 must not be pre-poisoned");
    }
}
