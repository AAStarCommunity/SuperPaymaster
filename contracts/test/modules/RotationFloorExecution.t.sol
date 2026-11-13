// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "./DVT_BLS.t.sol";

/// @notice Execution-time rotation floors, with genuine signatures on Prague.
contract RotationFloorExecution is DVTBLSTest {
    function _slashProof(uint256 id, uint256 epoch) internal view returns (bytes memory) {
        return _proofForMask(0x7F, keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), id, op, uint8(1), epoch, bytes32(0)
        )));
    }

    function test_RotatedBackDVTCannotExecutePreRotationSlash() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        vm.prank(address(101));
        uint256 oldId = dvt.createProposal(op, 1, "abandoned on rotation");
        bytes memory oldProof = _slashProof(oldId, 9);
        DVTValidator replacement = _replacement(1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        vm.prank(address(101));
        replacement.createProposal(op, 1, "replacement intent");
        vm.prank(owner);
        bls.setDVTValidator(address(dvt));
        assertLt(oldId, bls.proposalFloor());
        bytes memory queueProof = _queueProof(9);
        vm.prank(address(101));
        dvt.queueSlashWithProof(op, 1, 9, queueProof);
        assertTrue(sp.queued());
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidProposalId.selector));
        vm.prank(address(101));
        dvt.executeWithProof(oldId, new address[](0), new uint256[](0), 9, oldProof);
        assertFalse(bls.executedProposals(oldId), "rotation permanently invalidates the old slash");
        (,,, bool executed,,) = dvt.proposals(oldId);
        assertFalse(executed, "failed execution cannot mark the DVT proposal");
        assertEq(bls.proposalSignersCommitment(oldId), bytes32(0));
    }

    function test_SlashAllocatedAfterReactivationStillExecutes() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        vm.prank(address(101));
        uint256 oldId = dvt.createProposal(op, 1, "before A to B");
        DVTValidator replacement = _replacement(1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        vm.prank(address(101));
        uint256 successorId = replacement.createProposal(op, 1, "before B to A");
        vm.prank(owner);
        bls.setDVTValidator(address(dvt));
        assertEq(bls.proposalFloor(), successorId + 1);
        vm.prank(address(101));
        uint256 freshId = dvt.createProposal(op, 1, "after reactivation");
        assertEq(freshId, bls.proposalFloor(), "the fresh floor itself is executable");
        bytes memory proof = _slashProof(freshId, 9);
        bytes memory queueProof = _queueProof(9);
        vm.prank(address(101));
        dvt.queueSlashWithProof(op, 1, 9, queueProof);
        vm.expectCall(address(sp), abi.encodeWithSignature(
            "executeSlashWithBLS(address,uint8,bytes)", op, uint8(1), proof
        ), uint64(1));
        vm.prank(address(101));
        dvt.executeWithProof(freshId, new address[](0), new uint256[](0), 9, proof);
        assertTrue(bls.executedProposals(freshId));
        (,,, bool executed,,) = dvt.proposals(freshId);
        assertTrue(executed);
        assertFalse(bls.executedProposals(oldId));
        assertFalse(bls.executedProposals(successorId));
    }

    function test_CurrentDvtIdGoesStaleAfterLaterRotation() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        DVTValidator replacement = _replacement(1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        vm.prank(address(101));
        uint256 id = replacement.createProposal(op, 1, "proof ready while current");
        assertGe(id, bls.proposalFloor());
        bytes32 digest = keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), id, op, uint8(1), uint256(9), bytes32(0)
        ));
        bytes memory proof = _proofForMask(0x7F, digest);
        (, bytes memory signature) = abi.decode(proof, (uint256, bytes));
        assertTrue(bls.verify(digest, 0x7F, 7, signature), "proof is valid before the later rotation");
        vm.prank(owner);
        bls.setDVTValidator(address(dvt));
        assertEq(bls.proposalFloor(), id + 1);
        // The current DVT cannot forward a proof made stale by rotation.
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidProposalId.selector));
        vm.prank(address(dvt));
        bls.verifyAndExecute(id, op, 1, new address[](0), new uint256[](0), 9, bytes32(0), proof);
        assertFalse(bls.executedProposals(id));
        (,,, bool executed,,) = replacement.proposals(id);
        assertFalse(executed);
        assertEq(bls.proposalSignersCommitment(id), bytes32(0));
    }

    function test_StaleQueueProofCannotMoveFunds() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        vm.prank(address(101));
        uint256 oldId = dvt.createProposal(op, 1, "pre-rotation slash");
        bytes memory oldProof = _slashProof(oldId, 9);
        bytes memory oldQueueProof = _queueProof(9);
        DVTValidator replacement = _replacement(1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        assertLt(oldId, bls.proposalFloor());
        assertFalse(sp.queued());
        vm.prank(address(101));
        replacement.queueSlashWithProof(op, 1, 9, oldQueueProof);
        assertTrue(sp.queued(), "the unused queue proof survives rotation");

        vm.expectCall(address(sp), abi.encodeWithSignature(
            "executeSlashWithBLS(address,uint8,bytes)", op, uint8(1), oldProof
        ), uint64(0));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidProposalId.selector));
        vm.prank(address(replacement));
        bls.verifyAndExecute(oldId, op, 1, new address[](0), new uint256[](0), 9, bytes32(0), oldProof);
        assertFalse(bls.executedProposals(oldId));
        assertTrue(sp.queued(), "rejected slash leaves only the reversible pre-flag");
        assertEq(bls.proposalSignersCommitment(oldId), bytes32(0));

        vm.prank(address(101));
        uint256 freshId = replacement.createProposal(op, 1, "fresh slash");
        assertEq(freshId, bls.proposalFloor());
        // Merely relabelling the old signature with a fresh id is insufficient.
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SignatureVerificationFailed.selector));
        vm.prank(address(101));
        replacement.executeWithProof(freshId, new address[](0), new uint256[](0), 9, oldProof);
        assertFalse(bls.executedProposals(freshId));
        bytes memory freshProof = _slashProof(freshId, 9);
        vm.expectCall(address(sp), abi.encodeWithSignature(
            "executeSlashWithBLS(address,uint8,bytes)", op, uint8(1), freshProof
        ), uint64(1));
        vm.prank(address(101));
        replacement.executeWithProof(freshId, new address[](0), new uint256[](0), 9, freshProof);
        assertTrue(bls.executedProposals(freshId));
        (,,, bool executed,,) = replacement.proposals(freshId);
        assertTrue(executed);
        assertFalse(bls.executedProposals(oldId));
    }

    function test_ExactExhaustionFloorPersists() public {
        DVTValidator replacement = _replacement(1);
        vm.prank(owner);
        bls.setDVTValidatorWithFloor(address(replacement), uint256(1) << 128);
        assertEq(replacement.nextProposalId(), uint256(1) << 128);
        vm.prank(address(101));
        vm.expectRevert(abi.encodeWithSelector(DVTValidator.ProposalIdSpaceExhausted.selector));
        replacement.createProposal(op, 1, "exhausted");
        vm.startPrank(owner);
        bls.setDVTValidator(address(dvt));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidProposalFloor.selector));
        bls.setDVTValidatorWithFloor(address(replacement), type(uint128).max);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidProposalFloor.selector));
        bls.setDVTValidatorWithFloor(address(replacement), (uint256(1) << 128) + 1);
        vm.stopPrank();
        assertEq(bls.proposalFloor(), uint256(1) << 128);
    }

    function test_SuspendedKeyCannotBeStolenOrReleasedWhileActive() public {
        BLS.G1Point memory key = _stubKey(1);
        bytes32 keyHash = keccak256(abi.encode(key));
        vm.startPrank(owner);
        bls.setSuspended(address(101), true);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.KeyBindingStillActive.selector, keyHash, address(101)));
        bls.releaseKeyBinding(keyHash);
        bls.revokeAndSuspend(address(101));
        BLS.G2Point memory otherPop = _pop(address(501), 1);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.DuplicatePublicKey.selector, keyHash, address(101)));
        dvt.registerBLSPublicKey(address(501), key, 1, otherPop);
        vm.stopPrank();
        assertTrue(bls.suspended(address(101)));
        assertEq(bls.blsKeyOwner(keyHash), address(101));
    }

    /// @notice Accepted, disclosed residual: an unused pre-rotation queue proof can
    ///         set a reversible pre-flag that the owner can cancel and that moves no funds.
    function test_PreRotationQueuePreFlagIsDocumentedResidual() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        bytes memory oldQueueProof = _queueProof(9);
        bytes32 queueHash = keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_QUEUE_SLASH(), op, uint8(1), uint256(9)
        ));
        DVTValidator replacement = _replacement(1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        assertFalse(sp.queued());
        assertFalse(bls.usedSlashQueueHashes(queueHash));
        vm.expectCall(address(sp), abi.encodeWithSignature("executeSlashWithBLS(address,uint8,bytes)"), uint64(0));
        vm.prank(address(101));
        replacement.queueSlashWithProof(op, 1, 9, oldQueueProof);
        assertTrue(sp.queued(), "old queue approval executes after forward rotation");
        assertTrue(bls.usedSlashQueueHashes(queueHash));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlashQueueProofAlreadyUsed.selector, queueHash));
        vm.prank(address(101));
        replacement.queueSlashWithProof(op, 1, 9, oldQueueProof);
    }
}
