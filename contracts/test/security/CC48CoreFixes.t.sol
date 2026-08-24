// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IMySBT.sol";
import "src/utils/BLS.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockedPrecompiles} from "../helpers/MockedPrecompiles.sol";

/// @notice CC-48 core security fixes.
///
///  BLOCKER-1  an exit notice must not take effect in the block it is filed, must
///             not be flip-floppable, and must not be able to strand the committee
///             below quorum.
///  HIGH-1     issuance must be bounded protocol-wide, not just per proposal —
///             splitting across proposals / blocks / windows must not raise the total.
///  HIGH-2     a guardian slash must advance guardian-by-guardian and be retryable;
///             one staking-side failure must not release the whole accused set, and
///             the case window must strictly dominate a full exit notice.
///  MEDIUM-1   verifier rotation is delay-guarded, so governance cannot retroactively
///             kill a queued case.

contract CC48MockSBT is IMySBT {
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

contract CC48MockBLS {
    function defaultThreshold() external pure returns (uint256) { return 2; }
    function verify(bytes32, uint256, uint256, bytes calldata) external pure returns (bool) { return true; }
}

contract CC48MockFraudVerifier {
    bool public valid = true;
    function setValid(bool value) external { valid = value; }
    function verify(bytes32, uint256, address[] calldata, bytes calldata) external view returns (bool) { return valid; }
}

// ---------------------------------------------------------------------
// CC-48 round-4 — a REAL upgradeable verifier, not a mock with a flag.
//
// The round-3 defence snapshotted the verifier ADDRESS and re-verified against it.
// These three contracts are the counterexample: a genuine delegatecall proxy whose
// address AND extcodehash are constant across an implementation swap. Nothing the
// aggregator can observe about the address distinguishes the honest state from the
// post-upgrade one — which is why the verdict, not the judge, has to be frozen.
// ---------------------------------------------------------------------

contract CC48AlwaysTrueVerifierImpl {
    function verify(bytes32, uint256, address[] calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract CC48AlwaysFalseVerifierImpl {
    function verify(bytes32, uint256, address[] calldata, bytes calldata) external pure returns (bool) {
        return false;
    }
}

contract CC48RevertingVerifierImpl {
    error VerifierIsDown();
    function verify(bytes32, uint256, address[] calldata, bytes calldata) external pure returns (bool) {
        revert VerifierIsDown();
    }
}

/// @dev Minimal UUPS-shaped proxy: `verify` reaches the implementation through the
///      fallback's delegatecall, so the proxy's own runtime code (and therefore its
///      extcodehash) never changes when `upgradeTo` is called.
contract CC48UpgradeableVerifierProxy {
    address public implementation;

    constructor(address impl) {
        implementation = impl;
    }

    function upgradeTo(address impl) external {
        implementation = impl;
    }

    fallback() external payable {
        address impl = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

// =====================================================================
// HIGH-1 — protocol-wide outstanding credit-exposure budget
// =====================================================================

contract CC48TotalCreditExposureTest is Test {
    Registry registry;
    CC48MockBLS bls;
    address source = address(0x5150);

    function setUp() public {
        CC48MockSBT sbt = new CC48MockSBT();
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(sbt));
        bls = new CC48MockBLS();
        registry.setBLSAggregator(address(bls));
        registry.setReputationSource(source, true);
        registry.setCreditTier(1, 0);
    }

    function _proof() internal pure returns (bytes memory) {
        return abi.encode(uint256(3), bytes(""));
    }

    function _submit(uint256 id, address user, uint256 score, uint256 epoch) internal {
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = user;
        scores[0] = score;
        vm.prank(source);
        registry.batchUpdateGlobalReputation(id, users, scores, epoch, _proof());
    }

    function _user(uint256 i) internal pure returns (address) {
        return address(uint160(0xA000 + i));
    }

    /// The pre-fix bypass: N proposals in ONE block, each individually under the
    /// per-proposal cap, minting N x cap in aggregate. The stock budget stops it.
    function test_SameBlockProposalSplittingCannotExceedTotalBudget() public {
        // per-proposal 600, protocol-wide 1200 => at most two users may reach L1.
        registry.setCreditPolicy(600 ether, 1200 ether, 0, true);
        uint256 startBlock = block.number;

        _submit(1, _user(1), 100, 1);
        _submit(2, _user(2), 100, 1);
        assertEq(registry.totalCreditExposure(), 1200 ether);

        vm.prank(source);
        vm.expectRevert(
            abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, 1800 ether, 1200 ether)
        );
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = _user(3);
        scores[0] = 100;
        registry.batchUpdateGlobalReputation(3, users, scores, 1, _proof());

        assertEq(block.number, startBlock, "all three proposals in one block");
        assertEq(registry.globalReputation(_user(3)), 0, "third proposal rolled back atomically");
        assertEq(registry.totalCreditExposure(), 1200 ether, "budget unchanged by the rejected proposal");
    }

    /// A rolling-window rate limit would refill on the next window. A stock budget
    /// does not: time buys nothing.
    function test_TimePassingDoesNotRefillTheBudget() public {
        registry.setCreditPolicy(600 ether, 600 ether, 0, true);
        _submit(1, _user(1), 100, 1);
        assertEq(registry.totalCreditExposure(), 600 ether);

        vm.warp(block.timestamp + 3650 days);
        vm.roll(block.number + 1_000_000);

        vm.prank(source);
        vm.expectRevert(
            abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, 1200 ether, 600 ether)
        );
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = _user(2);
        scores[0] = 100;
        registry.batchUpdateGlobalReputation(2, users, scores, 1, _proof());
    }

    /// Genuine downgrades must give budget back, otherwise the protocol wedges
    /// permanently the first time it reaches the ceiling.
    function test_DowngradeReleasesBudgetAndAllowsReissue() public {
        registry.setCreditPolicy(600 ether, 600 ether, 0, true);
        _submit(1, _user(1), 100, 1);
        assertEq(registry.totalCreditExposure(), 600 ether);

        _submit(2, _user(1), 0, 2);
        assertEq(registry.totalCreditExposure(), 0, "downgrade released the exposure");

        _submit(3, _user(2), 100, 1);
        assertEq(registry.totalCreditExposure(), 600 ether, "released budget is reusable");
    }

    /// Mixed batches must net out rather than counting only the uplift side.
    function test_MixedBatchNetsUpAgainstDown() public {
        registry.setCreditPolicy(type(uint256).max, 600 ether, 0, true);
        _submit(1, _user(1), 100, 1);

        address[] memory users = new address[](2);
        uint256[] memory scores = new uint256[](2);
        users[0] = _user(1); scores[0] = 0;   // -600
        users[1] = _user(2); scores[1] = 100; // +600
        vm.prank(source);
        registry.batchUpdateGlobalReputation(2, users, scores, 2, _proof());

        assertEq(registry.totalCreditExposure(), 600 ether, "net zero change");
    }

    /// Zero ceiling is fail-closed for issuance but must never block de-risking.
    function test_ZeroTotalCapFailsClosedButAllowsDowngrade() public {
        registry.setCreditPolicy(type(uint256).max, 600 ether, 0, true);
        _submit(1, _user(1), 100, 1);

        registry.setCreditPolicy(type(uint256).max, 0, 0, false);

        vm.prank(source);
        vm.expectRevert(
            abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, 1200 ether, 0)
        );
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = _user(2);
        scores[0] = 100;
        registry.batchUpdateGlobalReputation(2, users, scores, 1, _proof());

        // Downgrade still lands: total goes to 0, which satisfies cap 0.
        _submit(3, _user(1), 0, 2);
        assertEq(registry.totalCreditExposure(), 0);
    }

    /// An under-counted migration baseline must saturate at zero, never underflow.
    function test_UnderSeededBaselineSaturatesInsteadOfUnderflowing() public {
        registry.setCreditPolicy(type(uint256).max, 10_000 ether, 0, true);
        _submit(1, _user(1), 100, 1);
        // Governance mistakenly resets the baseline below true outstanding exposure.
        registry.setCreditPolicy(type(uint256).max, 10_000 ether, 0, true);
        assertEq(registry.totalCreditExposure(), 0);

        _submit(2, _user(1), 0, 2); // releases 600 against a 0 total
        assertEq(registry.totalCreditExposure(), 0, "saturating subtraction, no revert");
    }

    function test_CreditPolicyIsOwnerGated() public {
        vm.prank(address(0xBAD));
        vm.expectRevert();
        registry.setCreditPolicy(1, 1, 0, false);
    }

    function test_FreshInitializerSeedsAFiniteProtocolCeiling() public view {
        assertEq(registry.maxAggregateCreditUpliftPerProposal(), 2000 ether);
        assertEq(registry.maxTotalCreditExposure(), 200_000 ether);
        assertEq(registry.totalCreditExposure(), 0);
    }
}

// =====================================================================
// BLOCKER-1 — exit notice cannot be used as an instant, reversible halt
// =====================================================================

contract CC48ExitNoticeTest is Test {
    BLSAggregator bls;
    CC48LivenessRegistryStub registry;
    CC48StakingStub staking;

    address owner = address(0xA1);
    uint8 constant N = 5;

    function _v(uint8 slot) internal pure returns (address) {
        return address(uint160(uint256(slot) + 0x100));
    }

    function _stubKey(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(uint256(0x01));
        pk.x_b = bytes32(seed);
        pk.y_a = bytes32(uint256(0x02));
        pk.y_b = bytes32(seed + 1);
    }

    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

    function _sigBytes() internal pure returns (bytes memory) {
        BLS.G2Point memory sig;
        return abi.encode(sig);
    }

    function _fullMask() internal pure returns (uint256) {
        return (uint256(1) << N) - 1;
    }

    function setUp() public {
        // CC-48 round-3 MEDIUM-5: this harness injects fake EIP-2537 precompiles, which
        // is impossible on a real Prague EVM. Step aside there; contracts/test/paper7/
        // covers these paths with genuine keys and pairings.
        if (MockedPrecompiles.skipIfReal()) return;
        vm.etch(address(0x0b), hex"60806000f3");
        vm.etch(address(0x0c), hex"60806000f3");
        vm.etch(address(0x0d), hex"6101006000f3");
        vm.etch(address(0x10), hex"60806000f3");
        vm.etch(address(0x11), hex"6101006000f3");
        // CC-48 round-3: PoP is now mandatory on BOTH registration paths, so the
        // pairing precompile must answer before any registerBLSPublicKey call in this
        // mocked-precompile harness. Real-pairing coverage of the same registrations
        // lives in contracts/test/paper7/ (RepCreditDomainReplay, CC48PragueE2E).
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        vm.warp(365 days); // keep cooldown/readyAt arithmetic away from t = 0

        vm.startPrank(owner);
        registry = new CC48LivenessRegistryStub();
        staking = new CC48StakingStub();
        registry.setStakingAddr(address(staking));
        bls = new BLSAggregator(address(registry), address(0xC0), address(0xC1));
        for (uint8 slot = 1; slot <= N; slot++) {
            registry.setHasDvtRole(_v(slot), true);
            staking.setLocked(_v(slot), 200);
            bls.registerBLSPublicKey(_v(slot), _stubKey(uint256(slot)), slot, _emptyPoP());
        }
        // 3-of-5: leaves room for two exits before the floor bites.
        bls.setDefaultThreshold(3);
        vm.stopPrank();

        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
    }

    /// The regression this whole item exists for: pre-fix, filing an exit notice
    /// made every in-flight proof containing that slot revert IMMEDIATELY, for the
    /// price of one SSTORE, and cancelGuardianExit put it straight back. That made
    /// any single ROLE_DVT member a free, self-erasing 1-of-N halt on every
    /// BLS-gated governance path.
    function test_ExitNoticeCannotHaltConsensusInTheSameBlock() public {
        vm.prank(_v(3));
        bls.requestGuardianExit();

        // Same block: the notice is on record but consensus is untouched.
        assertTrue(bls.verify(keccak256("msg"), _fullMask(), 3, _sigBytes()), "front-run had no effect");

        // Still untouched one second before the notice matures.
        vm.warp(block.timestamp + bls.GUARDIAN_EXIT_DELAY() - 1);
        assertTrue(bls.verify(keccak256("msg"), _fullMask(), 3, _sigBytes()), "in-flight proof survives the notice");

        // Only once the announced delay has fully elapsed is the slot excluded.
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotValidatorExitPending.selector, uint8(3), _v(3)));
        bls.verify(keccak256("msg"), _fullMask(), 3, _sigBytes());
    }

    /// The exclusion is always announced a full GUARDIAN_EXIT_DELAY ahead, so a
    /// proof signed today cannot be invalidated by a notice filed today.
    function test_NoticeAlwaysGivesFullDelayBeforeExclusion() public {
        uint256 t0 = block.timestamp;
        vm.prank(_v(2));
        bls.requestGuardianExit();
        (uint64 readyAt, uint64 expiresAt) = bls.guardianExitRequests(_v(2));
        assertEq(uint256(readyAt), t0 + bls.GUARDIAN_EXIT_DELAY());
        assertEq(uint256(expiresAt), uint256(readyAt) + bls.GUARDIAN_EXIT_WINDOW());
    }

    /// Flip-flopping is what made the pre-fix halt repeatable and invisible.
    function test_RequestCancelCycleIsRateLimited() public {
        uint256 cooldown = bls.GUARDIAN_EXIT_COOLDOWN();
        vm.prank(_v(3));
        bls.requestGuardianExit();
        vm.prank(_v(3));
        bls.cancelGuardianExit();
        uint256 cooldownUntil = uint256(bls.guardianExitCooldownUntil(_v(3)));
        assertEq(cooldownUntil, block.timestamp + cooldown);

        bytes memory expected =
            abi.encodeWithSelector(BLSAggregator.GuardianExitCooldownActive.selector, _v(3), cooldownUntil);
        vm.expectRevert(expected);
        vm.prank(_v(3));
        bls.requestGuardianExit();

        vm.warp(cooldownUntil);
        vm.prank(_v(3));
        bls.requestGuardianExit(); // allowed once the quiet period has elapsed
    }

    /// Even with the cooldown, N request/cancel rounds must never produce a single
    /// block in which consensus is unavailable.
    function test_RepeatedCyclesNeverProduceAHaltedBlock() public {
        for (uint256 round = 0; round < 5; round++) {
            vm.prank(_v(4));
            bls.requestGuardianExit();
            assertTrue(bls.verify(keccak256("m"), _fullMask(), 3, _sigBytes()), "no halt on request");

            vm.warp(block.timestamp + bls.GUARDIAN_EXIT_DELAY() - 1);
            assertTrue(bls.verify(keccak256("m"), _fullMask(), 3, _sigBytes()), "no halt before readyAt");

            vm.prank(_v(4));
            bls.cancelGuardianExit();
            assertTrue(bls.verify(keccak256("m"), _fullMask(), 3, _sigBytes()), "no halt after cancel");

            vm.warp(block.timestamp + bls.GUARDIAN_EXIT_COOLDOWN());
        }
    }

    /// An accused guardian must not be able to cancel its way back into the
    /// signing set while a slash case is open against it (MEDIUM-5).
    function test_AccusedGuardianCannotCancelBackIntoSignerSet() public {
        CC48MockFraudVerifier verifier = new CC48MockFraudVerifier();
        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        vm.prank(owner);
        bls.applyFraudProofVerifier();

        vm.prank(_v(5));
        bls.requestGuardianExit();

        address[] memory accused = new address[](1);
        accused[0] = _v(5);
        bls.queueGuardianSlash(1, accused, hex"01");

        vm.prank(_v(5));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitBlockedBySlash.selector, _v(5), 1));
        bls.cancelGuardianExit();
    }

    /// MEDIUM-2 — the committee may not be parked below the strictest threshold any
    /// BLS-gated path can demand.
    function test_ExitIsRefusedWhenItWouldBreakQuorum() public {
        // 5 signers, required 3 (defaultThreshold) vs 3 (MINOR/MAJOR slash) => 3.
        vm.prank(_v(1));
        bls.requestGuardianExit(); // 4 left
        vm.prank(_v(2));
        bls.requestGuardianExit(); // 3 left — still exactly at the floor

        vm.prank(_v(3));
        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.GuardianExitWouldBreakQuorum.selector, uint256(2), uint256(3))
        );
        bls.requestGuardianExit();
    }

    /// The floor tracks the STRICTEST threshold, not just defaultThreshold: a
    /// severity that needs more signers must not be silently stranded.
    function test_FloorUsesTheStrictestThresholdAcrossAllPaths() public {
        vm.prank(owner);
        bls.setSlashThreshold(uint8(ISuperPaymasterSlash.SlashLevel.MAJOR), 5);

        vm.prank(_v(1));
        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.GuardianExitWouldBreakQuorum.selector, uint256(4), uint256(5))
        );
        bls.requestGuardianExit();
    }

    /// If the committee is ALREADY short of quorum the BLS paths are dead anyway;
    /// holding guardians hostage buys nothing, so exits stay open.
    function test_AlreadyBelowQuorumDoesNotTrapGuardians() public {
        vm.prank(owner);
        bls.setSlashThreshold(uint8(ISuperPaymasterSlash.SlashLevel.MAJOR), 13);
        vm.prank(_v(1));
        bls.requestGuardianExit();
        (uint64 readyAt,) = bls.guardianExitRequests(_v(1));
        assertGt(uint256(readyAt), 0, "exit allowed when quorum is already unreachable");
    }

    /// A guardian that never held a BLS slot is not part of any mask, so the floor
    /// must not apply to it.
    function test_NonSignerGuardianIsUnaffectedByTheFloor() public {
        address plain = address(0xBEEF);
        registry.setHasDvtRole(plain, true);
        vm.prank(plain);
        bls.requestGuardianExit();
        (uint64 readyAt,) = bls.guardianExitRequests(plain);
        assertGt(uint256(readyAt), 0);
    }

    /// LOW — an expired notice keeps excluding the slot; cancelling is the
    /// supported way back in, and it costs a cooldown.
    function test_ExpiredNoticeIsClearedByCancel() public {
        vm.prank(_v(3));
        bls.requestGuardianExit();
        vm.warp(block.timestamp + bls.GUARDIAN_EXIT_DELAY() + bls.GUARDIAN_EXIT_WINDOW() + 1);

        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotValidatorExitPending.selector, uint8(3), _v(3)));
        bls.verify(keccak256("m"), _fullMask(), 3, _sigBytes());

        vm.prank(_v(3));
        bls.cancelGuardianExit();
        assertTrue(bls.verify(keccak256("m"), _fullMask(), 3, _sigBytes()));
    }

    /// MEDIUM-1 — a queued case must outlive any verifier rotation started after it,
    /// so an owner cannot swap in an always-false verifier to time the case out.
    function test_VerifierRotationCannotOutrunAQueuedCase() public {
        CC48MockFraudVerifier good = new CC48MockFraudVerifier();
        CC48MockFraudVerifier evil = new CC48MockFraudVerifier();
        evil.setValid(false);

        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(good));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        address[] memory accused = new address[](1);
        accused[0] = _v(5);
        uint256 queuedAt = block.timestamp;
        bls.queueGuardianSlash(7, accused, hex"07");

        // Owner immediately tries to neutralise the case.
        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(evil));

        (,, uint64 caseDeadline,,,,) = bls.guardianSlashCases(7);
        assertEq(uint256(caseDeadline), queuedAt + bls.GUARDIAN_SLASH_CASE_WINDOW());
        assertGe(
            uint256(bls.pendingFraudProofVerifierReadyAt()),
            uint256(caseDeadline),
            "rotation cannot mature before the case deadline"
        );
    }

    function test_VerifierRotationCanBeCancelledByOwnerOnly() public {
        CC48MockFraudVerifier v = new CC48MockFraudVerifier();
        vm.prank(owner);
        bls.proposeFraudProofVerifier(address(v));

        vm.prank(address(0xBAD));
        vm.expectRevert();
        bls.cancelFraudProofVerifierRotation();

        vm.prank(owner);
        bls.cancelFraudProofVerifierRotation();
        assertEq(uint256(bls.pendingFraudProofVerifierReadyAt()), 0);
        vm.expectRevert(BLSAggregator.NoPendingVerifierRotation.selector);
        bls.applyFraudProofVerifier();
    }
}

