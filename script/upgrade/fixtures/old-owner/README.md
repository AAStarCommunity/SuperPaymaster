# Deployed source input fragment

Copy both top-level fields of `deployed-sources.json` into `externalInputs.data`.
`deployedSources` contains 10 adopted executing targets: the eight previously
accepted targets and the aPNTs/PNTs clones, keyed by target address. Both clones
share the parity-verified factory nonce-1 implementation.

`pendingDsrRuling` retains the Registry proxy candidate and its creation boundary,
with the reason for the 2026-11-04 DSR re-ruling request. It is not adopted:
`bytecode_hash=none` leaves only the solc version in CBOR, so metadata-included
equality does not pin the source tree. Collection and replay STOP at
`deployed_source_pending` while this object is nonempty, even if a pending entry
is also copied into `deployedSources`. Omitting the pending field does not supply
the missing required Registry source.

Additional discovered clones need their own source entries and creation
boundaries. The collector still verifies pinned code, proxy/clone bindings,
before/at creation code and live storage authority; offline source acceptance is
not a full isolation certificate.

See `../../DEPLOYED_SOURCE_PARITY_RESULTS.md` for comparison evidence and the
Registry re-ruling status.
