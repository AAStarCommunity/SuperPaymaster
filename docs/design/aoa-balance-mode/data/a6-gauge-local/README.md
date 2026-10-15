# A6 per-UserOperation gauge: local Anvil evidence (CC-125, regenerated on macOS)

> **Local Anvil only. This is not A6 data. It can be accepted only after A4.** Nothing here was
> sent to a public chain. The only keys used are anvil's well-known dev keys. These files exercise
> the gauge locally. They say nothing about how VPM, TPM or SP perform. N, B_max and the
> scenario mix are still DSR's deliverable (plan §8.4).

> **LIMITATION: local A/B are proxies over ONE Anvil, not independent RPC sources.**
> A is the direct Anvil endpoint; B forwards to that same node. The gauge treats loopback
> endpoints as one identity regardless of port and requires `--allow-same-endpoint-local`.
> Every regenerated run records `allowSameEndpointLocal: true`, which disqualifies conformance.
> The N=50 run is consistent but **not accepted**, with `protocolConformant: false`.
> A real A6 run must use two independent providers. Their independence must still be
> established outside this gauge; distinct endpoint identities alone do not prove it.

## What was run

| item | value |
|---|---|
| collector head (recorded in every `run_start.head`, `collectorDirty: false`) | `d8c8a9f4a906e3c15991cf4cf62caebb904aaa4c` |
| old collector compared against (`origin/feat/aoa-balance-mode-5.5.0`) | `172ff7df9f3156ae9e6cb742647dd2b132adbbc7` (`old-collector.ref`, source in `old-collector.source.mjs`) |
| forge / anvil | Both 1.7.1, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`, profile `dist` (local `forge --version` and `anvil --version`) |
| solc | 0.8.33 (`setup-deploy-core.log.gz`) |
| node / pnpm / viem | v24.21.0 / 10.34.5 / 2.52.2 (local `node --version`, `pnpm --version`, and `node_modules/viem/package.json` through the existing symlink) |
| chain | fresh `anvil --port 8545 --chain-id 31337`, then `./deploy-core anvil --force`, `./prepare-test anvil`, `deploy-baselines.mjs` |
| SP under test | `SuperPaymaster-5.5.0` (UUPS proxy + impl), xPNTs `XPNTs-4.0.0` (EIP-1167 clone of xPNTsTokenV2 + Ext) |
| EntryPoint | v0.7 compiled from `singleton-paymaster/lib/account-abstraction-v7`, deployed by `deploy-core` at `0xe7f1…0512` (see the gaps section) |

The local run driver is archived as `full-run.sh.txt`. Its setup and collection commands are:

```bash
export PATH="$HOME/.foundry/bin:$PATH"
anvil --port 8545 --chain-id 31337 &
./deploy-core anvil --force          # log: setup-deploy-core.log.gz
./prepare-test anvil                 # log: setup-prepare-test.log.gz
OUT=docs/design/aoa-balance-mode/data/a6-gauge-local
node script/a6-collector/deploy-baselines.mjs http://127.0.0.1:8545 $OUT/baselines.anvil.json
cp deployments/config.anvil.json $OUT/config.anvil.json
script/a6-collector/negative-controls/run.sh $OUT $OUT/baselines.anvil.json
# run.sh passes --allow-same-endpoint-local to every collector invocation.
# archived copy only: baselines.anvil.json signerKey redacted (it is anvil dev key #2, but
# .github/workflows/check-secrets.yml would flag the literal); setup logs gzipped.
```

Re-validate any run without a chain: `node script/a6-collector/validate.mjs <run>.jsonl`.

## A/B read-back topology (local)

- **A** is anvil itself, `http://127.0.0.1:8545`.
- **B** is `script/a6-collector/rpc-proxy.mjs` on `:8546`, a pass-through JSON-RPC proxy in
  front of **the same anvil**.
- **B′** (control d only) is the same proxy on `:8547` with `--tamper-*`. It adds 1 to every
  `balanceOf` result from the xPNTs token.

