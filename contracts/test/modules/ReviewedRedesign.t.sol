// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "./DVT_BLS.t.sol";

/// @notice Fixed assertions for the adverse rotation, suspension and exit review probes.
contract ReviewedRedesign is DVTBLSTest {
    function _noticeThenPermissionlessRegistration() internal returns (uint64 readyAt) {
        vm.startPrank(owner);
        for (uint256 i = 107; i <= 110; ++i) bls.revokeBLSPublicKey(address(uint160(i)));
        bls.setPermissionlessBLSRegistration(true);
        vm.stopPrank();
        assertEq(bls.minThreshold(), 3);
        assertEq(bls.defaultThreshold(), 7);
        assertEq(bls.slashThresholds(0), 2);
        assertEq(bls.slashThresholds(1), 3);
        assertEq(bls.slashThresholds(2), 3);

        vm.prank(address(101));
        bls.requestGuardianExit(); // Six live signers, five projected; no threshold crossed.
        (readyAt,) = bls.guardianExitRequests(address(101));
        BLS.G1Point memory key = _stubKey(11);
        BLS.G2Point memory pop = _pop(address(111), 11);
        vm.prank(address(111));
        dvt.registerBLSPublicKey(address(111), key, 7, pop);
        assertEq(bls.validatorAtSlot(7), address(111));
        assertFalse(dvt.isValidator(address(111)), "new signer uses permissionless admission");
    }

    function _registeredCommitteeSignature(uint256 mask, bytes32 digest) internal view returns (bytes memory sig) {
        uint256[] memory scalars = new uint256[](7);
        for (uint256 i; i < 6; ++i) scalars[i] = i + 1;
        scalars[6] = 11;
        (, sig) = abi.decode(GenuineBLS.proof(digest, scalars, mask), (uint256, bytes));
    }

    function test_Prague_NoticeThenRegistrationRemovalPreservesLiveDefaultQuorum() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        _noticeThenPermissionlessRegistration();
        bytes32 digest = keccak256("seven live, six projected");
        bytes memory sig = _registeredCommitteeSignature(0x7F, digest);
        assertTrue(bls.verify(digest, 0x7F, 7, sig));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitWouldBreakQuorum.selector, uint256(6), uint256(7)));
        dvt.removeValidator(address(102));
        assertTrue(dvt.isValidator(address(102)));
        assertFalse(bls.suspended(address(102)));
        assertTrue(bls.verify(digest, 0x7F, 7, sig), "ordinary removal preserves all seven live signers");

        vm.prank(owner);
        bls.revokeAndSuspend(address(102));
        assertTrue(bls.suspended(address(102)), "emergency override remains available");
        (,, bool active) = bls.getBLSPublicKey(address(102));
        assertFalse(active);
    }

    function test_Prague_NoticeThenRegistrationExitPreservesLiveDefaultQuorum() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        _noticeThenPermissionlessRegistration();
        vm.prank(address(102));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitWouldBreakQuorum.selector, uint256(6), uint256(7)));
        bls.requestGuardianExit();
        (uint64 readyAt,) = bls.guardianExitRequests(address(102));
        assertEq(readyAt, 0, "refused exit leaves no notice");
    }

    function test_Prague_NoticeMaturityRemainsAcceptedAfterRegistration() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        uint64 readyAt = _noticeThenPermissionlessRegistration();
        bytes32 digest = keccak256("accepted maturity after registration");
        bytes memory sig = _registeredCommitteeSignature(0x7F, digest);
        vm.warp(uint256(readyAt) - 1);
        assertTrue(bls.verify(digest, 0x7F, 7, sig));
        vm.warp(readyAt);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotValidatorExitPending.selector, uint8(1), address(101)));
        bls.verify(digest, 0x7F, 7, sig);
        bytes memory remainingSig = _registeredCommitteeSignature(0x7E, digest);
        assertTrue(bls.verify(digest, 0x7E, 6, remainingSig), "six signers remain after the accepted maturity");
        vm.prank(owner);
        dvt.removeValidator(address(101));
        assertTrue(bls.verify(digest, 0x7E, 6, remainingSig), "removing a matured exit loses no live signer");
    }

    function test_Review_NoPredecessorInputCanReusePendingSignature() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        vm.prank(address(101));
        uint256 oldId = dvt.createProposal(op, 1, "pending");
        bytes memory proof = _proofForMask(0x7F, keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), oldId, op, uint8(1), uint256(9), bytes32(0)
        )));
        DVTValidator replacement = _replacement(1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        assertEq(bls.proposalFloor(), oldId + 1, "activation includes pending IDs");
        vm.startPrank(address(101));
        uint256 freshId = replacement.createProposal(op, 1, "new intent");
        assertGt(freshId, oldId, "no caller-supplied predecessor can reset the floor");
        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        replacement.executeWithProof(freshId, new address[](0), new uint256[](0), 9, proof);
        vm.stopPrank();
        assertFalse(bls.executedProposals(freshId));
    }

    function test_Review_RollbackCannotReuseSuccessorPendingSignature() public {
        if (!realPrecompiles) { vm.skip(true); return; }
        DVTValidator replacement = _replacement(1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        vm.prank(address(101));
        uint256 id = replacement.createProposal(op, 1, "successor pending");
        bytes memory proof = _proofForMask(0x7F, keccak256(abi.encode(
            bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), id, op, uint8(1), uint256(9), bytes32(0)
        )));
        vm.prank(owner);
        bls.setDVTValidator(address(dvt));
        assertEq(bls.proposalFloor(), id + 1, "rollback preserves successor allocations");
        vm.startPrank(address(101));
        uint256 freshId = dvt.createProposal(op, 1, "rollback intent");
        assertEq(freshId, id + 1);
        vm.expectRevert(BLSAggregator.SignatureVerificationFailed.selector);
        dvt.executeWithProof(freshId, new address[](0), new uint256[](0), 9, proof);
        vm.stopPrank();
        assertFalse(bls.executedProposals(freshId));
    }

    function test_Review_BrokenCounterFailsClosedAndExplicitFloorRecovers() public {
        vm.prank(address(101));
        uint256 pending = dvt.createProposal(op, 1, "pending");
        DVTValidator replacement = _replacement(1);
        vm.mockCallRevert(address(dvt), abi.encodeWithSignature("nextProposalId()"), abi.encodeWithSignature("Error(string)", "retired counter unavailable"));
        vm.startPrank(owner);
        vm.expectRevert("retired counter unavailable");
        bls.setDVTValidator(address(replacement));
        assertEq(bls.DVT_VALIDATOR(), address(dvt), "failed activation is atomic");
        assertEq(bls.proposalFloor(), 0);
        bls.setDVTValidatorWithFloor(address(replacement), pending + 1);
        vm.stopPrank();
        vm.prank(address(101));
        assertEq(replacement.createProposal(op, 1, "recovered"), pending + 1, "broken retired contract cannot veto allocation");
        vm.prank(owner);
        vm.expectRevert(BLSAggregator.InvalidProposalFloor.selector);
        bls.setDVTValidatorWithFloor(address(dvt), pending);
        assertEq(bls.proposalFloor(), pending + 1, "recovery cannot lower the floor");
    }

    function test_Review_GarbageCounterFailsClosedAndExplicitFloorRecovers() public {
        DVTValidator replacement = _replacement(1);
        vm.mockCall(address(dvt), abi.encodeWithSignature("nextProposalId()"), hex"01");
        vm.startPrank(owner);
        vm.expectRevert(); // malformed ABI return, before any pointer or floor write
        bls.setDVTValidator(address(replacement));
        assertEq(bls.DVT_VALIDATOR(), address(dvt));
        vm.mockCall(address(dvt), abi.encodeWithSignature("nextProposalId()"), abi.encode(type(uint256).max));
        vm.expectRevert(BLSAggregator.InvalidProposalFloor.selector);
        bls.setDVTValidator(address(replacement));
        bls.setDVTValidatorWithFloor(address(replacement), 42);
        vm.stopPrank();
        vm.prank(address(101));
        assertEq(replacement.createProposal(op, 1, "recovered"), 42);
    }

    function test_Review_RotationChecksBothPointersAndOwnerAuthority() public {
        vm.startPrank(owner);
        DVTValidator wrong = new DVTValidator(address(0xBAD), 1);
        wrong.setBLSAggregator(address(bls));
        vm.expectRevert(BLSAggregator.InvalidDVTPairing.selector);
        bls.setDVTValidator(address(wrong));
        DVTValidator wrongAgg = new DVTValidator(address(registry), 1);
        wrongAgg.setBLSAggregator(address(0xBAD));
        vm.expectRevert(BLSAggregator.InvalidDVTPairing.selector);
        bls.setDVTValidator(address(wrongAgg));
        vm.expectRevert();
        bls.setDVTValidator(address(0));
        vm.stopPrank();
        vm.prank(address(101));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(101)));
        bls.setDVTValidatorWithFloor(address(dvt), 2);
        assertEq(bls.DVT_VALIDATOR(), address(dvt));
        assertEq(bls.proposalFloor(), 0);
    }

    function test_Review_RetiredCountersCannotAccumulateDependencies() public {
        uint256 gasBefore = gasleft();
        uint256 rotations = 32;
        DVTValidator current = dvt;
        // setDVTValidator gas at the 2nd, 16th and 32nd rotation: a predecessor walk would grow with i.
        // The 1st rotation is excluded only because it writes proposalFloor from zero (a fresh SSTORE).
        uint256[3] memory rotationGas;
        for (uint256 i; i < rotations; ++i) {
            vm.prank(address(101));
            assertEq(current.createProposal(op, 1, "pending"), i + 1);
            // Run the real constructor/runtime without repeated code-deposit gas.
            // Rotation and allocation remain metered within one capped test call.
            DVTValidator next = DVTValidator(address(uint160(0xD000 + i)));
            vm.startPrank(owner);
            deployCodeTo("DVTValidator.sol:DVTValidator", abi.encode(address(registry), uint256(1)), address(next));
            next.setBLSAggregator(address(bls));
            next.addValidator(address(101));
            uint256 g = gasleft();
            bls.setDVTValidator(address(next));
            g -= gasleft();
            if (i == 1) rotationGas[0] = g;
            else if (i == 15) rotationGas[1] = g;
            else if (i == rotations - 1) rotationGas[2] = g;
            vm.stopPrank();
            vm.mockCallRevert(address(current), abi.encodeWithSignature("nextProposalId()"), hex"deadbeef");
            vm.expectCall(address(current), bytes(""), uint64(0));
            current = next;
        }
        assertEq(current.nextProposalId(), rotations + 1, "no retired-counter recursion after 32 rotations");
        emit log_named_uint("setDVTValidator gas, rotation 2", rotationGas[0]);
        emit log_named_uint("setDVTValidator gas, rotation 16", rotationGas[1]);
        emit log_named_uint("setDVTValidator gas, rotation 32", rotationGas[2]);
        assertEq(rotationGas[1], rotationGas[0], "rotation cost must not grow with the rotation number (16 vs 2)");
        assertEq(rotationGas[2], rotationGas[0], "rotation cost must not grow with the rotation number (32 vs 2)");
        vm.expectCall(address(bls), abi.encodeWithSignature("proposalFloor()"), uint64(1));
        vm.prank(address(101));
        assertEq(current.createProposal(op, 1, "still live"), rotations + 1);
        // gasleft() deltas here include cheatcode work (deployCodeTo) and are not the call's metered
        // gas under every engine, so the per-call cap is not asserted from inside the test; the
        // property under test is the constant rotation cost asserted above.
        emit log_named_uint("retired-counter test gasleft delta", gasBefore - gasleft());
    }

    function test_Review_ExitAndRemovalPreserveGenericMinimum() public {
        vm.startPrank(owner);
        for (uint256 i = 104; i <= 110; ++i) bls.revokeBLSPublicKey(address(uint160(i)));
        for (uint8 severity; severity < 3; ++severity) bls.setSlashThreshold(severity, 2);
        vm.stopPrank();
        assertEq(bls.minThreshold(), 3);
        bytes32 digest = keccak256("generic quorum");
        (, bytes memory sig) = abi.decode(_proofForMask(7, digest), (uint256, bytes));
        assertTrue(bls.verify(digest, 7, 3, sig));
        vm.prank(address(101));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitWouldBreakQuorum.selector, uint256(2), uint256(3)));
        bls.requestGuardianExit();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitWouldBreakQuorum.selector, uint256(2), uint256(3)));
        dvt.removeValidator(address(101));
        vm.warp(block.timestamp + bls.GUARDIAN_EXIT_DELAY());
        assertTrue(bls.verify(digest, 7, 3, sig), "failed exits preserve the working generic quorum");
    }

    function test_Review_RotationAndRollbackKeepSuspensionOnExistingSlot() public {
        vm.startPrank(owner);
        bls.setPermissionlessBLSRegistration(true);
        bls.setSuspended(address(101), true);
        vm.stopPrank();
        DVTValidator replacement = _replacement(1);
        vm.prank(owner);
        bls.setDVTValidator(address(replacement));
        bytes32 digest = keccak256("suspended existing slot");
        (, bytes memory sig) = abi.decode(_proofForMask(0x7F, digest), (uint256, bytes));
        BLS.G1Point memory key = _stubKey(1);
        BLS.G2Point memory pop = _pop(address(101), 1);
        vm.prank(address(101));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.ValidatorSuspended.selector, address(101)));
        replacement.registerBLSPublicKey(address(101), key, 1, pop);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.ValidatorSuspended.selector, address(101)));
        bls.verify(digest, 0x7F, 7, sig);
        vm.prank(owner);
        bls.setDVTValidator(address(dvt));
        assertTrue(bls.suspended(address(101)), "rotation and rollback preserve authoritative suspension");
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.ValidatorSuspended.selector, address(101)));
        bls.verify(digest, 0x7F, 7, sig);
        vm.prank(address(dvt));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.ValidatorSuspended.selector, address(101)));
        bls.registerBLSPublicKey(address(101), key, 1, pop);
        vm.prank(owner);
        bls.setSuspended(address(101), false);
        assertTrue(bls.verify(digest, 0x7F, 7, sig), "only explicit owner clearance restores slot voting");
    }

    function test_Review_EmergencyRevokeSuspendsPermissionlessOnlyMember() public {
        DVTValidator replacement = _replacement(1);
        vm.startPrank(owner);
        bls.setDVTValidator(address(replacement));
        bls.setPermissionlessBLSRegistration(true);
        bls.setDefaultThreshold(10);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.GuardianExitWouldBreakQuorum.selector, uint256(9), uint256(10)));
        replacement.removeValidator(address(102));
        bls.revokeAndSuspend(address(102));
        vm.stopPrank();
        assertFalse(replacement.isValidator(address(102)));
        assertTrue(bls.suspended(address(102)));
        (,, bool active) = bls.getBLSPublicKey(address(102));
        assertFalse(active);
        BLS.G1Point memory key = _stubKey(2);
        BLS.G2Point memory pop = _pop(address(102), 2);
        vm.prank(address(102));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.ValidatorSuspended.selector, address(102)));
        replacement.registerBLSPublicKey(address(102), key, 2, pop);
    }

    function test_Review_SuspensionCanPrecedeAnyKeyOrAdmissionAndIsOwnerOnly() public {
        address unknown = address(500);
        vm.prank(owner);
        bls.setSuspended(unknown, true);
        assertTrue(bls.suspended(unknown));
        vm.prank(unknown);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", unknown));
        bls.setSuspended(unknown, false);
        vm.prank(unknown);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", unknown));
        bls.revokeAndSuspend(address(101));
        vm.prank(owner);
        bls.revokeAndSuspend(unknown);
        assertTrue(bls.suspended(unknown), "atomic suspension is valid without an active key");
    }
}
