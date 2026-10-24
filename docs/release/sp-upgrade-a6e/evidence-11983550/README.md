# Safe A6e upgrade package — fork evidence at Sepolia block 11,983,550

Unsigned package for CC-125 deliverable 1 (DSR ruling d6d67a51: Safe A6e route).
Nothing here was signed or broadcast; every transaction below ran on a local anvil fork
(engine foundry nightly `4e8874b2bdc840929585ca73e170993c50a4a531`, EIP-8037 reservoir-correct)
pinned to block `0xb6dabe` / hash `0x77ab0a0b…cec01b8af4`.

| dir | what |
|---|---|
| `a3a-plan/` | A3a plan (timelock 0xCCdF…C34B bootstrap), sha256 `adf74bf3…cf059`; must execute first |
| `boot/` | bootstrap run: builds the upgrade plan (sha256 `81ceece1…e826e`) and simulates A3a + upgrade |
| `indep/` | independent `simulate --plan` run of the frozen `boot/plan.json` + same A3a plan |

Both runs: repo commit `af802726`, dirty 0, status PASS, phases `a3a` → `upgrade`.
The independent run reproduces the bootstrap exactly: identical gasUsed on all 16 upgrade
steps, the same 7 negative controls, identical pre-restore readback. `relay.log` in every
run contains only `refused eth_gasPrice` and the teardown marker (no abandoned/failed
upstream request). `engine.stderr` empty.

## Upgrade steps (gas limit = ceil(max(estimate, local estimate, fork gasUsed, mined min) × 1.3))

| step | gasUsed | eth_estimateGas | note |
|---|---:|---:|---|
| deploy (SP impl `0xbbbb…5b19` + Admin extension) | 52,389,391 | 52,811,426 | > 2^24: needs reservoir (EIP-8037); mined minimum 52,399,391 by binary search; limit 68,654,854 |
| freeze (configureRole PAYMASTER_SUPER isActive=false) | 72,722 | 86,371 | |
| pause_0..4 (5 holders = union(holders, OperatorConfigured)) | 36k–136k | | |
| transfer (SP ownership → timelock) | 36,635 | 36,998 | |
| upgrade schedule (Safe approve + exec) | 135,104 / 207,250 | | |
| upgrade execute (upgradeToAndCall + setGlobalPaused(true) + queueGasParams) | 135,104 / 368,675 | | after timelock delay |
| activation schedule | 135,104 / 189,547 | | |
| activation execute (executeGasParams) | 135,092 / 221,940 | | gasParams [440000, 420000, 5000, 340000] |

Full measurements (including the 26-point mined-gas search and the reservoir witness for
the deploy) are in `boot/upgrade-simulate.json`.

## Negative controls (all behaved as expected)

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

Pinned balances: deployer `0xb560…df0e` 2.1600 ETH (nonce 12136), so the deployer total of 1.8831 ETH leaves only **0.2769 ETH** of headroom. Re-check before executing. Approver 1.089 ETH, executor 132.78 ETH.
The deployer EOA is shared with other automation, so nonce-dependent values must be
recomputed at execution time, with that automation paused first.

## Not covered / preconditions

- Execution needs a DSR-reviewed packet **and** a separate go from the author. A2/A2a/A3a stay HOLD-R-AMS.
- Any change to shared Sepolia state between the pin and execution invalidates this package
  (holder set, nonces, Safe nonce, balances). Rebuild at a fresh pin instead of reusing it.

`SHA256SUMS` covers every file in this directory except itself and this README.
