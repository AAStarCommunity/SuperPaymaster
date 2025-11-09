# Safe Multisig Wallet Integration Guide

## Overview

This guide explains how to transfer community ownership to a [Safe](https://safe.global) multisig wallet for enterprise-grade governance.

## Why Use Safe Multisig?

- **Security**: Require multiple signatures for critical operations
- **Governance**: Distribute control among team members
- **Transparency**: All transactions are on-chain and auditable
- **Recovery**: No single point of failure

## What Gets Transferred?

When you transfer community ownership to Safe, the following contracts are transferred:

1. **Registry Community Profile** (always)
   - Community metadata and settings
   - Required for all modes (AOA and AOA+)

2. **PaymasterV4 Contract** (AOA mode only)
   - Independent Paymaster contract
   - Controls gas sponsorship settings

3. **xPNTs Token Contract** (if deployed)
   - Community points token
   - Controls tokenomics and minting

## Prerequisites

1. **Create a Safe Wallet**
   - Go to https://app.safe.global
   - Create a new Safe on Sepolia testnet
   - Add signers (recommend 2-of-3 or 3-of-5)
   - Note down the Safe address

2. **Verify Current Ownership**
   - You must be the current owner of the community
   - Verify ownership on Registry Explorer

## Step-by-Step Guide

### Step 1: Generate Safe Batch Transaction

```bash
# Set environment variables
export CURRENT_OWNER=0xYourCurrentOwnerAddress
export SAFE_ADDRESS=0xYourSafeMultisigAddress
export REGISTRY_V2_2_1=0x49245E1f3c2dD99b3884ffeD410d0605Cf4dC696

# Optional: For AOA mode with independent Paymaster
export PAYMASTER_ADDRESS=0xYourPaymasterV4Address

# Optional: If you have custom xPNTs token
export XPNTS_TOKEN_ADDRESS=0xYourXPNTsTokenAddress

# Generate Safe transaction JSON
forge script script/safe/GenerateSafeBatchTx.s.sol:GenerateSafeBatchTx \
  --rpc-url $SEPOLIA_RPC_URL \
  -vvv > safe-tx.json
```

### Step 2: Review Generated JSON

The script will output a Safe Transaction Builder compatible JSON:

```json
{
  "version": "1.0",
  "chainId": "11155111",
  "meta": {
    "name": "Community Ownership Transfer to Safe",
    "description": "Batch transfer of community ownership to Safe multisig wallet"
  },
  "transactions": [
    {
      "to": "0x49245E1f3c2dD99b3884ffeD410d0605Cf4dC696",
      "value": "0",
      "contractMethod": {
        "name": "transferCommunityOwnership",
        "inputs": [{"name": "newOwner", "type": "address"}]
      },
      "contractInputsValues": {
        "newOwner": "0xYourSafeAddress"
      }
    }
  ]
}
```

### Step 3: Import to Safe Transaction Builder

1. Go to https://app.safe.global
2. Connect your wallet (current owner)
3. Select your Safe
4. Navigate to: **New Transaction** → **Transaction Builder**
5. Click **"Upload JSON"**
6. Upload the generated `safe-tx.json` file
7. Review all transactions carefully
8. Click **"Create Batch"**

### Step 4: Sign and Execute

1. **First Signature**: Sign the transaction with your wallet
2. **Additional Signatures**: Share transaction link with other signers
3. **Execute**: Once threshold is met, execute the transaction
4. **Verify**: Check Registry Explorer to confirm new owner

## Example Scenarios

### Scenario 1: AOA Mode Community (Independent Paymaster)

```bash
export CURRENT_OWNER=0x411BD567E46C0781248dbB6a9211891C032885e5
export SAFE_ADDRESS=0xYourSafeAddress
export PAYMASTER_ADDRESS=0xYourPaymasterV4Address
export XPNTS_TOKEN_ADDRESS=0xYourXPNTsTokenAddress

forge script script/safe/GenerateSafeBatchTx.s.sol:GenerateSafeBatchTx \
  --rpc-url $SEPOLIA_RPC_URL -vvv
```

**Transfers:**
- Registry community ownership → Safe
- PaymasterV4 ownership → Safe
- xPNTs token ownership → Safe

### Scenario 2: AOA+ Mode Community (SuperPaymaster)

```bash
export CURRENT_OWNER=0x411BD567E46C0781248dbB6a9211891C032885e5
export SAFE_ADDRESS=0xYourSafeAddress
# No PAYMASTER_ADDRESS (uses shared SuperPaymaster)
export XPNTS_TOKEN_ADDRESS=0xYourXPNTsTokenAddress

forge script script/safe/GenerateSafeBatchTx.s.sol:GenerateSafeBatchTx \
  --rpc-url $SEPOLIA_RPC_URL -vvv
```

**Transfers:**
- Registry community ownership → Safe
- xPNTs token ownership → Safe
- SuperPaymaster operator account stays with original owner (multi-user system)

### Scenario 3: Minimal Transfer (Registry Only)

```bash
export CURRENT_OWNER=0x411BD567E46C0781248dbB6a9211891C032885e5
export SAFE_ADDRESS=0xYourSafeAddress
# No optional contracts

forge script script/safe/GenerateSafeBatchTx.s.sol:GenerateSafeBatchTx \
  --rpc-url $SEPOLIA_RPC_URL -vvv
```

**Transfers:**
- Registry community ownership → Safe only

## After Transfer

### Managing Community as Safe

Once ownership is transferred to Safe, all community management operations require Safe signatures:

1. **Update Community Settings**
   - Modify community profile
   - Update supported SBTs
   - Toggle permissionless minting

2. **Paymaster Management** (AOA mode)
   - Adjust service fees
   - Update gas price settings
   - Deposit EntryPoint balance

3. **Token Management**
   - Update xPNTs tokenomics
   - Manage minting permissions

### Required Signers

For each operation:
1. Navigate to Safe app
2. Create transaction (direct or Transaction Builder)
3. Collect required signatures
4. Execute when threshold is met

## Important Notes

### Security Best Practices

- **Verify Addresses**: Triple-check Safe address before transfer
- **Test First**: Consider testing on a test community first
- **Backup Access**: Ensure multiple trusted signers
- **Document Signers**: Keep record of all signer addresses
- **Review Transactions**: Always review batch transactions carefully

### Irreversible Transfer

⚠️ **WARNING**: Ownership transfer is irreversible from the individual wallet perspective!

- Once transferred to Safe, you need Safe signatures to transfer back
- Ensure Safe is properly configured before transfer
- Test Safe functionality with a small transaction first

### AOA+ SuperPaymaster Considerations

For AOA+ mode communities:
- SuperPaymaster operator account is **NOT transferred**
- Only Registry community profile is transferred
- Operator can still manage their SuperPaymaster account independently
- This is by design (multi-operator system)

## Troubleshooting

### Transaction Fails: "Not Owner"

**Cause**: Current connected wallet is not the community owner
**Solution**: Connect wallet that currently owns the community

### Transaction Fails: "Community Not Found"

**Cause**: Registry address is incorrect
**Solution**: Verify Registry address in shared-config

### Safe Transaction Not Appearing

**Cause**: Wrong network selected in Safe app
**Solution**: Switch to Sepolia testnet in Safe app

### Insufficient Signers

**Cause**: Safe threshold not met
**Solution**: Collect more signatures from Safe owners

## Support

For issues or questions:
- Check [Safe Documentation](https://docs.safe.global)
- Review Registry contract on Etherscan
- Contact AAStar Community support

## Appendix: Contract Addresses (Sepolia)

```
Registry v2.2.1:      0x49245E1f3c2dD99b3884ffeD410d0605Cf4dC696
SuperPaymaster V2.1:  0xD6aa17587737C59cbb82986Afbac88Db75771857
GTokenStaking:        0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0
```

## Related Documentation

- [Safe Global Documentation](https://docs.safe.global)
- [Registry Contract Documentation](../contracts/Registry_v2_2_1.md)
- [Community Management Guide](./COMMUNITY_MANAGEMENT.md)
