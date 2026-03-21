# Contract Upgrade Guide

> Version: 1.0 | Date: 2026-03-21 | Applies to: v4.x (UUPS Migration)

This guide covers how to upgrade all contracts in the SuperPaymaster ecosystem without changing deployed addresses.

---

## 1. UUPS Proxy Contracts (Address-Preserving Upgrades)

**Applicable to**: Registry, SuperPaymaster

These contracts use the UUPS (ERC-1822) proxy pattern. The proxy address is **permanent** — only the underlying implementation logic changes.

### 1.1 Upgrade Procedure

```bash
# Step 1: Write new implementation contract
# - Must inherit from the same base (UUPSUpgradeable, Ownable, etc.)
# - Must keep identical storage layout (append new vars before __gap, reduce __gap size)
# - Constructor must call _disableInitializers()
# - Must pass same immutable values to constructor

# Step 2: Deploy new implementation
forge create src/core/RegistryV2.sol:RegistryV2 \
  --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT

# Step 3: Upgrade proxy to point to new implementation
# (Must be called by proxy owner)
cast send $REGISTRY_PROXY_ADDRESS \
  "upgradeToAndCall(address,bytes)" \
  $NEW_IMPL_ADDRESS "0x" \
  --rpc-url $RPC_URL --account $OWNER_ACCOUNT
```

### 1.2 Registry Upgrade Example

```solidity
// RegistryV2.sol
contract RegistryV2 is Ownable, ReentrancyGuard, Initializable, UUPSUpgradeable, IRegistry {
    // ... all existing storage variables in exact same order ...

    // NEW variable: append before __gap
    uint256 public newFeature;    // occupies slot 28 (was __gap[0])
    uint256[49] private __gap;   // reduced from [50] to [49]

    // Constructor: same pattern, same _disableInitializers()
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    // No need for initialize() — proxy is already initialized
    // State from V1 is automatically preserved

    // Optional: reinitializer for new storage
    function initializeV2(uint256 _newFeature) external reinitializer(2) {
        newFeature = _newFeature;
    }

    function version() public pure virtual override returns (string memory) {
        return "Registry-4.2.0";
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
```

### 1.3 SuperPaymaster Upgrade Example

```solidity
// SuperPaymasterV2.sol
contract SuperPaymasterV2 is BasePaymasterUpgradeable, ISuperPaymaster {
    // Constructor immutables MUST match the original values
    // because immutables live in implementation bytecode, not proxy storage
    constructor(
        IEntryPoint _entryPoint,      // MUST be same EntryPoint
        address _registry,            // MUST be same Registry proxy address
        address _ethUsdPriceFeed      // MUST be same Chainlink feed
    ) BasePaymasterUpgradeable(_entryPoint, _registry, _ethUsdPriceFeed) {}

    // ... all existing storage in same order ...
    // Append new vars before __gap, reduce __gap size
}
```

### 1.4 Critical Rules

| Rule | Description |
|------|-------------|
| **Storage order** | NEVER reorder, remove, or change types of existing storage variables |
| **__gap management** | New variables go BEFORE __gap; reduce __gap size by the same number of slots |
| **Immutables** | Must pass identical immutable values in new constructor (entryPoint, REGISTRY, ETH_USD_PRICE_FEED) |
| **Constructor** | Must call `_disableInitializers()` |
| **reinitializer(N)** | Use `reinitializer(2)` for V2, `reinitializer(3)` for V3, etc. to initialize new state |
| **Ownership** | `upgradeToAndCall` can only be called by proxy owner |
| **Verify first** | Deploy new impl to testnet, run full test suite, verify storage layout compatibility |

### 1.5 Storage Layout Verification

```bash
# Compare old and new storage layouts
forge inspect Registry storage-layout --json > registry_v1_layout.json
forge inspect RegistryV2 storage-layout --json > registry_v2_layout.json
diff registry_v1_layout.json registry_v2_layout.json

# Slot numbers for existing vars must be identical
```

### 1.6 Deployed Proxy Addresses (Sepolia)

| Contract | Proxy Address | Implementation |
|----------|---------------|----------------|
| Registry | `0x9E3677d817E79E62b9a766F985F7A5e3999ABe28` | Upgradeable |
| SuperPaymaster | `0x3befB8A0007f3d2261DD59A5693278101fB38560` | Upgradeable |

---

## 2. Non-UUPS Contracts (Pointer-Replacement Upgrade)

**Applicable to**: GTokenStaking, MySBT, xPNTsFactory, ReputationSystem, BLSAggregator, DVTValidator, PaymasterFactory, PaymasterV4 (impl)

These contracts are NOT proxied. They use **immutable REGISTRY** that points to the Registry **proxy** address.

### 2.1 Why Most Upgrades Don't Require Redeployment

Since GTokenStaking and MySBT reference `REGISTRY` as an immutable pointing to the Registry **proxy** address, upgrading the Registry implementation (via UUPS) **does not affect these contracts**. The proxy address remains the same.

