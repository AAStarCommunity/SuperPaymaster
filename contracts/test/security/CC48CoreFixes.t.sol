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
    function verify(uint256, address[] calldata, bytes calldata) external view returns (bool) { return valid; }
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
        vm.etch(address(0x0b), hex"60806000f3");
        vm.etch(address(0x0c), hex"60806000f3");
        vm.etch(address(0x0d), hex"6101006000f3");
        vm.etch(address(0x10), hex"60806000f3");
        vm.etch(address(0x11), hex"6101006000f3");
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

        (, uint64 caseDeadline,,,) = bls.guardianSlashCases(7);
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

        (,, uint8 status,, uint16 resolved) = bls.guardianSlashCases(1);
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
        (,, status,, resolved) = bls.guardianSlashCases(1);
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

        (, uint64 deadline,,,) = bls.guardianSlashCases(3);
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
        (,, uint8 status,,) = bls.guardianSlashCases(4);
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
}

/// Minimal registry/staking stubs for the exit-notice suite (no real staking).
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
