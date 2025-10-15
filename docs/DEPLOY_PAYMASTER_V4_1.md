# PaymasterV4_1 Deployment Guide

This guide explains how to deploy PaymasterV4_1 with Registry management capabilities.

## Prerequisites

- Foundry installed (`forge`, `cast`)
- Private key with sufficient ETH for deployment
- EntryPoint v0.7 address (Sepolia: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`)
- SuperPaymasterRegistry address (optional, can be set post-deployment)

## Step 1: Configure Environment

1. Copy the example environment file:
```bash
cd contracts/script
cp .env.example.v4_1 .env
```

2. Edit `.env` and fill in the required values:
```bash
# Required
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
PRIVATE_KEY=0x...
ENTRY_POINT=0x0000000071727De22E5E9d8BAf0edAc6f37da032
OWNER_ADDRESS=0x...
TREASURY_ADDRESS=0x...

# Optional (can be set later via contract calls)
REGISTRY_ADDRESS=0x...
SBT_ADDRESS=0x...
GAS_TOKEN_ADDRESS=0x...

# Pricing parameters
GAS_TO_USD_RATE=4500000000000000000000  # $4500/ETH
PNT_PRICE_USD=20000000000000000         # $0.02/PNT
SERVICE_FEE_RATE=200                     # 2%
MAX_GAS_COST_CAP=1000000000000000000    # 1 ETH
MIN_TOKEN_BALANCE=1000000000000000000000 # 1000 PNT
```

## Step 2: Deploy PaymasterV4_1

### Dry Run (Simulation)
```bash
cd contracts
forge script script/DeployPaymasterV4_1.s.sol:DeployPaymasterV4_1 \
  --rpc-url $SEPOLIA_RPC_URL
```

### Actual Deployment
```bash
forge script script/DeployPaymasterV4_1.s.sol:DeployPaymasterV4_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

### Deployment Output
The script will:
1. Deploy PaymasterV4_1 contract
2. Set Registry address (if provided)
3. Add initial SBT (if provided)
4. Add initial GasToken (if provided)
5. Save deployment info to `deployments/paymaster-v4_1-sepolia.json`

Example output:
```
=== PaymasterV4_1 Deployment ===
EntryPoint: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
Owner: 0x...
Treasury: 0x...
GasToUSDRate: 4500000000000000000000
PntPriceUSD: 20000000000000000
ServiceFeeRate: 200 bps
MaxGasCostCap: 1000000000000000000
MinTokenBalance: 1000000000000000000000

=== Deployment Successful ===
PaymasterV4_1: 0x...
Version: PaymasterV4.1-Registry-v1.1.0
Registry configured: 0x...
Registry set: true

Deployment info saved to: deployments/paymaster-v4_1-sepolia.json
```

## Step 3: Post-Deployment Setup

### 3.1 Deposit ETH to EntryPoint
Paymaster needs ETH deposit in EntryPoint to sponsor gas:

```bash
cast send <PAYMASTER_ADDRESS> \
  "addDeposit()" \
  --value 1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

Check deposit:
```bash
cast call $ENTRY_POINT \
  "balanceOf(address)(uint256)" \
  <PAYMASTER_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL
```

### 3.2 Add Stake to EntryPoint
Paymaster must stake ETH in EntryPoint (required for reputation):

```bash
# Stake 0.1 ETH with 1 day unstake delay
cast send <PAYMASTER_ADDRESS> \
  "addStake(uint32)" \
  86400 \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

Check stake:
```bash
cast call $ENTRY_POINT \
  "getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))" \
  <PAYMASTER_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL
```

### 3.3 Set Registry Address (if not set during deployment)
```bash
cast send <PAYMASTER_ADDRESS> \
  "setRegistry(address)" \
  <REGISTRY_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 3.4 Add SBT and GasTokens (if not added during deployment)
```bash
# Add SBT
cast send <PAYMASTER_ADDRESS> \
  "addSBT(address)" \
  <SBT_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# Add GasToken
cast send <PAYMASTER_ADDRESS> \
  "addGasToken(address)" \
  <GAS_TOKEN_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 3.5 Register to SuperPaymasterRegistry
Call Registry's registration function (from Registry owner):

```bash
# This is typically done by Registry operator
cast send <REGISTRY_ADDRESS> \
  "registerPaymaster(address,string,uint256)" \
  <PAYMASTER_ADDRESS> \
  "My Paymaster" \
  200 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $REGISTRY_OWNER_PRIVATE_KEY
```

## Step 4: Verify Deployment

### Check Paymaster Configuration
```bash
# Check version
cast call <PAYMASTER_ADDRESS> "version()(string)" --rpc-url $SEPOLIA_RPC_URL

# Check Registry is set
cast call <PAYMASTER_ADDRESS> "isRegistrySet()(bool)" --rpc-url $SEPOLIA_RPC_URL

# Check active status in Registry
cast call <PAYMASTER_ADDRESS> "isActiveInRegistry()(bool)" --rpc-url $SEPOLIA_RPC_URL

# Check owner
cast call <PAYMASTER_ADDRESS> "owner()(address)" --rpc-url $SEPOLIA_RPC_URL

# Check pricing parameters
cast call <PAYMASTER_ADDRESS> "gasToUSDRate()(uint256)" --rpc-url $SEPOLIA_RPC_URL
cast call <PAYMASTER_ADDRESS> "pntPriceUSD()(uint256)" --rpc-url $SEPOLIA_RPC_URL
cast call <PAYMASTER_ADDRESS> "serviceFeeRate()(uint256)" --rpc-url $SEPOLIA_RPC_URL
```

### Check EntryPoint Status
```bash
# Check deposit balance
cast call $ENTRY_POINT \
  "balanceOf(address)(uint256)" \
  <PAYMASTER_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL

# Check stake info
cast call $ENTRY_POINT \
  "getDepositInfo(address)((uint256,bool,uint112,uint32,uint48))" \
  <PAYMASTER_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL
```

## Deactivate Paymaster (Operator Management)

When you want to stop accepting new gas payment requests:

```bash
# Owner calls deactivateFromRegistry()
cast send <PAYMASTER_ADDRESS> \
  "deactivateFromRegistry()" \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

After deactivation:
- Paymaster stops accepting new UserOperations
- Existing transactions continue to be processed
- Unstake and withdrawal processes can proceed

## Complete Exit Flow

To fully exit the SuperPaymaster protocol:

1. **Deactivate**: Stop accepting new requests
```bash
cast send <PAYMASTER_ADDRESS> "deactivateFromRegistry()" ...
```

2. **Wait for Settlement**: Ensure all pending transactions are settled

3. **Unlock Stake**: Initiate unstake (must wait unstakeDelay)
```bash
cast send <PAYMASTER_ADDRESS> "unlockStake()" --rpc-url $SEPOLIA_RPC_URL ...
```

4. **Withdraw Stake**: After unstakeDelay period
```bash
cast send <PAYMASTER_ADDRESS> \
  "withdrawStake(address)" \
  <RECIPIENT_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL ...
```

5. **Withdraw Deposit**: Withdraw remaining ETH from EntryPoint
```bash
cast send <PAYMASTER_ADDRESS> \
  "withdrawTo(address,uint256)" \
  <RECIPIENT_ADDRESS> \
  <AMOUNT> \
  --rpc-url $SEPOLIA_RPC_URL ...
```

## Troubleshooting

### Issue: Transaction reverts with "PaymasterV4__ZeroAddress"
**Solution**: Ensure all required addresses (EntryPoint, Owner, Treasury) are non-zero in `.env`

### Issue: "PaymasterV4_1__RegistryNotSet" when calling deactivateFromRegistry()
**Solution**: Call `setRegistry(address)` first to configure Registry address

### Issue: Unable to register to Registry
**Solution**: Ensure Paymaster has sufficient stake in EntryPoint and meets Registry's qualification requirements

### Issue: Deployment verification fails
**Solution**: Add `--etherscan-api-key $ETHERSCAN_API_KEY` to deployment command

## Security Considerations

1. **Owner Address**: Use a multisig wallet for production deployments
2. **Private Keys**: Never commit `.env` file or expose private keys
3. **Initial Parameters**: Carefully review all pricing parameters before deployment
4. **Registry Address**: Verify Registry contract address before setting
5. **Stake Amount**: Ensure sufficient stake to meet Registry requirements

## References

- [PaymasterV4_1 Contract](../contracts/src/v3/PaymasterV4_1.sol)
- [Deployment Script](../contracts/script/DeployPaymasterV4_1.s.sol)
- [Phase 2 Plan](./PHASE2_UNIFIED_PLAN.md)
- [ERC-4337 EntryPoint Spec](https://eips.ethereum.org/EIPS/eip-4337)
