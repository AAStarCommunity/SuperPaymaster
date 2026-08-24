// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @notice EXACT ABI of the verifier seam as of BLSAggregator-4.9.0. Copy this
///         interface verbatim into the DVT repo — do not re-derive it by hand.
///         Canonical selector: `verify(bytes32,uint256,address[],bytes)` = 0x61077735.
///         (The selector is unchanged since 4.7.0; the 4.9.0 bump is the aggregator's
///         own ABI, not this seam's.)
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
 *          function test_VerifierIsSetBound() public {
 *              Conformance.assertSetBound(
 *                  address(myVerifier),
 *                  address(aggregatorA),   // digests are recomputed per perturbed set
 *                  fraudProofId,
 *                  guiltyGuardians,        // the EXACT set the evidence commits to (>= 2)
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
 *
 *      CC-48 round-5 MEDIUM-1 — `assertDomainBound` IS NOT ENOUGH ON ITS OWN. Domain
 *      binding says nothing about WHICH guardians a proof covers, so a verifier that
 *      recomputes the digest from the (id, guardians) it was handed passes all three
 *      assertions above while happily accepting a strict SUBSET of the guilty set.
 *      Because `fraudProofId` is single-use for ever, that is directly exploitable —
 *      see `assertSetBound` below. BOTH assertions are release gates; running only
 *      this one is the failure mode this paragraph exists to prevent.
 */
library FraudProofVerifierConformance {
    error VerifierRejectedItsOwnDomain(address verifier, bytes32 domainDigest);
    error VerifierIgnoresDomainDigest(address verifier, bytes32 foreignDigest);
    error VerifierAcceptsArbitraryDigest(address verifier, bytes32 arbitraryDigest);
    error AggregatorsShareADigest(address aggregatorA, address aggregatorB);
    /// @dev CC-48 round-5 MEDIUM-1 (set completeness).
    error VerifierRejectedItsOwnGuardianSet(address verifier, bytes32 setHash);
    error VerifierAcceptsGuardianSubset(address verifier, address droppedGuardian);
    error VerifierAcceptsGuardianSuperset(address verifier, address addedGuardian);
    error VerifierAcceptsUnrelatedGuardianSet(address verifier, bytes32 unrelatedSetHash);
    error SetBoundNeedsAtLeastTwoGuardians(uint256 provided);

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

    /// @notice CC-48 round-5 MEDIUM-1: the guilty set a proof covers must be EXACT.
    ///
    /// @dev WHY THIS IS A SEPARATE, MANDATORY GATE. `assertDomainBound` proves the proof
    ///      belongs to this aggregator. It proves nothing about WHO the proof accuses,
    ///      and the two are independent: a verifier that recomputes
    ///      `fraudProofDigest(id, guardians)` from the arguments it was handed is
    ///      perfectly domain-bound and still self-consistent on any subset — it simply
    ///      re-derives a matching digest for the smaller set. Evidence-checking verifiers
    ///      ("each listed address co-signed the fraudulent proposal") are subset-lenient
    ///      BY CONSTRUCTION, which is exactly the shape `OverIssueFraudProofVerifier`
    ///      will have. The attester-commitment reference implementation in
    ///      `CC48VerifierConformance.t.sol` happens to be set-bound by accident of its
    ///      pre-image, which is precisely why this fixture must exist rather than relying
    ///      on "the reference passes".
    ///
    ///      THE VECTOR IT CLOSES. `queueGuardianSlash` is permissionless, the accused set
    ///      is chosen by the CALLER, and `fraudProofId` is single-use FOR EVER
    ///      (`guardianSlashCases[id].status != 0` blocks re-opening, and 2=executed /
    ///      3=expired block it as permanently as 1=pending). Against a subset-lenient
    ///      verifier, a colluder who sees an honest watcher's
    ///      `queueGuardianSlash(id, {A,B,C}, proof)` in the mempool front-runs it with
    ///      `queueGuardianSlash(id, {A}, proof)`. The case opens on {A}, executes, burns
    ///      `id`, and B and C are permanently immune to that evidence — with an on-chain
    ///      record saying the matter was adjudicated.
    ///
    ///      WHAT IS CHECKED. For the SAME `(fraudProofId, fraudProof)`, and with each
    ///      candidate set's own digest recomputed from `aggregator` exactly as
    ///      `queueGuardianSlash` would:
    ///        1. ACCEPTS the exact committed set        (no false negative)
    ///        2. REJECTS every strict subset of size n-1 (each guardian dropped in turn)
    ///        3. REJECTS the superset with one extra address
    ///        4. REJECTS an unrelated set of the same size
    ///
    /// @param verifier          the DVT verifier under test
    /// @param aggregator        the aggregator the proof was built for (digest source)
    /// @param fraudProofId      the id the proof was issued for
    /// @param guiltyGuardians   the EXACT set the evidence commits to; >= 2 entries, since
    ///                          a 1-element set has no non-empty strict subset and the
    ///                          aggregator rejects the empty one outright
    /// @param fraudProof        the proof bytes, unchanged across every candidate set
    function assertSetBound(
        address verifier,
        address aggregator,
        uint256 fraudProofId,
        address[] memory guiltyGuardians,
        bytes memory fraudProof
    ) internal view {
        uint256 n = guiltyGuardians.length;
        if (n < 2) revert SetBoundNeedsAtLeastTwoGuardians(n);

        // 1. the exact set must still be accepted (otherwise "rejects everything" would
        //    trivially pass 2-4, the same false-negative trap assertDomainBound guards).
        if (!_verifyAgainst(verifier, aggregator, fraudProofId, guiltyGuardians, fraudProof)) {
            revert VerifierRejectedItsOwnGuardianSet(verifier, keccak256(abi.encode(guiltyGuardians)));
        }

        // 2. every strict subset of size n-1. Dropping each guardian in turn is what an
        //    attacker actually does: keep the set self-consistent, shrink the blame.
        for (uint256 dropped = 0; dropped < n; ++dropped) {
            address[] memory subset = new address[](n - 1);
            uint256 k;
            for (uint256 i = 0; i < n; ++i) {
                if (i == dropped) continue;
                subset[k++] = guiltyGuardians[i];
            }
            if (_verifyAgainst(verifier, aggregator, fraudProofId, subset, fraudProof)) {
                revert VerifierAcceptsGuardianSubset(verifier, guiltyGuardians[dropped]);
            }
        }

        // CC-48 round-6 LOW-2: both synthetic sets come from ONE constructive generator
        // (see `syntheticSets`), which draws every address against a growing exclusion
        // list. Round-5 built the unrelated set against `guiltyGuardians` alone, so its
        // entries were merely PROBABLY distinct from each other and from `extra`; a
        // collision would have silently shortened "n unrelated addresses" into a smaller
        // multiset and weakened (4) with nothing failing.
        (address extra, address[] memory unrelated) = syntheticSets(guiltyGuardians, fraudProofId);

        // 3. superset: one extra address the evidence never named. A verifier that only
        //    checks "everyone I was told about is guilty" is caught by (2); one that only
        //    checks "everyone guilty is in the list I was told about" is caught here —
        //    the accused innocent would lose 100% of its lock.
        address[] memory superset = new address[](n + 1);
        for (uint256 i = 0; i < n; ++i) {
            superset[i] = guiltyGuardians[i];
        }
        superset[n] = extra;
        if (_verifyAgainst(verifier, aggregator, fraudProofId, superset, fraudProof)) {
            revert VerifierAcceptsGuardianSuperset(verifier, extra);
        }

        // 4. a wholly unrelated set of the same size — catches a verifier that only looks
        //    at the set's LENGTH, or ignores the set entirely. Disjoint from the guilty
        //    set, from `extra`, and pairwise distinct, by construction.
        if (_verifyAgainst(verifier, aggregator, fraudProofId, unrelated, fraudProof)) {
            revert VerifierAcceptsUnrelatedGuardianSet(verifier, keccak256(abi.encode(unrelated)));
        }
    }

    /// @notice The synthetic addresses `assertSetBound` will use for a given
    ///         `(guiltyGuardians, fraudProofId)` — the extra address for the superset case
    ///         and the n unrelated addresses for case (4).
    /// @dev    CC-48 round-6 LOW-2. Exposed (rather than inlined) so the fixture's own
    ///         regression tests can assert the property directly instead of inferring it:
    ///         `guiltyGuardians ∪ {extra} ∪ unrelated` are PAIRWISE DISTINCT and none is
    ///         `address(0)`, by construction — each draw is rejected against every address
    ///         already chosen, not merely against the accused set.
    function syntheticSets(address[] memory guiltyGuardians, uint256 fraudProofId)
        internal
        pure
        returns (address extra, address[] memory unrelated)
    {
        uint256 n = guiltyGuardians.length;
        address[] memory excluded = new address[](2 * n + 1);
        uint256 len;
        for (uint256 i = 0; i < n; ++i) {
            excluded[len++] = guiltyGuardians[i];
        }

        extra = _syntheticGuardian(excluded, len, _setSalt(fraudProofId, 0));
        excluded[len++] = extra;

        unrelated = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            address pick = _syntheticGuardian(excluded, len, _setSalt(fraudProofId, i + 1));
            unrelated[i] = pick;
            excluded[len++] = pick;
        }
    }

    /// @dev Recompute the digest for `candidate` from the aggregator itself — the same
    ///      call `queueGuardianSlash` makes — then ask the verifier. Recomputing (rather
    ///      than reusing the committed set's digest) is what makes this a real test: it
    ///      reproduces the attacker's transaction exactly, digest included.
    function _verifyAgainst(
        address verifier,
        address aggregator,
        uint256 fraudProofId,
        address[] memory candidate,
        bytes memory fraudProof
    ) private view returns (bool) {
        bytes32 digest = IAggregatorFraudDigest(aggregator).fraudProofDigest(fraudProofId, candidate);
        return _verify(verifier, digest, fraudProofId, candidate, fraudProof);
    }

    /// @dev CC-48 round-6 LOW-2. A per-index salt that cannot overflow. Round-5 used
    ///      `fraudProofId + 1 + i`, which reverts on an id within `n + 1` of
    ///      `type(uint256).max` — an id is caller-chosen and single-use for ever, so
    ///      "nobody would pick one that big" is not a property, it is a hope. Hashing
    ///      removes the arithmetic entirely.
    function _setSalt(uint256 fraudProofId, uint256 index) private pure returns (uint256) {
        return uint256(keccak256(abi.encode("CC-48 conformance set salt", fraudProofId, index)));
    }

    /// @dev A deterministic address guaranteed NOT to be among `excluded[0 .. len)`
    ///      (and never address(0), which the aggregator rejects anyway). Derived, not
    ///      hard-coded, so the fixture cannot be gamed by a verifier that allow-lists a
    ///      known test address. `len` is passed separately so a caller can grow one
    ///      buffer as it picks, and every later pick is checked against every earlier one.
    function _syntheticGuardian(address[] memory excluded, uint256 len, uint256 salt)
        private
        pure
        returns (address candidate)
    {
        bytes32 seed = keccak256(abi.encode("CC-48 conformance synthetic guardian", excluded, len, salt));
        while (true) {
            candidate = address(uint160(uint256(seed)));
            bool collides = candidate == address(0);
            for (uint256 i = 0; i < len && !collides; ++i) {
                if (excluded[i] == candidate) collides = true;
            }
            if (!collides) return candidate;
            seed = keccak256(abi.encode(seed));
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
