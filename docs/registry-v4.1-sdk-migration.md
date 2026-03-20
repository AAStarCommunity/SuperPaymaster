# Registry v4.1.0 — SDK/Frontend Migration Guide

## Overview

Registry v4.1.0 consolidates 5 specialized admin functions into 2 unified functions to reduce contract bytecode size (EIP-170 compliance with UUPS proxy). **All capabilities are preserved** — only the calling pattern changes.

**Contract version**: `Registry-4.1.0`
**Optimizer**: 500 runs, via_ir=true, Cancun EVM

## Breaking ABI Changes

### Removed Functions

| Function | Signature | Selector |
|----------|-----------|----------|
| `createNewRole(bytes32,RoleConfig,address)` | `createNewRole(bytes32,(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256),address)` | removed |
| `setRoleOwner(bytes32,address)` | `setRoleOwner(bytes32,address)` | removed |
| `setRoleLockDuration(bytes32,uint256)` | `setRoleLockDuration(bytes32,uint256)` | removed |
| `setLevelThreshold(uint256,uint256)` | `setLevelThreshold(uint256,uint256)` | removed |
| `addLevelThreshold(uint256)` | `addLevelThreshold(uint256)` | removed |
| `roleOwners(bytes32)` (interface) | Getter still exists on-chain via public mapping, but removed from IRegistry | N/A |

### New/Modified Functions

| Function | Purpose |
|----------|---------|
| `configureRole(bytes32,RoleConfig)` | Now handles both creating new roles AND updating existing roles |
| `setLevelThresholds(uint256[])` | Replaces both `setLevelThreshold` and `addLevelThreshold` |

### Changed Error Types

All `require(... , "string")` reverts replaced with custom errors (4-byte selectors). If your SDK catches error strings, update to decode custom errors instead.

| Old Error String | New Custom Error | Selector |
|------------------|------------------|----------|
| `"Unauthorized Reputation Source"` | `UnauthorizedSource()` | `0x...` |
| `"Length mismatch"` | `LenMismatch()` | `0x...` |
| `"BLS proof required"` | `BLSProofRequired()` | `0x...` |
| `"Caller must be Community"` | `CallerNotCommunity()` | `0x...` |
| Various `"Invalid..."` strings | `InvalidParam()` | `0x...` |

---

## Migration Recipes (viem)

### 1. Create a New Role (was `createNewRole`)

```typescript
// BEFORE (v4.0.0)
await registry.write.createNewRole([
  roleId,
  { minStake: 10n * 10n**18n, entryBurn: 1n * 10n**18n, ... , owner: '0x0', roleLockDuration: 604800n },
  roleOwnerAddress  // separate param
]);

// AFTER (v4.1.0) — set owner IN the config struct
await registry.write.configureRole([
  roleId,
  {
    minStake: 10n * 10n**18n,
    entryBurn: 1n * 10n**18n,
    slashThreshold: 10,
    slashBase: 2,
    slashInc: 1,
    slashMax: 10,
    exitFeePercent: 1000,
    isActive: true,
    minExitFee: 1n * 10n**18n,
    description: "My Role",
    owner: roleOwnerAddress,    // <-- MUST be non-zero
    roleLockDuration: 604800n,  // 7 days in seconds
  }
]);
```

**Key difference**: `config.owner` MUST be set (non-zero address). For new roles (no existing config), only the contract owner can call. For existing roles, the role owner or contract owner can call.

### 2. Transfer Role Ownership (was `setRoleOwner`)

```typescript
// BEFORE
await registry.write.setRoleOwner([roleId, newOwnerAddress]);

// AFTER — read config, modify owner, write back
const config = await registry.read.getRoleConfig([roleId]);
await registry.write.configureRole([
  roleId,
  { ...config, owner: newOwnerAddress }
]);
```

### 3. Update Lock Duration (was `setRoleLockDuration`)

```typescript
// BEFORE
await registry.write.setRoleLockDuration([roleId, 0n]); // disable lock

// AFTER
const config = await registry.read.getRoleConfig([roleId]);
await registry.write.configureRole([
  roleId,
  { ...config, roleLockDuration: 0n }
]);
```

