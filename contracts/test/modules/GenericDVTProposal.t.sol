// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/utils/BLS.sol";
import {MockedPrecompiles} from "../helpers/MockedPrecompiles.sol";

// Mock target contract for testing executeProposal
contract MockTarget {
    uint256 public lastValue;
    bool public shouldRevert;

    function setValue(uint256 value) external {
        if (shouldRevert) revert("MockTarget: revert requested");
        lastValue = value;
    }

    bytes32 public observedCommitment;

    function observeCommitment(uint256 proposalId) external {
        observedCommitment = BLSAggregator(msg.sender).proposalSignersCommitment(proposalId);
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
}

/// @notice Permissive staking stub — every validator has unlimited stake. Used
///         to satisfy the per-slot real-time stake check inside
///         BLSAggregator._reconstructPkAgg without modelling real stake.
contract MockStakingForProposal {
    function roleLocks(address, bytes32 roleId)
        external
        pure
        returns (uint128 amount, uint128 ticketPrice, uint48 lockedAt, bytes32 roleId_, bytes memory metadata)
    {
        return (type(uint128).max, 0, 0, roleId, "");
    }
}

contract MockRegistryForProposal is IRegistry {
    address public stakingAddr;

    function setStakingAddr(address s) external {
        stakingAddr = s;
    }

    /// @notice Mirrors Registry.GTOKEN_STAKING() so BLSAggregator's per-slot
    ///         real-time stake check inside `_reconstructPkAgg` resolves.
    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return IGTokenStaking(stakingAddr);
    }

    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata)
        external
        override
    {}

    function hasRole(bytes32, address) external pure override returns (bool) {
        return true;
    }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}

    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
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
        return "MockRegistryForProposal";
    }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}

    function getEffectiveStake(address, bytes32) external view override returns (uint256) {
        return 0;
    }
}

// Mock DVT Validator for markProposalExecuted callback
contract MockDVTValidator {
    mapping(uint256 => bool) public executedProposals;

    error ProposalDoesNotExist();

    function markProposalExecuted(uint256 proposalId) external {
        if (!executedProposals[proposalId]) revert ProposalDoesNotExist();
        executedProposals[proposalId] = true;
    }
}

/**
 * @title GenericDVTProposalTest
 * @notice Tests for executeProposal functionality including boundary conditions
 */
