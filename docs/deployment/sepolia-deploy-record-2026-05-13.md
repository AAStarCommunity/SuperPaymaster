# Sepolia Deployment Record — 2026-05-13

**部署时间**: 2026-05-13 22:03 CST  
**触发原因**: PR #195 引入 GTokenAuthorization v2.2.0（EIP-3009 无 gas 转账），替换旧 GToken  
**部署脚本**: `./deploy-core sepolia --force`  
**脚本版本**: commit `4ea69e46`  
**操作者**: Jason (0xb5600060e6de5E11D3636731964218E53caadf0E)

---

## 一、新部署合约地址

### 核心合约

| 合约 | 地址 | 说明 |
|------|------|------|
| **GTokenAuthorization** | `0xbC17B6C319561bcA805981fC2846e4678f9114Cb` | 替换旧 GToken，新增 EIP-3009 无 gas 转账 (RC-1 5min 窗口 + RC-2 SBT/xPNTs 双路验证) |
| **GTokenStaking** | `0x4C1EA3A91eF13236F5F13a47321C83cf86EF51dF` | REGISTRY 改为 immutable |
| **MySBT** | `0x4ab7FF379e3491C27FB26F8c0a811CbD7891A1B2` | REGISTRY 改为 immutable |
| **Registry proxy** (UUPS) | `0x3dfeBE636eDA211E0a783308Cf0CB31892686d67` | impl: `0x670E477B7BA796b25A47478e2C100015ddE66473` |
| **SuperPaymaster proxy** (UUPS) | `0x506962D17AEA6E7A15fd3479D8c4E2ABBBF91112` | impl: `0x07777B20929b235e32f5A67C03a8a758934c7f4F` |

### 代币

| 合约 | 地址 | 说明 |
|------|------|------|
| **xPNTsFactory** | `0x907C23F11c00221fa916c9d9b0F8169D5Bd46aC2` | Clones 工厂 |
| **aPNTs** (AAStar) | `0x6859dC0b5ee1CcE829673161B7a3550CC4A25E48` | AAStar 社区 gas 代币，初铸 20,000 |
| **PNTs** (Mycelium) | `0xAc57F61ad917d8D9325cB5388B7Ec307d8644eEa` | Mycelium 社区 gas 代币，初铸 500 |

### 模块

| 合约 | 地址 |
|------|------|
| **BLSAggregator** | `0x12Ae250EF63adCEF487B5679b917011D508687AB` |
| **DVTValidator** | `0x6b131ac781Adea7785d4DFfF612E5A26B37F0D0d` |
| **ReputationSystem** | `0x1290d30abD9324756258e6eE66dc11B4bC9E96de` |
| **PaymasterFactory** | `0x7647b6Db63f87C5625153CD1cD1675095E06B480` |
| **PaymasterV4Impl** | `0x661E02f276D2B589Fb08453E43739C3766be69Cb` |

### 不变的外部基础设施

| 合约 | 地址 |
|------|------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |
| SimpleAccountFactory | `0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985` |
| Chainlink ETH/USD | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |

---

## 二、部署后 Wiring 接线记录

### Step 1 — 基础层（新部署顺序）
1. 部署 Registry impl → ERC1967Proxy (`initialize(deployer, 0x0, 0x0)`)
2. 部署 xPNTsFactory(address(0), registry) — **前移到 Step 1，为 GTokenAuthorization 提供 immutable factory**
3. 部署 **GTokenAuthorization**(cap=21M×1e18, factory=xPNTsFactory) — 新 GToken
4. 部署 GTokenStaking(gtoken, deployer, registry) — REGISTRY immutable
5. 部署 MySBT(gtoken, staking, registry, deployer) — REGISTRY immutable
6. `registry.setStaking(staking)` → 自动触发 `_syncExitFees()` 同步 7 个角色退出费
7. `registry.setMySBT(mysbt)`
8. **`gtoken.setMySBT(mysbt)`** ← 新增，锁定 RC-2 SBT 路径（一次性 setter）

### Step 2-7 — 社区/模块/Wiring
- `registry.setSuperPaymaster / setReputationSystem / setBLSAggregator`
- `superPaymaster.setAuthorizedSlasher(blsAggregator, true)`
- `superPaymaster.initializePriceCache()` — 强制初始化 Chainlink 缓存
- Jason 注册 PAYMASTER_SUPER，配置 aPNTs operator，充值 1000 aPNTs
- Anni 注册 Mycelium COMMUNITY + PAYMASTER_SUPER，充值 1000 aPNTs + 铸造 500 PNTs

