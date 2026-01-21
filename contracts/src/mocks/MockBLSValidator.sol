// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "src/interfaces/v3/IBLSValidator.sol";

/**
 * @title MockBLSValidator
 * @notice Mock validator for testing environments (Anvil/Hardhat).
 * @dev Always returns true to bypass signature verification in tests.
 *      DO NOT USE IN PRODUCTION.
 */
contract MockBLSValidator is IBLSValidator {
    function verifyProof(bytes calldata /* proof */, bytes calldata /* message */) external pure override returns (bool) {
        return true;
    }

    function version() external pure override returns (string memory) {
        return "MockBLSValidator-0.1.0";
    }
}