contract GenericDVTProposalTest is Test {
    BLSAggregator bls;
    MockRegistryForProposal registry;
    MockTarget target;
    MockDVTValidator dvtValidator;

    address owner = address(1);
    address attacker = address(0x1337);

    function _stubKey(uint256 seed) internal pure returns (BLS.G1Point memory pk) {
        pk.x_a = bytes32(seed);
        pk.x_b = bytes32(seed + 1);
        pk.y_a = bytes32(seed + 2);
        pk.y_b = bytes32(seed + 3);
    }

    function _emptyPoP() internal pure returns (BLS.G2Point memory pop) {}

    function setUp() public {
        // Mock BLS precompiles BEFORE any registerBLSPublicKey call —
        // _validateG1Point invokes G1ADD (0x0b) and G1MUL (0x0c) at register
        // time, so the etch must already be in place.
        // 0x0b (G1ADD): Returns 128 bytes (0x80) — used by _reconstructPkAgg
        // CC-48 round-3 MEDIUM-5: this harness injects fake EIP-2537 precompiles, which
        // is impossible on a real Prague EVM. Step aside there; contracts/test/paper7/
        // covers these paths with genuine keys and pairings.
        if (MockedPrecompiles.skipIfReal()) return;
        vm.etch(address(0x0b), hex"60806000f3");
        // 0x0c (G1MUL): Returns 128 bytes of zeros (identity) — required by
        // _validateG1Point's prime-order subgroup check (r*P == O).
        vm.etch(address(0x0c), hex"60806000f3");
        // 0x10 (MapFpToG1): Returns 128 bytes (0x80)
        vm.etch(address(0x10), hex"60806000f3");
        // 0x11 (MapFp2ToG2): Returns 256 bytes (0x100)
        vm.etch(address(0x11), hex"6101006000f3");
        // 0x0d (G2ADD): Returns 256 bytes (0x100)
        vm.etch(address(0x0d), hex"6101006000f3");
        // CC-48 round-3: PoP is now mandatory on BOTH registration paths, so the
        // pairing precompile must answer before any registerBLSPublicKey call in this
        // mocked-precompile harness. Real-pairing coverage of the same registrations
        // lives in contracts/test/paper7/ (RepCreditDomainReplay, CC48PragueE2E).
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        vm.startPrank(owner);
        registry = new MockRegistryForProposal();
        // Wire a permissive staking stub so the real-time per-slot stake check
        // inside `_reconstructPkAgg` resolves with unlimited stake for every
        // validator. RoleConfig.minStake on this mock is 0, so any reported
        // balance passes the floor.
        registry.setStakingAddr(address(new MockStakingForProposal()));
        target = new MockTarget();
        dvtValidator = new MockDVTValidator();

        bls = new BLSAggregator(address(registry), address(999), address(dvtValidator));

        // P0-1: register validator keys into slots 1..MAX_VALIDATORS so the
        // aggregator can reconstruct pkAgg from on-chain state.
        for (uint8 i = 1; i <= 64; i++) {
            address v = address(uint160(uint256(i) + 200));
            bls.registerBLSPublicKey(v, _stubKey(uint256(i)), i, _emptyPoP());
        }

        vm.stopPrank();
    }

    function _createMockProof(uint256 reqThreshold) internal pure returns (bytes memory) {
        // P0-1: proof is now (uint256 signerMask, bytes sigG2). pkAgg / msgG2
        // are derived on-chain from validatorAtSlot / expectedMessageHash.
        uint256 signerMask = (uint256(1) << reqThreshold) - 1; // reqThreshold low bits set
        BLS.G2Point memory sig; // zeroed; the pairing precompile is mocked
        return abi.encode(signerMask, abi.encode(sig));
    }

    // ========================================
    // Success Cases
    // ========================================

    function test_GenericCommitmentIsStoredBeforeTargetCall() public {
        uint256 key = uint256(keccak256(abi.encode(bls.TAG_PROPOSAL(), uint256(901))));
        bytes memory callData = abi.encodeCall(MockTarget.observeCommitment, (key));
        bytes32 messageHash = keccak256(
            abi.encode(
                bls.domainSeparator(),
                keccak256("SuperPaymaster.BLS.Proposal.v1"),
                uint256(901),
                address(target),
                keccak256(callData),
                uint256(3)
            )
        );
        address[] memory signers = new address[](3);
        for (uint256 i; i < 3; ++i) {
            signers[i] = address(uint160(201 + i));
        }
        bytes32 expected = keccak256(
            abi.encode(
                bls.domainSeparator(),
                keccak256("SuperPaymaster.BLS.SignersCommitment.v1"),
                key,
                messageHash,
                uint256(7),
                signers,
                blockhash(block.number - 1)
            )
        );
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        vm.prank(owner);
        bls.executeProposal(901, address(target), callData, 3, _createMockProof(3));
        assertEq(target.observedCommitment(), expected);
        assertEq(bls.proposalSignersCommitment(key), expected);
    }

    function test_C4_L_01_GenericTypedKeyOwnsReplayAndCommitment() public {
        uint256 proposalId = 902;
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (902));
        bytes memory proof = _createMockProof(3);
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        vm.prank(owner);
        bls.executeProposal(proposalId, address(target), callData, 3, proof);

        uint256 replayKey = uint256(keccak256(abi.encode(bls.TAG_PROPOSAL(), proposalId)));
        assertTrue(bls.executedProposals(replayKey), "generic replay guard uses typed key");
        assertFalse(bls.executedProposals(proposalId), "raw id remains outside generic replay map");
        assertEq(bls.proposalSignersCommitment(proposalId), bytes32(0), "raw id must not read generic commitment");
        assertTrue(bls.proposalSignersCommitment(replayKey) != bytes32(0), "commitment uses typed replay key");
    }

    function test_ExecuteProposal_EmitsProofSignerMask() public {
        uint256 proposalId = 903;
        uint256 signerMask = 0x15;
        BLS.G2Point memory sig;
        bytes memory proof = abi.encode(signerMask, abi.encode(sig));
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (903));
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        vm.expectEmit(true, false, false, true, address(bls));
        uint256 key = uint256(keccak256(abi.encode(bls.TAG_PROPOSAL(), proposalId)));
        emit BLSAggregator.SignersCommitted(key, signerMask);
        vm.prank(owner);
        bls.executeProposal(proposalId, address(target), callData, 3, proof);
    }

    function test_ExecuteProposal_Success() public {
        uint256 proposalId = 100;
        uint256 requiredThreshold = 5;
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (12345));

        bytes memory proof = _createMockProof(requiredThreshold);

        // Mock BLS pairing
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        vm.prank(address(dvtValidator));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);

        // Generic execution must not consume slash-only state at the same numeric ID.
        assertFalse(bls.executedProposals(proposalId));
        assertFalse(dvtValidator.executedProposals(proposalId));
        assertEq(target.lastValue(), 12345, "Target value should be set");
    }

    function test_ExecuteProposal_OwnerCanCall() public {
        uint256 proposalId = 101;
        uint256 requiredThreshold = 3;
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (999));

        bytes memory proof = _createMockProof(requiredThreshold);
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        vm.prank(owner);
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);

        assertEq(target.lastValue(), 999);
    }

    // ========================================
    // Access Control Tests
    // ========================================

    function test_ExecuteProposal_Unauthorized_Reverts() public {
        uint256 proposalId = 200;
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (1));
        bytes memory proof = _createMockProof(5);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.UnauthorizedCaller.selector, attacker));
        bls.executeProposal(proposalId, address(target), callData, 5, proof);
    }

    // ========================================
    // Threshold Boundary Tests
    // ========================================

    function test_ExecuteProposal_ThresholdBelowMin_Reverts() public {
        uint256 proposalId = 300;
        uint256 requiredThreshold = 2; // Below generic minThreshold (3)
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (1));
        bytes memory proof = _createMockProof(requiredThreshold);

        vm.prank(address(dvtValidator));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Threshold below minimum"));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
    }

    function test_ExecuteProposal_ThresholdExceedsMax_Reverts() public {
        uint256 proposalId = 301;
        uint256 requiredThreshold = 65; // One past MAX_VALIDATORS (64)
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (1));
        bytes memory proof = _createMockProof(requiredThreshold);

        vm.prank(address(dvtValidator));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Threshold exceeds max"));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
    }

    function test_ExecuteProposal_ExactMinThreshold_Success() public {
        uint256 proposalId = 302;
        uint256 requiredThreshold = 3; // Exactly minThreshold
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (333));

        bytes memory proof = _createMockProof(requiredThreshold);
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        vm.prank(address(dvtValidator));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);

        assertEq(target.lastValue(), 333);
    }

    function test_ExecuteProposal_MaxThreshold_Success() public {
        uint256 proposalId = 303;
        uint256 requiredThreshold = 64; // Exactly MAX_VALIDATORS
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (1313));

        bytes memory proof = _createMockProof(requiredThreshold);
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        vm.prank(address(dvtValidator));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);

        assertEq(target.lastValue(), 1313);
    }

    function test_RegisterBLSPublicKey_HighestSlotAndOnePastCap() public {
        address atCap = address(uint160(264));
        (, uint8 slot, bool isActive) = bls.getBLSPublicKey(atCap);
        assertEq(slot, 64);
        assertTrue(isActive);

        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.SlotOutOfRange.selector, uint8(65)));
        bls.registerBLSPublicKey(address(0xF065), _stubKey(6500), 65, _emptyPoP());
    }

    // ========================================
    // Replay Protection Tests
    // ========================================

    function test_ExecuteProposal_AlreadyExecuted_Reverts() public {
        uint256 proposalId = 400;
        uint256 requiredThreshold = 5;
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (111));

        bytes memory proof = _createMockProof(requiredThreshold);
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        // First execution
        vm.prank(address(dvtValidator));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);

        // Second execution should fail
        vm.prank(address(dvtValidator));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.ProposalAlreadyExecuted.selector, proposalId));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
    }

    // ========================================
    // Target Contract Tests
    // ========================================

    function test_ExecuteProposal_ZeroTarget_Reverts() public {
        uint256 proposalId = 500;
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (1));
        bytes memory proof = _createMockProof(5);

        vm.prank(address(dvtValidator));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidTarget.selector, address(0)));
        bls.executeProposal(proposalId, address(0), callData, 5, proof);
    }

    function test_ExecuteProposal_TargetReverts_PropagatesError() public {
        uint256 proposalId = 501;
        uint256 requiredThreshold = 5;

        // Set target to revert
        target.setShouldRevert(true);

        bytes memory callData = abi.encodeCall(MockTarget.setValue, (999));
        bytes memory proof = _createMockProof(requiredThreshold);
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        vm.prank(address(dvtValidator));
        vm.expectRevert(); // ProposalExecutionFailed
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
    }

    // ========================================
    // Admin Function Tests
    // ========================================

    function test_SetMinThreshold() public {
        vm.prank(owner);
        bls.setMinThreshold(2);
        assertEq(bls.minThreshold(), 2);
    }

    function test_SetMinThreshold_TooLow_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Min threshold too low"));
        bls.setMinThreshold(1);
    }

    function test_SetDefaultThreshold() public {
        vm.prank(owner);
        bls.setDefaultThreshold(10);
        assertEq(bls.defaultThreshold(), 10);
    }

    function test_SetDefaultThreshold_BelowMin_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Below minThreshold"));
        bls.setDefaultThreshold(2); // Below minThreshold (3)
    }
}
