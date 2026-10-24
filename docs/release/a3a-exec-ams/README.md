# A3a under Amsterdam — reviewed-executor plan and fork simulation (R-AMS-3) — NOT EXECUTED

Produced by `script/a3a/a3a_exec.py plan` (read-only against the archive RPC) at Sepolia block **11,980,615**.
`plan` also runs the isolated simulation on foundry nightly 926eb1d (`--hardfork amsterdam --order fifo`)
through a loopback read-only relay. **Nothing was signed or broadcast.** `sign`/`send` refuse with rc=3 by design.

| file | content |
|---|---|
| `plan-11980615/plan.json` + `.sha256` | unsigned S1–S7 txs (to/data/value/nonce/chainId/gas/fee caps), pinned preconditions, roles, runtime identity, budget |
| `plan-11980615/simulate.json` | per-step receipt + gasUsed + read-backs; 4 negative controls |
| `plan-11980615/simulate.log` | header (engine commit, repo commit `d3ca3e75`, dirty count, pinned block; RPC redacted) + per-step lines |
| `plan-11980615/relay.log` | methods the relay refused (only `eth_gasPrice`, which the fork engine probes) |
| `plan-11980615/engine.stderr` | anvil stderr (sees only the loopback relay URL) |

`dirtyCount: 1` in the header is this output directory itself (`plan.json` is written before the simulation starts).

## Gas (Amsterdam), margin 1.3

| step | eth_estimateGas | fork gasUsed | gasLimit | v4 packet gasLimit (pre-Amsterdam, invalid) |
|---|---:|---:|---:|---:|
| S1 cancelAPNTsTokenChange | 48,938 | 38,582 | 63,620 | 41,108 |
| S2 deploy TimelockController | 9,307,838 | 9,233,390 | 12,100,190 | 1,792,211 |
| S3 deploy APNTsCapped | 9,257,602 | 9,183,549 | 12,034,883 | 1,806,663 |
| S4 transferOwnership | 131,358 | 130,258 | 170,766 | 62,709 |
| S5a approveHash | 137,344 | 135,104 | 178,548 | 68,619 |
| S5b execTransaction(schedule) | 191,832 | 189,163 | 249,382 | 128,885 |
| S6a approveHash | 137,344 | 135,104 | 178,548 | 68,619 |
| S6b execTransaction(execute) | 121,417 | 107,554 | 157,843 | 117,481 |
| S7 setAPNTsToken | 252,514 | 246,269 | 328,269 | 98,707 |

Every gasLimit is ≤ 2^24 (16,777,216): all steps are in the R0 regime (no reservoir). Budget at the plan's fee caps:
0.494 ETH; deployer balance at the pin 2.16 ETH.

## Read-backs and negatives (all in `simulate.json`)

- S2: minDelay 172800; exact role sets — PROPOSER/EXECUTOR/CANCELLER = {Safe}, DEFAULT_ADMIN = {timelock itself} (OZ self-admin; no external admin).
- S3: APNTsCapped runtime equals the build artifact outside the 7 EIP712 immutable ranges; each immutable value-checked (hashedName/Version, chainId, cachedThis = predicted address, domain separator, ShortStrings); cap 10,000,000e18, minter, cap guardian, owner, totalSupply 0.
- S4 pendingOwner == timelock; S5b op Waiting with planned ETA; S6b after ≥48h owner == timelock, op Done; S7 pendingAPNTsToken == APNTsCapped with eta = block.timestamp + the SP's `APNTS_TOKEN_TIMELOCK` (604,800, read from the contract).
- Negatives: S4-before-S3 is an **executor refusal** (calling an address with no code succeeds on-chain, so no chain revert exists); wrong Safe nonce, early timelock execute and non-owner S7 revert with exact payloads, sender and Safe nonces unchanged.

## Validity

Identity fields (addresses, op id, Safe tx hashes) hold only while deployer nonce = 12131 and Safe nonce = 1 (both read at the pin, block == pending). The gas numbers hold for the Amsterdam rules at this block. **Execution requires DSR review of this plan and the author's separate go**; the plan hash in `plan.json.sha256` is what a future reviewed signer would sign.
