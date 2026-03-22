# Contract Version Map

**Updated**: 2026-03-22

## On-Chain Version Strings

| Contract | `version()` Return | Role |
|----------|-------------------|------|
| Registry | `Registry-4.1.0` | UUPS Proxy — Community/Role management |
| SuperPaymaster | `SuperPaymaster-5.2.0` | UUPS Proxy — AOA+ shared paymaster |
| GTokenStaking | `Staking-3.2.0` | Pointer-replacement — Role-based staking |
| MySBT | `MySBT-3.1.3` | Pointer-replacement — Soulbound identity |
| PaymasterBase | `PaymasterV4-4.3.1` | Base class for AOA paymaster |
| Paymaster (V4) | `PMV4-Deposit-4.3.0` | EIP-1167 proxy — Independent per-community paymaster |
| xPNTsToken | `XPNTs-3.0.0-unlimited` | EIP-1167 proxy — Community gas token |
| xPNTsFactory | `xPNTsFactory-2.1.0-clone-optimized` | Standalone — Token factory |
| GToken | `GToken-2.1.2` | Standalone — Governance token (21M cap) |
| BLSValidator | `BLSValidator-0.3.2` | Standalone — BLS signature validation |
| BLSAggregator | `BLSAggregator-3.2.1` | Standalone — BLS proof aggregation |
| DVTValidator | `DVTValidator-0.3.2` | Standalone — Distributed validator tech |
| ReputationSystem | `Reputation-0.3.2` | Standalone — Operator reputation scoring |
| PaymasterFactory | `PaymasterFactory-1.0.2` | Standalone — V4 deployment factory |

## Naming Convention

```
<ContractName>-<Major>.<Minor>.<Patch>
```

- **Major**: Breaking changes (storage layout, interface changes)
- **Minor**: New features (backward compatible)
- **Patch**: Bug fixes, security hardening

## Version History

| Version | Date | Changes |
|---------|------|---------|
| Registry-4.1.0 | 2026-03-20 | Added `_syncExitFees()`, immutable REGISTRY support |
| Registry-4.0.0 | 2026-03-07 | UUPS proxy migration |
| SuperPaymaster-5.2.0 | 2026-03-22 | Agent sponsorship policies, x402 Permit2 settlement, EIP-1153 cache, feedback |
| SuperPaymaster-5.0.0 | 2026-03-21 | `_consumeCredit` kernel, `chargeMicroPayment` EIP-712, solady EIP712 |
| SuperPaymaster-4.1.0 | 2026-03-20 | postOp try/catch + pendingDebts resilience |
| SuperPaymaster-4.0.0 | 2026-03-07 | UUPS proxy migration |
| PaymasterV4-4.3.1 | 2026-03-22 | mulDiv 512-bit fix, oracle updatedAt validation, staleness check |
| Staking-3.2.0 | 2026-03-20 | REGISTRY → immutable, removed `setRegistry()` |
| MySBT-3.1.3 | 2026-03-20 | REGISTRY → immutable, removed `setRegistry()`, cleaned IRegistryLegacy |
| PMV4-Deposit-4.3.0 | 2026-03-20 | Added oracle bounds check, decimals validation, gas cap validation |

## Deployment Config

Runtime version is returned by `version()` on each contract.
Deployment config is stored in `deployments/config.<network>.json`.
The `srcHash` field tracks source code hash for skip-if-unchanged logic.

## Keeper / Oracle Operations

### Price Update Keeper

SuperPaymaster and PaymasterV4 rely on cached ETH/USD price from Chainlink.

- **Update frequency**: Must be within `priceStalenessThreshold` (default: 5 minutes for V3, configurable for V4)
- **If Keeper stops**: EntryPoint rejects UserOps with expired `validUntil` timestamp
- **Monitoring**: Alert if `cachedPrice.updatedAt` is older than 2x threshold
- **Fallback**: V3 has DVT dual-source oracle with ±20% deviation check

### Auto-Approved Spenders (xPNTsToken)

- `autoApprovedSpenders` mapping grants unlimited `allowance()` to trusted contracts
- **Only** SuperPaymaster and Factory-deployed contracts should be in this list
- Firewall enforces: auto-approved spenders can only `transferFrom` to themselves or SuperPaymaster
- `burn()` explicitly blocks SuperPaymaster (must use `burnFromWithOpHash()` with replay protection)
- Governance should review the spender list before any changes

## Governance Roadmap

Ownership of all admin-controlled contracts (Registry, SuperPaymaster, GTokenStaking, MySBT, BLSAggregator, PaymasterFactory) follows a phased decentralization roadmap.

### Phase 1: EOA (Current — Testnet & Initial Mainnet)

- Owner = deployer EOA
- Fast iteration, direct admin calls
- Acceptable risk: single key compromise = full control

### Phase 2: Ownable2Step + TimelockController

- Deploy OpenZeppelin `TimelockController` with 48h minimum delay
- Transfer ownership of all contracts to `TimelockController` via `Ownable2Step.transferOwnership()` + `acceptOwnership()`
- `Ownable2Step` prevents accidental transfer to wrong address (two-step: propose → accept)
- All sensitive operations (upgradeTo, setAPNTsPrice, setProtocolFeeBPS, setSuperPaymaster, etc.) go through Timelock queue
- Deployer EOA retains `PROPOSER_ROLE` on Timelock (can propose, but execution is delayed)
- **Trigger**: Before mainnet goes live with real user funds

### Phase 3: Gnosis Safe Multisig + TimelockController

- Deploy Gnosis Safe (3-of-5 or higher) with core team signers
- Transfer `PROPOSER_ROLE` on TimelockController from EOA to Gnosis Safe
- Optionally grant `EXECUTOR_ROLE` to a separate operational Safe or keeper
- All admin actions now require: multisig approval → Timelock delay → execution
- **Trigger**: After initial mainnet stabilization (1-3 months)

### Phase 4: DAO Governance + Multisig + TimelockController

- Deploy governance token voting (Governor contract or Snapshot + executor)
- DAO proposals replace multisig as `PROPOSER_ROLE` on Timelock
- Gnosis Safe retained as `GUARDIAN_ROLE` (emergency cancel during delay window)
- Full on-chain governance for upgrades, fee changes, and parameter updates
- **Trigger**: After community reaches sufficient decentralization

### Contracts Affected

| Contract | `onlyOwner` Functions | Notes |
|----------|----------------------|-------|
| Registry | `setStaking`, `setMySBT`, `setSuperPaymaster`, `configureRole`, `upgradeToAndCall` | UUPS — upgrade is most critical |
| SuperPaymaster | `setAPNTsToken`, `setAPNTsPrice`, `setProtocolFee`, `setBLSAggregator`, `upgradeToAndCall` | UUPS |
| GTokenStaking | `setRoleExitFee`, `setAuthorizedSlasher` | Pointer-replacement (redeploy to upgrade) |
| MySBT | `setGTokenStaking`, `setDAO` | Pointer-replacement |
| BLSAggregator | `setSuperPaymaster`, `setDVTValidator`, `registerBLSPublicKey`, `setMinThreshold` | Standalone |
| PaymasterFactory | `deployPaymaster` | Factory |
