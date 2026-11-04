# Deployed source input fragment

Copy `deployedSources` from `deployed-sources.json` into `externalInputs.data`.
It contains 11 adopted executing targets, including the Registry proxy and both
named aPNTs/PNTs clones. Both clones share the parity-verified factory nonce-1
implementation.

Registry is adopted under DSR option (a), 2026-11-04, with
`claim="behavioral-equivalence"`: on-chain runtime is behaviorally equivalent to
the a839347e build (immutable-masked byte-for-byte equality, solc 0.8.33).
APNTsCapped uses `claim="deployment-record + runtime parity"` with a committed
A3a plan and successful S3 receipt reference. All remaining targets use
`behavioral-equivalence`: the supplied broadcast files are not committed in this
repository. Their hashes and SP hash-swap discrepancy are retained in
`broadcast-provenance.json` as corroboration, not a validated source-identity claim.

Additional discovered clones need their own source entries and creation
boundaries. The collector verifies pinned runtime, every decoded immutable
against OLD and independently supplied expected configuration (missing address
expectation STOPs), both ERC1967Proxy runtimes built at cf26915e with metadata
unmasked, proxy/clone bindings, before/at
creation code, and live storage authority. A reverting AST-extracted getter
STOPs. Offline source acceptance is not a full isolation certificate.

See `../../DEPLOYED_SOURCE_PARITY_RESULTS.md` for the immutable table, creation
corroboration and comparison evidence.

Deployment-record claims require `deploymentRecord` with `path`, `sha256`,
`commit`, `txHash`, and receipt `contractAddress` (the implementation address).
The validator reads the file from Git HEAD, verifies its SHA-256, resolves its
recorded commit and checks a successful receipt with the same transaction hash
and address. A3a plans additionally reference a committed receipt via
`receipt: {path, sha256}` and must name that same capped-token address.
Invalid or absent records STOP; only an explicit behavioral-equivalence claim
can proceed without source-identity proof. Registry remains behavioral-equivalence.

RoleConfigured and RoleGranted/RoleRevoked use the same bounded/bisected reader,
1000-row limit and disjoint partition equality check. Both endpoint transcripts
are replayed through these gates. Consistent omission by every query on both
providers remains outside what partition checks can establish.
