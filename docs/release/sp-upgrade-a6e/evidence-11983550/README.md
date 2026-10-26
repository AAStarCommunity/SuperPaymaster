# Safe A6e upgrade package — fork evidence at Sepolia block 11,983,550

Unsigned package for the Safe A6e route. (Context, not backed by files here: CC-125
deliverable 1, DSR ruling d6d67a51 on Seeder.)
Nothing here was signed or broadcast; every transaction below ran on a local anvil fork
(engine foundry nightly `4e8874b2bdc840929585ca73e170993c50a4a531`, implements the EIP-8037 reservoir; calibrated 10/10 against real RR txs on the first step only)
pinned to block `0xb6dabe` / hash `0x77ab0a0b…cec01b8af4`.

| dir | what |
|---|---|
| `a3a-plan/` | A3a plan (timelock 0xCCdF…C34B bootstrap), sha256 `adf74bf3…cf059`; must execute first |
| `boot/` | bootstrap run: builds the upgrade plan (sha256 `81ceece1…e826e`) and simulates A3a + upgrade |
| `indep/` | independent `simulate --plan` run of the frozen `boot/plan.json` + same A3a plan |

Both runs: repo commit `af802726`, dirty 0, status PASS, phases `a3a` → `upgrade`.
The independent run matches the bootstrap on what the package depends on: identical gasUsed
on all 16 upgrade steps, the same 7 controls (1 positive, 6 negative) with the same outcomes, identical
pre-restore readback. Block timestamps, block hashes and timestamp-bearing log data differ
between the runs (each run mines its own fork blocks). `relay.log` in every
run contains only `refused eth_gasPrice` and the teardown marker (no abandoned/failed
upstream request). `engine.stderr` empty.

## Upgrade steps (gas limit = ceil(max(estimate, local estimate, fork gasUsed, mined min) × 1.3))

| step | gasUsed | eth_estimateGas | note |
|---|---:|---:|---|
| deploy (SP impl `0xbbbb…5b19` + Admin extension) | 52,389,391 | 52,811,426 | > 2^24: needs reservoir (EIP-8037); mined minimum 52,399,391 by binary search; limit 68,654,854 |
| freeze (configureRole PAYMASTER_SUPER isActive=false) | 72,722 | 86,371 | |
| pause_0..4 (5 holders = union(holders, OperatorConfigured)) | 38,393–136,325 | | |
| transfer (SP ownership → timelock) | 36,635 | 36,998 | |
| upgrade schedule (Safe approve + exec) | 135,104 / 207,250 | | |
| upgrade execute (upgradeToAndCall + setGlobalPaused(true) + queueGasParams) | 135,104 / 368,675 | | after timelock delay |
| activation schedule | 135,104 / 189,547 | | |
| activation execute (executeGasParams) | 135,092 / 221,940 | | gasParams [440000, 420000, 5000, 340000] |

Full measurements (including the mined-gas search — 27 entries: one 100M probe, then 26 bisection steps — and the reservoir witness for
the deploy) are in `boot/upgrade-simulate.json`.

## Controls: 1 positive, 6 negative (all behaved as expected)

`safeMint_positive`, `safeMint_negative` (RoleNotConfigured after freeze),
`failed_pause_readback`, `cancel_reschedule`, `non_safe_execute`, `early_upgrade`,
`early_activation`.

## Pre-restore readback (gate before un-pausing): PASS

implementation, guardian 0, both timelock operation ids, gasParams, the 5 paused operators —
see `preRestore` in `boot/upgrade-simulate.json`.

## Budgets (wei, at plan gas policy)

| signer | A3a | upgrade | total |
|---|---:|---:|---:|
| deployer | 0.4940 ETH | 1.3891 ETH | **1.8831 ETH** |
| approver | 0.0071 ETH | 0.0143 ETH | 0.0214 ETH |
| executor | 0.0081 ETH | 0.0266 ETH | 0.0347 ETH |

Balances at the pin, before A3a (`a3a-plan/plan.json` pin): deployer `0xb560…df0e`
2.161907553 ETH (nonce 12131), approver 1.0891 ETH, executor 132.78 ETH. The deployer's combined
A3a + upgrade budget of 1.8830836 ETH leaves **0.2788 ETH** of headroom, which is thin.
(`boot/plan.json` records the post-A3a fork state, 2.1600 ETH at nonce 12136. Do not subtract
the combined budget from that figure, because it would count A3a twice.)
Context, not backed by files here: the deployer EOA is shared with other automation. Recompute
nonce-dependent values at execution time and pause that automation first.

## Acceptance boundary (DSR, 2026-10-25, fixed tree 78c8d144)

Accepted as an **unsigned rehearsal package plus offline executor**. It is not an execution packet:
- These runs used repo `af802726`. The executor's RPC deadline was rewritten afterwards (daemon-thread wall clock,
  #536/#537). Offline tests passing on the final code are not a same-tree fork re-run. A new-pin packet must be
  rehearsed again with the final code.
- `boot/` is a plan that continues on the fork after a *simulated* A3a. It is not a live upgrade packet: after A3a
  really executes, the upgrade plan must be regenerated from the live state and reviewed and authorised again.
- 0.2788 ETH is what remains of the *historical* pin balance after the maximum combined budget. It is not the
  current wallet balance. Funding must happen before the new pin is taken.
- No fresh build/EVM/RPC re-run was done at acceptance time.

## Not covered / preconditions

- Execution needs a DSR-reviewed packet **and** a separate go from the author (process status is kept on Seeder CC-125, not here).
- Any change to shared Sepolia state between the pin and execution invalidates this package
  (holder set, nonces, Safe nonce, balances). Rebuild at a fresh pin instead of reusing it.

`SHA256SUMS` covers every file in this directory except itself and this README
(check with `shasum -a 256 -c SHA256SUMS`).
