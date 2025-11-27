# Community Registration Guide

**[English](#english)** | **[中文](#chinese)**

<a name="english"></a>

---

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

---

<a name="chinese"></a>

# 社区注册指南

**[English](#english)** | **[中文](#chinese)**

---

## 概述

本指南介绍如何使用 Registry 合约在 SuperPaymaster 生态系统中注册你的社区。

## 前提条件

注册前，请确保你拥有：

1. **GToken (GT)** - 最低质押要求：
   - AOA 模式（独立 Paymaster）：30 GT
   - AOA+ 模式（SuperPaymaster）：50 GT
   - ANODE（计算节点）：20 GT
   - KMS（密钥管理）：100 GT

2. **已质押的 GToken** - 你的 GT 必须在 GTokenStaking 中质押

3. **社区信息**：
   - 社区名称（唯一，最多 100 字符）
   - ENS 名称（可选，唯一）
   - xPNTs 代币地址（可选，可稍后添加）
   - 支持的 SBT 地址（可选，最多 10 个）

## 注册方法

### 方法 1：标准注册（预质押）

如果你已经有质押且可用的 GT 余额：

```solidity
// 1. 首先在 GTokenStaking 中质押 GT
GTokenStaking.stake(50 ether); // AOA+ 模式

// 2. 注册社区（这将锁定你的质押）
Registry.CommunityProfile memory profile = Registry.CommunityProfile({
    name: "我的社区",
    ensName: "mycommunity.eth",
    xPNTsToken: address(0),           // 稍后设置
    supportedSBTs: new address[](0),  // 稍后设置
    nodeType: Registry.NodeType.PAYMASTER_SUPER,
    paymasterAddress: address(0),     // 稍后设置
    community: address(0),            // 将设置为 msg.sender
    registeredAt: 0,                  // 将被设置
    lastUpdatedAt: 0,                 // 将被设置
    isActive: true,
    allowPermissionlessMint: true
});

Registry.registerCommunity(profile, 50 ether);
```

### 方法 2：自动质押注册（推荐）

单笔交易：授权 + 质押 + 锁定 + 注册

```solidity
// 1. 为 Registry 授权 GToken
GToken.approve(REGISTRY_ADDRESS, 50 ether);

// 2. 使用自动质押注册（一笔交易）
Registry.CommunityProfile memory profile = Registry.CommunityProfile({
    name: "我的社区",
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

## 节点类型

| 类型 | 枚举值 | 最低质押 | 用途 |
|------|--------|----------|------|
| `PAYMASTER_AOA` | 0 | 30 GT | 独立 paymaster 部署 |
| `PAYMASTER_SUPER` | 1 | 50 GT | 作为运营商加入 SuperPaymasterV2 |
| `ANODE` | 2 | 20 GT | 社区计算节点 |
| `KMS` | 3 | 100 GT | 密钥管理服务 |

## 注册后步骤

### 1. 部署 xPNTs 代币

```solidity
// 使用 xPNTsFactory
address xpntsToken = xPNTsFactory.deployxPNTsToken(
    "我的社区积分",        // 名称
    "MCP",                // 符号
    "我的社区",            // 社区名称
    "mycommunity.eth",    // ENS
    1 ether,              // 兑换率 (1:1)
    paymasterAddress      // 你的 paymaster（AOA+ 模式用 address(0)）
);
```

### 2. 更新社区资料

```solidity
// 添加 xPNTs 代币和支持的 SBT
Registry.CommunityProfile memory updatedProfile = existingProfile;
updatedProfile.xPNTsToken = xpntsToken;
updatedProfile.supportedSBTs = [MYSBT_ADDRESS];

Registry.updateCommunityProfile(updatedProfile);
```

### 3. AOA+ 模式：注册为运营商

```solidity
// 向 SuperPaymaster 存入 aPNTs
SuperPaymasterV2.depositAPNTs(
    operatorAddress,     // 你的地址
    1000 ether,          // aPNTs 数量
    xpntsToken,          // 你的 xPNTs 代币
    treasuryAddress,     // 用户支付去向
    1 ether              // 兑换率
);
```

## 查询社区

```solidity
// 通过地址
Registry.CommunityProfile memory profile = Registry.getCommunityProfile(communityAddress);

// 通过名称
address community = Registry.getCommunityByName("我的社区");

// 通过 ENS
address community = Registry.getCommunityByENS("mycommunity.eth");

// 通过 SBT
address community = Registry.getCommunityBySBT(sbtAddress);

// 列出所有
address[] memory communities = Registry.getCommunities(0, 100);
```

## 管理你的社区

### 停用/重新激活

```solidity
// 停用（停止接受新成员）
Registry.deactivateCommunity();

// 重新激活
Registry.reactivateCommunity();
```

### 转移所有权

```solidity
Registry.transferCommunityOwnership(newOwnerAddress);
```

### 切换无需许可铸造

```solidity
// 禁用无需许可铸造（需要审批）
Registry.setPermissionlessMint(false);

// 重新启用
Registry.setPermissionlessMint(true);
```

## Sepolia 测试网地址

| 合约 | 地址 |
|------|------|
| GToken | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| GTokenStaking | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` |
| Registry | `0xf384c592D5258c91805128291c5D4c069DD30CA6` |
| xPNTsFactory | `0x9dD72cB42427fC9F7Bf0c949DB7def51ef29D6Bd` |

## 常见错误

| 错误 | 原因 | 解决方案 |
|------|------|----------|
| `CommunityAlreadyRegistered` | 地址已注册 | 使用不同的地址 |
| `NameAlreadyTaken` | 名称已被占用 | 选择唯一名称 |
| `ENSAlreadyTaken` | ENS 已被注册 | 选择不同的 ENS |
| `InsufficientStake` | GT 质押不足 | 质押更多 GT |
| `InsufficientGTokenBalance` | 钱包 GT 不足 | 获取更多 GT |

## 后续步骤

- [部署 xPNTs 代币](./DEVELOPER_INTEGRATION_GUIDE.md)
- [Paymaster 运营指南](./PAYMASTER_OPERATOR_GUIDE.md)
- [合约架构](./CONTRACT_ARCHITECTURE.md)
