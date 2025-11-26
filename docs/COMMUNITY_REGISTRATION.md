# Community Registration Guide

## Overview

This guide explains how to register your community in the SuperPaymaster ecosystem using the Registry contract.

## Prerequisites

Before registering, ensure you have:

1. **GToken (GT)** - Minimum stake requirements:
   - AOA Mode (Independent Paymaster): 30 GT
   - AOA+ Mode (SuperPaymaster): 50 GT
   - ANODE (Compute Node): 20 GT
   - KMS (Key Management): 100 GT

2. **Staked GToken** - Your GT must be staked in GTokenStaking

3. **Community Information**:
   - Community name (unique, max 100 characters)
   - ENS name (optional, unique)
   - xPNTs token address (optional, can add later)
   - Supported SBT addresses (optional, max 10)

## Registration Methods

### Method 1: Standard Registration (Pre-staked)

If you already have staked and available GT balance:

```solidity
// 1. First stake GT in GTokenStaking
GTokenStaking.stake(50 ether); // For AOA+ mode

// 2. Register community (this will lock your stake)
Registry.CommunityProfile memory profile = Registry.CommunityProfile({
    name: "My Community",
    ensName: "mycommunity.eth",
    xPNTsToken: address(0),           // Set later
    supportedSBTs: new address[](0),  // Set later
    nodeType: Registry.NodeType.PAYMASTER_SUPER,
    paymasterAddress: address(0),     // Set later
    community: address(0),            // Will be set to msg.sender
    registeredAt: 0,                  // Will be set
    lastUpdatedAt: 0,                 // Will be set
    isActive: true,
    allowPermissionlessMint: true
});

Registry.registerCommunity(profile, 50 ether);
```

### Method 2: Auto-Stake Registration (Recommended)

Single transaction: approve + stake + lock + register

```solidity
// 1. Approve GToken for Registry
GToken.approve(REGISTRY_ADDRESS, 50 ether);

// 2. Register with auto-stake (one transaction)
Registry.CommunityProfile memory profile = Registry.CommunityProfile({
    name: "My Community",
    ensName: "mycommunity.eth",
    xPNTsToken: address(0),
    supportedSBTs: new address[](0),
    nodeType: Registry.NodeType.PAYMASTER_SUPER,
    paymasterAddress: address(0),
    community: address(0),
    registeredAt: 0,
    lastUpdatedAt: 0,
    isActive: true,
    allowPermissionlessMint: true
});

Registry.registerCommunityWithAutoStake(profile, 50 ether);
```

## Node Types

| Type | Enum Value | Min Stake | Use Case |
|------|------------|-----------|----------|
| `PAYMASTER_AOA` | 0 | 30 GT | Independent paymaster deployment |
| `PAYMASTER_SUPER` | 1 | 50 GT | Join SuperPaymasterV2 as operator |
| `ANODE` | 2 | 20 GT | Community compute node |
| `KMS` | 3 | 100 GT | Key management service |

## Post-Registration Steps

### 1. Deploy xPNTs Token

```solidity
// Using xPNTsFactory
address xpntsToken = xPNTsFactory.deployxPNTsToken(
    "My Community Points",  // name
    "MCP",                  // symbol
    "My Community",         // community name
    "mycommunity.eth",      // ENS
    1 ether,                // exchange rate (1:1)
    paymasterAddress        // your paymaster (or address(0) for AOA+)
);
```

### 2. Update Community Profile

```solidity
// Add xPNTs token and supported SBTs
Registry.CommunityProfile memory updatedProfile = existingProfile;
updatedProfile.xPNTsToken = xpntsToken;
updatedProfile.supportedSBTs = [MYSBT_ADDRESS];

Registry.updateCommunityProfile(updatedProfile);
```

### 3. For AOA+ Mode: Register as Operator

```solidity
// Deposit aPNTs to SuperPaymaster
SuperPaymasterV2.depositAPNTs(
    operatorAddress,     // your address
    1000 ether,          // aPNTs amount
    xpntsToken,          // your xPNTs token
    treasuryAddress,     // where user payments go
    1 ether              // exchange rate
);
```

## Querying Communities

```solidity
// By address
Registry.CommunityProfile memory profile = Registry.getCommunityProfile(communityAddress);

// By name
address community = Registry.getCommunityByName("My Community");

// By ENS
address community = Registry.getCommunityByENS("mycommunity.eth");

// By SBT
address community = Registry.getCommunityBySBT(sbtAddress);

// List all
address[] memory communities = Registry.getCommunities(0, 100);
```

## Managing Your Community

### Deactivate/Reactivate

```solidity
// Deactivate (stops accepting new members)
Registry.deactivateCommunity();

// Reactivate
Registry.reactivateCommunity();
```

### Transfer Ownership

```solidity
Registry.transferCommunityOwnership(newOwnerAddress);
```

### Toggle Permissionless Mint

```solidity
// Disable permissionless minting (require approval)
Registry.setPermissionlessMint(false);

// Re-enable
Registry.setPermissionlessMint(true);
```

## Sepolia Testnet Addresses

| Contract | Address |
|----------|---------|
| GToken | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| GTokenStaking | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` |
| Registry | `0xf384c592D5258c91805128291c5D4c069DD30CA6` |
| xPNTsFactory | `0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd` |

## Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `CommunityAlreadyRegistered` | Address already registered | Use a different address |
| `NameAlreadyTaken` | Name is taken | Choose a unique name |
| `ENSAlreadyTaken` | ENS is registered | Choose a different ENS |
| `InsufficientStake` | Not enough GT staked | Stake more GT |
| `InsufficientGTokenBalance` | Wallet lacks GT | Acquire more GT |

## Next Steps

- [Deploy xPNTs Token](./DEVELOPER_INTEGRATION_GUIDE.md)
- [Paymaster Operator Guide](./PAYMASTER_OPERATOR_GUIDE.md)
- [Contract Architecture](./CONTRACT_ARCHITECTURE.md)
