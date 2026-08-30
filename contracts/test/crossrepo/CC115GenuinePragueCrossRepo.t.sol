// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {BLS} from "src/utils/BLS.sol";
import {FraudProofVerifierConformance as Conformance} from "../helpers/FraudProofVerifierConformance.sol";
import {OverIssueFraudProofVerifier} from "./vendor/OverIssueFraudProofVerifier.sol";
import {XRegistry, XStaking, XDVT, XSP, XToken} from "./CC115CrossRepoConformance.t.sol";

/**
 * @title CC115GenuinePragueCrossRepo
 * @notice CC-115 B0: ONE execution path that is simultaneously cross-repo and genuinely
 *         cryptographic. Not two half-proofs stapled together.
 *
 * @dev    WHY THIS FILE EXISTS. CC-115 comment 28 (repo:dsr, 2026-08-29T17:05Z) refused to
 *         tick B0 because the repository held two disjoint halves:
 *
 *           - `CC115CrossRepoConformance` — real `BLSAggregator` + the real merged DVT
 *             `OverIssueFraudProofVerifier`, but pairing is `vm.mockCall`ed to a constant
 *             `1` and the keys are `bytes32(seed)` stubs that are not on the curve. It
 *             passes 7/7 on Cancun and steps aside entirely on Prague (0 pass / 1 skip),
 *             because `vm.etch` cannot overwrite a real precompile.
 *           - `paper7/RepCreditPragueE2E` — real EIP-2537, real keys, real PoP, real
 *             aggregate signatures, 6/6 on Prague, but the verifier in its path is SP's
 *             own `DVTValidator`. The DVT repository's verifier never appears.
 *
 *         Neither half can be promoted into the other's claim: the first never runs a
 *         pairing, the second never touches DVT's contract. This suite is the
 *         intersection, and it is the intersection that B0 asks for.
 *
 *         WHAT IS REAL HERE, all in one `setUp`:
 *           - `BLSAggregator` is the production contract, deployed, not stubbed;
 *           - the verifier is `vendor/OverIssueFraudProofVerifier.sol`, the vendored copy
 *             of DVT master @ 8395c94c (PR #240, released as v1.15.0), byte-checked
 *             against upstream by `VendoredProvenanceSelfCheck` in this same directory;
 *           - public keys are `sk * G1` computed by the real G1 MSM precompile;
 *           - proofs-of-possession are `sk * H_pop(popDigest)` on the real G2 precompiles;
 *           - the slash proof is a real aggregate signature `(Σ sk_i) * H(m)` over the
 *             message `verifyAndExecute` actually reconstructs;
 *           - `verifyAndExecute` performs a real pairing check, and only then writes
 *             `proposalSignersCommitment`, which is the anchor the DVT verifier
 *             independently recomputes.
 *
 *         There is NO `vm.etch`, NO `vm.mockCall`, and no synthetic curve point anywhere
 *         in this file. That is the property the file is for, so it is asserted rather
 *         than merely intended — see `test_GenuinePrague_PrecompilesAreRealNotInjected`.
 *
 *         THE CONTROL THAT MATTERS. Under mocked pairing every signature verifies, so a
 *         green run says nothing about signature validity — the instrument cannot produce
 *         a failing reading. `test_GenuinePrague_WrongAggregateSignatureIsRejected` and
 *         `test_GenuinePrague_BelowThresholdIsRejected` are the readings that prove this
 *         one can: both are impossible to fail-check in the mocked suite and both must be
 *         red if the pairing here were stubbed.
 *
 *         The scaffolding contracts (`XRegistry`, `XStaking`, `XDVT`, `XSP`, `XToken`) are
 *         imported from `CC115CrossRepoConformance.t.sol` rather than re-declared, so the
 *         ONLY difference between the mocked suite and this one is the cryptography. A
 *         divergence in the harness could otherwise explain a divergence in the result.
 *
 * Run:
 *   forge test --evm-version prague --match-contract CC115GenuinePragueCrossRepo -vv
 *
 * On Cancun the EIP-2537 precompiles do not exist, so every test skips by design; the
 * Prague command above is the gate. Skipping is never silently green here — see
 * `test_GenuinePrague_PrecompilesAreRealNotInjected`.
 */
