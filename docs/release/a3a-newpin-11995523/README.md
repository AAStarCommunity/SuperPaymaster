# A3a unsigned packet + full-chain rehearsal at Sepolia block 11,995,523 (final code)

Built per the DSR acceptance of 2026-10-25 (CC-125). The DSR asked for a new-pin A3a unsigned packet built from the
final code, together with its rehearsal, hashes and budget. **Nothing here was signed or broadcast.** Every
transaction ran on a local anvil fork.

- Code: `66df75ee` (main, includes #536/#537/#538), dirtyCount 0 in all four runs.
- Engine: foundry nightly `4e8874b2bdc840929585ca73e170993c50a4a531`.
- Pin: block `0xb70983` (11,995,523), hash `0xf55b7d5f…aba9db7`, timestamp 1792988016. At the pin, every
  sender's nonce equals its pending nonce.
- Funding came before the pin, as DSR required: the deployer received +10 ETH before the pin was taken.

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
- Negative controls in `a3a-sim/`: `S4_before_S3`, `wrong_safe_nonce`, `early_execute` and `non_owner_queue`, all refused.

**Budget**: deployer 0.4940 ETH, approver 0.0071 ETH, executor 0.0081 ETH. Balances at the pin: 12.1619, 1.0891 and
122.78 ETH.

## Upgrade rehearsal (not a live packet)

- 16 steps, 1 positive and 6 negative controls, and the pre-restore readback all PASS. The bootstrap and
  independent runs are identical in gasUsed, controls, readback and plan sha.
- Deploying the SP implementation (`0xbbbb…5b19`) uses gas 52,389,391 (> 2^24, so it is RR), with a reservoir witness.
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
`immutable_build_info`, because AST ids differ between toolchains. All four runs used
`A3A_ENGINE_DIR=$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b`. The commands are in `pipeline.log`
(URLs redacted).

## Before execution (gates unchanged)

1. DSR reviews this packet, by `plan.json` sha256.
2. The author gives a separate go for **this sha256**.
3. Nonce exclusivity holds. At the moment of sending, the senders must still be at deployer 12131, approver 7 and
   executor 29, and the Safe at nonce 1. `pre_send` re-reads every nonce and aborts on any drift. Automation that
   shares the deployer must be paused first.
4. Any other state drift means a rebuild at a new pin.

`SHA256SUMS` covers every file here except itself and this README (`shasum -a 256 -c SHA256SUMS`).
