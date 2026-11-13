// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import "./vendor/OverIssueFraudProofVerifier.sol";

/// @dev Round-3a compatibility adapter for the DVT verifier fixture. The production
///      commitment now binds blockhash(N-1), supplied explicitly in the fraud proof.
contract AnchoredOverIssueFraudProofVerifier is OverIssueFraudProofVerifier {
    uint256 internal constant ANCHORED_MAX_SIGNERS = 64;

    constructor(address aggregator, address registry) OverIssueFraudProofVerifier(aggregator, registry) {}

    function verify(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view override returns (bool) {
        try this.checkAnchored(domainDigest, fraudProofId, guiltyGuardians, fraudProof) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function checkAnchored(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view returns (bool) {
        require(msg.sender == address(this), "self only");
        if (domainDigest != expectedFraudProofDigest(fraudProofId, guiltyGuardians)) return false;

        (
            uint256 proposalId,
            address operator,
            uint8 slashLevel,
            uint256 epoch,
            address disputedToken,
            uint256 signerMask,
            address[] memory claimedSigners,
            bytes32 anchorBlockHash
        ) = abi.decode(fraudProof, (uint256, address, uint8, uint256, address, uint256, address[], bytes32));

        if (fraudProofId != deriveFraudProofId(proposalId)) return false;
        if (!_canonicalAnchoredSigners(claimedSigners)) return false;

        bytes32 stored = IBLSAggregatorCommitment(AGGREGATOR).proposalSignersCommitment(proposalId);
        if (stored == bytes32(0)) return false;
        bytes32 messageHash = slashMessageHash(proposalId, operator, slashLevel, epoch, disputedToken);
        bytes32 recomputed = keccak256(
            abi.encode(
                domainSeparator(),
                TAG_SIGNERS_COMMITMENT,
                proposalId,
                messageHash,
                signerMask,
                claimedSigners,
                anchorBlockHash
            )
        );
        if (recomputed != stored) return false;
        if (!_isEqualSet(guiltyGuardians, claimedSigners)) return false;
        if (IOverIssuable(disputedToken).isOverIssued()) return false;
        return true;
    }

    function _canonicalAnchoredSigners(address[] memory claimedSigners) internal pure returns (bool) {
        uint256 n = claimedSigners.length;
        if (n == 0 || n > ANCHORED_MAX_SIGNERS) return false;
        for (uint256 i; i < n; ++i) {
            if (claimedSigners[i] == address(0)) return false;
            if (i != 0 && uint160(claimedSigners[i - 1]) >= uint160(claimedSigners[i])) return false;
        }
        return true;
    }
}
