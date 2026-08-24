// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @notice EXACT ABI of the verifier seam as of BLSAggregator-4.8.0. Copy this
///         interface verbatim into the DVT repo — do not re-derive it by hand.
///         Canonical selector: `verify(bytes32,uint256,address[],bytes)` = 0x61077735.
interface IFraudProofVerifierConformance {
    function verify(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view returns (bool);
}

interface IAggregatorFraudDigest {
    function fraudProofDigest(uint256 fraudProofId, address[] calldata guiltyGuardians)
        external
        view
        returns (bytes32);
    function domainSeparator() external view returns (bytes32);
    function TAG_FRAUD_PROOF() external view returns (bytes32);
    function DOMAIN_NAME() external view returns (bytes32);
    function REGISTRY() external view returns (address);
}

/**
 * @title FraudProofVerifierConformance
 * @notice CC-48 round-3 MEDIUM-2: the test fixture that decides whether a DVT-supplied
 *         fraud-proof verifier really binds `domainDigest`, rather than merely accepting
 *         it as an argument.
 *
 * @dev The problem this exists for. `IFraudProofVerifier.verify` takes `domainDigest`
 *      first and the NatSpec says verifiers MUST bind it — but a verifier is an external
 *      contract, and ignoring a parameter has no on-chain consequence. A verifier that
 *      only looks at (fraudProofId, guiltyGuardians, fraudProof) accepts a proof built
 *      for a DIFFERENT aggregator or chain, which re-opens from the DVT side exactly the
 *      cross-contract replay the aggregator's domain separation closed. A comment is not
 *      a gate; this is.
 *
 *      Usage in the DVT repo (repo:dvt owns the verifier; SP owns this fixture):
 *
 *          import {FraudProofVerifierConformance as Conformance}
 *              from "<superpaymaster>/contracts/test/helpers/FraudProofVerifierConformance.sol";
 *
 *          function test_VerifierIsDomainBound() public {
 *              Conformance.assertDomainBound(
 *                  address(myVerifier),
 *                  address(aggregatorA),   // the aggregator the proof was built for
 *                  address(aggregatorB),   // any other aggregator: same chain is enough
 *                  fraudProofId,
 *                  guiltyGuardians,
 *                  fraudProofBytes
 *              );
 *          }
 *
 *      `aggregatorB` may be a second deployment on the SAME chain with the SAME Registry
 *      and the SAME validator keys — that is the hardest case and the one that actually
 *      happened (an experiment stack's proofs replaying onto production). If a verifier
 *      passes with only a different chainid, it has not been tested.
 *
 *      The three assertions:
 *        1. ACCEPTS the digest it was built for   (no false negatives — a verifier that
 *           rejects everything would trivially "pass" a replay test)
 *        2. REJECTS another aggregator's digest for the same (id, guardians, proof)
 *        3. REJECTS an arbitrary unrelated digest (catches "compares to a constant")
 */
library FraudProofVerifierConformance {
    error VerifierRejectedItsOwnDomain(address verifier, bytes32 domainDigest);
    error VerifierIgnoresDomainDigest(address verifier, bytes32 foreignDigest);
    error VerifierAcceptsArbitraryDigest(address verifier, bytes32 arbitraryDigest);
    error AggregatorsShareADigest(address aggregatorA, address aggregatorB);

    /// @notice Full conformance check for one (proof, guardians) pair.
    function assertDomainBound(
        address verifier,
        address aggregatorA,
        address aggregatorB,
        uint256 fraudProofId,
        address[] memory guiltyGuardians,
        bytes memory fraudProof
    ) internal view {
        bytes32 digestA = IAggregatorFraudDigest(aggregatorA).fraudProofDigest(fraudProofId, guiltyGuardians);
        bytes32 digestB = IAggregatorFraudDigest(aggregatorB).fraudProofDigest(fraudProofId, guiltyGuardians);

        // Sanity on the fixture itself: if the two aggregators produce the same digest,
        // the test proves nothing. (They cannot, unless aggregatorA == aggregatorB.)
        if (digestA == digestB) revert AggregatorsShareADigest(aggregatorA, aggregatorB);

        if (!_verify(verifier, digestA, fraudProofId, guiltyGuardians, fraudProof)) {
            revert VerifierRejectedItsOwnDomain(verifier, digestA);
        }
        if (_verify(verifier, digestB, fraudProofId, guiltyGuardians, fraudProof)) {
            revert VerifierIgnoresDomainDigest(verifier, digestB);
        }
        bytes32 arbitrary = keccak256("CC-48 conformance: not any aggregator's digest");
        if (_verify(verifier, arbitrary, fraudProofId, guiltyGuardians, fraudProof)) {
            revert VerifierAcceptsArbitraryDigest(verifier, arbitrary);
        }
    }

    /// @notice Recompute the digest independently of the aggregator, so DVT can build it
    ///         off-chain and assert byte equality rather than trusting a getter.
    function expectedFraudProofDigest(
        bytes32 domainName,
        uint256 chainId,
        address aggregator,
        address registry,
        bytes32 tagFraudProof,
        uint256 fraudProofId,
        address[] memory guiltyGuardians
    ) internal pure returns (bytes32) {
        bytes32 separator = keccak256(abi.encode(domainName, chainId, aggregator, registry));
        return keccak256(abi.encode(separator, tagFraudProof, fraudProofId, guiltyGuardians));
    }

    /// @dev A verifier that reverts (rather than returning false) is treated as
    ///      rejecting — the aggregator's own call would revert too, i.e. fail closed.
    function _verify(
        address verifier,
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] memory guiltyGuardians,
        bytes memory fraudProof
    ) private view returns (bool) {
        (bool ok, bytes memory ret) = verifier.staticcall(
            abi.encodeWithSelector(
                IFraudProofVerifierConformance.verify.selector,
                domainDigest,
                fraudProofId,
                guiltyGuardians,
                fraudProof
            )
        );
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (bool));
    }
}
