// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {GToken} from "src/tokens/GToken.sol";
import {GTokenStaking} from "src/core/GTokenStaking.sol";
import {MySBT} from "src/tokens/MySBT.sol";
import {Registry} from "src/core/Registry.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {BLS} from "src/utils/BLS.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @dev Minimal DVT sink: BLSAggregator rejects a zero DVT_VALIDATOR and makes a
///      typed call into it after execution, so the address must hold code.
contract DomainReplayDVTStub {
    function markProposalExecuted(uint256) external {}
}

/**
 * @title RepCreditDomainReplay
 * @notice CC-48 round-2: real-pairing proof that a BLS proof is bound to ONE
 *         (domain name, chain, aggregator, registry) tuple and to ONE path tag.
 *
 * @dev No precompile injection and no stubbed pairing. Keys and signatures are
 *      produced with the Prague EIP-2537 G1/G2 MSM precompiles and verified by the
 *      production BLSAggregator, so a "replay fails" assertion here means the
 *      pairing equation genuinely does not hold — not that a mock said no.
 *
 *      Run:
 *        forge test --evm-version prague --match-contract RepCreditDomainReplay -vv
 *
 *      The default Cancun suite skips these (EIP-2537 unavailable). The
 *      encoding-only half of the same properties runs unconditionally in
 *      contracts/test/security/CC48DomainSeparation.t.sol.
 *
 *      Secret scalars 1..N are used ONLY as test vectors. They are public
 *      knowledge and must never appear in a deployment — see the migration note
 *      in the CC-48 thread on the compromised experiment stack.
 */
