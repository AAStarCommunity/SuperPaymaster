// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/utils/BLS.sol";
import {MockedPrecompiles} from "../helpers/MockedPrecompiles.sol";
import {FraudProofVerifierConformance as Conformance} from "../helpers/FraudProofVerifierConformance.sol";
import {OverIssueFraudProofVerifier} from "./vendor/OverIssueFraudProofVerifier.sol";

/**
 * @title CC115CrossRepoConformance
 * @notice CC-115 B2, second half: run SP's release gate against the REAL, MERGED DVT
 *         verifier — not a stand-in for it.
 *
 * @dev    What makes this cross-repo rather than another mock test:
 *
 *         - the verifier under test is `contracts/test/crossrepo/vendor/
 *           OverIssueFraudProofVerifier.sol`, a vendored copy of DVT master @ 8395c94c
 *           (PR #240) whose only deviation from upstream is an import path, recorded and
 *           mechanically re-checkable from its own header;
 *         - the aggregator is a REAL `BLSAggregator`, and the commitment the verifier
 *           recomputes is written by SP's own `verifyAndExecute` → `_computeSignersCommitment`.
 *           Nothing in this file re-implements SP's inner encoding, so the verifier is not
 *           being compared against a second copy of its own assumptions. That circularity
 *           is exactly what let a stale inner layout survive 131 green tests upstream
 *           (CC-115 comment b5426965) — the fix is that the anchor comes from the real
 *           contract, and the recompute comes from the real verifier;
 *         - `GuardianSlashE2E` already had this harness with a `MockVerifier` and a comment
 *           saying "when the real DVT OverIssueFraudProofVerifier lands, swap it in". This
 *           is that swap.
 *
 *         BLS precompiles are mocked so `verifyAndExecute` reaches the commitment write
 *         without real pairing arithmetic — the same approach `GuardianSlashE2E` and
 *         `DVT_BLS` take, and impossible on a real Prague EVM, so this suite steps aside
 *         there (`MockedPrecompiles.skipIfReal`). The property under test is ENCODING
 *         PARITY across two repositories, not pairing correctness.
 */

// ---- minimal stand-ins for what BLSAggregator's constructor and reads require ----
contract XStaking {
    mapping(address => uint128) public lockAmt;
    function setLock(address u, uint128 a) external { lockAmt[u] = a; }
    function roleLocks(address user, bytes32 roleId)
        external view returns (uint128, uint128, uint48, bytes32, bytes memory)
    { return (lockAmt[user], 0, 0, roleId, ""); }
    function slashByDVT(address, bytes32, uint256, string calldata) external {}
}

