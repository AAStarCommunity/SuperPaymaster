// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/modules/validators/BLSValidator.sol";

contract BLSValidatorTest is Test {
    BLSValidator validator;

    function setUp() public {
        validator = new BLSValidator();
    }

    function test_ReturnsFalseIfProofEmpty() public {
        bool isValid = validator.verifyProof("", "");
        assertFalse(isValid);
    }

    function test_ReturnsFalseIfProofInvalid() public {
        // Invalid proof will cause ABI decode revert
        vm.expectRevert();
        validator.verifyProof("0x12", "");
    }
}
