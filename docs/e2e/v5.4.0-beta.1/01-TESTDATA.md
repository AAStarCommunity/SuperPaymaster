# 01 — TESTDATA (v5.4.0-beta.1 E2E)

> TX-Value-Verification framework, document 1 of 5.
> Source of truth for every address, actor and precondition used by the live E2E run.
> **A green receipt is not a proven feature** — this document only fixes the inputs; proof lives in 02-PLAN (L2 state assertions) and 03-RESULTS (real tx hashes).

## 1. Network & Infrastructure

| Item | Value |
|---|---|
| Network | Sepolia testnet |
| Chain ID | `11155111` |
| EntryPoint (ERC-4337 v0.7) | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| Chainlink ETH/USD feed | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Read RPC | Alchemy Sepolia endpoint (from `.env.sepolia`) — **reads only** |
| Broadcast RPC | `https://ethereum-sepolia-rpc.publicnode.com` (`E2E_BROADCAST_RPCS`) |
| Release tag | `v5.4.0-beta.1` |
| Deploy config (canonical) | `deployments/config.sepolia.json` (already patched) |

**RPC split rationale**: Alchemy occasionally accepts a tx but does not propagate it (the "ghost-nonce" failure mode, 2026-06-13). The suite therefore READS via Alchemy (the production endpoint under test) but ALSO broadcasts every tx to publicnode so an accept-but-don't-propagate primary cannot strand it. Clear with `E2E_BROADCAST_RPCS=""` only when deliberately testing the primary RPC in isolation.

## 2. Deployed Addresses (v5.4.0-beta.1)

### 2.1 New / changed in this release

| Contract | Address | Version / note |
|---|---|---|
| X402Facilitator | `0xFe95a77e4Db593E6EA88000Aad9cD1230BAB4512` | `X402Facilitator-1.0.0`, owner = deployer |
| PolicyRegistry | `0x37e4E40e69Fb7d5C3fbAA0F52A4002D27472Ff29` | `PolicyRegistry-1.0.0` |
| TimelockController | `0x6cEc100c9CDc6ee7D9EDe0533edD3554E641DdBF` | minDelay = 2 days |
| SuperPaymaster (proxy) | `0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a` | impl `0xE84Ae83Eb1fF99AF859e5FADA1104A8376a96d7A` |
| SuperPaymaster (impl) | `0xE84Ae83Eb1fF99AF859e5FADA1104A8376a96d7A` | content = v5.4 |
| Registry (proxy) | `0xB5Fb8920F7AcD8b395934bd1F21222b32A30eF1A` | impl `0x0B5ce7032804aEFA698bddeB355D1FDDc553c14A` |
| Registry (impl) | `0x0B5ce7032804aEFA698bddeB355D1FDDc553c14A` | |

> **KNOWN DEFERRAL (version-string mismatch)**: `SuperPaymaster.version()` on-chain still returns `"SuperPaymaster-5.3.3"`. The deployed bytecode IS the v5.4 content; only the embedded version literal was not bumped before deploy. This is an accepted, tracked deferral for beta.1 — do NOT use `version()` as a gate. Confirm v5.4 behaviour by feature presence (PolicyRegistry/Timelock wiring, x402 settle paths), not by the version literal.

### 2.2 Core / supporting (from `deployments/config.sepolia.json`)

| Contract | Address |
|---|---|
| GToken | `0x46B82966f8a40f0Bbb8C13aCfBA746631CC2ec72` |
| GTokenStaking | `0x574820E26Acb7D9a1202708C6183d6A8aC957dA6` |
| MySBT | `0x754CeB687aCFC72136B02a1cb7cE2F911B63F1f8` |
| xPNTsFactory | `0xc312CAFcb49dFe3aB76bFB2F3e37CaEdBa65ccd9` |
| aPNTs (protocol gas token) | `0xc53a8c96581D8b7ACeDF16995323D7b3888ABCe8` |
| PNTs (community xPNTs sample) | `0x5aa8b75eF1650CF3C67b17b474677eD5C847A435` |
| PaymasterFactory | `0x60B8f728Abca14B82a4EC72f00Ff5437e0702e90` |
| PaymasterV4 impl | `0x59aEAec186a8883c165adf5C72a64df2fD9af068` |
| MicroPaymentChannel | `0xfCC95340Cbd4Ca8DdbE74676e799ABFb61553082` |
| ReputationSystem | `0xDD4D6162F426998E8B8FC97D0a8a5912cd70e6E0` |
| BLSAggregator | `0x7ec72505220a13040c80EF2B895Bf3405b6ed3e9` |
| DVTValidator | `0xB60C82158734def92D0d2163C93927cf19b86a95` |
| AgentIdentityRegistry (ERC-8004) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| AgentReputationRegistry (ERC-8004) | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |
| AgentValidationRegistry (ERC-8004) | `0x8004Cb1BF31DAf7788923b405b754f57acEB4272` |
| SimpleAccountFactory | `0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985` |

