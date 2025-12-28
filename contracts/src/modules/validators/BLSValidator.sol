// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../interfaces/v3/IBLSValidator.sol";
import { LibBLS } from "solady/utils/LibBLS.sol";

/**
 * @title BLSValidator
 * @notice Production validator contract for BLS signature verification.
 * @dev Implements IBLSValidator. Logic can be upgraded/swapped via Registry configuration.
 */
contract BLSValidator is IBLSValidator {
    
    // BLS12-381 G1 Generator (affine) - 128 bytes (64 byte aligned coordinates)
    bytes constant G1_X_BYTES = hex"0000000000000000000000000000000017f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes constant G1_Y_BYTES = hex"0000000000000000000000000000000008b3f481e3aaa9a12174adfa9d9e00912180f1482c0bcd3b0ff955a6d051029441c4a4f147cc520556770e0a5c483a27";
    
    // Field Modulus P
    uint256 constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7; 
    uint256 constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab; 

    /**
     * @notice Verifies a robust BLS signature using EIP-2537 or equivalent logic via Solady.
     * @param proof Encoded proof data: (pkG1, sigG2, msgG2, signerMask). Note: msgG2 is optional if re-hashing.
     * @param referenceData Functionally unused in this implementation but kept for interface compatibility.
     * @return isValid True if the signature is valid.
     */
    function verifyProof(bytes calldata proof, bytes calldata referenceData) external view override returns (bool isValid) {
        if (proof.length == 0) revert("Validator: Proof Empty");
        
        // Decode the standard proof structure
        // pkG1: Aggregated Public Key (G1 Point) - 48 bytes (compressed) or 96 (uncompressed)
        // sigG2: Aggregated Signature (G2 Point) - 96 bytes (compressed) or 192 (uncompressed)
        // msgG2: Message mapped to G2 (optional fallback if not using referenceData)
        // signerMask: Bitmask of signers (unused for basic aggregate verification)
        (bytes memory pkG1, bytes memory sigG2, bytes memory msgG2, uint256 /* signerMask */) = abi.decode(proof, (bytes, bytes, bytes, uint256));

        // Use Solady's LibBLS for the pairing check: e(pk, msg) == e(g1, sig)? 
        // Note: LibBLS usually checks e(A, B) * e(C, D) == 1.
        // Standard check: e(g1, signature) == e(pubKey, H(m))
        // Pairing equation: e(g1, signature) * e(pubKey, -H(m)) == 1
        
        // 1. Convert Points
        // LibBLS works mainly with G1 points for PubKeys and G2 for Signatures if defined that way.
        // EIP-2537 supports both. Usually:
        // PK on G1, Sig on G2. Message hash on G2.
        
        // Try direct pairing check using precompiles via Solady
        try LibBLS.verify(
            LibBLS.decodePointG2(sigG2), 
            LibBLS.decodePointG2(msgG2), 
            LibBLS.decodePointG1(pkG1)
        ) returns (bool result) {
            return result;
        } catch {
            // Fallback for local testing if precompile fails/missing? 
            // Ideally we fail hard, but for Anvil without 0x0b-0x11, we might need a bypass via Mock.
            // Since this is the production contract, we allow the revert to propagate if the environment is strictly production.
            // But if we want to be safe:
            revert("Validator: EIP-2537 Precompile Call Failed");
        }
    }
}
