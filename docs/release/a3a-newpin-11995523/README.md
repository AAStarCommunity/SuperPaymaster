# A3a unsigned packet + full-chain rehearsal at Sepolia block 11,995,523 (final code)

Built per the DSR acceptance of 2026-10-25 (CC-125). The DSR asked for a new-pin A3a unsigned packet built from the
final code, together with its rehearsal, hashes and budget. **Nothing here was signed or broadcast.** Every
transaction ran on a local anvil fork.

- Code: `66df75ee` (main, includes #536/#537/#538), dirtyCount 0 in all four runs.
- Engine: foundry nightly `4e8874b2bdc840929585ca73e170993c50a4a531`.
- Pin: block `0xb70983` (11,995,523), hash `0xf55b7d5f…aba9db7`, timestamp 1792988016. `plan` refuses unless
  every sender's nonce at the pin equals its pending nonce (`deployer_nonce_pending` /
  `<sender>_nonce_pending`, `script/a3a/a3a_exec.py:679,706`). The plan was produced, so the check passed then.
  The pending values themselves are not recorded separately.
- Funding came before the pin, as DSR required. In the previous packet
  (`../sp-upgrade-a6e/evidence-11983550/a3a-plan/plan.json`) the deployer pin was nonce 12131 with
  2,161,907,553,052,084,158 wei. Here it is nonce 12131 with 12,161,907,553,052,084,158 wei, exactly +10 ETH at the
  same nonce. The funding transaction itself is not part of this bundle.

| dir | what | status |
|---|---|---|
| `a3a-plan/` | **A3a packet**: `plan.json` sha256 `9b1e2e01dbd092ec2e3fdb21bca51e29c2ce4606cc6cf06126b9063e7cdcd1ad`. Built with its own rehearsal | PASS |
| `a3a-sim/` | independent `simulate --plan` of the frozen A3a packet | PASS |
| `boot/` | upgrade rehearsal that continues on the fork after the simulated A3a. Upgrade plan sha256 `a595b7ba4fb6fe448dccaa78b62d105dff4bcff8195353c12268f7d4e1d9bf5a` | PASS |
| `indep/` | independent re-derivation and run of the frozen upgrade plan, with A3a replayed from the original pin | PASS |

All four relay logs contain only `refused eth_gasPrice` and the teardown marker.

## A3a packet

| step | sender | nonce | gas limit | fork gasUsed |
|---|---|---:|---:|---:|
| S1 | deployer `0xb560…df0e` | 12131 | 63,620 | 38,582 |
| S2 (TimelockController deploy) | deployer | 12132 | 12,100,190 | 9,233,390 |
| S3 (APNTsCapped deploy) | deployer | 12133 | 12,034,883 | 9,183,549 |
| S4 | deployer | 12134 | 170,766 | 130,258 |
| S5a Safe approveHash | approver `0x8c34…73d6` | 7 | 178,548 | 135,104 |
| S5b Safe execTransaction | executor `0x8716…fb48` | 29 | 249,382 | 189,163 |
| S6a Safe approveHash | approver | 8 | 178,548 | 135,104 |
| S6b Safe execTransaction | executor | 30 | 157,843 | 107,554 |
| S7 | deployer | 12135 | 328,269 | 246,269 |

All A3a steps are ≤ 2^24 (R0), so none of them uses the reservoir.
- Safe tx hashes: `0x65f033ab…6cd2a0`, `0x7c762ba6…7001ec` (Safe nonces 1, 2).
- Timelock operation id: `0xa8c50665…cebc40`.
- Timelock roles: PROPOSER, EXECUTOR and CANCELLER = Safe; DEFAULT_ADMIN = the timelock itself.
- Negative controls in `a3a-sim/`, all behaved as expected:
  - `S4_before_S3`: executor refusal, nothing sent.
  - `wrong_safe_nonce`, `early_execute`, `non_owner_queue`: mined transactions that reverted. The fork state and
    nonces were restored afterwards.