contract XRegistry is IRegistry {
    address public staking;
    uint256 public minStake;
    constructor(uint256 _minStake) { minStake = _minStake; }
    function setStaking(address s) external { staking = s; }
    function GTOKEN_STAKING() external view returns (IGTokenStaking) { return IGTokenStaking(staking); }
    function hasRole(bytes32, address) external pure override returns (bool) { return true; }
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        return RoleConfig(minStake, 0, 0, 0, 0, 0, 0, false, 0, "stub", address(0), 0);
    }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleUserCount(bytes32) external pure override returns (uint256) { return 0; }
    function getUserRoles(address) external pure override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function getCreditLimit(address) external pure override returns (uint256) { return 100 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external pure override returns (string memory) { return "XRegistry"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external pure override returns (uint256) { return 0; }
}

contract XDVT { function markProposalExecuted(uint256) external {} }
contract XSP {
    function queueSlash(address) external {}
    function executeSlashWithBLS(address, uint8, bytes calldata) external {}
}

/// @dev The disputed community token. `false` means "not over-issued", which is what makes
///      the disputed slash fraudulent and the proof valid.
contract XToken {
    bool public over;
    function setOverIssued(bool v) external { over = v; }
    function isOverIssued() external view returns (bool) { return over; }
}

contract CC115CrossRepoConformance is Test {
    BLSAggregator internal aggA;
    BLSAggregator internal aggB;
    XRegistry internal registry;
    XStaking internal staking;
    XToken internal token;
    OverIssueFraudProofVerifier internal verifier;

    address internal owner = address(0x0BEE);
    uint256 internal constant MIN_STAKE = 30 ether;

    // slots 1..7, already ascending by uint160 — the order SP's commitment sorts into.
    address[7] internal validators = [
        address(0x101), address(0x102), address(0x103), address(0x104),
        address(0x105), address(0x106), address(0x107)
    ];

    // the disputed proposal
    uint256 internal constant PID = 4242;
    address internal constant OPERATOR = address(0xABCD);
    uint8 internal constant SLASH_LEVEL = 1; // MINOR — threshold 3, mask 0x7F gives 7
    uint256 internal constant EPOCH = 100;
    uint256 internal constant MASK = 0x7F;

    address[] internal guardians;
    bool internal skipped;

    function setUp() public {
        if (MockedPrecompiles.skipIfReal()) { skipped = true; return; }
        vm.etch(address(0x0b), hex"60806000f3");
        vm.etch(address(0x0c), hex"60806000f3");
        vm.etch(address(0x10), hex"60806000f3");
        vm.etch(address(0x11), hex"6101006000f3");
        vm.etch(address(0x0d), hex"6101006000f3");
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        // Sepolia, because a domain separator that only differs by chainid is the WEAK
        // replay case; aggA and aggB below differ only by ADDRESS, which is the hard one
        // and the one that actually happened.
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
            aggA.registerBLSPublicKey(validators[i], _stubKey(i + 1), i + 1, _emptyPoP());
        }
        vm.stopPrank();
        for (uint8 i = 0; i < 7; i++) {
            staking.setLock(validators[i], uint128(MIN_STAKE));
            guardians.push(validators[i]);
        }

        // The real DVT verifier, bound to aggA and this Registry.
        verifier = new OverIssueFraudProofVerifier(address(aggA), address(registry));

        // Drive SP's OWN consensus path so the aggregator writes a real
        // proposalSignersCommitment. The evidenceHash must be the DVT convention, because
        // that is what the verifier will reconstruct.
        // Resolve the evidence hash BEFORE the prank: it is an external call, so leaving it
        // in the argument list would consume the prank and send verifyAndExecute from the
        // test contract, which is neither the owner nor DVT_VALIDATOR.
        bytes32 evidence = verifier.evidenceHash(address(token), OPERATOR, EPOCH);
        bytes memory blsProof = _blsProof(MASK);
        vm.prank(owner);
        aggA.verifyAndExecute(
            PID, OPERATOR, SLASH_LEVEL, new address[](0), new uint256[](0), EPOCH, evidence, blsProof
        );
    }

    // ==========================================================
    // The two release gates, run against the real DVT verifier
    // ==========================================================

    /// SP's `assertDomainBound`: accepts its own domain, rejects a sibling aggregator's,
    /// rejects an arbitrary digest.
    function test_RealDvtVerifierPassesAssertDomainBound() public view {
        if (skipped) return;
        Conformance.assertDomainBound(
            address(verifier), address(aggA), address(aggB), _fraudProofId(), guardians, _fraudProof()
        );
    }

    /// SP's `assertSetBound`: accepts the exact accused set, rejects every (n-1) subset,
    /// the superset, and an unrelated set of the same size. This is the gate the pre-B1
    /// subset-lenient verifier would have failed.
    function test_RealDvtVerifierPassesAssertSetBound() public view {
        if (skipped) return;
        Conformance.assertSetBound(
            address(verifier), address(aggA), _fraudProofId(), guardians, _fraudProof()
        );
    }

    // ==========================================================
    // Encoding parity, stated directly rather than only implied
    // ==========================================================

    /// The outer layer: the verifier's domain reconstruction must equal the aggregator's,
    /// for the SAME aggregator, and must NOT equal a sibling's.
    function test_DomainSeparatorParityWithRealAggregator() public view {
        if (skipped) return;
        assertEq(verifier.domainSeparator(), aggA.domainSeparator(), "verifier rebuilds aggA's domain");
        assertTrue(aggA.domainSeparator() != aggB.domainSeparator(), "siblings must not share a domain");
        assertTrue(verifier.domainSeparator() != aggB.domainSeparator(), "and the verifier is bound to aggA");
    }

    /// The digest SP actually hands to `verify` must be the one the verifier expects,
    /// across several ids and set shapes — not just the happy one above.
    function test_FraudProofDigestParityAcrossIdsAndSets() public view {
        if (skipped) return;
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

    /// The inner layer, non-circularly: the anchor is written by SP's own
    /// `_computeSignersCommitment` inside `verifyAndExecute`, and the verifier reaches it
    /// only by reconstructing slash message + commitment from the proof's raw fields. A
    /// stale inner layout on either side makes this fail — which is precisely what 131
    /// green upstream tests could not see while the anchor came from a mock that shared
    /// the verifier's own encoding.
    function test_InnerCommitmentLayoutParityAgainstRealAggregatorWrite() public view {
        if (skipped) return;
        assertTrue(aggA.proposalSignersCommitment(PID) != bytes32(0), "SP wrote a real anchor");
        assertTrue(
            verifier.verify(
                aggA.fraudProofDigest(_fraudProofId(), guardians), _fraudProofId(), guardians, _fraudProof()
            ),
            "the real verifier reproduces SP's real commitment"
        );
    }

    /// Step 5 is a live read, so the same proof must flip with the token's state. This
    /// pins that the acceptance above is earned by the evidence and not by a verifier
    /// that says yes to everything.
    function test_OverIssuedTokenFlipsTheSameProofToRejected() public {
        if (skipped) return;
        bytes32 digest = aggA.fraudProofDigest(_fraudProofId(), guardians);
        assertTrue(verifier.verify(digest, _fraudProofId(), guardians, _fraudProof()), "accepted while not over-issued");
        token.setOverIssued(true);
        assertFalse(verifier.verify(digest, _fraudProofId(), guardians, _fraudProof()), "rejected once over-issued");
    }

    /// The pre-4.11 three-parameter selector must be gone from the vendored build.
    function test_LegacyThreeParamSelectorIsAbsent() public view {
        if (skipped) return;
        assertEq(
            bytes4(keccak256("verify(bytes32,uint256,address[],bytes)")),
            bytes4(0x61077735),
            "SP expects the four-parameter selector CC-115 pinned"
        );
        (bool ok,) = address(verifier).staticcall(
            abi.encodeWithSelector(bytes4(keccak256("verify(uint256,address[],bytes)")), uint256(1), guardians, bytes(""))
        );
        assertFalse(ok, "the obsolete three-parameter entry point must not exist");
    }

    // ---- helpers ----
    function _fraudProofId() internal view returns (uint256) {
        return verifier.deriveFraudProofId(PID);
    }

    /// DVT's proof ABI: (proposalId, operator, slashLevel, epoch, disputedToken,
    /// signerMask, claimedSigners).
    function _fraudProof() internal view returns (bytes memory) {
        return abi.encode(PID, OPERATOR, SLASH_LEVEL, EPOCH, address(token), MASK, guardians);
    }

    function _blsProof(uint256 signerMask) internal pure returns (bytes memory) {
        BLS.G2Point memory sig;
        return abi.encode(signerMask, abi.encode(sig));
    }
    function _stubKey(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(seed); pk.x_b = bytes32(seed + 1);
        pk.y_a = bytes32(seed + 2); pk.y_b = bytes32(seed + 3);
    }
    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}
}
