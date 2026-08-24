// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {IRegistry} from "src/interfaces/v3/IRegistry.sol";
import {IGTokenStaking} from "src/interfaces/v3/IGTokenStaking.sol";
import {FraudProofVerifierConformance as Conformance, IAggregatorFraudDigest}
    from "../helpers/FraudProofVerifierConformance.sol";

/// @notice REFERENCE implementation for repo:dvt. It binds `domainDigest` into the
///         signed pre-image, which is the property the conformance fixture checks.
///         Signature scheme is deliberately trivial (an attester ECDSA-free HMAC-style
///         hash) — what matters is WHERE domainDigest enters, not the primitive.
contract DomainBoundFraudProofVerifier {
    bytes32 public immutable ATTESTER_SECRET_COMMITMENT;

    constructor(bytes32 attesterSecretCommitment) {
        ATTESTER_SECRET_COMMITMENT = attesterSecretCommitment;
    }

    /// @dev The proof is valid iff it equals the commitment over
    ///      (domainDigest, fraudProofId, guiltyGuardians). Because `domainDigest` is
    ///      IN the pre-image, a proof produced for aggregator A cannot be presented to
    ///      aggregator B: B supplies a different digest and the comparison fails.
    function verify(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view returns (bool) {
        bytes32 expected = keccak256(
            abi.encode(ATTESTER_SECRET_COMMITMENT, domainDigest, fraudProofId, guiltyGuardians)
        );
        return fraudProof.length == 32 && bytes32(fraudProof) == expected;
    }

    function attest(bytes32 domainDigest, uint256 fraudProofId, address[] calldata guiltyGuardians)
        external
        view
        returns (bytes memory)
    {
        return abi.encode(
            keccak256(abi.encode(ATTESTER_SECRET_COMMITMENT, domainDigest, fraudProofId, guiltyGuardians))
        );
    }
}

/// @notice ANTI-reference: takes `domainDigest` and ignores it. Compiles, satisfies the
///         interface, and re-opens cross-aggregator replay from the DVT side. The
///         conformance fixture must catch it — that is what makes the fixture a gate
///         rather than documentation.
contract DomainIgnoringFraudProofVerifier {
    function verify(bytes32, uint256 fraudProofId, address[] calldata, bytes calldata fraudProof)
        external
        pure
        returns (bool)
    {
        return fraudProof.length == 32 && uint256(bytes32(fraudProof)) == fraudProofId;
    }
}

/// @notice ANTI-reference #2 (CC-48 round-5 MEDIUM-1): perfectly DOMAIN-bound, and still
///         broken. It recomputes the digest from the very (id, guardians) it was handed,
///         against a hard-coded aggregator — so it passes all three `assertDomainBound`
///         assertions — and then checks only "every address I was given is guilty". That
///         predicate is self-consistent on any SUBSET, which is the shape an
///         evidence-checking verifier (e.g. the coming `OverIssueFraudProofVerifier`)
///         naturally has. Against a single-use `fraudProofId` this is the front-run vector.
contract SubsetLenientEvidenceVerifier {
    address public immutable AGGREGATOR;
    bytes32 public immutable PROOF_HASH;
    mapping(uint256 => mapping(address => bool)) public guilty;

    constructor(address aggregator, bytes32 proofHash) {
        AGGREGATOR = aggregator;
        PROOF_HASH = proofHash;
    }

    function markGuilty(uint256 fraudProofId, address guardian) external {
        guilty[fraudProofId][guardian] = true;
    }

    function verify(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view returns (bool) {
        if (domainDigest != IAggregatorFraudDigest(AGGREGATOR).fraudProofDigest(fraudProofId, guiltyGuardians)) {
            return false;
        }
        if (keccak256(fraudProof) != PROOF_HASH) return false;
        for (uint256 i = 0; i < guiltyGuardians.length; ++i) {
            if (!guilty[fraudProofId][guiltyGuardians[i]]) return false;
        }
        return guiltyGuardians.length != 0;
    }
}

/// @notice ANTI-reference #3: the mirror-image mistake — "every guardian I know to be
///         guilty appears in the list". Accepts a SUPERSET, so an innocent address can be
///         appended to the accused set and lose 100% of its ROLE_DVT lock.
contract SupersetLenientEvidenceVerifier {
    address public immutable AGGREGATOR;
    bytes32 public immutable PROOF_HASH;
    mapping(uint256 => address[]) internal known;

    constructor(address aggregator, bytes32 proofHash) {
        AGGREGATOR = aggregator;
        PROOF_HASH = proofHash;
    }

    function markGuilty(uint256 fraudProofId, address guardian) external {
        known[fraudProofId].push(guardian);
    }

    function verify(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view returns (bool) {
        if (domainDigest != IAggregatorFraudDigest(AGGREGATOR).fraudProofDigest(fraudProofId, guiltyGuardians)) {
            return false;
        }
        if (keccak256(fraudProof) != PROOF_HASH) return false;
        address[] storage expected = known[fraudProofId];
        for (uint256 i = 0; i < expected.length; ++i) {
            bool found;
            for (uint256 j = 0; j < guiltyGuardians.length && !found; ++j) {
                if (guiltyGuardians[j] == expected[i]) found = true;
            }
            if (!found) return false;
        }
        return expected.length != 0;
    }
}

contract ConformanceRegistryStub is IRegistry {
    address public stakingAddr;
    function setStakingAddr(address s) external { stakingAddr = s; }
    function GTOKEN_STAKING() external view returns (IGTokenStaking) { return IGTokenStaking(stakingAddr); }
    function hasRole(bytes32, address) external pure override returns (bool) { return true; }
    function getRoleConfig(bytes32) external pure override returns (RoleConfig memory) {
        return RoleConfig(100, 0, 0, 0, 0, 0, 0, false, 0, "stub", address(0), 0);
    }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external override {}
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleUserCount(bytes32) external pure override returns (uint256) { return 0; }
    function getUserRoles(address) external pure override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function getCreditLimit(address) external pure override returns (uint256) { return 0; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external pure override returns (string memory) { return "ConformanceRegistryStub"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external pure override returns (uint256) { return 0; }
}

/**
 * @title CC48VerifierConformance
 * @notice CC-48 round-3 MEDIUM-2 (SP side of a cross-repo item).
 *
 * @dev Ownership split, stated so neither side assumes the other did it:
 *        - repo:sp (here) supplies the exact ABI, the digest formula, and this
 *          conformance fixture, and proves the fixture actually discriminates.
 *        - repo:dvt owns `OverIssueFraudProofVerifier` and must run
 *          `FraudProofVerifierConformance.assertDomainBound` against it in the DVT repo's
 *          own CI. SP cannot enforce that from here — it can only make it one import.
 *
 *      Until that lands, `fraudProofVerifier` stays dormant (address(0)) in production.
 *      The tests below prove the fixture is not vacuous: a correct verifier passes, and
 *      a verifier that merely ACCEPTS `domainDigest` without binding it fails.
 */
contract CC48VerifierConformance is Test {
    BLSAggregator internal aggA;
    BLSAggregator internal aggB;
    ConformanceRegistryStub internal registry;
    DomainBoundFraudProofVerifier internal good;
    DomainIgnoringFraudProofVerifier internal bad;

    address[] internal guardians;

    function setUp() public {
        vm.chainId(11155111);
        registry = new ConformanceRegistryStub();
        // Same chain, same Registry, different addresses — the hardest replay case, and
        // the one that actually occurred (an experiment stack next to production).
        aggA = new BLSAggregator(address(registry), address(0xC0), address(0xC1));
        aggB = new BLSAggregator(address(registry), address(0xC0), address(0xC1));
        good = new DomainBoundFraudProofVerifier(keccak256("attester commitment"));
        bad = new DomainIgnoringFraudProofVerifier();

        guardians.push(address(0x9001));
        guardians.push(address(0x9002));
    }

    function _proofForA(uint256 id) internal view returns (bytes memory) {
        return good.attest(aggA.fraudProofDigest(id, guardians), id, guardians);
    }

    /// The reference verifier passes all three conformance assertions.
    function test_DomainBoundVerifierPassesConformance() public view {
        Conformance.assertDomainBound(address(good), address(aggA), address(aggB), 42, guardians, _proofForA(42));
    }

    /// The anti-reference is caught. Without this assertion the fixture could be
    /// silently vacuous and everyone would believe the seam was closed.
    function test_DomainIgnoringVerifierFailsConformance() public {
        bytes memory proof = abi.encode(bytes32(uint256(42)));
        // It accepts aggB's digest for a proof built with no domain at all.
        bytes32 foreign = aggB.fraudProofDigest(42, guardians);
        vm.expectRevert(
            abi.encodeWithSelector(Conformance.VerifierIgnoresDomainDigest.selector, address(bad), foreign)
        );
        this.callAssertDomainBound(address(bad), address(aggA), address(aggB), 42, guardians, proof);
    }

    /// A verifier that rejects everything must NOT be mistaken for "domain bound".
    function test_AlwaysFalseVerifierFailsConformance() public {
        DomainBoundFraudProofVerifier other = new DomainBoundFraudProofVerifier(keccak256("different attester"));
        bytes memory proof = _proofForA(43);
        bytes32 own = aggA.fraudProofDigest(43, guardians);
        vm.expectRevert(
            abi.encodeWithSelector(Conformance.VerifierRejectedItsOwnDomain.selector, address(other), own)
        );
        this.callAssertDomainBound(address(other), address(aggA), address(aggB), 43, guardians, proof);
    }

    /// The digest DVT computes off-chain must equal the one the aggregator supplies,
    /// byte for byte. This is the vector table the DVT repo can pin against.
    function test_DigestIsReproducibleOffChain() public view {
        uint256 id = 7;
        bytes32 fromChain = aggA.fraudProofDigest(id, guardians);
        bytes32 recomputed = Conformance.expectedFraudProofDigest(
            aggA.DOMAIN_NAME(),
            block.chainid,
            address(aggA),
            address(registry),
            aggA.TAG_FRAUD_PROOF(),
            id,
            guardians
        );
        assertEq(fromChain, recomputed, "off-chain derivation must match the aggregator");

        // ...and it differs for the sibling aggregator, on the same chain and Registry.
        assertTrue(fromChain != aggB.fraudProofDigest(id, guardians), "digest is aggregator-scoped");
    }

    /// Pin the selector so a future signature change to the seam is a loud test failure
    /// in SP rather than a silent decode failure in a deployed DVT verifier.
    function test_VerifierSelectorIsPinned() public pure {
        assertEq(
            bytes4(keccak256("verify(bytes32,uint256,address[],bytes)")),
            bytes4(0x61077735),
            "IFraudProofVerifier.verify selector changed - notify repo:dvt and repo:sdk"
        );
    }

    // =====================================================================
    // CC-48 round-5 MEDIUM-1: set completeness
    // =====================================================================

    /// The reference verifier is set-bound as well as domain-bound: its pre-image
    /// contains the full `guiltyGuardians` array, so any perturbation changes `expected`.
    function test_ReferenceVerifierPassesSetBound() public view {
        Conformance.assertSetBound(address(good), address(aggA), 42, guardians, _proofForA(42));
    }

    /// The vector that motivated this assertion. A verifier can be flawlessly
    /// domain-bound and still let a front-runner open the case on a strict subset,
    /// burning the single-use `fraudProofId` for the guardians it drops.
    function test_SubsetLenientVerifierPassesDomainBoundButFailsSetBound() public {
        bytes memory proof = abi.encode(keccak256("over-issue evidence blob"));
        SubsetLenientEvidenceVerifier lenient =
            new SubsetLenientEvidenceVerifier(address(aggA), keccak256(proof));
        lenient.markGuilty(77, guardians[0]);
        lenient.markGuilty(77, guardians[1]);

        // It is genuinely domain-bound — the existing gate says nothing is wrong.
        Conformance.assertDomainBound(address(lenient), address(aggA), address(aggB), 77, guardians, proof);

        // ...and it accepts {guardians[1]} alone for the same proof.
        vm.expectRevert(
            abi.encodeWithSelector(
                Conformance.VerifierAcceptsGuardianSubset.selector, address(lenient), guardians[0]
            )
        );
        this.callAssertSetBound(address(lenient), address(aggA), 77, guardians, proof);
    }

    /// The mirror-image failure: appending an innocent address is accepted, and that
    /// address would lose 100% of its ROLE_DVT lock. Proves assertion (3) is not vacuous.
    function test_SupersetLenientVerifierFailsSetBound() public {
        bytes memory proof = abi.encode(keccak256("over-issue evidence blob"));
        SupersetLenientEvidenceVerifier lenient =
            new SupersetLenientEvidenceVerifier(address(aggA), keccak256(proof));
        lenient.markGuilty(78, guardians[0]);
        lenient.markGuilty(78, guardians[1]);

        Conformance.assertDomainBound(address(lenient), address(aggA), address(aggB), 78, guardians, proof);

        (bool ok, bytes memory ret) = address(this).staticcall(
            abi.encodeWithSelector(
                this.callAssertSetBound.selector, address(lenient), address(aggA), uint256(78), guardians, proof
            )
        );
        assertFalse(ok, "a superset-lenient verifier must not pass assertSetBound");
        assertEq(bytes4(ret), Conformance.VerifierAcceptsGuardianSuperset.selector);
    }

    /// A verifier that rejects everything must not be mistaken for "set bound" either.
    function test_AlwaysFalseVerifierFailsSetBound() public {
        DomainBoundFraudProofVerifier other = new DomainBoundFraudProofVerifier(keccak256("different attester"));
        bytes memory proof = _proofForA(44);
        vm.expectRevert(
            abi.encodeWithSelector(
                Conformance.VerifierRejectedItsOwnGuardianSet.selector,
                address(other),
                keccak256(abi.encode(guardians))
            )
        );
        this.callAssertSetBound(address(other), address(aggA), 44, guardians, proof);
    }

    /// A one-element accused set has no non-empty strict subset, so the fixture would be
    /// silently weaker than it looks. It refuses instead of pretending to have checked.
    function test_SetBoundRefusesASingleGuardianSet() public {
        address[] memory single = new address[](1);
        single[0] = guardians[0];
        vm.expectRevert(
            abi.encodeWithSelector(Conformance.SetBoundNeedsAtLeastTwoGuardians.selector, uint256(1))
        );
        this.callAssertSetBound(address(good), address(aggA), 45, single, hex"00");
    }

    /// The synthetic addresses the fixture invents for the superset/unrelated cases must
    /// never collide with the real accused set — otherwise assertion (3)/(4) could be
    /// testing the committed set against itself.
    function test_SyntheticGuardiansNeverCollideWithTheAccusedSet() public view {
        // A three-element set exercises subset generation as well.
        address[] memory three = new address[](3);
        three[0] = guardians[0];
        three[1] = guardians[1];
        three[2] = address(0x9003);
        bytes memory proof = good.attest(aggA.fraudProofDigest(46, three), 46, three);
        Conformance.assertSetBound(address(good), address(aggA), 46, three, proof);
    }

    function callAssertSetBound(
        address verifier,
        address aggregator,
        uint256 id,
        address[] memory g,
        bytes memory proof
    ) external view {
        Conformance.assertSetBound(verifier, aggregator, id, g, proof);
    }

    function callAssertDomainBound(
        address verifier,
        address a,
        address b,
        uint256 id,
        address[] memory g,
        bytes memory proof
    ) external view {
        Conformance.assertDomainBound(verifier, a, b, id, g, proof);
    }
}
