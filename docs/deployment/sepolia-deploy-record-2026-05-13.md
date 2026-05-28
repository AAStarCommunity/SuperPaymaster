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

### 初次运行（2026-05-13 22:43 CST）

**结果**: 21/24 通过，3 失败（原因为 mempool 限流 + 脚本 bug，见下方复测）

### 复测（2026-05-14 mempool 冷却后）

**结果**: ✅ **24/24 全部通过，0 失败**

| 组 | 测试名 | 状态 | 说明 |
|----|--------|------|------|
| Preflight | Check Contracts | ✅ PASS | |
| Preflight | Check Balances | ✅ PASS | |
| A1 | Registry Roles | ✅ PASS | |
| A2 | Registry Queries | ✅ PASS | |
| B1 | Operator Config | ✅ PASS | |
| B2 | Operator Deposit/Withdraw | ✅ PASS | |
| C1 | SuperPaymaster Negative Cases | ✅ PASS | |
| C2 | PaymasterV4 Negative Cases | ✅ PASS | |
| D1 | Reputation Rules | ✅ PASS | |
| D2 | Credit Tiers | ✅ PASS | |
| E1 | Pricing & Oracle | ✅ PASS | |
| E2 | Protocol Fees | ✅ PASS | |
| F1 | Staking Queries | ✅ PASS | |
| **F2** | **Slash History** | ✅ **PASS** | 复测 8/8，初次失败原因：mempool 限流 |
| G1 | Reputation-Gated Sponsorship | ✅ PASS | |
| G2 | Agent Identity Sponsorship (ERC-8004) | ✅ PASS | |
| **G3** | **Credit Tier Escalation** | ✅ **PASS** | 复测 18/18，初次失败原因：脚本 exit-code bug |
| H1 | DVT & BLS Aggregator Queries | ✅ PASS | |
| H2 | ReputationSystem Community Scoring & BLS Sync | ✅ PASS | |
| **Gasless** | **PaymasterV4 真实 gasless 交易** | ✅ PASS | TX: `0x20c99e37...` |
| **Gasless** | **SuperPaymaster + xPNTs1 (aPNTs) 真实 gasless 交易** | ✅ PASS | TX: `0xdd46b9e0...` |
| **Gasless** | **SuperPaymaster + xPNTs2 (PNTs) 真实 gasless 交易** | ✅ PASS | TX: `0x9ddd0c08...` |
| **MicroPaymentChannel** | **Open / Settle / Close** | ✅ **PASS** | TX: `0x308180b4...` |
| x402 | EIP-3009 Settlement | ✅ PASS | |

---

## 七、真实 Gasless 交易测试详情

### Test Case 1: PaymasterV4 + aPNTs
- **Paymaster**: `0x3e3ae35c545E5fc0E7746E67F21f5cf1230930A8`
- **Token**: aPNTs `0x6859dC0b5ee1CcE829673161B7a3550CC4A25E48`
- **Sender AA**: `0xECD9C07f648B09CFb78906302822Ec52Ab87dd70`
- **TX**: [`0x20c99e37fa82630d7e79401a4cb3fa5667f243d9e20e081249bde3973f849c14`](https://sepolia.etherscan.io/tx/0x20c99e37fa82630d7e79401a4cb3fa5667f243d9e20e081249bde3973f849c14)
- **Gas 用量**: 412,177（估算）
- **结果**: ✅ PASS — AA 账户成功无 ETH 转账 1 aPNTs，gas 由 PaymasterV4 用 aPNTs 代付

### Test Case 2: SuperPaymaster + aPNTs (xPNTs1)
- **Paymaster**: SuperPaymaster `0x506962D17AEA6E7A15fd3479D8c4E2ABBBF91112`
- **Token**: aPNTs `0x6859dC0b5ee1CcE829673161B7a3550CC4A25E48`
- **Sender AA**: `0x179Faf25600c01DBFcEf7971f15DcFa3FbE5d31C`
- **TX**: [`0xdd46b9e0beeb1fbf62ed0728a2367faf57cd6683e8da28f1b20f46163b3fb8a1`](https://sepolia.etherscan.io/tx/0xdd46b9e0beeb1fbf62ed0728a2367faf57cd6683e8da28f1b20f46163b3fb8a1)
- **Gas 用量**: 581,836（估算）
- **结果**: ✅ PASS — 路由到 AAStar operator，gas 由 SuperPaymaster 用 aPNTs 代付

### Test Case 3: SuperPaymaster + PNTs (xPNTs2)
- **Paymaster**: SuperPaymaster `0x506962D17AEA6E7A15fd3479D8c4E2ABBBF91112`
- **Token**: PNTs `0xAc57F61ad917d8D9325cB5388B7Ec307d8644eEa`
- **Sender AA**: `0xb78ef5C8DD059ABa48b65c8069641f30BBf0A1ED`
- **TX**: [`0x9ddd0c087cb1797f2cd06af3e364daf3e0e925b570b432ce81cdf97e385e149e`](https://sepolia.etherscan.io/tx/0x9ddd0c087cb1797f2cd06af3e364daf3e0e925b570b432ce81cdf97e385e149e)
- **Gas 用量**: 562,785（估算）
- **结果**: ✅ PASS — 路由到 Mycelium operator，gas 由 SuperPaymaster 用 PNTs 代付

### MicroPaymentChannel: Open / Settle / Close
- **合约**: MicroPaymentChannel（V5.x 流式支付）
- **TX (Close)**: [`0x308180b4a7dbfa6ef6a1e5a7e1455bec8fccea279e03fe5de2ac13bc9c376e52`](https://sepolia.etherscan.io/tx/0x308180b4a7dbfa6ef6a1e5a7e1455bec8fccea279e03fe5de2ac13bc9c376e52)
- **结算金额**: 7 aPNTs，退款 3 aPNTs
- **结果**: ✅ PASS — Open → 中途 Settle → Close 全流程验证，finalization 保护有效

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
| commit `f5b967f4` | fix(e2e-tests): 修复 gasless 测试 false PASS + 新增 setup-gasless.js 前置检查脚本 |

---

## 十一、E2E 测试脚本改进（2026-05-14）

### 根本问题（已修复）
`test-case-1/2/3` 在 AA 账户余额为零时，使用 `return` 退出 async `main()`，导致
`main().then(() => process.exit(0))` 执行，对测试运行器产生虚假 exit 0（PASS）。
三个 gasless 测试在 2026-05-13 初次记录中均为"false PASS"——实际 UserOp 未提交。

### 修复内容
- **exit code 约定**：0=PASS，1=FAIL，2=SKIP（前置条件未满足）
- 所有早退出路径改为 `process.exit(2)`
- `run-all-e2e-tests.sh`：新增 SKIP 分支（exit 2 → 黄色 SKIPPED）
- **`setup-gasless.js`（新文件）**：幂等前置检查，自动修复：
  - SuperPaymaster 价格缓存过期 → 调用 `updatePrice()`
  - PaymasterV4 价格缓存过期 → 调用 `setCachedPrice(price, now-60)`
    （PaymasterV4 存的是 Chainlink `updatedAt` 而非 `block.timestamp`，须用 `setCachedPrice` 才能真正刷新）
  - PaymasterV4 代币存款不足 → 自动 `depositFor(AA_A, aPNTs, 500)`
  - SuperPaymaster operator 余额不足 → 自动 `deposit(1000 aPNTs)`

---

*生成时间: 2026-05-13 | 复测更新: 2026-05-14 | 环境: Sepolia Testnet (Chain ID: 11155111)*