So A and B are **not independent sources** on a local run. B exists to exercise the comparison
path, and B′ proves that a disagreement stops the run. Every read-back is pinned to an explicit
block number on both sides. Each run records its topology in `run_start.abTopology`. A real
campaign must use two independently operated nodes.

## Results

The full table is in `NEGATIVE-CONTROLS.md`, generated from these files. Exit codes are in
`results.tsv`.

| control | new gauge | collector exit | validator exit | old collector |
|---|---|---|---|---|
| positive (real triplet) | SP, VPM and TPM all `USEROP_SUCCESS`. SP: 30 conservation checks OK (BALANCE mode). VPM/TPM: 7 checks each OK, including deposit identity | 0 `COMPLETE` | 0 (consistent, accepted) | — |
| (a) tx succeeds, op execution reverts | all three arms `USEROP_REVERTED` (`user_operation_success`). SP conservation still OK (30 checks; VPM/TPM: 7 each), because postOp settles in `opReverted` | 10 | 3 (consistent, not accepted) | **success** (`status=success`, no failure flag) on all three, although the UserOperationEvent has `success=false` |
| (b) tx succeeds, our op is not in the bundle | all three arms `NO_EVENT` (`user_operation_event_present`) | 10 | 3 | **success** on all three, although there is **no** UserOperationEvent for the recorded hash |
| (c) wrong expected userOpHash | all three arms `HASH_MISMATCH` (`expected_hash_in_events`) | 10 | 3 | n/a (the old collector never matched hashes) |
| (d) endpoint B tampers a read-back | stop `RPC_DISAGREEMENT` on `$.userXPNTs`. The attempt row is still written, with `stoppedBy` | **20** | **2**: `missing field readbacks.before.A` (fails closed) | n/a (single endpoint) |
| (e) fake +1000 operator-balance delta injected into validator input | — | — | **1**: `conservation FAILS on raw read-backs: C1,C3`, plus `recorded conservation.ok=true, recomputed false`, operator-balance continuity/baseline failures and same-block disagreement | n/a |
| (e′) required field (`logs`) deleted | — | — | **2**: `missing field logs` (fails closed) | n/a |
| N=50 mechanism run | 150/150 `USEROP_SUCCESS`, 50/50 matched triplets, `COMPLETE`, `protocolConformant: false` | 0 | 3 (consistent, not accepted), recomputed `{"USEROP_SUCCESS":150}`, matchedTriplets 50 | — |

Control (d) stops at `RPC_DISAGREEMENT` before read-backs are complete. Its attempt row lacks
`readbacks.before.A`, and its `run_end.passport` is null. The validator exits 2 with
`missing field readbacks.before.A`. This is fail-closed by design,
not an accepted or fully validated run. See `d-tamper-b.jsonl` and `d-tamper-b.validator.json`.

The positive control is accepted with `protocolConformant: false` (one triplet).
For N=50, `n50-mechanism.jsonl` records 50 attempts per arm and `COMPLETE`; the validator
reports `consistent: true`, `accepted: false`, and `protocolConformant: false`, with no errors
and validator exit 3. The mandatory local override disqualifies conformance, so completion and
conservation do not make this N=50 run acceptable. The one-triplet positive control remains
accepted as a local control; it is not protocol conformant.

Collector exit 10 means the attempt budget ran out before N matched triplets. That is expected:
each fixture run gets one attempt per arm, and a fixture row never counts toward N.

The old-collector rows come from `old-collector.source.mjs` with the fixture patch in
`old-collector.fixture.diff`. The patch changes only *what is bundled*, never how a row is
judged. `old-*.recheck.json` looks up the UserOperationEvent for the hash each old row recorded.

## How the gauge decides (summary; the code is authoritative)

- **Verdict per op.** The gauge reads the EntryPoint events (`UserOperationEvent`,
  `UserOperationRevertReason`, `PostOpRevertReason`, `UserOperationPrefundTooLow`) for the
  expected hash. That hash is computed twice, locally and through
  `EntryPoint.getUserOpHash`, and the two must agree (stop 23). `receipt.status` only decides
  `TX_FAILED`.
