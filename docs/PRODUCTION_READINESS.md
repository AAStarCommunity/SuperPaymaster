# SuperPaymaster — Production Readiness (CC-30)

**Repo**: `AAStarCommunity/SuperPaymaster` (repo:sp)
**Role in ecosystem**: Gas-abstraction infra (ERC-4337 Paymaster + Registry + xPNTs + BLS/DVT slash). A **dependency hub** — YAAA(Cos72) gasless, SDK canonical addresses, and airaccount aPNTs all depend on SP being two-network ready.
**Current version**: `SuperPaymaster-5.4.2` (main == Sepolia).
**Last updated**: 2026-07-09.

> **Legend** — `[测]` testnet-only enough to ship · `[主]` must fix before mainnet · `[配]` two networks differ only by config.
> Core principle: **testnet vs mainnet = configuration only; contract logic is identical.**

---

## 1. SuperPaymaster readiness table

| # | 项 | 评估 | 状态 | 阻塞主网? | 标注 |
|---|---|---|---|---|---|
| 1 | 核心 V5.4.2 全栈（SP / Registry / xPNTs / GTokenStaking / MySBT / BLSAggregator / DVTValidator） | Sepolia 部署 + 验证，全量 **1156 forge 测试绿** | ✅ 就绪 | 否 | [测]=[主] |
| 2 | CC-28 xPNTs 滥发防护（isOverIssued 价值模型） | Codex 2 轮加固，Sepolia CC-28 工厂 + demo over-issue 已部署验证（#344/#345） | ✅ 就绪 | 否（测试网） | [测]；主网需部署带防护的 xPNTs（→ G1/G3） |
| 3 | CC-29 LivenessRegistry（offline 客观化 auto-jail） | Codex 3 轮 APPROVE，Sepolia `0x02d841F7905aFb4424DBA71680D27C0F75d36BE7` 部署 + cast 验证 | ✅ 就绪 | 否 | [测]；主网另部署 |
| 4 | **G1 · 主网 V3→V5 全栈重部署** | **OP 主网仍是 `SuperPaymaster-3.2.2 / Registry-3.0.2` 旧 V3**（`config.optimism.json`）；测试网 + SDK 是 5.4.2 | 🔴 未开始 | **是（主网头号阻塞）** | [主] — YAAA/SDK/airaccount 全等这个 |
| 5 | 主网部署 config + 多签 wiring | `config.op-mainnet.json` 为空；无 V5 主网 config | 🔴 未开始 | 是 | [主]+[配] |
| 6 | `slashPolicyAdmin` / 合约 owner 交多签 | 现 = deployer EOA；需交社区 Safe（CC-31 `0x51eD…E114`）/ Timelock | 🟠 待做 | 是（GA 门禁） | [主] |
| 7 | aPNTs 主网地址 + SP 充值 | airaccount / yaaa / SDK 都等 aPNTs 主网地址 + SP 主网充值 | 🟠 待做 | 是 | [主]+[配] |
| 8 | G10 · `config.op-mainnet.json` vs `config.optimism.json` 去冗余 | 两者都 chain 10、`paymasterV4` 值不同 → 定权威删冗余 | 🟠 待做 | 否 | [配] |
| 9 | 外部安全审计（V5.4.2 全栈） | GA 硬门禁（与 airaccount #29 同级）；主网前应过外部审计 | 🔴 待 jason | 是（GA） | [主] |
| 10 | 版本命名规范（CC-14 / #256） | 对外版本号带产品名（禁裸数字） | 🟡 约定 | 否 | [测] |
| 11 | 审计 Low 追踪 #328（L-1~L-14 + M-6） | 追踪伞，多数已修（audit H/M 批次 #245-#250/#203-#214 已闭） | 🟡 盘点 | 否 | [测] |
| 12 | 测试 gap #257 | 剩余测试补充 | 🟡 backlog | 否 | [测] |

### 下一期（非 YAAA 正式版阻塞 — 记录在案）

