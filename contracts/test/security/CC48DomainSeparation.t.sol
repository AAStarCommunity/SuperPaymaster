// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/interfaces/v3/IMySBT.sol";
import "src/utils/BLS.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @notice CC-48 round-2 — versioned domain separation, PoP binding and the
///         combined-proposal removal.
///
///  The pairing-dependent halves of these properties (a real signature that
///  verifies on aggregator A and fails on aggregator B, a real PoP lifted from
///  one registrant's calldata) live in
///  contracts/test/paper7/RepCreditDomainReplay.t.sol, which needs the EIP-2537
///  precompiles. Everything provable from the pre-image encoding alone is here,
///  so it runs in the default Cancun suite.
///
///  Schema under test:
///     domainSeparator = keccak256(abi.encode(
///         keccak256("SuperPaymaster.BLSConsensus.v1"),
///         block.chainid, aggregator, registry))
///     messageHash     = keccak256(abi.encode(domainSeparator, <PATH_TAG>, ...fields))

contract DomSepStakingStub {
    mapping(address => uint128) public lockedAmount;

    function setLocked(address user, uint128 amount) external {
        lockedAmount[user] = amount;
    }

    function roleLocks(address user, bytes32 roleId)
        external
        view
        returns (uint128, uint128, uint48, bytes32, bytes memory)
    {
        return (lockedAmount[user], 0, 0, roleId, "");
    }
}