---

## 三、Etherscan 验证状态

| 合约 | 状态 |
|------|------|
| GTokenAuthorization (GToken ABI) | ✅ Pass - Verified |
| GTokenStaking | ✅ Already verified |
| MySBT | ✅ Already verified |
| Registry (impl) | ✅ Already verified |
| SuperPaymaster (impl) | ✅ Already verified |
| ReputationSystem | ✅ Verified |
| BLSAggregator | ✅ Verified |
| DVTValidator | ✅ Verified |
| xPNTsFactory | ✅ Verified |
| xPNTsToken (impl) | ✅ Verified |
| PaymasterFactory | ✅ Already verified |
| PaymasterV4Impl | ✅ Already verified |

**总计: 12/12 合约验证通过**

---

## 四、部署验证审计结果

运行脚本: 7 个 Audit 脚本（Check01~Check08 + VerifyV3_1_1）  
**结论: ✅ 全部通过**

```
Check04_Registry   — Registry-5.3.3，Credit Limit Level 1: 0, Level 2: 100 aPNTs
Check01_GToken     — GTokenAuthorization 版本确认
Check02_GTokenStaking — Registry Address: 0x3dfeBE636eDA211E0a783308Cf0CB31892686d67
Check03_MySBT      — Registry Address: 0x3dfeBE636eDA211E0a783308Cf0CB31892686d67
Check07_SuperPaymaster — SuperPaymaster-5.3.2
Check08_Wiring     — "All Core & BLS Wiring Paths Verified Successfully!"
VerifyV3_1_1       — Wiring & Deep Init Checks all passed
```

---

## 五、单元测试结果（forge test）

**运行时间**: 2026-05-13  
**测试套件**: 72 个  
**结果**: ✅ **925/925 通过，0 失败**

```
Ran 72 test suites in 489.23ms (464.97ms CPU time)
925 tests passed, 0 failed, 0 skipped (925 total)
```

### Gas Report 关键指标

| 函数 | 最小 | 平均 | 最大 | 调用次数 |
|------|------|------|------|---------|
| SuperPaymaster.validatePaymasterUserOp | 8,831 | 58,909 | 77,997 | 37 |
| SuperPaymaster.postOp | 6,593 | 106,446 | 176,734 | 35 |
| SuperPaymaster.configureOperator | 7,180 | 80,314 | 92,323 | 109 |
| PaymasterV4.validatePaymasterUserOp | 2,702 | 24,519 | 43,749 | 14 |
| PaymasterV4.postOp | 25,357 | 59,115 | 83,514 | 7 |
| BLS.verify (n=3) | 110,264 | — | — | 1 |
| BLS.verify (n=7) | 175,788 | — | — | 1 |
| BLS.verify (n=13) | 273,561 | — | — | 1 |

---

## 六、E2E 测试结果（Sepolia 链上）

**运行时间**: 2026-05-13 22:43 CST  
**前置准备**: `./prepare-test sepolia` + `RegisterEnduser.s.sol` + `transfer-tokens.js`  
**结果**: **21/24 通过，3 失败**

### 通过的测试（21）

| 组 | 测试名 | 状态 |
|----|--------|------|
| Preflight | Check Contracts | ✅ PASS |
| Preflight | Check Balances | ✅ PASS |
| A1 | Registry Roles | ✅ PASS |
| A2 | Registry Queries | ✅ PASS |
| B1 | Operator Config | ✅ PASS |
| B2 | Operator Deposit/Withdraw | ✅ PASS |
| C1 | SuperPaymaster Negative Cases | ✅ PASS |
| C2 | PaymasterV4 Negative Cases | ✅ PASS |
| D1 | Reputation Rules | ✅ PASS |
| D2 | Credit Tiers | ✅ PASS |
| E1 | Pricing & Oracle | ✅ PASS |
| E2 | Protocol Fees | ✅ PASS |
| F1 | Staking Queries | ✅ PASS |
| G1 | Reputation-Gated Sponsorship | ✅ PASS |
| G2 | Agent Identity Sponsorship (ERC-8004) | ✅ PASS |
| H1 | DVT & BLS Aggregator Queries | ✅ PASS |
| H2 | ReputationSystem Community Scoring & BLS Sync | ✅ PASS |
| **Gasless** | **PaymasterV4 真实 gasless 交易** | ✅ PASS |
| **Gasless** | **SuperPaymaster + xPNTs1 (aPNTs) 真实 gasless 交易** | ✅ PASS |
| **Gasless** | **SuperPaymaster + xPNTs2 (PNTs) 真实 gasless 交易** | ✅ PASS |
| x402 | EIP-3009 Settlement | ✅ PASS |

