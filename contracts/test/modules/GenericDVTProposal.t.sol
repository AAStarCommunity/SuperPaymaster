// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/utils/BLS.sol";

// Mock target contract for testing executeProposal
contract MockTarget {
    uint256 public lastValue;
    bool public shouldRevert;

    function setValue(uint256 value) external {
        if (shouldRevert) revert("MockTarget: revert requested");
        lastValue = value;
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
    function setStakingAddr(address s) external { stakingAddr = s; }
    /// @notice Mirrors Registry.GTOKEN_STAKING() so BLSAggregator's per-slot
    ///         real-time stake check inside `_reconstructPkAgg` resolves.
    function GTOKEN_STAKING() external view returns (IGTokenStaking) {
        return IGTokenStaking(stakingAddr);
    }

    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function hasRole(bytes32, address) external pure override returns (bool) { return true; }
    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }
    function ROLE_PAYMASTER_AOA() external pure override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external pure override returns (bytes32) { return keccak256("KMS"); }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function exitRole(bytes32) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,0,false, 0,"stub",address(0),0); 
    }
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
    function version() external view override returns (string memory) { return "MockRegistryForProposal"; }
    function syncStakeFromStaking(address, bytes32, uint256) external override {}
    function getEffectiveStake(address, bytes32) external view override returns (uint256) { return 0; }
}

// Mock DVT Validator for markProposalExecuted callback
contract MockDVTValidator {
    mapping(uint256 => bool) public executedProposals;
    
    function markProposalExecuted(uint256 proposalId) external {
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

    function setUp() public {
        // Mock BLS precompiles BEFORE any registerBLSPublicKey call —
        // _validateG1Point invokes G1ADD (0x0b) and G1MUL (0x0c) at register
        // time, so the etch must already be in place.
        // 0x0b (G1ADD): Returns 128 bytes (0x80) — used by _reconstructPkAgg
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
        for (uint8 i = 1; i <= 13; i++) {
            address v = address(uint160(uint256(i) + 200));
            bls.registerBLSPublicKey(v, _stubKey(uint256(i)), i);
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
    
    function test_ExecuteProposal_Success() public {
        uint256 proposalId = 100;
        uint256 requiredThreshold = 5;
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (12345));
        
        bytes memory proof = _createMockProof(requiredThreshold);
        
        // Mock BLS pairing
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        
        vm.prank(address(dvtValidator));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
        
        // Verify execution
        assertTrue(bls.executedProposals(proposalId), "Proposal should be marked executed");
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
        uint256 requiredThreshold = 2; // Below minThreshold (3)
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (1));
        bytes memory proof = _createMockProof(requiredThreshold);
        
        vm.prank(address(dvtValidator));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Threshold below minimum"));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
    }
    
    function test_ExecuteProposal_ThresholdExceedsMax_Reverts() public {
        uint256 proposalId = 301;
        uint256 requiredThreshold = 14; // Above MAX_VALIDATORS (13)
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
        uint256 requiredThreshold = 13; // Exactly MAX_VALIDATORS
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (1313));
        
        bytes memory proof = _createMockProof(requiredThreshold);
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        
        vm.prank(address(dvtValidator));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
        
        assertEq(target.lastValue(), 1313);
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
