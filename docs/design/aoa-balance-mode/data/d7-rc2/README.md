# D7 JS E2E — rerun on the exact v5.5.0-rc.2 pin (local anvil)

DSR gate ① (Seeder CC-125 `a1c50793`): D7 was last independently accepted at `51c11e4f` / #438
(`a2be50b3`). Since then `contracts/src` changed in 10 files (`4d57a1c6` postOp fee snapshot,
`2d66867f` rc1 gate hardening, `3039ff6f` comment only), so the D7 suite was rerun on the pin.

**Local anvil only. Not public-chain evidence, not A6 data.**

## Coordinates

| item | value |
|---|---|
| contracts deployed from | `1ac0e1c595dc84e684b540ca6a936168e922194f` (tag `v5.5.0-rc.2`), worktree, `./deploy-core anvil --force` + `./prepare-test anvil` |
| E2E harness | branch `cc125/d7-chainid-harness` @ `68dfdccb` (= `b0ac4920` + harness fixes `e8913770`, `68dfdccb`; no `contracts/` change) |
| chain | fresh `anvil 1.7.1 --chain-id 31337 --hardfork prague`; fresh-chain control in `env.txt` (block 0, deployer nonce 0) |
| node | v24.21.0 |

## Procedure (`steps.txt`)

1. Fresh anvil → `deploy-core anvil --force` (rc 0) → `prepare-test anvil` (rc 0, T-4 read-back 50/0).
2. Three SimpleAccounts via `simpleAccountFactory.createAccount(anvil#0, salt 0/1/2)` (the suite needs
   `TEST_AA_ACCOUNT_ADDRESS_A/B/C`; DSR's #438 acceptance used the same kind of env aliases).
3. `ENV_FILE=e2e.env bash script/gasless-tests/run-all-e2e-tests.sh` → `03-e2e.clean.log`.
   `E2E_BROADCAST_RPCS` points at an unreachable local port on purpose: pointing it at the same
   anvil double-sends every raw tx and self-induces "nonce too low"; leaving it empty falls back to
   the Sepolia public node.
4. `evm_increaseTime 172900` + `evm_mine` (test-case-4 queues `creditPolicy=AUTO` behind the 48h
   timelock), `SuperPaymaster.updatePrice()` (setup-gasless compares the price cache against the
   *wall clock*, which is wrong after a warp), then `setup-gasless.js`, `test-case-4`, `test-case-2`.

## Result

Suite: **37 scripts — 31 PASS / 4 FAIL / 2 SKIP** (`03-e2e.clean.log` summary; identical in two
independent fresh-chain runs). After the warp: **test-case-4 PASS** (`05-tc4-after-warp.log`:
debt +132.96426 aPNTs, available credit −132.96426, xPNTs balance unchanged).

D7-migrated scripts (scope of the #438 acceptance):

| script | result |
|---|---|
| B4, B5, C1, E3, E4, G1, G3, I1 (the 8 write-path scripts DSR accepted at #438) | PASS |
| test-case-1 (PaymasterV4), test-case-3 (xPNTs2) | PASS |
| test-case-4 (SP credit/debt) | in-suite SKIP (48h timelock, by design); **PASS after warp** |
| test-case-2 (xPNTs1) | **SKIP** — AA account has 0 aPNTs at that point (harness funding); not exercised |

Outside the D7 migration scope (stale scripts, not contract defects; not fixed here):

| script | failure |
|---|---|
| B3 | passes the v1 `aPNTs` to `configureOperator`; 5.5.0 requires a factory-bound v2 token |
| D2 | `setCreditTier(7,0)` → `CreditTiersNotMonotonic()` (Registry rule; G3 already handles it) |
| E1 | `priceFeed()` call reverts with no data on the current SP |
| x402 EIP-3009 | `decimals()` on a token that is not deployed on anvil |

## Harness bugs found by this rerun (fixed on `cc125/d7-chainid-harness`)

1. `makeProvider()` / MPC / x402 signed with chain 11155111 regardless of `CHAIN_ID` → every tx on
   anvil rejected, gasless setup failed.
2. `sendAndWait` and test-case-4's `handleOps` took the nonce from ethers' cached `getNonce()` →
   the next tx reused a just-confirmed nonce (same root cause as #438, missed paths).
3. setup-gasless raised credit tier 1 above tier 2 → `CreditTiersNotMonotonic()` swallowed as
   non-fatal → 100 aPNTs cap → the contract's correct `EXCEEDS_CAP` rejection in test-case-4.

Earlier runs before each fix are not archived here (scratch only); they are described in the
commit messages of `e8913770` and `68dfdccb`.

## Files

`env.txt`, `steps.txt`, `config.anvil.json`, `e2e.env.redacted` (anvil default keys redacted),
`01-deploy-core.log.gz`, `02-prepare-test.log.gz`, `03-e2e.clean.log` (ANSI stripped),
`04-setup-after-warp.log`, `05-tc4-after-warp.log`, `06-tc2-after-warp.log`,
`anvil.log.redacted.gz` (only the default private-key block and mnemonic redacted; 190 tx hashes kept).
All files are covered by `../../EVIDENCE.sha256`.
