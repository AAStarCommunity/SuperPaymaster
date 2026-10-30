# A3a unsigned packet — Sepolia test Safe, block 12,025,632

Author decision 2026-10-30 (CC-125 / CC-127): for Sepolia testing, A3a uses the test Safe
`0x16dF788ed4ed1Fc384e52dC832A6a6C3A23bdEBf` (Safe 1.4.1, 2-of-3; owners Jammy `0xF7Bf…642C`, David
`0xE3D2…008d`, `0x92a3…45b3`; guard slot zero and no modules, both checked at the pin). Executor = Jammy,
approver = David. This Safe becomes PROPOSER / EXECUTOR / CANCELLER of the new TimelockController and minter /
capGuardian of APNTsCapped. **Sepolia only**; a production deployment uses a different Safe and signers. It
supersedes `../a3a-newpin-11995523/` (old Safe `0x51eD…E114`); that packet, `9b1e2e01…`, is void.

**Nothing here was signed or broadcast.** Both runs are local anvil forks (engine nightly `4e8874b`).

- Code: `cd9aa1c4` (branch `cc125/a3a-test-safe`), dirtyCount 0. Contract sources are those of main.
- Pin: block 12,025,632. Senders: deployer `0xb560…df0e` nonce 12131, David nonce 97, Jammy nonce 752; Safe nonce 1.
- `a3a-plan/`: **plan.json sha256 `0bb821d18f60495d9b576763923d456a8e5f64277be40549da24643de5083151`**, built with its own rehearsal — PASS.
- `a3a-sim/`: independent `simulate --plan` of the frozen packet — PASS. Negative controls: `S4_before_S3`
  (executor refusal), `wrong_safe_nonce`, `early_execute`, `non_owner_queue` (mined reverts, state restored).
- Both relay logs contain only `refused eth_gasPrice` and the teardown marker (no retries were needed).

| step | sender | nonce | gas limit |
|---|---|---:|---:|
| S1 | deployer | 12131 | 63,620 |
| S2 TimelockController deploy | deployer | 12132 | 12,100,190 |
| S3 APNTsCapped deploy | deployer | 12133 | 12,034,883 |
| S4 | deployer | 12134 | 170,766 |
| S5a approveHash | David | 97 | 178,548 |
| S5b execTransaction (schedule) | Jammy | 752 | 249,365 |
| — 48 h timelock — | | | |
| S6a approveHash | David | 98 | 178,548 |
| S6b execTransaction (execute) | Jammy | 753 | 157,826 |
| S7 | deployer | 12135 | 328,269 |

Budget: deployer 0.4940 ETH, David 0.0071 ETH, Jammy 0.0081 ETH. Safe tx hashes `0xc8ad70ec…` (Safe nonce 1),
`0x5feeca3f…` (Safe nonce 2).

## Execution
Only with the author's go for this sha256. One step per `a3a_send.py` run, from a clean checkout of `cd9aa1c4`,
in unattended mode (`--password-file` in a 0700 directory, `--confirm "SEND <step> 0bb821d18f60"`). Every other
gate of the sender still applies: reviewed sha256, pre_send before signing and again before broadcast, local decode
check, no resend or repricing. Any state drift (nonces, Safe nonce, balances) means a rebuild at a new pin.