| 类 | issue | 说明 | 阻塞? |
|---|---|---|---|
| v5.4 架构重构（redeploy 批次） | #251 god-contract 拆分 · #252 Registry 双向环 + 预言机去重 · #253 架构 Medium · #254 Gas 热路径 · #211 UUPS 批 · #212 非升级重部署批 | 优化，非硬阻塞（V5.4.2 已可用可审计）；搭下次 redeploy 一起做 | 否 |
| 功能 | #300 ERC-7677 web 服务 · #237 x402/agent settlement e2e · #217 ERC-8004 Agent Policy | 增量功能，非 YAAA 正式版依赖 | 否 |
| 设计债 | #321 DVT crypto 层统一 · #299 Registry 瘦身 · #286 aNode monorepo · #343 v4 EIP-1167 迁移 · #332 credit-purchase/ValidationLens 设计保留 | 记录在案，下一期 | 否 |

**Open PRs**: 无。**代码 TODO/FIXME**: 见 `docs/v5.4-todo.md`（推迟项已归入上表下一期）。

---

## 2. Dependency matrix

### 谁依赖 SP（SP 更新后必须 @ 通知）
| repo | 依赖内容 | 当前可解? |
|---|---|---|
| **@repo:yaaa** | gasless 上主网 = SP 主网 V5 部署 + 充值 + `slashPolicyAdmin` 交多签 | 测试网 ✅；主网等 G1 |
| **@repo:sdk** | canonical 主网地址（G1）；xPNTs 防护 ABI（G3，SDK 侧已 vendored）；CC-29 LivenessRegistry ABI（已给） | 测试网 ✅；主网等 G1，照 CC-18 两阶段接 canonical |
| **@repo:airaccount-contract** | aPNTs 主网地址（gasless） | 主网等第 7 项 |
| **@repo:dvt** | 读 CC-29 LivenessRegistry（已给 `0x02d841…`）；CC-13 slash 流水线 | ✅ 可接线 |

### SP 依赖谁（主网前需就位）
| repo | 需要什么 |
|---|---|
| **@repo:dvt** | 主网 DVT validator 地址 + 生产节点（BLS quorum 是 slash 前置）；CC-13 slash 真 E2E |
| **@repo:airaccount-contract** | 主网账户工厂 / validator 地址（如 SP 交互点需要） |
| **@repo:kms** | （间接）DVT 生产节点密钥 provision |
| **jason / 配置** | OP 主网 Safe（CC-31 已有 `0x51eD…E114`）、主网 RPC、部署 keystore、**外部审计** |

---

## 3. Release gates

### 测试网（Sepolia）— 🟢 SP 侧无阻塞
V5.4.2 全栈已发；CC-28 / CC-29 已上；SDK 侧 ABI 门禁（G2/G3/G4）已清零。**可支撑 YAAA 测试网正式版发布。**

### 主网（OP）— 🔴 阻塞清单
1. **G1** — V5.4.2 全栈重部署到 OP 主网（覆盖旧 V3）← 头号
2. 主网 config + 多签 wiring（第 5 项）
3. `slashPolicyAdmin` / owner 交社区 Safe（第 6 项）
4. aPNTs 主网地址 + SP 充值（第 7 项）
5. 外部安全审计（第 9 项，jason）
6. G10 config 去冗余（第 8 项）

### SP 能独立先做（不等外部，已排序）
1. 建 **OP 主网 V5 部署脚本 + config 骨架**（复用 Sepolia 部署链，只差 RPC/地址/env）。
2. **G10** config 去冗余（定权威 op-mainnet config）。
3. **slashPolicyAdmin / owner 交多签** 流程（Safe 地址 CC-31 已有；照 CC-29 「EOA→稳定后 transferOwnership」模式）。
4. 版本命名规范（CC-14）落地。

---

## 4. 单一真相源约定
本文件是 SP 侧 production-ready 单一真相源，回帖汇入 YAAA 合并版 `YetAnotherAA/docs/PRODUCTION_READINESS.md`。SP 主网地址部署后回 CC-30 + @ `repo:sdk` / `repo:yaaa` / `repo:airaccount-contract` 跟进。
