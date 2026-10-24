# A3a executor — R-AMS-3 / CC-125

`a3a_exec.py` builds unsigned Sepolia transactions and rehearses them on the
Amsterdam engine. It contains no signer and cannot broadcast to the archive RPC.
The quarantined prototype and sealed v1–v4 packets remain unchanged. Their gas
numbers are never used; see [the invalidation note](../../docs/release/a3a-packets-RAMS-INVALIDATION.md).
This implementation still requires review and a live archive-backed rehearsal;
passing offline tests is not an execution authorization.

## Use

Python 3, standard library only. Offline ABI encoding and Ethereum Keccak use
`cast` from `/Users/jason/Dev/aastar/tools/foundry-rams/nightly-926eb1d/`.
Forks use that directory's `anvil`, explicitly with `--hardfork amsterdam
--order fifo`. The full engine commit must be
`926eb1d087523f1de437e3c0c49ea6d26407e827`. Anvil 1.7.1 is not accepted.

Prepare the local default build artifacts before running. The executor reads
`out/APNTsCapped.sol/APNTsCapped.default.json` and
`out/TimelockController.sol/TimelockController.default.json`, falling back to
`<Contract>.json` only when `.default.json` is absent. Metadata must specify
Cancun and 500 optimizer runs. APNTsCapped must have exactly the seven named
EIP712 immutables described below. Both contract runtimes are checked; any
timelock immutables must also have computable exact values. Full compiler
build-info under `out/build-info/*.json` must include `output.sources[*].ast`
(including the inherited OZ sources) and `output.contracts` containing the
matching APNTsCapped deployed bytecode and immutable references. Generate full
build-info with the nightly forge's `--build-info --ast` options when preparing
artifacts. Source-index-only build-info is insufficient and fails the
`immutable_build_info` gate. AST IDs belong to a compilation unit: outputs from
other builds are never combined to guess names. The executor does invoke the
pinned local compiler toolchain for a fresh **offline HEAD archive rebuild**;
it never downloads dependencies or uses out/ as its own source of trust.

Ignored build output is covered separately from git status. For **both** artifacts,
every metadata `sources[*].keccak256` must equal Keccak of the source bytes
committed at HEAD, and the current file bytes must have that same hash. Source
names resolve through metadata remappings to files inside this repository.
Pinned gitlinks are followed using the commit recorded by the parent HEAD, never
the submodule's current HEAD. Missing/uncommitted files, ambiguous or escaping
remappings, and any metadata/worktree hash mismatch fail. The local nightly
cast Keccak implementation is checked against the known empty-input vector.
The resolved paths and committed hashes are saved as `artifactSources`.

## Bytecode binding to HEAD

Before building a plan, the executor materializes `git archive HEAD` in a fresh
temporary directory. Every gitlink is recursively archived at its **recorded
commit** using the initialized local submodule or locally retained module object
store. Working-tree dependency files are not copied. Missing local commits,
unsafe archive entries or unavailable submodules fail clear rebuild gates; there
is no fetch, clone, submodule download or network fallback.

The archive is built by `~/.foundry/bin/forge`, which must report exactly version
1.7.1, using `build --offline` and `FOUNDRY_PROFILE=default`. Only basic compiler
environment variables are inherited; wallet/RPC credentials and build-setting
overrides are not passed. The committed profile, compiler and all dependency
objects must be available offline. A build failure is `rebuild_offline_build`.
Temporary trees and outputs are removed after compilation or failure.

For APNTsCapped and TimelockController, creation bytecode, deployed bytecode and
immutableReferences are compared exactly against the freshly rebuilt artifacts.
Every mismatch fails. The plan's `rebuild` record includes forge version,
`tempTreeCommit`, profile, bytecode digests, immutable-reference digest and CBOR
metadata result. Canonical validation rebuilds this record independently, so a
frozen simulation or future signer cannot substitute self-attesting artifacts.
Within one invocation only the trusted rebuilt outputs are cached; current out/
files are re-compared on every canonical validation.

The CBOR trailer has two explicitly checked branches:

- **No-hash profile:** `[profile.default].bytecode_hash` must explicitly be
  `"none"` in foundry.toml read from **HEAD**, not the working tree. Each runtime
  trailer must decode to exactly `{solc: <0.8.33 bytes>}`. This exception is
  accepted only after exact fresh-rebuild equality for all required bytecode and
  reference fields. It does not claim that a missing metadata hash proves identity.
- **Hash enabled:** the embedded metadata hash must match the exact rawMetadata
  bytes. IPFS mode checks Solidity's SHA-256 UnixFS multihash (including its file
  envelope), not a plain SHA-256 of the JSON. The implementation supports one
  metadata chunk up to 262144 bytes; unsupported schemes, oversized metadata,
  missing hashes and incorrect hashes fail closed. The compiler marker must
  still be 0.8.33. Tests cover both branches and a fixture produced by local solc.

Put just the archive URL in a private file. Pass its **path**, never the URL:

```sh
python3 script/a3a/a3a_exec.py plan \
  --rpc-file /private/tmp/archive-rpc.txt --block 11969744 \
  --out /private/tmp/a3a-plan
python3 script/a3a/a3a_exec.py simulate \
  --rpc-file /private/tmp/archive-rpc.txt \
  --plan /private/tmp/a3a-plan/plan.json --out /private/tmp/a3a-sim
```

Choose a current pinned block for an actual review; the number above illustrates
syntax. Decimal and `0x` block numbers are accepted. `--out` must not exist or
must be an empty directory. Nonempty output is refused before RPC access and
existing evidence is preserved; the failure record is printed to stderr because
the requested directory cannot be reused. Use a new directory per attempt. RPC credentials stay in memory: anvil receives a loopback relay URL,
and the relay permits only read RPCs. Engine stdout is discarded; `engine.stderr`
is captured and must be **empty at the end**, or the run fails. The engine sees
only the loopback relay URL, never the archive URL.
No key, mnemonic or wallet is loaded. The relay handles batches request by request;
`eth_blockNumber`, `net_version`, and `web3_clientVersion` have pinned local
answers. Writes including `eth_sendRawTransaction`, `eth_sendTransaction`, and
`anvil_*` are refused before reaching the archive. Before PASS, `relay.log` must
be empty or contain only `refused eth_gasPrice` lines. Any failed request or other
refusal fails the evidence gate.

The git-state gate runs `git status --porcelain --untracked-files=all` and requires
empty output **after excluding exactly the resolved --out path** when it is
inside this worktree. No other tracked or untracked change is allowed. Using the
repository root as --out is refused. An output directory outside the worktree
needs no exclusion. The log header records `gitPolicy`, `excludedOutput`,
`repoCommit`, and `dirtyCount: 0`; the count refers to that filtered status, not an
unrestricted count. `plan.json` is written **after** calibration and final
preflight. Previously the output directory containing `relay.log` itself caused
a dirty entry; the plan file was not present yet.

## Subcommands and gates

`plan` makes only read calls to the archive RPC. It verifies chain 11155111 and
requires `eth_config.current.activationTime == 1791294816` and
`forkId == 0x6c1d9423` and `next == null`, matching the captures under
`docs/design/aoa-balance-mode/data/rams/`. Missing `eth_config` is a hard failure.
It verifies the pinned block's hash and post-activation timestamp, reads the
deployer's, approver's and executor's block and pending nonces, and requires each pair to agree. It checks the
Safe's nonce, exact three owners and threshold 2; SP owner, current token,
pending token and ETA; the on-chain SP queue delay; empty code at both predicted
CREATE addresses; and each of the three senders' balances against its own fee-cap budget.
The expected governance and SP pre-state comes from the sealed v4 snapshot;
changed pre-state requires a separately reviewed workflow change.

CREATE addresses are derived from the current deployer nonce, and Safe EIP-712
hashes from the current Safe nonce. Timelock operation ID and salt are derived
from the encoded operation. Safe.getTransactionHash is called on-chain at the
pin for both S5 and S6 and must equal the independently computed EIP-712 hash.
All three senders' planned nonces are derived from their pinned nonces and
incremented only for that sender's steps. S1–S4 and S7 use sequential deployer nonces;
S5a/S6a are `approveHash` calls by the approver, and S5b/S6b are
`execTransaction` calls by the executor using sorted approved-hash signatures.
Those bytes are not ECDSA signatures and give no authority by themselves.

Planning includes an isolated calibration rehearsal. Dependent steps cannot be
estimated against untouched pinned state. For each step the archive
`eth_estimateGas` request therefore names the pinned block plus explicit
cumulative state overrides and a block timestamp override. State overrides are
reconstructed from local `debug_traceTransaction` using `prestateTracer` with
`diffMode`; cleared storage slots are explicitly zeroed. The provider must
support the four-parameter estimate request (transaction, block, state overrides,
block overrides), and anvil must support that tracer. Unsupported capabilities
fail closed, with no fallback to `latest`. Per-step `estimateContext` in
`simulate.json` and `simulate.log` preserves those inputs for review. It is not
accepted as a plan field: arbitrary override dictionaries cannot become signing
inputs. Timestamp overrides permit the mature timelock operation to
be estimated without pretending it was mature at the archive pin.

A local estimate sizes a pilot, then the pilot's receipt supplies fork gasUsed.
The pilot is rolled back. The final unsigned limit is exactly
`ceil(max(archive estimate, local engine estimate, fork gasUsed) * 13 / 10)`; the margin is the
`MARGIN_NUM/MARGIN_DEN` constant, default 1.3. Every step is then replayed at that
exact limit, with its read-back required to pass. The local estimate is retained
as `localEstimateGas`; `estimateGas` and `forkGasUsed` retain the other inputs.
GasUsed is **not** a lower bound on the viable gas limit: v4 S1 needed 48,641 gas
to run despite using 38,582. Estimates are valid for the pin and simulated state;
`pre_send` must re-estimate against current state before any real send and reject
if the fresh estimate exceeds the frozen limit. Every planned or sent local
transaction has an explicit `gas <= 2**24` gate. `plan.json` records all three gas
numbers, sender, destination (null for CREATE), calldata, value, nonce, chain ID,
gas limit, fee caps and execution timestamps. Execution timestamps are a
canonical **rehearsal schedule** recomputed from the pin: sequential one-second
steps through S6a, then a maturity mine before S6b, then S7. These timestamps do
not constrain when a future real transaction may land. `budgetsWei` separately sums each
sender's gas limits times maxFeePerGas and checks that sender's pinned balance;
Safe owners pay their own transactions. It is a
fee-cap budget, not a forecast of actual cost. A final preflight rechecks the pin
and pending nonce before writing `plan.json` and `plan.json.sha256`.

`simulate` first validates the SHA-256 over the exact saved bytes, then repeats
preflight and starts a fresh fork at the same hash. The sidecar is only a
corruption check: `build_plan(pin)` is independently rebuilt from the artifacts,
and every step's to/data/from/value/nonce (plus chain/fees and all derived identity
fields) must agree. Exact JSON value types and key sets are enforced at the top level, within the
pin, for every step, and for every transaction. A frozen transaction has exactly
the rebuilt transaction's keys plus `gas`; `type`, `authorizationList`,
`accessList`, and `input` are rejected even if empty. `tx_rpc` independently
rejects unknown fields and serializes only its whitelist. Rehearsal timestamps,
S5b's informational `plannedETA`, gas limits, both budget fields, source hashes,
and runtime identity recipes are recomputed. Archive/local estimates and pilot
gasUsed are observations, not derived identity fields; the formula consumes them,
and the separate reviewed digest binds the complete file. Unknown annotations
and unsupported derived fields are rejected. Plans from older schema revisions
must be regenerated. All nine step IDs are required; edited fields are rejected
even when the adjacent sidecar is recomputed. Both plan readers reject duplicate
JSON keys using object_pairs_hook, including nested duplicates. Pin timestamps,
nonces, balances and delay fields must have `type(x) is int`; bools/floats are
rejected. Hex quantities in the pin and transaction fields must be lowercase and
canonical (`hex(int(x, 16)) == x`), with no leading zeros.

The binary's `--version` must contain the pinned full COMMIT. After startup,
`anvil_nodeInfo` must report Amsterdam, FIFO, chain 11155111, the requested fork
block, and this process's loopback relay URL (one normalized trailing slash is
accepted). Its `currentBlockNumber` must equal `forkBlockNumber` before step 1.
Local web3_clientVersion omits the commit and local eth_config describes the
engine's own chain configuration, so those are not used to authenticate Sepolia.
After the nodeInfo check, the child must still be alive, and
`lsof -nP -iTCP:<port> -sTCP:LISTEN -t` must report **only proc.pid**. Missing lsof
or a foreign/multiple listener fails. The child is checked again before every
step. These checks close the released-port authentication gap before any
impersonated transaction.
It impersonates accounts,
uses exactly the saved limits, and checks sender and Safe nonces before and
after every step. Only a full successful predecessor read-back releases the
next executable transaction. `simulate --plan <frozen plan.json>` is an
independent rerun: it does not call `plan_command`, perform calibration pilots,
replace limits, or rewrite the plan. It does re-run both **read-only** estimates
at each pre-step state: the local fork estimate must equal localEstimateGas and
the archive estimate at the pin, with independently reconstructed cumulative
state/time overrides, must equal estimateGas. State diffs and override evidence
are collected on independent replay too. The source plan remains unchanged. The
mined transaction identity and gas limit must match the frozen plan and each
receipt's gasUsed must be at most that limit and equal the recorded pilot gasUsed. The mined transaction must be
type 0x2 with no authorizations or nonempty access list; input and any data alias,
value, sender, destination, nonce, chain ID, fee caps and gas must match. Before PASS, all nine step IDs must
have completed in order and all four named controls must be present in order.
The measured gas formula, relay evidence, empty engine stderr, budgets and
frozen-plan identity are checked before writing PASS. RPC request IDs are
allocated under a lock so concurrent relay requests cannot share an ID.
Read-backs include:

- S1: pending token and ETA cleared, current SP token unchanged.
- S2 onward: minDelay 172800 and exact role sets reconstructed from all
  RoleGranted/RoleRevoked/RoleAdminChanged logs since creation, with empty code immediately before
  deployment. PROPOSER, EXECUTOR and CANCELLER each contain exactly the Safe.
  The deployed timelock runtime must match `timelockRuntimeIdentity`, including
  exact values at every masked immutable offset. DEFAULT_ADMIN contains exactly
  the timelock itself. Role-admin history must
  resolve to DEFAULT_ADMIN for every role and agree with getRoleAdmin getters.
- S3 onward: runtime bytes outside all immutable reference ranges equal the
  build artifact exactly, and every immutable range has its exact expected value
  (see below); cap 10,000,000e18,
  minter and cap guardian equal Safe, total supply zero, owner and pending owner
  match the current step. S4 must leave pendingOwner equal to the timelock.
- S5a/S6a: the appropriate Safe approved hash is recorded.
- S5b: Safe ExecutionSuccess, operation Waiting, ETA exactly schedule block
  timestamp + minDelay. `plannedETA` is a recomputed informational rehearsal
  value. For pre_send(S6a/S6b), the actual ETA is derived from the S5b receipt's
  CallScheduled log and its block timestamp plus the timelock's on-chain
  minDelay; it must equal getTimestamp(opId). The receipt must succeed and its
  transaction identity must match S5b. The receipt is located by its planned
  sender/nonce and full transaction identity; the schedule eth_getLogs query is
  then bounded to `fromBlock == toBlock == S5b receipt.blockNumber`. This allows S5b to land at a different
  real-chain timestamp. Once Done, getTimestamp must be the OZ Done sentinel 1.
- S6b: execute after a warp of at least 48 hours, Safe ExecutionSuccess,
  owner equal timelock, pending owner zero and operation Done.
- S7: pending token equal APNTsCapped, current token unchanged, and pending ETA
  exactly queue block timestamp plus the SP delay **read from the contract**.
  The delay must still match the 7-day value checked in preflight.

`simulate.json` stores receipts, gasUsed, read-backs and controls. Partial progress
is saved after each completed step. `simulate.log` begins with engine version,
engine and repository commits, the git exclusion policy and zero filtered dirty
count, pinned block and `rpc: REDACTED`, then records
per-step results. A nonzero exit and `FAILURE.json` identify the gate, observed
value and expected value. Provider fault messages are not printed or persisted;
malformed envelopes, typed results and unclassified RPC faults fail closed using
the shared `script/evidence/lib/rpc_strict.py` patterns and error classifier.
Output creation is inside exception handling. KeyboardInterrupt and other
BaseException interruptions record the `interrupted` gate and exit nonzero.
If --out itself cannot be created, failure evidence falls back to stderr.
A successful CLI run removes any FAILURE.json created during that attempt.
Prior output directories, including stale failure records, cannot be reused.

## Runtime identity with EIP712 immutables

APNTsCapped inherits ERC20Permit and OZ v5.0.2 EIP712. Its seven immutable
reference IDs are resolved through the **matching build-info's complete source
ASTs**, rather than the APNTsCapped AST alone. Plan construction checks the exact
named set, validates all 32-byte ranges for bounds and overlap, and stores the
artifact runtime plus the ID/name/range mapping in `runtimeIdentity`.
`constructorArgs` stores the same arguments used to encode S3. No live-chain
runtime check is attempted at the predicted, still-empty address.

On the deployed local fork, both calibration during `plan` and `simulate` compare
all bytes outside those ranges exactly, without hashing away differences. Every
masked range is checked independently against its computed 32-byte value:

- `_hashedName`: Keccak of the constructor name (`AAStar PNTs`).
- `_hashedVersion`: Keccak of `1`, the version fixed by ERC20Permit.
- `_cachedChainId`: 11155111, as a uint256.
- `_cachedThis`: predicted APNTsCapped CREATE address, padded to 32 bytes.
- `_cachedDomainSeparator`: Keccak of ABI-encoded domain type hash, hashed name,
  hashed version, chain ID and predicted address. The domain type is
  `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)`.
- `_name` and `_version`: UTF-8 bytes left-aligned with the byte length in the
  last byte when length is at most 31; otherwise the exact OZ fallback sentinel
  (31 zero bytes followed by `ff`). The expected inline/fallback case is computed
  and recorded; both actual constructor strings use inline encoding.

Runtime hash computations use `web3_sha3` on the local anvil. `plan` also checks
that method on the archive RPC; both paths require the known empty-input Keccak
vector `c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470`.
The archive allowlist permits this read-only hash method. Existing offline ABI
and Safe/operation encoding still uses local cast. Every occurrence of a repeated
ID must equal the same computed value. Unknown IDs, ambiguous build mappings,
missing or extra named variables, malformed ranges and uncomputable values fail
closed. Read-back evidence records every checked value and offset, the
ShortString cases and the unmasked-byte comparison.

TimelockController uses the same mask-and-value-check routine from S2 onward.
The current committed artifact has no immutables, so every runtime byte must
match. If immutable references appear, IDs must resolve through matching
TimelockController build-info and every offset must have a computed value. The
supported `_minDelay` value comes from the 172800 constructor argument; any other
uncomputable variable fails closed. Repeated offsets are checked individually.

## Negative controls and corrected requirements

Each chain control takes a local snapshot, **sends an actual impersonated
transaction with an explicit gas limit**, requires a status-0 receipt, and compares
the callTracer's complete top-level revert bytes against the expected error.
A mined reverted EOA transaction necessarily consumes one sender nonce: the
control asserts exactly that increment and that the Safe nonce does not move.
It then restores the snapshot and verifies both sender and Safe nonces equal
their original values. Evidence includes the failed receipt, exact reason and
before/mined/restored nonces. No nonce claim is based merely on eth_call:

- S6b before maturity, after the real S6a approval: Safe `GS013`, plus exactly
  one inner call to the timelock with the planned execute calldata. Its callTracer
  node must have an error and the exact
  `TimelockUnexpectedOperationState(opId, Ready bitmap)` revert bytes, where
  Ready is `1 << 2`. Missing/unavailable traces, absent inner calls or unrelated
  inner reasons fail. The verified inner revert is recorded in the control evidence.
- S5b with the wrong Safe nonce: Safe `GS025`. A local snapshot temporarily
  changes Safe 1.4.1's nonce slot, checks it through the getter, then restores it.
- S7 by a non-owner: `OwnableUnauthorizedAccount(executor)`.

Two original requirements were corrected by the author:

1. “Admin is none” means **no external admin**. The standard constructor always
   grants the timelock self-admin. The accepted exact DEFAULT_ADMIN_ROLE set is
   `{timelock}`; an additional or missing member fails.
2. S4 before S3 is an **executor refusal**, not a chain revert. Calling an address
   with no code can succeed at the EVM level. `pre_send(ExecutionStep(plan, id), remote)`
   refuses to return a transaction unless every target/dependency has code,
   latest and pending sender nonces agree with the plan, and the predecessor's
   full **current on-chain** read-back passes. It does not trust an in-memory
   completed-step list. The rehearsal invokes this boundary for every step.
   The rehearsal records `kind: executor_refusal`, gate `pre_send_code_S4`,
   and unchanged nonces. Offline tests exercise this gate without sending a call.

On failure stop and inspect the record. Do not carry later steps forward from
partial success. Recheck nonces and state and regenerate a plan for review;
changed nonces change addresses, calldata and hashes. Simulated snapshots and
impersonation apply only to the disposable local fork. There is no bypass flag.

## DSR requirement mapping

| Requirement | Implementation |
|---|---|
| Read-only preflight separated from signing | Archive RPC allowlist; plan produces unsigned bytes; separate disabled sign/send |
| Dry-run without a key | Impersonation on the isolated Amsterdam fork; zero generated accounts |
| No key in argv | No key-loading code; archive URL passed only through a file and in-memory relay |
| Fork-tier gate | Chain/config/time checks and pinned nightly commit |
| Full role/runtime/cap/minter/supply checks | Exact event-reconstructed roles; byte-for-byte masked artifact comparison plus exact immutable values; token getters after deployment and subsequent steps |
| S7 seven-day relation | On-chain delay getter and exact ETA arithmetic |
| Failure records | Nonzero exit plus FAILURE.json with gate/observed/expected |
| Recovery negative controls | Exact revert-data/nonces controls and predecessor refusal; stop/regenerate after failures |

## Deliberately unimplemented

`sign` and `send` always exit **3**, record distinct `sign_disabled` /
`send_disabled` gates, and print:

```text
not authorized: requires a reviewed plan hash and the author's separate go
```

`signing_transaction(plan_path, reviewed_sha256, id, remote)` is the sole future
signer input API. It reads the file once and compares the hash of those exact
bytes to the **out-of-band reviewed digest**, before parsing or performing RPC.
A sidecar is never the source of review authority. The future CLI must pass
`--reviewed-plan-sha256 <digest>` from the review decision; that option is exposed
on the disabled sign/send commands, which still always refuse. Replacing a file
and recomputing its sidecar does not replace this digest. The API validates the
frozen canonical plan, runs Safe.getTransactionHash cross-checks for all S5/S6
steps, and obtains the transaction only through `pre_send`. A future signer must use that returned transaction, with no alternate
raw-step path. The simulation uses the same pre_send boundary. This API prepares
bytes only; it signs and broadcasts nothing.

Future design only: signing must require the reviewed plan hash and separate
author go, verify the exact saved bytes and fresh nonces, load a key from a
keystore path or fd/environment **file** (never key material in argv), and sign
exactly the plan's transaction bytes. Sending needs its own reviewed authorization
and freshness/recovery checks. None of that is implemented or implied by a plan.
A SHA-256 sidecar detects changed bytes; it is not a review attestation.

## Offline verification

```sh
/Users/jason/.pyenv/versions/3.11.9/bin/python3 -B script/a3a/test_a3a_exec.py
```

Tests mock urllib in the same style as `script/evidence/test_rams_gauges.py`.
They exercise distinct chain/config/nonce/code/balance/envelope/hash/refusal
gates, additional Safe checks, exact admin exclusivity, predecessor refusal,
exact revert bytes and nonce preservation. Additional runtime controls cover unknown immutable
IDs, wrong cachedThis, unmasked byte changes, repeated offsets, ShortString
boundaries/fallback, a bad Keccak provider and a positive immutable-aware runtime.
The positive plan control performs
real local encoding, hash derivation, serialization and budget checks with
mocked archive reads and artifacts plus a deterministic offline local chain.
The real rehearsal, gas calculation, pre_send read-backs, sender/Safe nonce path,
reverted negative sends, completion and evidence gates stay in use. The positive
control scans plan.json for URL leaks and exercises an independent frozen rerun.
Other controls cover local engine authentication, relay batch filtering/pinned
extras, sender budgets, changed data with recomputed sidecars, role grants and
revocations/admin changes, interruptions, and output freshness. Round-2 controls
include the combined reviewer tamper case and each injected field separately,
exact schema/budget/timestamp validation, mined transaction aliases, out-of-band
hash authority, changed real schedule times, listener PID/child lifetime and
initial head checks, committed/remapped source provenance, empty engine stderr,
concurrent RPC IDs, and timelock runtime/immutable values. Round-3 controls exercise offline archive
and submodule handling, exact bytecode/reference comparisons, HEAD-authorized
no-hash CBOR and enabled-hash verification, duplicate keys, pin integer/canonical
quantity types, the gas cap and both estimate rechecks, exact inner early-execute
reverts, and receipt-block-bounded schedule logs. The compiler/archive boundary
is mocked in the orchestration tests and exercised independently by its own
failure controls; the full rebuild can also be run locally without an archive RPC. It cross-checks all
non-deployment calldata and derived identity hashes against v4, without reusing
v4 gas. It does not prove archive capabilities or replace the live fork run.
The module keeps `sys.dont_write_bytecode = True` at its top. Python 3.11 syntax
is required; compilation can be checked with py_compile output directed to a
temporary directory to avoid repository bytecode files. No shell script is added
or modified, so shell syntax checking is inapplicable.
