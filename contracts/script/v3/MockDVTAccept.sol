// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @title  MockDVTAccept — CC-89 Phase-2 E2E DVTValidator stand-in
/// @notice The E2E aggregator's verifyAndExecute slash-only path calls
///         DVT_VALIDATOR.markProposalExecuted(id). The production DVTValidator gates
///         it on BLS_AGGREGATOR + requires the proposal to pre-exist (createProposal),
///         which our ad-hoc E2E proposalId never had. This no-op stand-in accepts the
///         call so the E2E aggregator can run without touching the production
///         DVTValidator. Testnet E2E only.
contract MockDVTAccept {
    function markProposalExecuted(uint256) external {}
}