contract CC115GenuinePragueCrossRepo is Test {
    BLSAggregator internal aggA;
    BLSAggregator internal aggB;
    XRegistry internal registry;
    XStaking internal staking;
    XToken internal token;
    OverIssueFraudProofVerifier internal verifier;

    address internal owner = address(0x0BEE);
    uint256 internal constant MIN_STAKE = 30 ether;

    /// Slots 1..7, already ascending by uint160 — the order SP's commitment sorts into.
    address[7] internal validators = [
        address(0x101), address(0x102), address(0x103), address(0x104), address(0x105), address(0x106), address(0x107)
    ];
    /// Secret scalars 1..7; public key i is `secretScalars[i] * G1`.
    uint256[7] internal secretScalars = [uint256(1), 2, 3, 4, 5, 6, 7];

    // the disputed proposal — same coordinates as the mocked suite, deliberately
    uint256 internal constant PID = 4242;
    address internal constant OPERATOR = address(0xABCD);
    uint8 internal constant SLASH_LEVEL = 1; // MINOR — threshold 3, mask 0x7F gives 7
    uint256 internal constant EPOCH = 100;
    uint256 internal constant MASK = 0x7F;

    address[] internal guardians;
    bool internal pragueAvailable;

    function setUp() public {
        pragueAvailable = _hasPraguePrecompiles();
        if (!pragueAvailable) return;

        // Sepolia, because a domain separator that only differs by chainid is the WEAK
        // replay case; aggA and aggB below differ only by ADDRESS, which is the hard one.
        vm.chainId(11155111);

        staking = new XStaking();
        registry = new XRegistry(MIN_STAKE);
        registry.setStaking(address(staking));
        token = new XToken();

        vm.startPrank(owner);
        XDVT dvt = new XDVT();
        XSP sp = new XSP();
        aggA = new BLSAggregator(address(registry), address(sp), address(dvt));
        aggB = new BLSAggregator(address(registry), address(sp), address(dvt));
        for (uint8 i = 0; i < 7; i++) {
            BLS.G1Point memory pk = _publicKey(secretScalars[i]);
            // Genuine PoP on the real precompiles: mandatory on both registration paths
            // since CC-48 round-3, and the owner path is no exception.
            aggA.registerBLSPublicKey(validators[i], pk, i + 1, _pop(aggA, validators[i], pk, secretScalars[i]));
        }
        vm.stopPrank();
        for (uint8 i = 0; i < 7; i++) {
            staking.setLock(validators[i], uint128(MIN_STAKE));
            guardians.push(validators[i]);
        }

        // The real DVT verifier, bound to aggA and this Registry.
        verifier = new OverIssueFraudProofVerifier(address(aggA), address(registry));

        // Drive SP's OWN consensus path with a REAL aggregate signature, so the anchor
        // the verifier will later recompute is written behind a real pairing check.
        // Resolve the evidence hash before the prank: it is an external call, and leaving
        // it in the argument list would consume the prank.
        bytes32 evidence = verifier.evidenceHash(address(token), OPERATOR, EPOCH);
        bytes memory blsProof = _slashProof(evidence, MASK);
        vm.prank(owner);
        aggA.verifyAndExecute(PID, OPERATOR, SLASH_LEVEL, new address[](0), new uint256[](0), EPOCH, evidence, blsProof);
    }

    // ==========================================================
    // 0. The instrument itself
    // ==========================================================

    /// The whole point of this file is that the curve arithmetic is real. If the suite
    /// ever runs somewhere it is not, that must be a skip, never a silent pass.
    function test_GenuinePrague_PrecompilesAreRealNotInjected() public {
        _skipWithoutPrague();
        assertTrue(_hasPraguePrecompiles(), "EIP-2537 G1ADD must answer with 128 bytes");
        // `vm.etch` leaves code at the address; a genuine precompile has none. This does
        // not by itself prove pairing is unmocked — the behavioural proof of that is
        // `test_GenuinePrague_WrongAggregateSignatureIsRejected`, which cannot pass if
        // pairing returns a constant.
        assertEq(address(0x0b).code.length, 0, "G1ADD must not carry injected code");
        assertEq(address(0x0c).code.length, 0, "G1MSM must not carry injected code");
        assertEq(address(0x0d).code.length, 0, "G2ADD must not carry injected code");
        assertEq(address(0x0f).code.length, 0, "PAIRING must not carry injected code");
        assertEq(address(0x10).code.length, 0, "MAP_FP_TO_G1 must not carry injected code");
        assertEq(address(0x11).code.length, 0, "MAP_FP2_TO_G2 must not carry injected code");
    }

    // ==========================================================
    // 1. The two release gates, against the real DVT verifier,
    //    on an anchor written behind a real pairing
    // ==========================================================

    function test_GenuinePrague_RealDvtVerifierPassesAssertDomainBound() public {
        _skipWithoutPrague();
        Conformance.assertDomainBound(
            address(verifier), address(aggA), address(aggB), _fraudProofId(), guardians, _fraudProof()
        );
    }

    function test_GenuinePrague_RealDvtVerifierPassesAssertSetBound() public {
        _skipWithoutPrague();
        Conformance.assertSetBound(address(verifier), address(aggA), _fraudProofId(), guardians, _fraudProof());
    }

    // ==========================================================
    // 2. Encoding parity across the two repositories
    // ==========================================================

    function test_GenuinePrague_DomainSeparatorParityWithRealAggregator() public {
        _skipWithoutPrague();
        assertEq(verifier.domainSeparator(), aggA.domainSeparator(), "verifier rebuilds aggA's domain");
        assertTrue(aggA.domainSeparator() != aggB.domainSeparator(), "siblings must not share a domain");
        assertTrue(verifier.domainSeparator() != aggB.domainSeparator(), "and the verifier is bound to aggA");
    }

    function test_GenuinePrague_FraudProofDigestParityAcrossIdsAndSets() public {
        _skipWithoutPrague();
        uint256[3] memory ids = [uint256(1), _fraudProofId(), type(uint256).max];
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(
                verifier.expectedFraudProofDigest(ids[i], guardians),
                aggA.fraudProofDigest(ids[i], guardians),
                "digest parity over the full accused set"
            );
            address[] memory two = new address[](2);
            two[0] = guardians[0];
            two[1] = guardians[1];
            assertEq(
                verifier.expectedFraudProofDigest(ids[i], two),
                aggA.fraudProofDigest(ids[i], two),
                "digest parity over a two-address set"
            );
        }
    }

    /// The inner layer, non-circularly and now non-synthetically: the anchor was written
    /// by SP's own `_computeSignersCommitment` inside a `verifyAndExecute` that had to
    /// clear a genuine pairing first, and the verifier reaches it only by reconstructing
    /// slash message + commitment from the proof's raw fields.
    function test_GenuinePrague_InnerCommitmentLayoutParityAgainstRealAggregatorWrite() public {
        _skipWithoutPrague();
        assertTrue(aggA.proposalSignersCommitment(PID) != bytes32(0), "SP wrote a real anchor");
        assertTrue(
            verifier.verify(
                aggA.fraudProofDigest(_fraudProofId(), guardians), _fraudProofId(), guardians, _fraudProof()
            ),
            "the real verifier reproduces SP's real commitment"
        );
    }

    function test_GenuinePrague_OverIssuedTokenFlipsTheSameProofToRejected() public {
        _skipWithoutPrague();
        bytes32 digest = aggA.fraudProofDigest(_fraudProofId(), guardians);
        assertTrue(verifier.verify(digest, _fraudProofId(), guardians, _fraudProof()), "accepted while not over-issued");
        token.setOverIssued(true);
        assertFalse(verifier.verify(digest, _fraudProofId(), guardians, _fraudProof()), "rejected once over-issued");
    }

    function test_GenuinePrague_LegacyThreeParamSelectorIsAbsent() public {
        _skipWithoutPrague();
        assertEq(
            bytes4(keccak256("verify(bytes32,uint256,address[],bytes)")),
            bytes4(0x61077735),
            "SP expects the four-parameter selector CC-115 pinned"
        );
        (bool ok,) = address(verifier)
            .staticcall(
                abi.encodeWithSelector(
                    bytes4(keccak256("verify(uint256,address[],bytes)")), uint256(1), guardians, bytes("")
                )
            );
        assertFalse(ok, "the obsolete three-parameter entry point must not exist");
    }

    // ==========================================================
    // 3. Negative controls that only a real pairing can run
    // ==========================================================

    /// THE control for this suite. A structurally valid aggregate signature over a
    /// DIFFERENT message must not clear `verifyAndExecute`. Under the mocked suite's
    /// `vm.mockCall(0x0F, "", 1)` this test is unwritable: every signature verifies, so
    /// the mocked 7/7 carries no information about signature validity at all.
    function test_GenuinePrague_WrongAggregateSignatureIsRejected() public {
        _skipWithoutPrague();
        uint256 otherPid = PID + 1;
        bytes32 evidence = verifier.evidenceHash(address(token), OPERATOR, EPOCH);
        // A real aggregate signature — over the wrong proposal id.
        bytes memory wrongProof =
            _proofOverDigest(_slashMessageHash(otherPid, OPERATOR, SLASH_LEVEL, EPOCH, evidence), MASK);
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        aggA.verifyAndExecute(
            otherPid + 1, OPERATOR, SLASH_LEVEL, new address[](0), new uint256[](0), EPOCH, evidence, wrongProof
        );
    }

    /// The severity table is load-bearing only if a genuine signature by too few
    /// validators is still refused. MINOR requires 3; two real signers must not pass.
    function test_GenuinePrague_BelowThresholdIsRejected() public {
        _skipWithoutPrague();
        uint256 pid = PID + 10;
        bytes32 evidence = verifier.evidenceHash(address(token), OPERATOR, EPOCH);
        bytes memory twoSigners = _proofOverDigest(_slashMessageHash(pid, OPERATOR, SLASH_LEVEL, EPOCH, evidence), 0x3);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidSignatureCount.selector, uint256(2), uint256(3)));
        aggA.verifyAndExecute(
            pid, OPERATOR, SLASH_LEVEL, new address[](0), new uint256[](0), EPOCH, evidence, twoSigners
        );
    }

    // ==========================================================
    // 4. Negative controls on the inner layout the verifier rebuilds
    // ==========================================================

    /// Each field of the fraud proof feeds the commitment recompute. Perturbing any one
    /// of them must break the match — otherwise the "parity" above would be satisfied by
    /// a verifier that reads fewer fields than it claims to.
    function test_GenuinePrague_ObsoleteOrPerturbedInnerLayoutIsRejected() public {
        _skipWithoutPrague();
        bytes32 digest = aggA.fraudProofDigest(_fraudProofId(), guardians);
        uint256 id = _fraudProofId();

        assertTrue(verifier.verify(digest, id, guardians, _fraudProof()), "baseline accepted");

        assertFalse(
            verifier.verify(
                digest,
                id,
                guardians,
                abi.encode(PID, OPERATOR, SLASH_LEVEL, EPOCH + 1, address(token), MASK, guardians)
            ),
            "a different epoch must not reproduce the commitment"
        );
        assertFalse(
            verifier.verify(
                digest,
                id,
                guardians,
                abi.encode(PID, address(0xDEAD), SLASH_LEVEL, EPOCH, address(token), MASK, guardians)
            ),
            "a different operator must not reproduce the commitment"
        );
        assertFalse(
            verifier.verify(
                digest, id, guardians, abi.encode(PID, OPERATOR, uint8(2), EPOCH, address(token), MASK, guardians)
            ),
            "a different slash level must not reproduce the commitment"
        );
        assertFalse(
            verifier.verify(
                digest,
                id,
                guardians,
                abi.encode(PID, OPERATOR, SLASH_LEVEL, EPOCH, address(token), uint256(0x3F), guardians)
            ),
            "a different signer mask must not reproduce the commitment"
        );
        assertFalse(
            verifier.verify(
                digest, id, guardians, abi.encode(PID, OPERATOR, SLASH_LEVEL, EPOCH, address(0xBEEF), MASK, guardians)
            ),
            "a different disputed token must not reproduce the commitment"
        );
    }

    // ---- helpers ----
    function _hasPraguePrecompiles() internal view returns (bool) {
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = address(0x0B).staticcall(twoIdentities);
        return ok && result.length == 128;
    }

    function _skipWithoutPrague() internal {
        if (!pragueAvailable) vm.skip(true);
    }

    function _fraudProofId() internal view returns (uint256) {
        return verifier.deriveFraudProofId(PID);
    }

    /// DVT's proof ABI: (proposalId, operator, slashLevel, epoch, disputedToken,
    /// signerMask, claimedSigners).
    function _fraudProof() internal view returns (bytes memory) {
        return abi.encode(PID, OPERATOR, SLASH_LEVEL, EPOCH, address(token), MASK, guardians);
    }

    /// SP's slash pre-image, reconstructed field-by-field rather than read off the
    /// aggregator, so a silent schema drift in the contract shows up here as a failing
    /// signature rather than as a quietly-agreeing pair of copies.
    function _slashMessageHash(uint256 proposalId, address operator, uint8 slashLevel, uint256 epoch, bytes32 evidence)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                keccak256(
                    abi.encode(
                        keccak256("SuperPaymaster.BLSConsensus.v1"), block.chainid, address(aggA), address(registry)
                    )
                ),
                keccak256("SuperPaymaster.BLS.ExecuteSlash.v1"),
                proposalId,
                operator,
                slashLevel,
                epoch,
                evidence
            )
        );
    }

    function _slashProof(bytes32 evidence, uint256 mask) internal view returns (bytes memory) {
        return _proofOverDigest(_slashMessageHash(PID, OPERATOR, SLASH_LEVEL, EPOCH, evidence), mask);
    }

    /// A genuine aggregate signature: `(Σ_{i in mask} sk_i) * H(messageHash)`, built one
    /// partial signature at a time on the real G2 precompiles and summed with real G2 add.
    function _proofOverDigest(bytes32 messageHash, uint256 mask) internal view returns (bytes memory) {
        BLS.G2Point memory aggregateSignature;
        BLS.G2Point memory messagePoint = BLS.hashToG2(abi.encodePacked(messageHash));
        bool first = true;
        for (uint256 i = 0; i < 7; ++i) {
            if ((mask >> i) & 1 == 0) continue;
            BLS.G2Point memory partialSignature = _multiplyG2(messagePoint, secretScalars[i]);
            aggregateSignature = first ? partialSignature : BLS.add(aggregateSignature, partialSignature);
            first = false;
        }
        return abi.encode(mask, abi.encode(aggregateSignature));
    }

    function _publicKey(uint256 scalar) internal view returns (BLS.G1Point memory) {
        BLS.G1Point[] memory points = new BLS.G1Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = _g1Generator();
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function _pop(BLSAggregator agg, address validator, BLS.G1Point memory pk, uint256 sk)
        internal
        view
        returns (BLS.G2Point memory)
    {
        return _multiplyG2(BLS.hashToG2(abi.encodePacked(agg.popDigest(validator, pk))), sk);
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
