// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/modules/monitoring/DVTValidatorV3.sol";
import "src/modules/monitoring/BLSAggregatorV3.sol";

// Mocks
contract MockRegistryV3 {
    function batchUpdateGlobalReputation(address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
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
        
        // Check if executed
        // verifyAndExecute calls are automatic? 
        // DVTValidatorV3._forward calls BLS.
        // And BLS calls DVT.markProposalExecuted.
        
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
        
        // Only DVT or owner can call verifyAndExecute
        vm.prank(address(dvt));
        bls.verifyAndExecute(
            99, // manual id
            op,
            1, // level
            vals,
            sigs,
            new address[](0),
            new uint256[](0),
            123
        );
        
        assertTrue(bls.executedProposals(99));
    }
    
    function test_Fail_NotValidator() public {
        vm.prank(address(0x999));
        vm.expectRevert(DVTValidatorV3.NotValidator.selector);
        dvt.createProposal(op, 1, "fail");
    }
}