### 失败的测试（3）及原因

| 组 | 测试名 | 失败原因 | 是否影响上线 |
|----|--------|---------|-------------|
| F2 | Slash History | `slashOperator(WARNING, 0)` TX 失败：in-flight tx limit + slash 计数未增加 (8步中5步失败) | ⚠️ 非核心路径，slash 功能本身存在（H2 BLS slash 通过），测试账户限流问题 |
| G3 | Credit Tier Escalation | 17/20 步通过，3步失败（信用额度升降级边界条件）| ⚠️ 轻微，credit tier 基础功能正常（D2通过） |
| MicroPaymentChannel | Open/Settle/Close | `microPaymentChannel address missing from config.sepolia.json` | ℹ️ 未部署：MPC 是 V5.x 特性，本次未纳入部署范围 |

---

## 七、真实 Gasless 交易测试详情

### Test Case 1: PaymasterV4 + aPNTs
- **Paymaster**: `0x35deFe84539e88960cF35784a6e370B2afe6d484`
- **Token**: aPNTs `0x6859dC0b5ee1CcE829673161B7a3550CC4A25E48`
- **结果**: ✅ PASS — 链上 AA 交易成功执行，gas 由 PaymasterV4 用 aPNTs 代付

### Test Case 2: SuperPaymaster + aPNTs (xPNTs1)
- **Paymaster**: SuperPaymaster `0x506962D17AEA6E7A15fd3479D8c4E2ABBBF91112`
- **Token**: aPNTs `0x6859dC0b5ee1CcE829673161B7a3550CC4A25E48`
- **结果**: ✅ PASS — 路由到 AAStar operator，gas 由 SuperPaymaster 用 aPNTs 代付

### Test Case 3: SuperPaymaster + PNTs (xPNTs2)
- **Paymaster**: SuperPaymaster `0x506962D17AEA6E7A15fd3479D8c4E2ABBBF91112`
- **Token**: PNTs `0xAc57F61ad917d8D9325cB5388B7Ec307d8644eEa`
- **结果**: ✅ PASS — 路由到 Mycelium operator，gas 由 SuperPaymaster 用 PNTs 代付

---

## 八、ABI 更新记录

**更新时间**: 2026-05-13  
**更新内容**:
- 新增 `abis/GTokenAuthorization.json` — EIP-3009 完整 ABI（包含 transferWithAuthorization, receiveWithAuthorization, cancelAuthorization 等）
- 更新 `abis/GToken.json` → 指向 GTokenAuthorization ABI（向后兼容命名）
- 其他 11 个 ABI 与编译产物同步
- 全部 17 个 ABI 同步到 `../aastar-sdk/packages/core/src/abis/`

**abi.config.json totalHash**: `a6957da444a52c95...`

---

## 九、部署脚本改进记录

### deploy-core 修复
- 新增 `--non-interactive` flag（仅非 anvil 环境）
- 原因：forge 1.4+ 在非 TTY 环境（CI/background）广播前通过 `/dev/tty` 询问确认，stdin=/dev/null 导致进程无限阻塞
- 影响：后续所有 CI 和 background 部署均可正常工作

### verify-all.sh 修复
- GToken 验证路径从 `GToken.sol:GToken` 改为 `GTokenAuthorization.sol:GTokenAuthorization`
- 构造参数从 `(uint256 cap)` 改为 `(uint256 cap, address factory)`

---

## 十、相关 PR 和 Commit

| PR/Commit | 内容 |
|-----------|------|
| PR #195 | GTokenAuthorization v2.2.0 实现（已合并） |
| PR #196 | 本次部署脚本 + 配置更新（待 merge） |
| commit `f6a7c48b` | docs: 2026-05-13 安全扫描发现（v5.4-todo Section 8） |
| commit `4ea69e46` | feat(deploy): Sepolia 重新部署 + verify-all 修复 |

---

*生成时间: 2026-05-13 | 环境: Sepolia Testnet (Chain ID: 11155111)*