// =====================================================================
// HIGH-2 — partial, retryable guardian slash + case/exit timing
// =====================================================================

contract CC48GuardianSlashRetryTest is Test {
    Registry registry;
    GTokenStaking staking;
    GToken gtoken;
    BLSAggregator bls;
    CC48MockFraudVerifier verifier;

    address g1 = address(0x6001);
    address g2 = address(0x6002);

    function setUp() public {
        vm.warp(365 days);
        CC48MockSBT sbt = new CC48MockSBT();
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(sbt));
        gtoken = new GToken(1_000_000 ether);
        staking = new GTokenStaking(address(gtoken), address(this), address(registry));
        registry.setStaking(address(staking));
        bls = new BLSAggregator(address(registry), address(0x5050), address(0xD57));
        verifier = new CC48MockFraudVerifier();
        registry.setBLSAggregator(address(bls));
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();
        staking.setAuthorizedSlasher(address(bls), true);

        IRegistry.RoleConfig memory dvtConfig = registry.getRoleConfig(ROLE_DVT);
        dvtConfig.roleLockDuration = 0;
        registry.configureRole(ROLE_DVT, dvtConfig);

        _seat(g1);
        _seat(g2);
    }

    function _seat(address g) internal {
        gtoken.mint(g, 100 ether);
        vm.prank(g);
        gtoken.approve(address(staking), 100 ether);
        vm.prank(g);
        registry.registerRole(ROLE_DVT, g, abi.encode(uint256(30 ether)));
    }

    function _both() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = g1;
        a[1] = g2;
    }

    /// The HIGH-2 regression: pre-fix, ONE failing slashByDVT reverted the whole
    /// batch, and if the failure outlasted the deadline the case expired and freed
    /// EVERY accused guardian. Now the healthy guardian is slashed and banked, the
    /// failing one stays frozen, and the case stays retryable.
    function test_OneFailingSlashDoesNotBlockOrReleaseTheRest() public {
        address[] memory accused = _both();
        bls.queueGuardianSlash(1, accused, hex"01");
        assertEq(bls.pendingGuardianSlashCount(g1), 1);
        assertEq(bls.pendingGuardianSlashCount(g2), 1);

        // Make g2's slash revert on the staking side, leaving g1 slashable.
        staking.setAuthorizedSlasher(address(bls), true);
        vm.mockCallRevert(
            address(staking),
            abi.encodeWithSelector(IGTokenStakingSlash.slashByDVT.selector, g2, ROLE_DVT),
            "staking down"
        );

        vm.expectEmit(true, true, false, false);
        emit BLSAggregator.GuardianSlashFailed(1, g2);
        bls.executeGuardianSlash(1, accused, hex"01");

        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0, "healthy guardian was slashed");
        assertEq(bls.pendingGuardianSlashCount(g1), 0, "healthy guardian released");
        assertEq(bls.pendingGuardianSlashCount(g2), 1, "failing guardian still frozen");
        assertTrue(bls.guardianSlashed(1, g1));
        assertFalse(bls.guardianSlashed(1, g2));

        (,,, uint8 status,, uint16 resolved,) = bls.guardianSlashCases(1);
        assertEq(status, 1, "case stays pending, not silently executed");
        assertEq(resolved, 1);

        // g2 must not be able to walk out while it is still unresolved.
        vm.prank(g2);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitBlockedBySlash.selector, g2, 1));
        bls.requestGuardianExit();

        // Staking recovers -> retry succeeds and the case closes. g1 is not
        // double-slashed on the retry.
        vm.clearMockedCalls();
        bls.executeGuardianSlash(1, accused, hex"01");
        assertEq(bls.pendingGuardianSlashCount(g2), 0);
        assertEq(staking.getLockedStake(g2, ROLE_DVT), 0);
        (,,, status,, resolved,) = bls.guardianSlashCases(1);
        assertEq(status, 2, "case resolved once every guardian settled");
        assertEq(resolved, 2);
    }

    /// Expiry must only free the guardians that were never settled — the ones
    /// already slashed must not have their counter decremented twice.
    function test_ExpiryOnlyReleasesUnresolvedGuardians() public {
        address[] memory accused = _both();
        bls.queueGuardianSlash(2, accused, hex"02");

        vm.mockCallRevert(
            address(staking),
            abi.encodeWithSelector(IGTokenStakingSlash.slashByDVT.selector, g2, ROLE_DVT),
            "staking down"
        );
        bls.executeGuardianSlash(2, accused, hex"02");
        assertEq(bls.pendingGuardianSlashCount(g1), 0);
        assertEq(bls.pendingGuardianSlashCount(g2), 1);

        vm.clearMockedCalls();
        vm.warp(block.timestamp + bls.GUARDIAN_SLASH_CASE_WINDOW() + 1);
        bls.expireGuardianSlashCase(2, accused);

        assertEq(bls.pendingGuardianSlashCount(g1), 0, "no double decrement");
        assertEq(bls.pendingGuardianSlashCount(g2), 0);
        assertTrue(bls.guardianCaseResolved(2, g1));
        assertTrue(bls.guardianCaseResolved(2, g2));
    }

    /// The timing hole: with a 2-day case window and a 2-day exit delay, an exit
    /// notice filed at queue time matured exactly as the case expired. The window
    /// must strictly dominate delay + consumption window.
    function test_CaseWindowStrictlyDominatesAFullExitNotice() public {
        assertGt(
            bls.GUARDIAN_SLASH_CASE_WINDOW(),
            bls.GUARDIAN_EXIT_DELAY() + bls.GUARDIAN_EXIT_WINDOW(),
            "case window must outlast a full exit notice"
        );

        address[] memory accused = new address[](1);
        accused[0] = g1;

        vm.prank(g1);
        bls.requestGuardianExit();
        bls.queueGuardianSlash(3, accused, hex"03");

        (,, uint64 deadline,,,,) = bls.guardianSlashCases(3);
        (, uint64 expiresAt) = bls.guardianExitRequests(g1);
        // NOTE: read these into memory BEFORE any vm.warp — via-IR happily CSEs
        // block.timestamp across a cheatcode it cannot see.
        uint256 caseDeadline = uint256(deadline);
        uint256 noticeExpiry = uint256(expiresAt);
        assertLt(noticeExpiry, caseDeadline, "notice expires before the case does");

        // Walk to the end of the exit window: consumption is blocked throughout.
        vm.warp(noticeExpiry);
        vm.prank(g1);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitBlockedBySlash.selector, g1, 1));
        registry.exitRole(ROLE_DVT);

        // Case expires later; by then the notice is dead and a fresh one costs
        // another full GUARDIAN_EXIT_DELAY.
        vm.warp(caseDeadline + 1);
        bls.expireGuardianSlashCase(3, accused);
        vm.prank(g1);
        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.GuardianExitRequestExpired.selector, g1, noticeExpiry)
        );
        registry.exitRole(ROLE_DVT);
    }

    /// A guardian with nothing left to take is settled (not retried forever), but
    /// that must not consume the proof on behalf of the still-staked colluders.
    function test_ZeroLockGuardianIsSettledWithoutBurningTheCase() public {
        address[] memory accused = _both();
        bls.queueGuardianSlash(4, accused, hex"04");

        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(IGTokenStaking.roleLocks.selector, g1, ROLE_DVT),
            abi.encode(uint128(0), uint128(0), uint48(0), ROLE_DVT, bytes(""))
        );
        bls.executeGuardianSlash(4, accused, hex"04");
        vm.clearMockedCalls();

        assertEq(bls.pendingGuardianSlashCount(g1), 0);
        assertFalse(bls.guardianSlashed(4, g1), "nothing was taken from g1");
        assertTrue(bls.guardianSlashed(4, g2), "g2 was still slashed under the same proof");
        (,,, uint8 status,,,) = bls.guardianSlashCases(4);
        assertEq(status, 2);
    }

    /// A resolved case must not be replayable, and a fresh fraudProofId remains
    /// available for a re-opened case over the same guardian set.
    function test_ResolvedCaseCannotReplayButNewIdCanReopen() public {
        address[] memory accused = new address[](1);
        accused[0] = g1;
        bls.queueGuardianSlash(5, accused, hex"05");
        bls.executeGuardianSlash(5, accused, hex"05");

        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianSlashCaseNotPending.selector, uint256(5)));
        bls.executeGuardianSlash(5, accused, hex"05");

        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianSlashCaseAlreadyOpened.selector, uint256(5)));
        bls.queueGuardianSlash(5, accused, hex"05");

        // Same guardian set, new id from the verifier's id-space: allowed.
        bls.queueGuardianSlash(6, accused, hex"06");
        assertEq(bls.pendingGuardianSlashCount(g1), 1);
    }

    // =================================================================
    // CC-48 round-3 HIGH-1 — the case is bound to the verifier that opened it
    // =================================================================

    /// THE regression. Round-2 claimed `VERIFIER_ROTATION_DELAY` made a queued case
    /// immune to a governance verifier swap. It did not: the delay bounds
    /// propose -> apply, but NOTHING bounds matured -> apply, and
    /// `applyFraudProofVerifier` is permissionless. So an owner could arm a rotation
    /// long in advance, let it mature, and leave it sitting — a loaded gun — then fire
    /// it one second after a watcher queues a case. `executeGuardianSlash` read the
    /// LIVE verifier, so from that block on it returned false forever and the case ran
    /// out to expiry, releasing the accused.
    ///
    /// This test walks exactly that timeline and asserts the slash still lands.
    function test_PreArmedVerifierRotationCannotKillAQueuedCase() public {
        CC48MockFraudVerifier evil = new CC48MockFraudVerifier();
        evil.setValid(false);

        // T0: arm the rotation, then let it fully mature WITHOUT applying it.
        bls.proposeFraudProofVerifier(address(evil));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY() + 1);
        assertLe(uint256(bls.pendingFraudProofVerifierReadyAt()), block.timestamp, "rotation is armed and matured");

        // T0 + delay + X: a watcher queues a case against the CURRENT (honest) verifier.
        address[] memory accused = new address[](1);
        accused[0] = g1;
        bls.queueGuardianSlash(10, accused, hex"10");
        (,,,,,, address pinned) = bls.guardianSlashCases(10);
        assertEq(pinned, address(verifier), "case pinned the verifier that authorized it");

        // One block later: fire the pre-armed rotation. Permissionless, and legitimate
        // by the rotation rules — the delay was served in full.
        bls.applyFraudProofVerifier();
        assertEq(bls.fraudProofVerifier(), address(evil), "the live verifier is now the always-false one");

        // Pre-fix this reverted InvalidFraudProof and kept doing so until expiry.
        bls.executeGuardianSlash(10, accused, hex"10");
        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0, "the colluder was slashed under the pinned verifier");
        (,,, uint8 status,,,) = bls.guardianSlashCases(10);
        assertEq(status, 2, "case resolved");
    }

    /// The retry path must use the SAME pinned verifier, not the live one — otherwise
    /// the attack above just moves to the window between a partial execution and its
    /// retry, which is where a real slash spends most of its life.
    function test_RetryAfterRotationStillUsesThePinnedVerifier() public {
        CC48MockFraudVerifier evil = new CC48MockFraudVerifier();
        evil.setValid(false);

        address[] memory accused = _both();
        bls.queueGuardianSlash(11, accused, hex"11");

        // Partial execution: g2's staking call reverts, so g2 stays frozen + retryable.
        vm.mockCallRevert(
            address(staking),
            abi.encodeWithSelector(IGTokenStakingSlash.slashByDVT.selector, g2, ROLE_DVT),
            "staking down"
        );
        bls.executeGuardianSlash(11, accused, hex"11");
        assertEq(bls.pendingGuardianSlashCount(g2), 1, "g2 still frozen");
        vm.clearMockedCalls();

        // Rotate to the always-false verifier in the retry window.
        bls.proposeFraudProofVerifier(address(evil));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        // The case deadline has NOT passed (window > rotation delay is not assumed;
        // assert it, because the retry has to be reachable for this test to mean
        // anything).
        (,, uint64 deadline,,,,) = bls.guardianSlashCases(11);
        assertLe(block.timestamp, uint256(deadline), "retry window still open");

        bls.executeGuardianSlash(11, accused, hex"11");
        assertEq(bls.pendingGuardianSlashCount(g2), 0, "retry settled g2 under the pinned verifier");
        (,,, uint8 status,,,) = bls.guardianSlashCases(11);
        assertEq(status, 2);
    }

    /// Pinning must not make a case immortal: expiry is verifier-independent and still
    /// releases the accused on schedule, rotation or not.
    function test_ExpiryIsUnaffectedByARotation() public {
        CC48MockFraudVerifier next = new CC48MockFraudVerifier();

        address[] memory accused = new address[](1);
        accused[0] = g1;
        bls.queueGuardianSlash(12, accused, hex"12");

        bls.proposeFraudProofVerifier(address(next));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        (,, uint64 rawDeadline,,,,) = bls.guardianSlashCases(12);
        uint256 caseDeadline = uint256(rawDeadline);
        vm.warp(caseDeadline + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.GuardianSlashCaseExpiredError.selector, uint256(12), caseDeadline
            )
        );
        bls.executeGuardianSlash(12, accused, hex"12");

        bls.expireGuardianSlashCase(12, accused);
        assertEq(bls.pendingGuardianSlashCount(g1), 0, "expiry releases the freeze");
        (,,, uint8 status,,,) = bls.guardianSlashCases(12);
        assertEq(status, 3);
    }

    /// The LIVE verifier is the authority for opening a case — that much is unchanged.
    /// What changed in round-4 is that its authority ends the moment the case is queued:
    /// the audit field records who approved it, and a later `setValid(false)` on that very
    /// verifier cannot reach back into the open case.
    function test_ANewCaseAfterRotationRecordsTheNewVerifierAndThenIgnoresIt() public {
        CC48MockFraudVerifier next = new CC48MockFraudVerifier();
        bls.proposeFraudProofVerifier(address(next));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        // The new verifier really is the gate at QUEUE time: while it rejects, no case
        // can be opened at all.
        address[] memory accused = new address[](1);
        accused[0] = g1;
        next.setValid(false);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidFraudProof.selector, uint256(13)));
        bls.queueGuardianSlash(13, accused, hex"13");

        next.setValid(true);
        bls.queueGuardianSlash(13, accused, hex"13");
        (,,,,,, address recorded) = bls.guardianSlashCases(13);
        assertEq(recorded, address(next), "the case records the verifier that approved it");

        // ...and now that the verdict is frozen, the same verifier flipping to reject is
        // simply not consulted.
        next.setValid(false);
        bls.executeGuardianSlash(13, accused, hex"13");
        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0, "frozen verdict survives the verifier's change of mind");
    }

    /// A verifier that selfdestructs / is wiped must NOT be able to strand a queued case.
    /// Round-3 failed closed here (revert until expiry, accused released); with the verdict
    /// frozen there is nothing left to fail on, so the slash still lands.
    function test_ExecutionSurvivesThePinnedVerifierDisappearing() public {
        address[] memory accused = new address[](1);
        accused[0] = g1;
        bls.queueGuardianSlash(14, accused, hex"14");

        assertEq(bls.fraudProofVerifier(), address(verifier));
        vm.etch(address(verifier), hex""); // selfdestruct / wipe
        assertEq(address(verifier).code.length, 0, "verifier really is gone");

        bls.executeGuardianSlash(14, accused, hex"14");
        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0, "slash lands without the verifier");
        assertEq(bls.pendingGuardianSlashCount(g1), 0, "freeze released by execution, not by expiry");
        (,,, uint8 status,,,) = bls.guardianSlashCases(14);
        assertEq(status, 2, "case resolved");
    }

    /// A snapshot is only meaningful if it points at code: queueing against an EOA
    /// verifier is rejected up front rather than pinning a case to something that can
    /// never answer.
    function test_QueueRejectsAnEOAVerifier() public {
        address eoa = address(0xE0A);
        bls.proposeFraudProofVerifier(eoa);
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        address[] memory accused = new address[](1);
        accused[0] = g1;
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.VerifierNotContract.selector, eoa));
        bls.queueGuardianSlash(15, accused, hex"15");
    }

    /// Dormancy is still enforced at queue time: with no verifier wired, no case can be
    /// opened, so there is nothing to pin.
    function test_QueueStillRequiresAWiredVerifier() public {
        bls.proposeFraudProofVerifier(address(0));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();

        address[] memory accused = new address[](1);
        accused[0] = g1;
        vm.expectRevert(BLSAggregator.FraudProofVerifierNotSet.selector);
        bls.queueGuardianSlash(16, accused, hex"16");
    }
}

