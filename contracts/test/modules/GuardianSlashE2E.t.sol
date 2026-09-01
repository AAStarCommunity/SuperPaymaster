// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/utils/BLS.sol";
import {MockedPrecompiles} from "../helpers/MockedPrecompiles.sol";

/// @notice CC-89 stage-2 Phase-2 E2E harness (SP half real, DVT verifier mocked).
/// @dev  Full over-issue guardian-collusion slash chain wired end-to-end:
///         A)造 slash: verifyAndExecute (real, BLS precompiles mocked) → stores
///            proposalSignersCommitment  ← SP half, fully asserted incl. off-chain recompute.
///         B) fraud proof → executeGuardianSlash → slashByDVT → auto-eject  ← DVT half.
///       The verifier is a MOCK here (returns true). When the real DVT
///       OverIssueFraudProofVerifier lands (issue #222), swap MockVerifier for it and
///       feed a real fraudProof — the rest of the wiring stays identical.
///       Mirrors DVT_BLS.t.sol's mocked BLS precompiles so verifyAndExecute passes
///       _checkSignatures without real BLS signing.

// ---- staking: real-enough accounting to prove slash → 0 → auto-eject ----
contract MockStaking {
    mapping(address => uint128) public lockAmt;
    uint256 public slashCount;

    function setLock(address u, uint128 a) external {
        lockAmt[u] = a;
    }

    function roleLocks(address user, bytes32 roleId)
        external
        view
        returns (uint128, uint128, uint48, bytes32, bytes memory)
    {
        return (lockAmt[user], 0, 0, roleId, "");
    }

    function slashByDVT(address operator, bytes32, uint256 penalty, string calldata) external {
        require(lockAmt[operator] >= penalty, "InsufficientStake");
        lockAmt[operator] -= uint128(penalty);
        slashCount++;
    }
}

contract MockRegistry is IRegistry {
    address public staking;
    uint256 public minStake;
    mapping(address => uint256) public pending;

    constructor(uint256 _minStake) {
        minStake = _minStake;
    }

    function setStaking(address s) external {
        staking = s;
    }

    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return IGTokenStaking(staking);
    }

    function hasRole(bytes32, address) external pure override returns (bool) {
        return true;
    }

    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        return RoleConfig(minStake, 0, 0, 0, 0, 0, 0, false, 0, "stub", address(0), 0);
    }
    // stubs
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external
        override
    {}
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}

    function getRoleUserCount(bytes32) external pure override returns (uint256) {
        return 0;
    }

    function getUserRoles(address) external pure override returns (bytes32[] memory) {
        return new bytes32[](0);
    }
    function registerRole(bytes32, address, bytes calldata) external override {}

    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) {
        return 0;
    }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}

    function getCreditLimit(address) external pure override returns (uint256) {
        return 100 ether;
    }

    function isReputationSource(address) external pure override returns (bool) {
        return true;
    }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}

    function version() external pure override returns (string memory) {
        return "MockRegistry";
    }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}

    function getEffectiveStake(address, bytes32) external pure override returns (uint256) {
        return 0;
    }

    function setGuardianSlashPending(address guardian, bool value) external {
        if (value) pending[guardian]++;
        else pending[guardian]--;
    }
}

/// @notice Stand-in for the real DVT OverIssueFraudProofVerifier (issue #222).
///         The real one will: require(commitment!=0) → keccak(claimedSigners)==commitment
///         → guiltyGuardians ⊆ claimedSigners → over-issue evidence recompute.
contract MockVerifier {
    BLSAggregator public immutable AGG;
    bool public ok = true;

    constructor(BLSAggregator a) {
        AGG = a;
    }

    function set(bool v) external {
        ok = v;
    }

    /// @dev Binds the fraud proof to Phase A: fraudProof carries the disputed
    ///      proposalId, and step 0 (pr-daemon Medium) requires its commitment != 0.
    ///      The real verifier additionally checks keccak(claimedSigners)==commitment,
    ///      guiltyGuardians ⊆ claimedSigners, and recomputes the over-issue evidence.
    function verify(bytes32, uint256, address[] calldata, bytes calldata fraudProof) external view returns (bool) {
        if (!ok) return false;
        uint256 disputedPid = abi.decode(fraudProof, (uint256));
        return AGG.proposalSignersCommitment(disputedPid) != bytes32(0);
    }
}

/// @notice DVT_VALIDATOR stand-in — verifyAndExecute calls markProposalExecuted on it.
contract MockDVT {
    function markProposalExecuted(uint256) external {}
}

/// @notice SUPERPAYMASTER stand-in — _executeSlash forwards the operator slash here.
contract MockSP {
    function queueSlash(address) external {}
    function executeSlashWithBLS(address, uint8, bytes calldata) external {}
}

