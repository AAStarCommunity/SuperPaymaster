# Account Abstraction 钱包发展深度研究报告

> 调研日期：2026-03-21
> 作者：SuperPaymaster Research Team
> 状态：v1.0

---

## 目录

1. [传统钱包 vs AA 钱包](#1-传统钱包-vs-aa-钱包)
2. [主流 AA 钱包深度评测](#2-主流-aa-钱包深度评测)
3. [Paymaster 生态](#3-paymaster-生态)
4. [钱包技术趋势](#4-钱包技术趋势)
5. [市场数据和采用情况](#5-市场数据和采用情况)
6. [总结与展望](#6-总结与展望)

---

## 1. 传统钱包 vs AA 钱包

### 1.1 EOA 钱包的局限性

Externally Owned Account (EOA) 是以太坊最原始的账户类型，由一对公私钥控制。尽管 EOA 钱包（如 MetaMask、Trust Wallet）拥有最广泛的用户基础，但其架构存在根本性局限：

**安全风险**
- **单点故障**：一个私钥（或助记词）控制所有资产，私钥丢失意味着资产永久丢失
- **无法恢复**：没有原生的社交恢复机制，不像传统银行账户可以通过身份验证找回
- **签名单一**：只支持 secp256k1 ECDSA 签名，无法使用更现代的验证方式（如 Passkey/WebAuthn）

**用户体验缺陷**
- **Gas 必须用 ETH 支付**：用户必须持有原生代币来支付交易手续费，增加了入门门槛
- **每笔交易都需确认**：与 DApp 交互时，每一个操作都弹出签名确认，体验极差
- **无法批量操作**：approve + swap 需要两笔独立交易，不支持原子化批量执行
- **nonce 串行限制**：交易必须严格按 nonce 顺序执行，一笔 pending 会阻塞后续所有交易

**可编程性缺失**
- EOA 的验证逻辑硬编码在协议层，无法自定义验证规则
- 无法实现消费限额、白名单、时间锁等高级安全策略
- 不支持代理执行或权限委托

### 1.2 智能合约钱包的演进（Gnosis Safe -> Safe{Wallet}）

智能合约钱包通过将账户逻辑编码在链上合约中，克服了 EOA 的大部分局限。其演进路径清晰呈现了行业对"账户可编程性"的持续追求：

**第一阶段：多签钱包（2018-2020）**

Gnosis Safe 于 2018 年推出，定义了多签钱包标准。通过要求 M-of-N 个所有者签名才能执行交易，Safe 解决了单点故障问题。早期主要服务于 DAO 金库和团队资金管理场景。

**第二阶段：模块化扩展（2020-2023）**

Safe 引入了模块化架构，包括四大可插拔接口：
- **Modules（模块）**：白名单地址可代表 Safe 执行交易（如 Allowance Module 实现定额支出）
- **Guards（守卫）**：Hook 机制，在交易执行前进行额外安全检查
- **Plugins（插件）**：扩展 Safe 的功能边界
- **Signature Verifiers（签名验证器）**：支持自定义签名验证逻辑

**第三阶段：全栈智能账户基础设施（2023-至今）**

Safe 重新定位为 "Ownership Infrastructure Layer"（所有权基础设施层），从一个多签钱包演进为通用的链上所有权管理协议。截至 2025 年底：
- 管理超过 **$1000 亿** 数字资产
- 2025 年新部署 **1830 万** 个智能账户（平均每 1.7 秒创建一个）
- 处理 **$6000 亿** 交易量（占协议历史总量的 43%）
- 年化收入突破 **$1000 万**，较 2024 年底增长 5 倍

### 1.3 AA 钱包的核心优势

ERC-4337 于 2023 年 3 月在以太坊主网部署，通过 UserOperation、Bundler、EntryPoint 和 Paymaster 四大组件，在不修改协议层的前提下实现了完整的账户抽象。AA 钱包相比传统钱包具有以下核心优势：

#### 社交恢复（Social Recovery）

用户可以指定若干 "守护者"（Guardian），当私钥丢失时，通过守护者的多数投票来恢复账户控制权。这彻底告别了"助记词丢失 = 资产丢失"的困境。

实现方式包括：
- 指定可信联系人（朋友、家人）为守护者
- 使用硬件安全密钥作为备用验证
- 集成 Passkey/生物识别作为恢复因子
- 设置时间锁延迟恢复，防止恶意恢复攻击

#### 批量交易（Batched Transactions）

AA 钱包支持将多个操作原子化打包在单笔交易中执行：
- approve + swap 合并为一笔交易，节省 Gas 且更安全
- 多个 DeFi 操作（存入、借出、兑换）一次性完成
- 批量 NFT 转账或批量代币分发

#### Gas 代付（Gas Sponsorship）

通过 Paymaster 合约，AA 钱包实现了灵活的 Gas 支付方式：
- **应用方代付**：DApp 为用户全额赞助 Gas，实现真正的"无 Gas"体验
- **ERC-20 代付**：用户使用 USDC、DAI 等稳定币支付 Gas，无需持有 ETH
- **社区代付**：社区通过 xPNTs 等治理代币为成员赞助 Gas（SuperPaymaster 模式）
- **条件代付**：满足特定条件（如新用户、特定操作）时赞助 Gas

#### Session Keys（会话密钥）

Session Keys 是 AA 钱包最具颠覆性的创新之一，允许用户为 DApp 授予有限、可撤销的操作权限：
- **时间限制**：密钥仅在设定时间窗口内有效
- **操作限制**：只能调用特定合约的特定方法
- **金额限制**：设置单笔和累计消费上限
- **自动过期**：会话结束后密钥自动失效

这使得游戏、社交、DeFi 等场景可以实现类似 Web2 的"免确认"交互体验，同时保持安全性。

---

## 2. 主流 AA 钱包深度评测

### 2.1 Safe{Wallet}（原 Gnosis Safe）— 多签标准制定者

| 维度 | 详情 |
|------|------|
| **架构** | 模块化智能账户，ERC-4337 兼容，支持 Modules/Guards/Plugins/Signature Verifiers 四大扩展接口 |
| **账户标准** | 自有 Safe 协议（非 ERC-7579/6900），但兼容 ERC-4337 |
| **目标用户** | DAO、机构、团队金库、高净值个人 |
| **网络支持** | 以太坊、所有主流 L2（Base、Arbitrum、Optimism、Polygon 等）、14+ 条链 |

**功能特性：**
- M-of-N 多签机制，灵活的签名阈值配置
- 交易模拟和风险扫描（执行前预览）
- ERC-20 代付 Gas（通过 Relay Service）
- 批量交易打包（Batched Transactions），节省 Gas
- 角色权限管理（Role-Based Access Control）
- 消费限额和每日额度控制

**市场地位：**
- **$1000 亿+** 资产管理规模，行业第一
- 以太坊基金会已将其 **$6.5 亿+** 全部国库迁移至 Safe 多签
- 2025 年处理 3.26 亿笔交易
- 企业级安全审计最为充分的智能合约钱包

**用户体验：**
- Web 端为主，移动端体验相对薄弱
- 多签确认流程偏重（需多人签名），更适合机构而非个人
- 丰富的 DApp 集成（Safe Apps 生态）

### 2.2 ZeroDev (Kernel) — 模块化智能账户先驱

| 维度 | 详情 |
|------|------|
| **架构** | Kernel v3 智能账户，ERC-4337 + ERC-7579 完全兼容 |
| **账户标准** | ERC-7579（ZeroDev 是该标准的联合制定者） |
| **目标用户** | DApp 开发者（B2B2C） |
| **核心产品** | Kernel 智能账户 + SDK + 插件生态 |

**功能特性：**
- **运行时模块组合**：与 ERC-6900 的编译时绑定不同，ERC-7579 允许用户在安装插件时决定模块间的依赖关系
- 四大模块类型：Validators（签名验证）、Executors（交易执行）、Hooks（自定义逻辑）、Fallback Handlers
- 原生 Session Keys 支持，支持复杂权限规则
- Chain Abstraction（跨链抽象）能力
- Passkey/WebAuthn 验证器（被 Gemini 采用构建通用智能钱包）

**市场地位：**
- Kernel 是市场上使用最广泛的模块化智能账户
- ERC-7579 标准的联合制定者和最大推动者
- 被 Gemini 等头部交易所选用

**开发者体验：**
- TypeScript SDK 设计精良，Viem 集成
- 完善的文档和教程
- 与 Pimlico 基础设施深度集成
- Gas 优化出色（Kernel 是最省 Gas 的模块化账户之一）

### 2.3 Biconomy (Nexus) — 全栈 AA 平台

| 维度 | 详情 |
|------|------|
| **架构** | Nexus 智能账户 + Bundler + Paymaster 全栈方案 |
| **账户标准** | ERC-7579 兼容（从 SmartAccountV2 迁移至 Nexus） |
| **目标用户** | DApp 开发者，需要一站式 AA 解决方案 |
| **核心产品** | Nexus 账户 + Paymaster Service + Bundler Service |

**功能特性：**
- ERC-7579 模块化架构，支持自定义验证和执行模块
- 完整的 Paymaster 服务：Gas 赞助 + ERC-20 代付
- 高性能 Bundler 服务
- Session Keys 和嵌套类型数据验证
- ERC-7739 抗钓鱼保护
- EIP-7702 兼容，支持 EOA 升级

**市场地位：**
- Bundler 市场份额约 **15%**（以 UserOp 数量计）
- 早期 AA 生态参与者，拥有丰富的生产环境经验
- 从 V2 到 Nexus 的架构升级体现了对 ERC-7579 标准的全面拥抱
- 在 Polygon 和 Avalanche 生态有较强影响力

**开发者体验：**
- 一站式集成：Paymaster + Bundler + 智能账户 SDK
- 迁移路径完善（V2 到 Nexus 迁移指南）
- 与 Pimlico permissionless.js 等第三方 SDK 互操作

### 2.4 Alchemy Account Kit (Light Account / Modular Account) — 企业级 AA 平台

| 维度 | 详情 |
|------|------|
| **架构** | Modular Account V2 + Account Kit SDK + Bundler/Paymaster 服务 |
| **账户标准** | ERC-6900（Alchemy 是该标准的核心推动者） |
| **目标用户** | 企业级 DApp 开发者 |
| **核心产品** | Account Kit（SDK）+ Modular Account V2 + 嵌入式账户 |

**功能特性：**
- **Modular Account V2（MAv2）**：最新一代模块化账户
  - 原生 Session Keys 支持
  - Passkey/WebAuthn 验证（生物识别）
  - 权限系统：合约白名单、ERC-20 消费限额、原生代币限额（含 Gas 计算）、过期时间
- **嵌入式账户（Embedded Accounts）**：用户无需管理钱包，开箱即用
- **ERC-6900 插件生态**：MultiOwnerPlugin、SessionKeyPlugin、MultisigPlugin
- 多次安全审计（ChainLight + Quantstamp）

**市场地位：**
- 作为最大的以太坊 RPC 提供商，拥有独特的基础设施优势
- ERC-6900 标准的核心制定者（联合 Circle、Quantstamp、以太坊基金会）
- Bundler 服务曾创造最高收入记录（约 $20,000 单月）
- 企业级客户覆盖广泛

**与 ERC-7579 的竞争：**
- ERC-6900 采用更"规范性"的设计，模块依赖关系在编译时（插件开发时）确定
- 社区反馈认为 ERC-6900 过于限制性，导致 ERC-7579 阵营获得更广泛支持
- 但 MAv2 在安全审计和企业级特性方面仍领先

### 2.5 Pimlico — Bundler + Paymaster 基础设施龙头

| 维度 | 详情 |
|------|------|
| **架构** | Alto Bundler + Verifying Paymaster + ERC-20 Paymaster |
| **定位** | AA 基础设施提供商（非终端用户产品） |
| **目标用户** | AA 钱包和 DApp 开发者 |
| **核心产品** | Alto Bundler + Paymaster 服务 + permissionless.js SDK |

**功能特性：**
- **Alto Bundler**：TypeScript 编写的高性能、类型安全的 ERC-4337 Bundler
- **Verifying Paymaster**：支持 **100+ 条链** 的 Gas 赞助服务
- **ERC-20 Paymaster**：支持用 ERC-20 代币支付 Gas
- **permissionless.js**：基于 Viem 的 TypeScript SDK，支持所有主流智能账户（Kernel、Nexus、Safe、Coinbase Smart Wallet 等）

**市场地位：**
- Bundler 市场份额 **43-52%**（以 UserOp 数量/Gas 费用计），行业第一
- 支持链数量最多的 AA 基础设施
- permissionless.js 是事实上的 AA 开发标准 SDK
- 开源精神：Alto Bundler 和 ERC-20 Paymaster 均为开源项目

**开发者体验：**
- permissionless.js 与 Viem 深度集成，类型安全
- 支持所有主流智能账户类型
- 文档质量优秀，包含各种账户类型的对比指南
- Dashboard 管理 Paymaster 余额和配置

### 2.6 Coinbase Smart Wallet — 大规模消费级

| 维度 | 详情 |
|------|------|
| **架构** | 基于 ERC-4337 的智能钱包，Passkey-first 设计 |
| **账户标准** | 自有 CoinbaseSmartWallet 合约 |
| **目标用户** | 大规模消费级用户（面向 "next billion users"） |
| **核心产品** | Coinbase Smart Wallet + Base 链生态 |

**功能特性：**
- **Passkey 优先**：使用设备生物识别（Face ID、指纹）替代助记词
- **无需助记词**：云端 Passkey 支持跨设备访问
- **免 Gas 体验**：应用为用户赞助 Gas（Base Gasless Campaign 提供 $15,000 Gas 补贴）
- **批量交易**：复杂操作合并为单笔交易
- 与 Base 链深度集成

**市场地位：**
- 2025 年 8 月突破 **100 万用户**
- 单日新增账户峰值达 **27 万**（2025 年 8 月 16 日）
- 2025 年 4 月 UserOp 数量激增 **7 倍**
- 贡献了 Base 链上 **65%+** 的新智能账户部署
- 主导了 Base 链上 **87%** 的周 UserOperations

**用户体验：**
- 业界最简的注册流程：使用 Passkey 一键创建钱包
- 真正的 Web2 级别体验，无需理解区块链概念
- 与 Coinbase 交易所生态无缝衔接
- 移动端和浏览器端均流畅

### 2.7 Particle Network — Chain Abstraction + Universal Account

| 维度 | 详情 |
|------|------|
| **架构** | Universal Account + Omnichain Paymaster + Chain Abstraction 协议 |
| **账户标准** | 自有 Universal Account 标准 |
| **目标用户** | 需要跨链能力的 DApp 开发者和用户 |
| **核心产品** | Universal Account + UniversalX + Omnichain Paymaster |

**功能特性：**
- **Universal Account**：统一账户，跨链统一余额，无需桥接
- **Omnichain Paymaster**：单笔 USDT 存款即可赞助所有 EVM 链上的 Gas
- **Chain Abstraction**：用户无需感知底层链，DApp 自动路由最优执行路径
- **Universal SDK**：2025 年 7 月公开发布，供开发者构建链无关应用

**市场地位：**
- Universal Account 采用量在 2025 年 Q1 达到 **11.09 万**（同比增长 558%）
- 月增长率持续保持在 **30%** 以上
- **90+ 团队** 排队集成 Universal Account
- 与 Circle 等重要合作伙伴建立战略合作
- 基于 Avalanche L1 构建自有链

**用户体验：**
- 真正的"链无感"体验：用户无需选择链、无需桥接
- 统一余额显示：所有链上资产合并展示
- UniversalX Pro：面向高频交易者的专业交易界面

### 2.8 Privy — 嵌入式钱包 + AA

| 维度 | 详情 |
|------|------|
| **架构** | 嵌入式钱包基础设施 + AA 集成层 |
| **定位** | Web3 用户认证和钱包即服务（Wallet-as-a-Service） |
| **目标用户** | 希望为其终端用户提供无缝 Web3 体验的应用开发者 |
| **核心产品** | 嵌入式钱包 + 认证系统 + AA 集成 |

**功能特性：**
- **嵌入式钱包**：直接嵌入 DApp 的自托管钱包，用户无感知
- **灵活认证**：支持邮箱、手机号、社交登录（Google、Twitter 等）
- **AA 集成**：与 Biconomy、Pimlico 等基础设施无缝对接
- **策略引擎**：精细化权限控制（合约白名单、收款方白名单、MFA 要求、审批流程）
- **Global Embedded Wallets**：跨应用钱包（用户在 App A 创建的钱包可在 App B 使用）
- EIP-7702 支持，嵌入式钱包进化为可编程账户

**市场地位：**
- Web3 嵌入式认证领域的领先者
- 被大量消费级 DApp 采用
- 2025 年推出 Global Embedded Wallets，解决跨应用身份碎片化问题

**用户体验：**
- Web2 级别的注册和登录体验
- 用户完全不需要理解"钱包"的概念
- 应用内一体化交互，无需切换到外部钱包

### 2.9 Thirdweb — 开发者工具 + AA

| 维度 | 详情 |
|------|------|
| **架构** | In-App Wallet + Smart Wallet (ERC-4337) + SDK 套件 |
| **定位** | 全栈 Web3 开发者平台 |
| **目标用户** | Web3 开发者（从智能合约到前端的全栈） |
| **核心产品** | SDK（React、TypeScript、.NET、Unity）+ 智能钱包 + Dashboard |

**功能特性：**
- **ConnectButton 一键集成**：一行代码启用 AA 功能
- **Gas 赞助**：`accountAbstraction: { sponsorGas: true }` 即可为用户代付 Gas
- **批量交易和 Session Keys**：智能钱包原生支持
- **多平台 SDK**：React、TypeScript、.NET、Unity（覆盖 Web 和游戏场景）
- **EIP-7702 集成**：作为默认执行模式（2025 年起）
- `getAdminAccount` API：支持管理员账户检索

**市场地位：**
- Web3 开发者工具领域的头部平台
- 从合约部署到钱包集成到 AA 的全栈覆盖
- 活跃开发者社区
- 特别在游戏和 NFT 领域有强大影响力

**开发者体验：**
- 开箱即用的 AA 集成，学习成本极低
- 丰富的模板和样例代码
- Dashboard 管理合约、钱包、Paymaster 配置
- Unity SDK 使得游戏集成 AA 变得简单

### 2.10 Argent — 移动端 AA (StarkNet)

| 维度 | 详情 |
|------|------|
| **架构** | 原生 StarkNet 智能钱包（利用 StarkNet 原生 AA） |
| **定位** | 移动优先的自托管智能钱包 |
| **目标用户** | StarkNet 生态的移动端用户 |
| **核心产品** | Argent Mobile（StarkNet）+ Argent X（浏览器扩展） |

**功能特性：**
- **无助记词**：利用 StarkNet 原生账户抽象，告别助记词备份
- **Multicall 批量交易**：多笔交易合并执行，更安全且节省手续费
- **免 Gas 交易**：移动端支持 Gasless 体验
- **Session Keys**：DApp 可在用户授权的范围内代签交易，消除弹窗
- **欺诈保护**：在交易执行前警告诈骗和恶意 DApp
- **灵活 Gas 支付**：支持 ETH 或 STRK 支付手续费
- **内置 DApp 浏览器**：移动端直接访问 StarkNet 生态 DApp
- **借记卡**：支持现实世界支付

**市场地位：**
- StarkNet 生态最重要的钱包
- 移动端 AA 体验的标杆
- 利用 StarkNet 原生 AA（非 ERC-4337），在 StarkNet 生态内有独特优势

**用户体验：**
- 移动优先设计，流畅的触屏交互
- 真正自托管但不需要助记词
- 账户恢复简单且安全
- 游戏、DeFi 等场景的 Session Key 体验优秀

---

## 3. Paymaster 生态

### 3.1 Paymaster 类型与实现对比

ERC-4337 定义了 Paymaster 接口（`IPaymaster`），不同实现满足不同场景需求：

#### Verifying Paymaster（验证型 Paymaster）

**工作原理：** 链下服务决定是否赞助交易。Paymaster 合约验证链下签名，确认赞助授权。

**典型流程：**
1. 用户构建 UserOperation
2. 发送给链下赞助服务
3. 赞助服务根据规则决定是否赞助（新用户、白名单、特定操作等）
4. 若同意，返回签名后的 `paymasterAndData`
5. Bundler 提交交易，Paymaster 合约验证签名并支付 Gas

**代表实现：**
- Pimlico Verifying Paymaster（100+ 条链）
- Alchemy Gas Manager（企业级）
- Biconomy Sponsoring Paymaster

#### ERC-20 Paymaster（代币支付型 Paymaster）

**工作原理：** 用户使用 ERC-20 代币（如 USDC、DAI）支付 Gas，Paymaster 代为支付 ETH Gas 后从用户扣取等值代币。

**两种实现模式：**

1. **预扣款模式**：`validatePaymasterUserOp()` 阶段预扣最大 Gas 对应的代币，`postOp()` 退还多余部分
2. **后扣款模式**：`validatePaymasterUserOp()` 不扣款，`postOp()` 根据实际 Gas 消耗扣取代币

**代表实现：**
- Pimlico ERC-20 Paymaster（开源）
- Circle Paymaster（USDC 专用）
- SuperPaymaster（社区代币 xPNTs 支付）

#### 社区/协议 Paymaster

**工作原理：** 社区或协议为其成员赞助 Gas，通常结合治理代币或积分系统。

**代表实现：**
- SuperPaymaster（AOA+ 模式）：社区通过 Registry 注册，使用 xPNTs 社区代币支付 Gas
- Base Gasless Campaign（Coinbase 为 Base 生态赞助 $15,000 Gas 额度）
- World Chain Paymaster（World 为人类验证用户赞助 Gas）

### 3.2 各平台 Paymaster 实现对比

| 平台 | Paymaster 类型 | 支持链数 | ERC-20 支持 | 跨链 | 开源 |
|------|---------------|---------|------------|------|------|
| **Pimlico** | Verifying + ERC-20 | 100+ | USDC/DAI/USDT 等 | 否 | 是 |
| **Alchemy** | Verifying (Gas Manager) | 主流链 | 有限 | 否 | 否 |
| **Biconomy** | Sponsoring + ERC-20 | 20+ | 多种代币 | 否 | 否 |
| **Circle** | USDC Paymaster | 主流链 | 仅 USDC | 是(CCTP) | 否 |
| **Coinbase** | Verifying | Base 为主 | 有限 | 否 | 否 |
| **Particle** | Omnichain | 所有 EVM | USDT 入金 | 是 | 否 |
| **Thirdweb** | Verifying | 主流链 | 有限 | 否 | 否 |
| **SuperPaymaster** | Verifying + xPNTs | 可配置 | xPNTs 社区代币 | 规划中 | 是 |

### 3.3 Gas 代付模式详解

#### 完全赞助模式（Full Sponsorship）

- DApp/协议为用户全额支付 Gas
- 适用场景：新用户引导、游戏内操作、社交应用
- 风险：滥用和 Sybil 攻击
- 缓解措施：速率限制、白名单、用户行为分析

#### 条件赞助模式（Conditional Sponsorship）

- 根据条件决定是否赞助及赞助比例
- 条件示例：新用户前 N 笔免费、特定合约调用免费、VIP 用户全免
- 适用场景：用户激励策略、活动推广

#### ERC-20 代付模式（Token Payment）

- 用户使用 ERC-20 代币支付 Gas
- 价格通过预言机（Chainlink 等）实时转换
- 适用场景：持有大量稳定币但无 ETH 的用户
- 典型溢价：Gas 成本的 5-15%

### 3.4 Paymaster 商业模式和定价策略

| 提供商 | 定价模式 | 费率 | 说明 |
|--------|---------|------|------|
| **Pimlico** | 按 UserOp 计费 | 自定义 | 企业级定价 |
| **Alchemy** | 分层定价 | Free: 测试网免费; Growth: 8%; Enterprise: 定制 | 按赞助 Gas 金额的百分比 |
| **Circle** | 按 Gas 百分比 | 10% | 2025.7.1 起开始收费 |
| **Coinbase** | 补贴模式 | 免费（$15k 额度） | Base 生态推广 |
| **Biconomy** | SaaS + 用量 | 自定义 | Dashboard 管理 |

**行业趋势：**
- 2024 年 **87%** 的 ERC-4337 交易通过 Paymaster 代付 Gas
- Paymaster 赞助的 Gas 费用总计超过 **$340 万**
- 主要收入来源从纯 SaaS 订阅转向"Gas 溢价 + API 调用费"混合模式

### 3.5 跨链 Paymaster 方案

#### Particle Omnichain Paymaster

- 开发者在 Ethereum 或 BNB Chain 存入 USDT
- USDT 自动转换为目标链的原生代币
- 单一存款覆盖所有 EVM 链的 Gas 赞助
- 已赞助超过 **50 万** 笔 UserOperations
- 支持 Webhook 配置，精确控制赞助规则

#### Circle Paymaster (CCTP 跨链)

- 集成 CCTP（Cross-Chain Transfer Protocol）
- 一条链上的 USDC 可支付另一条链上的 Gas
- 2025 年 7 月 1 日起开始收取 10% 手续费
- 适合已有 USDC 流动性的场景

#### ERC-7677 标准

- 2025 年推出的 Paymaster 服务标准
- 定义了 DApp 与 Paymaster 服务间的标准化通信协议
- 使 Paymaster 服务可互换，降低供应商锁定风险

---

## 4. 钱包技术趋势

### 4.1 Passkey / WebAuthn 签名验证

Passkey 是 2025 年钱包领域最重要的技术突破之一，将彻底改变用户与链上账户的交互方式。

**技术原理：**
- 基于 WebAuthn 标准生成 secp256r1（P-256）密钥对
- 私钥存储在设备的安全芯片（Secure Enclave / TPM）中
- 云端 Passkey（Apple/Google）支持跨设备同步
- 链上通过 P-256 签名验证（RIP-7212 预编译合约大幅降低 Gas）

**2025 年采用情况：**
- FIDO Alliance 报告：全球超过 **10 亿** 人激活了至少一个 Passkey
- 超过 **150 亿** 在线账户支持 Passkey 认证
- Passkey 消费者认知度从 2022 年的 39% 上升至 2025 年的 **57%**
- Gemini 强制所有用户启用 Passkey，认证量增长 **269%**
- Solana 在 2025 年 6 月启用原生 secp256r1 签名验证预编译

**钱包集成：**
- Coinbase Smart Wallet：Passkey 作为主要身份验证方式
- ZeroDev Kernel：WebAuthn Validator 模块
- Alchemy MAv2：原生 Passkey/生物识别验证
- Safe：Passkey 签名验证器模块
- MetaMask：Passkey 作为备用签名者

### 4.2 Session Keys 和权限管理

Session Keys 正在从简单的"临时签名密钥"进化为完整的"链上权限管理系统"。

**ERC-7715（权限请求标准）：**
- 由 MetaMask 推动的标准，定义了 DApp 向钱包请求权限的标准化方式
- 引入 `wallet_grantPermissions` 方法
- DApp 可请求有明确范围的预批准访问权
- 示例：请求"未来 1 小时内最多花费 10 USDC"或"与特定合约交互 5 次"

**Smart Sessions（ERC-7579 生态）：**
- Rhinestone 推出的 ERC-7579 兼容 Session 模块
- 支持精细化策略配置：
  - 操作白名单（只能调用特定方法）
  - 代币消费限额
  - 时间窗口
  - 调用频率限制
- 用户可在离线状态下由 DApp 自动执行预授权操作

**MetaMask Delegation Toolkit（Smart Accounts Kit）：**
- 2025 年重命名为 Smart Accounts Kit
- 支持 ERC-4337 智能合约账户
- 委托权限给其他 SCA 或 EOA
- 与 EIP-7702 结合后，EOA 也能享受权限委托
- 支持可读权限、意图表达和链下权限

### 4.3 模块化账户标准：ERC-6900 vs ERC-7579

两个标准代表了模块化智能账户设计的不同哲学：

| 维度 | ERC-6900 | ERC-7579 |
|------|----------|----------|
| **推动者** | Alchemy, Circle, Quantstamp, EF | Rhinestone, Biconomy, ZeroDev, OKX |
| **设计哲学** | 规范性（Prescriptive） | 最小化（Minimal） |
| **模块绑定时机** | 编译时（开发者指定依赖） | 运行时（用户安装时指定） |
| **复杂度** | 高（嵌入安全措施和权限图谱） | 低（仅保证互操作性最小集） |
| **灵活性** | 受限（标准规定了合约行为边界） | 高（开发者自由度大） |
| **安全模型** | 内建安全约束 | 安全由模块自身负责 |
| **采用情况** | Alchemy 生态为主 | 行业广泛采用 |

**行业共识：**
- ERC-7579 已成为事实上的行业标准，获得了更广泛的生态支持
- ERC-6900 在 Alchemy 生态内（Modular Account V2）仍有重要应用
- 两个标准并非完全互斥，但互操作性有限
- 长期趋势看，ERC-7579 的"最小化、开放"理念更符合去中心化精神

### 4.4 EIP-7702 对钱包生态的影响

EIP-7702 随 Pectra 升级于 2025 年 5 月 7 日在以太坊主网激活，是 Account Abstraction 领域最重要的协议层变更。

**核心机制：**
- 引入新的交易类型（Type 4），允许 EOA **临时执行** 智能合约代码
- EOA 可以在单笔交易期间"指向"一个合约实现
- 不永久改变 EOA 状态，交易结束后恢复

**带来的能力：**
- **EOA 升级**：现有 MetaMask 等 EOA 钱包无需迁移即可获得 AA 能力
- **批量交易**：EOA 可在单笔交易中执行多个操作
- **Gas 赞助**：EOA 可使用 Paymaster 代付 Gas
- **替代认证**：EOA 可使用 Passkey、生物识别等新型验证
- **权限委托**：EOA 可像 SCA 一样委托权限

**钱包支持情况：**
- **MetaMask**：全面支持，推出 Smart Accounts Kit
- **Ambire**：首批支持 EIP-7702 的钱包
- **Trust Wallet**：已集成 Pectra 升级支持
- **Thirdweb**：EIP-7702 作为默认执行模式
- **Ledger**：正在评估安全模型

**与 ERC-4337 的关系：**
- **互补而非替代**：EIP-7702 让 EOA 可以使用 ERC-4337 基础设施（Bundler、Paymaster）
- EIP-7702 解决了 ERC-4337 最大的痛点：用户需要迁移到新的智能合约账户
- 两者结合使得 Account Abstraction 对 **所有** 以太坊用户可用

### 4.5 Intent-Based 交易和钱包体验

**概念：**
Intent-based（基于意图的）交易系统允许用户声明"我想做什么"而非"如何做"。系统自动找到最优的执行路径。

**2025 年进展：**
- **以太坊基金会 Open Intents Framework**：2025 年 2 月发布，超过 **30 个团队** 参与，基于 ERC-7683 构建
- **ERC-7683**：跨链意图标准，定义了统一的意图格式和执行接口
- **Solver 竞争机制**：多个 Solver 竞争执行用户意图，确保最优价格

**在钱包中的应用：**
- 用户说"我想用 Arbitrum 上的 ETH 买 Base 上的 NFT"
- 钱包自动处理桥接、兑换、购买的全部流程
- Gas 由 Solver 代付，用户以输入代币支付费用
- 无需用户选择桥、链或具体执行路径

**领先协议：**
- Across Protocol：跨链意图执行
- UniswapX：意图驱动的代币兑换
- Anoma：通用意图语言和执行引擎

### 4.6 Chain Abstraction（跨链抽象）钱包

Chain Abstraction 是 2025 年钱包领域最热门的叙事之一，目标是让用户完全无需感知底层链。

**核心理念：**
- 统一账户：用户在所有链上拥有一个身份和一个余额
- 统一流动性：资产自动在链间流转
- 统一交互：DApp 无需指定目标链

**实现方案对比：**

| 方案 | 实现方式 | 代表项目 |
|------|---------|---------|
| **Universal Account** | 自有链 + 跨链消息 | Particle Network |
| **Account + Intent** | 智能账户 + 意图执行 | ZeroDev + Across |
| **协议层** | L2 互操作标准 | Optimism Superchain |
| **Paymaster 层** | 跨链 Gas 赞助 | Particle Omnichain, Circle CCTP |

**当前挑战：**
- 跨链安全性：桥接是最大的攻击面
- 最终性差异：不同链的确认时间不同
- 状态同步：跨链状态一致性保证
- 用户资产碎片化尚未完全解决

---

## 5. 市场数据和采用情况

### 5.1 AA 钱包活跃用户数据

#### 智能账户部署量

| 时间 | 累计部署量 | 增长 |
|------|-----------|------|
| 2023 年末 | ~300 万 | — |
| 2024 年末 | ~4000 万+ | 7x YoY |
| 2025 年（Safe 单平台） | +1830 万新部署 | 平均 1.7 秒/个 |
| 2025 年中预测 | 2 亿+ | — |

#### 周活跃 UserOperations

| 时间 | 周 UserOps | 说明 |
|------|-----------|------|
| 2023 年末 | ~80 万 | 起步阶段 |
| 2025 年 4 月 | **400 万** | 5x vs 2023 |
| Coinbase Smart Wallet | 7x 激增 | 2025 年 4 月 |

#### 关键增长驱动因素

1. **Coinbase Smart Wallet + Base 链**：贡献了最大的增量
2. **Passkey 采用**：降低了用户入门门槛
3. **EIP-7702 上线**：EOA 升级带来的存量用户转化
4. **DApp 集成增加**：更多应用默认使用 AA 功能

### 5.2 各链上 UserOperation 数量趋势

#### 链上分布（2025 年 4 月数据）

| 链 | UserOps 占比 | 说明 |
|----|------------|------|
| **Base** | **87%**（周 UserOps） | 由 Coinbase Smart Wallet 驱动 |
| **Polygon** | 第二梯队 | 700 万+ 智能账户 |
| **Arbitrum** | 第三梯队 | DeFi 场景为主 |
| **Optimism** | 第四梯队 | Superchain 生态 |
| **Ethereum L1** | 较少 | Gas 成本高，AA 用户偏好 L2 |

#### 智能账户新部署分布

- Base 占 **65%+** 的新智能账户部署
- 智能账户创建峰值：2024 年 7 月单周超过 **100 万** 笔部署
- 2025 年趋稳：每周约 **12 万** 笔新部署（但现有账户活跃度持续上升）

#### 链级别交易数据（2025 年）

| 链 | 日均交易 | 趋势 |
|----|---------|------|
| Base | 5000 万+/月 | 持续增长，L2 DEX 交易量占 50% |
| Polygon PoS | 840 万/日 (Q1) | 同比增长 83% |
| Polygon CDK | +240% (Q4'24→Q1'25) | 爆发式增长 |
| Arbitrum | 4000 万/月 | 稳定增长 |

### 5.3 Bundler 和 Paymaster 市场份额

#### Bundler 市场份额

| Bundler 提供商 | 市场份额（UserOp 量） | 备注 |
|---------------|---------------------|------|
| **Pimlico (Alto)** | **43-52%** | 行业第一，TypeScript 实现 |
| **Biconomy** | ~15% | Polygon/Avalanche 为主 |
| **Alchemy (Rundler)** | 显著 | 最高单月收入 ~$20K |
| **StackUp** | ~9% | 早期参与者 |
| **Coinbase** | 增长中 | Base 生态内建 |
| 其他 | ~15-20% | 长尾分布 |

**关键洞察：**
- 15,000 个注册 Bundler 中，Pimlico 占主导
- **97.18%** 的 Bundle 交易只包含 **1 个 UserOp**，意味着绝大多数 Bundler 无法从打包中获利
- Bundler 的商业模式仍在探索中，纯 Bundler 服务盈利困难

#### Paymaster 市场份额与使用情况

- **87%** 的 ERC-4337 交易使用 Paymaster 代付 Gas（2024 年数据）
- Paymaster 赞助 Gas 总额超过 **$340 万**（2024 年）
- 主要提供商：Biconomy、Pimlico、Coinbase、Alchemy
- **88.24%** 的 AA 钱包使用次数不超过 5 次（留存率仍是挑战）

#### 智能账户类型市场份额

| 智能账户 | 生态定位 | 关键采用者 |
|---------|---------|-----------|
| **Safe** | 机构/DAO 标准 | 以太坊基金会、Aave、ENS |
| **Coinbase Smart Wallet** | 消费级标准 | Base 生态 DApp |
| **Kernel (ZeroDev)** | 开发者标准 | Gemini、DeFi 协议 |
| **Nexus (Biconomy)** | 全栈方案 | Polygon 生态 |
| **Modular Account (Alchemy)** | 企业级标准 | 企业客户 |

---

## 6. 总结与展望

### 6.1 当前行业格局

Account Abstraction 钱包生态在 2025 年进入了**成熟爆发期**：

1. **基础设施成熟**：EntryPoint v0.7 稳定运行，Bundler 和 Paymaster 服务覆盖 100+ 条链
2. **标准趋于统一**：ERC-7579 成为模块化账户的事实标准，EIP-7702 打通了 EOA 与 AA 的鸿沟
3. **用户增长强劲**：累计 4000 万+ 智能账户，周 400 万 UserOperations，87% 使用 Paymaster
4. **头部效应明显**：Base 链（Coinbase）主导增量，Pimlico 主导 Bundler 市场

### 6.2 对 SuperPaymaster 的启示

基于本次调研，对 SuperPaymaster 项目的战略建议如下：

**定位差异化：**
- 市场上的 Paymaster 解决方案主要面向"应用方赞助"或"稳定币支付"场景
- SuperPaymaster 的"社区代币 (xPNTs) 支付 Gas"模式在市场中具有独特性
- 建议强化"社区驱动的 Gas 经济"叙事，与社区治理和激励机制深度结合

**技术路线：**
- 保持 ERC-4337 EntryPoint v0.7 兼容性
- 考虑 EIP-7702 适配：允许 EOA 通过 7702 使用 SuperPaymaster
- 关注 ERC-7677 Paymaster 服务标准，确保接口互操作性
- 跨链 Paymaster 是高价值方向（参考 Particle Omnichain 模式）

**生态合作：**
- 与 Pimlico 的 permissionless.js 保持兼容（SDK 层接入）
- 考虑 ERC-7579 模块化集成（将 SuperPaymaster 封装为 Paymaster 模块）
- 探索与 Circle Paymaster 的互操作（USDC 结算层）

### 6.3 2026 年展望

1. **EIP-7702 全面落地**：MetaMask 等主流钱包完成集成，所有 EOA 用户获得 AA 能力
2. **Passkey 成为默认认证**：助记词逐渐退出主流视野
3. **Chain Abstraction 成熟**：用户不再需要选择链
4. **Intent-based UX 普及**：用户只需表达意图，执行完全抽象
5. **Paymaster 商业模式清晰化**：从补贴期过渡到可持续盈利模式
6. **模块化生态繁荣**：ERC-7579 模块市场形成，开发者可以即插即用各种账户功能

---

## 参考资料

### 标准与规范
- [ERC-4337: Account Abstraction Using Alt Mempool](https://eips.ethereum.org/EIPS/eip-4337)
- [ERC-4337 Documentation](https://docs.erc4337.io/index.html)
- [ERC-7579: Minimal Modular Smart Accounts](https://github.com/erc7579/erc7579-implementation)
- [ERC-6900: Modular Smart Contract Accounts](https://www.alchemy.com/blog/account-abstraction-erc-6900)
- [EIP-7702 Developer Guide](https://www.alchemy.com/blog/eip-7702-ethereum-pectra-hardfork)
- [ERC-7715: Advanced Permissions](https://docs.metamask.io/smart-accounts-kit/concepts/advanced-permissions/)

### 钱包与基础设施
- [Safe{Wallet} Official](https://safe.global/)
- [Safe Modular Architecture](https://safe.global/blog/safe-modular-smart-account-architecture-explained)
- [ZeroDev Kernel](https://docs.zerodev.app/)
- [ZeroDev: Why 7579 Over 6900](https://docs.zerodev.app/blog/why-7579-over-6900)
- [Biconomy Nexus](https://www.biconomy.io/nexus)
- [Alchemy Account Kit - Modular Account](https://accountkit.alchemy.com/smart-accounts/modular-account/)
- [Alchemy Modular Account V2](https://accountkit.alchemy.com/smart-contracts/modular-account-v2/overview)
- [Pimlico Documentation](https://docs.pimlico.io/)
- [Pimlico Smart Account Comparison](https://docs.pimlico.io/guides/how-to/accounts/comparison)
- [Coinbase Smart Wallet](https://github.com/coinbase/smart-wallet)
- [Particle Network Universal Accounts](https://developers.particle.network/intro/introduction)
- [Particle Network 2025 Review](https://blog.particle.network/2025-review/)
- [Privy Embedded Wallets](https://docs.privy.io/wallets/overview)
- [Privy Global Embedded Wallets](https://privy.io/blog/global-embedded-wallets)
- [Thirdweb Account Abstraction](https://thirdweb.com/account-abstraction)
- [Argent Smart Wallet Features](https://www.argent.xyz/blog/smart-wallet-features)

### Paymaster 与 Gas 代付
- [Pimlico ERC-20 Paymaster (GitHub)](https://github.com/pimlicolabs/erc20-paymaster)
- [Circle Paymaster](https://www.circle.com/paymaster)
- [Particle Omnichain Paymaster](https://blog.particle.network/cross-chain-paymaster-omnichain/)
- [ERC-4337 Paymasters: Better UX, Hidden Risks](https://osec.io/blog/2025-12-02-paymasters-evm/)
- [OpenZeppelin Paymasters](https://docs.openzeppelin.com/community-contracts/paymasters)

### EIP-7702 与 Pectra
- [Pectra Upgrade & EIP-7702 (Circle)](https://www.circle.com/blog/how-the-pectra-upgrade-is-unlocking-gasless-usdc-transactions-with-eip-7702)
- [EIP-7702 and MetaMask](https://www.alchemy.com/blog/eip-7702-metamask-and-wallets)
- [Pectra Upgrade Overview (Consensys)](https://consensys.io/ethereum-pectra-upgrade)
- [MetaMask Smart Accounts Kit](https://metamask.io/developer/delegation-toolkit)
- [MetaMask Roadmap 2025](https://metamask.io/news/metamask-roadmap-2025)

### 技术趋势
- [Passkeys and Smart Wallets](https://www.corbado.com/blog/smart-wallets-passkeys)
- [OpenZeppelin WebAuthn Smart Accounts](https://docs.openzeppelin.com/contracts/5.x/learn/webauthn-smart-accounts)
- [Rhinestone Smart Sessions (GitHub)](https://github.com/erc7579/smartsessions)
- [Reown Smart Sessions](https://docs.reown.com/appkit/next/early-access/smart-session)
- [Open Intents Framework](https://eco.com/support/en/articles/11802670-best-cross-chain-intent-protocols-2026-how-intents-are-replacing-bridges)
- [ERC-7683: Cross-Chain Intents Standard](https://www.archetype.fund/media/erc7683-the-cross-chain-intents-standard)
- [Chain Abstraction Relevance in 2025](https://blog.particle.network/is-chain-abstraction-relevant-in-2025/)

### 市场数据与分析
- [Dune Analytics: ERC-4337 Smart Accounts](https://dune.com/niftytable/account-abstraction)
- [Dune Analytics: Crypto Wallets 2025](https://dune.com/crypto-wallets)
- [The State of Wallets 2025 (Dune Report)](https://bitcoinke.io/wp-content/uploads/2025/05/Crypto-Wallets-2025-Report-by-Dune-Analytics-BitKE.pdf)
- [State of Wallets 2024 (Flashbots)](https://writings.flashbots.net/state-of-wallets-2024)
- [Coinbase Smart Wallet 1M Users](https://www.ainvest.com/news/coinbase-smart-wallet-surpasses-1-million-users-driven-base-app-innovation-2508/)
- [Safe Wallet Revenue 2025](https://www.theblock.co/post/388098/crypto-wallet-safe-reports-fivefold-revenue-jump-2025-not-break-even-profitability)
- [Ethereum Foundation Treasury to Safe](https://www.theblock.co/press-releases/375708/just-in-ethereum-foundation-moves-entire-650m-treasury-to-safe-multisig)
- [AA Market Map (Dynamic)](https://www.dynamic.xyz/blog/account-abstraction-market-map)
- [AA Market Map v2 (Dynamic)](https://www.dynamic.xyz/blog/aa-v2)
- [Cryptocurrency Wallet Adoption Statistics 2026](https://coinlaw.io/cryptocurrency-wallet-adoption-statistics/)
