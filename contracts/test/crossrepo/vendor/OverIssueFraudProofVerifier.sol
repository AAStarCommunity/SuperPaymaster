// VENDORED — DO NOT EDIT. (11 header lines; strip them to recover the vendored body.) Copy of the merged DVT source, for cross-repo conformance.
//   repo   : AAStarCommunity/YetAnotherAA-Validator
//   path   : contracts/src/verifiers/OverIssueFraudProofVerifier.sol
//   commit : 8395c94c (PR #240, CC-115 B1, merged 2026-08-29T11:31:43Z)
//   sha256 : 6616d5a70af6bd4dedd1982d5874376c014430cdad8af1e0e461bdb120af33ec   <- of the UPSTREAM file, before the deviation noted below
// Deviations from upstream: EXACTLY ONE, the import path on the line below, rewritten
//   from: import {IFraudProofVerifier} from "../interfaces/IFraudProofVerifier.sol";
//   to:   import {IFraudProofVerifier} from "./IFraudProofVerifier.sol";
// because both files live side by side here rather than in src/interfaces + src/verifiers.
// Nothing else changed — not the pragma (^0.8.19 is satisfied by SP's 0.8.33), not a
// comment, not a byte of logic.
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import {IFraudProofVerifier} from "./IFraudProofVerifier.sol";

/// @dev The BLSAggregator's A' commitment getter (SuperPaymaster PR #371).
interface IBLSAggregatorCommitment {
    function proposalSignersCommitment(uint256 proposalId) external view returns (bytes32);
}

/// @dev A community xPNTs token's objective over-issue flag (CC-28).
interface IOverIssuable {
    function isOverIssued() external view returns (bool);
}

/**
 * @title OverIssueFraudProofVerifier
 * @notice CC-89 stage-2, over-issue class. Proves a guardian-collusion slash was fraudulent so
 *         `BLSAggregator.queueGuardianSlash / executeGuardianSlash` (SP PR #370, ABI ≥ 4.7.0) can
 *         slash the colluding guardians' ROLE_DVT stake. SP trusts only this verifier's boolean and
 *         never judges fraud itself.
 *
 * A fraud proof is accepted iff ALL hold (fail-closed → returns `false`, NEVER reverts):
 *   0. `domainDigest` equals SP's canonical `fraudProofDigest(fraudProofId, guiltyGuardians)` recomputed
 *      from THIS verifier's bound (block.chainid, AGGREGATOR, REGISTRY). This is the CC-115 B1 anti-replay
 *      gate: a proof built for another chain / aggregator / Registry produces a different digest and is
 *      refused, closing cross-contract replay from the DVT side (SuperPaymaster BLSAggregator §domain).
 *   1. `fraudProofId` is the canonical derivation of the disputed `proposalId` (content-bound).
 *   2. `claimedSigners` is canonical: strictly ascending by uint160, non-zero, bounded.
 *   3. The FULL disputed slash message is reconstructed from the proof's slash fields and matches
 *      SP's fraud-time A' commitment for `proposalId`. Crucially the `disputedToken` is bound INTO
 *      the recomputed `evidenceHash → messageHash → commitment` chain, so an attacker cannot take a
 *      real proposal's signer set and point it at an unrelated not-over-issued token to slash the
 *      honest guardians who signed it (the CC-89 Codex-review Critical).
 *   4. `guiltyGuardians == claimedSigners` EXACTLY (not merely a subset). See SET-EXACT note below.
 *   5. the over-issue the slash cited is FALSE — the token is not over-issued → the slash was unjust.
 *
 * @dev SET-EXACT (CC-115 B1, supersedes the earlier `⊆` rule). The accused set must equal the committed
 *      signer set, because the fraudProof is entirely CALLER-supplied: the only set an attacker cannot
 *      forge is `claimedSigners` (it must reproduce SP's A' commitment). A subset-lenient verifier is
 *      the CC-48 round-5 vector — a colluder front-runs an honest watcher's
 *      `queueGuardianSlash(id, {A,B,C}, proof)` with `queueGuardianSlash(id, {A}, proof)`; the case opens
 *      on {A}, burns the single-use `fraudProofId` FOR EVER, and B,C become permanently immune with an
 *      on-chain record saying the matter was adjudicated. For the over-issue class this is also the
 *      correct semantics: an UNJUST slash's ENTIRE signer set colluded, so the guilty set IS the signer
 *      set. This is why the verifier passes SP's `FraudProofVerifierConformance.assertSetBound` (a
 *      documented release gate), which the pre-existing `⊆` implementation would have failed.
 *
 * @dev EVIDENCE STRUCTURE (cross-repo alignment). The disputed slash's `evidenceHash` (opaque to SP,
 *      supplied by the slash filer) MUST be `keccak256(abi.encode(OVERISSUE_EVIDENCE_TAG, token,
 *      operator, epoch))`. The E2E slash filer must file with exactly this — else the message
 *      reconstruction won't match and every proof is rejected.
 *
 * @dev ⚠️ SECURITY — NOT PRODUCTION-SAFE / DO NOT WIRE TO A SLASH-CAPABLE DEPLOYMENT.
 *      Step 5 reads the disputed token's CURRENT `isOverIssued()`. This is the **testnet-E2E variant**,
 *      sound ONLY while the token's over-issue state is held constant between the disputed slash and
 *      this proof. Because the read is current-state, the verdict is NOT bound to the disputed epoch:
 *        • a token whose supply is later repaired (over-issue → fixed) flips a once-JUSTIFIED slash
 *          into a "provable fraud", letting the colluders' victims be re-slashed — i.e. honest
 *          guardians who correctly slashed a truly over-issuing token can themselves be slashed later;
 *        • an adversarial MUTABLE token can return whatever `isOverIssued()` value serves the caller
 *          at proof time.
 *      This is the historical-state gap in docs/design/guardian-collusion-slash.md §4b. PRODUCTION
 *      MUST recompute against the disputed epoch-block state (BLOCKHASH + storage proof, bounded
 *      challenge window) before this verifier is set as an aggregator's `fraudProofVerifier` on any
 *      deployment where `executeGuardianSlash` moves real stake. Test/E2E use only until that lands.
 */