> The canonical, machine-readable source for ALL addresses is `deployments/config.sepolia.json`. If any address above conflicts with that file, the file wins. The E2E suite computes a SHA-256 fingerprint over the entire file to key its idempotent skip-cache, so any address change forces a full re-run.

## 3. Actors & Funding Gate

| Role | Identity | Funding requirement (GATE — run is INVALID if unmet) |
|---|---|---|
| Deployer / Owner | EOA = `DEPLOYER_ACCOUNT` keystore (signer priority: keystore > `PRIVATE_KEY` > anvil key) | Sepolia ETH for admin txs; is X402Facilitator owner, SP owner, Registry owner, MySBT daoMultisig |
| Community (Anni) | community private key | Sepolia ETH; holds `ROLE_COMMUNITY`, GToken stake locked, SBT minted |
| Operator (paymaster) | operator key | Sepolia ETH; holds `ROLE_PAYMASTER_SUPER` / `ROLE_PAYMASTER_AOA`; aPNTsBalance funded |
| End-user AA account A | SimpleAccount via factory (`TEST_AA_ACCOUNT_ADDRESS_A`) | xPNTs balance for balance-pay; SBT status set true |
| AA account B / C | Kernel / ZeroDev accounts | **Override to A in TC2/TC3** — B/C use raw-hash signing incompatible with EIP-191; only SimpleAccount (A) signs correctly |
| Agent sender (ERC-8004) | registered Agent NFT holder, NO SBT | Sepolia ETH; proves dual-channel eligibility |
| x402 payer / payee | EOAs holding USDC + xPNTs | payer holds test USDC (EIP-3009) and xPNTs (direct settle) |
| Price keeper | any funded key | Sepolia ETH; runs price cache update before E2E |

**Funding gate is hard**: every signer must hold Sepolia ETH before the run. A zero-balance signer must SKIP (exit 2), never produce a false-green. The suite proactively mints test tokens to AA accounts during `setup-gasless.js` and is idempotent (`SKIP_PASSED=1` skips already-green tests for the current deployment fingerprint).

## 4. Test Tokens

| Token | Address | Use |
|---|---|---|
| aPNTs | `0xc53a8c96581D8b7ACeDF16995323D7b3888ABCe8` | Protocol gas accounting unit (operator balance, debt, protocol revenue) |
| PNTs (xPNTs sample) | `0x5aa8b75eF1650CF3C67b17b474677eD5C847A435` | Community gas token: burn-on-sponsor, x402 direct settle, firewall/limits |
| USDC (Sepolia) | per `.env.sepolia` / x402 test config | x402 EIP-3009 `receiveWithAuthorization` settlement |
| GToken | `0x46B82966f8a40f0Bbb8C13aCfBA746631CC2ec72` | Role stake lock / slash governance |

## 5. Pre-Run Checklist (all must be ✅ before any live tx)

- [ ] `deployments/config.sepolia.json` matches §2 addresses (fingerprint current).
- [ ] `.env.sepolia` present; `DEPLOYER_ACCOUNT` keystore unlockable.
- [ ] All actors in §3 hold Sepolia ETH (funding gate).
- [ ] **Price keeper run immediately before E2E** — SuperPaymaster + PaymasterV4 price caches fresh. Stale price → ops rejected (`DRYRUN_STALE_PRICE` / validation failure). This is the most common false-FAIL; refresh first.
- [ ] `E2E_BROADCAST_RPCS` set to publicnode (default) for redundant broadcast.
- [ ] `node_modules` installed under `script/gasless-tests/`.
- [ ] AA account A funded with xPNTs and SBT status = true (`RegisterEnduser.s.sol`).
- [ ] Operator aPNTsBalance funded; PaymasterV4 escrow funded via `depositFor()` (~150 tokens/tx at $0.02/token).
- [ ] Community holds `ROLE_COMMUNITY` and stake locked; xPNTs deployed + `propagateSuperPaymaster` done.

## 6. How To Run

```bash
cd script/gasless-tests
# full suite (dependency-ordered):
./run-all-e2e-tests.sh
# idempotent re-run (skip already-green for this deployment):
SKIP_PASSED=1 ./run-all-e2e-tests.sh
# single phase, e.g. x402 only:
ONLY="x402" ./run-all-e2e-tests.sh
```

Exit-code convention: `0` = clean pass (all executed + asserted), `1` = FAIL (revert/assert), `2` = SKIP/inconclusive (precondition unmet). Exit 2 must NOT be treated as a pass.
