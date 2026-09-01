// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {GToken} from "src/tokens/GToken.sol";
import {GTokenStaking} from "src/core/GTokenStaking.sol";
import {MySBT} from "src/tokens/MySBT.sol";
import {Registry} from "src/core/Registry.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {IGTokenStaking} from "src/interfaces/v3/IGTokenStaking.sol";
import {BLS} from "src/utils/BLS.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @dev BLSAggregator rejects a zero DVT_VALIDATOR and makes a typed call into it
///      after execution, so the address must hold code.
contract PragueStateMachineDVTStub {
    function markProposalExecuted(uint256) external {}
}

/// @dev Stands in for the DVT repo's fraud-proof verifier. Deliberately NOT a BLS
///      contract: the aggregator's job is to pin WHICH verifier decides a case, not to
///      judge fraud itself.
contract PragueStateMachineVerifier {
    bool public valid = true;

    function setValid(bool value) external {
        valid = value;
    }

    function verify(bytes32, uint256, address[] calldata, bytes calldata) external view returns (bool) {
        return valid;
    }
}

/// @dev CC-48 round-4: the same stand-in, but behind a REAL delegatecall proxy so its
///      answer can be flipped after a case is queued without its address or extcodehash
///      moving. This is the shape the round-3 address-pinning defence could not see.
contract PragueMutableVerifierProxy {
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

contract PragueAlwaysTrueVerifierImpl {
    function verify(bytes32, uint256, address[] calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract PragueAlwaysFalseVerifierImpl {
    function verify(bytes32, uint256, address[] calldata, bytes calldata) external pure returns (bool) {
        return false;
    }
}

/**
 * @title CC48PragueStateMachine
 * @notice CC-48 round-3 MEDIUM-5: real-EIP-2537 coverage for the state machines that,
 *         until now, had only ever been exercised against injected precompiles.
 *
 * @dev Why this file exists. The exit-notice (BLOCKER-1), credit-cap (HIGH-1) and
 *      guardian-slash (HIGH-2, and round-3's verifier pinning) fixes are structural —
 *      counters, deadlines and status transitions — so a mocked pairing is logically
 *      sufficient to test them. But those suites cannot run under
 *      `--evm-version prague` at all (vm.etch refuses to overwrite real precompiles),
 *      which meant the release gate had a hole exactly where CC-48's own fixes live:
 *      every claim about them rested on a harness where a mock said "signature ok".
 *
 *      Here nothing is injected. Keys are real G1 points, proofs-of-possession and
 *      aggregate signatures are real G2 points produced with the Prague MSM
 *      precompiles, and the production BLSAggregator verifies them with a real pairing.
 *      When a test below says a proof stops verifying after an exit notice matures, the
 *      pairing genuinely fails.
 *
 *      Run:
 *        forge test --evm-version prague --match-contract CC48PragueStateMachine -vv
 *
 *      Secret scalars 1..N are test vectors ONLY — they are public knowledge and must
 *      never appear in a deployment (see the compromised experiment stack note in the
 *      CC-48 thread).
 */
contract CC48PragueStateMachine is Test {
    uint256 internal constant VALIDATOR_COUNT = 5;
    uint256 internal constant DVT_STAKE = 30 ether;
    bytes32 internal constant ROLE_DVT = keccak256("DVT");

    bytes32 internal constant DOMAIN_NAME = keccak256("SuperPaymaster.BLSConsensus.v1");
    bytes32 internal constant TAG_REPUTATION = keccak256("SuperPaymaster.BLS.Reputation.v1");

    bool internal pragueAvailable;

    GToken internal gtoken;
    GTokenStaking internal staking;
    MySBT internal sbt;
    Registry internal registry;
    BLSAggregator internal agg;
    PragueStateMachineDVTStub internal dvtSink;
    PragueStateMachineVerifier internal verifier;

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

        dvtSink = new PragueStateMachineDVTStub();
        agg = new BLSAggregator(address(registry), address(0xBEEF), address(dvtSink));
        registry.setBLSAggregator(address(agg));
        registry.setReputationSource(address(agg), true);
        registry.setCreditTier(1, 0);
        registry.setCreditPolicy(type(uint256).max, type(uint256).max);
        staking.setAuthorizedSlasher(address(agg), true);

        // ROLE_DVT with no lock duration, so `exitRole` timing is governed by the
        // aggregator's exit notice rather than by the staking lock.
        Registry.RoleConfig memory dvtConfig = registry.getRoleConfig(ROLE_DVT);
        dvtConfig.roleLockDuration = 0;
        registry.configureRole(ROLE_DVT, dvtConfig);

        agg.setMinThreshold(2);
        for (uint256 i = 0; i < VALIDATOR_COUNT; ++i) {
            address validator = address(uint160(0x2000 + i));
            uint256 scalar = i + 1;
            validators[i] = validator;
            secretScalars[i] = scalar;

            gtoken.mint(validator, 40 ether);
            vm.startPrank(validator);
            gtoken.approve(address(staking), 40 ether);
            registry.registerRole(ROLE_DVT, validator, abi.encode(DVT_STAKE));
            vm.stopPrank();

            // Real PoP, signed with the validator's own scalar under this aggregator's
            // domain — mandatory on both registration paths since CC-48 round-3.
            BLS.G1Point memory pk = _publicKey(scalar);
            agg.registerBLSPublicKey(validator, pk, uint8(i + 1), _pop(validator, pk, scalar));
        }
        agg.setDefaultThreshold(3);

        verifier = new PragueStateMachineVerifier();
        agg.proposeFraudProofVerifier(address(verifier));
        vm.warp(block.timestamp + agg.VERIFIER_ROTATION_DELAY());
        agg.applyFraudProofVerifier();
    }

    // =================================================================
    // BLOCKER-1 — exit notice, on real pairings
    // =================================================================

    /// A real 3-of-5 aggregate signature verifies before the notice matures and stops
    /// verifying after — and the "stops" is the aggregator refusing the slot, not a
    /// mock changing its mind. Pre-fix, the notice took effect in the block it was
    /// filed, which made any single ROLE_DVT member a free 1-of-N halt.
    function test_Prague_ExitNoticeDoesNotHaltAnInFlightProof() public {
        _skipWithoutPrague();
        (address[] memory users, uint256[] memory scores) = _batch(address(0xCA11), 40);

        vm.prank(validators[2]);
        agg.requestGuardianExit();

        // Same block: a genuine quorum proof still verifies and executes.
        bytes32 h1 = _reputationHash(7101, users, scores, 1);
        agg.verifyAndExecute(7101, address(0), 0, users, scores, 1, bytes32(0), _proof(h1, 3));
        assertEq(registry.globalReputation(address(0xCA11)), 40);

        // One second before maturity: still fine.
        vm.warp(block.timestamp + agg.GUARDIAN_EXIT_DELAY() - 1);
        bytes32 h2 = _reputationHash(7102, users, scores, 2);
        agg.verifyAndExecute(7102, address(0), 0, users, scores, 2, bytes32(0), _proof(h2, 3));

        // Once the announced delay has fully elapsed the slot is excluded, and the same
        // shape of proof is refused by name.
        vm.warp(block.timestamp + 1);
        bytes32 h3 = _reputationHash(7103, users, scores, 3);
        // NOTE: build the proof BEFORE arming expectRevert — `_proof` itself staticcalls
        // the curve precompiles, and an armed expectRevert would latch onto those.
        bytes memory proof3 = _proof(h3, 3);
        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.SlotValidatorExitPending.selector, uint8(3), validators[2])
        );
        agg.verifyAndExecute(7103, address(0), 0, users, scores, 3, bytes32(0), proof3);
    }

    /// Cancelling re-enters the signer set but costs a cooldown, so request/cancel
    /// flip-flopping is not a cheap repeatable lever.
    function test_Prague_CancelRestoresTheSignerAndImposesACooldown() public {
        _skipWithoutPrague();
        (address[] memory users, uint256[] memory scores) = _batch(address(0xCA12), 30);

        vm.prank(validators[2]);
        agg.requestGuardianExit();
        vm.warp(block.timestamp + agg.GUARDIAN_EXIT_DELAY() + 1);

        vm.prank(validators[2]);
        agg.cancelGuardianExit();

        // The slot signs again immediately — verified by a real pairing.
        bytes32 h = _reputationHash(7111, users, scores, 1);
        agg.verifyAndExecute(7111, address(0), 0, users, scores, 1, bytes32(0), _proof(h, 3));
        assertEq(registry.globalReputation(address(0xCA12)), 30);

        // But re-opening a notice is blocked for the cooldown.
        uint256 cooldownUntil = uint256(agg.guardianExitCooldownUntil(validators[2]));
        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.GuardianExitCooldownActive.selector, validators[2], cooldownUntil)
        );
        vm.prank(validators[2]);
        agg.requestGuardianExit();

        vm.warp(cooldownUntil);
        vm.prank(validators[2]);
        agg.requestGuardianExit();
        (uint64 readyAt,) = agg.guardianExitRequests(validators[2]);
        assertGt(uint256(readyAt), 0, "a new notice is available once the cooldown lapses");
    }

    // =================================================================
    // HIGH-1 — protocol-wide credit exposure, on real pairings
    // =================================================================

    /// The per-proposal cap is only a transaction-level guard; the real bound is the
    /// running stock of outstanding exposure. Here the quorum is genuine and the
    /// signatures are genuine — the only thing stopping the second proposal is the
    /// ceiling. Pre-fix, slicing the same issuance across proposals raised the total
    /// without limit.
    function test_Prague_TotalExposureCeilingSurvivesProposalSlicing() public {
        _skipWithoutPrague();
        registry.setCreditPolicy(type(uint256).max, type(uint256).max);

        (address[] memory u1, uint256[] memory s1) = _batch(address(0xC0F1), 50);
        bytes32 h1 = _reputationHash(7201, u1, s1, 1);
        agg.verifyAndExecute(7201, address(0), 0, u1, s1, 1, bytes32(0), _proof(h1, 3));
        uint256 perUser = registry.totalCreditExposure();
        assertGt(perUser, 0, "one user's uplift is measurable");

        // Set the protocol ceiling to EXACTLY what is already outstanding, leaving the
        // per-proposal cap generous. Any further issuance must now be refused however it
        // is sliced — that is the difference between a transaction-level guard and a
        // stock bound.
        registry.setCreditPolicy(type(uint256).max, perUser);

        vm.roll(block.number + 1);
        (address[] memory u2, uint256[] memory s2) = _batch(address(0xC0F2), 50);
        bytes32 h2 = _reputationHash(7202, u2, s2, 2);
        bytes memory proof2 = _proof(h2, 3);
        vm.expectRevert(abi.encodeWithSelector(Registry.TotalCreditExposureExceeded.selector, perUser * 2, perUser));
        agg.verifyAndExecute(7202, address(0), 0, u2, s2, 2, bytes32(0), proof2);
        assertEq(registry.totalCreditExposure(), perUser, "rejected proposal moved nothing");
    }

    // =================================================================
    // HIGH-2 / round-3 HIGH-1 — guardian slash on a real deployment
    // =================================================================

    /// The round-3 finding, replayed against real keys and a real staking contract: a
    /// verifier rotation armed BEFORE the case, matured, and fired one block AFTER the
    /// case is queued must not decide the case. The case is pinned to the verifier that
    /// authorized it.
    function test_Prague_PreArmedRotationCannotKillAQueuedCase() public {
        _skipWithoutPrague();
        PragueStateMachineVerifier evil = new PragueStateMachineVerifier();
        evil.setValid(false);

        // Arm and mature the rotation, but do NOT apply it.
        agg.proposeFraudProofVerifier(address(evil));
        vm.warp(block.timestamp + agg.VERIFIER_ROTATION_DELAY() + 1);

        address[] memory accused = new address[](1);
        accused[0] = validators[4];
        agg.queueGuardianSlash(7301, accused, hex"73");
        (,,,,,,, address pinned) = agg.guardianSlashCases(7301);
        assertEq(pinned, address(verifier));

        // Fire the pre-armed rotation, then execute.
        agg.applyFraudProofVerifier();
        assertEq(agg.fraudProofVerifier(), address(evil));

        agg.executeGuardianSlash(7301, accused, hex"73");
        assertEq(
            staking.getLockedStake(validators[4], ROLE_DVT),
            _afterOneGuardianSlash(DVT_STAKE),
            "collusion stake taken in full"
        );
        (,,, uint8 status,,,,) = agg.guardianSlashCases(7301);
        assertEq(status, 2);
    }

    /// A slashed guardian falls below minStake, so the NEXT real aggregate signature
    /// that includes its slot is rejected during pkAgg reconstruction. This is the
    /// property the paper's ρ·S_op deterrent depends on, and here it is a genuine
    /// pairing input, not a stub's answer.
    function test_Prague_SlashedGuardianIsEjectedFromTheNextRealProof() public {
        _skipWithoutPrague();
        address[] memory accused = new address[](1);
        accused[0] = validators[2];
        agg.queueGuardianSlash(7311, accused, hex"74");
        agg.executeGuardianSlash(7311, accused, hex"74");
        assertEq(staking.getLockedStake(validators[2], ROLE_DVT), _afterOneGuardianSlash(DVT_STAKE));

        (address[] memory users, uint256[] memory scores) = _batch(address(0xC0F3), 20);
        bytes32 h = _reputationHash(7312, users, scores, 1);
        bytes memory proofWithSlashed = _proof(h, 3);
        // A fully slashed lock is 0 < minStake, so pkAgg reconstruction refuses the slot.
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.SlotValidatorStakeBelowMinimum.selector,
                uint8(3),
                validators[2],
                // Not 0: a guardian slash now takes the frozen fraction, not the whole
                // lock, so the ejected validator still holds a remainder and the revert
                // payload reports it. The rejection is unchanged -- the remainder is
                // still below DVT_STAKE -- only the number it names moved.
                _afterOneGuardianSlash(DVT_STAKE),
                DVT_STAKE
            )
        );
        agg.verifyAndExecute(7312, address(0), 0, users, scores, 1, bytes32(0), proofWithSlashed);

        // The remaining honest quorum (slots 1, 2 and 4) still signs successfully.
        bytes32 h2 = _reputationHash(7313, users, scores, 2);
        agg.verifyAndExecute(7313, address(0), 0, users, scores, 2, bytes32(0), _proofFromSlots(h2));
        assertEq(registry.globalReputation(address(0xC0F3)), 20);
    }

    /// CC-48 round-4, on a real deployment: the verifier is a genuine delegatecall proxy.
    /// The case is queued while it answers true, then its implementation is swapped — same
    /// address, same extcodehash — to one that answers false. Under round-3 (re-verify
    /// against the pinned ADDRESS) this froze the case until expiry and released the
    /// colluder. With the verdict frozen the slash still lands, and the slashed guardian is
    /// genuinely ejected from the next REAL aggregate proof.
    function test_Prague_MutableProxyVerifierCannotUndoAQueuedCase() public {
        _skipWithoutPrague();
        address alwaysTrue = address(new PragueAlwaysTrueVerifierImpl());
        address alwaysFalse = address(new PragueAlwaysFalseVerifierImpl());
        PragueMutableVerifierProxy proxy = new PragueMutableVerifierProxy(alwaysTrue);

        agg.proposeFraudProofVerifier(address(proxy));
        vm.warp(block.timestamp + agg.VERIFIER_ROTATION_DELAY());
        agg.applyFraudProofVerifier();

        address[] memory accused = new address[](1);
        accused[0] = validators[2];
        agg.queueGuardianSlash(7331, accused, hex"76");
        (, bytes32 frozenProof,,,,,, address recorded) = agg.guardianSlashCases(7331);
        assertEq(frozenProof, keccak256(hex"76"), "verdict frozen at queue time");
        assertEq(recorded, address(proxy), "verifier recorded for audit only");

        bytes32 codehashBefore;
        address proxyAddr = address(proxy);
        assembly { codehashBefore := extcodehash(proxyAddr) }
        proxy.upgradeTo(alwaysFalse);
        bytes32 codehashAfter;
        assembly { codehashAfter := extcodehash(proxyAddr) }
        assertEq(codehashAfter, codehashBefore, "the upgrade is invisible to extcodehash");

        // Substituting the proof is still refused...
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.FraudProofMismatch.selector, uint256(7331), keccak256(hex"76"), keccak256(hex"77")
            )
        );
        agg.executeGuardianSlash(7331, accused, hex"77");

        // ...and the real proof still executes despite the flipped implementation.
        agg.executeGuardianSlash(7331, accused, hex"76");
        assertEq(
            staking.getLockedStake(validators[2], ROLE_DVT),
            _afterOneGuardianSlash(DVT_STAKE),
            "collusion stake taken in full"
        );
        (,,, uint8 status,,,,) = agg.guardianSlashCases(7331);
        assertEq(status, 2);

        // And the ejection is real: slot 3's lock is now below minStake, so the next
        // genuine aggregate signature that includes it is refused during reconstruction.
        (address[] memory users, uint256[] memory scores) = _batch(address(0xC0F4), 20);
        bytes32 h = _reputationHash(7332, users, scores, 1);
        bytes memory proofWithSlashed = _proof(h, 3);
        vm.expectRevert(
            abi.encodeWithSelector(
                BLSAggregator.SlotValidatorStakeBelowMinimum.selector,
                uint8(3),
                validators[2],
                // Not 0: a guardian slash now takes the frozen fraction, not the whole
                // lock, so the ejected validator still holds a remainder and the revert
                // payload reports it. The rejection is unchanged -- the remainder is
                // still below DVT_STAKE -- only the number it names moved.
                _afterOneGuardianSlash(DVT_STAKE),
                DVT_STAKE
            )
        );
        agg.verifyAndExecute(7332, address(0), 0, users, scores, 1, bytes32(0), proofWithSlashed);
    }

    /// A queued case freezes the accused guardian's ROLE_DVT exit end-to-end, through
    /// Registry.exitRole -> consumeGuardianExit, on a real staking deployment.
    function test_Prague_QueuedCaseFreezesTheRegistryExitPath() public {
        _skipWithoutPrague();
        address[] memory accused = new address[](1);
        accused[0] = validators[3];

        vm.prank(validators[3]);
        agg.requestGuardianExit();
        agg.queueGuardianSlash(7321, accused, hex"75");

        vm.warp(block.timestamp + agg.GUARDIAN_EXIT_DELAY() + 1);
        vm.prank(validators[3]);
        vm.expectRevert(
            abi.encodeWithSelector(BLSAggregator.GuardianExitBlockedBySlash.selector, validators[3], uint256(1))
        );
        registry.exitRole(ROLE_DVT);
    }

    // =================================================================
    // Helpers
    // =================================================================

    function _pop(address validator, BLS.G1Point memory pk, uint256 sk) internal view returns (BLS.G2Point memory) {
        return _multiplyG2(BLS.hashToG2(abi.encodePacked(agg.popDigest(validator, pk))), sk);
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_NAME, block.chainid, address(agg), address(registry)));
    }

    function _reputationHash(uint256 proposalId, address[] memory users, uint256[] memory scores, uint256 epoch)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(_domain(), TAG_REPUTATION, proposalId, users, scores, epoch));
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

    /// @dev Aggregate signature from the first `signerCount` slots (mask 1..signerCount).
    function _proof(bytes32 messageHash, uint256 signerCount) internal view returns (bytes memory) {
        BLS.G2Point memory aggregateSignature;
        BLS.G2Point memory messagePoint = BLS.hashToG2(abi.encodePacked(messageHash));
        for (uint256 i = 0; i < signerCount; ++i) {
            BLS.G2Point memory partialSig = _multiplyG2(messagePoint, secretScalars[i]);
            aggregateSignature = i == 0 ? partialSig : BLS.add(aggregateSignature, partialSig);
        }
        return abi.encode((uint256(1) << signerCount) - 1, abi.encode(aggregateSignature));
    }

    /// @dev Aggregate signature from slots 1, 2 and 4 — i.e. skipping the slashed
    ///      validator at slot 3 (bit index 2).
    function _proofFromSlots(bytes32 messageHash) internal view returns (bytes memory) {
        uint256[3] memory idx = [uint256(0), 1, 3];
        BLS.G2Point memory aggregateSignature;
        BLS.G2Point memory messagePoint = BLS.hashToG2(abi.encodePacked(messageHash));
        uint256 mask;
        for (uint256 i = 0; i < idx.length; ++i) {
            BLS.G2Point memory partialSig = _multiplyG2(messagePoint, secretScalars[idx[i]]);
            aggregateSignature = i == 0 ? partialSig : BLS.add(aggregateSignature, partialSig);
            mask |= (uint256(1) << idx[i]);
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

    function _hasPraguePrecompiles() internal view returns (bool) {
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = address(0x0B).staticcall(twoIdentities);
        return ok && result.length == 128;
    }

    function _skipWithoutPrague() internal {
        if (!pragueAvailable) vm.skip(true);
    }

    /// @dev What a guardian's DVT lock reads after ONE guardian slash. It used to be
    ///      zero: executeGuardianSlash took the whole lock, so a single finding put the
    ///      guardian below minStake and out of the very quorum the slash path protects.
    ///      It now takes the fraction FROZEN INTO THE CASE AT QUEUE TIME. Read through
    ///      the getter so these assertions track the configured value rather than
    ///      pinning today's default.
    ///
    ///      These three assertions live only in the Prague tree, so a `forge test` run
    ///      on the default EVM never executes them — which is how they survived the
    ///      Cancun-side fix.
    function _afterOneGuardianSlash(uint256 lock) internal view returns (uint256) {
        return lock - (lock * uint256(agg.guardianSlashBps())) / 10000;
    }
}
