// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/IVersioned.sol";
import "src/interfaces/v3/IGTokenStaking.sol";

import "src/utils/BLS.sol";
import {GenuineBLS} from "../helpers/GenuineBLS.sol";
import {MockedPrecompiles} from "../helpers/MockedPrecompiles.sol";

/// @notice Stand-in for GTokenStaking that always reports unlimited stake —
///         lets the mocked Registry advertise sufficient backing for every
///         test validator without modelling real stake accounting.
contract MockStakingPermissive {
    function roleLocks(address, bytes32 roleId)
        external
        pure
        returns (uint128 amount, uint128 ticketPrice, uint48 lockedAt, bytes32 roleId_, bytes memory metadata)
    {
        return (type(uint128).max, 0, 0, roleId, "");
    }
}

// Mocks
contract MockRegistryV3 is IRegistry {
    address public stakingAddr;

    function setStakingAddr(address s) external {
        stakingAddr = s;
    }

    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external
        override
    {}

    function hasRole(bytes32, address) external pure override returns (bool) {
        return true;
    }

    // Stubs
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}

    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        // P0-2: minStake = 0 lets test validators pass the floor without
        // having to model stake accounting in the mock; the permissive
        // staking stub still advertises max balance.
        return RoleConfig(0, 0, 0, 0, 0, 0, 0, false, 0, "stub", address(0), 0);
    }

    function getRoleUserCount(bytes32) external view override returns (uint256) {
        return 0;
    }

    function getUserRoles(address) external view override returns (bytes32[] memory) {
        return new bytes32[](0);
    }
    function registerRole(bytes32, address, bytes calldata) external override {}

    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) {
        return 0;
    }
    function setReputationSource(address, bool) external override {}
    function markProposalExecuted(uint256) external override {}
    function setCreditTier(uint256, uint256) external override {}

    function getCreditLimit(address) external view override returns (uint256) {
        return 100 ether;
    }

    function isReputationSource(address) external pure override returns (bool) {
        return true;
    }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}

    function version() external view override returns (string memory) {
        return "MockRegistryV3";
    }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}

    function getEffectiveStake(address, bytes32) external view override returns (uint256) {
        return 0;
    }

    /// @notice Mirrors Registry.GTOKEN_STAKING() so the IRegistryStakingAware
    ///         cast inside DVTValidator.addValidator can resolve.
    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return IGTokenStaking(stakingAddr);
    }
}

contract MockSuperPaymaster {
    enum SlashLevel {
        WARNING,
        MINOR,
        MAJOR
    }
    // Mock the call signatures used by the two-step BLS slash.
    bool public queued;

    function queueSlash(address) external {
        queued = true;
    }
    // executeSlashWithBLS(address,SlashLevel,bytes)
    function executeSlashWithBLS(address operator, SlashLevel level, bytes calldata proof) external {}
}