```
GTokenStaking.REGISTRY (immutable) → Registry Proxy (0x9E36...)
                                          ↓ delegatecall
                                     Registry Impl V1 → Registry Impl V2
                                     (address changes)  (proxy stays same)
```

### 2.2 When Redeployment IS Required

Redeployment is only needed when:
1. **The contract's own logic needs to change** (bug fix, new feature)
2. **A referenced immutable address changes** (extremely unlikely for proxy addresses)

### 2.3 Redeployment Procedure

```bash
# Step 1: Deploy new contract with same immutable references
# GTokenStaking example:
forge create src/core/GTokenStaking.sol:GTokenStaking \
  --constructor-args $GTOKEN_ADDRESS $TREASURY_ADDRESS $REGISTRY_PROXY_ADDRESS \
  --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT

# Step 2: Update references in Registry
cast send $REGISTRY_PROXY "setStaking(address)" $NEW_STAKING_ADDRESS \
  --rpc-url $RPC_URL --account $OWNER_ACCOUNT

# Step 3: Update config.json with new address
# Step 4: Re-run verification checks
```

### 2.4 Dependency Matrix

This table shows what needs to be updated when each contract is redeployed:

| Contract Redeployed | Update In Registry | Update In SuperPaymaster | Update Elsewhere |
|---------------------|-------------------|--------------------------|-----------------|
| **GTokenStaking** | `setStaking(newAddr)` | — | MySBT constructor (if also redeploying) |
| **MySBT** | `setMySBT(newAddr)` | — | — |
| **xPNTsFactory** | — | `setXPNTsFactory(newAddr)` | — |
| **BLSAggregator** | `setBLSAggregator(newAddr)` | `setBLSAggregator(newAddr)` | — |
| **DVTValidator** | — | — | BLSAggregator.setDVTValidator(newAddr) |
| **ReputationSystem** | `setReputationSource(newAddr, true)` | — | — |
| **PaymasterFactory** | — | — | Update config.json |
| **PaymasterV4 (impl)** | — | — | PaymasterFactory.setImplementation(newAddr) |

### 2.5 Safe Redeployment Checklist

- [ ] Deploy new contract to testnet first
- [ ] Verify constructor immutables match (especially `REGISTRY` proxy address)
- [ ] Run all tests against new contract
- [ ] Deploy to mainnet
- [ ] Update all references (see dependency matrix above)
- [ ] Run verification checks (`Check01-Check08`)
- [ ] Update `config.<network>.json` with new address
- [ ] Notify SDK team of address change (if applicable)

---

## 3. Emergency Procedures

### 3.1 Ownership Transfer (Pre-Upgrade Safety)

Before any upgrade, ensure the owner is correct:

```bash
# Check current owner
cast call $PROXY_ADDRESS "owner()" --rpc-url $RPC_URL

# Transfer to multisig (RECOMMENDED before mainnet)
cast send $PROXY_ADDRESS "transferOwnership(address)" $MULTISIG_ADDRESS \
  --rpc-url $RPC_URL --account $CURRENT_OWNER
```

**Warning**: With current `Ownable` (not `Ownable2Step`), transferring to a wrong address is irreversible. Verify the target address thoroughly.

### 3.2 Rollback an Upgrade

UUPS upgrades are reversible — deploy the old implementation and upgrade back:

```bash
# Re-deploy old implementation (exact same code)
forge create src/core/Registry.sol:Registry \
  --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT

# Upgrade back to old implementation
cast send $REGISTRY_PROXY "upgradeToAndCall(address,bytes)" \
  $OLD_IMPL_ADDRESS "0x" \
  --rpc-url $RPC_URL --account $OWNER_ACCOUNT
```

### 3.3 What Cannot Be Rolled Back

- Storage variable values changed by the new implementation
- Events emitted during the upgrade period
- External state changes (EntryPoint deposits, token transfers)

---

## 4. Version Compatibility Matrix

| Component | Current Version | Upgrade Method | Address Changes? |
|-----------|----------------|---------------|-----------------|
| Registry | 4.1.0 | UUPS `upgradeToAndCall` | No (proxy permanent) |
| SuperPaymaster | 4.1.0 | UUPS `upgradeToAndCall` | No (proxy permanent) |
| GTokenStaking | 3.2.0 | Redeploy + `setStaking()` | Yes (new address) |
| MySBT | 3.1.3 | Redeploy + `setMySBT()` | Yes (new address) |
| GToken | 3.0.0 | Not upgradeable (ERC20) | — |
| xPNTsFactory | 3.0.0 | Redeploy + `setXPNTsFactory()` | Yes |
| PaymasterV4 | 4.3.0 | New impl + factory update | Per-operator address |
| BLSAggregator | 1.0.0 | Redeploy + re-wire | Yes |
| ReputationSystem | 3.0.0 | Redeploy + re-authorize | Yes |
