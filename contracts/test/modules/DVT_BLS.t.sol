// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/interfaces/IVersioned.sol";

import "src/utils/BLS.sol";

// Mocks
contract MockRegistryV3 is IRegistry {
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function hasRole(bytes32, address) external pure override returns (bool) { return true; }
    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }
    function ROLE_PAYMASTER_AOA() external pure override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS() external pure override returns (bytes32) { return keccak256("KMS"); }
    
    // Stubs
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
    function version() external view override returns (string memory) { return "MockRegistryV3"; }
}

contract MockSuperPaymaster {
    enum SlashLevel { WARNING, MINOR, MAJOR }
    // Mock the call signature
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
    
    function setUp() public {
        vm.startPrank(owner);
        registry = new MockRegistryV3();
        sp = new MockSuperPaymaster();
        
        // Circular dependency handling
        dvt = new DVTValidator(address(registry));
        bls = new BLSAggregator(address(registry), address(sp), address(dvt));
        
        dvt.setBLSAggregator(address(bls));
        
        // Add validators
        for(uint i=1; i<=10; i++) {
            address v = address(uint160(i+100)); // 101..110
            dvt.addValidator(v);
            // BLS key registration (mock 48 bytes)
            bytes memory pubKey = new bytes(48);
            bls.registerBLSPublicKey(v, pubKey);
        }
        
        // Mock BLS precompiles using raw bytecode injection (vm.etch)
        // This avoids nested contract compilation errors and reliably mocks return data size.
        
        // 0x10 (MapFpToG1): Returns 128 bytes (0x80)
        // Code: PUSH1 0x80 PUSH1 0x00 RETURN -> 60806000f3
        vm.etch(address(0x10), hex"60806000f3");
        
        // 0x11 (MapFp2ToG2): Returns 256 bytes (0x100)
        // Code: PUSH2 0x0100 PUSH1 0x00 RETURN -> 6101006000f3
        vm.etch(address(0x11), hex"6101006000f3");
        
        // 0x0d (G2ADD): Returns 256 bytes (0x100)
        vm.etch(address(0x0d), hex"6101006000f3");

        vm.stopPrank();
    }
    
    function test_DVT_ProposalFlow() public {
        vm.startPrank(address(101)); // Validator 1
        uint256 id = dvt.createProposal(op, 1, "Bad Operator");
        assertEq(id, 1);
        vm.stopPrank();
        
        // ✅ Signatures now collected off-chain via DVT P2P protocol
        // Skip on-chain signProposal calls
        
        
        // ✅ KEY INSIGHT: keccak256(msgG2Bytes) must equal expectedMessageHash
        // expectedMessageHash = keccak256(abi.encode(proposalId, operator, slashLevel, ...))
        // So: msgG2Bytes = abi.encode(proposalId, operator, slashLevel, ...)
        
        bytes memory msgG2Bytes = abi.encode(
            id,                     // proposalId = 1
            op,                     // operator
            uint8(1),              // slashLevel
            new address[](0),       // repUsers
            new uint256[](0),       // newScores  
            uint256(0),            // epoch
            block.chainid           // chainid
        );
        
        // Mock BLS pairing moved down to avoid interference
        // vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        
        bytes32 msgHash = keccak256(msgG2Bytes);
        console.log("TEST msgHash:"); console.logBytes32(msgHash);
        
        BLS.G2Point memory point = BLS.hashToG2(abi.encodePacked(msgHash));
        console.log("TEST Point X_C0_A:"); console.logBytes32(point.x_c0_a);
        
        // Re-encode msgG2Bytes with the point we just calculated/logged
        // This ensures the point passed to verify logic matches what we logged
        bytes memory msgG2Bytes_Corrected = abi.encode(point);

        bytes memory mockProof = abi.encode(
            new bytes(128),  // pkG1 (mock, any value)
            new bytes(256),  // sigG2 (mock, any value)
            msgG2Bytes_Corrected, // Use the one we verified
            uint256(0x7F)    // signerMask: 7 signers
        );
        
        // Mock BLS pairing now
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));

        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, mockProof);
        
        // Check proposal was executed
        (,,,bool executed) = dvt.proposals(id);
        assertTrue(executed, "Proposal should be executed");
    }
    
    function test_BLS_ManualVerify() public {
        // ✅ Same strategy: msgG2Bytes = abi.encode of message params
        bytes memory messageData = abi.encode(
            99,                     // proposalId
            op,                     // operator
            uint8(1),              // slashLevel
            new address[](0),       // repUsers
            new uint256[](0),       // newScores
            uint256(123),          // epoch
            block.chainid           // chainid
        );
        
        bytes32 msgHash = keccak256(messageData);
        BLS.G2Point memory point = BLS.hashToG2(abi.encodePacked(msgHash));
        bytes memory msgG2Bytes = abi.encode(point);
        
        // Mock BLS pairing AFTER point calculation
        vm.mockCall(address(0x0F), "", abi.encode(uint256(1)));
        
        bytes memory mockProof = abi.encode(
            new bytes(128),  // pkG1
            new bytes(256),  // sigG2
            msgG2Bytes,      // ✅ Will pass hash check
            uint256(0x7F)    // signerMask
        );
        
        vm.prank(address(dvt));

        bls.verifyAndExecute(
            99, op, 1,
            new address[](0), new uint256[](0), 123,
            mockProof
        );
        
        assertTrue(bls.executedProposals(99));
    }
    
    function test_Fail_NotValidator() public {
        vm.prank(address(0x999));
        vm.expectRevert(DVTValidator.NotValidator.selector);
        dvt.createProposal(op, 1, "fail");
    }
}
