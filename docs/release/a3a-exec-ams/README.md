# A3a under Amsterdam — reviewed-executor plan and independent fork simulation (R-AMS-3) — NOT EXECUTED

Executor: `script/a3a/a3a_exec.py` at repo commit `5cff0037` (clean tree, `dirtyCount: 0` in both log headers;
outputs were written outside the repository and copied here afterwards).
Engine: foundry nightly 926eb1d anvil, `--hardfork amsterdam --order fifo`, authenticated through `anvil_nodeInfo`
(fork URL = the executor's loopback read-only relay, fork block, `Amsterdam`, `fifo`, chainId 11155111).
**Nothing was signed or broadcast.** `sign`/`send` refuse with rc=3.

| dir | command | result |
|---|---|---|
| `plan-11980710/` | `plan --block 11980710` — read-only preconditions at the pin, unsigned S1–S7, plus a calibration simulation | PASS |
| `simulate-11980710/` | `simulate --plan plan-11980710/plan.json` — independent rerun of the frozen plan (no re-planning; plan rebuilt from the pin and compared field by field; all 9 steps + 4 negatives required) | PASS |

`plan.json` sha256 `c90877f36736797e3257310170fbcfd7591236cc0a75719cee9a7a8f2f044ad1`. `relay.log` in both runs holds only
`refused eth_gasPrice` (the only line the relay-evidence gate tolerates).

## Preconditions at the pin (block 11,980,710)

| sender | address | nonce (block == pending) | balance | budget at fee caps |
|---|---|---:|---:|---:|
| deployer (S1–S4, S7) | `0xb5600060…df0e` | 12131 | 2.1619 ETH | 0.49395 ETH |
| approver (S5a, S6a) | `0x8c349925…73d6` | 7 | 1.0891 ETH | 0.00714 ETH |
| executor (S5b, S6b) | `0x871608cb…fb48` | 28 | 132.78 ETH | 0.00814 ETH |

Safe nonce 1 (Safe tx hashes also verified on-chain with `getTransactionHash`); eth_config activation 1791294816,
forkId 0x6c1d9423, `next` null; empty code at both CREATE targets.

## Gas (Amsterdam), gasLimit = ceil(max(eth_estimateGas, local estimate, fork gasUsed) × 1.3)

| step | eth_estimateGas | local estimate | fork gasUsed | gasLimit | v4 packet (invalid) |
|---|---:|---:|---:|---:|---:|
| S1 cancelAPNTsTokenChange | 48,938 | 48,641 | 38,582 | 63,620 | 41,108 |
| S2 deploy TimelockController | 9,307,838 | 9,233,390 | 9,233,390 | 12,100,190 | 1,792,211 |
| S3 deploy APNTsCapped | 9,257,602 | 9,183,549 | 9,183,549 | 12,034,883 | 1,806,663 |
| S4 transferOwnership | 131,358 | 130,258 | 130,258 | 170,766 | 62,709 |
| S5a approveHash | 137,344 | 136,876 | 135,104 | 178,548 | 68,619 |
| S5b execTransaction(schedule) | 191,832 | 191,754 | 189,163 | 249,382 | 128,885 |
| S6a approveHash | 137,344 | 136,876 | 135,104 | 178,548 | 68,619 |
| S6b execTransaction(execute) | 121,417 | 120,616 | 107,554 | 157,843 | 117,481 |
| S7 setAPNTsToken | 252,514 | 249,820 | 246,269 | 328,269 | 98,707 |

The S1 local estimate 48,641 equals the minimum viable gas measured independently on 2026-10-22
(`a3a-packets-RAMS-INVALIDATION.md`). All limits ≤ 2^24, so every step runs in the R0 regime. The estimates hold for this pin;
`pre_send` must re-check on-chain state (code at targets, sender nonce latest == pending == planned, predecessor read-back)
before any future real send.

## Read-backs and negatives (`simulate.json` in both dirs)

- S2: minDelay 172800; exact role sets from RoleGranted/RoleRevoked/RoleAdminChanged — PROPOSER/EXECUTOR/CANCELLER = {Safe}, DEFAULT_ADMIN = {timelock itself} (OZ self-admin; no external admin).
- S3: APNTsCapped runtime equals the build artifact outside the 7 EIP712 immutable ranges; each immutable value-checked; cap 10,000,000e18, minter, cap guardian, owner, totalSupply 0.
- S4 pendingOwner == timelock; S5b op Waiting at the planned ETA; S6b after ≥48h owner == timelock, op Done; S7 pendingAPNTsToken == APNTsCapped, eta = block.timestamp + `APNTS_TOKEN_TIMELOCK` (604,800, read from the contract).
- Negatives, each a **real transaction on the fork** under a snapshot (receipt status 0, exact revert, then snapshot restored):
  wrong Safe nonce (`GS025`), early timelock execute, non-owner S7 (`OwnableUnauthorizedAccount`). The sender EOA nonce advances when the
  reverted tx is mined (normal chain behaviour) and the Safe nonce does not; both are restored. S4-before-S3 is an **executor refusal**
  by `pre_send` (an address with no code accepts the call on-chain, so no chain revert exists).

## Validity

Identity fields hold while deployer nonce = 12131, approver = 7, executor = 28 and Safe nonce = 1. **Execution requires DSR review of
this plan and the author's separate go**; sign/send are not implemented.
