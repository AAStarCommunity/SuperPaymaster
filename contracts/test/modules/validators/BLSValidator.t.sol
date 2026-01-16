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

    function test_RevertsIfProofInvalid() public {
        // Invalid but properly structured proof should return false
        bytes memory badProof = abi.encode(
            hex"1234", // bad PK
            hex"1234", // bad sig
            hex"1234", // bad msg
            uint256(1) // mask
        );
        vm.expectRevert();
        validator.verifyProof(badProof, "hello");
    }
}