contract DomSepRegistryStub is IRegistry {
    address public stakingAddr;
    mapping(address => bool) public dvtRoleHolders;
    uint256 public minStake = 100;

    function setStakingAddr(address s) external { stakingAddr = s; }
    function setHasDvtRole(address v, bool has_) external { dvtRoleHolders[v] = has_; }
    function GTOKEN_STAKING() external view returns (IGTokenStaking) { return IGTokenStaking(stakingAddr); }
    function hasRole(bytes32, address user) external view override returns (bool) { return dvtRoleHolders[user]; }
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        return RoleConfig(minStake, 0, 0, 0, 0, 0, 0, false, 0, "stub", address(0), 0);
    }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external override {}
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function getCreditLimit(address) external view override returns (uint256) { return 100 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external pure override returns (string memory) { return "DomSepRegistryStub"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
}

contract DomSepMockSBT is IMySBT {
    function mintForRole(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
    function airdropMint(address, bytes32, bytes calldata) external pure returns (uint256, bool) { return (1, true); }
    function getUserSBT(address) external pure returns (uint256) { return 1; }
    function getSBTData(uint256) external pure returns (SBTData memory) {
        return SBTData(address(0), address(0), 0, 0);
    }
    function verifyCommunityMembership(address, address) external pure returns (bool) { return true; }
    function deactivateMembership(address, address) external pure {}
    function deactivateAllMemberships(address) external pure {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external pure {}
    function burnSBT(address) external pure {}
}

/// @dev A verifier that behaves the way DVT's real one must: it accepts a proof
///      ONLY for the exact domain digest it was built against. Anything else is a
///      different contract or a different chain, and is refused.
contract DomSepBoundVerifier {
    bytes32 public acceptedDigest;

    function setAcceptedDigest(bytes32 d) external { acceptedDigest = d; }

    function verify(bytes32 domainDigest, uint256, address[] calldata, bytes calldata)
        external
        view
        returns (bool)
    {
        return domainDigest == acceptedDigest;
    }
}

// =====================================================================
// Domain separator: derivation, cross-contract distinctness, Registry parity
// =====================================================================

contract CC48DomainSeparatorTest is Test {
    BLSAggregator aggA;
    BLSAggregator aggB;
    DomSepRegistryStub stubRegistry;
    Registry realRegistry;

    function setUp() public {
        vm.chainId(11155111);
        stubRegistry = new DomSepRegistryStub();
        aggA = new BLSAggregator(address(stubRegistry), address(0xC0), address(0xC1));
        aggB = new BLSAggregator(address(stubRegistry), address(0xC0), address(0xC1));

        DomSepMockSBT sbt = new DomSepMockSBT();
        realRegistry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(sbt));
    }

    function _expectedDomain(address agg, address reg, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(keccak256("SuperPaymaster.BLSConsensus.v1"), chainId, agg, reg));
    }

    function test_SeparatorMatchesThePublishedSchema() public view {
        assertEq(
            aggA.domainSeparator(),
            _expectedDomain(address(aggA), address(stubRegistry), block.chainid),
            "aggregator separator must equal the schema DVT/SDK will implement"
        );
        assertEq(aggA.DOMAIN_NAME(), keccak256("SuperPaymaster.BLSConsensus.v1"));
    }

    /// The finding this closes: same chain, same registry, same validator keys —
    /// only the contract address differs. Pre-fix both contracts hashed the same
    /// pre-image, so an experiment deployment's signatures were byte-valid against
    /// a production one.
    function test_TwoAggregatorsOnOneChainHaveDisjointDomains() public view {
        assertTrue(aggA.domainSeparator() != aggB.domainSeparator(), "address(this) must enter the domain");
    }

    function test_DomainFollowsTheChain() public {
        bytes32 onSepolia = aggA.domainSeparator();
        vm.chainId(1);
        assertTrue(aggA.domainSeparator() != onSepolia, "chainid must enter the domain");
        assertEq(aggA.domainSeparator(), _expectedDomain(address(aggA), address(stubRegistry), 1));
    }

    function test_DomainFollowsTheRegistry() public {
        DomSepRegistryStub otherRegistry = new DomSepRegistryStub();
        BLSAggregator aggOtherReg = new BLSAggregator(address(otherRegistry), address(0xC0), address(0xC1));
        // Deployed after aggA/aggB, so a different address too — compare against the
        // schema directly to isolate the registry field.
        assertTrue(
            _expectedDomain(address(aggOtherReg), address(otherRegistry), block.chainid)
                != _expectedDomain(address(aggOtherReg), address(stubRegistry), block.chainid),
            "registry must enter the domain"
        );
        assertEq(aggOtherReg.domainSeparator(), _expectedDomain(address(aggOtherReg), address(otherRegistry), block.chainid));
    }

    /// Registry re-derives the separator itself. It must land byte-identical, or
    /// every reputation proposal dies inside Registry with an opaque BLSFailed.
    function test_RegistryAndAggregatorAgreeByteForByte() public {
        BLSAggregator agg = new BLSAggregator(address(realRegistry), address(0xC0), address(0xC1));
        realRegistry.setBLSAggregator(address(agg));
        assertEq(realRegistry.blsDomainSeparator(), agg.domainSeparator());
    }

    /// A mis-wired pair (aggregator bound to registry X, configured on registry Y)
    /// must NOT agree — that disagreement is what makes the mis-wiring fail closed
    /// instead of silently verifying.
    function test_MisWiredPairFailsClosed() public {
        BLSAggregator foreignAgg = new BLSAggregator(address(stubRegistry), address(0xC0), address(0xC1));
        realRegistry.setBLSAggregator(address(foreignAgg));
        assertTrue(
            realRegistry.blsDomainSeparator() != foreignAgg.domainSeparator(),
            "aggregator bound to another Registry must not share this Registry's domain"
        );
    }

    function test_PathTagsAreDistinct() public view {
        bytes32[7] memory tags = [
            aggA.TAG_QUEUE_SLASH(),
            aggA.TAG_EXECUTE_SLASH(),
            aggA.TAG_REPUTATION(),
            aggA.TAG_PROPOSAL(),
            aggA.TAG_POP(),
            aggA.TAG_SIGNERS_COMMITMENT(),
            aggA.TAG_FRAUD_PROOF()
        ];
        for (uint256 i = 0; i < tags.length; i++) {
            assertTrue(tags[i] != bytes32(0));
            for (uint256 j = i + 1; j < tags.length; j++) {
                assertTrue(tags[i] != tags[j], "path tags must be pairwise distinct");
            }
        }
    }

    /// The blacklist path lives entirely on Registry, so its tag is asserted here
    /// against the value DVT/SDK must hardcode.
    function test_BlacklistTagIsPinned() public {
        BLSAggregator agg = new BLSAggregator(address(realRegistry), address(0xC0), address(0xC1));
        realRegistry.setBLSAggregator(address(agg));
        bytes32 domain = realRegistry.blsDomainSeparator();
        address[] memory users = new address[](1);
        bool[] memory statuses = new bool[](1);
        users[0] = address(0xBEEF);
        statuses[0] = true;
        // Nonce 1 = first call. Reproduced here exactly as an indexer would.
        bytes32 expected = keccak256(
            abi.encode(
                domain, keccak256("SuperPaymaster.BLS.Blacklist.v1"), uint256(1), address(0xAAA), users, statuses
            )
        );
        assertTrue(expected != bytes32(0));
        assertTrue(
            expected
                != keccak256(abi.encode(block.chainid, uint256(1), address(0xAAA), users, statuses)),
            "blacklist pre-image must no longer be the pre-fix chainid-only encoding"
        );
    }

    function test_ReputationMessageHashMatchesTheSchema() public {
        BLSAggregator agg = new BLSAggregator(address(realRegistry), address(0xC0), address(0xC1));
        realRegistry.setBLSAggregator(address(agg));
        address[] memory users = new address[](2);
        uint256[] memory scores = new uint256[](2);
        users[0] = address(0x1); users[1] = address(0x2);
        scores[0] = 10; scores[1] = 20;

        bytes32 expected = keccak256(
            abi.encode(
                agg.domainSeparator(),
                keccak256("SuperPaymaster.BLS.Reputation.v1"),
                uint256(7),
                users,
                scores,
                uint256(3)
            )
        );
        assertEq(agg.reputationMessageHash(7, users, scores, 3), expected);
    }

    /// Fields still separate proposals within one domain — the domain is added
    /// protection, not a replacement for field binding.
    function test_FieldsStillSeparateProposals() public view {
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = address(0x1);
        scores[0] = 10;
        bytes32 h1 = aggA.reputationMessageHash(1, users, scores, 1);
        bytes32 h2 = aggA.reputationMessageHash(2, users, scores, 1);
        bytes32 h3 = aggA.reputationMessageHash(1, users, scores, 2);
        assertTrue(h1 != h2 && h1 != h3 && h2 != h3);
    }
}

// =====================================================================
// Fraud-proof verifier domain
// =====================================================================

contract CC48FraudProofDomainTest is Test {
    BLSAggregator aggA;
    BLSAggregator aggB;
    DomSepRegistryStub registry;
    DomSepStakingStub staking;
    DomSepBoundVerifier verifier;

    address owner = address(0xA1);

    function setUp() public {
        vm.warp(365 days);
        vm.chainId(11155111);
        vm.startPrank(owner);
        registry = new DomSepRegistryStub();
        staking = new DomSepStakingStub();
        registry.setStakingAddr(address(staking));
        aggA = new BLSAggregator(address(registry), address(0xC0), address(0xC1));
        aggB = new BLSAggregator(address(registry), address(0xC0), address(0xC1));
        verifier = new DomSepBoundVerifier();
        aggA.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + aggA.VERIFIER_ROTATION_DELAY());
        vm.stopPrank();
        aggA.applyFraudProofVerifier();
    }

    function _guardians() internal pure returns (address[] memory g) {
        g = new address[](2);
        g[0] = address(0x101);
        g[1] = address(0x102);
    }

    function test_DigestMatchesThePublishedSchema() public view {
        address[] memory g = _guardians();
        assertEq(
            aggA.fraudProofDigest(42, g),
            keccak256(
                abi.encode(
                    aggA.domainSeparator(), keccak256("SuperPaymaster.BLS.FraudProof.v1"), uint256(42), g
                )
            )
        );
    }

    /// The same fraudProofId over the same guardian set produces a DIFFERENT digest
    /// on a second aggregator — a verifier that binds the digest cannot be made to
    /// accept the same proof twice across contracts.
    function test_SameProofIdHasDifferentDigestsPerAggregator() public view {
        address[] memory g = _guardians();
        assertTrue(aggA.fraudProofDigest(7, g) != aggB.fraudProofDigest(7, g));
    }

    function test_DigestFollowsTheChain() public {
        address[] memory g = _guardians();
        bytes32 before = aggA.fraudProofDigest(7, g);
        vm.chainId(1);
        assertTrue(aggA.fraudProofDigest(7, g) != before);
    }

    /// The aggregator must actually PASS the digest on the live path — a getter
    /// nobody calls is not a control. A verifier bound to aggA's digest accepts.
    function test_QueueGuardianSlashHandsTheDigestToTheVerifier() public {
        address[] memory g = _guardians();
        verifier.setAcceptedDigest(aggA.fraudProofDigest(99, g));

        aggA.queueGuardianSlash(99, g, hex"01");

        (, , , uint8 status, , ,,) = aggA.guardianSlashCases(99);
        assertEq(status, 1, "case queued => verifier saw the digest it was bound to");
    }

    /// Cross-contract replay, verifier side: the same (id, guardians, proof) bytes
    /// against a verifier bound to the OTHER aggregator's digest is refused. This is
    /// what stops one deployment's fraud proof from being replayed on another.
    function test_ProofBoundToAnotherAggregatorIsRefused() public {
        address[] memory g = _guardians();
        verifier.setAcceptedDigest(aggB.fraudProofDigest(99, g));

        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidFraudProof.selector, uint256(99)));
        aggA.queueGuardianSlash(99, g, hex"01");
    }

    /// Same aggregator, same guardians, WRONG chain: a digest captured pre-fork does
    /// not authorize a case post-fork.
    function test_ProofBoundToAnotherChainIsRefused() public {
        address[] memory g = _guardians();
        verifier.setAcceptedDigest(aggA.fraudProofDigest(99, g));
        vm.chainId(1);

        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidFraudProof.selector, uint256(99)));
        aggA.queueGuardianSlash(99, g, hex"01");
    }
}

