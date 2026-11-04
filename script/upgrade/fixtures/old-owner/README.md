# Deployed source input fragment

Copy `deployedSources` from `deployed-sources.json` into `externalInputs.data`.
It contains 11 adopted executing targets, including the Registry proxy and both
named aPNTs/PNTs clones. Both clones share the parity-verified factory nonce-1
implementation.

Registry is adopted under DSR option (a), 2026-11-04, with
`claim="behavioral-equivalence"`: on-chain runtime is behaviorally equivalent to
the a839347e build (immutable-masked byte-for-byte equality, solc 0.8.33).
All other contracts use `claim="deployment-record + runtime parity"`.

Additional discovered clones need their own source entries and creation
boundaries. The collector verifies pinned runtime, every decoded immutable
against OLD and known expected configuration, proxy/clone bindings, before/at
creation code, and live storage authority. A reverting AST-extracted getter
STOPs. Offline source acceptance is not a full isolation certificate.

See `../../DEPLOYED_SOURCE_PARITY_RESULTS.md` for the immutable table, creation
corroboration and comparison evidence.