contract RepCreditDomainReplay is Test {
    uint256 internal constant VALIDATOR_COUNT = 5;
    uint256 internal constant DVT_STAKE = 30 ether;
    bytes32 internal constant ROLE_DVT = keccak256("DVT");

    bytes32 internal constant DOMAIN_NAME = keccak256("SuperPaymaster.BLSConsensus.v1");
    bytes32 internal constant TAG_REPUTATION = keccak256("SuperPaymaster.BLS.Reputation.v1");
    bytes32 internal constant TAG_PROPOSAL = keccak256("SuperPaymaster.BLS.Proposal.v1");
    bytes32 internal constant TAG_QUEUE_SLASH = keccak256("SuperPaymaster.BLS.QueueSlash.v1");
    bytes32 internal constant TAG_POP = keccak256("SuperPaymaster.BLS.PoP.v1");

    bool internal pragueAvailable;
    GToken internal gtoken;
    GTokenStaking internal staking;
    MySBT internal sbt;
    Registry internal registry;

    /// Two aggregators, SAME chain, SAME Registry, SAME validator addresses, SAME
    /// keys, SAME slots. Everything an attacker could copy is identical; only the
    /// contract address differs. Pre-fix that meant byte-identical pre-images.
    BLSAggregator internal aggA;
    BLSAggregator internal aggB;
    DomainReplayDVTStub internal dvtSink;

    address[VALIDATOR_COUNT] internal validators;
    uint256[VALIDATOR_COUNT] internal secretScalars;

    function setUp() public {
        pragueAvailable = _hasPraguePrecompiles();
        if (!pragueAvailable) return;

        vm.warp(1_800_000_000);
        gtoken = new GToken(21_000_000 ether);
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(0));
        staking = new GTokenStaking(address(gtoken), address(this), address(registry));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), address(this));
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));

        dvtSink = new DomainReplayDVTStub();
        aggA = new BLSAggregator(address(registry), address(0xBEEF), address(dvtSink));
        aggB = new BLSAggregator(address(registry), address(0xBEEF), address(dvtSink));

        registry.setBLSAggregator(address(aggA));
        registry.setReputationSource(address(aggA), true);
        registry.setReputationSource(address(aggB), true);
        registry.setCreditTier(1, 0);
        registry.setCreditPolicy(type(uint256).max, type(uint256).max, 0, false);

        for (uint256 i = 0; i < VALIDATOR_COUNT; ++i) {
            aggA.setMinThreshold(2);
            aggB.setMinThreshold(2);
            address validator = address(uint160(0x1000 + i));
            uint256 scalar = i + 1;
            validators[i] = validator;
            secretScalars[i] = scalar;

            gtoken.mint(validator, 40 ether);
            vm.startPrank(validator);
            gtoken.approve(address(staking), 40 ether);
            registry.registerRole(ROLE_DVT, validator, abi.encode(DVT_STAKE));
            vm.stopPrank();

            // CC-48 round-3: PoP is mandatory on the owner path too, and it is bound to
            // (domain, validator, key) — so the SAME key needs a DIFFERENT signature on
            // each aggregator. That is the migration cost the release notes describe,
            // demonstrated here rather than asserted.
            BLS.G1Point memory pk = _publicKey(scalar);
            aggA.registerBLSPublicKey(validator, pk, uint8(i + 1), _pop(aggA, validator, pk, scalar));
            aggB.registerBLSPublicKey(validator, pk, uint8(i + 1), _pop(aggB, validator, pk, scalar));
        }
        aggA.setDefaultThreshold(3);
        aggB.setDefaultThreshold(3);
    }

    // =================================================================
    // Cross-contract replay — the finding
    // =================================================================

    /// Reputation path. A quorum signs a batch for aggA; the identical proof bytes
    /// and identical fields are then submitted to aggB. Same chain, same keys, same
    /// slots, same Registry — only the aggregator differs, and the pairing fails.
    function test_ReputationProofDoesNotReplayToAnotherAggregator() public {
        _skipWithoutPrague();
        (address[] memory users, uint256[] memory scores) = _batch(address(0xCAFE), 50);
        uint256 epoch = 1;

        bytes32 hashA = _reputationHash(address(aggA), address(registry), block.chainid, 9001, users, scores, epoch);
        bytes memory proof = _proof(hashA, 3);

        // Sanity: the proof IS valid where it was made.
        aggA.verifyAndExecute(9001, address(0), 0, users, scores, epoch, bytes32(0), proof);
        assertEq(registry.globalReputation(address(0xCAFE)), 50);

        // Replay verbatim onto aggB (a distinct proposalId so we are testing the
        // domain, not the executedProposals replay guard).
        bytes32 hashAForNewId =
            _reputationHash(address(aggA), address(registry), block.chainid, 9002, users, scores, epoch + 1);
        bytes memory proofForNewId = _proof(hashAForNewId, 3);

        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        aggB.verifyAndExecute(9002, address(0), 0, users, scores, epoch + 1, bytes32(0), proofForNewId);
    }

    /// Generic proposal path — the same property, on the path with a caller-chosen
    /// threshold. Included because "we only fixed slash" was the round-2 objection.
    function test_GenericProposalProofDoesNotReplayToAnotherAggregator() public {
        _skipWithoutPrague();
        bytes memory callData = abi.encodeWithSignature("noop()");
        bytes32 hashA = keccak256(
            abi.encode(
                _domain(address(aggA), address(registry), block.chainid),
                TAG_PROPOSAL,
                uint256(7001),
                address(0xD00D),
                keccak256(callData),
                uint256(3)
            )
        );
        bytes memory proof = _proof(hashA, 3);

        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        aggB.executeProposal(7001, address(0xD00D), callData, 3, proof);
    }

    /// Queue-slash path — same property again. Every quorum-gated entry, not one.
    function test_QueueSlashProofDoesNotReplayToAnotherAggregator() public {
        _skipWithoutPrague();
        bytes32 hashA = keccak256(
            abi.encode(
                _domain(address(aggA), address(registry), block.chainid),
                TAG_QUEUE_SLASH,
                address(0xBAD),
                uint8(1),
                uint256(42)
            )
        );
        bytes memory proof = _proof(hashA, 3);

        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        aggB.queueSlashWithConsensus(address(0xBAD), 1, 42, proof);
    }

    // =================================================================
    // Domain field-by-field negatives
    // =================================================================

    function test_WrongChainIdInDomainFails() public {
        _skipWithoutPrague();
        _expectReputationRejected(
            _reputationHash(address(aggA), address(registry), block.chainid + 1, 9101, _users(), _scores(), 1)
        );
    }

    function test_WrongAggregatorInDomainFails() public {
        _skipWithoutPrague();
        _expectReputationRejected(
            _reputationHash(address(aggB), address(registry), block.chainid, 9102, _users(), _scores(), 1)
        );
    }

    function test_WrongRegistryInDomainFails() public {
        _skipWithoutPrague();
        _expectReputationRejected(
            _reputationHash(address(aggA), address(0xDEAD), block.chainid, 9103, _users(), _scores(), 1)
        );
    }

    function test_WrongDomainNameFails() public {
        _skipWithoutPrague();
        bytes32 wrongDomain = keccak256(
            abi.encode(
                keccak256("SuperPaymaster.BLSConsensus.v2"), block.chainid, address(aggA), address(registry)
            )
        );
        _expectReputationRejected(
            keccak256(abi.encode(wrongDomain, TAG_REPUTATION, uint256(9104), _users(), _scores(), uint256(1)))
        );
    }

    /// Right domain, WRONG path tag: a proposal signature is not a reputation
    /// signature even with identical fields.
    function test_WrongPathTagFails() public {
        _skipWithoutPrague();
        _expectReputationRejected(
            keccak256(
                abi.encode(
                    _domain(address(aggA), address(registry), block.chainid),
                    TAG_PROPOSAL,
                    uint256(9105),
                    _users(),
                    _scores(),
                    uint256(1)
                )
            )
        );
    }

    /// The pre-fix encoding itself, replayed against the fixed contract. This is the
    /// concrete regression guard: an old signature does not survive the upgrade.
    function test_LegacyPreImageIsNoLongerAccepted() public {
        _skipWithoutPrague();
        _expectReputationRejected(
            keccak256(abi.encode(uint256(9106), address(0), uint8(0), _users(), _scores(), uint256(1), block.chainid))
        );
    }

    /// The domain is layered ON TOP of field binding, not instead of it.
    function test_FieldsStillBindWithinOneDomain() public {
        _skipWithoutPrague();
        _expectReputationRejected(
            _reputationHash(address(aggA), address(registry), block.chainid, 9107, _users(), _scores(), 99)
        );
    }

    // =================================================================
    // Registry's independent re-verification agrees byte-for-byte
    // =================================================================

    /// Registry re-derives the separator locally. If it drifted from the aggregator
    /// by a single byte, every reputation proposal would die here with BLSFailed —
    /// so a passing execution is the parity proof on the live path.
    function test_RegistryReVerificationAcceptsTheAggregatorPreImage() public {
        _skipWithoutPrague();
        assertEq(registry.blsDomainSeparator(), aggA.domainSeparator());

        (address[] memory users, uint256[] memory scores) = _batch(address(0xF00D), 60);
        bytes32 h = _reputationHash(address(aggA), address(registry), block.chainid, 9201, users, scores, 1);
        aggA.verifyAndExecute(9201, address(0), 0, users, scores, 1, bytes32(0), _proof(h, 3));
        assertEq(registry.globalReputation(address(0xF00D)), 60);
    }

    /// Direct Registry entry (no aggregator in the middle) must accept exactly the
    /// same pre-image — this is the path an indexer/SDK builds by hand.
    function test_DirectRegistryCallUsesTheSameSchema() public {
        _skipWithoutPrague();
        (address[] memory users, uint256[] memory scores) = _batch(address(0xF11D), 40);
        bytes32 h = _reputationHash(address(aggA), address(registry), block.chainid, 9202, users, scores, 1);
        registry.setReputationSource(address(this), true);
        registry.batchUpdateGlobalReputation(9202, users, scores, 1, _proof(h, 3));
        assertEq(registry.globalReputation(address(0xF11D)), 40);
    }

    /// Repointing Registry at a different aggregator changes Registry's domain, so
    /// a proof minted under the old wiring stops verifying. Governance rotating the
    /// aggregator invalidates in-flight proofs — stated here as an executable fact
    /// because it is an operational constraint on the upgrade batch.
    function test_RepointingRegistryInvalidatesInFlightProofs() public {
        _skipWithoutPrague();
        (address[] memory users, uint256[] memory scores) = _batch(address(0xF22D), 30);
        bytes32 h = _reputationHash(address(aggA), address(registry), block.chainid, 9203, users, scores, 1);
        bytes memory proof = _proof(h, 3);

        registry.setBLSAggregator(address(aggB));
        registry.setReputationSource(address(this), true);

        vm.expectRevert(Registry.BLSFailed.selector);
        registry.batchUpdateGlobalReputation(9203, users, scores, 1, proof);
    }

    // =================================================================
    // Proof of possession — validator binding + duplicate key
    // =================================================================

    /// A real, valid PoP filed by v0 cannot be lifted out of its public calldata and
    /// reused by another address: the digest commits to the registrant.
    function test_PoPCannotBeLiftedByAnotherValidator() public {
        _skipWithoutPrague();
        BLSAggregator agg = _freshAggregatorWithPermissionlessRegistration();
        address v0 = validators[0];
        address v1 = validators[1];
        BLS.G1Point memory pk = _publicKey(secretScalars[0]);

        BLS.G2Point memory popForV0 = _pop(agg, v0, pk, secretScalars[0]);

        // v0 registers its own key — the honest path still works.
        vm.prank(v0);
        agg.registerBLSPublicKey(v0, pk, 1, popForV0);
        (, uint8 slot, bool active) = agg.getBLSPublicKey(v0);
        assertEq(slot, 1);
        assertTrue(active);

        // v1 lifts v0's PoP verbatim for its OWN key: the digest binds v1, so the
        // pairing fails against v0's signature.
        BLS.G1Point memory pkV1 = _publicKey(secretScalars[1]);
        vm.prank(v1);
        vm.expectRevert(BLSAggregator.InvalidPoP.selector);
        agg.registerBLSPublicKey(v1, pkV1, 2, popForV0);
    }

    /// Address binding alone is not enough: one operator holding two ROLE_DVT
    /// addresses AND one secret key can mint a genuinely valid PoP for the second
    /// address over the same key. Only the key-to-owner binding stops that, and
    /// this is the forgery it prevents — pkAgg over N such slots is N*pk, which the
    /// single sk holder can sign as N*sk*H(m).
    function test_OneKeyCannotBeSplitAcrossTwoValidatorsEvenWithValidPoPs() public {
        _skipWithoutPrague();
        BLSAggregator agg = _freshAggregatorWithPermissionlessRegistration();
        address v0 = validators[0];
        address v1 = validators[1];
        uint256 sk = secretScalars[0];
        BLS.G1Point memory pk = _publicKey(sk);

        vm.prank(v0);
        agg.registerBLSPublicKey(v0, pk, 1, _pop(agg, v0, pk, sk));

        // A genuinely valid PoP for v1 over the SAME key — the same person owns sk.
        BLS.G2Point memory popForV1 = _pop(agg, v1, pk, sk);
        bytes32 keyHash = keccak256(abi.encode(pk.x_a, pk.x_b, pk.y_a, pk.y_b));

        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.DuplicatePublicKey.selector, keyHash, v0));
        agg.registerBLSPublicKey(v1, pk, 2, popForV1);

        assertEq(agg.validatorAtSlot(2), address(0), "no second slot may be bound to the same key");
    }

    /// A PoP is aggregator-scoped too, so an operator cannot recycle the PoP it
    /// published on the compromised experiment deployment into a fresh one.
    function test_PoPDoesNotCarryAcrossAggregators() public {
        _skipWithoutPrague();
        BLSAggregator first = _freshAggregatorWithPermissionlessRegistration();
        BLSAggregator second = _freshAggregatorWithPermissionlessRegistration();
        address v0 = validators[0];
        BLS.G1Point memory pk = _publicKey(secretScalars[0]);

        BLS.G2Point memory popForFirst = _pop(first, v0, pk, secretScalars[0]);
        vm.prank(v0);
        first.registerBLSPublicKey(v0, pk, 1, popForFirst);

        vm.prank(v0);
        vm.expectRevert(BLSAggregator.InvalidPoP.selector);
        second.registerBLSPublicKey(v0, pk, 1, popForFirst);

        // Re-signing under the new contract's domain is the intended migration.
        vm.prank(v0);
        second.registerBLSPublicKey(v0, pk, 1, _pop(second, v0, pk, secretScalars[0]));
        (, , bool active) = second.getBLSPublicKey(v0);
        assertTrue(active);
    }

    // =================================================================
    // Helpers
    // =================================================================

    function _freshAggregatorWithPermissionlessRegistration() internal returns (BLSAggregator agg) {
        agg = new BLSAggregator(address(registry), address(0xBEEF), address(dvtSink));
        agg.setPermissionlessBLSRegistration(true);
    }

    function _pop(BLSAggregator agg, address validator, BLS.G1Point memory pk, uint256 sk)
        internal
        view
        returns (BLS.G2Point memory)
    {
        return _multiplyG2(BLS.hashToG2(abi.encodePacked(agg.popDigest(validator, pk))), sk);
    }

    function _expectReputationRejected(bytes32 badHash) internal {
        bytes memory proof = _proof(badHash, 3);
        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        aggA.verifyAndExecute(9999, address(0), 0, _users(), _scores(), 1, bytes32(0), proof);
    }

    function _domain(address agg, address reg, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_NAME, chainId, agg, reg));
    }

    function _reputationHash(
        address agg,
        address reg,
        uint256 chainId,
        uint256 proposalId,
        address[] memory users,
        uint256[] memory scores,
        uint256 epoch
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_domain(agg, reg, chainId), TAG_REPUTATION, proposalId, users, scores, epoch));
    }

    function _users() internal pure returns (address[] memory users) {
        users = new address[](1);
        users[0] = address(0xA11CE);
    }

    function _scores() internal pure returns (uint256[] memory scores) {
        scores = new uint256[](1);
        scores[0] = 50;
    }

    function _batch(address user, uint256 score)
        internal
        pure
        returns (address[] memory users, uint256[] memory scores)
    {
        users = new address[](1);
        scores = new uint256[](1);
        users[0] = user;
        scores[0] = score;
    }

    function _hasPraguePrecompiles() internal view returns (bool) {
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = address(0x0B).staticcall(twoIdentities);
        return ok && result.length == 128;
    }

    function _skipWithoutPrague() internal {
        if (!pragueAvailable) vm.skip(true);
    }

    function _proof(bytes32 messageHash, uint256 signerCount) internal view returns (bytes memory) {
        BLS.G2Point memory aggregateSignature;
        BLS.G2Point memory messagePoint = BLS.hashToG2(abi.encodePacked(messageHash));
        for (uint256 i = 0; i < signerCount; ++i) {
            BLS.G2Point memory partialSignature = _multiplyG2(messagePoint, secretScalars[i]);
            aggregateSignature = i == 0 ? partialSignature : BLS.add(aggregateSignature, partialSignature);
        }
        return abi.encode((uint256(1) << signerCount) - 1, abi.encode(aggregateSignature));
    }

    function _publicKey(uint256 scalar) internal view returns (BLS.G1Point memory) {
        BLS.G1Point[] memory points = new BLS.G1Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = _g1Generator();
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function _multiplyG2(BLS.G2Point memory point, uint256 scalar) internal view returns (BLS.G2Point memory) {
        BLS.G2Point[] memory points = new BLS.G2Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = point;
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function _g1Generator() internal pure returns (BLS.G1Point memory generator) {
        generator.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        generator.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        generator.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        generator.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }
}