contract GuardianSlashE2ETest is Test {
    BLSAggregator bls;
    MockRegistry registry;
    MockStaking staking;
    MockVerifier verifier;

    MockDVT dvtC;
    MockSP spC;
    address owner = address(0x0BEE);
    uint256 constant MIN_STAKE = 30 ether;

    // slots 1..7 → these validator addresses (already ascending by uint160)
    address[7] signers = [
        address(0x101), address(0x102), address(0x103), address(0x104), address(0x105), address(0x106), address(0x107)
    ];

    function setUp() public {
        // Mock BLS precompiles (same shape as DVT_BLS.t.sol) so verifyAndExecute
        // passes _reconstructPkAgg + pairing without real BLS signing.
        // CC-48 round-3 MEDIUM-5: this harness injects fake EIP-2537 precompiles, which
        // is impossible on a real Prague EVM. Step aside there; contracts/test/paper7/
        // covers these paths with genuine keys and pairings.
        if (MockedPrecompiles.skipIfReal()) return;
        vm.etch(address(0x0b), hex"60806000f3"); // G1ADD → 128 bytes
        vm.etch(address(0x0c), hex"60806000f3"); // G1MUL → 128 bytes (identity)
        vm.etch(address(0x10), hex"60806000f3"); // MapFpToG1
        vm.etch(address(0x11), hex"6101006000f3"); // MapFp2ToG2 → 256 bytes
        vm.etch(address(0x0d), hex"6101006000f3"); // G2ADD → 256 bytes
        // BLS12_PAIRING (0x0f) → success (1); focuses the harness on commitment +
        // slash wiring, not real pairing arithmetic (same approach as DVT_BLS.t.sol).
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        staking = new MockStaking();
        registry = new MockRegistry(MIN_STAKE);
        registry.setStaking(address(staking));

        vm.startPrank(owner);
        dvtC = new MockDVT();
        spC = new MockSP();
        bls = new BLSAggregator(address(registry), address(spC), address(dvtC));
        // register 7 validators into slots 1..7 + give each a ROLE_DVT lock ≥ minStake
        for (uint8 i = 0; i < 7; i++) {
            bls.registerBLSPublicKey(signers[i], _stubKey(i + 1), i + 1, _emptyPoP());
        }
        vm.stopPrank();
        for (uint8 i = 0; i < 7; i++) {
            staking.setLock(signers[i], uint128(MIN_STAKE)); // exactly at floor
        }

        verifier = new MockVerifier(bls);
    }

    function _stubKey(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(seed);
        pk.x_b = bytes32(seed + 1);
        pk.y_a = bytes32(seed + 2);
        pk.y_b = bytes32(seed + 3);
    }
    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

    function _proof(uint256 signerMask) internal pure returns (bytes memory) {
        BLS.G2Point memory sig;
        return abi.encode(signerMask, abi.encode(sig));
    }

    // ============================================================
    // Phase A — SP half: verifyAndExecute stores a commitment an off-chain
    //           watcher can reproduce byte-for-byte.
    // ============================================================
    function test_E2E_A_CommitmentStoredAndReproducible() public {
        uint256 pid = 42;
        address op = address(0xABCD);
        uint8 slashLevel = 1; // MINOR (threshold 3); mask 0x7F = 7 signers passes
        uint256 epoch = 100;
        // DVT's frozen cross-repo convention (CC-89 f41fd3b1): the verifier recomputes
        // this exact preimage from the slash fields to bind disputedToken and block the
        // token-swap attack. The E2E filer MUST use it or the commitment won't match.
        address disputedToken = address(0x7000); // the over-issued token under dispute
        bytes32 evidenceHash = keccak256(abi.encode("DVT_OVERISSUE_EVIDENCE_V1", disputedToken, op, epoch));
        uint256 mask = 0x7F; // slots 1..7
        bytes memory proof = _proof(mask);

        vm.prank(owner);
        bls.verifyAndExecute(pid, op, slashLevel, new address[](0), new uint256[](0), epoch, evidenceHash, proof);

        bytes32 stored = bls.proposalSignersCommitment(pid);
        assertTrue(stored != bytes32(0), "commitment must be non-zero (pr-daemon require)");

        // Off-chain recompute (this is exactly what the DVT watcher/verifier does):
        // slash-only messageHash + canonical ascending signer set.
        // CC-48 round-2 schema: every pre-image is domain-separated by
        // keccak256(abi.encode(DOMAIN_NAME, chainid, aggregator, registry)). Rebuilt
        // from raw fields (not read off the contract) so a schema drift fails here.
        bytes32 domain = keccak256(
            abi.encode(keccak256("SuperPaymaster.BLSConsensus.v1"), block.chainid, address(bls), address(registry))
        );
        bytes32 expectedMsgHash = keccak256(
            abi.encode(
                domain, keccak256("SuperPaymaster.BLS.ExecuteSlash.v1"), pid, op, slashLevel, epoch, evidenceHash
            )
        );
        address[] memory sorted = new address[](7);
        // already ascending
        for (uint8 i = 0; i < 7; i++) {
            sorted[i] = signers[i];
        }
        bytes32 expected = keccak256(
            abi.encode(domain, keccak256("SuperPaymaster.BLS.SignersCommitment.v1"), pid, expectedMsgHash, mask, sorted)
        );
        assertEq(stored, expected, "off-chain recompute must match on-chain commitment");
    }

    // ============================================================
    // Phase B — DVT half (verifier mocked): fraud proof → executeGuardianSlash →
    //           slash guilty guardians' ROLE_DVT lock to 0 → auto-eject.
    // ============================================================
    function test_E2E_B_FraudProofSlashesAndEjects() public {
        // First run Phase A so a commitment exists for the disputed proposal.
        test_E2E_A_CommitmentStoredAndReproducible();

        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(verifier)); // real verifier swaps in here
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        // The (mock) verifier attests these two signers colluded on the fraudulent slash.
        address[] memory guilty = new address[](2);
        guilty[0] = signers[0]; // 0x101
        guilty[1] = signers[3]; // 0x104
        // fraudProof binds to the disputed proposal FROM PHASE A (pid = 42); the mock
        // verifier reads its commitment (mirrors pr-daemon's step-0 require != 0). A real
        // fraudProof adds claimedSigners/mask/msgHash/token, but the pid binding is the same.
        bytes memory fraudProof = abi.encode(uint256(42));
        bls.queueGuardianSlash(1, guilty, fraudProof);
        bls.executeGuardianSlash(1, guilty, fraudProof);

        // Fractional slash. This assertion used to read `== 0`: the path passed the whole
        // remaining lock to slashByDVT, so every successful guardian slash zeroed the lock
        // and ejected the role in the same transaction. `guardianSlashBps` (default 3000)
        // makes the penalty a fraction, which is what lets an over-staked guardian survive
        // one slash and stay in the quorum.
        uint256 expectedPenalty = (MIN_STAKE * uint256(bls.guardianSlashBps())) / 10000;
        assertEq(
            staking.lockAmt(signers[0]),
            MIN_STAKE - expectedPenalty,
            "guilty guardian 0x101 slashed by guardianSlashBps, not wiped"
        );
        assertEq(staking.lockAmt(signers[3]), MIN_STAKE - expectedPenalty, "guilty guardian 0x104 likewise");
        assertEq(staking.slashCount(), 2, "both guilty slashed");
        // Non-guilty untouched.
        assertEq(staking.lockAmt(signers[1]), MIN_STAKE, "innocent 0x102 untouched");

        // Auto-eject still happens, but for the reason it always really did: the remaining
        // lock is below minStake, not that it is zero. At MIN_STAKE exactly (margin 0) ANY
        // non-zero penalty drops below the gate — which is why the operational rule is to
        // stake above minStake, and why the cap alone is not the whole fix.
        vm.prank(owner);
        vm.expectRevert(); // SlotValidatorStakeBelowMinimum(1, 0x101, 0, 30e)
        bls.verifyAndExecute(99, address(0xABCD), 1, new address[](0), new uint256[](0), 101, bytes32(0), _proof(0x7F));
    }

    // ============================================================
    // The cap is NECESSARY and NOT SUFFICIENT — both halves pinned here.
    //
    // `guardianSlashBps` only buys something for a guardian that staked ABOVE the gate.
    // The eligibility check is absolute (`getEffectiveStake >= minStake`), so at the
    // margin the current deployment actually runs at — every ROLE_DVT lock is exactly
    // minStake — a capped slash ejects just as surely as a full one did. Stating that in
    // a comment is cheap; these two tests make it checkable, and make it break loudly if
    // someone later "fixes" the self-disable by tuning bps alone.
    // ============================================================

    /// Margin 0: the cap does NOT save the quorum. This is today's configuration.
    function test_Cap_AtExactlyMinStake_StillEjects() public {
        test_E2E_A_CommitmentStoredAndReproducible();
        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        address[] memory guilty = new address[](1);
        guilty[0] = signers[0];
        bytes memory fraudProof = abi.encode(uint256(42));
        bls.queueGuardianSlash(1, guilty, fraudProof);
        bls.executeGuardianSlash(1, guilty, fraudProof);

        uint256 remaining = staking.lockAmt(signers[0]);
        assertGt(remaining, 0, "capped, so not wiped");
        assertLt(remaining, MIN_STAKE, "but still under the gate: one slash still ejects");
    }

    /// Over-staked past minStake/(1-bps): the cap is what makes that stake matter.
    function test_Cap_AboveThreshold_SurvivesOneSlash() public {
        test_E2E_A_CommitmentStoredAndReproducible();
        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        // 50e18 against a 30e18 gate at 3000 bps: 50 - 15 = 35 >= 30.
        uint128 overStake = 50 ether;
        staking.setLock(signers[0], overStake);

        address[] memory guilty = new address[](1);
        guilty[0] = signers[0];
        bytes memory fraudProof = abi.encode(uint256(42));
        bls.queueGuardianSlash(1, guilty, fraudProof);
        bls.executeGuardianSlash(1, guilty, fraudProof);

        uint256 remaining = staking.lockAmt(signers[0]);
        assertEq(remaining, overStake - (overStake * uint256(bls.guardianSlashBps())) / 10000, "fractional");
        assertGe(remaining, MIN_STAKE, "survives ONE finding at this stake and this bps");
    }

    /// @notice The cap is per-finding, not cumulative, and this pins the arithmetic.
    ///         `amount` is re-read from staking.roleLocks on every execution
    ///         (BLSAggregator.sol), so a second execution takes guardianSlashBps of
    ///         what is LEFT: the sequence is 0.7^n, not 1 - 0.3n. At 50e18 over a
    ///         30e18 gate that is 35e18 after the first and 24.5e18 after the second,
    ///         below the gate and ejected. So the headroom this cap buys is one
    ///         execution's worth, not immunity.
    ///
    ///         WHAT THIS TEST DOES NOT SHOW, because it would be false. The second
    ///         case here reuses the SAME fraudProof bytes under a different
    ///         fraudProofId. That is a replay, not a second independent finding, and
    ///         it only passes because this file's mock verifier discards its first
    ///         parameter — the `domainDigest` that BLSAggregator computes as
    ///         fraudProofDigest(fraudProofId, guiltyGuardians) and that the interface
    ///         requires verifiers to bind ("ignoring it re-opens cross-contract
    ///         replay"). Against a conforming verifier these two cases would need two
    ///         genuinely distinct proofs, each bound to its own id. An earlier version
    ///         of this test called them independent findings; it was measuring the
    ///         mock, not the protocol. Raised by Codex.
    ///
    ///         The arithmetic above is real regardless: it comes from re-reading the
    ///         lock, which no verifier is involved in.
    function test_Cap_IsPerFinding_SecondExecutionTakesFromWhatIsLeft() public {
        test_E2E_A_CommitmentStoredAndReproducible();
        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        uint128 overStake = 50 ether;
        staking.setLock(signers[0], overStake);

        address[] memory guilty = new address[](1);
        guilty[0] = signers[0];

        bytes memory proofOne = abi.encode(uint256(42));
        bls.queueGuardianSlash(1, guilty, proofOne);
        bls.executeGuardianSlash(1, guilty, proofOne);
        uint256 afterFirst = staking.lockAmt(signers[0]);
        assertEq(afterFirst, 35 ether, "first execution takes 30% of 50");
        assertGe(afterFirst, MIN_STAKE, "control: still in the quorum after one");

        // Same bytes, new id. See the note above: this is a replay the mock permits,
        // used here only to reach a second execution and observe the base it uses.
        bls.queueGuardianSlash(2, guilty, proofOne);
        bls.executeGuardianSlash(2, guilty, proofOne);
        uint256 afterSecond = staking.lockAmt(signers[0]);
        // 35 - 30% of 35 = 24.5. A cumulative reading predicts 50 - 2*15 = 20 and a
        // fixed-base reading predicts 35 - 15 = 20, so this number is what separates
        // re-reading the lock from not.
        assertEq(afterSecond, 24.5 ether, "second execution takes 30% of what is LEFT");
        assertLt(afterSecond, MIN_STAKE, "ejected anyway: the cap buys one execution, not immunity");
    }

    // A fraud proof pointing at a proposalId with NO commitment (never executed, or
    // executed via the generic executeProposal path) must be rejected — this is the
    // pr-daemon `require(commitment != 0)` step the real verifier enforces, and it's
    // why Phase B's proof must bind to a real Phase A proposal.
    function test_E2E_B_RejectsUnanchoredProof() public {
        test_E2E_A_CommitmentStoredAndReproducible(); // commitment exists for pid 42 ONLY
        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        address[] memory guilty = new address[](1);
        guilty[0] = signers[0];
        // Point at pid 999 — no commitment stored → verifier returns false → reject.
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidFraudProof.selector, uint256(7)));
        bls.queueGuardianSlash(7, guilty, abi.encode(uint256(999)));
    }

    // Sanity: verifier gating still fail-closed in the E2E wiring.
    function test_E2E_VerifierNotSet_Reverts() public {
        test_E2E_A_CommitmentStoredAndReproducible();
        address[] memory guilty = new address[](1);
        guilty[0] = signers[0];
        vm.expectRevert(BLSAggregator.FraudProofVerifierNotSet.selector);
        bls.queueGuardianSlash(1, guilty, hex"");
    }
}
