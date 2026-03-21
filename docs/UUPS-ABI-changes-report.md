# ABI Changes Report: UUPS Migration (v3.x → v4.x)

> Generated: 2026-03-20 | Branch: `feature/uups-migration` vs `main`

## Executive Summary

The UUPS migration introduces **breaking ABI changes** across 4 contracts. SDK consumers must update their integration code before switching to v4.x contracts.

| Contract | Breaking Changes | Non-Breaking Additions | Deployment Model Change |
|----------|-----------------|----------------------|------------------------|
| **Registry** | 7 functions removed, 1 event removed, error format changed | 2 new functions, 1 new event, UUPS functions | Constructor → UUPS Proxy + `initialize()` |
| **SuperPaymaster** | Constructor parameter split | 3 new functions, 2 new events, 1 new mapping | Constructor → UUPS Proxy + `initialize()` |
| **GTokenStaking** | 1 function removed, REGISTRY → immutable | None | Constructor gains `_registry` param |
| **MySBT** | 1 function removed, 1 event removed, REGISTRY → immutable | None | Constructor adds `_r` zero-check |
| **PaymasterBase** | None | None (defensive checks added) | Unchanged |

---

## 1. Registry (v3.0.2 → v4.1.0)

### 1.1 Deployment Change [BREAKING]

```
// OLD: Direct deployment
Registry registry = new Registry(gtoken, staking, mysbt);

// NEW: UUPS Proxy deployment
Registry impl = new Registry();
bytes memory init = abi.encodeCall(Registry.initialize, (owner, staking, mysbt));
ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
Registry registry = Registry(address(proxy));
```

Note: `_gtoken` parameter removed (was unused in v3).

### 1.2 Removed Functions [BREAKING]

| Function | Old Signature | Replacement |
|----------|--------------|-------------|
| `registerRoleSelf` | `registerRoleSelf(bytes32 roleId, bytes calldata roleData) → uint256` | Use `registerRole(roleId, msg.sender, roleData)` |
| `createNewRole` | `createNewRole(bytes32 roleId, RoleConfig calldata config, address roleOwner)` | Use `configureRole(roleId, config)` with `config.owner` set |
| `setRoleOwner` | `setRoleOwner(bytes32 roleId, address newOwner)` | Use `configureRole(roleId, config)` with `config.owner` |
| `setRoleLockDuration` | `setRoleLockDuration(bytes32 roleId, uint256 duration)` | Use `configureRole(roleId, config)` with `config.roleLockDuration` |
| `adminConfigureRole` | `adminConfigureRole(bytes32 roleId, uint256, uint256, uint256, uint256)` | Use `configureRole(roleId, config)` |
| `setLevelThreshold` | `setLevelThreshold(uint256 index, uint256 threshold)` | Use `setLevelThresholds(uint256[])` |
| `addLevelThreshold` | `addLevelThreshold(uint256 threshold)` | Use `setLevelThresholds(uint256[])` |
| `calculateExitFee` | `calculateExitFee(bytes32 roleId, uint256 amount) → uint256` | Use `GTokenStaking.previewExitFee()` directly |

### 1.3 New Functions [NON-BREAKING]

| Function | Signature | Description |
|----------|-----------|-------------|
| `initialize` | `initialize(address _owner, address _staking, address _mysbt)` | UUPS proxy init (one-time) |
| `setLevelThresholds` | `setLevelThresholds(uint256[] calldata thresholds)` | Batch-replace all level thresholds |
| `proxiableUUID` | `proxiableUUID() → bytes32` | Inherited from UUPSUpgradeable |
| `upgradeToAndCall` | `upgradeToAndCall(address newImpl, bytes data)` | UUPS upgrade entry (onlyOwner) |

### 1.4 Error Format Change [BREAKING]

All `require(... , "string")` and `revert("string")` converted to custom errors:

| Old (string revert) | New (custom error) |
|---------------------|-------------------|
| `"Lock duration not met"` | `LockNotMet()` |
| `"Caller must be Community"` | `CallerNotCommunity()` |
| `"Unauthorized"` | `Unauthorized()` |
| `"Fee too high"` | `FeeTooHigh()` |
| `"Invalid owner"` / `"Invalid parameter"` | `InvalidAddr()` / `InvalidParam()` |
| `"Length mismatch"` | `LenMismatch()` |
| `"BLS Proof required"` | `BLSProofRequired()` |
| `"BLS Verification Failed"` | `BLSFailed()` |
| `"BLS Validator not configured"` | `BLSNotConfigured()` |
| `"SuperPaymaster not set"` | `SPNotSet()` |
| `"Thresholds must be ascending"` | `ThreshNotAscending()` |
| `"Proposal already executed"` | `ProposalExecuted()` |
| `"Insufficient consensus threshold"` | `InsufficientConsensus()` |
| `"Unauthorized Reputation Source"` | `UnauthorizedSource()` |

**SDK Impact**: Error parsing must switch from string matching to ABI-decoded custom error selectors.

### 1.5 Event Changes

| Type | Event | Notes |
|------|-------|-------|
| NEW | `ExitFeeSyncFailed(bytes32 indexed roleId)` | Emitted when `setStaking()` fails to sync exit fees |
| REMOVED | `RoleLockDurationUpdated(bytes32 indexed roleId, uint256 duration)` | Now tracked via `RoleConfigured` event |

### 1.6 Interface (IRegistry) Removals

