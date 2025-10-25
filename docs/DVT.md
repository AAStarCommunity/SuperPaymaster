# DVT Validator 和 BLS 签名技术文档

## 目录
1. [核心概念](#1-核心概念)
2. [在 SuperPaymaster V2 中的应用](#2-在-superpaymaster-v2-中的应用)
3. [注册过程详解](#3-注册过程详解)
4. [工作流程示例](#4-工作流程示例)
5. [能力范围和限制](#5-能力范围和限制)
6. [参数总结](#6-参数总结)
7. [生产环境部署指南](#7-生产环境部署指南)

---

## 1. 核心概念

### 1.1 DVT (Distributed Validator Technology) - 分布式验证器技术

#### 问题背景
在传统的区块链系统中，如果依赖单一节点进行验证和监控，会存在：
- **单点故障**：节点宕机则整个系统无法工作
- **作恶风险**：单一节点可能被攻击或恶意操作
- **缺乏共识**：一个节点的判断可能不准确

#### DVT 解决方案
```
传统模式：
1个节点 → 做出决策 → 执行操作
(单点)     (无共识)    (风险高)

DVT 模式：
13个独立节点 → 7个以上同意 → 才能执行操作
(分布式)       (阈值共识)     (安全可靠)
```

#### 核心特性
- **去中心化**：13 个独立运行的监控节点
- **容错性**：最多可容忍 6 个节点失败或作恶
- **共识机制**：需要 7/13（超过半数）节点同意才能执行操作
- **抗审查**：单个节点无法阻止合法操作

### 1.2 BLS 签名 (Boneh-Lynn-Shacham Signature)

#### 为什么选择 BLS？

1. **签名聚合**：可以将多个签名合并成一个
   - 传统 ECDSA：需要存储和验证 7 个独立签名
   - BLS：7 个签名聚合成 1 个，大小固定 96 字节

2. **验证高效**：验证一个聚合签名比验证多个独立签名快得多
   - ECDSA：需要 7 次验证操作
   - BLS：只需 1 次配对验证

3. **空间节省**：节省链上存储成本
   - ECDSA：7 × 65 字节 = 455 字节
   - BLS：96 字节（聚合签名）

#### 技术原理

**数学基础**：椭圆曲线密码学（BLS12-381 曲线）

```
密钥生成：
┌─────────────────────────────────────────────┐
│ 1. 每个 validator 生成密钥对：              │
│    - 私钥 (SK): 随机 32 字节                │
│    - 公钥 (PK): SK × G1 = 48 字节 G1 点    │
│                                              │
│ 2. 公钥注册到链上（BLSAggregator 合约）    │
│    - 任何人都可以查看和验证                 │
└─────────────────────────────────────────────┘

签名过程：
┌─────────────────────────────────────────────┐
│ Message: keccak256(proposalId, operator, level, nonce)
│                                              │
│ Validator 1: Sign(SK1, Message) → Sig1      │
│ Validator 2: Sign(SK2, Message) → Sig2      │
│ Validator 3: Sign(SK3, Message) → Sig3      │
│ ...                                          │
│ Validator 7: Sign(SK7, Message) → Sig7      │
│                                              │
│ 每个签名都是 96 字节的 G2 点                 │
└─────────────────────────────────────────────┘

签名聚合：
┌─────────────────────────────────────────────┐
│ AggSig = Sig1 + Sig2 + ... + Sig7           │
│                                              │
│ 在 G2 群上进行点加法运算                     │
│ 结果仍然是 96 字节的 G2 点                   │
└─────────────────────────────────────────────┘

验证（配对验证）：
┌─────────────────────────────────────────────┐
│ 1. 聚合公钥：                                │
│    AggPK = PK1 + PK2 + ... + PK7             │
│                                              │
│ 2. 配对验证：                                │
│    e(H(Message), AggPK) == e(AggSig, G2)     │
│                                              │
│    其中：                                    │
│    - e() 是配对函数                          │
│    - H() 是哈希到曲线函数                    │
│    - G2 是 G2 群的生成元                     │
│                                              │
│ 3. 验证通过 → 签名有效                      │
└─────────────────────────────────────────────┘
```

#### BLS 曲线参数

```
曲线：BLS12-381
- 安全级别：128 位
- 公钥大小：48 字节（G1 点压缩）
- 签名大小：96 字节（G2 点压缩）
- 配对友好：支持高效的配对运算

群结构：
- G1：定义在基域 Fq 上的椭圆曲线点
- G2：定义在扩展域 Fq² 上的椭圆曲线点
- GT：目标群（配对结果）

优势：
- 签名聚合：O(n) 个签名 → O(1) 个聚合签名
- 验证效率：O(n) 次验证 → O(1) 次验证
- 空间效率：固定 96 字节，无论多少签名者
```

---

## 2. 在 SuperPaymaster V2 中的应用

### 2.1 系统架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    SuperPaymaster V2 生态系统                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  Operators (运营商)                                     │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │    │
│  │  │Operator 1│  │Operator 2│  │Operator N│             │    │
│  │  │质押: 50sGT│ │质押:100sGT│ │质押: 30sGT│             │    │
│  │  │状态:Active│ │状态:Active│ │状态:Paused│             │    │
│  │  └──────────┘  └──────────┘  └──────────┘             │    │
│  │                                                          │    │
│  │  职责：                                                  │    │
│  │  - 质押 stGToken (最低 30 sGT)                          │    │
│  │  - 提供 gas 赞助服务                                    │    │
│  │  - 维护 aPNTs 余额 (最低 100 aPNTs)                    │    │
│  │  - 处理用户交易                                         │    │
│  └────────────────────────────────────────────────────────┘    │
│                           ↓                                     │
│                    【实时监控】                                  │
│                           ↓                                     │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  DVT Validators (13个分布式监控节点)                    │    │
│  │                                                          │    │
│  │  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐    │    │
│  │  │ V1 │ │ V2 │ │ V3 │ │ V4 │ │ V5 │ │ V6 │ │ V7 │    │    │
│  │  └────┘ └────┘ └────┘ └────┘ └────┘ └────┘ └────┘    │    │
│  │  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐          │    │
│  │  │ V8 │ │ V9 │ │V10 │ │V11 │ │V12 │ │V13 │          │    │
│  │  └────┘ └────┘ └────┘ └────┘ └────┘ └────┘          │    │
│  │                                                          │    │
│  │  监控指标（每个区块检查）：                              │    │
│  │  ┌──────────────────────────────────────────────────┐  │    │
│  │  │ 1. 余额监控：aPNTs balance < 100                 │  │    │
│  │  │ 2. 失败率监控：连续失败次数 > 10                 │  │    │
│  │  │ 3. 活跃度监控：超过 7 天无交易                   │  │    │
│  │  │ 4. 质押监控：stGToken 低于最低要求              │  │    │
│  │  └──────────────────────────────────────────────────┘  │    │
│  │                                                          │    │
│  │  每个 Validator 拥有：                                   │    │
│  │  - 以太坊地址（用于链上交互）                            │    │
│  │  - BLS 私钥（用于签名，保密）                           │    │
│  │  - BLS 公钥（48字节，注册在链上）                       │    │
│  │  - Node URI（监控服务端点）                             │    │
│  └────────────────────────────────────────────────────────┘    │
│                           ↓                                     │
│                  【发现违规行为】                                 │
│                           ↓                                     │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  Slash Proposal (惩罚提案)                              │    │
│  │                                                          │    │
│  │  任一 Validator 发现问题后创建提案：                     │    │
│  │  ┌──────────────────────────────────────────────────┐  │    │
│  │  │ Proposal ID: 1                                    │  │    │
│  │  │ Operator: 0xe24b6f321B0140716a2b671ed0D983bb...   │  │    │
│  │  │ Slash Level: MINOR                                │  │    │
│  │  │ Reason: "aPNTs balance below 100 threshold"       │  │    │
│  │  │ Created At: 1735135200                            │  │    │
│  │  │ Expires At: 1735221600 (24小时后)                 │  │    │
│  │  │ Status: PENDING                                   │  │    │
│  │  └──────────────────────────────────────────────────┘  │    │
│  │                                                          │    │
│  │  提案等级：                                              │    │
│  │  - WARNING: 首次违规，仅警告 (声誉 -10)                 │    │
│  │  - MINOR: 二次违规，轻度惩罚 (扣5% stake, 声誉-20)      │    │
│  │  - MAJOR: 严重违规，重度惩罚 (扣10% stake + 暂停)       │    │
│  └────────────────────────────────────────────────────────┘    │
│                           ↓                                     │
│                    【投票签名阶段】                               │
│                           ↓                                     │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  Validators 独立验证并签名                               │    │
│  │                                                          │    │
│  │  每个 Validator 独立执行：                               │    │
│  │  1. 接收提案通知（链上事件）                             │    │
│  │  2. 独立验证违规事实                                     │    │
│  │  3. 如果确认违规，用 BLS 私钥签名                        │    │
│  │  4. 提交签名到 DVTValidator 合约                        │    │
│  │                                                          │    │
│  │  签名进度（示例）：                                      │    │
│  │  [✓] Validator 1: 已签名                                │    │
│  │  [✓] Validator 2: 已签名                                │    │
│  │  [✓] Validator 3: 已签名                                │    │
│  │  [✓] Validator 4: 已签名                                │    │
│  │  [✓] Validator 5: 已签名                                │    │
│  │  [✓] Validator 6: 已签名                                │    │
│  │  [✓] Validator 7: 已签名 ← 达到 7/13 阈值！            │    │
│  │  [ ] Validator 8: 未响应                                │    │
│  │  [ ] Validator 9: 未响应                                │    │
│  │  ...                                                     │    │
│  │                                                          │    │
│  │  → 自动触发聚合和执行                                    │    │
│  └────────────────────────────────────────────────────────┘    │
│                           ↓                                     │
│                    【BLS 签名聚合】                              │
│                           ↓                                     │
│  ┌────────────────────────────────────────────────────────┐    │
│  │  BLSAggregator 合约                                     │    │
│  │                                                          │    │
│  │  步骤 1: 聚合签名                                        │    │
│  │  ┌──────────────────────────────────────────────────┐  │    │
│  │  │ 输入：7 个独立签名 (每个 96 字节)                │  │    │
│  │  │ Sig1 = 0x8a3d...                                  │  │    │
│  │  │ Sig2 = 0x9f2e...                                  │  │    │
│  │  │ ...                                               │  │    │
│  │  │ Sig7 = 0x7b1c...                                  │  │    │
│  │  │                                                    │  │    │
│  │  │ 聚合：AggSig = Sig1 + Sig2 + ... + Sig7          │  │    │
│  │  │ 输出：1 个聚合签名 (96 字节)                      │  │    │
│  │  │ AggSig = 0xa5f4...                                │  │    │
│  │  └──────────────────────────────────────────────────┘  │    │
│  │                                                          │    │
│  │  步骤 2: 验证聚合签名                                    │    │
│  │  ┌──────────────────────────────────────────────────┐  │    │
│  │  │ 1. 构造消息哈希：                                 │  │    │
│  │  │    msg = keccak256(proposalId, operator,         │  │    │
│  │  │                    slashLevel, nonce)             │  │    │
│  │  │                                                    │  │    │
│  │  │ 2. 聚合公钥：                                     │  │    │
│  │  │    AggPK = PK1 + PK2 + ... + PK7                 │  │    │
│  │  │                                                    │  │    │
│  │  │ 3. 配对验证：                                     │  │    │
│  │  │    e(H(msg), AggPK) == e(AggSig, G2)             │  │    │
│  │  │                                                    │  │    │
│  │  │ 4. 验证通过 ✓                                     │  │    │
│  │  └──────────────────────────────────────────────────┘  │    │
│  │                                                          │    │
│  │  步骤 3: 执行惩罚                                        │    │
│  │  ┌──────────────────────────────────────────────────┐  │    │
│  │  │ 调用 SuperPaymaster.executeSlashWithBLS():       │  │    │
│  │  │                                                    │  │    │
│  │  │ 参数：                                            │  │    │
│  │  │ - operator: 被惩罚的运营商地址                   │  │    │
│  │  │ - level: MINOR                                    │  │    │
│  │  │ - proof: 聚合签名 (作为证明)                     │  │    │
│  │  │                                                    │  │    │
│  │  │ 执行结果：                                        │  │    │
│  │  │ ✓ 扣除 5% 质押 (2.5 sGT)                         │  │    │
│  │  │ ✓ 声誉分数 -20                                    │  │    │
│  │  │ ✓ 记录惩罚历史                                    │  │    │
│  │  │ ✓ 触发 SlashExecuted 事件                        │  │    │
│  │  └──────────────────────────────────────────────────┘  │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 合约关系图

```
┌──────────────────────────────────────────────────────────┐
│                     Owner (部署者)                        │
│                    0x411BD567...                          │
└───────────────┬──────────────────────┬───────────────────┘
                │                      │
                │ registerValidator()  │ registerBLSPublicKey()
                │                      │
        ┌───────▼──────────┐   ┌──────▼────────────┐
        │  DVTValidator    │   │  BLSAggregator    │
        │  合约            │◄──┤  合约             │
        └───────┬──────────┘   └──────┬────────────┘
                │                      │
                │ createSlashProposal()│ verifyAndExecute()
                │ signProposal()       │
                │                      │
        ┌───────▼──────────────────────▼────────────┐
        │         SuperPaymasterV2 合约              │
        │                                             │
        │  executeSlashWithBLS(operator, level, proof)
        │                                             │
        │  职责：                                     │
        │  - 执行惩罚决策                             │
        │  - 扣除质押                                 │
        │  - 更新声誉分数                             │
        │  - 暂停/恢复运营商                          │
        └─────────────────────────────────────────────┘
                │
                │ 影响
                │
        ┌───────▼──────────┐
        │  Operator        │
        │  账户状态        │
        │                  │
        │  - 质押余额      │
        │  - 声誉分数      │
        │  - Active 状态   │
        └──────────────────┘
```

### 2.3 数据流图

```
监控周期：每个区块 (~12秒)

┌─────────────────────────────────────────────────────────┐
│ Validator 1-13 (并行运行)                                │
│                                                          │
│ while (true) {                                           │
│     // 1. 获取所有 active operators                     │
│     operators = SuperPaymaster.getActiveOperators();     │
│                                                          │
│     for (operator in operators) {                        │
│         // 2. 检查 aPNTs 余额                           │
│         balance = getAPNTsBalance(operator);             │
│         if (balance < 100e18) {                          │
│             createProposal(operator, MINOR,              │
│                 "aPNTs balance below threshold");        │
│         }                                                │
│                                                          │
│         // 3. 检查失败率                                │
│         stats = getOperatorStats(operator);              │
│         if (stats.consecutiveFailures > 10) {            │
│             createProposal(operator, MAJOR,              │
│                 "Consecutive failures exceeded");        │
│         }                                                │
│                                                          │
│         // 4. 检查活跃度                                │
│         if (now - stats.lastActivity > 7 days) {         │
│             createProposal(operator, WARNING,            │
│                 "Inactive for over 7 days");             │
│         }                                                │
│     }                                                    │
│                                                          │
│     // 5. 监听新提案并签名                              │
│     listenForNewProposals();                             │
│                                                          │
│     sleep(12 seconds);  // 等待下一个区块               │
│ }                                                        │
└─────────────────────────────────────────────────────────┘
```

---

## 3. 注册过程详解

### 3.1 DVT Validator 注册

#### 合约接口

```solidity
// DVTValidator.sol
function registerValidator(
    address validatorAddress,  // Validator 的以太坊地址
    bytes memory blsPublicKey, // BLS 公钥（48字节）
    string memory nodeURI      // 节点服务器地址
) external onlyOwner;
```

#### 参数说明

| 参数 | 类型 | 长度 | 说明 | 示例 |
|------|------|------|------|------|
| `validatorAddress` | `address` | 20 bytes | Validator 的以太坊地址，用于链上交互和接收奖励 | `0xae2FC1dfe37a2aaca0954fba8BB713081b4161e7` |
| `blsPublicKey` | `bytes` | 48 bytes | BLS12-381 曲线上的 G1 点（压缩格式），用于验证签名 | `0x8d5e7f3a2b...` (48字节) |
| `nodeURI` | `string` | 可变 | 节点的网络地址，用于节点间通信和监控 | `https://dvt-node-0.example.com` |

#### 注册流程

```
Step 1: Owner 准备 Validator 信息
┌─────────────────────────────────────────────────────────┐
│ 1. 生成 BLS 密钥对（离线）                              │
│    $ bls-keygen generate                                 │
│    → Private Key: 保存到安全存储（HSM/加密文件）        │
│    → Public Key:  0x8d5e7f3a2b... (48 bytes)            │
│                                                          │
│ 2. 部署监控节点服务器                                   │
│    - 配置服务器 IP 和域名                               │
│    - 安装监控软件                                       │
│    - 配置 RPC 端点                                      │
│    → Node URI: https://dvt-node-0.example.com           │
│                                                          │
│ 3. 为 Validator 创建以太坊账户                          │
│    $ cast wallet new                                     │
│    → Address: 0xae2FC1dfe37a2aaca0954fba8BB713081b4161e7│
│    → 充值少量 ETH（用于 gas）                           │
└─────────────────────────────────────────────────────────┘

Step 2: 调用注册函数
┌─────────────────────────────────────────────────────────┐
│ cast send $DVT_VALIDATOR \                               │
│   "registerValidator(address,bytes,string)" \            │
│   0xae2FC1dfe37a2aaca0954fba8BB713081b4161e7 \          │
│   0x8d5e7f3a2b... \                                      │
│   "https://dvt-node-0.example.com" \                     │
│   --private-key $OWNER_PRIVATE_KEY                       │
└─────────────────────────────────────────────────────────┘

Step 3: 链上存储
┌─────────────────────────────────────────────────────────┐
│ validators[0] = ValidatorInfo({                          │
│     validatorAddress: 0xae2FC1dfe37a2aaca0954fba8BB..., │
│     blsPublicKey: 0x8d5e7f3a2b...,                       │
│     nodeURI: "https://dvt-node-0.example.com",           │
│     registeredAt: 1735135200,                            │
│     lastCheckTime: 1735135200,                           │
│     totalChecks: 0,                                      │
│     totalProposals: 0,                                   │
│     isActive: true                                       │
│ });                                                      │
│                                                          │
│ validatorIndex[0xae2FC1...] = 1;  // index + 1          │
│ validatorCount++;  // now = 1                            │
│                                                          │
│ emit ValidatorRegistered(0xae2FC1..., 0x8d5e7f..., 0);  │
└─────────────────────────────────────────────────────────┘
```

#### 验证注册成功

```bash
# 查询 validator 数量
cast call $DVT_VALIDATOR "validatorCount()(uint256)"
# → 7

# 查询特定 validator 信息
cast call $DVT_VALIDATOR \
  "getValidator(uint256)((address,bytes,string,uint256,uint256,uint256,uint256,bool))" \
  0
# → (0xae2FC1dfe37a2aaca0954fba8BB713081b4161e7, 0x8d5e7f..., https://dvt-node-0.example.com, ...)

# 查询所有活跃 validators
cast call $DVT_VALIDATOR "getActiveValidators()(address[])"
# → [0xae2FC1..., 0x44D9bB..., 0x8947ED..., ...]
```

### 3.2 BLS 公钥注册

#### 合约接口

```solidity
// BLSAggregator.sol
function registerBLSPublicKey(
    address validator,        // Validator 地址
    bytes memory publicKey    // BLS 公钥（48字节 G1 点）
) external onlyOwner;
```

#### 注册流程

```
Step 1: 调用注册函数
┌─────────────────────────────────────────────────────────┐
│ cast send $BLS_AGGREGATOR \                              │
│   "registerBLSPublicKey(address,bytes)" \                │
│   0xae2FC1dfe37a2aaca0954fba8BB713081b4161e7 \          │
│   0x8d5e7f3a2b... \                                      │
│   --private-key $OWNER_PRIVATE_KEY                       │
└─────────────────────────────────────────────────────────┘

Step 2: 链上存储
┌─────────────────────────────────────────────────────────┐
│ blsPublicKeys[0xae2FC1...] = BLSPublicKey({              │
│     publicKey: 0x8d5e7f3a2b...,                          │
│     isActive: true                                       │
│ });                                                      │
│                                                          │
│ emit BLSPublicKeyRegistered(0xae2FC1..., 0x8d5e7f...); │
└─────────────────────────────────────────────────────────┘
```

#### 为什么需要两次注册？

```
┌─────────────────────────────────────────────────────────┐
│ DVTValidator 合约：                                      │
│ - 管理 validator 的身份和状态                           │
│ - 跟踪监控活动和提案创建                                │
│ - 控制谁可以创建和签署提案                              │
│                                                          │
│ BLSAggregator 合约：                                     │
│ - 专门负责 BLS 签名的聚合和验证                         │
│ - 存储公钥用于验证签名                                  │
│ - 执行密码学运算                                        │
│                                                          │
│ 分离的好处：                                            │
│ - 关注点分离：每个合约职责明确                          │
│ - 可升级性：可以单独升级聚合算法                        │
│ - 安全性：密码学逻辑独立验证                            │
└─────────────────────────────────────────────────────────┘
```

### 3.3 批量注册脚本

我们在 `script/v2/Step3_RegisterValidators.s.sol` 中实现了批量注册：

```solidity
contract Step3_RegisterValidators is Script {
    DVTValidator public dvtValidator;
    BLSAggregator public blsAggregator;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 注册 7 个 validators
        for (uint256 i = 0; i < 7; i++) {
            // 1. 生成确定性地址
            address validatorAddr = address(uint160(uint256(
                keccak256(abi.encodePacked("validator", i))
            )));

            // 2. 生成 48 字节 BLS 公钥（测试用）
            bytes memory blsKey = _generateTestBLSKey(i);

            // 3. 构造 Node URI
            string memory nodeURI = string(abi.encodePacked(
                "https://dvt-node-",
                vm.toString(i),
                ".example.com"
            ));

            // 4. 注册到 DVTValidator
            dvtValidator.registerValidator(
                validatorAddr,
                blsKey,
                nodeURI
            );

            // 5. 注册到 BLSAggregator
            blsAggregator.registerBLSPublicKey(
                validatorAddr,
                blsKey
            );
        }

        vm.stopBroadcast();
    }
}
```

运行批量注册：
```bash
forge script script/v2/Step3_RegisterValidators.s.sol:Step3_RegisterValidators \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vv
```

---

## 4. 工作流程示例

### 4.1 完整的惩罚流程

#### 场景：Operator 的 aPNTs 余额低于阈值

**时间线**：

```
T+0s (Block 9487800)
┌─────────────────────────────────────────────────────────┐
│ Operator 状态：                                          │
│ - Address: 0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA   │
│ - Staked: 100 sGT                                        │
│ - aPNTs Balance: 85 aPNTs ← 低于 100 阈值！             │
│ - Status: Active                                         │
│ - Reputation: 100                                        │
└─────────────────────────────────────────────────────────┘

T+12s (Block 9487801)
┌─────────────────────────────────────────────────────────┐
│ Validator 1 检测到问题：                                 │
│                                                          │
│ const balance = await xPNTs.balanceOf(operatorAddress); │
│ if (balance < 100e18) {                                  │
│     console.log("Operator aPNTs balance too low!");      │
│     await createSlashProposal(...);                      │
│ }                                                        │
└─────────────────────────────────────────────────────────┘

T+15s
┌─────────────────────────────────────────────────────────┐
│ Validator 1 创建提案：                                   │
│                                                          │
│ tx = dvtValidator.createSlashProposal(                   │
│     0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA,         │
│     1,  // SlashLevel.MINOR                              │
│     "aPNTs balance (85) below minimum threshold (100)"   │
│ );                                                       │
│                                                          │
│ 链上记录：                                              │
│ proposals[1] = SlashProposal({                           │
│     proposalId: 1,                                       │
│     operator: 0xe24b6f...,                               │
│     slashLevel: 1,                                       │
│     reason: "aPNTs balance below...",                    │
│     timestamp: 1735135215,                               │
│     expiresAt: 1735221615,  // 24小时后                 │
│     validators: [],  // 尚无签名                        │
│     signatures: [],                                      │
│     executed: false,                                     │
│     expired: false                                       │
│ });                                                      │
│                                                          │
│ emit SlashProposalCreated(1, 0xe24b6f..., 1, "...");    │
└─────────────────────────────────────────────────────────┘

T+20s ~ T+80s
┌─────────────────────────────────────────────────────────┐
│ Validators 2-7 监听到事件并独立验证：                    │
│                                                          │
│ dvtValidator.on('SlashProposalCreated', async (id) => { │
│     // 1. 读取提案详情                                  │
│     const proposal = await dvtValidator.getProposal(id);│
│                                                          │
│     // 2. 独立验证问题                                  │
│     const balance = await xPNTs.balanceOf(              │
│         proposal.operator                                │
│     );                                                   │
│                                                          │
│     if (balance < 100e18) {                              │
│         // 3. 确认违规，生成 BLS 签名                   │
│         const message = keccak256(                       │
│             id,                                          │
│             proposal.operator,                           │
│             proposal.slashLevel,                         │
│             nonce                                        │
│         );                                               │
│                                                          │
│         const signature = blsSign(myPrivateKey, message);│
│                                                          │
│         // 4. 提交签名                                  │
│         await dvtValidator.signProposal(id, signature);  │
│     }                                                    │
│ });                                                      │
│                                                          │
│ 签名进度：                                              │
│ T+20s: Validator 2 签名 ✓                               │
│ T+35s: Validator 3 签名 ✓                               │
│ T+40s: Validator 4 签名 ✓                               │
│ T+55s: Validator 5 签名 ✓                               │
│ T+65s: Validator 6 签名 ✓                               │
│ T+70s: Validator 7 签名 ✓                               │
│ T+80s: Validator 8 签名 ✓ ← 达到 7/13 阈值！           │
└─────────────────────────────────────────────────────────┘

T+81s
┌─────────────────────────────────────────────────────────┐
│ DVTValidator 自动转发到 BLSAggregator：                 │
│                                                          │
│ function signProposal(...) external {                    │
│     // ... 记录签名 ...                                 │
│                                                          │
│     if (proposal.validators.length >= MIN_VALIDATORS) {  │
│         _forwardToBLSAggregator(proposalId);             │
│     }                                                    │
│ }                                                        │
│                                                          │
│ function _forwardToBLSAggregator(...) internal {         │
│     IBLSAggregator(BLS_AGGREGATOR).verifyAndExecute(     │
│         proposalId,                                      │
│         proposal.operator,                               │
│         proposal.slashLevel,                             │
│         proposal.validators,                             │
│         proposal.signatures                              │
│     );                                                   │
│ }                                                        │
└─────────────────────────────────────────────────────────┘

T+82s
┌─────────────────────────────────────────────────────────┐
│ BLSAggregator 处理：                                     │
│                                                          │
│ 1. 聚合签名：                                           │
│    aggregatedSig = _aggregateSignatures([               │
│        sig1, sig2, sig3, sig4, sig5, sig6, sig7          │
│    ]);                                                   │
│    → 0xa5f4e8d2... (96 bytes)                            │
│                                                          │
│ 2. 验证签名：                                           │
│    messageHash = keccak256(1, 0xe24b6f..., 1, nonce);   │
│    isValid = _verifyAggregatedSignature(                 │
│        messageHash,                                      │
│        aggregatedSig,                                    │
│        [val2, val3, val4, val5, val6, val7, val8]        │
│    );                                                    │
│    → true ✓                                              │
│                                                          │
│ 3. 存储聚合结果：                                       │
│    aggregatedSignatures[1] = AggregatedSignature({      │
│        aggregatedSig: 0xa5f4e8d2...,                     │
│        individualSigs: [sig1, sig2, ...],                │
│        signers: [val2, val3, ...],                       │
│        messageHash: 0x7c3f...,                           │
│        timestamp: 1735135295,                            │
│        verified: true                                    │
│    });                                                   │
│                                                          │
│ emit SignatureAggregated(1, 0xa5f4e8d2..., 7);          │
└─────────────────────────────────────────────────────────┘

T+83s
┌─────────────────────────────────────────────────────────┐
│ BLSAggregator 执行惩罚：                                 │
│                                                          │
│ ISuperPaymaster(SUPERPAYMASTER).executeSlashWithBLS(    │
│     0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA,         │
│     SlashLevel.MINOR,                                    │
│     0xa5f4e8d2...  // 聚合签名作为证明                  │
│ );                                                       │
└─────────────────────────────────────────────────────────┘

T+84s
┌─────────────────────────────────────────────────────────┐
│ SuperPaymasterV2 执行惩罚：                              │
│                                                          │
│ function executeSlashWithBLS(                            │
│     address operator,                                    │
│     SlashLevel level,                                    │
│     bytes memory proof                                   │
│ ) external {                                             │
│     require(msg.sender == BLS_AGGREGATOR);               │
│                                                          │
│     if (level == SlashLevel.MINOR) {                     │
│         // 1. 扣除 5% 质押                              │
│         uint256 slashAmount = stake * 5 / 100;           │
│         // = 100 sGT * 5 / 100 = 5 sGT                  │
│         _slashStake(operator, slashAmount);              │
│                                                          │
│         // 2. 降低声誉                                  │
│         reputation[operator] -= 20;                      │
│         // = 100 - 20 = 80                              │
│                                                          │
│         // 3. 记录历史                                  │
│         slashHistory[operator].push(SlashRecord({        │
│             timestamp: block.timestamp,                  │
│             level: SlashLevel.MINOR,                     │
│             reason: "aPNTs balance below threshold",     │
│             proof: proof                                 │
│         }));                                             │
│                                                          │
│         emit OperatorSlashed(operator, level, proof);    │
│     }                                                    │
│ }                                                        │
│                                                          │
│ 执行后状态：                                            │
│ - Staked: 95 sGT (100 - 5)                              │
│ - Reputation: 80 (100 - 20)                              │
│ - Status: Active (仍可运营)                             │
│ - Slash Count: 1                                         │
└─────────────────────────────────────────────────────────┘

T+85s
┌─────────────────────────────────────────────────────────┐
│ DVTValidator 标记提案为已执行：                          │
│                                                          │
│ proposals[1].executed = true;                            │
│ executedProposals[1] = true;                             │
└─────────────────────────────────────────────────────────┘
```

### 4.2 代码示例

#### Validator 监控脚本（Node.js）

```javascript
// validator-monitor.js
const { ethers } = require('ethers');
const { blsSign } = require('@noble/bls12-381');

class ValidatorMonitor {
    constructor(config) {
        this.provider = new ethers.providers.JsonRpcProvider(config.rpcUrl);
        this.wallet = new ethers.Wallet(config.privateKey, this.provider);
        this.blsPrivateKey = config.blsPrivateKey;

        // 合约实例
        this.dvtValidator = new ethers.Contract(
            config.dvtValidatorAddress,
            DVT_ABI,
            this.wallet
        );
        this.superPaymaster = new ethers.Contract(
            config.superPaymasterAddress,
            SUPERPAYMASTER_ABI,
            this.provider
        );
    }

    // 主监控循环
    async start() {
        console.log('Starting validator monitor...');

        // 监听新提案事件
        this.dvtValidator.on('SlashProposalCreated',
            async (proposalId, operator, level, reason) => {
                await this.handleNewProposal(proposalId);
            }
        );

        // 定期检查 operators
        setInterval(async () => {
            await this.checkOperators();
        }, 12000);  // 每个区块
    }

    // 检查所有 operators
    async checkOperators() {
        const operators = await this.superPaymaster.getActiveOperators();

        for (const operator of operators) {
            await this.checkOperator(operator);
        }
    }

    // 检查单个 operator
    async checkOperator(operatorAddress) {
        const account = await this.superPaymaster.getOperatorAccount(
            operatorAddress
        );

        // 检查 1: aPNTs 余额
        const xPNTs = new ethers.Contract(account.xPNTsToken, ERC20_ABI, this.provider);
        const balance = await xPNTs.balanceOf(operatorAddress);

        if (balance.lt(ethers.utils.parseEther('100'))) {
            console.log(`⚠️  Operator ${operatorAddress} aPNTs balance too low: ${ethers.utils.formatEther(balance)}`);
            await this.createProposal(
                operatorAddress,
                1,  // MINOR
                `aPNTs balance (${ethers.utils.formatEther(balance)}) below minimum (100)`
            );
        }

        // 检查 2: 失败率
        const stats = await this.superPaymaster.getOperatorStats(operatorAddress);
        if (stats.consecutiveFailures > 10) {
            console.log(`⚠️  Operator ${operatorAddress} has ${stats.consecutiveFailures} consecutive failures`);
            await this.createProposal(
                operatorAddress,
                2,  // MAJOR
                `Consecutive failures (${stats.consecutiveFailures}) exceeded threshold (10)`
            );
        }

        // 检查 3: 活跃度
        const now = Math.floor(Date.now() / 1000);
        const inactiveDays = (now - stats.lastActivity) / 86400;
        if (inactiveDays > 7) {
            console.log(`⚠️  Operator ${operatorAddress} inactive for ${inactiveDays.toFixed(1)} days`);
            await this.createProposal(
                operatorAddress,
                0,  // WARNING
                `Inactive for ${inactiveDays.toFixed(1)} days (threshold: 7 days)`
            );
        }
    }

    // 创建提案
    async createProposal(operator, level, reason) {
        try {
            const tx = await this.dvtValidator.createSlashProposal(
                operator,
                level,
                reason
            );
            const receipt = await tx.wait();

            // 从事件中获取 proposal ID
            const event = receipt.events.find(e => e.event === 'SlashProposalCreated');
            const proposalId = event.args.proposalId;

            console.log(`✓ Created proposal ${proposalId} for operator ${operator}`);

            // 立即签名自己的提案
            await this.signProposal(proposalId);
        } catch (error) {
            console.error(`Failed to create proposal:`, error.message);
        }
    }

    // 处理新提案
    async handleNewProposal(proposalId) {
        console.log(`📝 New proposal ${proposalId} detected`);

        // 读取提案详情
        const proposal = await this.dvtValidator.getProposal(proposalId);

        // 检查是否已过期
        const now = Math.floor(Date.now() / 1000);
        if (now > proposal.expiresAt) {
            console.log(`Proposal ${proposalId} already expired`);
            return;
        }

        // 检查是否已签名
        for (const validator of proposal.validators) {
            if (validator === this.wallet.address) {
                console.log(`Already signed proposal ${proposalId}`);
                return;
            }
        }

        // 独立验证问题
        const verified = await this.verifyProposal(proposal);

        if (verified) {
            console.log(`✓ Proposal ${proposalId} verified, signing...`);
            await this.signProposal(proposalId);
        } else {
            console.log(`✗ Proposal ${proposalId} verification failed, not signing`);
        }
    }

    // 验证提案
    async verifyProposal(proposal) {
        // 重新检查 operator 状态
        const account = await this.superPaymaster.getOperatorAccount(
            proposal.operator
        );

        // 根据提案理由验证
        if (proposal.reason.includes('aPNTs balance')) {
            const xPNTs = new ethers.Contract(account.xPNTsToken, ERC20_ABI, this.provider);
            const balance = await xPNTs.balanceOf(proposal.operator);
            return balance.lt(ethers.utils.parseEther('100'));
        }

        if (proposal.reason.includes('Consecutive failures')) {
            const stats = await this.superPaymaster.getOperatorStats(proposal.operator);
            return stats.consecutiveFailures > 10;
        }

        if (proposal.reason.includes('Inactive')) {
            const stats = await this.superPaymaster.getOperatorStats(proposal.operator);
            const now = Math.floor(Date.now() / 1000);
            const inactiveDays = (now - stats.lastActivity) / 86400;
            return inactiveDays > 7;
        }

        return false;
    }

    // 签名提案
    async signProposal(proposalId) {
        try {
            const proposal = await this.dvtValidator.getProposal(proposalId);
            const nonce = await this.dvtValidator.proposalNonces(proposalId);

            // 构造消息
            const messageHash = ethers.utils.solidityKeccak256(
                ['uint256', 'address', 'uint8', 'uint256'],
                [proposalId, proposal.operator, proposal.slashLevel, nonce]
            );

            // BLS 签名
            const signature = await blsSign(
                this.blsPrivateKey,
                ethers.utils.arrayify(messageHash)
            );

            // 提交签名
            const tx = await this.dvtValidator.signProposal(
                proposalId,
                signature
            );
            await tx.wait();

            console.log(`✓ Signed proposal ${proposalId}`);
        } catch (error) {
            console.error(`Failed to sign proposal ${proposalId}:`, error.message);
        }
    }
}

// 启动
const config = {
    rpcUrl: process.env.RPC_URL,
    privateKey: process.env.VALIDATOR_PRIVATE_KEY,
    blsPrivateKey: process.env.BLS_PRIVATE_KEY,
    dvtValidatorAddress: process.env.DVT_VALIDATOR_ADDRESS,
    superPaymasterAddress: process.env.SUPERPAYMASTER_ADDRESS
};

const monitor = new ValidatorMonitor(config);
monitor.start();
```

---

## 5. 能力范围和限制

### 5.1 已实现的能力

#### ✅ 分布式监控
- **13 个独立节点**监控所有 operators
- **防止单点故障**：6 个节点失败仍可正常工作
- **7/13 共识机制**：需要超过半数同意才能执行

#### ✅ 自动惩罚机制
| 级别 | 触发条件 | 惩罚措施 | 声誉影响 |
|------|---------|---------|---------|
| **WARNING** | 首次轻微违规 | 仅警告，无经济损失 | -10 |
| **MINOR** | 二次违规或中度问题 | 扣除 5% stGToken | -20 |
| **MAJOR** | 严重违规或多次重犯 | 扣除 10% stGToken + 暂停运营 | -50 |

#### ✅ 签名聚合
- **空间优化**：7 个签名（7×96=672字节）→ 1个聚合签名（96字节）
- **Gas 优化**：验证 1 次 vs 验证 7 次
- **存储优化**：链上只存储聚合签名

#### ✅ 时间限制
- **提案有效期**：24 小时
- **过期自动失效**：超时提案无法执行
- **防止过时决策**：确保基于最新状态

### 5.2 当前限制（测试阶段）

#### ⚠️ BLS 签名是模拟的

**当前实现** (`src/paymasters/v2/monitoring/BLSAggregator.sol:255-283`):
```solidity
function _aggregateSignatures(bytes[] memory signatures)
    internal pure returns (bytes memory aggregated)
{
    // Simplified aggregation: concatenate for now
    // TODO: Replace with proper BLS12-381 point addition

    if (signatures.length == 0) {
        return "";
    }

    // For now: return first signature as placeholder
    // In production: implement BLS12-381 aggregation
    aggregated = signatures[0];

    // Real implementation should:
    // BLS.G2Point memory sum = BLS.G2Point(0, 0, 0, 0);
    // for (uint i = 0; i < signatures.length; i++) {
    //     BLS.G2Point memory sig = BLS.decodeG2(signatures[i]);
    //     sum = BLS.addG2(sum, sig);
    // }
    // aggregated = BLS.encodeG2(sum);
}
```

**问题**：
- 只返回第一个签名，没有真正聚合
- 无法发挥 BLS 的聚合优势
- 测试环境可用，生产环境不安全

#### ⚠️ 验证是简化的

**当前实现** (`src/paymasters/v2/monitoring/BLSAggregator.sol:293-332`):
```solidity
function _verifyAggregatedSignature(
    bytes32 messageHash,
    bytes memory aggregatedSig,
    address[] memory signers
) internal view returns (bool valid) {
    // Basic checks
    if (aggregatedSig.length == 0) return false;
    if (signers.length < THRESHOLD) return false;

    // Check all signers have registered BLS keys
    for (uint i = 0; i < signers.length; i++) {
        BLSPublicKey memory key = blsPublicKeys[signers[i]];
        if (!key.isActive || key.publicKey.length != 48) {
            return false;
        }
    }

    // TODO: Implement actual BLS pairing verification
    // bool result = BLS.verify(
    //     messageHash,
    //     aggregatedSig,
    //     _aggregatePublicKeys(signers)
    // );
    // return result;

    // For now: return true if basic checks pass
    return true;
}
```

**问题**：
- 只做基础检查（签名长度、签名者数量）
- **没有真正验证签名的密码学有效性**
- 恶意签名可能通过验证

#### ⚠️ Validators 是确定性生成的

**当前实现** (`script/v2/Step3_RegisterValidators.s.sol:59-63`):
```solidity
function _initializeValidatorData() internal {
    for (uint256 i = 0; i < 7; i++) {
        // Use deterministic addresses for testing
        address validatorAddr = address(uint160(uint256(
            keccak256(abi.encodePacked("validator", i))
        )));

        // Generate deterministic BLS key (placeholder)
        bytes memory blsKey = _generateTestBLSKey(i);

        // ...
    }
}
```

**问题**：
- 不是真实的独立服务器
- BLS 密钥是测试用的确定性生成
- 无法提供真正的分布式保障

### 5.3 生产环境需要的改进

#### 1️⃣ 实现真正的 BLS 库

**选项 A：使用 Solidity BLS 库**
```solidity
// 使用现有的 BLS 库
import "bls-solidity/contracts/BLS.sol";

function _aggregateSignatures(bytes[] memory signatures)
    internal pure returns (bytes memory aggregated)
{
    BLS.G2Point memory sum;

    for (uint i = 0; i < signatures.length; i++) {
        BLS.G2Point memory sig = BLS.decodeG2(signatures[i]);
        sum = BLS.addG2(sum, sig);
    }

    aggregated = BLS.encodeG2(sum);
}

function _verifyAggregatedSignature(
    bytes32 messageHash,
    bytes memory aggregatedSig,
    address[] memory signers
) internal view returns (bool) {
    // 聚合公钥
    BLS.G1Point memory aggPK;
    for (uint i = 0; i < signers.length; i++) {
        BLS.G1Point memory pk = BLS.decodeG1(blsPublicKeys[signers[i]].publicKey);
        aggPK = BLS.addG1(aggPK, pk);
    }

    // 配对验证
    return BLS.verify(messageHash, aggregatedSig, aggPK);
}
```

**选项 B：使用 EIP-2537 预编译**
```solidity
// 参考：https://eips.ethereum.org/EIPS/eip-2537
// 使用以太坊的 BLS 预编译合约（如果可用）

function _aggregateSignatures(bytes[] memory signatures)
    internal view returns (bytes memory)
{
    // 调用预编译合约进行 G2 点加法
    // Address: 0x0b (BLS12_G2ADD precompile)
    // ...
}
```

#### 2️⃣ 部署真实的 DVT 节点

**基础设施要求**：

```
每个 Validator 节点：
┌─────────────────────────────────────────────────────────┐
│ 硬件：                                                   │
│ - CPU: 2 cores                                           │
│ - RAM: 4 GB                                              │
│ - Storage: 50 GB SSD                                     │
│ - Network: 10 Mbps                                       │
│                                                          │
│ 软件：                                                   │
│ - OS: Ubuntu 22.04 LTS                                   │
│ - Node.js: v18+                                          │
│ - Docker: 24.0+                                          │
│                                                          │
│ 服务：                                                   │
│ - Monitoring Service (Node.js)                           │
│ - Ethereum RPC Client (Geth/Nethermind)                 │
│ - Database (PostgreSQL)                                  │
│ - Metrics (Prometheus + Grafana)                         │
│                                                          │
│ 安全：                                                   │
│ - Firewall: UFW/iptables                                │
│ - HSM: BLS 私钥存储                                      │
│ - SSL/TLS: HTTPS 加密                                    │
│ - VPN: 节点间通信                                        │
└─────────────────────────────────────────────────────────┘
```

**部署脚本**：
```bash
#!/bin/bash
# deploy-validator-node.sh

# 1. 安装依赖
sudo apt update
sudo apt install -y nodejs npm docker.io postgresql

# 2. 克隆监控软件
git clone https://github.com/yourorg/dvt-monitor.git
cd dvt-monitor
npm install

# 3. 生成 BLS 密钥（使用 HSM）
npm run keygen -- --output /secure/bls-key.json

# 4. 配置环境变量
cat > .env << EOF
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
VALIDATOR_PRIVATE_KEY=0x...
BLS_PRIVATE_KEY_PATH=/secure/bls-key.json
DVT_VALIDATOR_ADDRESS=0x...
SUPERPAYMASTER_ADDRESS=0x...
DATABASE_URL=postgresql://localhost/dvt
EOF

# 5. 启动服务
docker-compose up -d

# 6. 注册到链上
npm run register-validator
```

#### 3️⃣ 监控指标实现

**数据源**：
```javascript
class MetricsCollector {
    async collectOperatorMetrics(operator) {
        return {
            // 链上数据
            apntsBalance: await this.getAPNTsBalance(operator),
            stakeAmount: await this.getStakeAmount(operator),
            isActive: await this.isOperatorActive(operator),

            // 交易统计
            txCount: await this.getTxCount(operator),
            successRate: await this.getSuccessRate(operator),
            consecutiveFailures: await this.getConsecutiveFailures(operator),
            lastActivity: await this.getLastActivityTimestamp(operator),

            // 性能指标
            avgGasUsed: await this.getAvgGasUsed(operator),
            avgResponseTime: await this.getAvgResponseTime(operator),

            // 声誉数据
            reputation: await this.getReputation(operator),
            slashHistory: await this.getSlashHistory(operator)
        };
    }
}
```

#### 4️⃣ 安全措施

**私钥管理**：
```
┌─────────────────────────────────────────────────────────┐
│ BLS 私钥安全存储方案：                                   │
│                                                          │
│ 选项 1: 硬件安全模块 (HSM)                              │
│ - AWS CloudHSM                                           │
│ - Azure Key Vault                                        │
│ - YubiHSM 2                                              │
│                                                          │
│ 选项 2: 加密文件 + KMS                                   │
│ - AES-256-GCM 加密私钥                                   │
│ - 密钥存储在 KMS (AWS KMS/Google KMS)                   │
│ - 应用启动时解密到内存                                   │
│                                                          │
│ 选项 3: 多方计算 (MPC)                                   │
│ - 私钥分片存储                                           │
│ - 需要 t-of-n 分片才能签名                              │
│ - 更高安全性，更复杂                                     │
└─────────────────────────────────────────────────────────┘
```

**网络安全**：
```
┌─────────────────────────────────────────────────────────┐
│ 防护措施：                                               │
│                                                          │
│ 1. DDoS 防护                                             │
│    - Cloudflare                                          │
│    - AWS Shield                                          │
│    - Rate limiting                                       │
│                                                          │
│ 2. 访问控制                                              │
│    - IP 白名单                                           │
│    - API Key 认证                                        │
│    - mTLS 双向认证                                       │
│                                                          │
│ 3. 监控告警                                              │
│    - 异常流量检测                                        │
│    - 失败率告警                                          │
│    - 节点掉线通知                                        │
└─────────────────────────────────────────────────────────┘
```

---

## 6. 参数总结

### 6.1 DVT Validator 注册参数

| 参数名 | 类型 | 长度 | 必填 | 说明 | 约束 | 示例 |
|--------|------|------|------|------|------|------|
| `validatorAddress` | `address` | 20 bytes | ✓ | Validator 以太坊地址 | 不能为零地址，不能重复 | `0xae2FC1dfe37a2aaca0954fba8BB713081b4161e7` |
| `blsPublicKey` | `bytes` | 48 bytes | ✓ | BLS 公钥（G1 点） | 必须恰好 48 字节 | `0x8d5e7f3a2b1c9d...` |
| `nodeURI` | `string` | 可变 | ✓ | 节点服务器地址 | 建议使用 HTTPS | `https://dvt-node-0.example.com` |

### 6.2 BLS 公钥注册参数

| 参数名 | 类型 | 长度 | 必填 | 说明 | 约束 | 示例 |
|--------|------|------|------|------|------|------|
| `validator` | `address` | 20 bytes | ✓ | Validator 地址 | 必须已在 DVTValidator 注册 | `0xae2FC1dfe37a2aaca0954fba8BB713081b4161e7` |
| `publicKey` | `bytes` | 48 bytes | ✓ | BLS 公钥 | 必须恰好 48 字节，G1 点压缩格式 | `0x8d5e7f3a2b1c9d...` |

### 6.3 系统常量

| 常量名 | 值 | 合约 | 说明 |
|--------|-----|------|------|
| `MAX_VALIDATORS` | 13 | DVTValidator | 最大 validator 数量 |
| `MIN_VALIDATORS` | 7 | DVTValidator | 执行提案所需最小签名数（7/13 = 53.8%） |
| `THRESHOLD` | 7 | BLSAggregator | BLS 签名聚合阈值 |
| `PROPOSAL_EXPIRATION` | 24 hours | DVTValidator | 提案过期时间 |

### 6.4 Slash 级别

| 级别 | 枚举值 | 质押扣除 | 声誉扣除 | 其他惩罚 | 典型触发条件 |
|------|--------|---------|---------|---------|-------------|
| `WARNING` | 0 | 0% | -10 | 无 | 首次轻微违规、7天未活跃 |
| `MINOR` | 1 | 5% | -20 | 无 | aPNTs余额不足、二次违规 |
| `MAJOR` | 2 | 10% | -50 | 暂停运营 | 连续失败>10次、严重违规 |

### 6.5 监控阈值

| 指标 | 阈值 | 触发级别 | 说明 |
|------|------|---------|------|
| aPNTs 余额 | < 100 aPNTs | MINOR | 运营商资金不足 |
| 连续失败次数 | > 10 次 | MAJOR | 服务质量严重问题 |
| 不活跃天数 | > 7 天 | WARNING | 长期无交易 |
| 最低质押 | < 30 sGT | MAJOR | 质押不足 |

---

## 7. 生产环境部署指南

### 7.1 部署检查清单

#### 阶段 1: 准备（部署前 2-4 周）

- [ ] **BLS 库集成**
  - [ ] 选择 BLS 库（Solidity 库 or EIP-2537）
  - [ ] 实现真正的签名聚合
  - [ ] 实现配对验证
  - [ ] Gas 成本测试
  - [ ] 安全审计

- [ ] **合约审计**
  - [ ] DVTValidator 合约审计
  - [ ] BLSAggregator 合约审计
  - [ ] SuperPaymasterV2 集成审计
  - [ ] 修复审计发现的问题
  - [ ] 重新审计修复

- [ ] **基础设施准备**
  - [ ] 租用 13 台服务器（不同地理位置）
  - [ ] 配置防火墙和安全组
  - [ ] 设置 VPN/专用网络
  - [ ] 配置负载均衡和 DDoS 防护
  - [ ] 准备 HSM 或密钥管理服务

- [ ] **密钥生成**
  - [ ] 生成 13 对 BLS 密钥对
  - [ ] 生成 13 个以太坊账户
  - [ ] 安全存储私钥（HSM/加密）
  - [ ] 备份恢复测试
  - [ ] 密钥轮换计划

#### 阶段 2: 测试（部署前 1-2 周）

- [ ] **测试网部署**
  - [ ] 部署到 Sepolia
  - [ ] 注册 13 个 validators
  - [ ] 启动监控服务
  - [ ] 测试提案创建
  - [ ] 测试签名聚合
  - [ ] 测试惩罚执行

- [ ] **压力测试**
  - [ ] 并发提案处理
  - [ ] 高频率签名
  - [ ] 网络延迟模拟
  - [ ] 节点故障模拟
  - [ ] 拜占庭节点测试

- [ ] **安全测试**
  - [ ] 重放攻击测试
  - [ ] 签名伪造测试
  - [ ] 权限控制测试
  - [ ] DoS 攻击测试
  - [ ] 时序攻击测试

#### 阶段 3: 部署（1 天）

- [ ] **合约部署**
  - [ ] 部署 DVTValidator
  - [ ] 部署 BLSAggregator
  - [ ] 配置 SuperPaymasterV2 集成
  - [ ] Etherscan 验证
  - [ ] 权限配置

- [ ] **Validator 注册**
  - [ ] 注册 13 个 validators
  - [ ] 注册 BLS 公钥
  - [ ] 验证注册成功
  - [ ] 激活所有 validators

- [ ] **服务启动**
  - [ ] 部署监控软件到 13 台服务器
  - [ ] 配置 RPC 端点
  - [ ] 启动监控服务
  - [ ] 验证节点间通信
  - [ ] 启动告警系统

#### 阶段 4: 监控（持续）

- [ ] **性能监控**
  - [ ] 节点健康检查
  - [ ] 提案处理延迟
  - [ ] 签名成功率
  - [ ] Gas 消耗统计

- [ ] **安全监控**
  - [ ] 异常提案检测
  - [ ] 恶意签名检测
  - [ ] 访问日志审计
  - [ ] 密钥使用审计

- [ ] **运维管理**
  - [ ] 定期密钥轮换
  - [ ] 软件版本更新
  - [ ] 安全补丁应用
  - [ ] 备份恢复演练

### 7.2 成本估算

#### 基础设施成本（月度）

| 项目 | 数量 | 单价 | 小计 | 说明 |
|------|------|------|------|------|
| 云服务器 | 13 | $50 | $650 | AWS EC2 t3.medium 或同等配置 |
| 负载均衡 | 1 | $20 | $20 | Application Load Balancer |
| 数据传输 | - | $100 | $100 | 估计 1TB/月 |
| CloudFront CDN | - | $50 | $50 | API 加速 |
| RDS 数据库 | 1 | $80 | $80 | PostgreSQL db.t3.medium |
| HSM/KMS | 13 | $30 | $390 | AWS KMS 或 CloudHSM |
| 监控/日志 | - | $100 | $100 | CloudWatch + Datadog |
| 域名/SSL | - | $10 | $10 | 13 个子域名 |
| **合计** | - | - | **$1,400** | **月度运营成本** |

#### 一次性成本

| 项目 | 成本 | 说明 |
|------|------|------|
| 智能合约审计 | $30,000 | 2-3 轮审计 |
| 安全测试 | $10,000 | 渗透测试 |
| 开发成本 | $50,000 | BLS 库集成、监控软件开发 |
| **合计** | **$90,000** | **初始投资** |

### 7.3 维护建议

#### 日常维护
```bash
# 每日检查
./scripts/health-check.sh

# 检查项：
# - 所有 13 个节点是否在线
# - 最近 24 小时提案数量
# - 签名成功率
# - 异常日志
```

#### 周度维护
```bash
# 每周检查
./scripts/weekly-report.sh

# 生成报告：
# - 提案统计（创建/执行/过期）
# - Validator 活跃度
# - Gas 消耗统计
# - 惩罚执行记录
```

#### 月度维护
```bash
# 每月任务
1. 审查安全日志
2. 更新依赖包
3. 备份验证
4. 性能优化
5. 成本分析
```

### 7.4 应急预案

#### 场景 1: Validator 节点故障

```
问题：某个 validator 节点宕机

影响：
- 剩余 12 个节点
- 仍可达成 7/12 共识
- 系统继续正常运行

处理步骤：
1. 告警通知（5分钟内）
2. 检查故障原因
3. 重启节点或切换备用节点
4. 验证节点恢复
5. 事后分析

目标恢复时间：< 1 小时
```

#### 场景 2: BLS 签名验证失败

```
问题：聚合签名验证失败

可能原因：
1. BLS 库 bug
2. 签名格式错误
3. 公钥不匹配
4. 恶意签名

处理步骤：
1. 立即暂停提案执行
2. 分析失败日志
3. 验证单个签名
4. 识别问题 validator
5. 隔离或移除问题节点
6. 修复后恢复服务

目标恢复时间：< 4 小时
```

#### 场景 3: 大量提案积压

```
问题：提案处理速度慢于创建速度

可能原因：
1. Validator 响应慢
2. 网络拥堵
3. Gas price 过低

处理步骤：
1. 增加 Gas price
2. 优化签名流程
3. 扩展 Validator 数量
4. 调整监控频率

目标恢复时间：< 2 小时
```

---

## 附录

### A. 相关合约代码

**DVTValidator.sol**: `src/paymasters/v2/monitoring/DVTValidator.sol`
**BLSAggregator.sol**: `src/paymasters/v2/monitoring/BLSAggregator.sol`
**SuperPaymasterV2.sol**: `src/paymasters/v2/core/SuperPaymasterV2.sol`

### B. 部署脚本

**注册脚本**: `script/v2/Step3_RegisterValidators.s.sol`
**环境配置**: `.env`

### C. 参考资料

- **BLS 签名规范**: [IETF Draft](https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-bls-signature)
- **BLS12-381 曲线**: [EIP-2537](https://eips.ethereum.org/EIPS/eip-2537)
- **DVT 概念**: [Ethereum DVT](https://ethereum.org/en/staking/dvt/)
- **账户抽象**: [ERC-4337](https://eips.ethereum.org/EIPS/eip-4337)

### D. 术语表

| 术语 | 英文 | 解释 |
|------|------|------|
| DVT | Distributed Validator Technology | 分布式验证器技术 |
| BLS | Boneh-Lynn-Shacham | 一种支持签名聚合的签名算法 |
| G1/G2 | Group 1/2 | BLS12-381 曲线上的两个群 |
| 配对 | Pairing | 双线性映射，用于验证 BLS 签名 |
| 阈值 | Threshold | 执行操作所需的最小签名数 |
| 质押 | Staking | 锁定代币作为保证金 |
| 声誉 | Reputation | 基于历史行为的信用分数 |
| 惩罚 | Slash | 扣除质押和降低声誉的处罚 |

---

**文档版本**: v1.0
**最后更新**: 2025-10-25
**维护者**: SuperPaymaster 开发团队
