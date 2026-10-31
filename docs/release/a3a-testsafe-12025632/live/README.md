# A3a live send — packet 0bb821d1, steps S1–S5b

Author go 2026-10-31 for plan.json sha256
`0bb821d18f60495d9b576763923d456a8e5f64277be40549da24643de5083151` (`../a3a-plan/plan.json`).
Sent unattended by `script/a3a/a3a_send.py` from a clean checkout of `cd9aa1c4`, one step per run.
Before S1, at block 12,032,373, the sender nonces were 12131 / 97 / 752 and the Safe nonce was 1, as packed.

| step | tx | block | gasUsed | rehearsal pilot |
|---|---|---:|---:|---:|
| S1 | `0x33ec86044f8b0238bb192c610ebfb8924f28665e688764ac83b83f7b5d908d4b` | 12,032,398 | 38,582 | 38,582 |
| S2 TimelockController | `0xe2c6b4276e8be5ea26057499b924c2550d29ff983fccac790784d715c117d48c` | 12,032,424 | 9,233,390 | 9,233,390 |
| S3 APNTsCapped | `0x93e0fe11f4de1cd88b087b5ef9b40fcc4ee9355d940e169825f23d6c2a721abe` | 12,032,447 | 9,183,549 | 9,183,549 |
| S4 | `0x80e2d82efc23b9843ae5426492862a250e77c424a3054d4895e3e03dbbfc6b56` | 12,032,472 | 130,258 | 130,258 |
| S5a approveHash | `0xc484848671e105981bb58e0dc6fb2cf8c411127a3f9d491ad5125938d5b0686b` | 12,032,495 | 135,104 | 135,104 |
| S5b execTransaction (schedule) | `0x29920acb5a6742ce2608f43b7eb130630e9c68598d4b3e68a295b31b0f3594e8` | 12,032,520 | 189,151 | 189,151 |

All six receipts have status 0x1, and every sender exit code was 0.

- TimelockController: `0xCCdF8e0D29Fb2c3061910D79484a2b653757C34B`.
- APNTsCapped: `0x9Eb17FAc022557F64924aA2F9E018dB3A330e1E7`.
- Operation `0xa8c50665…bc40` is Waiting. Its ETA is 1,793,606,676 (2026-11-02 08:04:36 UTC), which is the S5b block time plus 172,800 s.

## Files

- `S*/` holds each step's sender output: `unsigned.json`, `decoded.json`, `broadcast.json`, `receipt.json`, `result.json`, `signed.raw` and the run's stdout.
  - `signed.raw` is the broadcast transaction, which is public on chain.
  - No step wrote stderr.
- The sender also saves `plan.reviewed.json` for each step. All six copies hashed to `0bb821d1…` and were left out, since the plan is already in this repository.
- `readback-12033089/` holds `script/evidence/a3a-live-readback.sh` run at commit `3761c01f` from a clean tree, at block 12,033,089. Its `verdict.txt` is `READBACK PASS`.
  - It reads from two different endpoints, Alchemy and publicnode; only their hostnames are recorded. Both return the same block hash before and after the reads, and the same value for every query.
  - The timelock role sets are rebuilt from every RoleGranted / RoleRevoked / RoleAdminChanged event since deployment, using both RPCs' logs (4 grants, no revokes or admin changes). They equal `plan.json` `roles` exactly, so an extra member would fail.
  - It also checks that the timelock had no code the block before S2. It checks operation state, ETA = S5b block time + 172,800, minDelay, the APNTsCapped cap, supply, owner and pending owner, the Safe nonce and the three sender nonces.
- `controls/` holds four runs of the same script that must fail. `SUMMARY.txt` lists their exit codes.
  - At block 12,032,510, before S5b: exit 1. Exactly the four S5b-dependent values mismatch.
  - With a plan copy whose CANCELLER set is emptied, which models an extra on-chain member: exit 1 on the role-set comparison.
  - With the same endpoint passed twice: exit 2.
  - With the tag `latest` instead of a block number: exit 2.

## Remaining

S6a, S6b and S7 run after the ETA under the same go, and their records will be added here. A3a does not upgrade SP: the SP proxy stays 5.4.2, and S7 only queues APNTsCapped behind the 7-day token delay.
