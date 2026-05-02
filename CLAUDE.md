# CLAUDE.md

## Mycelium Protocol 生态上下文

@/Users/jason/Dev/Brood/protocol/MISSION.md
@/Users/jason/Dev/Brood/orgs/aastar/PROFILE.md
@/Users/jason/Dev/Brood/orgs/aastar/INTERFACES.md

## Project Overview

SuperPaymaster is a **decentralized gas payment infrastructure** for ERC-4337 Account Abstraction, built with Foundry (Solidity 0.8.33). It enables communities to sponsor gas fees for users via community tokens (xPNTs) instead of ETH.

Two operating modes:
- **AOA+ Mode** (SuperPaymaster): Shared multi-operator paymaster with Registry-based community management
- **AOA Mode** (PaymasterV4): Independent per-community paymasters deployed via EIP-1167 minimal proxy factory

## Build & Test Commands

```bash
# Build all contracts
forge build

# Build only V3 contracts (faster, for deployment)
forge build --profile v3-only

# Run all Foundry tests
forge test

# Run a specific test file
forge test --match-path contracts/test/v3/Registry.t.sol

# Run a specific test function
forge test --match-test testRegisterCommunity

# Run tests with verbosity
forge test -vvvv

# Run tests with gas report
forge test --gas-report

# Echidna fuzz testing
echidna . --config echidna.yaml
echidna . --config echidna-long-run.yaml    # Extended run
echidna . --config echidna-all-contracts.yaml

# Full regression (deploy to anvil + all verification checks)
./run_full_regression.sh

# Deploy core contracts to a target environment
./deploy-core <env>          # env: anvil, sepolia, op-sepolia, optimism
./deploy-core anvil --force  # force redeploy even if code unchanged

# Prepare test accounts after deployment
./prepare-test <env>

# E2E gasless tests (requires deployed contracts + node_modules)
cd script/gasless-tests && ./run-all-tests.sh

# Check deployed contract versions on-chain
./version-check-onchain.sh

# Initialize git submodules (first-time setup)
./init-submoduel.sh
```

## Architecture

### Contract Structure (`contracts/src/`)

**Core contracts** (deployment order matters):
1. `tokens/GToken.sol` — ERC20 governance token (21M cap, mintable, burnable)
2. `core/GTokenStaking.sol` — Role-based staking with true burn mechanism
3. `tokens/MySBT.sol` — Soulbound Token for identity + reputation tracking
4. `core/Registry.sol` — Community/node registration, slashing, role management
5. `tokens/xPNTsFactory.sol` + `xPNTsToken.sol` — Community gas token factory (Clones-based)
6. `paymasters/superpaymaster/v3/SuperPaymaster.sol` — AOA+ shared paymaster (Chainlink oracle, xPNTs pricing, debt tracking)
7. `paymasters/v4/Paymaster.sol` + `PaymasterBase.sol` + `core/PaymasterFactory.sol` — AOA independent mode (EIP-1167 proxies)

**Supporting modules:**
- `modules/validators/BLSValidator.sol` — BLS signature validation (BLS12-381 pairing)
- `modules/monitoring/DVTValidator.sol` + `BLSAggregator.sol` — Distributed validator technology
- `modules/reputation/ReputationSystem.sol` — Reputation scoring with community rules

**Interfaces** are in `contracts/src/interfaces/` (v3-specific in `interfaces/v3/`).

### Dependency Graph

SuperPaymaster depends on Registry and Chainlink price feeds. Registry depends on GTokenStaking. MySBT integrates with GToken, GTokenStaking, and Registry. PaymasterV4 instances are created via PaymasterFactory and registered in Registry. Both paymaster modes share the same Registry.

### Key External Dependencies

- **OpenZeppelin v5.0.2** (via `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/`)
- **Account Abstraction v7** (via `singleton-paymaster/lib/account-abstraction-v7/`)
- **Chainlink** price feeds (via `contracts/lib/chainlink-brownie-contracts/`)
- **Solady** utilities (via `contracts/lib/solady/`)
- **Pimlico's singleton-paymaster** (git submodule, base paymaster implementation)

### Remappings (from `foundry.toml`)

```
@openzeppelin/contracts/   → contracts/lib/openzeppelin-contracts/contracts/
@openzeppelin-v5.0.2/     → singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/
@account-abstraction-v7/  → singleton-paymaster/lib/account-abstraction-v7/contracts/
account-abstraction/       → lib/account-abstraction/contracts/
@chainlink/contracts/      → contracts/lib/chainlink-brownie-contracts/contracts/
solady/                    → contracts/lib/solady/src/
singleton-paymaster/       → singleton-paymaster/
src/                       → contracts/src/
```

### Foundry Path Quirk

`foundry.toml` sets `script = "script"` (root-level `script/` dir), but the actual Forge `.s.sol` scripts live under `contracts/script/`. Shell scripts like `deploy-core` invoke them with full paths: `forge script "contracts/script/v3/DeployAnvil.s.sol:DeployAnvil"`.

### Deployment & Configuration

**Deployment workflow** (`deploy-core`):
1. Loads `.env.<env>` for RPC URL and credentials
2. Computes SHA256 hash of all `contracts/src/*.sol` files; skips deploy if hash matches stored config (non-anvil, no `--force`)
3. Signer priority: `DEPLOYER_ACCOUNT` (Foundry keystore) > `PRIVATE_KEY` (plaintext) > anvil default key
4. Runs `DeployAnvil.s.sol` or `DeployLive.s.sol` based on environment
5. Runs 7 verification check scripts (Check01–Check08, VerifyV3_1_1)

**Key paths:**
- **Forge deployment scripts**: `contracts/script/v3/` (DeployAnvil, DeployLive, TestAccountPrepare)
- **Verification checks**: `contracts/script/checks/` (Check01–Check09, VerifyV3_1_1)
- **Step-by-step deployment**: `contracts/script/deployment/` (01–13 individual contract steps)
- **Environment files**: `.env.<network>` (anvil, sepolia, op-sepolia, optimism, mainnet); `.env` is a symlink to `../env/.env.v3`
- **Deployment configs**: `deployments/config.<network>.json` — stores all deployed addresses + `srcHash` for skip-if-unchanged logic
- **ABIs**: `abis/` — extracted ABI JSONs synced to SDK via `sync_to_sdk.sh`
- **Helper scripts**: `scripts/` — ABI extraction, gasless test helpers, environment sync tools

### Test Structure (`contracts/test/`)

- `v3/` — Comprehensive V3 suite (Registry, MySBT, SuperPaymaster admin/pricing, credit system, DVT slashing, reputation, xPNTs security)
- `v4/` — PaymasterV4 tests (security, optimizations)
- `paymasters/superpaymaster/v3/` — SuperPaymaster-specific tests (pricing, security, refund, verification hardening)
- `modules/` — DVT/BLS validator tests
- `tokens/` — xPNTsFactory tests

### Subgraph

`subgraph/` contains The Graph indexing config (`schema.graphql`, `subgraph.yaml`) for on-chain event indexing.

### CI

`.github/workflows/check-secrets.yml` scans for leaked private keys and API secrets on push/PR to main/master/develop.

### Compiler Settings

Solidity 0.8.33, optimizer enabled (10000 runs), via_ir = true, EVM target: cancun

## Conventions

- All code comments in English
- All conversation responses in Chinese (中文)
- Contract versioning embedded in `version()` functions (e.g., `"Registry-3.0.2"`, `"SuperPaymaster-3.2.2"`, `"PaymasterV4-4.3.0"`)
- EntryPoint v0.7 address: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`