Removed from `contracts/src/interfaces/v3/IRegistry.sol`:
- `registerRoleSelf`, `adminConfigureRole`, `createNewRole`, `setRoleOwner`, `setRoleLockDuration`
- `calculateExitFee` (duplicate declaration)
- `roleOwners(bytes32) → address` (mapping still public in contract, just removed from interface)

---

## 2. SuperPaymaster (v3.2.2 → v4.1.0)

### 2.1 Deployment Change [BREAKING]

```
// OLD
SuperPaymaster sp = new SuperPaymaster(entryPoint, owner, registry, apnts, priceFeed, treasury, staleness);

// NEW: Immutables in constructor, mutables in initialize()
SuperPaymaster impl = new SuperPaymaster(entryPoint, registry, priceFeed);  // immutables
bytes memory init = abi.encodeCall(SuperPaymaster.initialize, (owner, apnts, treasury, staleness));
ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
```

### 2.2 New Functions [NON-BREAKING]

| Function | Signature | Description |
|----------|-----------|-------------|
| `initialize` | `initialize(address _owner, address _apntsToken, address _treasury, uint256 _staleness)` | UUPS proxy init |
| `retryPendingDebt` | `retryPendingDebt(address token, address user)` | Retry failed debt recording (anyone can call) |
| `clearPendingDebt` | `clearPendingDebt(address token, address user)` | Admin escape hatch for stuck debts (onlyOwner) |
| `pendingDebts` | `pendingDebts(address, address) → uint256` | Auto-generated getter for pending debts mapping |
| `proxiableUUID` | `proxiableUUID() → bytes32` | Inherited from UUPSUpgradeable |
| `upgradeToAndCall` | `upgradeToAndCall(address, bytes)` | UUPS upgrade entry (onlyOwner) |

### 2.3 New Events [NON-BREAKING]

| Event | Signature | Description |
|-------|-----------|-------------|
| `DebtRecordFailed` | `DebtRecordFailed(address indexed token, address indexed user, uint256 amount)` | postOp recordDebt failed, debt stored in pendingDebts |
| `PendingDebtRetried` | `PendingDebtRetried(address indexed token, address indexed user, uint256 amount)` | Pending debt retried or cleared |

### 2.4 Behavior Change (ABI unchanged)

`postOp` now wraps `recordDebt` in `try/catch`. Failed debt recording no longer reverts the entire postOp; instead, debt is accumulated in `pendingDebts` mapping. This is a resilience improvement.

### 2.5 Base Class Change

`BasePaymaster` → `BasePaymasterUpgradeable`. All inherited functions (`deposit()`, `withdrawTo()`, `addStake()`, `getDeposit()`, etc.) maintain identical ABI signatures.

---

## 3. GTokenStaking (v3.1.2 → v3.2.0)

### 3.1 Constructor Change [BREAKING]

```
// OLD
GTokenStaking staking = new GTokenStaking(gtoken, treasury);
staking.setRegistry(registryAddr);  // separate call

// NEW
GTokenStaking staking = new GTokenStaking(gtoken, treasury, registryAddr);
// No setRegistry() available
```

### 3.2 Removed Functions [BREAKING]

| Function | Old Signature |
|----------|--------------|
| `setRegistry` | `setRegistry(address _registry) external` (onlyOwner) |

Also removed from `IGTokenStaking` interface.

### 3.3 Storage Change

`REGISTRY`: `address public` (mutable) → `address public immutable`

Getter ABI is unchanged, but value can no longer be modified after deployment.

---

## 4. MySBT (v3.1.2 → v3.1.3)

### 4.1 Removed Functions [BREAKING]

| Function | Old Signature |
|----------|--------------|
| `setRegistry` | `setRegistry(address r) external` (onlyDAO) |

### 4.2 Removed Events [BREAKING]

| Event | Signature |
|-------|-----------|
| `RegistryUpdated` | `RegistryUpdated(address indexed old, address indexed new, uint256 timestamp)` |

### 4.3 Internal Change

Removed `IRegistryLegacy.isRegisteredCommunity()` fallback in `_isValid()`. Now only uses V3 `IRegistry.hasRole()`. **Not backward-compatible with V2 Registry**.

---

## 5. PaymasterBase (unchanged ABI)

No ABI changes. Added defensive checks in:
- `updatePrice()`: oracle staleness and price bounds validation
- `setTokenPrice()`: `require(decimals <= 24)`
- `setMaxGasCostCap()`: `require(_maxGasCostCap > 0)`

---

## SDK Migration Checklist

### P0 — Must Fix (will break)
- [ ] Update Registry/SuperPaymaster deployment to UUPS proxy pattern
- [ ] Remove calls to: `registerRoleSelf`, `createNewRole`, `setRoleOwner`, `setRoleLockDuration`, `adminConfigureRole`
- [ ] Remove calls to: `GTokenStaking.setRegistry()`, `MySBT.setRegistry()`
- [ ] Update error parsing: all string reverts → custom error selectors
- [ ] Update ABI JSON files for all changed contracts

### P1 — Should Fix
- [ ] Migrate role management to unified `configureRole(roleId, config)`
- [ ] Replace `setLevelThreshold`/`addLevelThreshold` → `setLevelThresholds(uint256[])`
- [ ] Replace `Registry.calculateExitFee` → `GTokenStaking.previewExitFee`

### P2 — Optional
- [ ] Listen for new events: `DebtRecordFailed`, `PendingDebtRetried`, `ExitFeeSyncFailed`
- [ ] Integrate `retryPendingDebt` / `clearPendingDebt` in admin UI
- [ ] Query `pendingDebts` mapping for monitoring
- [ ] Add `upgradeToAndCall` to admin dashboard
