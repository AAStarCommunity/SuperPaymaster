// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {BLS} from "src/utils/BLS.sol";
import {GenuineBLS} from "../helpers/GenuineBLS.sol";
import {MockedPrecompiles} from "../helpers/MockedPrecompiles.sol";

/**
 * @title BLSWrapper
 * @notice Thin external wrapper exposing the `internal` BLS library functions so
 *         they can be unit-tested directly (the library is otherwise only reached
 *         indirectly through BLSAggregator).
 */
contract BLSWrapper {
    function addG1(BLS.G1Point memory a, BLS.G1Point memory b) external view returns (BLS.G1Point memory) {
        return BLS.add(a, b);
    }

    function addG2(BLS.G2Point memory a, BLS.G2Point memory b) external view returns (BLS.G2Point memory) {
        return BLS.add(a, b);
    }

    function pairing(BLS.G1Point[] memory g1, BLS.G2Point[] memory g2) external view returns (bool) {
        return BLS.pairing(g1, g2);
    }

    function toG1(BLS.Fp memory e) external view returns (BLS.G1Point memory) {
        return BLS.toG1(e);
    }

    function toG2(BLS.Fp2 memory e) external view returns (BLS.G2Point memory) {
        return BLS.toG2(e);
    }

    function hashToG2(bytes memory m) external view returns (BLS.G2Point memory) {
        return BLS.hashToG2(m);
    }
}

/**
 * @title BLSLibrary_Test
 * @notice T-H3 (audit §6): direct unit-test skeleton for the EIP-2537 BLS12-381
 *         wrapper library `contracts/src/utils/BLS.sol`, which previously had no
 *         dedicated tests (only indirect coverage via BLSAggregator).
 *
 *         The host EVM is `cancun`, which does NOT ship the EIP-2537 precompiles
 *         (0x0b..0x11). So — exactly like the existing BLSAggregatorUnit suite —
 *         we mock each precompile with `vm.etch` to assert the library's
 *         *dispatch + calldata-packing + error-handling* logic:
 *           - success path: precompile returns the right-sized buffer → library
 *             returns the decoded point / bool.
 *           - failure path: precompile reverts or returns the wrong size → the
 *             library reverts with its typed error (G1AddFailed, PairingFailed…).
 *
 *         Prague/Amsterdam run genuine arithmetic and exact-input dispatch checks.
 *         Malformed-output tests use call mocks on the real precompile addresses;
 *         Cancun retains the original bytecode stubs.
 */
