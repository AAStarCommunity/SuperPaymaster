# Changes

## 2026-03-21 (v4.1.1 Comprehensive E2E Test Suite)
- **Comprehensive E2E Test Suite**: 14 new files, ~68 test points covering all major contract flows on Sepolia
  - `test-helpers.js`: Shared utility module (ABI definitions, role constants, display/assertion helpers, nonce-managed TX wrapper)
  - A1: Registry role lifecycle (register community, enduser, SBT verification)
  - A2: Registry view queries (role constants, configs, member counts, credit tiers, wiring)
  - B1: Operator configuration (configureOperator, limits, pause/unpause cycle)
  - B2: Operator deposit/withdraw (deposit, depositFor, withdraw, excess revert)
  - C1: SuperPaymaster negative cases (no SBT, paused operator, unconfigured operator)
  - C2: PaymasterV4 negative cases (zero-balance user, supported tokens query)
  - D1: Reputation rules & scoring (setRule, computeScore, entropyFactor, communityReputation)
  - D2: Credit tier configuration (setCreditTier, levelThresholds, getCreditLimit)
  - E1: Pricing & oracle (cachedPrice, updatePrice, setAPNTSPrice, Chainlink direct, V4 updatePrice)
  - E2: Protocol fee configuration (setProtocolFee, MAX_PROTOCOL_FEE revert, revenue queries)
  - F1: Staking queries (totalStaked, stakes, lockedStake, previewExitFee, wiring verification)
  - F2: Slash history & WARNING test (getSlashCount, slashOperator WARNING/0, updateReputation restore)
  - `run-all-e2e-tests.sh`: Full test runner with dependency-ordered phases and summary table
- **Idempotent & Safe**: All write tests check state before acting, restore modified configs, use WARNING-level slash (0 penalty)
- **Nonce Management**: Explicit nonce tracking in `sendTxSafe` to prevent TX conflicts on Sepolia rapid sends
- **prepare-test**: Added deployer account/key detection logic (DEPLOYER_ACCOUNT > PRIVATE_KEY > anvil default)
- **docs**: Kimi final audit report, AGENTS.md
- **Sepolia verified**: 17/17 test groups passing (12 new + 2 preflight + 3 legacy gasless)

## 2026-03-21 (v4.1.0 UUPS Migration)
- **UUPS Proxy Migration**: Registry and SuperPaymaster converted to UUPS upgradeable proxies (ERC-1967/ERC-1822)
- **Registry API Consolidation**: 5 admin functions merged into 2 (`configureRole`, `setLevelThresholds`) for EIP-170 compliance (24,383B)
- **Custom Errors**: ~40 string reverts converted to custom errors across 8 contracts
- **Immutable REGISTRY**: GTokenStaking and MySBT REGISTRY references made immutable (removed `setRegistry()`)
- **SuperPaymaster v4.1.0**: postOp `recordDebt` try/catch with `pendingDebts` escape hatch, `clearPendingDebt()` admin function
- **PaymasterBase**: Oracle bounds validation, decimals check, gas cap enforcement
- **GTokenStaking v3.2.0**: Post-slash zero-lock cleanup (`_cleanupZeroLocks`), two-tier slash (DVT + operational)
- **MySBT v3.1.3**: Removed IRegistryLegacy fallback
- **CI Pipeline**: Added `.github/workflows/test.yml` (forge test + EIP-170 size check)
- **Boundary Tests**: Batch limit (200/201), level threshold limit (20/21)
- **Security Reviews**: 3 independent audits (Kimi, Codeex, mainnet-readiness), all P0/P1 items resolved
- **Deployment**: `deploy-sepolia.sh` non-interactive script, `MigrateToUUPS.s.sol` migration script
- **Documentation**: 10 new docs (UUPS architecture, SDK migration guide, VERSION_MAP, governance roadmap)
- 336 tests passing, 0 failures

## 2026-03-04
- PaymasterV4.3: Token管理系统（`removeToken`, `getSupportedTokens`, `isTokenSupported`, `getSupportedTokensInfo`）
- PaymasterV4.3: `setTokenPrice` 增强零值校验，自动跟踪 supported tokens 列表
- 多链稳定币配置 (`deployments/stablecoins.json`): Ethereum/Optimism/Arbitrum/Base/Polygon/Sepolia
- 新增 ConfigureStablecoins / TestStablecoinSepolia / DeployAndTestV4 部署脚本
- 新增10个单元测试 + 13项Sepolia链上测试 (12 pass, 1 skip)
- 安全审查: 0 Critical / 0 High / 0 Medium（详见 `docs/Security-Review-V4.3-TokenManagement.md`）

## 2025-10-31
- 统一OpenZeppelin v5.0.2
- 删除废弃GasTokenV2
- 添加aPNTs部署脚本
- 添加社区注册页面
- GTokenStaking细粒度测试
- 安全审计工具评估文档
- 修复Slither重入漏洞
- SuperPaymasterV2添加SafeERC20

## 2025-10-30
- 完成统一xPNTs架构实现
- 添加部署指南和测试脚本
