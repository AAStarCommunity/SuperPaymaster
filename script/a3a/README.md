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
EIP712 immutables described below; the timelock must have none. Full compiler
build-info under `out/build-info/*.json` must include `output.sources[*].ast`
(including the inherited OZ sources) and `output.contracts` containing the
matching APNTsCapped deployed bytecode and immutable references. Generate full
build-info with the nightly forge's `--build-info --ast` options when preparing
artifacts. Source-index-only build-info is insufficient and fails the
`immutable_build_info` gate. AST IDs belong to a compilation unit: outputs from
other builds are never combined to guess names. The executor never invokes a
compiler or downloads dependencies.

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
syntax. Decimal and `0x` block numbers are accepted. Use a fresh output directory
per attempt. RPC credentials stay in memory: anvil receives a loopback relay URL,
and the relay permits only read RPCs. Engine stdout/stderr are discarded to avoid
accidental credential disclosure. No key, mnemonic or wallet is loaded.

## Subcommands and gates

`plan` makes only read calls to the archive RPC. It verifies chain 11155111 and
requires `eth_config.current.activationTime == 1791294816` and
`forkId == 0x6c1d9423`, matching the captures under
`docs/design/aoa-balance-mode/data/rams/`. Missing `eth_config` is a hard failure.
It verifies the pinned block's hash and post-activation timestamp, reads the
deployer's block and pending nonces, and requires them to agree. It checks the
Safe's nonce, exact three owners and threshold 2; SP owner, current token,
pending token and ETA; the on-chain SP queue delay; empty code at both predicted
CREATE addresses; and the deployer's balance against the fee-cap budget.
The expected governance and SP pre-state comes from the sealed v4 snapshot;
changed pre-state requires a separately reviewed workflow change.

CREATE addresses are derived from the current deployer nonce, and Safe EIP-712
hashes from the current Safe nonce. Timelock operation ID and salt are derived
from the encoded operation. S1–S4 and S7 use sequential deployer nonces;
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
fail closed, with no fallback to `latest`. `estimateContext` preserves those
inputs for review. Timestamp overrides permit the mature timelock operation to
be estimated without pretending it was mature at the archive pin.

A local estimate sizes a pilot, then the pilot's receipt supplies fork gasUsed.
The pilot is rolled back. The final unsigned limit is exactly
`ceil(max(archive estimate, fork gasUsed) * 13 / 10)`; the margin is the
`MARGIN_NUM/MARGIN_DEN` constant, default 1.3. Every step is then replayed at that
exact limit, with its read-back required to pass. `plan.json` records both gas
numbers, sender, destination (null for CREATE), calldata, value, nonce, chain ID,
gas limit, fee caps and execution timestamps. The budget sums deployer gas
limits times maxFeePerGas; Safe owners pay their own transactions. It is a
fee-cap budget, not a forecast of actual cost. A final preflight rechecks the pin
and pending nonce before writing `plan.json` and `plan.json.sha256`.

`simulate` first validates the SHA-256 over the exact saved bytes, then repeats
preflight and starts a fresh fork at the same hash. It impersonates accounts,
uses exactly the saved limits, and checks sender and Safe nonces before and
after every step. Only a full successful predecessor read-back releases the
next executable transaction. No calibration pilot is run by this subcommand.
Read-backs include:

- S1: pending token and ETA cleared, current SP token unchanged.
- S2 onward: minDelay 172800 and exact role sets reconstructed from all
  RoleGranted/RoleRevoked logs since creation, with empty code immediately before
  deployment. PROPOSER, EXECUTOR and CANCELLER each contain exactly the Safe.
  DEFAULT_ADMIN contains exactly the timelock itself.
- S3 onward: runtime bytes outside all immutable reference ranges equal the
  build artifact exactly, and every immutable range has its exact expected value
  (see below); cap 10,000,000e18,
  minter and cap guardian equal Safe, total supply zero, owner and pending owner
  match the current step. S4 must leave pendingOwner equal to the timelock.
- S5a/S6a: the appropriate Safe approved hash is recorded.
- S5b: Safe ExecutionSuccess, operation Waiting, ETA exactly schedule block
  timestamp + 172800, also saved as `plannedETA` and checked on replay.
- S6b: execute after a warp of at least 48 hours, Safe ExecutionSuccess,
  owner equal timelock, pending owner zero and operation Done.
- S7: pending token equal APNTsCapped, current token unchanged, and pending ETA
  exactly queue block timestamp plus the SP delay **read from the contract**.
  The delay must still match the 7-day value checked in preflight.

`simulate.json` stores receipts, gasUsed, read-backs and controls. Partial progress
is saved after each completed step. `simulate.log` begins with engine version,
commit, working-tree dirty count, pinned block and `rpc: REDACTED`, then records
per-step results. A nonzero exit and `FAILURE.json` identify the gate, observed
value and expected value. Provider fault messages are not printed or persisted;
malformed envelopes, typed results and unclassified RPC faults fail closed using
the shared `script/evidence/lib/rpc_strict.py` patterns and error classifier.

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

## Negative controls and corrected requirements

The chain controls use `eth_call`, compare the **complete revert bytes** rather
than a message substring, and verify both sender and Safe nonces are unchanged:

- S6b before maturity, after the real S6a approval: Safe `GS013`.
- S5b with the wrong Safe nonce: Safe `GS025`. A local snapshot temporarily
  changes Safe 1.4.1's nonce slot, checks it through the getter, then restores it.
- S7 by a non-owner: `OwnableUnauthorizedAccount(executor)`.

Two original requirements were corrected by the author:

1. “Admin is none” means **no external admin**. The standard constructor always
   grants the timelock self-admin. The accepted exact DEFAULT_ADMIN_ROLE set is
   `{timelock}`; an additional or missing member fails.
2. S4 before S3 is an **executor refusal**, not a chain revert. Calling an address
   with no code can succeed at the EVM level. `StepOrder.prepare()` refuses to
   prepare an executable step unless all predecessor read-backs have passed.
   The rehearsal records `kind: executor_refusal`, gate `step_predecessor_S4`,
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

Future design only: signing must require the reviewed plan hash and separate
author go, verify the exact saved bytes and fresh nonces, load a key from a
keystore path or fd/environment **file** (never key material in argv), and sign
exactly the plan's transaction bytes. Sending needs its own reviewed authorization
and freshness/recovery checks. None of that is implemented or implied by a plan.
A SHA-256 sidecar detects changed bytes; it is not a review attestation.

## Offline verification

```sh
python3 -m py_compile script/a3a/a3a_exec.py script/a3a/test_a3a_exec.py
python3 script/a3a/test_a3a_exec.py
```

Tests mock urllib in the same style as `script/evidence/test_rams_gauges.py`.
They exercise distinct chain/config/nonce/code/balance/envelope/hash/refusal
gates, additional Safe checks, exact admin exclusivity, predecessor refusal,
exact revert bytes and nonce preservation. Additional runtime controls cover unknown immutable
IDs, wrong cachedThis, unmasked byte changes, repeated offsets, ShortString
boundaries/fallback, a bad Keccak provider and a positive immutable-aware runtime.
The positive plan control performs
real local encoding, hash derivation, serialization and budget checks with
mocked chain reads, artifacts and the calibration boundary. It cross-checks all
non-deployment calldata and derived identity hashes against v4, without reusing
v4 gas. It does not prove archive capabilities or replace the live fork run.
No shell script is added or modified, so shell syntax checking is inapplicable.