- **SP conservation.** The identities are in `script/a6-collector/gauge-lib.mjs`, and each one
  cites `path:line`. For one bundle tx, with state read at blocks N−1 and N:
  - aPNTs side:
    - `ΔoperatorBalance == −charge` (SuperPaymaster.sol:322,447)
    - `ΔprotocolRevenue == +charge` (:448)
    - `inflightOf(h)` is empty before and after (:324,445)
    - `ΔtotalTxSponsored == 1` (:417)
    - `ΔtotalSpent == a0` (:323)
    - `TransactionSponsored(op, user, ·, charge)` is emitted once (:450)
  - xPNTs side:
    - `ΔuserXPNTs == ΔtotalSupply == −xBurned`, and `ΔlockedOf == 0` (xPNTsTokenV2.sol:240,263,267)
    - `xBurned == min(ceil(charge·xLocked/a0), xLocked)` (:259-260)
    - `LockSettled.aCharged == charge ≤ a0` (:258,268; SuperPaymaster.sol:434)
  - CREDIT mode and postOp-reverted branches are implemented as well. Neither occurred in these runs.
    `creditReservedOf` citations are xPNTsTokenV2.sol:305,322.
  - Every arm: `ΔEntryPoint deposit == −actualGasCost` (EntryPoint.sol:535,744-745).
- **Requested identity vs. what is checked.** The task asked for `operator delta + revenue delta
  + burned == charge`. That sum adds two different assets: `burned` is in xPNTs, everything else
  is in aPNTs. The checks that type-check are the ones above. In aPNTs, `Δop + Δrev == 0` and
  `Δrev == charge`. In xPNTs, `burned` follows from `charge` by the C7 formula.
- **Passport.** It records:
  - chain id, plus block number and hash at the start and end
  - runtime codehashes: EntryPoint, SP proxy and impl, xPNTs clone/impl/ext, account proxy and impl, VPM, TPM, TPM token, price feed
  - SP config getters, operator config, xPNTs config, the three paymasters' stakes, and `entryPoint()` of every arm and of the account (all must be the same EntryPoint, otherwise stop 26)
  - the gas fields and the callData hash

  It is checked at the start, after every attempt, and at the end. Any drift stops the run (21).
- **Attempts and stops.** Every attempt produces exactly one append-only JSONL line, failures
  included, and `run_start`/`run_end` lines frame the run. A matched triplet means all three
  arms are `USEROP_SUCCESS` with the same callData, gas, bundler, EntryPoint and sender.
  Exclusion reasons are `FIXTURE`, `NOT_SENT:DEPOSIT_FLOOR`, `NOT_SENT:INFRA_AA31`,
  `NOT_SENT:PREFLIGHT_UNDECODED`, `BLOCK_NOT_ISOLATED` and `STOPPED`. Stop codes are 20–26 (see
  the `collector.mjs` header).

## What changed vs the cloud run

The superseded cloud run used collector `bbf34d46` and Linux Foundry 1.5.1.
This directory now contains the macOS regeneration at `d8c8a9f4`, after five rounds of
adversarial-review hardening in the `script/a6-collector` history (`6ad0a035`, `5d2bdc02`,
`67fc6c60`, `e272baa7`, `e8187911`) and the regression fixes `23660234` and `d8c8a9f4`:

- Fixtures are run-level only. Each success is bound to the userOpHash recomputed from
  `packedOp`. The validator recomputes `callDataHash` and reads gas and bundler from the recorded transaction.
- Passport completeness fails closed: 100 single-field deletions each produced validator exit 2.
- The collector refuses identical A and B endpoints unless it records an explicit local override.
  The validator recomputes `protocolConformant` from N=50, no fixture, three arms,
  distinct endpoints, and no local override. Distinct endpoints do not establish independent providers.
- PostOp R1 and R2 use the independent reservation. Not-evaluable rows cannot count,
  and unevaluated conservation is `ok: null`.
- Citations were corrected to `lockedOf` at XT:240,263 and `creditReservedOf` at XT:305,322.
- **Round 2 — arms and transaction binding.** Each arm's paymaster must match both its
  `packedOp` and passport. Triplet arms require distinct paymasters, transaction hashes and
  userOpHashes; the expected op must appear in `bundledOps`, and extra events cannot satisfy
  another arm.