### 4. Update Level Thresholds (was `setLevelThreshold` + `addLevelThreshold`)

```typescript
// BEFORE — modify single index
await registry.write.setLevelThreshold([0, 20n]);  // change level 2 threshold
await registry.write.addLevelThreshold([1597n]);     // add level 7

// AFTER — pass the COMPLETE threshold array
// Default thresholds: [13, 34, 89, 233, 610]

// To change index 0 to 20:
await registry.write.setLevelThresholds([[20n, 34n, 89n, 233n, 610n]]);

// To add a new level:
await registry.write.setLevelThresholds([[13n, 34n, 89n, 233n, 610n, 1597n]]);

// To read current thresholds first:
// Note: levelThresholds is a public array, read each index
const thresholds: bigint[] = [];
for (let i = 0; ; i++) {
  try {
    thresholds.push(await registry.read.levelThresholds([BigInt(i)]));
  } catch { break; }
}
// Modify and write back
thresholds[0] = 20n;
await registry.write.setLevelThresholds([thresholds]);
```

### 5. Get Role Owner (was `roleOwners(bytes32)`)

```typescript
// BEFORE
const owner = await registry.read.roleOwners([roleId]);

// AFTER — use getRoleConfig
const config = await registry.read.getRoleConfig([roleId]);
const owner = config.owner;
```

> Note: The `roleOwners` public mapping getter still exists on-chain (storage cannot be removed in UUPS upgrades), but it may return stale data. Always use `getRoleConfig().owner` instead.

---

## Unchanged Functions (No Migration Needed)

These functions are **identical** in v4.0.0 and v4.1.0:

| Category | Functions |
|----------|-----------|
| **Registration** | `registerRole`, `exitRole`, `safeMintForRole` |
| **Reputation** | `batchUpdateGlobalReputation`, `updateOperatorBlacklist`, `setReputationSource` |
| **Credit** | `setCreditTier`, `getCreditLimit` |
| **View** | `hasRole`, `getRoleConfig`, `getUserRoles`, `getRoleUserCount`, `getRoleMembers` |
| **Admin** | `setStaking`, `setMySBT`, `setSuperPaymaster`, `setBLSAggregator`, `setBLSValidator` |
| **UUPS** | `upgradeToAndCall`, `proxiableUUID` |
| **Constants** | `ROLE_COMMUNITY`, `ROLE_ENDUSER`, `ROLE_PAYMASTER_AOA`, `ROLE_PAYMASTER_SUPER`, `ROLE_DVT`, `ROLE_ANODE`, `ROLE_KMS` |

---

## RoleConfig Struct (Unchanged)

```solidity
struct RoleConfig {
    uint256 minStake;        // Minimum stake required
    uint256 entryBurn;       // Amount burned on registration
    uint32  slashThreshold;  // Slash trigger threshold
    uint32  slashBase;       // Base slash amount
    uint32  slashInc;        // Slash increment per violation
    uint32  slashMax;        // Maximum slash amount
    uint16  exitFeePercent;  // Exit fee in basis points (100 = 1%, max 2000 = 20%)
    bool    isActive;        // Whether role accepts registrations
    uint256 minExitFee;      // Minimum exit fee amount
    string  description;     // Role description
    address owner;           // Role owner (can reconfigure)
    uint256 roleLockDuration; // Lock duration in seconds (0 = no lock)
}
```

---

## configureRole Authorization Logic

```
Is roleConfigs[roleId].owner == address(0)?
├── YES → New role → only contract owner() can call
└── NO  → Existing role → role owner OR contract owner() can call

Additional checks:
- config.owner MUST be non-zero (revert InvalidAddr)
- config.exitFeePercent MUST be ≤ 2000 (revert FeeTooHigh)
- Automatically syncs exit fee to GTokenStaking
```

---

## ABI File

After deployment, regenerate ABI from the new contract:

```bash
forge inspect Registry abi > abis/Registry.json
```

Or extract from build artifacts:

```bash
cat out/Registry.sol/Registry.json | jq '.abi' > abis/Registry.json
```
