# F5 — BLSAggregator signerMask not validated against registered validators

**Status:** deferred to separate PR
**Severity:** high (allows forged BLS proofs from unregistered keys to pass
consensus if the signerMask is crafted to reference non-existent validator
indices)

## Issue

`BLSAggregator._checkSignatures` counts the bits set in `signerMask` and
compares against `requiredThreshold`, but never verifies that each set bit
corresponds to a validator whose BLS public key is actually registered in
`blsPublicKeys`. A malicious aggregator that holds a single valid signature
(or none, in certain configurations) can pad `signerMask` with arbitrary bits
to cross the threshold check, then submit a pairing proof that only covers the
subset of keys it actually has.

The aggregate public-key pairing check catches most forgeries today because
unregistered indices contribute no G1 point to the aggregate. However, this
relies on implementation details of how the aggregate is reconstructed and
leaves room for bypasses if the reconstruction logic ever treats missing keys
leniently. The fix is to make the validator-set membership explicit in the
threshold count.

## Proposed fix

Iterate `signerMask` bit-by-bit; for each set bit, require the validator slot
to map to an active `BLSPublicKey`. Sum only those and compare against
`requiredThreshold`. Reject the proof if any set bit points to an unregistered
slot.

This requires an on-chain list/array of validator addresses indexed the same
way the off-chain aggregator constructs the mask. Options:

1. Maintain `address[] validatorList` alongside `mapping blsPublicKeys`, with
   explicit add/remove operations so the index space is stable.
2. Use the existing `MAX_VALIDATORS = 13` bound to keep the loop cheap
   (13 iterations worst case).

## Dependency

Clean implementation benefits from EIP-2537 (BLS12-381 precompile) landing on
Pectra so we can verify the aggregate G1 point without the manual precompile
shim currently in `BLS.sol`.

## Action

Track as its own PR once the validator-list data model is agreed. Do not
merge into the current ticket-model PR.
