# 01 — TESTDATA (v5.4.0-beta.1 FRESH REDEPLOY — Sepolia mainnet rehearsal)

> TX-Value-Verification framework, document 1 of 5.
> Source of truth for every address, actor and precondition used by the live E2E run.
> **A green receipt is not a proven feature** — this document only fixes the inputs; proof lives in 02-PLAN (L2 state assertions) and 03-RESULTS (real tx hashes).

> **FRAMING — this is NOT a new version.** This run re-deploys the **same `v5.4.0-beta.1` release code** cleanly from scratch on Sepolia (`./deploy-core sepolia --fresh-deploy` → `DeployLive.s.sol`) as a **mainnet-deployment rehearsal**. **No `contracts/src/*.sol` changed** — only deploy/test scripts were hardened. The deployed contracts therefore ARE `v5.4.0-beta.1`, and the two beta.1 GA blockers disappear on a clean deploy:
> - `SuperPaymaster.version()` now correctly returns **`SuperPaymaster-5.4.0`** (no stale literal — see §2.1).
> - `SuperPaymaster.APNTS_TOKEN()` **== `config.aPNTs`** (no `queueSetAPNTsToken` migration, no config↔on-chain divergence — the beta.1 §2.3 reconcile items are GONE — see §2.3).
> Companion: [`REHEARSAL-RECORD.md`](./REHEARSAL-RECORD.md) (the deploy-level summary this 5-doc suite is the evidence layer beneath).

## 1. Network & Infrastructure

| Item | Value |
|---|---|
| Network | Sepolia testnet |
| Chain ID | `11155111` |
| EntryPoint (ERC-4337 v0.7) | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| Chainlink ETH/USD feed | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Read RPC | Alchemy Sepolia endpoint (from `.env.sepolia`) — **reads only** |
| Broadcast RPC | `https://ethereum-sepolia-rpc.publicnode.com` (`E2E_BROADCAST_RPCS`) |
| Release tag (code) | `v5.4.0-beta.1` (fresh full redeploy 2026-06-16; deploy path = `DeployLive.s.sol`) |
| Deploy config (canonical) | `deployments/config.sepolia.json` (`updateTime` 2026-06-16 13:20, `srcHash` `14ba1a4d…16d9`) |
| Source-verification record | `deployments/verify.sepolia.contracts-6-16.md` (Etherscan source-verified) |

**RPC split rationale**: Alchemy occasionally accepts a tx but does not propagate it (the "ghost-nonce" failure mode, 2026-06-13). The suite therefore READS via Alchemy (the production endpoint under test) but ALSO broadcasts every tx to publicnode so an accept-but-don't-propagate primary cannot strand it. Clear with `E2E_BROADCAST_RPCS=""` only when deliberately testing the primary RPC in isolation.

## 2. Deployed Addresses (fresh deploy 2026-06-16)

### 2.1 New / changed by the fresh deploy

| Contract | Address | Version / note |
|---|---|---|
| SuperPaymaster (proxy) | `0x030025f40d509b1a99547bAEb3795bD27F7182b7` | impl `0x24a94572cfB6Ca6C8dE107431043556D461d8cFf`. `version()` = **`SuperPaymaster-5.4.0`** (clean — confirmed on-chain in I1, see 03). |
| SuperPaymaster (impl) | `0x24a94572cfB6Ca6C8dE107431043556D461d8cFf` | content = v5.4.0-beta.1 |
| Registry (proxy) | `0x3F920B25f8b65988359C372F66F036E48adFc556` | impl `0x1770338C0669d3333473a72CF0c164Ccc640Dc34`. `version()` = `Registry-5.4.0`. |
| Registry (impl) | `0x1770338C0669d3333473a72CF0c164Ccc640Dc34` | |
| X402Facilitator | `0x326Fc3413c8A0185b0179B971C69813B6dFD971B` | `X402Facilitator-1.0.0`, owner = deployer |
| PolicyRegistry | `0x8c2488d46d5447418558c38AA6441720df656094` | `PolicyRegistry-1.0.0` |
| TimelockController | `0xB734df3c0A1809bc06708512363D368Ac51dF1A2` | minDelay = 2 days |

> **NO version-string deferral this run.** Unlike beta.1 (whose on-chain `version()` read `5.3.3`), the fresh deploy compiles and deploys current source, so `version()` returns the correct `5.4.0` strings. The only residual is a *test-script hygiene* item: `check-contracts.js` still carries a stale **expected-version table** (`expected Registry-4.1.0`, `SuperPaymaster-4.1.0`, …) and prints `MISMATCH` warnings — but it still PASSES, and the on-chain values are correct (see 03, group [1]).

### 2.2 Core / supporting (from `deployments/config.sepolia.json`)