**Budget**: deployer 0.4940 ETH, approver 0.0071 ETH, executor 0.0081 ETH. Balances at the pin: 12.1619, 1.0891 and
122.78 ETH.

## Upgrade rehearsal (not a live packet)

- 16 steps, 1 positive and 6 negative controls, and the pre-restore readback all PASS.
- The bootstrap and independent runs match on per-step gasUsed, control identities and outcomes, pre-restore
  readback and plan sha. Block timestamps, block hashes, some transaction hashes and timestamp-bearing event data
  differ, because each run mines its own fork blocks.
- Deploying the SP implementation (`0xbbbb…5b19`) uses gas 52,389,391 (> 2^24, so it is RR), with a reservoir witness.
- The SP implementation is compiled from the executor's pinned candidate `fbd74fb1` (#513 merge; `CANDIDATE` in
  `script/upgrade/sp_upgrade_exec.py:21`), not from `66df75ee`. The upgrade plans record that commit as
  `rebuild.commit`. Between the two commits, `contracts/src` and `foundry.toml` are byte-identical
  (`git diff --quiet fbd74fb1 66df75ee -- contracts/src foundry.toml`), so the implementation bytecode is the same.
  The two commits do differ elsewhere: docs, scripts, workflows, contract tests and dependency lockfiles. None of
  those are inputs to the implementation's compilation.
- Upgrade budget: deployer 1.3891 ETH. Total deployer need, A3a plus upgrade: **1.8831 ETH, against 12.1619 ETH**.
- Per the DSR boundary, `boot/` continues after a **simulated** A3a. Once A3a has really executed, the upgrade plan
  must be regenerated from the live state, then reviewed and authorised again.

## Reproduce: build prerequisites

The executor rebuilds the HEAD archive with stable forge 1.7.1 and compares the result to local `out/`. Local `out/`
must therefore come from the same toolchain, with full build-info:

```sh
rm -rf out cache && FOUNDRY_PROFILE=default ~/.foundry/bin/forge build --offline --build-info --ast
```

A build with nightly forge, or without `--build-info --ast`, fails `rebuild_*_immutableReferences` or
`immutable_build_info`. During preparation both failures occurred, so these gates do fire, but the logs of those
attempts are not part of this bundle. `pipeline.log` records only stage labels, timestamps and exit codes. The
commands run were:

```sh
export A3A_ENGINE_DIR=$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b   # engineCommit is recorded in each simulate.log
python3 -B script/a3a/a3a_exec.py plan --rpc-file <archive-rpc-file> --block 11995523 --out a3a-plan
python3 -B script/a3a/a3a_exec.py simulate --rpc-file <archive-rpc-file> --plan a3a-plan/plan.json --out a3a-sim
python3 -B script/upgrade/sp_upgrade_exec.py simulate --rpc-file <archive-rpc-file> --a3a-plan a3a-plan/plan.json --out boot
python3 -B script/upgrade/sp_upgrade_exec.py simulate --rpc-file <archive-rpc-file> --a3a-plan a3a-plan/plan.json \
  --plan boot/plan.json --out indep
```

## Before execution (gates unchanged)

1. DSR reviews this packet, by `plan.json` sha256.
2. The author gives a separate go for **this sha256**.
3. Nonce exclusivity holds. At the moment of sending, the senders must still be at deployer 12131, approver 7 and
   executor 29, and the Safe at nonce 1. Before each step, `pre_send` (`script/a3a/a3a_exec.py:1332-1336`)
   requires that the sender's latest nonce equals its pending nonce, that it equals the step's planned nonce, and
   that the Safe nonce equals the planned value. Otherwise it stops. This is the executor's guard. The rehearsals
   ran it before every step on the local fork (`a3a_exec.py:1422`); live sending remains disabled. Automation that shares the deployer must be
   paused first.
4. Any other state drift means a rebuild at a new pin.

`SHA256SUMS` covers every file here except itself and this README (`shasum -a 256 -c SHA256SUMS`).