- **Round 2 — endpoints, passport and target.** Endpoint identity uses normalized host and effective port,
  ignoring transport. Path, query, userinfo and fragment cannot create distinctness. The passport
  is bound to the emitting EntryPoint and sender, with typed, non-empty config. The target
  must be at least 1, conformance requires exactly 50, and a count-50 run is accepted only
  when conformance recomputes true.
- **Round 2 — conservation.** The postOp-revert branch checks persisting validation writes
  (`totalSpent`, inflight) and unchanged xPNTs/supply. Success checks `LockCreated` user/locker
  identity.
- **Round 3 — run-wide continuity and strict fixtures.** Transaction hashes, userOpHashes and
  blocks cannot be reused across attempts; consecutive single-transaction blocks and balances
  must be continuous. Only `fixture === null` can count; empty string, false and zero are rejected.
- **Round 3 — loopback identity.** Loopback aliases, including `localhost.`, `*.localhost`,
  `127/8`, `::1`, IPv4-mapped loopback and `0.0.0.0`, share one identity. Different local ports
  require `--allow-same-endpoint-local`, which disqualifies conformance. The negative-control
  harness now passes this mandatory override.
- **Round 3 — full conservation.** BALANCE success checks cleared `inflightOperator`, unchanged
  debts and `creditReservedOf`, and `LockSettled` identity. CREDIT checks `totalSpent += a0`,
  reservation bounds and `CreditSettled` identity. The postOp branch requires absent settle
  events and unchanged credit fields.
- **Round 3 — end passport.** The end passport must retain the start chainId and bind a block
  at or after the last attempt (strengthened in round 5 to strictly after it);
  `run_end.exitCode` must equal `stop.code`.
- **Round 4 hardening (`e272baa7`).** Malformed or unspecified hosts cannot establish
  distinct endpoints. Successful nonce sequences must strictly increase per sender and nonce key
  across arms. Counted successes require sponsorship eligibility, enabled SP/operator/xPNTs,
  and fresh cached prices. Passport operator balances require A/B read-backs at the same block
  hash; the collector now records operatorBalance for every arm, including the end block.
  `TransactionSponsored` cost must agree with charge and fee BPS. BALANCE lock admission checks
  reservation bounds, exchange-rate conversion and available balance. Deployed accounts require
  empty initCode, and the packed paymaster operator must match the passport and event.
  Block brackets and receipt hashes are checked even without a UserOperationEvent.
- **Continuity regression (`23660234`).** Round 4 wrongly stopped a legitimate N=50 run
  with collector exit 22 at attemptIndex 4 (VPM, block 190). It compared the shared
  operatorBalance with VPM's previous block-188 value, despite the intervening legitimate SP
  charge. The fix tracks this balance in chronological attempt order, anchored at the start
  passport. SP changes still require event-backed conservation; VPM/TPM transactions must leave
  it unchanged. Per-arm state checks remain, with no allowance for unexplained top-ups.
  Three regression controls verify that a legitimate synthetic N=50 passes, while an
  unexplained jump and a mutation inside a baseline transaction fail.
- **Round 5 hardening (`e8187911`).** Nonces must advance exactly one per sender/key.
  Reservation quotes must use valid oracle inputs and the contract's rounding; SP enforces
  `minTxInterval` and the configured postOp gas floor. Non-executed rows must leave state
  unchanged. The end passport must use a fresh block strictly after the last attempt, with
  an unused block hash and unchanged final operator balance. Under the local Anvil override
  on chain 31337, the collector mines one block with `evm_mine` to take this fresh end
  passport; real chains wait for a later block. Packed SP maxRate, token and renewal flags,
  VPM validity windows, and account size/codehash consistency are checked as well.
