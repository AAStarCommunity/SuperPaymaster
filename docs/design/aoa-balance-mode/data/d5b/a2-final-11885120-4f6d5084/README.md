# A2 all — full fork rehearsal on the final head `4f6d5084` (DSR CC-125 9479dbd8 package ④)

DSR: the 10-15 Mac mini A2a PASS pinned the older script (`a4ceb47a`, script blob `9c836f45`); #485
changed `a2-full-rehearsal.sh` (A1c/A1d now pass `TIMELOCK_DEPLOYMENT_BLOCK`, current blob `996a69c8`)
and the Solidity scripts it calls, so that PASS cannot be extrapolated. This is the rerun on the final head.

**Local anvil fork only.** Every write targets `127.0.0.1`; the public RPCs are used only as
`anvil --fork-url` and for read-only pre-state cross-checks. No transaction was sent to Sepolia.

## Coordinates

| item | value |
|---|---|
| script commit | `4f6d50842c51678f79c1246dde86282f3b37b74f` (`rehearsal.log` L2, no "uncommitted changes") |
| contracts/src vs `v5.5.0-rc.2` `1ac0e1c5` | IDENTICAL (`rehearsal.log` L3) |
| tools (`tool-versions.txt`) | forge 1.7.1, anvil 1.7.1, node v24.21.0; `forge build` (profile.default) before the run |
| fork | Sepolia block **11885120**, hash `0xd86af1c6…64adc3` — same block as the previous generation `../a2-failclosed-reads2-11885120-4f638f61/` |
| endpoint A (fork provider) | Alchemy archive (key not written) |
| endpoint B (independent read-only) | `RPC_URL_X=https://sepolia.gateway.tenderly.co` — see "Deviation" |
| argv / timing / exit (`exit.txt`) | `RPC_URL_X=https://sepolia.gateway.tenderly.co script/evidence/a2-full-rehearsal.sh <env: RPC_URL, PRIVATE_KEY, PRIVATE_KEY_ANNI> 11885120 <this dir> all` — **exit 0** |

## Result

`rehearsal.log` tally: **370 CHECK PASS, 0 CHECK FAIL, 0 `!!!` lines; 65 expected negative controls, all
passed** (`neg-controls.jsonl`: 55 matched by exact revert data, 10 by regex — the regex ones include
process/provenance failures such as NEG-44–49, not only EVM reverts; see `neg.log`). Same counts as the
previous generation (370 / 65). The tally line is
not evidence by itself; the per-step `CHECK` / `TX` / `readback` lines and `receipts.jsonl` are.

## Deviation from the previous generation: endpoint B

The script's default endpoint B (`ethereum-sepolia-rpc.publicnode.com`) has pruned the fork block's
history: `error code 4444: pruned history unavailable: requested 11885120, earliest available 11944027`
(`aborted-attempt2-endpointB-pruned/0-prestate-read-failures.log`). The script failed closed on it
(attempt 2: 368 PASS / 1 FAIL — only the endpoint-B read check; tally in
`aborted-attempt2-endpointB-pruned/rehearsal-tally.txt`). Before switching, Tenderly's public gateway
was probed at block 11885120: `SP.version()` = `"SuperPaymaster-5.4.2"` and block hash
`0xd86af1c6…64adc3`, both equal to endpoint A. Tenderly is a different operator from Alchemy. The fork
block was kept so the result stays comparable with the previous generation.

## Aborted attempts (not evidence)

1. Env file contained only `RPC_URL`; Stage I / A7 needs the owner key to sign the acceptance UserOp →
   `PRIVATE_KEY does not derive OWNER`, exit 1. Operator error; output discarded.
2. Endpoint B pruned (above); only the failure files are kept here.

## Files

All rehearsal outputs as written by the script (`rehearsal.log`, `receipts.jsonl`, `neg-controls.jsonl`,
attestation snapshots, role dumps, per-step logs, …), plus `console.log` (stdout/stderr), `exit.txt`,
`tool-versions.txt`, `aborted-attempt2-endpointB-pruned/`. Private keys and RPC keys were checked
absent (0 hits, including inside `.gz`). Integrity: `EVIDENCE.sha256` in this directory and the main
`../../../EVIDENCE.sha256`.
