// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {BLS} from "src/utils/BLS.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";

/// @notice Genuine EIP-2537 test material, extracted from the paper7 suites.
/// @dev Requires real precompiles. Scalar array index i corresponds to slot i + 1.
library GenuineBLS {
    function pop(BLSAggregator aggregator, address validator, uint256 scalar)
        internal view returns (BLS.G2Point memory)
    {
        return signature(abi.encodePacked(aggregator.popDigest(validator, publicKey(scalar))), scalar);
    }

    function signature(bytes memory message, uint256 scalar) internal view returns (BLS.G2Point memory) {
        return multiplyG2(BLS.hashToG2(message), scalar);
    }

    function proof(bytes32 messageHash, uint256[] memory scalars, uint256 signerMask)
        internal view returns (bytes memory)
    {
        require(scalars.length <= 256 && signerMask != 0, "Invalid signer mask");
        require(scalars.length == 256 || (signerMask >> scalars.length) == 0, "Missing signer scalar");
        BLS.G2Point memory aggregateSignature;
        BLS.G2Point memory messagePoint = BLS.hashToG2(abi.encodePacked(messageHash));
        bool first = true;
        for (uint256 i = 0; i < scalars.length; ++i) {
            if ((signerMask & (uint256(1) << i)) == 0) continue;
            BLS.G2Point memory partialSignature = multiplyG2(messagePoint, scalars[i]);
            aggregateSignature = first ? partialSignature : BLS.add(aggregateSignature, partialSignature);
            first = false;
        }
        return abi.encode(signerMask, abi.encode(aggregateSignature));
    }

    function publicKey(uint256 scalar) internal view returns (BLS.G1Point memory) {
        BLS.G1Point[] memory points = new BLS.G1Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = g1Generator();
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function multiplyG2(BLS.G2Point memory point, uint256 scalar) internal view returns (BLS.G2Point memory) {
        BLS.G2Point[] memory points = new BLS.G2Point[](1);
        bytes32[] memory scalars = new bytes32[](1);
        points[0] = point;
        scalars[0] = bytes32(scalar);
        return BLS.msm(points, scalars);
    }

    function g1Generator() internal pure returns (BLS.G1Point memory generator) {
        generator.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        generator.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        generator.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        generator.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }
}
