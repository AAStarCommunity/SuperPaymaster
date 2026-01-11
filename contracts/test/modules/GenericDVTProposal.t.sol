// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/v3/IRegistry.sol";
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

contract MockRegistryForProposal is IRegistry {
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function hasRole(bytes32, address) external pure override returns (bool) { return true; }
    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }
    function ROLE_PAYMASTER_AOA() external pure override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external pure override returns (bytes32) { return keccak256("KMS"); }
    function calculateExitFee(bytes32, uint256) external pure override returns (uint256) { return 0; }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function createNewRole(bytes32, RoleConfig calldata, address) external override {}
    function exitRole(bytes32) external override {}
    function setRoleLockDuration(bytes32, uint256) external override {}
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,0,false,0,"stub",address(0),0); 
    }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function registerRoleSelf(bytes32, bytes calldata) external override returns (uint256) { return 0; }
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function adminConfigureRole(bytes32, uint256, uint256, uint256, uint256) external override {}
    function setReputationSource(address, bool) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function setRoleOwner(bytes32, address) external override {}
    function roleOwners(bytes32) external view override returns (address) { return address(0); }
    function getCreditLimit(address) external view override returns (uint256) { return 100 ether; }
    function isReputationSource(address) external pure override returns (bool) { return true; }
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function version() external view override returns (string memory) { return "MockRegistryForProposal"; }
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
    
    function setUp() public {
        vm.startPrank(owner);
        registry = new MockRegistryForProposal();
        target = new MockTarget();
        dvtValidator = new MockDVTValidator();
        
        bls = new BLSAggregator(address(registry), address(0), address(dvtValidator));
        vm.stopPrank();
    }
    
    function _createMockProof(uint256 proposalId, address _target, bytes memory callData, uint256 reqThreshold) internal view returns (bytes memory) {
        // Construct the expected message hash (must match executeProposal logic)
        bytes32 expectedMessageHash = keccak256(abi.encode(
            proposalId,
            _target,
            keccak256(callData),
            reqThreshold,
            block.chainid
        ));
        
        BLS.G2Point memory point = BLS.hashToG2(abi.encodePacked(expectedMessageHash));
        bytes memory msgG2Bytes = abi.encode(point);
        
        // Create signerMask with enough signatures
        uint256 signerMask = (1 << reqThreshold) - 1; // reqThreshold bits set
        
        return abi.encode(
            new bytes(128),  // pkG1 (mock)
            new bytes(256),  // sigG2 (mock)
            msgG2Bytes,
            signerMask
        );
    }
    
    // ========================================
    // Success Cases
    // ========================================
    
    function test_ExecuteProposal_Success() public {
        uint256 proposalId = 100;
        uint256 requiredThreshold = 5;
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (12345));
        
        bytes memory proof = _createMockProof(proposalId, address(target), callData, requiredThreshold);
        
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
        
        bytes memory proof = _createMockProof(proposalId, address(target), callData, requiredThreshold);
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
        bytes memory proof = _createMockProof(proposalId, address(target), callData, 5);
        
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
        bytes memory proof = _createMockProof(proposalId, address(target), callData, requiredThreshold);
        
        vm.prank(address(dvtValidator));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Threshold below minimum"));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
    }
    
    function test_ExecuteProposal_ThresholdExceedsMax_Reverts() public {
        uint256 proposalId = 301;
        uint256 requiredThreshold = 14; // Above MAX_VALIDATORS (13)
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (1));
        bytes memory proof = _createMockProof(proposalId, address(target), callData, requiredThreshold);
        
        vm.prank(address(dvtValidator));
        vm.expectRevert(abi.encodeWithSelector(BLSAggregator.InvalidParameter.selector, "Threshold exceeds max"));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
    }
    
    function test_ExecuteProposal_ExactMinThreshold_Success() public {
        uint256 proposalId = 302;
        uint256 requiredThreshold = 3; // Exactly minThreshold
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (333));
        
        bytes memory proof = _createMockProof(proposalId, address(target), callData, requiredThreshold);
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        
        vm.prank(address(dvtValidator));
        bls.executeProposal(proposalId, address(target), callData, requiredThreshold, proof);
        
        assertEq(target.lastValue(), 333);
    }
    
    function test_ExecuteProposal_MaxThreshold_Success() public {
        uint256 proposalId = 303;
        uint256 requiredThreshold = 13; // Exactly MAX_VALIDATORS
        bytes memory callData = abi.encodeCall(MockTarget.setValue, (1313));
        
        bytes memory proof = _createMockProof(proposalId, address(target), callData, requiredThreshold);
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
        
        bytes memory proof = _createMockProof(proposalId, address(target), callData, requiredThreshold);
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
        bytes memory proof = _createMockProof(proposalId, address(0), callData, 5);
        
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
        bytes memory proof = _createMockProof(proposalId, address(target), callData, requiredThreshold);
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
