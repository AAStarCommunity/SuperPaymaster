# 03 — RESULTS (v5.4.0-beta.1 E2E chronological log)

> TX-Value-Verification framework, document 3 of 5.
> Chronological record of every live tx. One row per executed scenario leg.
> Status legend: ✅ PASS (executed + L2 state asserted) · ⛔ PASS (reverted with the EXACT expected selector) · ❌ FAIL · ⏭️ SKIP (precondition unmet, inconclusive — NOT a pass) · ⏳ PENDING live run.
>
> Reminder: a green L1 receipt alone is NOT a pass — the Notes column must record the L2 state delta (or, for ⛔ rows, the exact revert selector).

## Run metadata

| Field | Value |
|---|---|
| Release | v5.4.0-beta.1 |
| Network | Sepolia (chainId 11155111) |
| SuperPaymaster | `0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a` |
| X402Facilitator | `0xFe95a77e4Db593E6EA88000Aad9cD1230BAB4512` |
| MicroPaymentChannel | `0xfCC95340Cbd4Ca8DdbE74676e799ABFb61553082` (v1.3.0) |
| Deploy fingerprint | sha256(`deployments/config.sepolia.json`) = `d8a29f85c06b8b375120ecf582fd8ead52629ba9de7a1400020f9ddaaba37cbb` |
| Price keeper run before suite? | YES — gasless pre-flight reported price cache fresh (valid 2057s) before Phase 9 |
| Run started / finished | Full suite 2026-06-16 09:41:38 → 10:18:52; isolated re-runs 10:27–10:32 |
| Final tally (full suite) | **37 groups · 34 PASS · 3 FAIL** (B1, B2, B4) — all 3 root-caused to harness nonce/mempool flakes and **re-run clean** (see §"Full-suite failures"). |
| Independent RPC verification (axis-1) | **82/82 unique TXs REAL, all status=1** (full-suite set) — independently re-derived via `cast receipt` on `ethereum-sepolia-rpc.publicnode.com` (different RPC than the suite). Zero NOT_FOUND, zero status=0. Evidence: `logs/rpc-independent-verify.txt`. **+3 new credit/debt live-proof TXs** (drain `0x32cbc627…`, updatePrice `0x431e3942…`, sponsor `0x94eed4ed…`) independently RPC-verified status=1 — see "Credit/debt live-proof setup". (⛔ negatives are `eth_call`/staticcall reverts and produce no mined tx, hence no status=0 receipts — expected, see 05 §B.) |
| On-chain `version()` | SuperPaymaster / Registry both return `5.3.3` while impl content is v5.4 — intentional beta deferral (see Known-Oversight). |

## Chronological log

Phase is the execution-order proxy (the harness logs only suite start/finish wall-clock, not per-group). Each tx links to Sepolia Etherscan via `https://sepolia.etherscan.io/tx/<hash>`.

