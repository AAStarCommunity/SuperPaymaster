# Deploy Record — Registry 5.4.1 → 5.4.2 (Sepolia, 2026-07-08)

UUPS in-place upgrade (proxy address unchanged). Owner = `0xb5600060…adf0E`.

## Registry 5.4.1 → 5.4.2 (#324 M-2)

M-2 fix: `exitRole`'s `updateSBTStatus` call is now a **non-fatal low-level call**
(emits `SBTStatusSyncFailed`) so a reverting/paused SuperPaymaster can no longer
deadlock `exitRole` and freeze a user's locked-stake withdrawal. Register path stays
fatal on purpose (atomic rollback). Pure logic fix; no new storage, no reinitializer.

| Item | Value |
|---|---|
| Proxy | `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71` |
| New impl | `0x9e5da7B4461Ff92F9Ea2Ae57bcf749afC812CC00` (was `0x6Af5A2A7…`) |
| impl deploy tx | `0x8d4e543ab0b906bb3750c50ae4f3d4cc6786cf1174a1c556e8315f65976e56c5` |
| upgrade tx | `0x6cdb6ce7ffd6ae91a73c58f96376a0b60d47515f0bf458b15dff6a554db8a50f` |
| Verified | `version() == "Registry-5.4.2"`; owner/staking/sbt/sp/blsAggregator unchanged |
| Runtime | 23,663 / 24,576 (headroom 913) |

## Mainnet-blocker batch — final disposition (Opus-triaged)

| # | Verdict |
|---|---|
| #324 M-2 exitRole deadlock | FIXED + deployed (this record) |
| #210, #255 | already done → closed |
| #206 (exitRole cascade) | premise invalidated (`_isValid` gate) → closed |
| #205 (leaveCommunity) | harm neutralized → closed |
| #323 (minExitFee), #325 (credit N×L), #326 (revenue) | wontfix → closed |

Remaining pre-mainnet work is operational (multisig `setSlashPolicyAdmin`, mainnet
deploy config), not contract code.
