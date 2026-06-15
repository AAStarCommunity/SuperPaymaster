# BLS Golden Vectors — `hash_to_field` cross-repo contract

**Status:** frozen (v5.4 DVT step ②)
**Owner surface:** SuperPaymaster `contracts/src/utils/BLS.sol`
**Test:** `contracts/test/modules/BLSGoldenVectors.t.sol`
**Generator:** `scripts/bls-golden-vectors.mjs`

## 1. Domain Separation Tag (frozen)

```
BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_
```

- **Length:** 43 bytes → `0x2b` (the value appended as `I2OSP(len,1)` in `DST_prime`).
- **Scheme:** BLS-signature **Proof-of-Possession** (`_POP_`), per draft-irtf-cfrg-bls-signature / RFC 9380.
- **History:** SuperPaymaster's `BLS.sol` previously (incorrectly) used the bare
  hash-to-curve `..._SSWU_RO_NUL_` tag (35 bytes). v5.4 step ① changed it to the
  `_POP_` tag (43 bytes) so SP agrees with the BLS-signature PoP scheme already
  used by the DVT nodes. These golden vectors lock that in.

The exact same DST string is used by:

| Repo | Location | Usage |
|---|---|---|
| SuperPaymaster | `contracts/src/utils/BLS.sol` (`dstPrime`) | on-chain `hash_to_field` |
| YetAnotherAA-Validator | `src/utils/bls.util.ts` (`BLS_DST`) | `bls.G2.hashToCurve(msg, { DST })` |
| airaccount-contract / AirAccount | (DVT co-signer integration) | same DST for `hash_to_curve(userOpHash, DST)` |

## 2. Why the golden surface is `hash_to_field`, not the full G2 point

SuperPaymaster runs on a **cancun** EVM, which does **not** ship the EIP-2537
BLS12-381 precompiles (`0x0b..0x11`). Consequently `BLS.sol` can only compute
**step 1 of hash-to-curve**:

```
hash_to_field(msg, DST, count=2) -> (u0, u1)
```

two `Fp2` elements = 4 `Fp` coordinates. It cannot run `map_to_curve` or
`clear_cofactor` (those need the precompiles), so it cannot produce the full
256-byte G2 point on-chain. Therefore the byte-exact value SuperPaymaster can
verify on-chain — and the value the 4 program repos share as their CI contract —
is exactly **`(u0, u1)`**.

Each `Fp` coordinate is a 48-byte big-endian value. In the `BLS.Fp` struct it is
split into `a` (upper 32 bytes; the top 16 bytes are always zero) and `b` (lower
32 bytes).

## 3. The vector set

5 messages (canonical + 4 edge cases). Full `(u0, u1)` values are hard-coded in
`BLSGoldenVectors.t.sol`; regenerate with the script below for the canonical hex.

| Label | Message | Length |
|---|---|---|
| `canonical_0x11x32` | `0x11` repeated | 32 bytes |
| `empty` | (empty) | 0 bytes |
| `one_byte_a` | `0x61` (`'a'`) | 1 byte |
| `ninetysix_0xab` | `0xab` repeated | 96 bytes |
| `userophash_like` | `0xdeadbeef` repeated | 32 bytes |

The `canonical_0x11x32` `u0` matches the pre-existing on-chain-verified value in
`contracts/test/modules/BLSLibrary.t.sol::test_HashToG2_DST_MatchesNobleHashToField`.

## 4. How `(u0, u1)` are surfaced on-chain in the test

`BLS.sol` computes `u0, u1` using only `sha256` (`0x02`) and `modexp` (`0x05`),
both **real** on cancun. It then calls `map_fp2_to_g2` (`0x11`) twice and `g2add`
(`0x0d`) once — all **DST-independent** and absent on cancun. The test `vm.etch`es
those two precompiles with tiny echo stubs so the result's X coordinate equals the
field element under test:

- `map_fp2_to_g2` → echo its `0x80`-byte `Fp2` input as the mapped point's X
  (`Y = 0`), so `mapped(u0).X == u0` and `mapped(u1).X == u1`.
- `g2add` → echo input **point0** (calldata offset 0) ⇒ `result.X == u0`; or echo
  input **point1** (offset `0x100`) ⇒ `result.X == u1`.

This is a read-only harness — it does **not** modify `BLS.sol`. Any CI in the
program repos that can run the real `hash_to_field` (e.g. a Prague/Pectra fork,
or the TS noble reference) must produce the identical `(u0, u1)` bytes.

## 5. Regeneration (deterministic, offline)

Reference implementation: **`@noble/curves` v1.2.0** (`bls12_381` / `hash_to_field`),
the same library `YetAnotherAA-Validator` uses. The version is vendored in the repo
`node_modules`, so generation is reproducible without network access.

```bash
# from repo root (uses pnpm-managed node_modules)
node scripts/bls-golden-vectors.mjs
```

Output is JSON with, per vector, `msgHex`, `u0`/`u1` each as `{c0, c1}`, and each
`Fp` coordinate as `{ full (48B), a (high bytes32), b (low bytes32) }` — paste the
`a`/`b` values directly into the test's `Vec{...}` literals.

To verify equality against the noble reference for the canonical message:

```bash
node -e "
const { bls12_381 } = require('@noble/curves/bls12-381');
const { hash_to_field } = require('@noble/curves/abstract/hash-to-curve');
const { sha256 } = require('@noble/hashes/sha256');
const Fp = bls12_381.fields.Fp;
const DST = 'BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_POP_';
const u = hash_to_field(Uint8Array.from(Array(32).fill(0x11)), 2,
  { p: Fp.ORDER, m: 2, k: 128, expand: 'xmd', hash: sha256, DST });
console.log(u[0][0].toString(16), u[0][1].toString(16));
"
```

## 6. Cross-repo CI intent

These vectors are the **shared contract** for the DVT program. SuperPaymaster is
the reference producer (no published hub canonical existed at freeze time —
YetAnotherAA-Validator issue #42). Each repo verifies the same `hash_to_field`
output so that a BLS signature produced by a DVT node (`hash_to_curve(msg, DST)`)
and verified on-chain (pairing against the same `msgG2`) agree on the **same
domain separation and the same field elements**. A divergence in any repo's DST
or `hash_to_field` would silently break aggregate-signature verification; these
vectors make such a divergence a hard CI failure.