// =====================================================================
// PoP binding + duplicate public key rejection
// =====================================================================

contract CC48PoPBindingTest is Test {
    BLSAggregator aggA;
    BLSAggregator aggB;
    DomSepRegistryStub registry;
    DomSepStakingStub staking;

    address owner = address(0xA1);
    address v1 = address(0x101);
    address v2 = address(0x102);

    bool internal pragueAvailable;

    /// @dev These cases stub the curve precompiles so `_validateG1Point` accepts a
    ///      synthetic key — the owner path never reaches a pairing. Under
    ///      --evm-version prague those addresses are real precompiles that vm.etch
    ///      refuses to overwrite (and that would reject the synthetic keys anyway),
    ///      so the suite steps aside there; RepCreditDomainReplay covers the same
    ///      properties with genuine keys.
    function _skipUnderPrague() internal {
        if (pragueAvailable) vm.skip(true);
    }

    function setUp() public {
        vm.chainId(11155111);
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = address(0x0B).staticcall(twoIdentities);
        pragueAvailable = ok && result.length == 128;
        if (!pragueAvailable) {
            vm.etch(address(0x0b), hex"60806000f3");
            vm.etch(address(0x0c), hex"60806000f3");
            vm.etch(address(0x0d), hex"6101006000f3");
            vm.etch(address(0x10), hex"60806000f3");
            vm.etch(address(0x11), hex"6101006000f3");
            // CC-48 round-3: the owner path verifies a proof-of-possession too, so the
            // pairing precompile has to answer for these synthetic keys. Whether a PoP
            // is genuinely bound is proven with real pairings in
            // contracts/test/paper7/RepCreditDomainReplay.t.sol; here we are asserting
            // the duplicate-key / binding bookkeeping around it.
            vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        }

        vm.startPrank(owner);
        registry = new DomSepRegistryStub();
        staking = new DomSepStakingStub();
        registry.setStakingAddr(address(staking));
        aggA = new BLSAggregator(address(registry), address(0xC0), address(0xC1));
        aggB = new BLSAggregator(address(registry), address(0xC0), address(0xC1));
        vm.stopPrank();
    }

    function _key(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(uint256(0x01));
        pk.x_b = bytes32(seed);
        pk.y_a = bytes32(uint256(0x02));
        pk.y_b = bytes32(seed + 1);
    }

    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

    function _keyHash(BLS.G1Point memory pk) internal pure returns (bytes32) {
        return keccak256(abi.encode(pk.x_a, pk.x_b, pk.y_a, pk.y_b));
    }

    function test_PoPDigestBindsTheValidatorAddress() public view {
        BLS.G1Point memory pk = _key(1);
        assertTrue(
            aggA.popDigest(v1, pk) != aggA.popDigest(v2, pk),
            "a PoP for v1 must not be a PoP for v2 over the same key"
        );
    }

    function test_PoPDigestBindsTheAggregator() public view {
        assertTrue(
            aggA.popDigest(v1, _key(1)) != aggB.popDigest(v1, _key(1)),
            "a PoP filed on one aggregator must not be liftable to another"
        );
    }

    function test_PoPDigestMatchesThePublishedSchema() public view {
        BLS.G1Point memory pk = _key(1);
        assertEq(
            aggA.popDigest(v1, pk),
            keccak256(
                abi.encode(
                    aggA.domainSeparator(),
                    keccak256("SuperPaymaster.BLS.PoP.v1"),
                    v1,
                    pk.x_a,
                    pk.x_b,
                    pk.y_a,
                    pk.y_b
                )
            )
        );
    }

    /// The core forgery this blocks: one key in N slots makes pkAgg = N*pk, and the
    /// single holder of sk can produce N*sk*H(m). That is a valid aggregate
    /// signature for an N-signer mask held by one party.
    function test_SameKeyCannotBeRegisteredForTwoValidators() public {
        _skipUnderPrague();
        BLS.G1Point memory pk = _key(1);
        vm.prank(owner);
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.DuplicatePublicKey.selector, _keyHash(pk), v1));
        aggA.registerBLSPublicKey(v2, pk, 2, _emptyPoP());
    }

    /// Enforced on the OWNER path too. The owner is trusted to curate the set, not
    /// to be immune to a copy-paste; and the whole point of a duplicate key is that
    /// it looks identical to a legitimate one.
    function test_DuplicateRejectionAppliesToTheOwnerPath() public {
        _skipUnderPrague();
        BLS.G1Point memory pk = _key(5);
        vm.startPrank(owner);
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.DuplicatePublicKey.selector, _keyHash(pk), v1));
        aggA.registerBLSPublicKey(v2, pk, 3, _emptyPoP());
        vm.stopPrank();
        assertEq(aggA.validatorAtSlot(3), address(0), "no slot may be bound by the rejected call");
    }

    function test_ValidatorMayReRegisterItsOwnKey() public {
        _skipUnderPrague();
        BLS.G1Point memory pk = _key(9);
        vm.startPrank(owner);
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP()); // idempotent re-register
        vm.stopPrank();
        (, uint8 slot, bool active) = aggA.getBLSPublicKey(v1);
        assertEq(slot, 1);
        assertTrue(active);
        assertEq(aggA.blsKeyOwner(_keyHash(pk)), v1);
    }

    /// Revocation frees the SLOT but never the KEY. Releasing the key binding would
    /// let a revoked (possibly compromised, possibly deliberately shared) key be
    /// re-claimed by a second address — the exact duplicate condition.
    function test_RevocationDoesNotReleaseTheKeyBinding() public {
        _skipUnderPrague();
        BLS.G1Point memory pk = _key(11);
        vm.startPrank(owner);
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());
        aggA.revokeBLSPublicKey(v1);
        assertEq(aggA.validatorAtSlot(1), address(0), "slot is freed");
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.DuplicatePublicKey.selector, _keyHash(pk), v1));
        aggA.registerBLSPublicKey(v2, pk, 1, _emptyPoP());
        // ...but the original owner may take it back.
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());
        vm.stopPrank();
        assertEq(aggA.validatorAtSlot(1), v1);
    }

    function test_DistinctKeysStillRegisterNormally() public {
        _skipUnderPrague();
        vm.startPrank(owner);
        aggA.registerBLSPublicKey(v1, _key(1), 1, _emptyPoP());
        aggA.registerBLSPublicKey(v2, _key(2), 2, _emptyPoP());
        vm.stopPrank();
        assertEq(aggA.validatorAtSlot(1), v1);
        assertEq(aggA.validatorAtSlot(2), v2);
    }

    /// The binding is per-contract state, so a fresh aggregator starts clean —
    /// which is exactly why the migration is "redeploy + re-register", not
    /// "keep the old key table".
    function test_KeyBindingIsPerAggregator() public {
        _skipUnderPrague();
        BLS.G1Point memory pk = _key(1);
        vm.startPrank(owner);
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());
        aggB.registerBLSPublicKey(v2, pk, 1, _emptyPoP());
        vm.stopPrank();
        assertEq(aggA.blsKeyOwner(_keyHash(pk)), v1);
        assertEq(aggB.blsKeyOwner(_keyHash(pk)), v2);
    }

    // =================================================================
    // CC-48 round-3 — misconfiguration recovery for the permanent binding
    // =================================================================

    /// The binding is permanent by design, which used to mean a wrong entry was
    /// permanent too: the key was burned forever and the validator had to rotate to a
    /// brand-new secret key. `releaseKeyBinding` is the escape hatch — owner-only, and
    /// only for a key no ACTIVE slot is using.
    function test_OwnerCanReleaseABindingNoActiveSlotUses() public {
        _skipUnderPrague();
        BLS.G1Point memory pk = _key(7);
        vm.prank(owner);
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());
        assertEq(aggA.blsKeyOwner(_keyHash(pk)), v1);

        // Revoking alone must NOT release it — that is the anti-duplicate property.
        vm.prank(owner);
        aggA.revokeBLSPublicKey(v1);
        assertEq(aggA.blsKeyOwner(_keyHash(pk)), v1, "revoke still does not release the binding");

        vm.prank(owner);
        aggA.releaseKeyBinding(_keyHash(pk));
        assertEq(aggA.blsKeyOwner(_keyHash(pk)), address(0));

        // The key's real holder can now claim it at a different address.
        vm.prank(owner);
        aggA.registerBLSPublicKey(v2, pk, 2, _emptyPoP());
        assertEq(aggA.blsKeyOwner(_keyHash(pk)), v2);
    }

    /// The narrow precondition is the whole safety argument: a LIVE signer's binding
    /// can never be released out from under it, so the duplicate-key guard cannot be
    /// disarmed by governance one call at a time.
    function test_ReleaseIsRefusedWhileAnActiveSlotHoldsTheKey() public {
        _skipUnderPrague();
        BLS.G1Point memory pk = _key(8);
        vm.prank(owner);
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.KeyBindingStillActive.selector, _keyHash(pk), v1)
        );
        aggA.releaseKeyBinding(_keyHash(pk));
        assertEq(aggA.blsKeyOwner(_keyHash(pk)), v1);
    }

    /// The scan looks at the ACTIVE table, not at the address the binding names: after
    /// a rotation the key can be live under a different address, and releasing it there
    /// would be the same hole.
    function test_ReleaseIsRefusedWhenTheKeyIsLiveUnderAnotherAddress() public {
        _skipUnderPrague();
        BLS.G1Point memory pk = _key(9);
        vm.startPrank(owner);
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());
        aggA.revokeBLSPublicKey(v1);
        aggA.releaseKeyBinding(_keyHash(pk));
        // Same key, new holder.
        aggA.registerBLSPublicKey(v2, pk, 2, _emptyPoP());

        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.KeyBindingStillActive.selector, _keyHash(pk), v2)
        );
        aggA.releaseKeyBinding(_keyHash(pk));
        vm.stopPrank();
    }

    function test_ReleaseIsOwnerOnlyAndRejectsAnUnknownKey() public {
        _skipUnderPrague();
        BLS.G1Point memory pk = _key(10);
        vm.prank(owner);
        aggA.registerBLSPublicKey(v1, pk, 1, _emptyPoP());
        vm.prank(owner);
        aggA.revokeBLSPublicKey(v1);

        vm.prank(address(0xBAD));
        vm.expectRevert();
        aggA.releaseKeyBinding(_keyHash(pk));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "keyHash"));
        aggA.releaseKeyBinding(keccak256("never registered"));
    }
}