| Contract | Address |
|---|---|
| GToken | `0x20a051502a7AE6e40cfFd6EBe59057538E698984` |
| GTokenStaking | `0x3B363598746Ea57314d4869B160940948c569D48` |
| MySBT | `0x072A0D12f4212B6baD7c6d0A633eaffbDE9105bF` |
| xPNTsFactory | `0xCec3655525a112882E74Fb7C26AcB267a07724cb` |
| `aPNTs` (`config.aPNTs` **== `SuperPaymaster.APNTS_TOKEN`**) | `0x9e66B457E0ABb1F139FD8A596d00f784eBA2873b` — base accounting token AND operator xPNTs gas token (see §2.3). |
| PNTs (Mycelium xPNTs sample) | `0xC687f8a115D308ECD39658a8EE33bC3c8F75EE31` |
| PaymasterFactory | `0x0Aa06EA5295eeD4D48c93c594Db1CBf3626971A5` |
| PaymasterV4 impl | `0x59DCA5861aaDA602fE1BFbfcc36DFAc36C58623d` |
| PaymasterV4 clone (active AOA) | `0x957852251f44570dc2B60Dde0954f191FF3372eE` |
| MicroPaymentChannel | `0x405851A141Cde827E33247d4D4089Af2814c2FF5` (`MicroPaymentChannel-1.3.0`) |
| ReputationSystem | `0x7fEd690E1663755e24a1C9d6164336809d68a578` |
| BLSAggregator | `0x15387e161c1b3dAe7c66Fbd5c1F32837B58B2e79` |
| DVTValidator | `0x19BA9829C784E4A41b68960b9c0bA55f83718997` |
| AgentIdentityRegistry (`config` **== SP-wired**) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` (official ERC-8004) |
| AgentReputationRegistry (ERC-8004) | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |
| AgentValidationRegistry (ERC-8004) | `0x8004Cb1BF31DAf7788923b405b754f57acEB4272` |
| SimpleAccountFactory | `0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985` |

> **Source-of-truth model.** `deployments/config.sepolia.json` is authoritative for the deployed-contract address registry and is exactly what the E2E suite reads (it SHA-256-fingerprints the whole file to key its idempotent skip-cache, so any address change forces a full re-run). On a fresh deploy there is **exactly one source of truth, and it does not split**: the two SuperPaymaster runtime pointers that DIVERGED in beta.1 now match the file (§2.3).

### 2.3 On-chain runtime pointers — NO divergence on the fresh deploy

The two beta.1 "reconcile-before-GA" items both vanish on a clean deploy. Verified on-chain this run:

| Pointer | `config.sepolia.json` | `SuperPaymaster` getter (on-chain) | Status |
|---|---|---|---|
| Base accounting token | `aPNTs` = `0x9e66B457…` | `APNTS_TOKEN()` = **`0x9e66B457…`** — operator `deposit`/`withdraw`/`aPNTsBalance` move THIS token (B2 asserts `APNTS_TOKEN (0x9e66B457…) balance after withdraw`). | **MATCH** — wired directly at `initialize()`; no `pendingAPNTsToken`, no `queueSetAPNTsToken` migration, no in-flight timelock. |
| Agent identity registry | `agentIdentityRegistry` = `0x8004A818…` | `agentIdentityRegistry()` = **`0x8004A818…`** (B4 asserts `agentIdentityRegistry restored == 0x8004a818…`). | **MATCH** — SP wired to the official ERC-8004 registry; dual-channel eligibility queries it. |

> Because `APNTS_TOKEN == config.aPNTs`, the **same** token (`0x9e66B457…`) is both the protocol base accounting unit AND the operator's xPNTs gas token in this deployment. End-user balances, `burnFromWithOpHash`, `getDebt`, and operator `aPNTsBalance` all reference `0x9e66B457…`. The beta.1 "two-tokens-both-symbol-aPNTs" hazard does not exist here.

## 3. Actors & Funding Gate

| Role | Identity | Funding requirement (GATE — run is INVALID if unmet) |
|---|---|---|
| Deployer / Owner / Operator / AAStar community | EOA `0xb5600060e6de5E11D3636731964218E53caadf0E` (keystore `DEPLOYER_ACCOUNT`; signer priority keystore > `PRIVATE_KEY` > anvil key) | Sepolia ETH for admin + handleOps; is X402Facilitator owner, SP owner, Registry owner, MySBT daoMultisig, operator treasury, AAStar (`aastar.eth`) community owner. Holds `ROLE_COMMUNITY` + `ROLE_PAYMASTER_SUPER` + `ROLE_PAYMASTER_AOA`. |
| Community (Anni / Mycelium, `mushroom.box`) | EOA `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` | Sepolia ETH; holds `ROLE_COMMUNITY` + `ROLE_PAYMASTER_SUPER`; GToken stake locked; SBT minted. Also the gasless **recipient** in TC1–TC4. |
| End-user AA account A (sender) | SimpleAccount `0xECD9C07f648B09CFb78906302822Ec52Ab87dd70` (via factory) | xPNTs balance for balance-pay; SBT status set true (`RegisterEnduser.s.sol`). Only SimpleAccount (A) signs EIP-191-compatibly. |
| Agent sender (ERC-8004) | registered Agent NFT holder, NO SBT | Sepolia ETH; would prove dual-channel eligibility — **not set up this run** (owed, §5 + 04). |
| x402 payer / payee | EOAs holding USDC + xPNTs | payer holds test USDC (EIP-3009) and xPNTs (direct settle) |
| Price keeper | any funded key | Sepolia ETH; runs price-cache update before E2E |

**Funding gate is hard**: every signer must hold Sepolia ETH before the run. A zero-balance signer must SKIP (exit 2), never produce a false-green. The suite proactively mints test tokens to AA accounts during `setup-gasless.js` and is idempotent (`SKIP_PASSED=1` skips already-green tests for the current deployment fingerprint).

## 4. Test Tokens

| Token | Address | Use |
|---|---|---|
| `aPNTs` (`config.aPNTs` == `APNTS_TOKEN`) | `0x9e66B457E0ABb1F139FD8A596d00f784eBA2873b` | **Single token, dual role this deploy.** Protocol base accounting unit (operator `deposit`/`withdraw`/`aPNTsBalance`, B2) AND the operator's xPNTs gas token (user balances, `burnFromWithOpHash`, user `getDebt`). symbol `aPNTs`. |
| PNTs (xPNTs sample, Mycelium) | `0xC687f8a115D308ECD39658a8EE33bC3c8F75EE31` | Second community gas token: burn-on-sponsor (TC3), multi-operator/multi-token proof. |
| USDC (Sepolia) | per `.env.sepolia` / x402 test config | x402 EIP-3009 `receiveWithAuthorization` settlement |
| GToken | `0x20a051502a7AE6e40cfFd6EBe59057538E698984` | Role stake lock / slash governance |

## 5. Pre-Run Checklist (all must be ✅ before any live tx)

- [ ] `deployments/config.sepolia.json` matches §2 addresses (fingerprint current; `srcHash 14ba1a4d…`).
- [ ] `.env.sepolia` present; `DEPLOYER_ACCOUNT` keystore unlockable.
- [ ] All actors in §3 hold Sepolia ETH (funding gate).
- [ ] **Deployer holds `ROLE_PAYMASTER_SUPER`** — a fresh deploy grants the deployer `COMMUNITY` + `PAYMASTER_AOA` but `configureOperator` requires `PAYMASTER_SUPER`; `TestAccountPrepare.s.sol` now grants it idempotently (fresh-deploy fix, see 03 §Failures #1).
- [ ] **Price keeper run immediately before E2E** — SuperPaymaster + PaymasterV4 caches fresh. Stale price → ops rejected. Most common false-FAIL; refresh first.
- [ ] **Base credit tier raised for L1 representativeness** — `setCreditTier(1,300)` + `setCreditTier(2,300)` so a fresh ENDUSER's validate-time charge (~120 aPNTs on Sepolia L1) fits the credit ceiling. **L1-gas artifact only — the contract default (100) is kept; on the OP L2 mainnet target the charge is ~1–5 aPNTs so 100 is plenty (see 03 §Credit-ceiling + OP-L2 caveat).**
- [ ] `E2E_BROADCAST_RPCS` set to publicnode (default) for redundant broadcast.
- [ ] `node_modules` installed under `script/gasless-tests/`.
- [ ] AA account A funded with `aPNTs`/`PNTs` and SBT status = true (`RegisterEnduser.s.sol`).
- [ ] Operator `aPNTsBalance` funded; PaymasterV4 escrow funded via `depositFor()`.
- [ ] Genesis communities present: AAStar (`aastar.eth`, deployer-owned) and Mycelium/MushroomDAO (`mushroom.box`, Anni-owned), xPNTs deployed + `propagateSuperPaymaster` done.

## 6. How To Run

```bash
# fresh full deploy (mainnet rehearsal path):
./deploy-core sepolia --fresh-deploy        # → DeployLive.s.sol
./prepare-test sepolia                       # grants roles, configures operator (idempotent)
forge script contracts/script/v3/RegisterEnduser.s.sol ...   # SBT status for AA-A

cd script/gasless-tests
./run-all-e2e-tests.sh                        # full suite (37 groups, dependency-ordered)
SKIP_PASSED=1 ./run-all-e2e-tests.sh          # idempotent re-run
ONLY="x402" ./run-all-e2e-tests.sh            # single phase
```

Exit-code convention: `0` = clean pass (all executed + asserted), `1` = FAIL (revert/assert), `2` = SKIP/inconclusive (precondition unmet). Exit 2 must NOT be treated as a pass.
