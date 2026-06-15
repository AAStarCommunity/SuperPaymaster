// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {BLS} from "src/utils/BLS.sol";

/**
 * @title BLSGoldenVectors_Test
 * @notice v5.4 DVT step (2): byte-exact golden-vector lock for the on-chain
 *         `hash_to_field` stage of `contracts/src/utils/BLS.sol`.
 *
 *  ── DST (frozen, cross-repo contract) ──────────────────────────────────────
 *    "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_"   43 bytes, length 0x2b
 *    BLS-signature Proof-of-Possession scheme. Byte-identical to:
 *      - SuperPaymaster      contracts/src/utils/BLS.sol  (dstPrime)
 *      - YetAnotherAA-Validator src/utils/bls.util.ts     (BLS_DST)
 *    (was previously "BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_" — corrected to _POP_.)
 *
 *  ── Why hash_to_field only ─────────────────────────────────────────────────
 *    The SuperPaymaster host EVM is `cancun`, which does NOT ship the EIP-2537
 *    precompiles (0x0b..0x11). So BLS.sol can only compute step 1 of
 *    hash-to-curve: hash_to_field(msg, DST, count=2) -> (u0, u1), two Fp2
 *    elements = 4 Fp coordinates. It cannot run map_to_curve / clear_cofactor,
 *    so it cannot produce the full 256-byte G2 point on-chain. Therefore the
 *    cross-repo golden surface SuperPaymaster verifies is exactly (u0, u1).
 *
 *  ── Reference / regeneration ───────────────────────────────────────────────
 *    Golden values produced by noble/curves (npm @ noble curves) v1.2.0
 *    hash_to_field, the same
 *    bls12_381 reference that YetAnotherAA-Validator's bls.G2.hashToCurve uses.
 *    Reproduce offline (deterministic, no network):
 *        node scripts/bls-golden-vectors.mjs
 *    The canonical vector (msg = 0x11*32) u0 matches the pre-existing
 *    on-chain-verified value in BLSLibrary.t.sol.
 *
 *  ── How u0 / u1 are surfaced on-chain ──────────────────────────────────────
 *    BLS.sol computes u0, u1 in field arithmetic (sha256 0x02 + modexp 0x05,
 *    both REAL on cancun), then calls map_fp2_to_g2 (0x11) twice and g2add
 *    (0x0d) once — all DST-independent and absent on cancun. We `vm.etch` those
 *    two precompiles so the pipeline runs and the result's X coordinate echoes
 *    the field element we want:
 *      - map_fp2_to_g2 -> echo its 0x80-byte Fp2 input as the mapped point's X
 *        (Y = 0), so mapped(u0).X == u0 and mapped(u1).X == u1.
 *      - g2add -> echo input point0 (offset 0) => result.X == u0, OR
 *                 echo input point1 (offset 0x100) => result.X == u1.
 *    This is purely a test harness to read internal field output; it does NOT
 *    alter BLS.sol. CI in the 4 program repos asserts the same (u0,u1) bytes.
 */
contract BLSGoldenVectorsWrapper {
    function hashToG2(bytes memory m) external view returns (BLS.G2Point memory) {
        return BLS.hashToG2(m);
    }
}

