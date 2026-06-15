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
// SuperPaymaster's cancun EVM has NO EIP-2537 precompiles, so BLS.sol can only
// compute step 1 of hash-to-curve (hash_to_field -> two Fp2 elements). It cannot
// run map_to_curve / clear_cofactor. Therefore the cross-repo golden surface that
// SP can verify on-chain is the (u0, u1) hash_to_field output — that is what this
// script freezes and what contracts/test/modules/BLSGoldenVectors.t.sol asserts.
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
  return {
    label,
    msgHex: "0x" + Buffer.from(msg).toString("hex"),
    msgLen: msg.length,
    u0: { c0: u0c0, c1: u0c1 },
    u1: { c0: u1c0, c1: u1c1 },
  };
});

console.log("// DST =", JSON.stringify(DST), "len", DST.length, "(0x" + DST.length.toString(16) + ")");
console.log("// @noble/curves v1.2.0  hash_to_field count=2\n");
console.log(JSON.stringify(vectors, null, 2));
