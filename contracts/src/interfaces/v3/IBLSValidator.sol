// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import "src/interfaces/IVersioned.sol";

interface IBLSValidator is IVersioned {
    /**
     * @notice Verifies a robust BLS signature using EIP-2537 or equivalent logic.
     * @param proof Encoded proof data (e.g., [pkG1.x, pkG1.y, sigG2..., msg...])
     * @param referenceData Additional context (e.g., public keys, rule IDs) if needed
     * @return isValid True if the signature is valid
     */
    function verifyProof(bytes calldata proof, bytes calldata referenceData) external view returns (bool isValid);
}
