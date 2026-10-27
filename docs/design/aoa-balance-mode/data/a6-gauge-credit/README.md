# A6 gauge: credit-state controls (a6-gauge/2, A4-G1)

> **Local Anvil only. This is not A6 data.** Nothing here was sent to a public chain. The only
> keys used are anvil's well-known dev keys (redacted in the archived copies). A and B are a direct
> Anvil endpoint and a pass-through proxy over the **same** node, so every run records
> `allowSameEndpointLocal: true` and `protocolConformant: false`.

## What this shows

`collector.mjs` (schema `a6-gauge/2`) records the operator token's credit state in the Passport
invariant: `creditPolicy`, `hasPendingPolicy`, `pendingPolicy`, `pendingPolicyEta`, `policyEpoch`.
It also hashes the token's on-chain `EXTENSION()` and SP's `ETH_USD_PRICE_FEED()`, no longer the
config addresses. `validate.mjs` rejects a /2 run whose policy is not OFF or has a change queued
(A4 Passport C2/C3, `docs/design/aoa-balance-mode/aoa-sp02-a4-passport.md` §2).

| run | state set before the run | Passport `credit` | validator |
|---|---|---|---|
| `credit-off` | none (fresh deploy) | policy 0, nothing queued, epoch 0 | exit 0, accepted |
| `credit-queued` | `queueCreditPolicy(2)` by the community owner (`queue.log`) | policy 0, **queued 2**, epoch 0 | exit 1: `passport credit policy change is queued` |
| `credit-on` | 48 h warp, then `executeCreditPolicy()` (`execute.log`) | **policy 2**, nothing queued, epoch 1 | exit 1: `passport credit policy is not OFF` |

Every collector run completed (exit 0, 1/1 matched triplet). The errors appear twice because the start and end
Passports are both checked. Each rejection comes from its own check. Disabling the policy check lets `credit-on` pass and
leaves `credit-queued` rejected. Disabling the queued check does the reverse. `credit-off` stays accepted in both cases.

`credit-off` exported with `to-aoa-m3-receive.mjs` and checked with DSR
`scripts/aoa_m3_check.py --expected 1` gives `OFFLINE_STRUCTURE_PASS` (runType `rehearsal`).

Schema downgrade (Codex finding): relabelling a credit-ON run as `/1` and dropping the credit fields
must not make it conformant. `script/a6-collector/negative-controls/credit-schema-downgrade.py`
checks this offline on synthetic variants of the n50 run. The /1 variant fails with exactly
`conformant run requires a6-gauge/2 (credit OFF recorded)`, and the same data as /2 with credit
OFF is accepted. The exporter marks `formal-candidate` only for /2.

## What was run

| item | value |
|---|---|
| collector head (`run_start.head`, `collectorDirty: false` in all three runs) | `0fdd35e6` |
| forge / anvil | 1.7.1 |
| node / viem | v24.21.0 / 2.52.2 |
| chain | fresh `anvil --port 8545 --chain-id 31337`, `./deploy-core anvil --force`, `./prepare-test anvil`, `deploy-baselines.mjs` |
| driver | `credit-run.sh.txt` (dev key redacted; `--count 1 --b-max 1`) |

## Not covered

- The legacy `a6-gauge/1` runs under `data/a6-gauge-local/` still validate with their recorded exit
  codes. They now carry the note `credit policy not recorded, so this run does not show credit OFF`.
- Per-op reservation records (`creditReservationOf(opHash, sender)`, C6) and the event scans C4/C7
  are not part of this change. Policy OFF over the window plus no queued change rules out new
  credit reservations by this token. It says nothing about reservations made before the window.
- Only the operator's own token is read. A run that uses more tokens would need each one recorded.