// =====================================================================
// CC-48 round-4 HIGH — the frozen VERDICT, against a real mutable proxy verifier
// =====================================================================

/// Round-3 pinned the verifier ADDRESS and re-verified against it at execute/retry time.
/// This suite is the attack that defeats that: a real delegatecall proxy keeps its address
/// AND its extcodehash across an implementation swap, so the "pinned" verifier can be
/// turned into an always-false one after a case is queued and the accused walks at expiry.
///
/// The round-4 rule is that `queueGuardianSlash` freezes keccak256(fraudProof) together
/// with the guardian set, and execute/retry only re-check those two — no verifier call at
/// all. Every test below asserts a property of that rule, not of a mock's flag.
contract CC48MutableProxyVerifierTest is Test {
    Registry registry;
    GTokenStaking staking;
    GToken gtoken;
    BLSAggregator bls;

    CC48UpgradeableVerifierProxy proxy;
    address alwaysTrue;
    address alwaysFalse;
    address reverting;

    address g1 = address(0x7001);
    address g2 = address(0x7002);

    bytes constant PROOF = hex"c0ffee";
    bytes constant OTHER_PROOF = hex"deadbeef";

    function setUp() public {
        vm.warp(365 days);
        CC48MockSBT sbt = new CC48MockSBT();
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(sbt));
        gtoken = new GToken(1_000_000 ether);
        staking = new GTokenStaking(address(gtoken), address(this), address(registry));
        registry.setStaking(address(staking));
        bls = new BLSAggregator(address(registry), address(0x5050), address(0xD57));
        registry.setBLSAggregator(address(bls));

        alwaysTrue = address(new CC48AlwaysTrueVerifierImpl());
        alwaysFalse = address(new CC48AlwaysFalseVerifierImpl());
        reverting = address(new CC48RevertingVerifierImpl());
        proxy = new CC48UpgradeableVerifierProxy(alwaysTrue);

        bls.proposeFraudProofVerifier(address(proxy));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();
        staking.setAuthorizedSlasher(address(bls), true);

        IRegistry.RoleConfig memory dvtConfig = registry.getRoleConfig(ROLE_DVT);
        dvtConfig.roleLockDuration = 0;
        registry.configureRole(ROLE_DVT, dvtConfig);

        _seat(g1);
        _seat(g2);
    }

    function _seat(address g) internal {
        gtoken.mint(g, 100 ether);
        vm.prank(g);
        gtoken.approve(address(staking), 100 ether);
        vm.prank(g);
        registry.registerRole(ROLE_DVT, g, abi.encode(uint256(30 ether)));
    }

    function _one(address g) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = g;
    }

    function _both() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = g1;
        a[1] = g2;
    }

    /// Establishes the premise the whole suite rests on: swapping the implementation
    /// changes NOTHING an on-chain observer can see about the verifier address.
    /// `code.length`, the address itself, and `extcodehash` are all identical before and
    /// after — so no snapshot of any of them could have detected this.
    function test_ProxyUpgradeIsInvisibleToAddressAndCodehash() public {
        address addrBefore = address(proxy);
        uint256 lenBefore = addrBefore.code.length;
        bytes32 hashBefore;
        assembly { hashBefore := extcodehash(addrBefore) }

        proxy.upgradeTo(alwaysFalse);

        uint256 lenAfter = addrBefore.code.length;
        bytes32 hashAfter;
        assembly { hashAfter := extcodehash(addrBefore) }

        assertEq(lenAfter, lenBefore, "code length unchanged by the upgrade");
        assertEq(hashAfter, hashBefore, "extcodehash unchanged by the upgrade");
        assertEq(proxy.implementation(), alwaysFalse, "but the semantics did change");
    }

    /// THE round-4 regression. queue true -> upgrade the SAME address to always-false ->
    /// execute must still slash. Under round-3 this reverted `InvalidFraudProof` and kept
    /// reverting until the case expired and released the colluder.
    function test_QueuedCaseSurvivesAnImplementationSwapAtTheSameAddress() public {
        address[] memory accused = _one(g1);
        bls.queueGuardianSlash(20, accused, PROOF);
        (, bytes32 frozenProofHash,,,,, address recorded) = bls.guardianSlashCases(20);
        assertEq(frozenProofHash, keccak256(PROOF), "verdict frozen as the proof hash");
        assertEq(recorded, address(proxy), "verifier recorded for audit");

        // The attack: same address, same codehash, opposite answer.
        proxy.upgradeTo(alwaysFalse);
        assertFalse(
            IFraudProofVerifier(address(proxy)).verify(
                bls.fraudProofDigest(20, accused), 20, accused, PROOF
            ),
            "the live verifier now rejects the very proof it approved"
        );

        bls.executeGuardianSlash(20, accused, PROOF);
        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0, "the colluder was slashed anyway");
        assertEq(bls.pendingGuardianSlashCount(g1), 0);
        (,,, uint8 status,,,) = bls.guardianSlashCases(20);
        assertEq(status, 2, "case resolved");
    }

    /// Freezing the verdict must not create a "any bytes will do" hole: the executor has
    /// to re-present the exact proof the verifier approved.
    function test_ExecutionRejectsASubstitutedProof() public {
        address[] memory accused = _one(g1);
        bls.queueGuardianSlash(21, accused, PROOF);

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.FraudProofMismatch.selector,
                uint256(21),
                keccak256(PROOF),
                keccak256(OTHER_PROOF)
            )
        );
        bls.executeGuardianSlash(21, accused, OTHER_PROOF);

        // Even an empty proof — the degenerate substitution — is refused.
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.FraudProofMismatch.selector, uint256(21), keccak256(PROOF), keccak256(bytes(""))
            )
        );
        bls.executeGuardianSlash(21, accused, "");

        assertEq(bls.pendingGuardianSlashCount(g1), 1, "case untouched by the failed attempts");
        bls.executeGuardianSlash(21, accused, PROOF);
        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0);
    }

    /// A substituted proof must be refused even when the CURRENT implementation would
    /// happily approve it — the frozen verdict, not the live verifier, is the authority
    /// in both directions.
    function test_SubstitutedProofIsRefusedEvenIfTheLiveVerifierWouldApproveIt() public {
        address[] memory accused = _one(g1);
        bls.queueGuardianSlash(22, accused, PROOF);

        // Live verifier still says yes to anything, including OTHER_PROOF.
        assertTrue(
            IFraudProofVerifier(address(proxy)).verify(
                bls.fraudProofDigest(22, accused), 22, accused, OTHER_PROOF
            )
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.FraudProofMismatch.selector,
                uint256(22),
                keccak256(PROOF),
                keccak256(OTHER_PROOF)
            )
        );
        bls.executeGuardianSlash(22, accused, OTHER_PROOF);
    }

    /// The retry window is where a slash spends most of its life, so the upgrade attack
    /// is repeated there: partial execution, THEN the swap, then the retry with the same
    /// proof must still settle the remaining guardian.
    function test_PartialRetryAfterUpgradeUsesTheSameFrozenProof() public {
        address[] memory accused = _both();
        bls.queueGuardianSlash(23, accused, PROOF);

        vm.mockCallRevert(
            address(staking),
            abi.encodeWithSelector(IGTokenStakingSlash.slashByDVT.selector, g2, ROLE_DVT),
            "staking down"
        );
        bls.executeGuardianSlash(23, accused, PROOF);
        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0, "g1 banked");
        assertEq(bls.pendingGuardianSlashCount(g2), 1, "g2 still frozen and retryable");
        vm.clearMockedCalls();

        // Swap the implementation mid-case, then retry.
        proxy.upgradeTo(alwaysFalse);

        (,, uint64 deadline,,,,) = bls.guardianSlashCases(23);
        assertLe(block.timestamp, uint256(deadline), "retry window still open");

        bls.executeGuardianSlash(23, accused, PROOF);
        assertEq(staking.getLockedStake(g2, ROLE_DVT), 0, "g2 settled after the upgrade");
        assertEq(bls.pendingGuardianSlashCount(g2), 0);
        (,,, uint8 status,,,) = bls.guardianSlashCases(23);
        assertEq(status, 2);

        // ...and the retry path is equally strict about the proof. (Opening a fresh case
        // still needs the LIVE implementation to approve, so restore it first — queue-time
        // authority is unchanged by this fix.)
        proxy.upgradeTo(alwaysTrue);
        bls.queueGuardianSlash(24, _one(g1), PROOF);
        proxy.upgradeTo(alwaysFalse);
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.FraudProofMismatch.selector,
                uint256(24),
                keccak256(PROOF),
                keccak256(OTHER_PROOF)
            )
        );
        bls.executeGuardianSlash(24, _one(g1), OTHER_PROOF);
    }

    /// A verifier that has been upgraded to a REVERTING implementation is the outage
    /// variant of the same attack (deny instead of deny-by-answer). It must not strand
    /// the case either.
    function test_QueuedCaseSurvivesAnUpgradeToARevertingImplementation() public {
        address[] memory accused = _one(g1);
        bls.queueGuardianSlash(25, accused, PROOF);

        // Compute the digest BEFORE expectRevert — it is a call of its own and would
        // otherwise absorb the expectation.
        bytes32 digest = bls.fraudProofDigest(25, accused);
        proxy.upgradeTo(reverting);
        vm.expectRevert(CC48RevertingVerifierImpl.VerifierIsDown.selector);
        IFraudProofVerifier(address(proxy)).verify(digest, 25, accused, PROOF);

        bls.executeGuardianSlash(25, accused, PROOF);
        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0, "outage cannot veto a frozen verdict");
    }

    /// Freezing the verdict must not make a case immortal: expiry is unchanged, still
    /// permissionless, and still releases the accused on schedule — upgrade or no upgrade.
    function test_ExpiryIsUnchangedByTheFrozenVerdictAndByAnUpgrade() public {
        address[] memory accused = _one(g1);
        bls.queueGuardianSlash(26, accused, PROOF);
        proxy.upgradeTo(alwaysFalse);

        (,, uint64 rawDeadline,,,,) = bls.guardianSlashCases(26);
        uint256 caseDeadline = uint256(rawDeadline);
        vm.warp(caseDeadline + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.GuardianSlashCaseExpiredError.selector, uint256(26), caseDeadline
            )
        );
        bls.executeGuardianSlash(26, accused, PROOF);

        bls.expireGuardianSlashCase(26, accused);
        assertEq(bls.pendingGuardianSlashCount(g1), 0, "expiry still releases the freeze");
        assertEq(staking.getLockedStake(g1, ROLE_DVT), 30 ether, "and nothing was slashed");
        (,,, uint8 status,,,) = bls.guardianSlashCases(26);
        assertEq(status, 3);
    }

    /// A verifier ROTATION after queueing is the round-3 scenario; it must still be a
    /// no-op for an open case now that nothing external is consulted.
    function test_RotationAfterQueueingStillCannotTouchAnOpenCase() public {
        address[] memory accused = _one(g1);
        bls.queueGuardianSlash(27, accused, PROOF);

        CC48UpgradeableVerifierProxy evil = new CC48UpgradeableVerifierProxy(alwaysFalse);
        bls.proposeFraudProofVerifier(address(evil));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();
        assertEq(bls.fraudProofVerifier(), address(evil));

        (,, uint64 deadline,,,,) = bls.guardianSlashCases(27);
        assertLe(block.timestamp, uint256(deadline), "case still open");

        bls.executeGuardianSlash(27, accused, PROOF);
        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0);
    }

    /// The guardian-set half of the frozen verdict is still enforced independently: a
    /// caller cannot keep the approved proof and swap in a different accused set.
    function test_GuardianSetIsStillPinnedAlongsideTheProof() public {
        bls.queueGuardianSlash(28, _one(g1), PROOF);

        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianSetMismatch.selector, uint256(28)));
        bls.executeGuardianSlash(28, _one(g2), PROOF);

        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianSetMismatch.selector, uint256(28)));
        bls.executeGuardianSlash(28, _both(), PROOF);

        assertEq(staking.getLockedStake(g2, ROLE_DVT), 30 ether, "the un-accused guardian is untouched");
    }

    /// The upgrade attack must not work at QUEUE time either: while the live
    /// implementation rejects, no case can be opened — the freeze only ever captures a
    /// verdict the verifier actually gave.
    function test_QueueStillHonoursTheLiveImplementation() public {
        proxy.upgradeTo(alwaysFalse);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidFraudProof.selector, uint256(29)));
        bls.queueGuardianSlash(29, _one(g1), PROOF);

        proxy.upgradeTo(alwaysTrue);
        bls.queueGuardianSlash(29, _one(g1), PROOF);
        (, bytes32 frozen,,,,,) = bls.guardianSlashCases(29);
        assertEq(frozen, keccak256(PROOF));
    }
}