contract BLSLibrary_Test is Test {
    BLSWrapper internal wrapper;
    bool internal realMode;

    // EIP-2537 precompile addresses.
    address constant G1ADD = address(0x0b);
    address constant G2ADD = address(0x0d);
    address constant PAIRING = address(0x0f);
    address constant MAP_FP_TO_G1 = address(0x10);
    address constant MAP_FP2_TO_G2 = address(0x11);

    // Runtime that returns N bytes of zeros: PUSH2 N PUSH1 0 RETURN.
    function _retZeros(uint16 n) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"61", n, hex"6000f3");
    }

    // Runtime that reverts immediately: PUSH1 0 PUSH1 0 REVERT.
    bytes constant RET_REVERT = hex"60006000fd";
    // Runtime that stores 1 at mem[0] and returns a 32-byte truthy word.
    bytes constant RET_TRUE = hex"600160005260206000f3";

    function setUp() public {
        realMode = MockedPrecompiles.praguePrecompilesAvailable();
        wrapper = new BLSWrapper();
        if (realMode) return;
        // Default: install size-correct success mocks for the additive precompiles.
        vm.etch(G1ADD, _retZeros(0x80));    // G1 add → 128-byte point
        vm.etch(G2ADD, _retZeros(0x100));   // G2 add → 256-byte point
        vm.etch(MAP_FP_TO_G1, _retZeros(0x80));
        vm.etch(MAP_FP2_TO_G2, _retZeros(0x100));
    }

    function _revertPrecompile(address target) internal {
        if (realMode) vm.mockCallRevert(target, "", "");
        else vm.etch(target, RET_REVERT);
    }

    function _returnZeros(address target, uint16 size) internal {
        if (realMode) vm.mockCall(target, "", new bytes(size));
        else vm.etch(target, _retZeros(size));
    }

    // ─── G1ADD ───────────────────────────────────────────────────────────────────

    function test_G1Add_Success_ReturnsDecodedPoint() public {
        BLS.G1Point memory a;
        BLS.G1Point memory b;
        if (realMode) {
            a = GenuineBLS.publicKey(7);
            vm.expectCall(G1ADD, abi.encode(a, b));
            assertEq(abi.encode(wrapper.addG1(a, b)), abi.encode(a));
            return;
        }
        BLS.G1Point memory r = wrapper.addG1(a, b);
        // Success mock returns 128 zero bytes → identity-like point.
        assertEq(r.x_a, bytes32(0));
        assertEq(r.x_b, bytes32(0));
        assertEq(r.y_a, bytes32(0));
        assertEq(r.y_b, bytes32(0));
    }

    function test_G1Add_PrecompileRevert_BubblesTypedError() public {
        _revertPrecompile(G1ADD);
        BLS.G1Point memory a;
        BLS.G1Point memory b;
        vm.expectRevert(BLS.G1AddFailed.selector);
        wrapper.addG1(a, b);
    }

    function test_G1Add_WrongReturnSize_Reverts() public {
        // Returns only 64 bytes instead of 128 → returndatasize check fails.
        _returnZeros(G1ADD, 0x40);
        BLS.G1Point memory a;
        BLS.G1Point memory b;
        vm.expectRevert(BLS.G1AddFailed.selector);
        wrapper.addG1(a, b);
    }

    // ─── G2ADD ───────────────────────────────────────────────────────────────────

    function test_G2Add_Success() public {
        BLS.G2Point memory a;
        BLS.G2Point memory b;
        if (realMode) {
            a = GenuineBLS.signature(bytes("addition"), 7);
            vm.expectCall(G2ADD, abi.encode(a, b));
            assertEq(abi.encode(wrapper.addG2(a, b)), abi.encode(a));
            return;
        }
        BLS.G2Point memory r = wrapper.addG2(a, b);
        assertEq(r.x_c0_a, bytes32(0));
        assertEq(r.y_c1_b, bytes32(0));
    }

    function test_G2Add_PrecompileRevert_Reverts() public {
        _revertPrecompile(G2ADD);
        BLS.G2Point memory a;
        BLS.G2Point memory b;
        vm.expectRevert(BLS.G2AddFailed.selector);
        wrapper.addG2(a, b);
    }

    function test_G2Add_WrongReturnSize_Reverts() public {
        _returnZeros(G2ADD, 0x80); // 128 != 256
        BLS.G2Point memory a;
        BLS.G2Point memory b;
        vm.expectRevert(BLS.G2AddFailed.selector);
        wrapper.addG2(a, b);
    }

    // ─── PAIRING ───────────────────────────────────────────────────────────────────

    /// @dev The pairing precompile returns a 32-byte word; nonzero == "pairing holds".
    ///      We mock it returning 1 and assert the library surfaces `true`, and that
    ///      it packs k (g1,g2) tuples of 0x180 bytes each (single-point case here).
    function test_Pairing_Mocked_ReturnsTrue() public {
        // Runtime: store 1 at mem[0], return 32 bytes.
        if (!realMode) vm.etch(PAIRING, RET_TRUE);
        BLS.G1Point[] memory g1 = new BLS.G1Point[](1);
        BLS.G2Point[] memory g2 = new BLS.G2Point[](1);
        if (realMode) vm.expectCall(PAIRING, abi.encode(g1[0], g2[0]));
        assertTrue(wrapper.pairing(g1, g2), "pairing should surface precompile's true result");
    }

    function test_Pairing_Mocked_ReturnsFalse() public {
        // Runtime: return 32 zero bytes → pairing does not hold.
        if (!realMode) _returnZeros(PAIRING, 0x20);
        BLS.G1Point[] memory g1 = new BLS.G1Point[](1);
        BLS.G2Point[] memory g2 = new BLS.G2Point[](1);
        if (realMode) {
            // A single nonidentity pair must fail the product-equals-one check.
            g1[0] = GenuineBLS.publicKey(7);
            g2[0] = GenuineBLS.signature(bytes("pairing"), 3);
            vm.expectCall(PAIRING, abi.encode(g1[0], g2[0]));
        }
        assertFalse(wrapper.pairing(g1, g2), "pairing should surface precompile's false result");
    }

    function test_Pairing_MultiPoint_Packing() public {
        // 3 (g1,g2) pairs — verifies the 0x180-stride packing loop doesn't revert
        // and the precompile is invoked with the full k-tuple length.
        if (!realMode) vm.etch(PAIRING, RET_TRUE);
        BLS.G1Point[] memory g1 = new BLS.G1Point[](3);
        BLS.G2Point[] memory g2 = new BLS.G2Point[](3);
        if (realMode) {
            // Each pair contains one identity, but distinct nonzero coordinates
            // ensure all three tuples and the stride are observed.
            g1[0] = GenuineBLS.publicKey(2);
            g2[1] = GenuineBLS.signature(bytes("packing"), 3);
            g1[2] = GenuineBLS.publicKey(5);
            vm.expectCall(PAIRING, abi.encode(g1[0], g2[0], g1[1], g2[1], g1[2], g2[2]));
        }
        assertTrue(wrapper.pairing(g1, g2));
    }

    function test_Pairing_PrecompileRevert_Reverts() public {
        _revertPrecompile(PAIRING);
        BLS.G1Point[] memory g1 = new BLS.G1Point[](1);
        BLS.G2Point[] memory g2 = new BLS.G2Point[](1);
        vm.expectRevert(BLS.PairingFailed.selector);
        wrapper.pairing(g1, g2);
    }

    // ─── MAP_FP(2)_TO_G(1/2) ───────────────────────────────────────────────────────

    function test_MapFpToG1_Success() public {
        BLS.Fp memory e;
        if (realMode) {
            e.a = bytes32(uint256(1));
            e.b = bytes32(uint256(2));
            (bool ok, bytes memory expected) = MAP_FP_TO_G1.staticcall(abi.encode(e));
            assertTrue(ok);
            vm.expectCall(MAP_FP_TO_G1, abi.encode(e));
            assertEq(abi.encode(wrapper.toG1(e)), expected);
            return;
        }
        BLS.G1Point memory r = wrapper.toG1(e);
        assertEq(r.x_a, bytes32(0));
    }

    function test_MapFpToG1_WrongSize_Reverts() public {
        _returnZeros(MAP_FP_TO_G1, 0x40);
        BLS.Fp memory e;
        vm.expectRevert(BLS.MapFpToG1Failed.selector);
        wrapper.toG1(e);
    }

    function test_MapFp2ToG2_Success() public {
        BLS.Fp2 memory e;
        if (realMode) {
            e = BLS.Fp2(bytes32(uint256(1)), bytes32(uint256(2)), bytes32(uint256(3)), bytes32(uint256(4)));
            (bool ok, bytes memory expected) = MAP_FP2_TO_G2.staticcall(abi.encode(e));
            assertTrue(ok);
            vm.expectCall(MAP_FP2_TO_G2, abi.encode(e));
            assertEq(abi.encode(wrapper.toG2(e)), expected);
            return;
        }
        BLS.G2Point memory r = wrapper.toG2(e);
        assertEq(r.x_c0_a, bytes32(0));
    }

    function test_MapFp2ToG2_PrecompileRevert_Reverts() public {
        _revertPrecompile(MAP_FP2_TO_G2);
        BLS.Fp2 memory e;
        vm.expectRevert(BLS.MapFp2ToG2Failed.selector);
        wrapper.toG2(e);
    }

    // ─── hashToG2 ───────────────────────────────────────────────────────────────────
    // hashToG2 uses sha256 (0x02) + modexp (0x05) — both REAL on cancun — plus
    // MAP_FP2_TO_G2 (0x11, mocked in setUp). This exercises the full XMD:SHA-256
    // expand-message + map dispatch end-to-end against the mocked map precompile.

    function test_HashToG2_DispatchesAndReturnsPoint() public view {
        if (realMode) {
            BLS.G2Point memory point = wrapper.hashToG2(hex"1111111111111111111111111111111111111111111111111111111111111111");
            assertEq(abi.encode(point), hex"0000000000000000000000000000000006ee78bc8f2dec556b1fc39b04afe2126b9817c06dc3a62eebea7015bc5e5f83209b3b632351b8b32442ea4df23425cb00000000000000000000000000000000160a054c6de9a3df5ba20bdb88a06e0af04e27fccf362e3469b11ba80243ad6e78fc020c8fc79cc26c489731f7be19590000000000000000000000000000000001e519a10826c01e6492cf454c3b4fe21103add791f18c950f4202ff9e4be43e8b15185d25e6ae64f23e1c861b5e1a8300000000000000000000000000000000134607d8f6cd2b673a9d3283ec12f593d3bcb787d5d6198f3ad472e680eff430e95c708d1d880ac65fa080e74ef5e36b");
            return;
        }
        BLS.G2Point memory r = wrapper.hashToG2(bytes("AAStar-DVT-message"));
        // With the map precompile mocked to 256 zero bytes, the result is the
        // zero point — what matters is the expand-message + map pipeline ran
        // without reverting (sha256/modexp are real).
        assertEq(r.x_c0_a, bytes32(0));
    }

    function test_HashToG2_DistinctMessages_DoNotRevert() public view {
        if (realMode) {
            assertNotEq(keccak256(abi.encode(wrapper.hashToG2(bytes("msg-a")))),
                keccak256(abi.encode(wrapper.hashToG2(bytes("a-much-longer-message-than-the-first-one-to-vary-len")))));
            return;
        }
        // Different messages must both traverse the full pipeline cleanly.
        wrapper.hashToG2(bytes("msg-a"));
        wrapper.hashToG2(bytes("a-much-longer-message-than-the-first-one-to-vary-len"));
    }

    function test_HashToG2_MapFailure_Reverts() public {
        _revertPrecompile(MAP_FP2_TO_G2);
        vm.expectRevert(BLS.MapFp2ToG2Failed.selector);
        wrapper.hashToG2(bytes("x"));
    }

    // ─── DST cross-check against @noble/curves (RFC-9380 expand_message_xmd) ─────────
    // The cancun host lacks the EIP-2537 map/add precompiles, so we cannot produce a
    // real G2 point. But the DST only feeds the expand_message_xmd -> hash_to_field
    // stage (sha256 0x02 + modexp 0x05, both REAL on cancun). map_fp2_to_g2 and g2add
    // are DST-independent. So we ECHO those two precompiles to surface the contract's
    // computed first hash_to_field element u[0] = (c0, c1) as the returned point's X,
    // and assert it equals @noble/curves v1.2.0 hash_to_field(msg, 2, {DST}) under the
    // BLS-signature PoP-scheme DST "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_".
    //
    // Reference (msg = 0x1111...11, 32 bytes; DST = the POP scheme above):
    //   u[0].c0 = 0x12e25bd78f6e72f2ec5255886b16fcb6092ddd2abd63803d14b3d6bda5aa8700d4c853da0dd342d66c22db44860a357b
    //   u[0].c1 = 0x12311112ab2764d8f3d560c7aa00b2e74c5169b5645e7f737a8c78a0d4244b7035fe3d78fea995b99aaa3d4b8a24e7e1
    function test_HashToG2_DST_MatchesNobleHashToField() public {
        if (realMode) {
            vm.expectCall(MAP_FP2_TO_G2, hex"0000000000000000000000000000000012e25bd78f6e72f2ec5255886b16fcb6092ddd2abd63803d14b3d6bda5aa8700d4c853da0dd342d66c22db44860a357b0000000000000000000000000000000012311112ab2764d8f3d560c7aa00b2e74c5169b5645e7f737a8c78a0d4244b7035fe3d78fea995b99aaa3d4b8a24e7e1");
            assertEq(abi.encode(wrapper.hashToG2(hex"1111111111111111111111111111111111111111111111111111111111111111")), hex"0000000000000000000000000000000006ee78bc8f2dec556b1fc39b04afe2126b9817c06dc3a62eebea7015bc5e5f83209b3b632351b8b32442ea4df23425cb00000000000000000000000000000000160a054c6de9a3df5ba20bdb88a06e0af04e27fccf362e3469b11ba80243ad6e78fc020c8fc79cc26c489731f7be19590000000000000000000000000000000001e519a10826c01e6492cf454c3b4fe21103add791f18c950f4202ff9e4be43e8b15185d25e6ae64f23e1c861b5e1a8300000000000000000000000000000000134607d8f6cd2b673a9d3283ec12f593d3bcb787d5d6198f3ad472e680eff430e95c708d1d880ac65fa080e74ef5e36b");
            return;
        }
        // map_fp2_to_g2: return [input(0x80) || zeros(0x80)] so the mapped point's X = input Fp2.
        vm.etch(MAP_FP2_TO_G2, hex"608060006000376101006000f3");
        // g2add: echo the first input point (0x100 bytes) so result.X stays = u[0].
        vm.etch(G2ADD, hex"61010060006000376101006000f3");

        bytes memory msg32 = new bytes(32);
        for (uint256 i = 0; i < 32; i++) {
            msg32[i] = 0x11;
        }
        BLS.G2Point memory r = wrapper.hashToG2(msg32);

        // r.X = u[0] = (c0, c1), each as a 64-byte big-endian value split high/low.
        assertEq(r.x_c0_a, bytes32(0x0000000000000000000000000000000012e25bd78f6e72f2ec5255886b16fcb6), "u0.c0 high");
        assertEq(r.x_c0_b, bytes32(0x092ddd2abd63803d14b3d6bda5aa8700d4c853da0dd342d66c22db44860a357b), "u0.c0 low");
        assertEq(r.x_c1_a, bytes32(0x0000000000000000000000000000000012311112ab2764d8f3d560c7aa00b2e7), "u0.c1 high");
        assertEq(r.x_c1_b, bytes32(0x4c5169b5645e7f737a8c78a0d4244b7035fe3d78fea995b99aaa3d4b8a24e7e1), "u0.c1 low");
    }
}
