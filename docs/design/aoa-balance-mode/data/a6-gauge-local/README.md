# A6 per-UserOperation gauge: local Anvil evidence (CC-125, regenerated on macOS)

> **Local Anvil only. This is not A6 data. It can be accepted only after A4.** Nothing here was
> sent to a public chain. The only keys used are anvil's well-known dev keys. These files exercise
> the gauge locally. They say nothing about how VPM, TPM or SP perform. N, B_max and the
> scenario mix are still DSR's deliverable (plan §8.4).

> **LIMITATION: endpoint B is a pass-through proxy over the SAME Anvil as endpoint A.**
> The N=50 validator's `protocolConformant: true` checks distinct URLs, N, arms, no fixture,
> and no same-endpoint override. It is **not evidence of independent RPC sources**.
> A real A6 run must use two independent providers. Their independence must be established
> outside this gauge.

## What was run

| item | value |
|---|---|
| collector head (recorded in every `run_start.head`, `collectorDirty: false`) | `6ad0a0356ec54e83e1d1bf68d704e8af66f396b0` |
| old collector compared against (`origin/feat/aoa-balance-mode-5.5.0`) | `64e84e35ed5d27a2bf9114fa055ae58ddde5b197` (`old-collector.ref`, source in `old-collector.source.mjs`) |
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
| positive (real triplet) | SP, VPM and TPM all `USEROP_SUCCESS`. SP: 18 conservation checks OK (BALANCE mode). VPM/TPM: deposit identity OK | 0 `COMPLETE` | 0 (consistent, accepted) | — |
| (a) tx succeeds, op execution reverts | all three arms `USEROP_REVERTED` (`user_operation_success`). SP conservation still OK, because postOp settles in `opReverted` | 10 | 3 (consistent, not accepted) | **success** (`status=success`, no failure flag) on all three, although the UserOperationEvent has `success=false` |
| (b) tx succeeds, our op is not in the bundle | all three arms `NO_EVENT` (`user_operation_event_present`) | 10 | 3 | **success** on all three, although there is **no** UserOperationEvent for the recorded hash |
| (c) wrong expected userOpHash | all three arms `HASH_MISMATCH` (`expected_hash_in_events`) | 10 | 3 | n/a (the old collector never matched hashes) |
| (d) endpoint B tampers a read-back | stop `RPC_DISAGREEMENT` on `$.userXPNTs`. The attempt row is still written, with `stoppedBy` | **20** | **2**: `missing field chainId` (fails closed) | n/a (single endpoint) |
| (e) fake +1000 operator-balance delta injected into validator input | — | — | **1**: `conservation FAILS on raw read-backs: C1,C3`, plus `recorded conservation.ok=true, recomputed false` | n/a |
| (e′) required field (`logs`) deleted | — | — | **2**: `missing field logs` (fails closed) | n/a |
| N=50 mechanism run | 150/150 `USEROP_SUCCESS`, 50/50 matched triplets, `COMPLETE`, `protocolConformant: true` | 0 | 0, recomputed `{"USEROP_SUCCESS":150}`, matchedTriplets 50 | — |

Control (d) stops at `RPC_DISAGREEMENT` before the passport is complete. Its `run_end.passport`
is null, so the validator exits 2 with `missing field chainId`. This is fail-closed by design,
not an accepted or fully validated run. See `d-tamper-b.jsonl` and `d-tamper-b.validator.json`.

The positive control is accepted with `protocolConformant: false` (one triplet).
For N=50, `n50-mechanism.jsonl` records 50 attempts per arm and `COMPLETE`; the validator
reports `consistent: true`, `accepted: true`, and `protocolConformant: true`, with no errors.
These flags have the local limitations stated above.

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
This directory now contains the macOS regeneration at `6ad0a035`, whose commit message
records the following hardening after adversarial review:

- Fixtures are run-level only. Each success is bound to the userOpHash recomputed from
  `packedOp`. The validator recomputes `callDataHash` and reads gas and bundler from the recorded transaction.
- Passport completeness fails closed: 98 single-field deletions each produced validator exit 2.
- The collector refuses identical A and B endpoints unless it records an explicit local override.
  The validator recomputes `protocolConformant` from N=50, no fixture, three arms,
  distinct endpoints, and no local override. Distinct endpoints do not establish independent providers.
- PostOp R1 and R2 use the independent reservation. Not-evaluable rows cannot count,
  and unevaluated conservation is `ok: null`.
- Citations were corrected to `lockedOf` at XT:240,263 and `creditReservedOf` at XT:305,322.
- The commit's `offline-review/` campaign contains 115 JSONL tampering controls.
  Of these, 111 that previously exited 0 are now rejected. These counts describe that
  hardening campaign, not additional on-chain runs in this directory.

The old-collector comparison was also regenerated. `old-collector.ref` now records
`64e84e35ed5d27a2bf9114fa055ae58ddde5b197`; its false successes remain documented
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
  The gauge does not yet handle multi-op bundles from other senders sharing a block. It stops
  with `BLOCK_NOT_ISOLATED` (24) instead of attributing deltas.
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
