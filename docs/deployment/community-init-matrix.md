# Community & Token Initialization Matrix

> SuperPaymaster deployment initialization by environment.
> Last updated: 2026-05-29

## TL;DR

| Environment | Script | Communities | Token(s) | Test Extras |
|---|---|---|---|---|
| **Anvil** (local) | `DeployAnvil.s.sol` | AAStar + DemoCommunity | aPNTs + dPNTs | Yes (AOA paymaster, AA accounts) |
| **Sepolia / OP-Sepolia** (testnet) | `DeployLive.s.sol` | AAStar + Mycelium | aPNTs + PNTs | Yes (prepare-test + RegisterEnduser) |
| **OP Mainnet / Mainnet** (production) | `DeployLive.s.sol` | AAStar + Mycelium | aPNTs + PNTs | **NO** — no prepare-test |

---

## Anvil (Local Dev / CI)

Script: `contracts/script/v3/DeployAnvil.s.sol`  
Runner: `./deploy-core anvil`

### Communities Registered

| Community | Role | Admin | Token | Notes |
|---|---|---|---|---|
| **AAStar** | `ROLE_COMMUNITY` + `ROLE_PAYMASTER_SUPER` | deployer (`0xf39F...`) | **aPNTs** ("AAStar PNTs", symbol "aPNTs") | Protocol token; used for all SP deposits |
| **DemoCommunity** | `ROLE_COMMUNITY` + `ROLE_PAYMASTER_SUPER` | Anni (`0x7099...` Anvil #1) | **dPNTs** ("DemoPoints", symbol "dPNTs") | Test-only community; simulates a real operator |

### Token Balances After Deploy

| Address | aPNTs | dPNTs | GToken |
|---|---|---|---|
| deployer | 1,000 (deposited to SP) | — | ~1,970 (remainder after staking) |
| Anni | 1,000 (deposited to SP) | 500 | 100 |

### `prepare-test anvil` also adds

- Anni gets `ROLE_PAYMASTER_AOA` + deploys V4 AOA paymaster proxy
- EntryPoint deposit: 0.05 ETH for Anni's V4 paymaster
- Price cache refresh for both SP and V4

---

## Testnet (Sepolia / OP-Sepolia)

Script: `contracts/script/v3/DeployLive.s.sol`  
Runner: `./deploy-core sepolia` or `./deploy-core op-sepolia`

### Communities Registered (Same Real Names as Mainnet)

| Community | Role(s) | Admin | Token | Notes |
|---|---|---|---|---|
| **AAStar** | `ROLE_COMMUNITY` + `ROLE_PAYMASTER_AOA` | deployer (`DEPLOYER_ADDRESS` from `.env`) | **aPNTs** ("AAStar PNTs", "aPNTs", rate 1e18) | Protocol governance token; 20,000 aPNTs minted at deploy |
| **Mycelium Community** | `ROLE_COMMUNITY` + `ROLE_PAYMASTER_SUPER` | Anni (`PRIVATE_KEY_ANNI` from `.env`) | **PNTs** ("Mycelium PNTs", "PNTs", rate 1e18) | First partner community; Anni is the operator |

### Token Balances After Deploy

| Address | aPNTs | PNTs | GToken | ETH |
|---|---|---|---|---|
| deployer | 19,000 (20k minted - 1k sent to Anni) | — | ~1,950 | depleted by gas + 0.35 ETH deposited to SP/EP |
| Anni | 0 (1,000 deposited to SP) | 500 | — | needs ETH for txs |

### Additional Testnet Setup (NOT for mainnet)

Run after `deploy-core`:

| Step | Script/Command | What it does |
|---|---|---|
| `./prepare-test sepolia` | `TestAccountPrepare.s.sol` | Anni gets `ROLE_PAYMASTER_AOA` + V4 paymaster proxy; price cache refresh |
| `forge script RegisterEnduser.s.sol` | `RegisterEnduser.s.sol` | Registers AA test accounts as `ROLE_ENDUSER`, sets SBT holder status |
| `node setup-gasless.js` | gasless-tests setup | Tops up EP deposits, refreshes price cache for E2E tests |

---

## Production Mainnet (OP Mainnet / Ethereum Mainnet)

Script: `contracts/script/v3/DeployLive.s.sol` (same as testnet)  
Runner: `./deploy-core optimism` or `./deploy-core mainnet`

### Communities Registered (Identical to Testnet Script)

| Community | Role(s) | Admin | Token | Notes |
|---|---|---|---|---|
| **AAStar** | `ROLE_COMMUNITY` + `ROLE_PAYMASTER_AOA` | deployer (hardware wallet / keystore) | **aPNTs** ("AAStar PNTs", "aPNTs", rate 1e18) | |
| **Mycelium Community** | `ROLE_COMMUNITY` + `ROLE_PAYMASTER_SUPER` | Anni (separate key, PRIVATE_KEY_ANNI) | **PNTs** ("Mycelium PNTs", "PNTs", rate 1e18) | |

### What is DIFFERENT from testnet

| Item | Testnet | Production Mainnet |
|---|---|---|
| `prepare-test` | ✅ Run after deploy | ❌ **DO NOT run** — no test accounts |
| `RegisterEnduser.s.sol` | ✅ Run for E2E setup | ❌ **DO NOT run** — ENDUSER registration is user-initiated via dApp |
| `setup-gasless.js` | ✅ Run before E2E | ❌ **DO NOT run** |
| ERC-8004 agent registries | Testnet addresses auto-detected | Mainnet addresses auto-detected |
| `priceFeed` | Sepolia: `0x694AA...` (Chainlink ETH/USD Sepolia) | OP Mainnet: set in `.env.optimism` |
| `ENTRY_POINT` | `0x000...71727...` (same) | `0x000...71727...` (same) |
| Initial aPNTs mint | 20,000 (same) | 20,000 (same) |
| `deploy-core` mode | `DeployLive` (first) or `UpgradeLive` (upgrade) | Same — **always `UpgradeLive` after first deploy** |

### What `deploy-core` does NOT do for mainnet (and should never do)

- Does NOT register any ENDUSER roles (users self-register via dApp)
- Does NOT mint tokens to test AA accounts
- Does NOT fund arbitrary test wallets
- Does NOT set up PaymasterV4 AOA paymasters for anyone other than deployer
- Does NOT call `RegisterEnduser.s.sol`

---

## UUPS Upgrade Policy (from v5.3.3-beta)

For **all live networks** (Sepolia, OP-Sepolia, OP Mainnet, Mainnet):

```
# First-time deploy on a new network (no config.json yet):
./deploy-core <env>             # auto-routes to DeployLive

# All subsequent upgrades (preserves proxy addresses + on-chain state):
./deploy-core <env>             # auto-routes to UpgradeLive (UUPS)
./deploy-core <env> --force     # override hash check, still UpgradeLive

# DANGER — only for disaster recovery on a brand-new network:
./deploy-core <env> --fresh-deploy  # re-deploys new proxies (LOSES ALL STATE, requires confirmation)
```

Script routing:
- `DeployAnvil.s.sol` — Anvil only (fresh every time, EVM resets)  
- `DeployLive.s.sol` — First deploy on a live network (creates new UUPS proxies)
- `UpgradeLive.s.sol` — All subsequent upgrades (SP + Registry UUPS, state preserved)

---

## Key Env Variables per Environment

| Variable | Anvil | Sepolia | OP Mainnet |
|---|---|---|---|
| `PRIVATE_KEY_ANNI` | `0x59c6...` (Anvil #1, default) | Real key in `.env.sepolia` | Real key in `.env.optimism` |
| `ETH_USD_FEED` | Mock address | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | OP Mainnet Chainlink feed |
| `ENTRY_POINT` | Deployed by script | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Same |
| `SIMPLE_ACCOUNT_FACTORY` | Deployed by script | `0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985` | OP Mainnet address |
| ERC-8004 Identity | Mock (`MockAgentIdentityRegistry`) | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` |
| ERC-8004 Reputation | Mock (`MockAgentReputationRegistry`) | `0x8004B663056A597Dffe9eCcC1965A193B7388713` | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` |
| ERC-8004 Validation | `address(0)` | `0x8004Cb1BF31DAf7788923b405b754f57acEB4272` | `0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58` |
