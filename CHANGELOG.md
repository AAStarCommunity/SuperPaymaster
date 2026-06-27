# Changelog

All notable changes to SuperPaymaster are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [v5.4.1-rc.1] — 2026-06-27 (Sepolia Release Candidate)

### Security Fixes

- **S1 — Two-step slash guard** (HIGH, fixes #249): Operators could call `withdraw()` immediately
  after slash initiation to escape penalties. Added mandatory two-step flow:
  - `queueSlash(operator)` — governance sets `_pendingSlash[operator]`; emits `SlashQueued`
  - `withdraw()` reverts with `SlashPending()` if flag is set
  - Both `slashOperator()` and `executeSlashWithBLS()` now require `_pendingSlash` to be set first
  - `cancelSlash(operator)` — governance escape hatch; emits `SlashCancelled`

- **S2 — srcHash authority** (HIGH, Codex H-3): Deploy scripts previously wrote `srcHash` to config
  before audit ran, creating a window where unverified code could appear audited.
  - All forge scripts now write `srcHash=""` unconditionally
  - `deploy-core` is the sole authority: writes real hash atomically only after `audit-core` exits 0
  - `foundry.toml`, `remappings.txt`, `deploy-core` itself added to hash inputs

- **S3 — BLS_AGGREGATOR wiring** (HIGH, Codex H-2): Fresh deployments left `BLS_AGGREGATOR`
  as `address(0)`, silently disabling BLS-based slash execution.
  - `initBLSAggregator(address)` — one-time setter callable only when `BLS_AGGREGATOR == address(0)`;
    no timelock (fresh deploy path); `onlyOwner`
  - Called automatically in `DeployLive._executeWiring()` and asserted in `_assertWiring()`
  - Anvil deploy uses `queue + warp + applyBLSAggregator()` sequence

- **MEDIUM — `_assertWiring()` completeness**: Added assertions for `SP.BLS_AGGREGATOR` and
  price-feed address so wiring failures surface immediately at deploy time.

### Changed

- `SuperPaymaster.version()`: `"SuperPaymaster-5.4.0"` → `"SuperPaymaster-5.4.1"`
- `__gap`: `uint256[31]` → `uint256[30]` (`_pendingSlash` consumes one slot; no collision)
- `DeployLive.s.sol`: ASCII `-` replaces Unicode em-dash `—` in string literals (compiler rejects non-ASCII)

### Added (ABI)

| Function | Selector | Description |
|---|---|---|
| `queueSlash(address)` | `0x...` | Start two-step slash; sets `_pendingSlash` |
| `cancelSlash(address)` | `0x...` | Cancel queued slash; clears `_pendingSlash` |
| `initBLSAggregator(address)` | `0x...` | One-time BLS_AGGREGATOR wiring for fresh deploy |

Events: `SlashQueued(address indexed operator)`, `SlashCancelled(address indexed operator)`
Error: `SlashPending()`

### Verified (Sepolia, chainId 11155111)

| Contract | Address |
|---|---|
| SuperPaymaster proxy | `0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9` |
| SuperPaymaster impl v5.4.1 | `0x0274811E93B4AaE027c1A7dbF592e2B2D37E0250` |
| Registry proxy | `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71` |
| BLSAggregator | `0x893b8fb7B3d203C288b481400fE05Ade5edD6d11` |

Upgrade TX: `0xa57d6007cd98522b641286815a9501f193eb2fedddc773b38e502b78ab446771`

---

## [v5.4.0-beta.1] — 2026-06-11 (Sepolia)

### Added

- **x402 god-split**: `X402Facilitator` extracted from `SuperPaymaster` (~2,875 bytes recovered;
  EIP-170 compliance restored). Standalone facilitator handles x402 settlement + policy enforcement.
- **DVT hardening**: `PolicyRegistry` contract, golden test vectors, domain-separation tag `_POP_`
  for BLS proof-of-possession.
- **V54Bootstrap**: shared library wiring `DeployLive` / `UpgradeLive` / `DeployAnvil` for v5.4
  complete deployments via `./deploy-core`.
- **H-1 credit ceiling**, **M-1**, **#211 L-C**, sentinel-ordering fix, per-spender cap — security
  audit findings addressed.

---

## [v5.3.0] — 2026-03-23

### Added

- ERC-8004 Agent Identity + dual-channel sponsorship (`SBT OR Agent NFT`)
- `settleX402Payment()` / `settleX402PaymentDirect()` replacing Permit2
- Agent sponsorship policies: `setAgentPolicies()`, tiered BPS rates + daily USD cap
- EIP-1153 transient cache (`_getCachedBalance` / `_setCachedBalance`) for same-operator batch
- `IAgentIdentityRegistry`, `IAgentReputationRegistry`, `IERC3009` interfaces

---

## [v5.0.0] — 2026-03-22

### Added

- UUPS upgradeable proxies for Registry and SuperPaymaster (ERC1967Proxy)
- `BasePaymasterUpgradeable` base class
- `GTokenStaking.REGISTRY` and `MySBT.REGISTRY` made `immutable`
- `__gap[50]` storage gaps; `_authorizeUpgrade` restricted to `onlyOwner`
- Deployment order Scheme B (Registry proxy first, then Staking/MySBT with immutable REGISTRY)
