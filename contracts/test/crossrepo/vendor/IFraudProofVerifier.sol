// VENDORED — DO NOT EDIT. (8 header lines; strip them to recover the vendored body.) Copy of the merged DVT source, for cross-repo conformance.
//   repo   : AAStarCommunity/YetAnotherAA-Validator
//   path   : contracts/src/interfaces/IFraudProofVerifier.sol
//   commit : 8395c94c (PR #240, CC-115 B1, merged 2026-08-29T11:31:43Z)
//   sha256 : 4d96d411af30e4d384232f48743f0b31f70e1bb3afd16af5e64f16a4421dbe65   <- of the UPSTREAM file, before the deviation noted below
// Deviations from upstream: NONE. Not even the pragma — upstream's ^0.8.19 is
// satisfied by SP's 0.8.33 compiler, so unlike DVT's vendoring of SP's conformance
// fixture this copy needed no widening.
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

/**
 * @title IFraudProofVerifier
 * @notice The seam BLSAggregator.queueGuardianSlash (SuperPaymaster BLSAggregator ≥ 4.7.0, ABI
 *         frozen through 4.11.0) plugs into. SP trusts only an owner-set verifier and never judges
 *         fraud itself: it slashes the addresses in `guiltyGuardians` iff `verify(...)` returns true.
 *         Correctness of "are these guardians truly guilty" is entirely the verifier's job (CC-89 A').
 *
 * @dev    CC-115 B1 — 4-parameter, DOMAIN-BOUND ABI. The selector is
 *         `verify(bytes32,uint256,address[],bytes)` == 0x61077735 (unchanged since SP 4.7.0; the
 *         4.9.0 bump is the aggregator's own ABI, not this seam's). SP invokes it as
 *
 *             verify(fraudProofDigest(fraudProofId, guiltyGuardians), fraudProofId,
 *                    guiltyGuardians, fraudProof)
 *
 *         where `fraudProofDigest` binds (DOMAIN_NAME, block.chainid, aggregator, Registry) via the
 *         BLS-consensus domain separator plus the fraud-proof path tag, `fraudProofId` and
 *         `guiltyGuardians`. A conformant verifier MUST bind `domainDigest` INTO its accept/reject
 *         decision (recompute the canonical digest and require byte equality) — merely accepting the
 *         argument and ignoring it re-opens, from the DVT side, exactly the cross-contract / cross-chain
 *         / cross-Registry replay the aggregator's domain separation closed. A comment is not a gate;
 *         SP's `FraudProofVerifierConformance` fixture is.
 *
 * @dev    `view` — the fraud proof must reduce to on-chain-checkable facts (see
 *         docs/design/guardian-collusion-slash.md §4b). MUST fail-closed: any malformed input,
 *         wrong domain, missing/mismatched signer-set commitment, non-canonical accusation, or
 *         unproven fraud returns `false` (never revert on a rejected proof — a revert would let the
 *         caller distinguish rejection reasons and grief the permissionless entry).
 */
interface IFraudProofVerifier {
    /// @param domainDigest    SP's canonical `fraudProofDigest(fraudProofId, guiltyGuardians)` — the
    ///                        anti-replay domain separator binding (chainId, aggregator, Registry) +
    ///                        the fraud-proof path tag + (fraudProofId, guiltyGuardians). The verifier
    ///                        MUST recompute this from its own bound (aggregator, Registry) and reject
    ///                        any mismatch, so a proof valid in one (chain, aggregator, Registry)
    ///                        context cannot be replayed in another.
    /// @param fraudProofId    Replay-guard key (SP-side, per (proof,guardian)); the verifier binds it
    ///                        to the disputed content so a valid proof can't be filed under an unrelated id.
    /// @param guiltyGuardians Addresses the caller wants slashed — the verifier MUST prove the accused
    ///                        set is EXACTLY the committed signer set (see OverIssueFraudProofVerifier),
    ///                        so a caller cannot shrink the blame to a subset and permanently burn the id.
    /// @param fraudProof      Opaque proof bytes, decoded and interpreted solely by the verifier.
    /// @return ok             true iff the slash of `guiltyGuardians` is proven fraudulent-collusion.
    function verify(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view returns (bool ok);
}
