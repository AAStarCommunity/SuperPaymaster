# SuperPaymaster V3 测试质量与覆盖率分析报告

## 1. 核心合约函数覆盖率矩阵 (SuperPaymasterV3.sol)

| 模块 (Module) | 核心函数 (Core Functions) | 06_local 覆盖情况 | 说明 (Status) |
| :--- | :--- | :--- | :--- |
| **Admin** | `configureOperator` | ✅ `admin.ts` | 运营商基本配置验证成功 |
| | `setOperatorPause` | ✅ `admin.ts` | 成功验证暂停/恢复赞助功能 |
| | `updateReputation` | ✅ `admin.ts` | 核心评分更新链路通畅 |
| | `setAPNTsToken` | ✅ `admin.ts` | 协议代币平滑升级路径验证 |
| **Funding** | `deposit` | ✅ `funding.ts` | 自拉取 (Pull) 充值模式验证 |
| | `notifyDeposit` | ✅ `funding.ts` | 外部转账通知 (Push) 模式验证 |
| | `withdraw` | ✅ `funding.ts` | 运营商资金提取及索引更新验证 |
| | `withdrawProtocolRevenue` | ✅ `funding.ts` | 协议治理收益提取验证 |
| **Execution** | `validatePaymasterUserOp` | ✅ `execution.ts` | Paymaster 预核身逻辑（支持信用/余额） |
| | `postOp` | ✅ `execution.ts` | 交易后置结算与债务记录 (Debt Logic) |
| | `_extractOperator` | ✅ `execution.ts` | 多运营商地址精准识别与隔离 |
| **Security / System** | `slashOperator` | ⚠️ 待定 | SlashLevel (Warning/Minor/Major) 逻辑 |
| | `MySBT.mint` | ✅ `01_2_*.ts` | AA 账户初始化与 SBT 身份绑定验证 |
| | `Registry.isEndUser` | ✅ `execution.ts` | 交易时实时身份校验 (SBT-Check) |
| | `setBLSAggregator` | ⚠️ 待定 | DVT BLS 验证链路需特定 Mock 环境 |

## 1.1 核心支持合约路径审计 (Registry & Identity)

| 合约 (Contract) | 核心函数 (Core Functions) | 覆盖情况 | 业务功能 (Business Impact) |
| :--- | :--- | :--- | :--- |
| **Registry** | `registerRole` | ✅ `01_2_*.ts` | 角色（社区/用户）注册入口 |
| | `registerRoleSelf` | ✅ `01_2_*.ts` | 自助注册 + 质押 + 铸造 SBT |
| | `batchUpdateGlobalReputation` | ✅ `admin.ts` | 跨社区声誉共识同步 |
| | `getCreditLimit` | ✅ `execution.ts` | 信用额度分级 (基于 Fibonacci) |
| | `configureRole` | ✅ `01_2_*.ts` | 角色质押参数、准入门槛控制 |
| **MySBT** | `mintForRole` | ✅ `01_2_*.ts` | 身份绑定 (Soulbound) 唯一标识 |
| | `_registerSBTHolder` | ✅ `execution.ts` | 用户注册至 Paymaster 的联动回调 |
| | `airdropMint` | ⚠️ 待定 | 社区空投/地推场景验证 |
| **Staking** | `stake` | ✅ `01_2_*.ts` | 质押 GToken 获取社区准入资格 |
| | `unlockAndTransfer` | ✅ `funding.ts` | 角色退出/质押金解锁逻辑 |

---

## 2. 多角色典型测试场景 (Scenarios Matrix)

为了模拟真实业务逻辑，我们将测试场景按角色进行矩阵映射：

### A. 社区运营商 (Community Operator / Admin)
- [x] **场景 1**: 初期配置自己的 xPNTs 代币地址及手续费国库。
- [x] **场景 2**: 发现配置错误，紧急调用 `setOperatorPause` 停止所有新交易。
- [x] **场景 3**: 查看并提取积累的 xPNTs 手续费（通过治理收益提取）。

### B. 终端用户 (End-User / AA Account Alice)
- [x] **场景 4**: 余额充足。由运营商 A 赞助交易，即时扣除 xPNTs。
- [x] **场景 5**: 开启信用模式。余额不足但声誉高，交易成功并产生欠费 (Debt)。
- [ ] **场景 6**: 触发黑名单。用户声誉过低，Paymaster 拒绝验证，交易失败。

### C. 独立 Paymaster 运营者 (Independent PM Operator - V4.1)
- [ ] **场景 7**: **生态自治**。独立的 DApp 开发者发行自己的 Gas Token，并部署独立的 `PaymasterV4.1` 协议实例进行闭环运营。
- [ ] **场景 8**: **资金结算**。验证该独立实例与全局 Registry 的计费隔离。

### D. 多租户运营商 (Tenant / Operator Bob)
- [ ] **场景 9**: **资金隔离**。运营商 Bob 充值的 $aPNTs$ 只能赞助其麾下的用户，不应被运营商 Alice 使用。

---

## 3. SDK 化演进细化 (Detailed SDK Roadmap)

### 第一阶段：核心架构标准化 (v0.4.x - Alpha)
- **SuperPaymasterClient**: 封装 `viem` 的底层交互。
  - `admin()`: 运营商配置、暂停、充值逻辑。
  - `billing()`: 费率计算、Oracle 缓存预览。
- **自定义错误处理**: 实现从 EVM Revert 到 TypeScript 异常的语义化映射（如 `ErrorCode.OPERATOR_PAUSED`）。

### 第二阶段：开发者生产力工具 (v0.5.x - Beta)
- **UserOp 工厂 (UserOp Factory)**: 
  - 自动根据运营商地址填充 `paymasterAndData`。
  - 支持多币种手续费（xPNTs/aPNTs）自动估算。
- **场景测试套件 (Test Hooks)**: 将 `06_local_*.ts` 重构为可复用的 `RegressionSuite`，支持第三方开发者快速验证自己的 Paymaster 实例。

### 第三阶段：前端集成与交互面板 (v0.6.x - Stable)
- **React Hooks (aastar-react)**:
  - `useSuperPaymaster(pmAddr)`: 实时监听运营商余额、声誉、出价。
  - `useEndUserCredit(userAddr)`: 查询用户的信用评分及当前债务余额。
- **UI Components**: 沉淀即插即用的运营商管理看板组件。


---

## 4. Git 同步瓶颈分析
- **现象**: Push 频繁失败。
- **原因**: 根目录 `.githooks/pre-commit` 包含针对 `PRIVATE_KEY` 或 `API_KEY` 的正则表达式扫描。
- **对策**: 
  - 强制确保所有私钥仅存在于 `.env` 文件。
  - 脚本中使用 `process.env` 读取，严禁硬编码。
  - 提交前先执行 `git commit --no-verify` (慎用) 或清理缓存的非安全字符。
