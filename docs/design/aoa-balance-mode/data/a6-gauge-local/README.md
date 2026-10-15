# A6 per-UserOperation gauge: local Anvil evidence (CC-125 a71741ed)

> **Local Anvil only. This is not A6 data. It can be accepted only after A4.** Nothing here was
> sent to a public chain. The only keys used are anvil's well-known dev keys. These files prove
> that the *gauge* works. They say nothing about how VPM, TPM or SP perform. N, B_max and the
> scenario mix are still DSR's deliverable (plan §8.4).

## What was run

| item | value |
|---|---|
| collector head (recorded in every `run_start.head`, `collectorDirty: false`) | `bbf34d462f97b5ac838aa9c791fef45039599101` |
| old collector compared against (`origin/feat/aoa-balance-mode-5.5.0`) | `25c33feaf6092eb183f606e571eb7b72e9f0f930` (`old-collector.ref`, source in `old-collector.source.mjs`) |
| forge / anvil / cast | 1.5.1-stable, commit `b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2` (from the GitHub release tarball, because `foundryup`'s host was blocked by the sandbox proxy) |
| solc | 0.8.33+commit.64118f21 (static linux build from the GitHub release; `forge build --offline`) |
| node / pnpm / viem | v22.22.0 / 10.28.0 / 2.52.2 (`pnpm install --frozen-lockfile`) |
| chain | fresh `anvil --port 8545 --chain-id 31337`, then `./deploy-core anvil --force`, `./prepare-test anvil`, `deploy-baselines.mjs` |
| SP under test | `SuperPaymaster-5.5.0` (UUPS proxy + impl), xPNTs `XPNTs-4.0.0` (EIP-1167 clone of xPNTsTokenV2 + Ext) |
| EntryPoint | v0.7 compiled from `singleton-paymaster/lib/account-abstraction-v7`, deployed by `deploy-core` at `0xe7f1…0512` (see the gaps section) |

Commands (the full driver is copied here as `full-run.sh.txt`):

```bash
export PATH="$HOME/.foundry/bin:$PATH"
anvil --port 8545 --chain-id 31337 &
./deploy-core anvil --force          # log: setup-deploy-core.log.gz
./prepare-test anvil                 # log: setup-prepare-test.log.gz
OUT=docs/design/aoa-balance-mode/data/a6-gauge-local
node script/a6-collector/deploy-baselines.mjs http://127.0.0.1:8545 $OUT/baselines.anvil.json
cp deployments/config.anvil.json $OUT/config.anvil.json
script/a6-collector/negative-controls/run.sh $OUT $OUT/baselines.anvil.json
# afterwards: git checkout -- abis deployments/config.anvil.json   (deploy-core/prepare-test rewrite them)
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
| (d) endpoint B tampers a read-back | stop `RPC_DISAGREEMENT` on `$.userXPNTs`. The attempt row is still written, with `stoppedBy` | **20** | 3 (consistent, not accepted) | n/a (single endpoint) |
| (e) fake +1000 operator-balance delta injected into validator input | — | — | **1**: `conservation FAILS on raw read-backs: C1,C3`, plus `recorded conservation.ok=true, recomputed false` | n/a |
| (e′) required field (`logs`) deleted | — | — | **2**: `missing field logs` (fails closed) | n/a |
| N=50 mechanism run | 150/150 `USEROP_SUCCESS`, 50/50 matched triplets, no stop, `protocolConformant: true` | 0 | 0, recomputed `{"USEROP_SUCCESS":150}`, matchedTriplets 50 | — |

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
    - `ΔuserXPNTs == ΔtotalSupply == −xBurned`, and `ΔlockedOf == 0` (xPNTsTokenV2.sol:239,263,267)
    - `xBurned == min(ceil(charge·xLocked/a0), xLocked)` (:259-260)
    - `LockSettled.aCharged == charge ≤ a0` (:258,268; SuperPaymaster.sol:434)
  - CREDIT mode and postOp-reverted branches are implemented as well. Neither occurred in these runs.
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
