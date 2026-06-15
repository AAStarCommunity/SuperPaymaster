// SPDX-License-Identifier: Apache-2.0
//
// BLS golden-vector generator — SuperPaymaster v5.4 DVT step (2)
//
// Produces the CANONICAL hash_to_field(msg, DST, count=2) -> (u0, u1) reference
// set for the BLS-signature Proof-of-Possession Domain Separation Tag:
//
//   DST = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_"   (43 bytes, len 0x2b)
//
// This is the EXACT DST used by:
//   - SuperPaymaster contracts/src/utils/BLS.sol  (on-chain hash_to_field, step 1)
//   - YetAnotherAA-Validator src/utils/bls.util.ts (BLS_DST, bls.G2.hashToCurve)
//
// TWO golden layers (Blocker-2 resolution, #283 / #42):
//   1. (u0, u1) = hash_to_field(msg, DST, 2)  — step 1. SuperPaymaster's cancun EVM
//      has NO EIP-2537 precompiles, so BLS.sol can only compute this. SP CI asserts
//      it (contracts/test/modules/BLSGoldenVectors.t.sol).
//   2. g2Affine = full G2 point (x, y) after map_to_curve + clear_cofactor — step 2.
//      SP cannot compute this on-chain, but YetAnotherAA-Validator uses noble v2,
//      which does NOT expose hash_to_field and can only produce this full point.
//      So the validator CI asserts g2Affine.
//   Both layers come from the SAME noble v1.2.0 reference and the SAME DST, so they
//   are equivalent evidence (g2Affine == step2(u0,u1)) and cross-version-consistent
//   with the validator's noble v2 (RFC-9380 is a fixed standard). Neither side has to
//   reimplement the other's layer: SP keeps (u0,u1), the validator keeps g2Affine.
//
// Reference impl: @noble/curves v1.2.0 (bls12_381 / hash_to_field).
//   The same noble version is vendored in the repo node_modules, so this is
//   reproducible offline. Run:  node scripts/bls-golden-vectors.mjs
//
// Output: JSON of {label, msgHex, u0:{c0,c1}, u1:{c0,c1}} plus Solidity-ready
// (a,b) 32-byte splits for each 48-byte Fp coordinate.

import { bls12_381 } from "@noble/curves/bls12-381";
import { hash_to_field } from "@noble/curves/abstract/hash-to-curve";
import { sha256 } from "@noble/hashes/sha256";

const DST = "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_";
if (DST.length !== 43) throw new Error(`DST must be 43 bytes, got ${DST.length}`);

const Fp = bls12_381.fields.Fp;
const htfOpts = { p: Fp.ORDER, m: 2, k: 128, expand: "xmd", hash: sha256, DST };

function hexToBytes(hex) {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
  return out;
}

// 48-byte BLS12-381 Fp element -> {full128, a (high bytes32), b (low bytes32)}
// matching BLS.Fp struct (a = upper 32 bytes incl. 16 leading zero bytes,
// b = lower 32 bytes).
function fpSplit(big) {
  const hex96 = big.toString(16).padStart(96, "0"); // 48 bytes
  const hex128 = hex96.padStart(128, "0"); // left-pad to 64 bytes
  return { full: "0x" + hex96, a: "0x" + hex128.slice(0, 64), b: "0x" + hex128.slice(64) };
}

// label, message bytes
const MESSAGES = [
  ["canonical_0x11x32", hexToBytes("11".repeat(32))], // 32-byte canonical message
  ["empty", new Uint8Array(0)], // empty message edge case
  ["one_byte_a", hexToBytes("61")], // single byte 'a'
  ["ninetysix_0xab", hexToBytes("ab".repeat(96))], // 96-byte message
  ["userophash_like", hexToBytes("deadbeef".repeat(8))], // 32-byte userOpHash-style
];

const vectors = MESSAGES.map(([label, msg]) => {
  const u = hash_to_field(msg, 2, htfOpts); // count=2 -> [u0=[c0,c1], u1=[c0,c1]]
  const u0c0 = fpSplit(u[0][0]);
  const u0c1 = fpSplit(u[0][1]);
  const u1c0 = fpSplit(u[1][0]);
  const u1c1 = fpSplit(u[1][1]);

  // FULL G2 point — step 2 (map_to_curve + clear_cofactor) applied to (u0,u1).
  // SuperPaymaster CANNOT compute this on-chain (cancun lacks EIP-2537), but the
  // YetAnotherAA-Validator side (noble v2, which does NOT expose hash_to_field)
  // CAN only produce this full point. So we emit BOTH layers from the same noble
  // v1.2.0 reference: SP CI asserts (u0,u1); the validator CI asserts the affine
  // G2 (x,y). Same DST + same RFC-9380 standard => the two layers are equivalent
  // evidence and cross-version-consistent (v1.2.0 here vs v2 there).
  const aff = bls12_381.G2.hashToCurve(msg, { DST }).toAffine();
  const g2 = {
    x: { c0: fpSplit(aff.x.c0), c1: fpSplit(aff.x.c1) },
    y: { c0: fpSplit(aff.y.c0), c1: fpSplit(aff.y.c1) },
  };

  return {
    label,
    msgHex: "0x" + Buffer.from(msg).toString("hex"),
    msgLen: msg.length,
    u0: { c0: u0c0, c1: u0c1 },
    u1: { c0: u1c0, c1: u1c1 },
    g2Affine: g2,
  };
});

console.log("// DST =", JSON.stringify(DST), "len", DST.length, "(0x" + DST.length.toString(16) + ")");
console.log("// @noble/curves v1.2.0  hash_to_field count=2\n");
console.log(JSON.stringify(vectors, null, 2));
