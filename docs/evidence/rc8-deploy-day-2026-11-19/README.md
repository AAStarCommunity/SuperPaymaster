# rc.8 deploy-day evidence, Sepolia fork (2026-11-18/19)

All runs used a LOCAL anvil fork of Sepolia: nightly 4e8874b, `--hardfork amsterdam`, Tenderly upstream through a
loopback proxy scaffold that is not in the repository. The only real-chain calls were read-only. No transaction was
sent to any real chain. Endpoint URLs and keys are absent: hostname scans returned 0 hits in every directory.

| Directory | SP head | What it proves |
|---|---|---|
| `e2e-sepolia-pop-1d8ec2fa/` | main 1d8ec2fa | First end-to-end PoP flow: DVT real export (ae9390b1) → converter → broadcast → on-chain PoP 3/3 → checker 188/188, via both method (a) and method (b). `gas-table.txt` has the per-tx gas for all 97 txs under Amsterdam. `phase3/` has the EIP-8037 regular/state split: the largest regular-gas portion is 807,489 (SP impl, total 60,155,369); the Paymaster's regular portion is 241,588. |
| `e2e-sepolia-ddf-e6f5c7a8/` | e6f5c7a8 | Part B stopped on three driver bugs, all fixed later. **`simulate-fullseq-alchemy.txt`: real Sepolia `eth_simulateV1` of the full 97-tx sequence (Alchemy, head 12163425) succeeded, and the 7 large CREATEs plus H have gas exactly equal to nightly forge's simulation.** |
| `final-deploy-day-49caaa50/` | 49caaa50 | **Final acceptance.** A fresh agent ran only the HANDOFF commands, with no command edits: steps 1–8 all passed, checker `SUMMARY 189 passed, 0 failed, 189 total`. The price gate had a margin of 1039.8 s with no time manipulation, and the real-chain gas gate matched all 8 targets. `worktree-leftovers/` holds the deployed config and broadcast receipts, copied after the archive; they are not covered by its SHA256SUMS. |
| `final-deploy-day-f38f0526/` | f38f0526 | Steps 1–5 re-checked with endpoint URLs given only as `*_FILE` inputs: the same expected lines; a URL in an input is refused. |

Fork-only manipulations, where used, are logged in each directory's `fork-manipulation.log`.
`e2e-sepolia-pop-1d8ec2fa/OMITTED.txt` records the one truncated file.
