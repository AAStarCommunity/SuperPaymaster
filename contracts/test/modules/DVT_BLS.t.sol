// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/IVersioned.sol";
import "src/interfaces/v3/IGTokenStaking.sol";

import "src/utils/BLS.sol";
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
    BLSAggregator bls;
    MockRegistryV3 registry;
    MockSuperPaymaster sp;

    address owner = address(1);
    address op = address(2);

    uint256 constant THRESHOLD = 7;

    function _stubKey(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(seed);
        pk.x_b = bytes32(seed + 1);
        pk.y_a = bytes32(seed + 2);
        pk.y_b = bytes32(seed + 3);
    }

    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

    function setUp() public {
        // Mock BLS precompiles BEFORE any registerBLSPublicKey call below —
        // _validateG1Point invokes G1ADD (0x0b) and G1MUL (0x0c) at register
        // time, so the etch must already be in place.
        // 0x0b (G1ADD): returns 128 bytes (0x80) — used by _reconstructPkAgg + on-curve check.
        // CC-48 round-3 MEDIUM-5: this harness injects fake EIP-2537 precompiles, which
        // is impossible on a real Prague EVM. Step aside there; contracts/test/paper7/
        // covers these paths with genuine keys and pairings.
        if (MockedPrecompiles.skipIfReal()) return;
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

        vm.startPrank(owner);
        registry = new MockRegistryV3();
        // P0-2: provide a permissive staking stub so addValidator's stake gate
        // resolves; minStake on the mock RoleConfig is 0 so any reported
        // balance passes the floor.
        registry.setStakingAddr(address(new MockStakingPermissive()));
        sp = new MockSuperPaymaster();

        // Circular dependency handling
        dvt = new DVTValidator(address(registry), 1);
        bls = new BLSAggregator(address(registry), address(sp), address(dvt));

        dvt.setBLSAggregator(address(bls));

        // Add validators (10) and register their BLS keys into deterministic slots.
        for (uint256 i = 1; i <= 10; i++) {
            address v = address(uint160(i + 100)); // 101..110
            dvt.addValidator(v);
            // P0-1: register typed G1 key into slot i. The first 7 keys (slots 1..7)
            // form the default-threshold quorum used by tests below.
            bls.registerBLSPublicKey(v, _stubKey(uint256(i)), uint8(i), _emptyPoP());
        }

        vm.stopPrank();
    }

    /// @notice Build a P0-1 compliant proof: only (signerMask, sigG2). pkAgg
    ///         is reconstructed inside the contract from on-chain keys.
    function _proofForMask(uint256 signerMask) internal pure returns (bytes memory) {
        BLS.G2Point memory sig; // zeroed — pairing precompile is mocked
        return abi.encode(signerMask, abi.encode(sig));
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
        vm.startPrank(address(101)); // Validator 1
        uint256 id = dvt.createProposal(op, 1, "Bad Operator");
        assertEq(id, 1);
        vm.stopPrank();

        // ✅ Signatures now collected off-chain via DVT P2P protocol
        // Skip on-chain signProposal calls

        // P0-4: executeWithProof now restricted to BLS aggregator or registered
        // validators. Use Validator 1 to drive the call.
        vm.startPrank(address(101));

        // Mock BLS pairing as success
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        // 7 signers across slots 1..7 = bits 0..6 set = 0x7F.
        uint256 signerMask = 0x7F;
        bytes memory mockProof = _proofForMask(signerMask);

        uint256 epoch = id;
        bytes32 queueMessage = keccak256(abi.encode(bls.domainSeparator(), bls.TAG_QUEUE_SLASH(), op, uint8(1), epoch));
        uint256 queueKey = uint256(queueMessage);
        vm.expectEmit(true, false, false, true, address(bls));
        emit BLSAggregator.SignersCommitted(queueKey, signerMask);
        dvt.queueSlashWithProof(op, 1, epoch, mockProof);

        bytes memory callData = abi.encodeWithSignature("queued()");
        bytes32 genericMessage = keccak256(
            abi.encode(bls.domainSeparator(), bls.TAG_PROPOSAL(), id, address(sp), keccak256(callData), uint256(3))
        );
        uint256 genericKey = uint256(keccak256(abi.encode(bls.TAG_PROPOSAL(), id)));
        vm.stopPrank();
        vm.prank(owner);
        bls.executeProposal(id, address(sp), callData, 3, mockProof);

        uint256 slashKey = id;
        bytes32 slashMessage =
            keccak256(abi.encode(bls.domainSeparator(), bls.TAG_EXECUTE_SLASH(), id, op, uint8(1), epoch, bytes32(0)));
        vm.startPrank(address(101));
        vm.expectEmit(true, false, false, true, address(bls));
        emit BLSAggregator.SignersCommitted(slashKey, signerMask);
        dvt.executeWithProof(id, new address[](0), new uint256[](0), epoch, mockProof);
        vm.stopPrank();

        // Check proposal was executed
        (,,, bool executed,,) = dvt.proposals(id);
        assertTrue(executed, "Proposal should be executed");
        assertEq(bls.proposalSignersCommitment(queueKey), _expectedCommitment(queueKey, queueMessage, signerMask));
        assertEq(bls.proposalSignersCommitment(genericKey), _expectedCommitment(genericKey, genericMessage, signerMask));
        assertEq(bls.proposalSignersCommitment(slashKey), _expectedCommitment(slashKey, slashMessage, signerMask));
    }

    function test_SlashRawIdEqualToGenericKeyCannotOverwriteGenericCommitment() public {
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        uint256 signerMask = 0x7F;
        bytes memory proof = _proofForMask(signerMask);
        uint256 genericId = 8123;
        uint256 genericKey = uint256(keccak256(abi.encode(bls.TAG_PROPOSAL(), genericId)));
        bytes memory callData = abi.encodeWithSignature("queued()");

        vm.prank(owner);
        bls.executeProposal(genericId, address(sp), callData, 3, proof);
        bytes32 genericCommitment = bls.proposalSignersCommitment(genericKey);

        vm.mockCall(
            address(dvt), abi.encodeWithSelector(DVTValidator.markProposalExecuted.selector, genericKey), bytes("")
        );
        vm.expectRevert(BLSAggregator.InvalidProposalId.selector);
        vm.prank(owner);
        bls.verifyAndExecute(genericKey, op, 1, new address[](0), new uint256[](0), 9, bytes32(uint256(0xE1D3)), proof);

        assertEq(bls.proposalSignersCommitment(genericKey), genericCommitment, "generic commitment preserved");
    }

    /// @dev The reputation branch shares the raw-id namespace; it must be bounded too, or a
    ///      reputation id equal to a generic typed key pre-consumes and overwrites that slot.
    function test_ReputationRawIdEqualToGenericKeyCannotPreconsumeGenericSlot() public {
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        uint256 signerMask = 0x7F;
        bytes memory proof = _proofForMask(signerMask);
        uint256 genericId = 8124;
        uint256 genericKey = uint256(keccak256(abi.encode(bls.TAG_PROPOSAL(), genericId)));
        address[] memory users = new address[](1);
        users[0] = address(0xBEEF);
        uint256[] memory scores = new uint256[](1);
        scores[0] = 10;

        // Attack order: a reputation proposal FIRST, with its raw id set to the generic typed key.
        vm.expectRevert(BLSAggregator.InvalidProposalId.selector);
        vm.prank(owner);
        bls.verifyAndExecute(genericKey, address(0), 0, users, scores, 9, bytes32(0), proof);
        assertFalse(bls.executedProposals(genericKey), "generic replay slot not pre-consumed");
        assertEq(bls.proposalSignersCommitment(genericKey), bytes32(0), "no commitment written at the generic key");

        // The generic proposal still executes and owns its slot.
        vm.prank(owner);
        bls.executeProposal(genericId, address(sp), abi.encodeWithSignature("queued()"), 3, proof);
        assertTrue(bls.executedProposals(genericKey));

        // Boundary: 2^128-1 passes the bound (it may fail later, never with InvalidProposalId).
        vm.prank(owner);
        try bls.verifyAndExecute(type(uint128).max, address(0), 0, users, scores, 9, bytes32(0), proof) {}
        catch (bytes memory err) {
            assertTrue(bytes4(err) != BLSAggregator.InvalidProposalId.selector, "2^128-1 must pass the bound");
        }
    }

    function test_QueueSlashWithConsensus_FlagsAndBlocksReplay() public {
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1))); // pairing success
        bytes memory proof = _proofForMask(0x7F); // 7 signers >= MINOR threshold (3)

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
        vm.prank(address(dvt));
        bls.queueSlashWithConsensus(op, 1, 43, proof);
    }

    function test_QueueSlashWithProof_ForwarderFlags() public {
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        uint256 signerMask = 0x7F;
        bytes memory proof = _proofForMask(signerMask);
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
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        bytes memory mockProof = _proofForMask(0x7F);

        vm.prank(address(dvt));

        bls.verifyAndExecute(id, op, 1, new address[](0), new uint256[](0), 123, bytes32(0), mockProof);

        assertTrue(bls.executedProposals(id));
    }

    function test_DVTRotation_ContinuesAfterExecutedProposalRange() public {
        bytes memory proof = _proofForMask(0x7F);
        uint256 lastExecutedId = 2;

        for (uint256 expectedId = 1; expectedId <= lastExecutedId; ++expectedId) {
            vm.prank(address(101));
            uint256 id = dvt.createProposal(op, 1, "pre-rotation");
            assertEq(id, expectedId);
            vm.prank(address(101));
            dvt.executeWithProof(id, new address[](0), new uint256[](0), id, proof);
            assertTrue(bls.executedProposals(id));
        }

        vm.startPrank(owner);
        DVTValidator replacement = new DVTValidator(address(registry), lastExecutedId + 1);
        replacement.setBLSAggregator(address(bls));
        replacement.addValidator(address(101));
        bls.setDVTValidator(address(replacement));
        vm.stopPrank();

        vm.prank(address(101));
        uint256 replacementId = replacement.createProposal(op, 1, "post-rotation");
        assertEq(replacementId, lastExecutedId + 1);
        vm.prank(address(101));
        replacement.executeWithProof(
            replacementId, new address[](0), new uint256[](0), replacementId, proof
        );

        assertTrue(bls.executedProposals(replacementId));
        (,,, bool executed,,) = replacement.proposals(replacementId);
        assertTrue(executed);
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
