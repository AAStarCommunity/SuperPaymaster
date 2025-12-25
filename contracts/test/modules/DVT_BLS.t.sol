// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidatorV3.sol";
import "src/modules/monitoring/BLSAggregatorV3.sol";

// Mocks
contract MockRegistryV3 is IRegistryV3 {
    function batchUpdateGlobalReputation(address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function hasRole(bytes32, address) external pure override returns (bool) { return true; }
    function ROLE_COMMUNITY() external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER() external pure override returns (bytes32) { return keccak256("ENDUSER"); }
    
    // Stubs
    function calculateExitFee(bytes32, uint256) external pure override returns (uint256) { return 0; }
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function createNewRole(bytes32, RoleConfig calldata, address) external override {}
    function exitRole(bytes32) external override {}
    function getBurnHistory(address) external view override returns (BurnRecord[] memory) { return new BurnRecord[](0); }
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) { 
        return RoleConfig(0,0,0,0,0,0,0,0,false,"stub"); 
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
}

contract MockSuperPaymasterV3 {
    enum SlashLevel { WARNING, MINOR, MAJOR }
    // Mock the call signature
    // executeSlashWithBLS(address,SlashLevel,bytes)
    function executeSlashWithBLS(address operator, SlashLevel level, bytes calldata proof) external {}
}

contract DVTBLSTest is Test {
    DVTValidatorV3 dvt;
    BLSAggregatorV3 bls;
    MockRegistryV3 registry;
    MockSuperPaymasterV3 sp;
    
    address owner = address(1);
    address op = address(2);
    
    uint256 constant THRESHOLD = 7;
    
    function setUp() public {
        vm.startPrank(owner);
        registry = new MockRegistryV3();
        sp = new MockSuperPaymasterV3();
        
        // Circular dependency handling
        dvt = new DVTValidatorV3(address(registry));
        bls = new BLSAggregatorV3(address(registry), address(sp), address(dvt));
        
        dvt.setBLSAggregator(address(bls));
        
        // Add validators
        for(uint i=1; i<=10; i++) {
            address v = address(uint160(i+100)); // 101..110
            dvt.addValidator(v);
            // BLS key registration (mock 48 bytes)
            bytes memory pubKey = new bytes(48);
            bls.registerBLSPublicKey(v, pubKey);
        }
        
        vm.stopPrank();
    }
    
    function test_DVT_ProposalFlow() public {
        vm.startPrank(address(101)); // Validator 1
        uint256 id = dvt.createProposal(op, 1, "Bad Operator");
        assertEq(id, 1);
        vm.stopPrank();
        
        // Sign by 7 validators
        for(uint i=0; i<7; i++) {
            address v = address(uint160(i+101));
            vm.prank(v);
            dvt.signProposal(id, "sig");
        }
        
        // In hardened V3, auto-forward is disabled or requires aggregated proof.
        // We manually execute with a mock proof.
        bytes memory mockProof = abi.encode(
            new bytes(96), // pkG1
            new bytes(192), // sigG2
            new bytes(192), // msgG2
            uint256(0x7F) // mask for 7 signers
        );
        
        // Mock BLS precompile (0x11) to return true (1) for any input
        vm.mockCall(address(0x11), "", abi.encode(uint256(1)));
        
        dvt.executeWithProof(id, new address[](0), new uint256[](0), 0, mockProof);
        
        (,,,bool executed) = dvt.proposals(id);
        // Note: struct order: operator, slashLevel, reason, validators[], signatures[], executed.
        // Wait, proposal struct is not fully exposed via public getter automatically for arrays.
        // Let's rely on event or generic check.
        // Actually public mapping getter returns simple fields, excluding arrays.
        // struct mapping getter: operator, slashLevel, reason, executed.
        
        // (address _op, uint8 _level, string memory _reason, address[] memory _validators, bytes[] memory _signatures, bool _executed) 
        //    = this.getProposalHelper(id); 
            
        // The default getter for `proposals` mapping only returns non-array fields.
        // (address operator, uint8 slashLevel, string reason, bool executed)
        
        (address opOut, , , bool exec) = dvt.proposals(id);
        assertTrue(exec, "Proposal should be executed");
        assertEq(opOut, op);
    }
    
    function test_BLS_ManualVerify() public {
        // Test BLS contract directly
        address[] memory vals = new address[](7);
        bytes[] memory sigs = new bytes[](7);
        for(uint i=0; i<7; i++) {
            vals[i] = address(uint160(i+101));
            sigs[i] = "sig";
        }
        
        // Mock BLS precompile (0x11) for any input
        vm.mockCall(address(0x11), "", abi.encode(uint256(1)));
        
        bytes memory mockProof = abi.encode(
            new bytes(96),
            new bytes(192),
            new bytes(192),
            uint256(0x7F)
        );

        // Only DVT or owner can call verifyAndExecute
        vm.prank(address(dvt));
        bls.verifyAndExecute(
            99, // manual id
            op,
            1, // level
            new address[](0),
            new uint256[](0),
            123,
            mockProof
        );
        
        assertTrue(bls.executedProposals(99));
    }
    
    function test_Fail_NotValidator() public {
        vm.prank(address(0x999));
        vm.expectRevert(DVTValidatorV3.NotValidator.selector);
        dvt.createProposal(op, 1, "fail");
    }
}