contract OverIssueFraudProofVerifier is IFraudProofVerifier {
    string internal constant FRAUD_ID_TAG = "GUARDIAN_FRAUD_V1"; // DVT-internal fraudProofId derivation
    string internal constant OVERISSUE_EVIDENCE_TAG = "DVT_OVERISSUE_EVIDENCE_V1"; // DVT evidence convention
    uint256 internal constant MAX_SIGNERS = 13; // == BLSAggregator.MAX_VALIDATORS

    /// @notice SP's BLS-consensus domain-separator + path-tag constants, byte-for-byte identical to
    ///         SuperPaymaster contracts/src/modules/monitoring/BLSAggregator.sol
    ///         (DOMAIN_NAME :238, TAG_EXECUTE_SLASH :243, TAG_SIGNERS_COMMITMENT :247,
    ///         TAG_FRAUD_PROOF :248, domainSeparator() :255, slash message :977, commitment :1299).
    ///         These MUST match the LIVE aggregator or every recompute misses — the pre-4.11 layout
    ///         (string tag + raw chainid/aggregator, empty rep arrays in the slash message) is gone.
    bytes32 internal constant DOMAIN_NAME = keccak256("SuperPaymaster.BLSConsensus.v1");
    bytes32 internal constant TAG_EXECUTE_SLASH = keccak256("SuperPaymaster.BLS.ExecuteSlash.v1");
    bytes32 internal constant TAG_SIGNERS_COMMITMENT = keccak256("SuperPaymaster.BLS.SignersCommitment.v1");
    bytes32 internal constant TAG_FRAUD_PROOF = keccak256("SuperPaymaster.BLS.FraudProof.v1");

    /// @notice The BLSAggregator whose commitment we read AND whose address SP bound into the
    ///         commitment (`address(this)` in `_computeSignersCommitment`) and into the domain
    ///         separator. The recompute only matches when this equals the aggregator that stored
    ///         the commitment / computed `domainDigest`.
    address public immutable AGGREGATOR;

    /// @notice SP's Registry, the fourth field of the BLS-consensus domain separator
    ///         (`keccak256(abi.encode(DOMAIN_NAME, chainid, aggregator, REGISTRY))`). Bound here so the
    ///         verifier reconstructs `domainDigest` byte-for-byte and refuses a proof issued for an
    ///         aggregator wired to a different Registry.
    address public immutable REGISTRY;

    constructor(address aggregator, address registry) {
        require(aggregator != address(0), "aggregator=0");
        require(registry != address(0), "registry=0");
        AGGREGATOR = aggregator;
        REGISTRY = registry;
    }

    /// @notice SP's BLS-consensus domain separator for THIS (chain, aggregator, Registry).
    ///         Mirrors BLSAggregator.domainSeparator().
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_NAME, block.chainid, AGGREGATOR, REGISTRY));
    }

    /// @notice SP's canonical `fraudProofDigest` — the value SP passes as `domainDigest`.
    ///         Mirrors BLSAggregator.fraudProofDigest(fraudProofId, guiltyGuardians) byte-for-byte.
    function expectedFraudProofDigest(uint256 fraudProofId, address[] memory guiltyGuardians)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(domainSeparator(), TAG_FRAUD_PROOF, fraudProofId, guiltyGuardians));
    }

    /// @notice Canonical fraudProofId for a disputed proposal (callers derive the same value).
    function deriveFraudProofId(uint256 proposalId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(FRAUD_ID_TAG, proposalId)));
    }

    /// @notice The over-issue evidenceHash the slash filer MUST use (binds token+operator+epoch).
    function evidenceHash(address disputedToken, address operator, uint256 epoch) public pure returns (bytes32) {
        return keccak256(abi.encode(OVERISSUE_EVIDENCE_TAG, disputedToken, operator, epoch));
    }

    /// @notice Reconstruct SP's slash-only `expectedMessageHash`, byte-identical to the LIVE
    ///         BLSAggregator execute-slash encoding (BLSAggregator.sol:977):
    ///         keccak256(abi.encode(domainSeparator(), TAG_EXECUTE_SLASH, proposalId, operator,
    ///                              slashLevel, epoch, evidenceHash)).
    ///         `domainSeparator()` already binds chainid+aggregator+Registry, so there is no raw
    ///         chainid field and no empty reputation arrays (that was the obsolete pre-4.11 shape).
    ///         `evidenceHash` is the DVT-defined convention the slash filer MUST match.
    function slashMessageHash(uint256 proposalId, address operator, uint8 slashLevel, uint256 epoch, address disputedToken)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                domainSeparator(),
                TAG_EXECUTE_SLASH,
                proposalId,
                operator,
                slashLevel,
                epoch,
                evidenceHash(disputedToken, operator, epoch)
            )
        );
    }

    /**
     * @inheritdoc IFraudProofVerifier
     * @dev fraudProof = abi.encode(
     *        uint256 proposalId, address operator, uint8 slashLevel, uint256 epoch,
     *        address disputedToken, uint256 signerMask, address[] claimedSigners)
     *      Wraps the real check in a self-staticcall so a malformed proof or a malicious
     *      `disputedToken` that reverts can only make verify return false — never revert.
     */
    function verify(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view override returns (bool) {
        try this.check(domainDigest, fraudProofId, guiltyGuardians, fraudProof) returns (bool ok) {
            return ok;
        } catch {
            return false; // fail-closed: decode revert, missing commitment call, or token revert
        }
    }

    /// @dev The real verification. External only so `verify` can try/catch it; self-call-gated.
    function check(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view returns (bool) {
        require(msg.sender == address(this), "self only");

        // 0. DOMAIN BINDING (CC-115 B1). The digest SP handed us MUST be the canonical
        //    fraudProofDigest for THIS (chain, aggregator, Registry) over (fraudProofId, guiltyGuardians).
        //    A proof built for another chain / aggregator / Registry yields a different digest → refused.
        //    Checked BEFORE decoding so a wrong-domain proof is rejected regardless of its payload.
        if (domainDigest != expectedFraudProofDigest(fraudProofId, guiltyGuardians)) return false;

        (
            uint256 proposalId,
            address operator,
            uint8 slashLevel,
            uint256 epoch,
            address disputedToken,
            uint256 signerMask,
            address[] memory claimedSigners
        ) = abi.decode(fraudProof, (uint256, address, uint8, uint256, address, uint256, address[]));

        // 1. Content binding: fraudProofId MUST be the canonical derivation of proposalId.
        if (fraudProofId != deriveFraudProofId(proposalId)) return false;

        // 2. claimedSigners canonical: strictly ascending uint160, non-zero, bounded.
        if (!_canonicalSigners(claimedSigners)) return false;

        // 3. Commitment check with disputedToken bound in via evidenceHash → messageHash (an
        //    attacker can't swap disputedToken without breaking evidenceHash → messageHash → commitment).
        if (!_commitmentMatches(proposalId, operator, slashLevel, epoch, disputedToken, signerMask, claimedSigners)) {
            return false;
        }

        // 4. SET-EXACT: guiltyGuardians == claimedSigners. `claimedSigners` is the only forgery-proof
        //    set (it must reproduce SP's A' commitment); requiring exact equality blocks the CC-48
        //    round-5 front-run-and-shrink vector and rejects any superset / reordering / duplicate.
        if (!_isEqualSet(guiltyGuardians, claimedSigners)) return false;

        // 5. Over-issue evidence (E2E current-state variant; see contract @dev). A revert here bubbles
        //    to verify's catch → false (fail-closed). `false` ⇒ not over-issued ⇒ slash was fraudulent.
        if (IOverIssuable(disputedToken).isOverIssued()) return false;

        return true;
    }

    /// @dev claimedSigners canonical form: strictly ascending uint160, non-zero, bounded.
    function _canonicalSigners(address[] memory claimedSigners) internal pure returns (bool) {
        uint256 n = claimedSigners.length;
        if (n == 0 || n > MAX_SIGNERS) return false;
        for (uint256 i = 0; i < n; i++) {
            if (claimedSigners[i] == address(0)) return false;
            if (i > 0 && uint160(claimedSigners[i - 1]) >= uint160(claimedSigners[i])) return false;
        }
        return true;
    }

    /// @dev Reconstruct SP's slash message (binding disputedToken) and match the A' commitment.
    function _commitmentMatches(
        uint256 proposalId,
        address operator,
        uint8 slashLevel,
        uint256 epoch,
        address disputedToken,
        uint256 signerMask,
        address[] memory claimedSigners
    ) internal view returns (bool) {
        bytes32 anchor = IBLSAggregatorCommitment(AGGREGATOR).proposalSignersCommitment(proposalId);
        if (anchor == bytes32(0)) return false; // not a recorded proposal
        bytes32 messageHash = slashMessageHash(proposalId, operator, slashLevel, epoch, disputedToken);
        // Byte-identical to BLSAggregator._computeSignersCommitment (BLSAggregator.sol:1299):
        // keccak256(abi.encode(domainSeparator(), TAG_SIGNERS_COMMITMENT, proposalId, messageHash,
        //                      signerMask, signers)). domainSeparator() binds chainid+aggregator+
        // Registry, replacing the obsolete pre-4.11 `string tag + raw chainid + raw aggregator` shape.
        bytes32 recomputed = keccak256(
            abi.encode(
                domainSeparator(), TAG_SIGNERS_COMMITMENT, proposalId, messageHash, signerMask, claimedSigners
            )
        );
        return recomputed == anchor;
    }

    /// @dev Exact set equality: `a == b` element-wise. Because `b` (claimedSigners) is already
    ///      verified canonical (ascending, non-zero), equality forces `a` to be canonical too — so a
    ///      superset (different length), a reordering (element mismatch) and a duplicate (mismatch or
    ///      non-canonical) all return false without a separate canonical pass over `a`.
    function _isEqualSet(address[] calldata a, address[] memory b) internal pure returns (bool) {
        uint256 n = b.length;
        if (a.length != n) return false;
        for (uint256 i = 0; i < n; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
