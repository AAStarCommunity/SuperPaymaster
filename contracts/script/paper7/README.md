# Paper7 Gas Data Collection Scripts

## Setup
```bash
# Copy from existing .env.sepolia (PRIVATE_KEY + RPC_URL already there)
# Or manually:
cp contracts/script/paper7/.env.paper7.example .env.paper7
# fill in PRIVATE_KEY and SEPOLIA_RPC_URL

set -a && source .env.paper7 && set +a  # export all vars
```

## 3 scripts, run in order

### Step 1: Register DVT Validator (one-time, ~3 on-chain txs)
```bash
forge script contracts/script/paper7/RegisterDVTValidator.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --evm-version prague --broadcast -vvv
```
Requires: PRIVATE_KEY = owner of DVTValidator+BLSAggregator, >=33 GT balance.
Idempotent: skips steps already done on-chain.

### Step 2: Execute mock DVT proposals (~8 on-chain txs)
```bash
forge script contracts/script/paper7/MockDVTExecution.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --evm-version prague --broadcast -vvv
```
Sends createProposal + executeWithProof for batch sizes 1/10/50/100.
executeWithProof REVERTs (zero BLS sig) — expected. Gas before revert is still measured.

### Step 3: Print gas report (read-only, no broadcast)
```bash
forge script contracts/script/paper7/CollectPaper7Gas.s.sol \
  --rpc-url $SEPOLIA_RPC_URL --evm-version prague -vvv
```

## Notes
- `--evm-version prague` is required for EIP-2537 BLS precompiles (0x0b-0x14).
  Sepolia is post-Pectra so it has them; local cancun EVM does not.
- Dry-run (no --broadcast) works for Step 1. Step 2 dry-run will fail with
  "Not a validator" until Step 1 has been broadcast.

## After Sepolia validates -> OP Mainnet
```bash
export ENV=optimism
# Run same 3 scripts with --rpc-url https://mainnet.optimism.io
```

## Prerequisites
- Jason EOA owns DVTValidator + BLSAggregator (already owner)
- Jason has >= 33 GT in GToken balance on Sepolia