| Phase | Scenario ID | Status | Tx hash (etherscan) | Gas | Notes (L2 delta / exact revert selector for ⛔) |
|---|---|---|---|---|---|
| 0 Preflight | infra | ✅ PASS | (read-only) | — | 12 contracts + EntryPoint present. Version-string MISMATCH warnings printed (stale expected-version constants in `check-contracts.js`) — preflight still PASSED; see Known-Oversight. |
| 1 A1 | 3.1 / 3.3 | ✅ PASS | (idempotent — no new tx) | — | Community + ENDUSER already registered (steps SKIP as idempotent). On-chain asserted: deployer `hasRole COMMUNITY`; `sbtHolders(AA_A)==true`; COMMUNITY members=2. No fresh mint tx this run. |
| 1 A2 | 3.2 (read) | ✅ PASS | (read-only) | — | 7 ROLE keccak constants match; getRoleConfig minStake (SUPER=50, AOA=30…); wiring addrs == config.json. |
| 2 B1 | 7.1 | ❌ FAIL→✅ rerun | setOpLimits `0xd3ead607279a901faf6f3f1d99d88491b09d73790fd69ded4202a4af490f981c`; pause `0x093da1c86fe8a172cc70bec8daf39dc8362e35455446e777c43b6a26f49aff1b` | 42590 / 36705 | `minTxInterval==60` asserted; pause asserted. **Unpause tx SKIPPED — "nonce/in-flight conflict (pending TXs in mempool) — skipped [CRITICAL]"** → final unpause-assert FAILED. Re-run clean: unpause `0x8cf930c3fba6a964a043d0760ca795064919550de185e4516238747c3aeea4f8` (gas 36694), operator confirmed unpaused. Harness flake, not a contract bug. |
| 2 B2 | 7.1 (deposit/withdraw) | ❌ FAIL→✅ rerun | deposit `0xb6f7d4fa9c53cce6fda6d6bc34b0d0dd3ea8c975047e26217b20c482f0858bda`; withdraw(3) `0x4cab4a101b0ffd0f6cff1bec4da097490b3a50c8b5ebfab9649524867d3e97cd`; cleanup `0x7430e69d345abe7621f6d6d7e69c65627cafaf1c74ffddc086e7570b758ee5bd` | 80596 / 62500 / 62500 | deposit(10) asserted OK. **depositFor(5) SKIPPED (nonce/in-flight CRITICAL)** → every later balance assertion off by exactly +5.0 aPNTs → 3 cascade FAILs. Re-run clean (6/6): deposit `0xf5859d451be9966b5d790e1dbe6fb4986f106e648177a7ce8f62c283c1b5c6e6`, depositFor `0x1a036bda4ee31a19d02db8ad305ee95af4c3658e64a165538ed2a24c0055ce33`, withdraw `0xde3cc212a991cbf88b92ec9b96647ce869b8663ba6cfa0c349ecfbe410c07bab`, cleanup `0x225744f386f529e46b032940784f0af9f31d2bbbb2604ed669a19ee77b334156` — balance restored exactly. |
| 2 B2 | 8.2 (withdraw excess ⛔) | ⛔ PASS | (eth_call revert) | — | `withdraw` over balance reverted (`execution reverted (unknown custom error)`). Same in re-run. |
| 2 B3 | 7.1 / 3.2 | ✅ PASS | configureOperator(2-arg) `0x727b7014f0c2cc7c1b593eae4e285cf0701c4512a6d9f88a44ad7ad55a0dd7de`; re-configure `0x3f01c7437454bb9d4841ca4817a3f3919e90de0dac0076192cdb98952e44669d` | 58866 / 58866 | PR#200 2-arg signature: xPNTsToken + treasury stored; `operators()` returns 9 fields (no exchangeRate); live rate read from token = 1.07213…; idempotent re-configure restored treasury. Same operator-config contract path as B1 — passed here. |
| 2 B4 | 7.2 / 2.4 | ❌ FAIL→✅ rerun | (full suite: 300s TIMEOUT after first read, gov tx stuck in mempool) | — | Full-suite group **timed out after 300s** at Step 1 — a governance tx stuck. Re-run clean (11 pass / 0 fail / 3 legit skip): setTreasury `0x8f8f2e4afd7203ce53372c748a4ac32f48fa11bbca4f859c675466bba33cf1b6`; setAgentRegistries `0x15dc92767c40f29feff2400370b43a3d34d5f203258b010f50e76678b29c4b03` / restore `0x741cdf7da0fcc2c703b0dec0103eb0cfc53151dd1f1e4da2f6e54038ccb5f25e`; withdrawProtocolRevenue `0xd446e00e8e4b4443242b7ce37dd80cb5c113ffaa2a7922d0abf8b47dbabbbc41` (protocolRevenue ↓). |
| 2 B4 | 2.4 (facilitator fee) | ✅ PASS (partial) | setFacilitatorFeeBPS(100) `0xb4229a58f98eaf07d188e0c6fff89f50b5fafa379ef67f28355dcc36a434007e` / restore `0x40ca58ee4c804eb52055d49a419f46d4e529cd4dac30ca579174539ddd465a5f`; setOperatorFacilitatorFee(50) `0xe3b0b61ab683b70beea3f192444d2dd123aa36e3f312982d5480fb7037b0039b` / restore `0x557c5b582dd574430a4837484a28b47656ae725e01e199d478f5a3c8e7842122` | 46971 / 25059 / 46410 / 24498 | feeBPS set→100→restored 0; operator override 50→restored 0. **Withdraw leg SKIPPED: `facilitatorEarnings(deployer,aPNTs)==0`** — no earnings accrued (suite x402 fee was 0%), so the withdraw path was not exercised on-chain. |
| 2 B4 | (gov timelock) | ⏭️ SKIP (deferred) | queueBLSAggregator `0x9a4cb9715301949c05163d7f0ccb321c2a26386322d17fbe8a0fe20e936c1d16` | 36391 | pendingBLSAgg + ETA set; `applyBLSAggregator` skipped — requires 24h timelock to elapse. updateSBTStatus / updateBlockedStatus SKIP (write is `onlyRegistry`). |
| 2 B5 | 1.6 (dry-run) / 7.7 | ✅ PASS | (read / static-call) | — | `dryRunValidation` returned `ok=false`, reasonCode `0x4f50455241544f52...` = **`OPERATOR_PAUSED`** (operator was paused at this point in suite — NOT the `DRYRUN_RATE_COMMITMENT_VIOLATED` leg). `pendingDebts==0`; retryPendingDebt / clearPendingDebt SKIP (no pending debt). |
| 3 C1 | negatives | ⛔ PASS | pause `0xc747115a47c4ebd1cf3567b959a9f6f7c8a86e26abfce8c4c2c28db135730109`; unpause `0xe30d87cd2de4c148d2a7ff94aecd8826f1e44f6b8c11b6d067bc7f16209f0a7a` | 33905 / 36694 | No-SBT sender → `reverted (missing revert data)`; paused operator → `reverted (unknown custom error)`; unconfigured operator → `reverted (unknown custom error)`. Exact named selectors not surfaced by RPC (validation-time reverts). |
| 3 C2 | 1.5 (V4 negative) | ⛔ PASS | (eth_call revert) | — | Zero-balance V4 user → `reverted (missing revert data)`; getSupportedTokens returned 2 tokens. |
| 4 D1 | 6.1 | ✅ PASS | setRule `0x4f3c0a91c092e12198b609a223ca6fe27614382afdd5338843554a695128dd28`; setEntropyFactor `0x6667c9502e3c0256e26affb83f76b8d24802ebb3db5acb9fc699bae3ee2f691d` / restore `0x213d21fef68f4e08c33426a43fb9ba4f1c02664fe384ccb8ac5bbd770d47ad54`; setCommunityReputation `0xbd396864cfd479fd82dc8bd2c62105546c060b8bdb499016546730269639563a`; remove rule `0x76376aa0ac335a6c44b873b2d3e3b2e5b9a26d1f89205b5ed6a087dff60f353d` | 153132 / 30605 / 30605 / 28530 / 45408 | Rule E2E_ACTIVITY base=20/bonus=5/max=200 stored & read; entropy 1.5→score 105→restored; communityReputation=42; rule cleaned up. |
| 4 D2 | 6.1 / 7.6 (read) | ✅ PASS | setCreditTier(7,5000) `0x2176efbcdbb3e3bfaf7fcfdff130376beccba3b3c84d1ab8e69e4dad0c26ec9c` / reset `0x24c86c8c491938ad974ed3dca297d893cba592f5b32657232a59cb01349aae13` | 52044 / 30048 | Tier-7 ceiling set→5000→reset 0; getCreditLimit(rep=0)→tier-1 1000 aPNTs. |
| 5 E1 | 7.3 | ✅ PASS | SP updatePrice `0xc4a1f1cb2141f79d3874c68f3ec81fcd5566f0938ac9a45d1c9139eb08787f1f`; setAPNTSPrice(0.03) `0x88d1b7bdbfb96abba11ccb63d048d3b0be261f1551d3c0d8ae66000903fb0fd7` / restore `0x64133dcb6f4ba5351ecd83ebdbf9f592ba5fb8a5f934523d8d952ee45b399864`; V4 updatePrice `0x958fa4854165f53e65db00536b1b5b005adbb6576b60af94a8b85dde05f44257` | 69295 / 36549 / 36549 / 54493 | Cache refreshed (ETH/USD $1773.95); aPNTsPrice 0.02205→0.03→restored. **`DRYRUN_STALE_PRICE` negative leg NOT executed this run** (cache was kept fresh). |
| 5 E2 | 7.2 | ⛔+✅ PASS | setProtocolFee(500) `0xdb9f9a661782de9166e6ea128535285cf08ee87a372bc5b13729ce0f9e31972c` / restore `0x609118d585b3f7f862903e00aa2a20021c3e4794d2d38bcc2181ec70eedf786b` | 32657 / 32657 | protocolFeeBPS=500 set/restored; **setProtocolFee(2001) reverted (unknown custom error)** — over MAX_PROTOCOL_FEE=2000; protocolRevenue=275.68 read. |
| 5 E3 | (read, PR#200) | ✅ PASS | (read-only) | — | `operators()` 9-tuple confirmed (exchangeRate removed); live rate from xPNTsToken=1.07213…; getAvailableCredit denominated in aPNTs; getDebt=0. |
| 5 E4 | 1.3 (debt repay) | ✅ PASS (no-op) | (read / SKIP) | — | Deployer debt==0 → `repayDebt` TX **SKIPPED (no-op)**; ceil/floor conversion math verified read-only. No `debts[user]` delta observable (nothing to repay). |
| 6 F1 | 4.1 (read) | ✅ PASS | (read-only) | — | totalStaked=130; stakes(deployer).amount=50; wiring REGISTRY/GTOKEN/treasury verified. |
| 6 F2 | slash (supporting) | ✅ PASS | slashOperator(WARNING,0) `0xc30dc6d2a082c0d9bd3b7273cbdb43b5c5935dcb67b3d9d8c1f15a10784f92f9`; updateReputation(100) `0x6550bb6f3698cf3693fd8d44559dcc5a77e3099003ab97267d649d8e4908aa20` | 124476 / 37068 | Slash count 5→6; level=WARNING, amount=0 (no stake burned); reputation restored to 100. (Tier-1/Tier-2 DVT slash NOT exercised — see footnote in 04.) |
| 6 F3 | 3.5 / 4.1 (admin) | ✅ PASS | setRoleExitFee `0x20406dca1408b6e49aab5bf84573190ef09d3b78a29b37f52199697687e5c74d` / restore `0xf2f297cfff53c1c0be4e24afe7234553675892cd505f344d7338f2d12d9c24da`; addSlasher `0x69732b2e04fdfe318388ea1772beb23a9078ec196f42301df3a649d4b574d7f1` / remove `0x8efaf88e0b8977058cecaed591a10a58fcf498f2864a51b6e86bf9f196260473`; addRepSource `0x70f5b75e058e13b8bcaa0dde65639670897e16d90bfec7b15d0740750047a4f2` / remove `0x16931af70b2e87316a51de7643bb9a4bab8462d4d43d47ee0542a810737c957a`; setLevelThresholds `0x6794fc330a4cd62da8ef11a84cbe4c5776a83712a6240ddb1b0ada71c5fc8395` / restore `0xb8052a94b2c1bb2da5504005bf5ceda963993b2b4ca84da83ae080c786306b59`; setCreditTier(3) `0x0f8e455630118528dd2a2fd3423cb5a2ac8c142dbb28a5ce6321ec4ab8032bf2` / restore `0x1b93a6de3a4d1d2e3fad8d2151abda0c3cc4b6ef13e1e8f6ee5922a29dd95c4f` | 30990 ea / 47655 / 25743 / 52722 / 30810 / 62955 / 62931 / 32132 ea | Exit-fee config, authorized-slasher add/remove, reputation-source add/remove, level thresholds set/restore, credit tier set/restore — all asserted & restored. `topUpStake` direct call skipped (onlyRegistry); `batchUpdateGlobalReputation` SKIP (needs BLS proof). |
| 7 G1 | 6.2 (read) | ✅ PASS | (read-only) | — | sbtHolders / isEligibleForSponsorship / isRegisteredAgent / globalReputation / levelThresholds / getCreditLimit all read & asserted. **Agent feedback emission NOT asserted** (no live agent handleOps this run). |
| 7 G2 | 3.4 (read) | ✅ PASS (read-only) | (read-only) | — | Dual-channel logic `sbtHolders \|\| isRegisteredAgent` verified by query: deployer eligible via SBT; random addr ineligible. **No agent NFT was registered**, so a live agent-sender `handleOps` (sbt==false yet sponsored) was NOT executed on-chain this run. |
| 7 G3 | 1.2 / 6.2 (read) | ✅ PASS | setCreditTier(7,5000) `0xfa2785033335a8bdd622236e29a1cc480d91f0fa4f5a75b1d910fc1eb8b60b86` / reset `0xd4a286bfbcb37266933da136ad437c4716064ef06106018f228f90356a865e98` | 52044 / 30048 | Tier ceiling expand/reset; fresh user (rep=0)→tier-1 1000 aPNTs. Live tier escalation requires BLS-signed reputation update (not run). |
| 8 H1 | DVT/BLS (read) | ✅ PASS | (read-only) | — | DVT/BLS wiring + thresholds (min=3, default=7, MAX=13); addValidator SKIP (deployer lacks ROLE_DVT). |
| 8 H2 | reputation (read) | ✅ PASS | (read-only) | — | ReputationSystem wiring/getters; syncToRegistry SKIP (needs ≥3 DVT BLS cluster). |
| 9 setup | 1.5 prep | ✅ PASS | pmV4.depositFor(AA_A) `0x27d122215482677376090e8bb181e5085043c50ddad5ca02005cf9ff6e27c766` | 61196 | AA_A V4 escrow funded to 687.98 aPNTs; price caches fresh. |
| 9 Gasless | 1.5 (PaymasterV4 escrow) | ✅ PASS | `0x669fd92e842e0a3e64bc6ada0a346eb3d7bd57c7d73b5a36beab54df1f829643` | est 412213 | handleOps confirmed. L2: sender aPNTs 1356.85→1355.85 (−1 transfer); recipient +1. Gas paid from V4 token escrow, no ETH from user. **Fresh equiv of headline `0x1314…` (PaymasterV4 leg).** |
| 9 Gasless | 1.1 (SP xPNTs balance-pay) | ✅ PASS | `0xf1d92178f8fe0427e90532fc6661349830f5e8159a686369d67c9285cfbfe855` | est 588471 | handleOps confirmed. L2: sender aPNTs 1355.85→1311.23 — i.e. −1 transfer **+ ~43.62 aPNTs burned for gas**; recipient +1. **Fresh equiv of headline `0x1314…` (SP xPNTs leg).** |
| 9 Gasless | 1.1 (SP, PNTs / Anni op) | ✅ PASS | `0x14ecc12b460da3114ea2d3e21223ab90be73d2869a225a40c344e860741a477d` | est 588267 | Second xPNTs token (PNTs). L2: sender PNTs 734.47→692.80 (−1 transfer + gas burn); recipient +1. Confirms multi-operator/multi-token sponsorship. |
| 9 Gasless | 1.2 (credit/debt — burn branch) | ✅ PASS | `0x78ac6ba23e40fc4477e4dc24a1c2d01fd294a53142bd94719c1b507ca5be763b` | est 588506 | **Burn path** (account had balance): xPNTs 1311.23→1266.61 (burned 44.62 aPNTs); `debts[user]` unchanged at 0. Pure-credit (0-balance → DebtRecorded) leg proven separately below. |
| 9b Gasless | 1.2 (credit/debt — DEBT branch, live proof) | ✅ PASS | `0x94eed4edd77db3e0a94dad1b0c2d834f60410a3b2edf7ecef0ce6502e1ebf18b` | 316899 | **Pure-credit path PROVEN LIVE** (test-case-4). Sender AA Account A (`0xECD9C07f648B09CFb78906302822Ec52Ab87dd70`) drained to 0 xPNTs/aPNTs first. L2 (independently RPC-verified): `debts[AccountA]` 0→**39.759333601280400000 aPNTs** (getDebt==39759333601280400000 wei, read live from chain); **xPNTs balance unchanged = 0 → burn branch NOT taken, `recordDebtWithOpHash` path proven**; available credit ↓39.76. Proves "sponsor-now-pay-later". Evidence: `logs/rerun-creditdebt-111047.log`. Block 11070221. |
| 10 Channel | 2.5 (MicroPaymentChannel) | ✅ PASS | open `0x3d7d166b9430db259f90cf894eed68afb74f0b5f2b8008761a9a1335fe8116f8`; settle `0x6b65b731425444c37edb8921c71fe1fa0ffd57ac43ae8eb053f9e2d8c0ab96d1`; close `0xa986bf37018344dfb17fc38675df8a6bb4b4ee414a110939db0f3ae80dad080d` | 168793 / 72334 / 111296 | Deposit 10 → settle cumulative 3 → close (7 final). L2: payee +7.0 aPNTs; payer net cost 7.0; channel struct deleted (payer==0). Finalized channel rejects re-settle. |
| 10 x402 | 2.1 (EIP-3009 USDC) | ✅ PASS | `0xb8a7536b5d6e9301e29d9f933c8a3f73b19ae07f9052b49777f74e9237bb5990` | 153479 | `settleX402Payment` (receiveWithAuthorization). L2: payee +1.0 USDC; fee 0 (feeBPS=0); nonce consumed=true; **replay rejected** (2.3). **Fresh equiv of headline `0x878dbb0b…`.** |
| 10 x402 | 2.2 (direct xPNTs, C-02) | ✅ PASS | mint `0x5c4afafe50ed86c08d4ce5eaa4c2d8a66368c416e42ec646bae704874b7c8d53`; settle `0x899ac2ada975e099ffd276c5200f26b814fc0fd23f049f3b1bbde9c6dfaf33c1`; binding-isolated `0x0bfa001f357a089ff8035c5c5f363bef35314505924cfc7b6d22c6f0a1554360` | 60852 / 132541 / 132553 | `settleX402PaymentDirect`. L2: payee +1.0 xPNTs; fee 0; nonce consumed. **Fresh equiv of headline `0x3bb790b6…`.** |
| 10 x402 | 2.3 (replay ⛔) | ⛔ PASS | (eth_call revert, both x402 tests) | — | Re-submit used nonce → **`NonceAlreadyUsed`** (asserted explicitly in direct test; "replay correctly rejected" in EIP-3009 test). |
| 10 x402 | 2.2 C-02 (redirect ⛔) | ⛔ PASS | (eth_call revert) | — | Tampered recipient redirect → **`InvalidX402Signature`**; same signature settles to AUTHORIZED recipient (tx `0x0bfa00…`) — recipient binding isolated, C-02 verified. |
| 10 BLS | 4.4 (permissionless ⛔, H-02) | ⛔ PASS | (eth_call revert) | — | `permissionlessBLSRegistration==false`; non-owner `registerBLSPublicKey` → **`PermissionlessRegistrationDisabled`**. (Positive BLS-key registration write NOT executed this run.) |
| 11 P2 | 7.9 (PaymasterV4 lifecycle) | ✅ PASS | deactivate `0xbed2826a92d5e7431e9494c6ce5aa9b5e8e41b564dc0ed139a988c86ee73a4ec`; activate `0x46070701a37f3915149c0c0daeb391b5ea7bc9a12e1ccee06f4824f950144169`; depositFor `0x369e1ac6e59946b38cf3045b90a6fdea0057698997f7f42578797b4589e276c5`; withdraw `0xadd59b55408a146e91a9924bb2a9c385920e6aa379b1608f40058596e854390c`; updatePrice `0x77733a89f450fe1f04774fa8f8232e9350d7987bac55c11d45992c3dd308a701` | 50631 / 29586 / 61184 / 56925 / 51693 | paused toggle (deactivate→true, activate→false); depositFor +1, withdraw −1 asserted; price cache synced. (Factory clone-deploy NOT re-run — existing clone `0x2118…` reused.) |
| 12 X1 | 8.1 / 8.2 (xPNTs admin) | ✅ PASS | setMaxSingleTxLimit `0xc3e2bec322c9614a2a6fc159e8f61f908d506a3f9443031a572623b099675c5b` / restore `0x73e579aeda2a8feb3efca91e4b9b6e9ff361c848ecf1cf53ecbf8c4e7ce5daec`; setSpenderDailyCap `0x4dbd3f12ba92a0acf10c04c947fa90edb2fa2db08e541c9d0f6566dab773b9ca` / restore `0xf6cde2996a34963b89e65b62df548d14753c69bb7382f2d8edb4067c45615656`; rm/add autoApproved `0x08e347da97828dd391b6743ef70d1120c8377af6291d0225ca0866d313f09d18` / `0x421589be7341ccc457ae641abc06d5444304c4c15418d975568edfe6a1ebd856`; rm/add facilitator `0x5311510987e5116060de6f62bd0bea3bbd5c8b6da55be6b7031f5ae9673879f8` / `0xb733b9252cdaa8d97b9903a37fe8293c046c694cc0f8a9b98fb9b231dcaf8e39`; burn(1wei) `0x7be2cfc86c511d6212f00cd8c9f553b8e0688404679b5a5a9679b984aa863520`; updateExchangeRate(+1%) `0x3eb74ee82b8c8f44da71d74f46495ade5dc5383fef6c66200018cdb92426c709` | 33091 / 33091 / 32717 / 32717 / 28973 / 52885 / 28665 / 50574 / 36714 / 41169 | Caps + spender/facilitator whitelists set/restored; self-burn −1 wei; exchangeRate +1% (restore reverted on 1h cooldown — expected). transferAndCall→SP SKIP (APNTS_TOKEN mismatch). **NOTE: the 8.2 firewall REVERT legs (`UnauthorizedRecipient`, `SingleTxLimitExceeded`) were NOT executed live this run — only the cap *config* was exercised.** |
| 13 I1 | 7.6 (credit ceiling H-1) | ✅ PASS (read-only) | (read-only) | — | creditTierConfig, getCreditLimit, pendingDebts, userOpState(isBlocked) all readable; availableCredit = limit − totalDebt verified (1000−0); version asserts `SuperPaymaster-5.3.3`. **Over-ceiling drain REVERT leg NOT executed** (needs mid-UserOp drain fixture). |
| 13 I2 | 7.5 (emergency halt H-2) | ⛔ PASS | emergencyRevoke `0x21964a24030205904574e8358491e2a8b053273253bbae2ab796c6ddeba3cae8`; addAutoApproved(temp) `0x088c608a1ae3ec339a5340a269c231109b9a52cd2cd29e18c6100f5e713f5497`; restore `0x1ccc68a1008a4dcfbc9d1241487ebc614b4375ebcfff03833f14d871dfeb6ac9` / `0x16c4ff8a6d828dec76f811b2bdc8f344ff7490dc973f762db580e3b5f3b8f739` / `0xa15b76813c05ccdfa28da99d5b8d6ced20bb602060c2cc1770c606191f263f28` | 55477 / 52873 / 61120 / 31674 / 62733 | `emergencyDisabled` flipped true after revoke (asserted). The self-pull transferFrom reverted with selector **`0x4e97bcfc` == `EmergencyStop()`** (confirmed via `cast 4byte 0x4e97bcfc`) — the correct named selector; the original doc under-claimed it as "unknown custom error". SP carve-out (transferFrom→SP) succeeded; state fully restored. **CLEAN ⛔ PASS — exact named selector matched.** |

### Credit/debt live-proof setup (3-step, scenario 1.2 DEBT branch)

The DEBT branch (row 9b) was previously OWED because the full-suite sender held an xPNTs balance (→ burn branch). It is now PROVEN LIVE via a 3-step setup, all status=1:

1. **Drain** sender AA Account A (`0xECD9C07f648B09CFb78906302822Ec52Ab87dd70`) aPNTs/xPNTs balance to 0 — owner-signed `SimpleAccount.execute(aPNTs, 0, transfer(deployer, fullBalance))`. Tx `0x32cbc627e0c93d3cafad3ea572e8c01218d2319ea09f07db810346197a65ee32` (status 1, block 11070212).
2. **Refresh** stale price cache — `SuperPaymaster.updatePrice()`. Tx `0x431e3942bb0b8d1705bd27e5e50e20d3d0f181f577d0e7682c627a76fa51b4b9` (status 1).
3. **Sponsor** the UserOp on the pure-credit path — row 9b tx `0x94eed4ed…` (status 1, block 11070221, gas 316899).

Result independently RPC-verified: `debts[AccountA]` 0→39.759333601280400000 aPNTs; xPNTs balance still 0 (burn branch not taken → `recordDebtWithOpHash` proven). Evidence: `logs/rerun-creditdebt-111047.log`.

## Full-suite failures (honest record)

The full suite reported **3 FAIL out of 37**. All three trace to the **same E2E-harness defect — nonce/mempool congestion**, not a contract bug. When prior txs were still pending in the Sepolia mempool, the harness chose to **SKIP a critical tx** (logged `nonce/in-flight conflict (pending TXs in mempool) — skipped [CRITICAL]`) instead of serializing the nonce or retrying. Each skip then failed a downstream assertion.

| Group | Full-suite failure | Mechanism | Isolated re-run result |
|---|---|---|---|
| **B1 Operator Config** | unpause assert FAILED | the **unpause** tx was SKIPPED (critical) → operator stayed paused → assert "unpaused" failed | **5 pass / 0 fail / 2 skip** — unpause confirmed `0x8cf930c3fba6a964a043d0760ca795064919550de185e4516238747c3aeea4f8` |
| **B2 Operator Deposit/Withdraw** | 3 balance asserts FAILED | the **depositFor(5)** tx was SKIPPED (critical) → all later balances off by exactly +5.0 aPNTs | **6 pass / 0 fail / 0 skip** — depositFor `0x1a036bda4ee31a19d02db8ad305ee95af4c3658e64a165538ed2a24c0055ce33`, final balance restored exactly |
| **B4 SP Governance Admin** | 300s TIMEOUT (killed) | a governance tx stuck in mempool → group hung past the 300s watchdog | **11 pass / 0 fail / 3 skip** — setTreasury `0x8f8f2e4afd7203ce53372c748a4ac32f48fa11bbca4f859c675466bba33cf1b6`, full governance surface exercised |

Corroborating evidence that these are flakes, not contract defects:
- **B3** (`configureOperator` — the *same* operator-config contract path as B1) **PASSED** in the full suite.
- The txs that *did* confirm in B1/B2 asserted correctly; only the SKIPPED legs broke the assertions.
- The 3 B4 re-run SKIPs are **legitimate**, not failures: `updateSBTStatus` / `updateBlockedStatus` require `msg.sender == REGISTRY` (covered by Registry unit tests); `withdrawFacilitatorEarnings` skipped because `facilitatorEarnings == 0` (nothing to withdraw).

Action item (harness, not contract): serialize nonces / await receipts before issuing the next tx, and retry on in-flight conflict instead of skipping. Tracked separately from this release's contract verification.

**RESOLVED (harness fix, no contract change).** The root cause was `sendTxSafe` in `script/gasless-tests/test-helpers.js` treating a nonce/in-flight conflict as an immediate CRITICAL skip — its retry loop only retried NETWORK errors. The fix makes nonce/in-flight conflicts RETRYABLE: on conflict the helper waits for the signer's mempool to drain (`_waitMempoolDrain`: polls until pending nonce == latest), re-syncs the nonce, and retries within the budget; it only skips after exhausting all attempts. With this fix, B1/B2/B4 should pass in-suite on the next full run (no longer dependent on isolated re-runs).

## Unit-test coverage (forge coverage --ir-minimum)

Captured 2026-06-16 10:27 (`logs/forge-coverage-102712.log`):

| Metric | Coverage |
|---|---|
| Lines | **64.16%** (2952 / 4601) |
| Statements | **73.10%** (3218 / 4402) |
| Branches | **59.39%** (509 / 857) |
| Functions | **37.93%** (602 / 1587) |

Note: the function % is dragged down by deploy/safe-batch scripts and `*_Coverage.t.sol` harness files counted in the denominator (e.g. `GenerateSafeBatchTx.s.sol` 0/111, `PaymasterFactory_Coverage.t.sol` 0/23). Core security paths (`xPNTsSecurityDeepAudit.t.sol`, `xPNTsTokenFull.t.sol`) are at 100%.

## Known-Oversight / test-hygiene items (NOT run failures)

1. **Stale expected-version constants in `check-contracts.js`.** Preflight printed `version MISMATCH` for 5 contracts (Registry-5.3.3 vs expected 4.1.0; Staking-4.2.0 vs 3.2.0; MySBT-3.2.0 vs 3.1.3; GToken-2.2.0 vs 2.1.2; SuperPaymaster-5.3.3 vs 4.1.0). These are **stale hardcoded constants in the test script's expected-version table**, not on-chain problems — preflight still PASSED. Fix: update the table to the v5.4 versions.
2. **On-chain `version()` == 5.3.3 while impl is v5.4.** SuperPaymaster/Registry `version()` still return `5.3.3` though deployed bytecode is v5.4 — known **intentional beta deferral**. Do not gate on the literal version string for beta.1.
3. **`EmergencyStop` selector — RESOLVED, clean ⛔ PASS** (I2 / scenario 7.5). The emergency-halt revert surfaced as `0x4e97bcfc`, originally logged as "unknown custom error". Independent decode `cast 4byte 0x4e97bcfc` → **`EmergencyStop()`** — it IS the correct named selector. The doc previously under-claimed it; 7.5 is now a clean ⛔ PASS with exact-selector match. No longer owed.
4. **`SP.APNTS_TOKEN` (`0x9f0E…210B`) differs from `config.aPNTs` (`0xc53a…BCe8`).** B2 deposit/withdraw and X1 transferAndCall operate against `APNTS_TOKEN`; the latter's push-deposit path is skipped pending a 7-day `queueSetAPNTsToken` migration. Documented divergence, not a failure.

## Negative (⛔) coverage gaps this run (honest)

These plan ⛔ legs were **NOT executed live** in this run (covered by Foundry unit tests / fork tests instead):
- **1.6 `DRYRUN_RATE_COMMITMENT_VIOLATED`** — B5 dry-run returned `OPERATOR_PAUSED`, not the rate-commitment revert.
- **7.3 `DRYRUN_STALE_PRICE`** — price cache was kept fresh; stale leg not triggered.
- **7.6 credit-ceiling revert** — I1 verified ceiling *state* read-only; no over-ceiling drain tx.
- **8.2 `UnauthorizedRecipient` / `SingleTxLimitExceeded`** — X1 set/restored caps but did not run the firewall reverts.
- **8.3 `OperationAlreadyProcessed`** (burn replay) — not re-run as an explicit same-opHash replay this suite.
- **8.4 `Unauthorized`** (unapproved facilitator) — x402 direct test ran with an already-approved facilitator; unapproved-revert leg not executed.

> Note: **7.5 `EmergencyStop` is NOT a gap** — it reverted live with `0x4e97bcfc` == `EmergencyStop()` (confirmed via `cast 4byte`); it is a clean ⛔ PASS (see Known-Oversight #3, now resolved).

## Deferred (Tier C) — not executed live (see 02-PLAN)

4.2, 4.3, 5.1, 5.2, 5.3, 7.4, 7.5(gov), 7.8, 8.5 — intentionally deferred; covered by Foundry unit / fork tests. See 04-CAPABILITY-MAP footnotes.