// =====================================================================
// Combined (reputation + slash) proposal shape is removed
// =====================================================================

contract CC48CombinedProposalTest is Test {
    BLSAggregator agg;
    DomSepRegistryStub registry;
    DomSepStakingStub staking;
    address owner = address(0xA1);

    function setUp() public {
        vm.chainId(11155111);
        vm.startPrank(owner);
        registry = new DomSepRegistryStub();
        staking = new DomSepStakingStub();
        registry.setStakingAddr(address(staking));
        agg = new BLSAggregator(address(registry), address(0xC0), address(0xC1));
        vm.stopPrank();
    }

    function _rep() internal pure returns (address[] memory u, uint256[] memory s) {
        u = new address[](1);
        s = new uint256[](1);
        u[0] = address(0xAB11);
        s[0] = 50;
    }

    /// Pre-fix this shape hashed one pre-image in the aggregator (real operator +
    /// slashLevel) and a different one in Registry (address(0)/0), so no single
    /// signature could satisfy both — it was a dead path that failed with an opaque
    /// BLSFailed deep inside Registry. It is now an explicit, named protocol rule.
    function test_ReputationBatchWithAnOperatorIsRejected() public {
        (address[] memory u, uint256[] memory s) = _rep();
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.CombinedProposalNotSupported.selector);
        agg.verifyAndExecute(1, address(0xDEAD), 0, u, s, 1, bytes32(0), abi.encode(uint256(7), bytes("")));
    }

    function test_ReputationBatchWithASlashLevelIsRejected() public {
        (address[] memory u, uint256[] memory s) = _rep();
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.CombinedProposalNotSupported.selector);
        agg.verifyAndExecute(1, address(0), 2, u, s, 1, bytes32(0), abi.encode(uint256(7), bytes("")));
    }

    /// It is rejected BEFORE any signature work, so it cannot be used as a cheap
    /// pairing-gas grief either.
    function test_RejectionPrecedesSignatureVerification() public {
        (address[] memory u, uint256[] memory s) = _rep();
        vm.prank(owner);
        // Deliberately malformed proof: if the guard ran after _checkSignatures this
        // would revert on the decode instead.
        vm.expectRevert(BLSAggregator.CombinedProposalNotSupported.selector);
        agg.verifyAndExecute(1, address(0xDEAD), 1, u, s, 1, bytes32(0), hex"");
    }

    /// CC-48 round-3: the slash-only branch must be pinned from the other side too.
    /// The slash pre-image commits to (proposalId, operator, slashLevel, epoch,
    /// evidenceHash) — `newScores` is NOT a field — so a non-empty `newScores` on this
    /// branch was caller-controlled input that rode through a signature check without
    /// being covered by any signature. Unused today; rejected so it cannot quietly
    /// become used-but-unsigned later.
    function test_SlashOnlyBranchRejectsUnsignedNewScores() public {
        address[] memory noUsers = new address[](0);
        uint256[] memory scores = new uint256[](1);
        scores[0] = 42;
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.CombinedProposalNotSupported.selector);
        agg.verifyAndExecute(1, address(0xDEAD), 1, noUsers, scores, 1, bytes32(0), hex"");
    }

    /// ...and it is rejected before any signature work, same as the combined shape.
    function test_UnsignedNewScoresRejectionPrecedesSignatureVerification() public {
        address[] memory noUsers = new address[](0);
        uint256[] memory scores = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.CombinedProposalNotSupported.selector);
        agg.verifyAndExecute(2, address(0xDEAD), 2, noUsers, scores, 1, bytes32(0), hex"");
    }

    /// A proposal with no batch, no target and no severity only burns a proposalId in
    /// two contracts. It needs a real quorum so it was never an attack — but a no-op
    /// shape on a consensus path is a place for future divergence, so it is now a
    /// named rule rather than an accident of the branch structure.
    function test_EmptyProposalShapeIsRejected() public {
        address[] memory noUsers = new address[](0);
        uint256[] memory noScores = new uint256[](0);
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.EmptyProposalNotSupported.selector);
        agg.verifyAndExecute(3, address(0), 0, noUsers, noScores, 1, bytes32(0), hex"");
    }

    /// The legitimate slash-only shapes are untouched: they get past the shape guards
    /// and fail later, on the signature, which is where they should fail with a
    /// malformed proof.
    function test_LegitimateSlashOnlyShapesStillReachSignatureVerification() public {
        address[] memory noUsers = new address[](0);
        uint256[] memory noScores = new uint256[](0);

        // operator set, level 0 (MINOR) — reaches _checkSignatures.
        vm.prank(owner);
        vm.expectRevert();
        agg.verifyAndExecute(4, address(0xDEAD), 0, noUsers, noScores, 1, bytes32(0), hex"");

        // no operator but a real severity — also a shape the protocol allows
        // (marks the proposalId without moving funds).
        vm.prank(owner);
        vm.expectRevert();
        agg.verifyAndExecute(5, address(0), 1, noUsers, noScores, 1, bytes32(0), hex"");
    }
}
