// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../interfaces/v3/IBLSValidator.sol";
import { BLS } from "../../utils/BLS.sol";

/**
 * @title BLSValidator
 * @notice Production validator contract for BLS signature verification.
 * @dev Implements IBLSValidator. Logic can be upgraded/swapped via Registry configuration.
 */
contract BLSValidator is IBLSValidator {
    
    // P Split
    uint256 constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7; 
    uint256 constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab; 

    function verifyProof(bytes calldata proof, bytes calldata message) external view override returns (bool isValid) {
        if (proof.length == 0) return false;

        // 1. Decode Proof (Aggregate Signature G2 and Public Key G1)
        // Proof format: [G1_PK(128 bytes)][G2_SIG(256 bytes)]
        if (proof.length < 384) return false;

        BLS.G1Point memory pk = abi.decode(proof[0:128], (BLS.G1Point));
        BLS.G2Point memory sig = abi.decode(proof[128:384], (BLS.G2Point));

        // 2. Hash message to G2
        BLS.G2Point memory msgG2 = BLS.hashToG2(message);

        // 3. Pairing Check: e(G1_GEN, SIG) == e(PK, msgG2)
        // Equivalent to: e(G1_GEN, SIG) * e(-PK, msgG2) == 1
        
        BLS.G1Point[] memory g1s = new BLS.G1Point[](2);
        BLS.G2Point[] memory g2s = new BLS.G2Point[](2);

        g1s[0] = _getG1Gen();
        g2s[0] = sig;

        g1s[1] = _negateG1(pk);
        g2s[1] = msgG2;

        try BLS.pairing(g1s, g2s) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }

    /// @dev Negates a G1 point (P - Y)
    function _negateG1(BLS.G1Point memory p) internal pure returns (BLS.G1Point memory) {
        uint256 ya = uint256(p.y_a);
        uint256 yb = uint256(p.y_b);
        if (ya == 0 && yb == 0) return p;

        unchecked {
            uint256 res_b = P_LO - yb;
            uint256 borrow = (yb > P_LO) ? 1 : 0;
            uint256 res_a = P_HI - ya - borrow;

            p.y_a = bytes32(res_a);
            p.y_b = bytes32(res_b);
        }
        return p;
    }

    function _getG1Gen() internal pure returns (BLS.G1Point memory p) {
        // G1 Generator (Standard BLS12-381)
        p.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        p.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        
        p.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        p.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }

    function version() external pure override returns (string memory) {
        return "BLSValidator-0.3.2";
    }
}