/// Minimal registry/staking stubs for the exit-notice suite (no real staking).
// =====================================================================
// CC-48 round-5 MEDIUM-2 — emergency disarm of the fraud-proof verifier
// =====================================================================

/// @notice Before round-5 the ONLY way to take a lying verifier off-line was
///         `proposeFraudProofVerifier(0)` + `VERIFIER_ROTATION_DELAY` (4 days) +
///         `applyFraudProofVerifier`. A compromised verifier can open a case and have
///         100% of every accused guardian's lock taken in a SINGLE block, so a four-day
///         remedy was not a remedy — and round-4's own documentation described the
///         remedy as stronger than the contract actually made it.
///
///         The addition is deliberately asymmetric, and these tests pin that asymmetry:
///         disarming is immediate because it only ever REMOVES power; re-arming still
///         costs the full delay; and an already-queued case is decided by its frozen
///         verdict, so the owner cannot use "emergency" as a way to rescue an accused
///         colluder.
contract CC48VerifierDisarmTest is Test {
    Registry registry;
    GTokenStaking staking;
    GToken gtoken;
    BLSAggregator bls;
    CC48MockFraudVerifier verifier;

    address constant NOT_OWNER = address(0x7777);
    address g1 = address(0x6101);
    address g2 = address(0x6102);

    function setUp() public {
        vm.warp(365 days);
        CC48MockSBT sbt = new CC48MockSBT();
        registry = UUPSDeployHelper.deployRegistryProxy(address(this), address(0), address(sbt));
        gtoken = new GToken(1_000_000 ether);
        staking = new GTokenStaking(address(gtoken), address(this), address(registry));
        registry.setStaking(address(staking));
        bls = new BLSAggregator(address(registry), address(0x5050), address(0xD57));
        verifier = new CC48MockFraudVerifier();
        registry.setBLSAggregator(address(bls));
        bls.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY());
        bls.applyFraudProofVerifier();
        staking.setAuthorizedSlasher(address(bls), true);

        IRegistry.RoleConfig memory dvtConfig = registry.getRoleConfig(ROLE_DVT);
        dvtConfig.roleLockDuration = 0;
        registry.configureRole(ROLE_DVT, dvtConfig);

        _seat(g1);
        _seat(g2);
    }

    function _seat(address g) internal {
        gtoken.mint(g, 100 ether);
        vm.prank(g);
        gtoken.approve(address(staking), 100 ether);
        vm.prank(g);
        registry.registerRole(ROLE_DVT, g, abi.encode(uint256(30 ether)));
    }

    function _both() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = g1;
        a[1] = g2;
    }

    /// The whole point: it takes effect in THIS block, not in four days.
    function test_DisarmIsImmediateAndStopsNewCases() public {
        address[] memory accused = _both();
        // Armed: a case can be opened right now.
        bls.queueGuardianSlash(1, accused, hex"01");

        bls.emergencyDisarmFraudProofVerifier();
        assertEq(bls.fraudProofVerifier(), address(0), "verifier cleared in the same tx");

        vm.expectRevert(BLSAggregator.FraudProofVerifierNotSet.selector);
        bls.queueGuardianSlash(2, accused, hex"02");

        // Not merely "later" — no amount of waiting re-arms it.
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(BLSAggregator.FraudProofVerifierNotSet.selector);
        bls.queueGuardianSlash(3, accused, hex"03");
    }

    /// A rotation already in flight is part of the attack surface being removed: leaving
    /// it queued would let the pending verifier install itself when its delay matures.
    function test_DisarmAlsoClearsAnInFlightRotation() public {
        CC48MockFraudVerifier next = new CC48MockFraudVerifier();
        bls.proposeFraudProofVerifier(address(next));
        assertEq(bls.pendingFraudProofVerifier(), address(next));
        assertTrue(bls.pendingFraudProofVerifierReadyAt() != 0);

        bls.emergencyDisarmFraudProofVerifier();

        assertEq(bls.pendingFraudProofVerifier(), address(0), "pending rotation cleared");
        assertEq(bls.pendingFraudProofVerifierReadyAt(), 0);

        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY() + 1);
        vm.expectRevert(BLSAggregator.NoPendingVerifierRotation.selector);
        bls.applyFraudProofVerifier();
        assertEq(bls.fraudProofVerifier(), address(0), "nothing matured into place");
    }

    /// The asymmetry that makes immediacy safe: an owner cannot use disarm as a fast
    /// path to a verifier of its choosing. Coming back on-line is still four days.
    function test_ReArmingStillCostsAFullRotationDelay() public {
        bls.emergencyDisarmFraudProofVerifier();

        CC48MockFraudVerifier next = new CC48MockFraudVerifier();
        bls.proposeFraudProofVerifier(address(next));
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.VerifierRotationNotReady.selector, bls.pendingFraudProofVerifierReadyAt()
            )
        );
        bls.applyFraudProofVerifier();

        vm.warp(block.timestamp + bls.VERIFIER_ROTATION_DELAY() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.VerifierRotationNotReady.selector, bls.pendingFraudProofVerifierReadyAt()
            )
        );
        bls.applyFraudProofVerifier();

        vm.warp(block.timestamp + 1);
        bls.applyFraudProofVerifier();
        assertEq(bls.fraudProofVerifier(), address(next));
    }

    /// The other half of the asymmetry: the owner may stop FUTURE accusations, and may
    /// NOT rescue an already-accused colluder. Execution reads the verdict frozen at
    /// queue time and never touches `fraudProofVerifier`, so disarming is invisible to it.
    function test_AQueuedCaseStillExecutesOnItsFrozenVerdictAfterDisarm() public {
        address[] memory accused = _both();
        bls.queueGuardianSlash(9, accused, hex"09");

        bls.emergencyDisarmFraudProofVerifier();
        // Belt and braces: even a verifier that would now say "innocent" is irrelevant.
        verifier.setValid(false);

        bls.executeGuardianSlash(9, accused, hex"09");

        assertEq(staking.getLockedStake(g1, ROLE_DVT), 0, "frozen verdict still executed");
        assertEq(staking.getLockedStake(g2, ROLE_DVT), 0);
        (,,, uint8 status,, uint16 resolved,) = bls.guardianSlashCases(9);
        assertEq(status, 2, "case resolved");
        assertEq(resolved, 2);
    }

    /// CC-48 round-6 LOW-3. The case round-4's HIGH-2 was about, crossed with round-5's
    /// disarm: a case that only PARTIALLY executed (one guardian's `slashByDVT` reverted)
    /// is disarmed mid-flight, then retried. The property is that disarm is invisible to
    /// the retry — `fraudProofVerifier` has exactly one non-governance read, inside
    /// `queueGuardianSlash`, so `executeGuardianSlash` never consults it — but "provable
    /// by static reading" and "pinned by a test" are different things, and partial retry
    /// is precisely where an accidental verifier re-read would hide.
    function test_PartialExecutionSurvivesADisarmAndStillRetries() public {
        address[] memory accused = _both();
        bls.queueGuardianSlash(11, accused, hex"11");

        // g2's slash fails on the staking side: partial execution, case stays pending.
        vm.mockCallRevert(
            address(staking),
            abi.encodeWithSelector(IGTokenStakingSlash.slashByDVT.selector, g2, ROLE_DVT),
            "staking down"
        );
        bls.executeGuardianSlash(11, accused, hex"11");
        assertEq(bls.pendingGuardianSlashCount(g1), 0, "g1 settled");
        assertEq(bls.pendingGuardianSlashCount(g2), 1, "g2 still frozen mid-case");
        (,,, uint8 status,, uint16 resolved,) = bls.guardianSlashCases(11);
        assertEq(status, 1, "case still pending");
        assertEq(resolved, 1);

        // Now disarm, with the case half-finished, and make the old verifier hostile.
        bls.emergencyDisarmFraudProofVerifier();
        verifier.setValid(false);
        assertEq(bls.fraudProofVerifier(), address(0));

        // The retry completes on the FROZEN verdict. No verifier is consulted, so neither
        // the disarm nor the flipped verdict can strand g2 half-accused.
        vm.clearMockedCalls();
        bls.executeGuardianSlash(11, accused, hex"11");

        assertEq(bls.pendingGuardianSlashCount(g2), 0, "g2 settled by the retry");
        assertEq(staking.getLockedStake(g2, ROLE_DVT), 0, "g2 actually slashed");
        assertTrue(bls.guardianSlashed(11, g1));
        assertTrue(bls.guardianSlashed(11, g2));
        (,,, status,, resolved,) = bls.guardianSlashCases(11);
        assertEq(status, 2, "case resolved after the disarm");
        assertEq(resolved, 2, "g1 not double-counted on the retry");

        // And the disarm still holds: no NEW case can be opened.
        vm.expectRevert(BLSAggregator.FraudProofVerifierNotSet.selector);
        bls.queueGuardianSlash(12, accused, hex"12");
    }

    /// ...and the pre-existing case can still be dropped the normal way, on its own
    /// bounded window — disarm neither shortens nor extends it.
    function test_DisarmDoesNotChangeAQueuedCaseDeadline() public {
        address[] memory accused = _both();
        bls.queueGuardianSlash(10, accused, hex"10");
        (,, uint64 deadline,,,,) = bls.guardianSlashCases(10);
        uint256 caseDeadline = uint256(deadline);

        bls.emergencyDisarmFraudProofVerifier();
        (,, uint64 after_,,,,) = bls.guardianSlashCases(10);
        assertEq(uint256(after_), caseDeadline, "deadline untouched");

        vm.warp(caseDeadline + 1);
        bls.expireGuardianSlashCase(10, accused);
        assertEq(bls.pendingGuardianSlashCount(g1), 0);
        assertEq(bls.pendingGuardianSlashCount(g2), 0);
    }

    /// Permission: it is a governance lever, not a public panic button. A permissionless
    /// disarm would let anyone shut the collusion deterrent off for four days (the cost
    /// of re-arming) for the price of one transaction.
    function test_DisarmIsOwnerOnly() public {
        vm.prank(NOT_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NOT_OWNER));
        bls.emergencyDisarmFraudProofVerifier();
        assertEq(bls.fraudProofVerifier(), address(verifier), "still armed");
    }

    /// Refuse rather than emit a "disarmed" trail that took nothing away — monitors key
    /// off this event, and a no-op emergency stop is exactly the kind of thing that gets
    /// mistaken for one that worked.
    function test_DisarmRevertsWhenAlreadyDormant() public {
        bls.emergencyDisarmFraudProofVerifier();
        vm.expectRevert(BLSAggregator.VerifierAlreadyDisarmed.selector);
        bls.emergencyDisarmFraudProofVerifier();
    }

    /// A pending rotation with NO active verifier is still something to clear, so the
    /// "already dormant" guard must not swallow it.
    function test_DisarmWorksWithOnlyAPendingRotationToClear() public {
        bls.emergencyDisarmFraudProofVerifier();
        CC48MockFraudVerifier next = new CC48MockFraudVerifier();
        bls.proposeFraudProofVerifier(address(next));

        bls.emergencyDisarmFraudProofVerifier();
        assertEq(bls.pendingFraudProofVerifier(), address(0));
        assertEq(bls.pendingFraudProofVerifierReadyAt(), 0);
    }

    /// The audit trail: the routine events fire AND a distinct emergency marker, so a
    /// monitor can tell an emergency stop apart from a scheduled rotation landing.
    function test_DisarmEmitsTheRoutineEventsAndAnEmergencyMarker() public {
        CC48MockFraudVerifier next = new CC48MockFraudVerifier();
        bls.proposeFraudProofVerifier(address(next));

        vm.expectEmit(true, true, false, false);
        emit BLSAggregator.FraudProofVerifierUpdated(address(verifier), address(0));
        vm.expectEmit(true, false, false, false);
        emit BLSAggregator.FraudProofVerifierRotationCancelled(address(next));
        vm.expectEmit(true, true, false, false);
        emit BLSAggregator.FraudProofVerifierEmergencyDisarmed(address(verifier), address(next));
        bls.emergencyDisarmFraudProofVerifier();
    }
}

contract CC48StakingStub {
    mapping(address => uint128) public lockedAmount;
    function setLocked(address user, uint128 amount) external { lockedAmount[user] = amount; }
    function roleLocks(address user, bytes32 roleId)
        external view returns (uint128, uint128, uint48, bytes32, bytes memory)
    { return (lockedAmount[user], 0, 0, roleId, ""); }
}

contract CC48LivenessRegistryStub is IRegistry {
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
    function version() external view override returns (string memory) { return "CC48LivenessRegistryStub"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
}
