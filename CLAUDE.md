# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

# Full regression (deploy to anvil + on-chain verification scripts)
./run_full_regression.sh

# Deploy core contracts to a target environment
./deploy-core <env>          # env: anvil, sepolia, op-sepolia, optimism
./deploy-core anvil --force  # force redeploy even if code unchanged

# Prepare test accounts after deployment
./prepare-test <env>

# Initialize git submodules (first-time setup)
./init-submoduel.sh
```

## Architecture

### Contract Structure (`contracts/src/`)

**Core contracts** (deployment order matters):
1. `tokens/GToken.sol` — ERC20 governance token (capped, mintable)
2. `core/GTokenStaking.sol` — Role-based staking with true burn mechanism
3. `core/Registry.sol` — Community/node registration, slashing, role management
4. `tokens/MySBT.sol` — Soulbound Token for identity + reputation tracking
5. `paymasters/superpaymaster/v3/SuperPaymaster.sol` — AOA+ shared paymaster (Chainlink oracle, xPNTs pricing, debt tracking)
6. `tokens/xPNTsFactory.sol` + `xPNTsToken.sol` — Community gas token factory
7. `paymasters/v4/Paymaster.sol` + `PaymasterBase.sol` + `core/PaymasterFactory.sol` — AOA independent mode

**Supporting modules:**
- `modules/validators/BLSValidator.sol` — BLS signature validation
- `modules/monitoring/DVTValidator.sol` + `BLSAggregator.sol` — Distributed validator technology
- `modules/reputation/ReputationSystem.sol` — Reputation scoring

**Interfaces** are in `contracts/src/interfaces/` (v3-specific in `interfaces/v3/`).

### Dependency Graph

SuperPaymaster depends on Registry and Chainlink price feeds. Registry depends on GTokenStaking. MySBT integrates with GToken, GTokenStaking, and Registry. PaymasterV4 instances are created via PaymasterFactory and registered in Registry.

### Key External Dependencies

- **OpenZeppelin v5.0.2** (via `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/`)
- **Account Abstraction v7** (via `singleton-paymaster/lib/account-abstraction-v7/`)
- **Chainlink** price feeds (via `contracts/lib/chainlink-brownie-contracts/`)
- **Solady** utilities (via `contracts/lib/solady/`)
- **Pimlico's singleton-paymaster** (git submodule, base paymaster implementation)

### Remappings (from `foundry.toml`)

```
@openzeppelin/contracts/ → contracts/lib/openzeppelin-contracts/contracts/
@openzeppelin-v5.0.2/   → singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/
@account-abstraction-v7/ → singleton-paymaster/lib/account-abstraction-v7/contracts/
@chainlink/contracts/    → contracts/lib/chainlink-brownie-contracts/contracts/
solady/                  → contracts/lib/solady/src/
src/                     → contracts/src/
```

### Deployment & Configuration

- **Deployment scripts**: `contracts/script/` (Forge scripts, `*.s.sol`)
  - V3 deployment: `contracts/script/v3/`
  - On-chain verification checks: `contracts/script/checks/` (Check01-Check09, VerifyV3_1_1)
- **Environment files**: `.env.<network>` (anvil, sepolia, op-sepolia, optimism, mainnet)
- **Deployment configs**: `deployments/config.<network>.json` — stores deployed addresses + source hash for skip-if-unchanged logic
- **ABIs**: `abis/` — extracted ABIs for SDK consumption
- **Shared config**: Contract addresses consumed via `@aastar/shared-config` npm package

### Test Structure (`contracts/test/`)

- `v3/` — V3 contract tests (Registry, MySBT, SuperPaymaster, credit system, DVT slashing, reputation)
- `v4/` — PaymasterV4 tests (security, optimizations)
- `paymasters/superpaymaster/v3/` — SuperPaymaster-specific tests (pricing, security, refund, verification hardening)
- `modules/` — DVT/BLS validator tests
- `tokens/` — xPNTsFactory tests

### Compiler Settings

- Solidity 0.8.33, optimizer enabled (10000 runs), via_ir = true, EVM target: cancun

## Conventions

- All code comments in English
- All conversation responses in Chinese (中文)
- Contract versioning embedded in `version()` functions (e.g., `"Registry-3.0.2"`, `"Staking-3.1.2"`)
- EntryPoint v0.7 address: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`