contract DVTBLSTest is Test {
    DVTValidator dvt;
    bool realPrecompiles;
    BLSAggregator bls;
    MockRegistryV3 registry;
    MockSuperPaymaster sp;

    address owner = address(1);
    address op = address(2);

    uint256 constant THRESHOLD = 7;

    function _stubKey(uint256 seed) internal view returns (BLS.G1Point memory pk) {
        if (realPrecompiles) return GenuineBLS.publicKey(seed);
        pk.x_a = bytes32(seed);
        pk.x_b = bytes32(seed + 1);
        pk.y_a = bytes32(seed + 2);
        pk.y_b = bytes32(seed + 3);
    }

    function _pop(address validator, uint256 scalar) internal view returns (BLS.G2Point memory pop) {
        if (realPrecompiles) return GenuineBLS.pop(bls, validator, scalar);
    }

    function setUp() public {
        // Mock BLS precompiles BEFORE any registerBLSPublicKey call below —
        // _validateG1Point invokes G1ADD (0x0b) and G1MUL (0x0c) at register
        // time, so the etch must already be in place.
        // 0x0b (G1ADD): returns 128 bytes (0x80) — used by _reconstructPkAgg + on-curve check.
        realPrecompiles = MockedPrecompiles.praguePrecompilesAvailable();
        if (!realPrecompiles) {
            vm.etch(address(0x0b), hex"60806000f3");
            // 0x0c (G1MUL): returns 128 bytes of zeros (identity) so the subgroup
            // check r*P == O passes for stub keys.
            vm.etch(address(0x0c), hex"60806000f3");
            // 0x10 (MapFpToG1): returns 128 bytes (0x80)
            vm.etch(address(0x10), hex"60806000f3");
            // 0x11 (MapFp2ToG2): returns 256 bytes (0x100)
            vm.etch(address(0x11), hex"6101006000f3");
            // 0x0d (G2ADD): returns 256 bytes (0x100)
            vm.etch(address(0x0d), hex"6101006000f3");
            // CC-48 round-3: PoP is now mandatory on BOTH registration paths, so the
            // pairing precompile must answer before any registerBLSPublicKey call in this
            // mocked-precompile harness. Real-pairing coverage of the same registrations
            // lives in contracts/test/paper7/ (RepCreditDomainReplay, CC48PragueE2E).
            vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        }

        vm.startPrank(owner);
        registry = new MockRegistryV3();
        // P0-2: provide a permissive staking stub so addValidator's stake gate
        // resolves; minStake on the mock RoleConfig is 0 so any reported
        // balance passes the floor.
        registry.setStakingAddr(address(new MockStakingPermissive()));
        sp = new MockSuperPaymaster();

        // Circular dependency handling
        dvt = new DVTValidator(address(registry), 1, address(0));
        bls = new BLSAggregator(address(registry), address(sp), address(dvt));

        dvt.setBLSAggregator(address(bls));

        // Add validators (10) and register their BLS keys into deterministic slots.
        for (uint256 i = 1; i <= 10; i++) {
            address v = address(uint160(i + 100)); // 101..110
            dvt.addValidator(v);
            // P0-1: register typed G1 key into slot i. The first 7 keys (slots 1..7)
            // form the default-threshold quorum used by tests below.
            dvt.registerBLSPublicKey(v, _stubKey(uint256(i)), uint8(i), _pop(v, i));
        }

        vm.stopPrank();
    }

    /// @notice Build a P0-1 compliant proof: only (signerMask, sigG2). pkAgg
    ///         is reconstructed inside the contract from on-chain keys.
    function _proofForMask(uint256 signerMask, bytes32 messageHash) internal view returns (bytes memory) {
        if (realPrecompiles) {
            uint256[] memory scalars = new uint256[](10);
            for (uint256 i; i < 10; ++i) scalars[i] = i + 1;
            return GenuineBLS.proof(messageHash, scalars, signerMask);
        }
        BLS.G2Point memory sig; // zeroed — pairing precompile is mocked
        return abi.encode(signerMask, abi.encode(sig));
    }

    function _queueProof(uint256 epoch) internal view returns (bytes memory) {
        return _proofForMask(0x7F, keccak256(abi.encode(bls.domainSeparator(), bls.TAG_QUEUE_SLASH(), op, uint8(1), epoch)));
    }

    function _expectedCommitment(uint256 key, bytes32 messageHash, uint256 signerMask) internal view returns (bytes32) {
        address[] memory signers = new address[](7);
        for (uint256 i; i < signers.length; ++i) {
            signers[i] = address(uint160(101 + i));
        }
        return keccak256(
            abi.encode(
                bls.domainSeparator(),
                bls.TAG_SIGNERS_COMMITMENT(),
                key,
                messageHash,
                signerMask,
                signers,
                blockhash(block.number - 1)
            )
        );
    }

    function test_QueueSlashGeneric_OverlappingInputsKeepAllCommitments() public {
        vm.roll(100);
        vm.setBlockhash(99, bytes32(uint256(0xA11CE)));
        vm.prank(address(101));
        uint256 id = dvt.createProposal(op, 1, "Bad Operator");
        assertEq(id, 1);

        uint256 signerMask = 0x7F;
        uint256 epoch = id;
        bytes32 queueMessage = keccak256(abi.encode(bls.domainSeparator(), bls.TAG_QUEUE_SLASH(), op, uint8(1), epoch));
        uint256 queueKey = uint256(queueMessage);
        bytes memory queueProof = _queueProof(epoch);
        bytes32 queueCommitment = _expectedCommitment(queueKey, queueMessage, signerMask);
        vm.expectEmit(true, false, false, true, address(bls));
        emit BLSAggregator.SignersCommitted(queueKey, signerMask);
        vm.prank(address(101));
        dvt.queueSlashWithProof(op, 1, epoch, queueProof);
        assertEq(bls.proposalSignersCommitment(queueKey), queueCommitment);

        vm.roll(101);
        vm.setBlockhash(100, bytes32(uint256(0xB0B)));
        bytes memory callData = abi.encodeWithSignature("queued()");
        bytes32 genericMessage = keccak256(
            abi.encode(bls.domainSeparator(), bls.TAG_PROPOSAL(), id, address(sp), keccak256(callData), uint256(3))
        );
        uint256 genericKey = uint256(keccak256(abi.encode(bls.TAG_PROPOSAL(), id)));
        bytes memory genericProof = _proofForMask(signerMask, genericMessage);
        bytes32 genericCommitment = _expectedCommitment(genericKey, genericMessage, signerMask);
        vm.prank(owner);
        bls.executeProposal(id, address(sp), callData, 3, genericProof);
        assertEq(bls.proposalSignersCommitment(queueKey), queueCommitment, "generic preserves queue commitment");
        assertEq(bls.proposalSignersCommitment(genericKey), genericCommitment);

        vm.roll(102);
        vm.setBlockhash(101, bytes32(uint256(0xCAFE)));
        // Slash/reputation use bounded raw ids; generic execution uses TAG_PROPOSAL's hashed key.
        uint256 slashKey = id;
        bytes32 slashMessage =
            keccak256(abi.encode(bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), id, op, uint8(1), epoch, bytes32(0)));
        bytes memory slashProof = _proofForMask(signerMask, slashMessage);
        vm.expectEmit(true, false, false, true, address(bls));
        emit BLSAggregator.SignersCommitted(slashKey, signerMask);
        vm.prank(address(101));
        dvt.executeWithProof(id, new address[](0), new uint256[](0), epoch, slashProof);

        (,,, bool executed,,) = dvt.proposals(id);
        assertTrue(executed, "Proposal should be executed");
        assertEq(bls.proposalSignersCommitment(queueKey), queueCommitment, "slash preserves queue commitment");
        assertEq(bls.proposalSignersCommitment(genericKey), genericCommitment, "slash preserves generic commitment");
        assertEq(bls.proposalSignersCommitment(slashKey), _expectedCommitment(slashKey, slashMessage, signerMask));
        assertTrue(bls.executedProposals(slashKey));
        assertTrue(bls.executedProposals(genericKey));
    }

    function test_SlashRawIdEqualToGenericKeyCannotOverwriteGenericCommitment() public {
        uint256 signerMask = 0x7F;
        uint256 genericId = 8123;
        uint256 genericKey = uint256(keccak256(abi.encode(bls.TAG_PROPOSAL(), genericId)));
        bytes memory callData = abi.encodeWithSignature("queued()");
        bytes32 genericMessage = keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_PROPOSAL(), genericId, address(sp), keccak256(callData), uint256(3)
        ));
        bytes memory genericProof = _proofForMask(signerMask, genericMessage);
        vm.prank(owner);
        bls.executeProposal(genericId, address(sp), callData, 3, genericProof);
        bytes32 genericCommitment = bls.proposalSignersCommitment(genericKey);
        assertEq(genericCommitment, _expectedCommitment(genericKey, genericMessage, signerMask));

        bytes32 slashMessage = keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), genericKey, op, uint8(1), uint256(9), bytes32(uint256(0xE1D3))
        ));
        bytes memory slashProof = _proofForMask(signerMask, slashMessage);
        vm.mockCall(
            address(dvt), abi.encodeWithSelector(DVTValidator.markProposalExecuted.selector, genericKey), bytes("")
        );
        vm.expectRevert(BLSAggregator.InvalidProposalId.selector);
        vm.prank(owner);
        bls.verifyAndExecute(genericKey, op, 1, new address[](0), new uint256[](0), 9, bytes32(uint256(0xE1D3)), slashProof);

        assertEq(bls.proposalSignersCommitment(genericKey), genericCommitment, "generic commitment preserved");
    }

    /// @dev The reputation branch shares the raw-id namespace; it must be bounded too, or a
    ///      reputation id equal to a generic typed key pre-consumes and overwrites that slot.
    function test_ReputationRawIdEqualToGenericKeyCannotPreconsumeGenericSlot() public {
        uint256 signerMask = 0x7F;
        uint256 genericId = 8124;
        uint256 genericKey = uint256(keccak256(abi.encode(bls.TAG_PROPOSAL(), genericId)));
        address[] memory users = new address[](1);
        users[0] = address(0xBEEF);
        uint256[] memory scores = new uint256[](1);
        scores[0] = 10;
        bytes memory reputationProof = _proofForMask(signerMask, bls.reputationMessageHash(genericKey, users, scores, 9));

        // Attack order: a reputation proposal FIRST, with its raw id set to the generic typed key.
        vm.expectRevert(BLSAggregator.InvalidProposalId.selector);
        vm.prank(owner);
        bls.verifyAndExecute(genericKey, address(0), 0, users, scores, 9, bytes32(0), reputationProof);
        assertFalse(bls.executedProposals(genericKey), "generic replay slot not pre-consumed");
        assertEq(bls.proposalSignersCommitment(genericKey), bytes32(0), "no commitment written at the generic key");

        bytes memory callData = abi.encodeWithSignature("queued()");
        bytes32 genericMessage = keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_PROPOSAL(), genericId, address(sp), keccak256(callData), uint256(3)
        ));
        bytes memory genericProof = _proofForMask(signerMask, genericMessage);
        vm.prank(owner);
        bls.executeProposal(genericId, address(sp), callData, 3, genericProof);
        assertTrue(bls.executedProposals(genericKey));

        // Boundary: 2^128-1 passes the bound (it may fail later, never with InvalidProposalId).
        bytes memory boundaryProof = _proofForMask(signerMask, bls.reputationMessageHash(type(uint128).max, users, scores, 9));
        vm.prank(owner);
        try bls.verifyAndExecute(type(uint128).max, address(0), 0, users, scores, 9, bytes32(0), boundaryProof) {}
        catch (bytes memory err) {
            assertTrue(bytes4(err) != BLSAggregator.InvalidProposalId.selector, "2^128-1 must pass the bound");
        }
    }

    function test_QueueSlashWithConsensus_FlagsAndBlocksReplay() public {
        if (!realPrecompiles) vm.mockCall(address(0x0F), "", abi.encode(uint256(1))); // pairing success
        bytes memory proof = _queueProof(42); // 7 signers >= MINOR threshold (3)

        // First queue succeeds and pre-flags the operator on SP.
        vm.prank(address(dvt));
        bls.queueSlashWithConsensus(op, 1, 42, proof); // MINOR, epoch 42
        assertTrue(sp.queued(), "operator pre-flagged via SP.queueSlash");

        // Replaying the SAME proof (same operator/level/epoch) reverts — a consumed
        // queue proof cannot re-flag after a cancel/execute cleared the flag.
        bytes32 h = keccak256(abi.encode(bls.domainSeparator(), bls.TAG_QUEUE_SLASH(), op, uint8(1), uint256(42)));
        vm.prank(address(dvt));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlashQueueProofAlreadyUsed.selector, h));
        bls.queueSlashWithConsensus(op, 1, 42, proof);

        // A fresh, legitimate re-queue (new epoch → new hash) is allowed.
        bytes memory freshProof = _queueProof(43);
        vm.prank(address(dvt));
        bls.queueSlashWithConsensus(op, 1, 43, freshProof);
        assertTrue(bls.usedSlashQueueHashes(keccak256(abi.encode(bls.domainSeparator(), bls.TAG_QUEUE_SLASH(), op, uint8(1), uint256(43)))));
    }

    function test_QueueSlashWithProof_ForwarderFlags() public {
        uint256 signerMask = 0x7F;
        bytes memory proof = _queueProof(7);
        bytes32 messageHash =
            keccak256(abi.encode(bls.domainSeparator(), bls.TAG_QUEUE_SLASH(), op, uint8(1), uint256(7)));
        uint256 key = uint256(messageHash);
        bytes32 expected = _expectedCommitment(key, messageHash, signerMask);
        vm.expectEmit(true, false, false, true, address(bls));
        emit BLSAggregator.SignersCommitted(key, signerMask);
        vm.prank(address(101)); // active validator drives the forwarder
        dvt.queueSlashWithProof(op, 1, 7, proof);
        assertTrue(sp.queued(), "operator pre-flagged via DVTValidator forwarder");
        assertEq(bls.proposalSignersCommitment(key), expected, "queue commitment exact tuple");
    }

    function test_BLS_ManualVerify() public {
        // P0-17: BLSAggregator now calls back into DVTValidator.markProposalExecuted
        // which requires the proposal to exist. Create it first via the legitimate
        // validator path so the callback can find a real proposal record.
        vm.prank(address(101)); // Validator 1
        uint256 id = dvt.createProposal(op, 1, "Bad Operator");

        // Mock BLS pairing as success — the test focuses on the access control
        // and proposal lifecycle, not on real pairing arithmetic.
        if (!realPrecompiles) vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        bytes memory mockProof = _proofForMask(0x7F, keccak256(abi.encode(bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), id, op, uint8(1), uint256(123), bytes32(0))));

        vm.prank(address(dvt));

        bls.verifyAndExecute(id, op, 1, new address[](0), new uint256[](0), 123, bytes32(0), mockProof);

        assertTrue(bls.executedProposals(id));
    }

    function test_DVTRotation_ContinuesAfterExecutedProposalRange() public {
        uint256 lastExecutedId = 2;

        for (uint256 expectedId = 1; expectedId <= lastExecutedId; ++expectedId) {
            vm.prank(address(101));
            uint256 id = dvt.createProposal(op, 1, "pre-rotation");
            assertEq(id, expectedId);
            bytes memory proof = _proofForMask(0x7F, keccak256(abi.encode(
                bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), id, op, uint8(1), id, bytes32(0)
            )));
            vm.prank(address(101));
            dvt.executeWithProof(id, new address[](0), new uint256[](0), id, proof);
            assertTrue(bls.executedProposals(id));
        }

        vm.startPrank(owner);
        DVTValidator replacement = new DVTValidator(address(registry), lastExecutedId + 1, address(dvt));
        replacement.setBLSAggregator(address(bls));
        replacement.addValidator(address(101));
        bls.setDVTValidator(address(replacement));
        vm.stopPrank();

        vm.prank(address(101));
        uint256 replacementId = replacement.createProposal(op, 1, "post-rotation");
        assertEq(replacementId, lastExecutedId + 1);
        bytes memory replacementProof = _proofForMask(0x7F, keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), replacementId, op, uint8(1), replacementId, bytes32(0)
        )));
        vm.prank(address(101));
        replacement.executeWithProof(
            replacementId, new address[](0), new uint256[](0), replacementId, replacementProof
        );

        assertTrue(bls.executedProposals(replacementId));
        (,,, bool executed,,) = replacement.proposals(replacementId);
        assertTrue(executed);
    }

    function _replacement(address predecessor, uint256 firstId) internal returns (DVTValidator replacement) {
        vm.startPrank(owner);
        replacement = new DVTValidator(address(registry), firstId, predecessor);
        replacement.setBLSAggregator(address(bls));
        replacement.addValidator(address(101));
        vm.stopPrank();
    }

    function test_M1_NotYetCurrentCannotAllocateEitherOverload() public {
        DVTValidator replacement = _replacement(address(dvt), 1);
        vm.startPrank(address(101));
        vm.expectRevert(DVTValidator.NotCurrentDVT.selector);
        replacement.createProposal(op, 1, "not current");
        vm.expectRevert(DVTValidator.NotCurrentDVT.selector);
        replacement.createProposal(op, 1, "not current", keccak256("evidence"));
        vm.stopPrank();
        assertEq(replacement.nextProposalId(), 1, "failed creates do not allocate IDs");
    }

    function test_M1_RotatedAwayCannotAllocateEitherOverload() public {
        DVTValidator replacement = _replacement(address(dvt), 1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        vm.startPrank(address(101));
        vm.expectRevert(DVTValidator.NotCurrentDVT.selector);
        dvt.createProposal(op, 1, "rotated away");
        vm.expectRevert(DVTValidator.NotCurrentDVT.selector);
        dvt.createProposal(op, 1, "rotated away", keccak256("evidence"));
        vm.stopPrank();
        assertEq(dvt.nextProposalId(), 1);
    }

    function test_M1_LiveFloorIncludesAllocationsAfterReplacementDeployment() public {
        DVTValidator replacement = _replacement(address(dvt), 1);
        for (uint256 i = 1; i <= 5; ++i) {
            vm.prank(address(101));
            assertEq(dvt.createProposal(op, 1, "before rotation"), i);
        }
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        vm.prank(address(101));
        assertEq(replacement.createProposal(op, 1, "fresh"), 6, "live floor prevents pending ID reuse");
        vm.prank(address(101));
        assertEq(replacement.createProposal(op, 1, "fresh", keccak256("evidence")), 7);
        assertEq(dvt.nextProposalId(), 6, "previous counter stays final");
        assertEq(replacement.nextProposalId(), 8);
    }

    function test_M1_EmptyIntermediateRotationPreservesLiveFloor() public {
        DVTValidator intermediate = _replacement(address(dvt), 1);
        DVTValidator replacement = _replacement(address(intermediate), 1);
        vm.prank(address(101));
        dvt.createProposal(op, 1, "allocated after both deployments");
        vm.startPrank(owner);
        bls.setDVTValidator(address(intermediate));
        bls.setDVTValidator(address(replacement));
        vm.stopPrank();
        vm.prank(address(101));
        assertEq(replacement.createProposal(op, 1, "fresh"), 2);
    }

    function test_M1_ZeroPredecessorAndExplicitFirstIdWork() public {
        assertEq(dvt.previousDVT(), address(0));
        vm.prank(address(101));
        assertEq(dvt.createProposal(op, 1, "first deployment"), 1);
        DVTValidator replacement = _replacement(address(dvt), 100);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        vm.prank(address(101));
        assertEq(replacement.createProposal(op, 1, "explicit higher floor"), 100);
        assertEq(replacement.version(), "DVTValidator-0.8.0");
    }

    function test_M1_PreviousCounterExhaustionReverts() public {
        DVTValidator previous = _replacement(address(dvt), type(uint128).max);
        vm.prank(owner);
        bls.setDVTValidator(address(previous));
        vm.prank(address(101));
        assertEq(previous.createProposal(op, 1, "last ID"), type(uint128).max);
        DVTValidator replacement = _replacement(address(previous), 1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        vm.prank(address(101));
        vm.expectRevert(DVTValidator.ProposalIdSpaceExhausted.selector);
        replacement.createProposal(op, 1, "exhausted");
    }

    function test_M1_RotationCannotReplayAbandonedProposal() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        for (uint256 i = 1; i <= 42; ++i) {
            vm.prank(address(101));
            assertEq(dvt.createProposal(op, 1, "rotation"), i);
        }
        bytes memory executedProof = _proofForMask(0x7F, keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), uint256(41), op, uint8(1), uint256(9), bytes32(0)
        )));
        vm.prank(address(101));
        dvt.executeWithProof(41, new address[](0), new uint256[](0), 9, executedProof);
        assertTrue(bls.executedProposals(41));
        bytes memory abandonedProof = _proofForMask(0x7F, keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), uint256(42), op, uint8(1), uint256(9), bytes32(0)
        )));
        bytes memory queueProof = _queueProof(9);
        vm.prank(address(101));
        dvt.queueSlashWithProof(op, 1, 9, queueProof);
        assertTrue(sp.queued());

        (bool replayed, bytes memory replayError) = address(this).call(abi.encodeCall(this.replayAbandonedProposal, (abandonedProof)));
        assertFalse(replayed, "M1: abandoned signature executed after DVT rotation");
        assertEq(replayError, abi.encodeWithSelector(BLSAggregator.SignatureVerificationFailed.selector), "M1: replay reaches pairing and fails for the fresh ID");
        assertFalse(bls.executedProposals(42));
    }

    function replayAbandonedProposal(bytes calldata proof) external {
        require(msg.sender == address(this));
        vm.startPrank(owner);
        DVTValidator replacement = new DVTValidator(address(registry), 42, address(dvt));
        replacement.setBLSAggregator(address(bls));
        replacement.addValidator(address(101));
        bls.setDVTValidator(address(replacement));
        vm.stopPrank();
        vm.startPrank(address(101));
        uint256 freshId = replacement.createProposal(op, 1, "rotation");
        assertEq(freshId, 43, "pending predecessor IDs must be abandoned");
        replacement.executeWithProof(freshId, new address[](0), new uint256[](0), 9, proof);
        vm.stopPrank();
    }

    function test_M3_RemovedValidatorCannotSelfRestoreVotingPower() public {
        vm.startPrank(owner);
        bls.setPermissionlessBLSRegistration(true);
        dvt.removeValidator(address(101));
        vm.stopPrank();
        assertFalse(dvt.isValidator(address(101)));
        assertTrue(registry.hasRole(keccak256("DVT"), address(101)));
        bytes32 digest = keccak256("owner removal must persist");
        bytes memory proof = _proofForMask(0x7F, digest);
        (, bytes memory signature) = abi.decode(proof, (uint256, bytes));
        BLS.G1Point memory key = _stubKey(1);
        BLS.G2Point memory pop = _pop(address(101), 1);
        vm.prank(address(101));
        (bool registered,) = address(bls).call(abi.encodeCall(bls.registerBLSPublicKey, (address(101), key, 1, pop)));
        (bool verified, bytes memory result) = address(bls).staticcall(abi.encodeCall(bls.verify, (digest, 0x7F, 7, signature)));
        assertFalse(verified && abi.decode(result, (bool)), "M3: owner-removed key regained voting power");
        assertFalse(registered, "M3: suspended validator registered directly through aggregator");
        assertTrue(dvt.isSuspended(address(101)), "owner suspension persists");
        vm.prank(address(101));
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.ValidatorSuspended.selector, address(101)));
        dvt.registerBLSPublicKey(address(101), key, 1, pop);
        vm.prank(address(101));
        vm.expectRevert();
        dvt.addValidator(address(101));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.ValidatorSuspended.selector, address(101)));
        dvt.registerBLSPublicKey(address(101), key, 1, pop);
        vm.prank(owner);
        dvt.addValidator(address(101));
        assertFalse(dvt.isSuspended(address(101)), "only owner reinstates");
        vm.prank(address(101));
        dvt.registerBLSPublicKey(address(101), key, 1, pop);
        assertTrue(bls.verify(digest, 0x7F, 7, signature), "owner reinstatement restores voting");

    }

    function test_M2_RemovalPreservesReachableSlashQuorum() public {
        vm.startPrank(owner);
        for (uint256 i = 104; i <= 110; ++i) bls.revokeBLSPublicKey(address(uint160(i)));
        assertEq(bls.defaultThreshold(), 7);
        assertEq(bls.slashThresholds(1), 3);
        (bool removed,) = address(dvt).call(abi.encodeCall(dvt.removeValidator, (address(101))));
        vm.stopPrank();
        assertFalse(removed, "M2: removal destroyed a reachable slash quorum");
        assertTrue(dvt.isValidator(address(101)));
        assertFalse(dvt.isSuspended(address(101)), "failed removal must not suspend");
        (,, bool active) = bls.getBLSPublicKey(address(101));
        assertTrue(active);
    }

    function test_Fail_NotValidator() public {
        // P0 follow-up: createProposal now goes through _requireActiveValidator
        // which reverts NotActiveValidator(v) for unregistered callers — the
        // old NotValidator() error is no longer reached on this path.
        vm.prank(address(0x999));
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.NotActiveValidator.selector, address(0x999)));
        dvt.createProposal(op, 1, "fail");
    }
}