contract BLSGoldenVectors_Test is Test {
    BLSGoldenVectorsWrapper internal wrapper;

    address constant G2ADD = address(0x0d);
    address constant MAP_FP2_TO_G2 = address(0x11);

    // map_fp2_to_g2 echo: copy 0x80-byte Fp2 input to mem[0], return 0x100 bytes
    // (X = input, Y = 0).  PUSH1 0x80 PUSH1 0 PUSH1 0 CALLDATACOPY PUSH2 0x100 PUSH1 0 RETURN.
    bytes constant MAP_ECHO = hex"608060006000376101006000f3";
    // g2add echo point0: copy 0x100 from calldata offset 0, return 0x100 (=> result.X = u0).
    bytes constant G2ADD_ECHO_P0 = hex"61010060006000376101006000f3";
    // g2add echo point1: copy 0x100 from calldata offset 0x100, return 0x100 (=> result.X = u1).
    bytes constant G2ADD_ECHO_P1 = hex"6101006101006000376101006000f3";

    struct Vec {
        string label;
        bytes message;
        // u0 = first Fp2 element (c0, c1); each Fp split into a (high 32B) / b (low 32B).
        bytes32 u0c0a;
        bytes32 u0c0b;
        bytes32 u0c1a;
        bytes32 u0c1b;
        // u1 = second Fp2 element.
        bytes32 u1c0a;
        bytes32 u1c0b;
        bytes32 u1c1a;
        bytes32 u1c1b;
    }

    function setUp() public {
        wrapper = new BLSGoldenVectorsWrapper();
    }

    /// @dev Run hash_to_field on-chain and surface u0 (result.X with g2add echoing point0).
    function _u0(bytes memory m) internal returns (BLS.G2Point memory) {
        vm.etch(MAP_FP2_TO_G2, MAP_ECHO);
        vm.etch(G2ADD, G2ADD_ECHO_P0);
        return wrapper.hashToG2(m);
    }

    /// @dev Run hash_to_field on-chain and surface u1 (result.X with g2add echoing point1).
    function _u1(bytes memory m) internal returns (BLS.G2Point memory) {
        vm.etch(MAP_FP2_TO_G2, MAP_ECHO);
        vm.etch(G2ADD, G2ADD_ECHO_P1);
        return wrapper.hashToG2(m);
    }

    function _assertVec(Vec memory v) internal {
        BLS.G2Point memory r0 = _u0(v.message);
        assertEq(r0.x_c0_a, v.u0c0a, string.concat(v.label, ": u0.c0 high"));
        assertEq(r0.x_c0_b, v.u0c0b, string.concat(v.label, ": u0.c0 low"));
        assertEq(r0.x_c1_a, v.u0c1a, string.concat(v.label, ": u0.c1 high"));
        assertEq(r0.x_c1_b, v.u0c1b, string.concat(v.label, ": u0.c1 low"));

        BLS.G2Point memory r1 = _u1(v.message);
        assertEq(r1.x_c0_a, v.u1c0a, string.concat(v.label, ": u1.c0 high"));
        assertEq(r1.x_c0_b, v.u1c0b, string.concat(v.label, ": u1.c0 low"));
        assertEq(r1.x_c1_a, v.u1c1a, string.concat(v.label, ": u1.c1 high"));
        assertEq(r1.x_c1_b, v.u1c1b, string.concat(v.label, ": u1.c1 low"));
    }

    // ── Vector 1: canonical msg = 0x11 * 32 (32 bytes) ──────────────────────────
    function test_Golden_Canonical_0x11x32() public {
        bytes memory m = new bytes(32);
        for (uint256 i = 0; i < 32; i++) m[i] = 0x11;
        _assertVec(
            Vec({
                label: "canonical_0x11x32",
                message: m,
                u0c0a: 0x0000000000000000000000000000000012e25bd78f6e72f2ec5255886b16fcb6,
                u0c0b: 0x092ddd2abd63803d14b3d6bda5aa8700d4c853da0dd342d66c22db44860a357b,
                u0c1a: 0x0000000000000000000000000000000012311112ab2764d8f3d560c7aa00b2e7,
                u0c1b: 0x4c5169b5645e7f737a8c78a0d4244b7035fe3d78fea995b99aaa3d4b8a24e7e1,
                u1c0a: 0x0000000000000000000000000000000018cb15f0b29c9e8fc82f2c02b0944de9,
                u1c0b: 0xca00e55395db980e90617f034ee1f0c5767b81c7f8f3bb417e1b664959f497cd,
                u1c1a: 0x000000000000000000000000000000000f3b654969e998e3bd1d56c3ca5adaec,
                u1c1b: 0x6e6d3f5933652f29e115614adf3b6349daa43cb5d0e91d25a2e155b91d5491ff
            })
        );
    }

    // ── Vector 2: empty message (0 bytes) ───────────────────────────────────────
    function test_Golden_Empty() public {
        _assertVec(
            Vec({
                label: "empty",
                message: "",
                u0c0a: 0x00000000000000000000000000000000003051213109bd3c0a95ffa570521504,
                u0c0b: 0x7851ce352016f2c3da53ecb70e8aafefa9891d4f6c362732c767b0efa52c8a54,
                u0c1a: 0x000000000000000000000000000000000c5c6c7c1496c6de9c50065dd8323a2a,
                u0c1b: 0x9a7f17a1506fb3f5b15b49f4155775f47c5f6fa01b64cffddb17ccc9d7cc5de1,
                u1c0a: 0x00000000000000000000000000000000098bc5a5c85b0e923446e56f4dc1ee3c,
                u1c0b: 0x346fa7099054bdfa6e0c578f20d629fe8759a065678b83dca77de02c48a4e3ec,
                u1c1a: 0x0000000000000000000000000000000003b899e75c2c1a5b76ff772172f6e256,
                u1c1b: 0x61df5e919d286683f30dc6c2eb6650168a8842105de910dd919153f35f1daf9a
            })
        );
    }

    // ── Vector 3: single byte 'a' (0x61) ────────────────────────────────────────
    function test_Golden_OneByte() public {
        _assertVec(
            Vec({
                label: "one_byte_a",
                message: hex"61",
                u0c0a: 0x00000000000000000000000000000000069e35a606fd5b6ab78032b40cf97ac6,
                u0c0b: 0x8b346fdb86eb42134f9b5054f3e00548518cffb3998160ebee1f2562732ff449,
                u0c1a: 0x000000000000000000000000000000000de9514ea5d617ffb7908ff6e92cbd54,
                u0c1b: 0x4946e43a554d569a0c6fa1dc16b5767933249f89bf0a1de72f7a7c3c7e214112,
                u1c0a: 0x00000000000000000000000000000000117b61bea357237f969c06799ed38e25,
                u1c0b: 0xcde0c8140c81ed5c908e5e6d65891b4f44a590b33416e76487bea869bfbf9e6f,
                u1c1a: 0x000000000000000000000000000000001755f1694d58fa28b71e5d5d534e5dd8,
                u1c1b: 0x41a5a4c56775c14765aee363f6098ac90d9b900c4339db5a6912c1ff90ba82fc
            })
        );
    }

    // ── Vector 4: 96-byte message = 0xab * 96 ───────────────────────────────────
    function test_Golden_NinetySix() public {
        bytes memory m = new bytes(96);
        for (uint256 i = 0; i < 96; i++) m[i] = 0xab;
        _assertVec(
            Vec({
                label: "ninetysix_0xab",
                message: m,
                u0c0a: 0x0000000000000000000000000000000003572117dbead03e23b31045168010a6,
                u0c0b: 0x683f7043cf6a8946bdcb18b52d30cf83942e9c7a00bdafd9689304e25265fc82,
                u0c1a: 0x0000000000000000000000000000000017818e3eedaa30e739617e7d17fa57c8,
                u0c1b: 0x2fd8be53536dfcbb6068f8be48e0be00a1cae0f239d3994daeb508b622a6ba77,
                u1c0a: 0x000000000000000000000000000000001976496ac05e431e2552e76906d0de33,
                u1c0b: 0xcc5425a510fc85f20224d10b63e1622f818be743a5d7c2e04bb243369cdb8b6a,
                u1c1a: 0x0000000000000000000000000000000004175a4ec245f45edf5725bd37e18216,
                u1c1b: 0xd0e4a39c0e3a456986d5caf6c3fcd4b5c98c14e3e209679eeb6c30f57b33575a
            })
        );
    }

    // ── Vector 5: 32-byte userOpHash-like = 0xdeadbeef * 8 ───────────────────────
    function test_Golden_UserOpHashLike() public {
        _assertVec(
            Vec({
                label: "userophash_like",
                message: hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
                u0c0a: 0x0000000000000000000000000000000012c3ee56935350cea84c79c02e1df53d,
                u0c0b: 0x1d8b8b636cebec35fca9b1558efe6317fb7a49dfe9335911c655c6c4ad035b14,
                u0c1a: 0x00000000000000000000000000000000137a692b4382584f5bc17e5552753ff9,
                u0c1b: 0xaaaaa540eb7876b4d12ce32547eb838ee25575cf27830d26029c4e2b91e51cf0,
                u1c0a: 0x0000000000000000000000000000000004e1e1b268b8e5b2e112980c65f92480,
                u1c0b: 0x62e0f7ab848599686ee92be4fdf3a3efc7e03c769f0256ad1955c03a6a20cf64,
                u1c1a: 0x00000000000000000000000000000000086302e0e0c5f0400b18182259da8497,
                u1c1b: 0x1b774c3b35a9a43ab4126dc978599d1bf3e43aa57d91e71d291ead1e15516a11
            })
        );
    }

    /// @dev Sanity: the DST is the _POP_ scheme (43 bytes). A different msg must
    ///      yield a different u0 (guards against a degenerate all-zero echo).
    function test_Golden_DistinctMessagesDiffer() public {
        BLS.G2Point memory a = _u0(hex"00");
        BLS.G2Point memory b = _u0(hex"01");
        assertTrue(a.x_c0_b != b.x_c0_b, "distinct messages must hash to distinct fields");
    }
}