- **Second regression — receipt attribution (`d8c8a9f4`).** Round 5's “no UOE => no change”
  rule wrongly flagged honest foreign-op and hash-mismatch fixtures: no UserOperationEvent
  (UOE) for the expected hash does not mean no operation executed. The fix attributes deltas
  to executed receipt UOEs bound to the recorded bundled operations, checks each operation's
  events and conservation, then compares aggregate state deltas. Unexplained or unbacked
  changes still fail; honest foreign/hash-mismatch rows remain non-countable. The 43 controls
  in `receipt-attribution-results.tsv` record three honest cases (including two foreign ops)
  at validator exit 3, consistent but not accepted with zero matched triplets, and 40
  tampered/unbacked cases at exit 1.
- The current `offline-review/` result tables contain **117 + 57 + 44 + 36 + 3 + 51 + 43
  = 351 controls**: base, round-2, round-3, round-4, shared-balance regression, round-5,
  and receipt-attribution (`no_execution`) regression suites respectively (`results.tsv`,
  `round2-results.tsv`, `round3-results.tsv`, `round4-results.tsv`,
  `shared-balance-results.tsv`, `round5-results.tsv`, `receipt-attribution-results.tsv`).
  All 351 controls record their expected outcomes. Of the base controls, 113 previously
  exited 0 and are now rejected; all 57 round-2, 44 round-3, 36 round-4 and 51 round-5
  controls also previously exited 0 and are now rejected (round-2 includes one consistent,
  not-accepted exit 3). The shared-balance regression table records collector pass/validator 0
  for the legitimate N=50 and collector reject/validator 1 for each of two mutations.
  The receipt-attribution outcomes are detailed above. These are offline tampering/control
  campaigns, not additional on-chain runs in this directory.

The old-collector comparison was also regenerated. `old-collector.ref` now records
`172ff7df9f3156ae9e6cb742647dd2b132adbbc7`; its false successes remain documented
in `NEGATIVE-CONTROLS.md` and `old-*.recheck.json`.

## Gaps / not verified here

- **EntryPoint is not at the canonical address.** The task requires EntryPoint v0.7 at
  `0x0000000071727De22E5E9d8BAf0edAc6f37da032`. `deploy-core anvil` deploys its own EntryPoint
  by CREATE, at `0xe7f1…0512`. SP binds that address immutably, so all three arms here share
  *one* EntryPoint, but not the canonical one. Its runtime codehash
  (`0x2c4c5c5f…80f9c`, recorded in the Passport) is **not** the canonical v0.7 codehash used by
  `script/b-layer` (`0x8db5ff69…fc58`), because it was compiled in this repo's profile. The
  Passport records `isCanonicalV07Address: false`. A real campaign should pass
  `--expect-entrypoint 0x0000000071727De22E5E9d8BAf0edAc6f37da032`, which stops the run if the
  address differs. The gauge has never been run against the canonical deployment.
- **One bundler, one op per bundle.** The bundler is anvil key #1, and every handleOps carries a
  single op (two only in the drop-op fixture). No external bundler (Alto/Skandha) was involved.
  Receipt attribution now has offline coverage for two foreign ops in one bundle, but that
  is not an on-chain run here. The gauge still requires an isolated transaction block;
  other transactions sharing the block stop it with `BLOCK_NOT_ISOLATED` (24).
- **Paths not exercised by any run.**
  - CREDIT-mode conservation (C5′) and the postOp-reverted branch (R1/R2) exist in both the
    gauge and the validator, but no run produced them.
  - `TX_FAILED` and `NOT_SENT:*` rows were not produced either. The preflight `simulateContract`
    withholds anything that would revert.
- **SBT eligibility setup.** It still impersonates Registry to call `updateSBTStatus`, as the
  previous revision did (see this directory's parent README). Every other setup step is a real
  tx by its real owner. The xPNTs caps are raised to 50,000 through `account.execute`, which is
  needed for 50 ops at these placeholder gas fields.
- **Placeholder parameters.** The gas fields, `--b-max 1` and the `--max-attempts` default (2N)
  are placeholders. DSR has not frozen them.

## Evidence integrity

`EVIDENCE.sha256` covers every file in this directory except itself, in sorted path order.
Regeneration command, run from this directory:

```bash
find . -type f ! -name EVIDENCE.sha256 | LC_ALL=C sort | while IFS= read -r file; do shasum -a 256 "$file"; done > EVIDENCE.sha256
```
