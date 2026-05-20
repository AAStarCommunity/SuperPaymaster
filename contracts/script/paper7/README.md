# Paper7 Gas Data Collection Scripts

## 3 scripts, run in order

### Step 1: Register DVT Validator (one-time, ~3 txs on-chain)
```bash
export ENV=sepolia
forge script contracts/script/paper7/RegisterDVTValidator.s.sol   --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvv
```
Requires: PRIVATE_KEY (owner of DVTValidator+BLSAggregator), >=33 GT balance

### Step 2: Execute mock DVT proposals (collects gas data)
```bash
forge script contracts/script/paper7/MockDVTExecution.s.sol   --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast -vvv
```
Sends createProposal + executeWithProof for batch sizes 1/10/50/100.
executeWithProof will REVERT (zero BLS sig), but gas is still measured.

### Step 3: Print gas report (read-only)
```bash
forge script contracts/script/paper7/CollectPaper7Gas.s.sol   --rpc-url $SEPOLIA_RPC_URL -vvv
```

## After Sepolia validates -> OP Mainnet
```bash
export ENV=optimism
# Run same 3 scripts with --rpc-url https://mainnet.optimism.io
```

## Prerequisites
- Jason EOA () owns DVTValidator+BLSAggregator (already is owner)
- Jason has COMMUNITY role (already has it)
- Jason has >= 33 GT in GToken balance

## Env template
```
cp contracts/script/paper7/.env.paper7.example .env.paper7
# fill in PRIVATE_KEY and SEPOLIA_RPC_URL
source .env.paper7
```
