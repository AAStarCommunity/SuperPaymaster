# SuperPaymaster V3 三阶段测试框架

本框架旨在为开发者（包括新手）提供一套标准化的、可重复的验证流程，确保 SuperPaymaster V3 及其配套合约（DVT, Credit, Registry）的逻辑正确性与安全性。

## 1. 快速入门指南 (新手必读) 🔰

如果你是第一次运行此项目，请按照以下步骤操作：

### 1.1 环境准备
1. **安装 Foundry**: [指导链接](https://book.getfoundry.sh/getting-started/installation)
2. **安装依赖**: `pnpm install`
3. **设置路径**: 确保你在项目根目录 `my-exploration/projects/SuperPaymaster` 下。

### 1.2 运行第一个测试
```bash
# 进入合约目录
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster

# 执行 V3 专属全量测试 (包含逻辑验证)
./build_v3.sh test
```

### 1.3 如何解读结果
- **PASS**: 表示该逻辑分支与预期一致。
- **FAIL**: 表示合约行为偏离设计，需查看日志。使用 `-vvvv` 可以看到详细调用轨迹 (Traces)。

---

## 2. 合约覆盖清单 (V3 关联全量) 📋

本阶段必须覆盖以下所有合约及其业务函数：

### 2.1 核心账户/角色层
- **Registry.sol**: 角色注册、生命周期管理、`registerRoleSelf`。
- **GTokenStaking.sol**: 1:1 质押锁定、提现手续费结算、惩罚划扣。

### 2.2 支付与信用层
- **SuperPaymasterV3.sol**: 预支付校验、Gas 定价、信用额度抵扣。
- **xPNTsToken.sol**: 债务记录、转账自动平账、防火墙拦截。
- **ReputationSystemV3.sol**: 积分计算、Entropy 因子应用、配额提供。

### 2.3 零节点与安全层
- **BLSAggregatorV3.sol**: DVT 签名验证。
- **Slasher.sol (or internal logic)**: 惩罚逻辑分级触发。
- **PaymasterV4_1i.sol**: V4 版本代理逻辑兼容。

---

## 3. 详细测试场景清单 🧪

### 3.1 角色生命周期测试 (Lifecycle)
| 场景 | 合约 | 验证点 |
|---|---|---|
| 初次进入 (Stake & Lock) | Registry / Staking | Token 是否正确转入 Staking， entryBurn 是否销毁。 |
| 跨角色注册 | Registry | ENDUSER 转向 COMMUNITY 是否需要补齐质押。 |
| 正常退出 (Exit & Fee) | Registry / Staking | 是否准确扣除 5%/10% 的退出费，余额是否退回。 |

### 3.2 信用与债务测试 (Credit System)
| 场景 | 合约 | 验证点 |
|---|---|---|
| 债务产生 | SuperPaymaster / xPNTs | `recordDebt` 是否准确增加用户负债。 |
| 自动平账 | xPNTsToken | 用户收入（Mint/Transfer）时是否自动优先偿还债务。 |
| 防火墙保护 | xPNTsToken | 拦截 SuperPaymaster 的 `transferFrom` 越权调用。 |

### 3.3 DVT 与惩罚测试 (Slashing)
| 场景 | 合约 | 验证点 |
|---|---|---|
| Tier 1 Slash (aPNTs) | SuperPaymaster | 仅销毁积分，不触碰质押金。 |
| Tier 2 Slash (GToken) | GTokenStaking | 直接从质押本金中扣除并转入财库。 |

---

## 4. 自动化回归命令
- **执行测试**: `FOUNDRY_PROFILE=v3-only forge test`
- **查看覆盖率**: `FOUNDRY_PROFILE=v3-only forge coverage --ir-minimum --report summary`
- **安全扫描**: `slither . --filter-paths "lib" --fail-none`
- 安全扫描报告 (Slither)。

---

## 第二阶段：Anvil 本地集成测试 (Scenario/Local E2E)
**执行环境**: 本地 Anvil 节点 + `aastar-sdk` (pnpm ts-node)。
**核心目标**: 验证跨合约交互链路、事件驱动逻辑及基于 SDK 的自动化流。

### 2.1 准备动作
- ABI 提取：`pnpm run extract-abi` (从 `out/` 复制核心 ABI 到 `sdk/abis/`)。
- 环境部署：运行 `DeployV3FullLocal.s.sol` 部署全栈到 Anvil。

### 2.2 自动化测试脚本 (aastar-sdk)
| 脚本编号 | 测试场景 | 关键验证点 |
| :--- | :--- | :--- |
| `06_local_full.ts` | 完整链路冒烟测试 | UserOp 成功 Sponsored |
| `08_registry_life.ts` | 用户生命周期测试 | SBT 铸造 -> 激活 -> 销毁 |
| `12_staking_slash.ts` | 复杂惩罚场景测试 | 多次 Slash 叠加及退出费用计算 |
| `14_credit_test.ts` | 信用额度压力测试 | 不同信誉等级对应的信用透支能力 |

### 2.3 产出要求
- 所有 TS 脚本执行成功。
- 跨合约 Event 链路日志分析。
- 本地环境稳定性 Review。

---

## 第三阶段：SDK 生产级测试与 Sepolia 验证
**执行环境**: Sepolia 测试网 + `aastar-sdk` 分布式节点。
**核心目标**: 验证真实网络延迟下的系统表现、生产级 SDK 类库的一致性及最终用户交互层。

### 3.1 准备动作
- 生产级配置：更新 `.env.sepolia`。
- 部署：运行 `DeployV3FullProduction.s.sol`。

### 3.2 验证内容
- **SDK 全接口测试**: 使用 `aastar-sdk` 核心类进行生产模拟。
- **并发与压力测试**: 模拟多个 Community 同时进行 Reputation 同步及气费代付。
- **性能报告**: 不同网络状况下的响应时间与 Gas Price 波动适应性。

---

## 持续集成与 Review 系统
1. **自动化集成**: 代码 Push 触发 Stage 1。
2. **手工 Review 点**: 每个阶段结束，开发者提供覆盖率截图及扫描结果。
3. **用户动作**: 用户执行 `手工验证命令集` 进行最终确认。
