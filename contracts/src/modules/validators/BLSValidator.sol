// SPDX-License-Identifier: MIT
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
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
        if (proof.length < 192) return false; // Min length for PK + Sig + MsgG2 + Mask
        if (message.length == 0) return false;

        // ✅ UNIFIED SCHEMA: Support ABI-encoded proof format
        // Proof format: abi.encode(bytes pkG1, bytes sigG2, bytes msgG2, uint256 signerMask)
        // This matches Registry and BLSAggregator format for consistency
        
        (bytes memory pkG1Bytes, bytes memory sigG2Bytes, bytes memory msgG2Bytes, uint256 signerMask) 
            = abi.decode(proof, (bytes, bytes, bytes, uint256));
        
        // Decode G1/G2 points from bytes
        BLS.G1Point memory pk = abi.decode(pkG1Bytes, (BLS.G1Point));
        BLS.G2Point memory sig = abi.decode(sigG2Bytes, (BLS.G2Point));
        BLS.G2Point memory providedMsgG2 = abi.decode(msgG2Bytes, (BLS.G2Point));

        // ✅ MESSAGE BINDING: Verify msgG2 matches expected message
        BLS.G2Point memory expectedMsgG2 = BLS.hashToG2(message);
        if (!_g2Equal(expectedMsgG2, providedMsgG2)) return false;

        // Pairing Check: e(G1_GEN, SIG) == e(PK, msgG2)
        BLS.G1Point[] memory g1s = new BLS.G1Point[](2);
        BLS.G2Point[] memory g2s = new BLS.G2Point[](2);

        g1s[0] = _getG1Gen();
        g2s[0] = sig;
        g1s[1] = _negateG1(pk);
        g2s[1] = providedMsgG2;

        return BLS.pairing(g1s, g2s);
    }

    /// @dev Compare two G2 points for equality
    function _g2Equal(BLS.G2Point memory a, BLS.G2Point memory b) internal pure returns (bool) {
        return a.x_c0_a == b.x_c0_a && a.x_c0_b == b.x_c0_b &&
               a.x_c1_a == b.x_c1_a && a.x_c1_b == b.x_c1_b &&
               a.y_c0_a == b.y_c0_a && a.y_c0_b == b.y_c0_b &&
               a.y_c1_a == b.y_c1_a && a.y_c1_b == b.y_c1_b;
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
