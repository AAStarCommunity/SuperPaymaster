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

    function test_ReturnsTrueIfProofPresent() public {
        bool isValid = validator.verifyProof("0x12", "");
        assertTrue(isValid);
    }
}
