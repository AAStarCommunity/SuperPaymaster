# 2026 OP 主网 Alpha 部署计划

> 文档状态：草稿
> 创建时间：2026-06-24
> 目标：Sepolia beta 稳定运行 2-3 周后发布 OP 主网 Alpha 版本

---

## 一、现状快照（2026-06-24）

| 项目 | Sepolia（当前 beta） | OP 主网（旧） |
|---|---|---|
| 部署版本 | v5.4.0-beta.1-redeploy（2026-06-16） | v2.x（2026-02-11，4个月前） |
| 缺少的合约 | — | x402Facilitator、PolicyRegistry、TimelockController、MicroPaymentChannel、AgentIdentityRegistry、PaymasterV4 相关，共 11 个字段 |
| 签名方式 | PRIVATE_KEY 明文（Sepolia 测试用） | `.env.optimism` 已配 `DEPLOYER_ACCOUNT=optimism-deployer` ✅ |
| 链上状态 | 两个官方社区 + 用户 SBT + E2E 验证 | 几乎无真实用户状态，可全新部署 |

### 旧 OP 主网缺失字段（对比 Sepolia）

```
aPNTsPaymasterV4, agentIdentityRegistry, agentReputationRegistry,
agentValidationRegistry, microPaymentChannel, pnts, pNTsPaymasterV4,
policyRegistry, registryImpl, spImpl, timelockController, x402Facilitator
```

---

## 二、关键设计决策（已确认）

| 决策项 | 结论 |
|---|---|
| ENV 名 | `op-mainnet`（区别于旧的 `optimism`） |
| 部署模式 | 全新部署 `--fresh-deploy`（旧合约非 UUPS，无法 upgrade） |
| GToken 初始供应量 | 21M 封顶，与测试网一致，不可改 |
| 基础信用档（tier 1/2） | 默认 100 ether（100 aPNTs），部署后可调（`Registry.setCreditTier()`） |
| Anni/Mycelium owner 地址 | OP 主网会更换，确认后更新本文档 |
| Keystore 方式 | Foundry Encrypted Keystore（`cast wallet import`），禁止裸 PRIVATE_KEY |
| prepare-test | 主网**跳过**（deploy-core 已有保护），社区注册走人工脚本 |

---

## 三、Foundry Keystore 准备（人工操作，部署前必做）

```bash
# Deployer 主钱包（AAStar 社区 owner）
cast wallet import optimism-deployer --interactive
# 提示输入：私钥 → 设密码 → 存储到 ~/.foundry/keystores/optimism-deployer

# Mycelium 社区 owner（地址待确认）
cast wallet import optimism-anni --interactive
```

使用时 forge 弹密码框，私钥不落磁盘，不进 env 文件。

---

## 四、ENV 文件配置（`.env.op-mainnet`）

当前 `.env.op-mainnet` 已有：

```bash
DEPLOYER_ACCOUNT=optimism-deployer
DEPLOYER_ADDRESS="0x51Ac694981b6CEa06aA6c51751C227aac5F6b8A3"
ANNI_ACCOUNT=optimism-anni
ANNI_ADDRESS=<待确认>            # Mycelium owner，地址待确认后填入
RPC_URL="https://opt-mainnet.g.alchemy.com/v2/..."
ENTRY_POINT="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
ETH_USD_FEED="0x13e3Ee699D1909E989722E753853AE30b17e08c5"  # 需核实 OP 主网 Chainlink 地址
SIMPLE_ACCOUNT_FACTORY="0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985"
```

**待补充：**
- `ANNI_ADDRESS` — Mycelium OP 主网 owner 地址（会和 Sepolia 不同）
- `OP_MAINNET_RPC_URL` — 用于 deploy-core RPC 变量映射（`op-mainnet` → `OP_MAINNET_RPC_URL`）
- `ETHERSCAN_API_KEY` — OPScan 验证用（兼容 Etherscan API）

---

## 五、deploy-core 适配（需要代码改动）

### 5.1 ENV 路由扩展

deploy-core 当前识别 `mainnet|optimism` 为主网（跳过 prepare-test）。  
需要增加 `op-mainnet` 到主网列表：

```bash
# deploy-core 第 161 行附近，prepare-test 跳过规则
case "$ENV" in
    mainnet|optimism|op-mainnet)   # ← 加 op-mainnet
        echo "ℹ️  Skipping prepare-test on $ENV (mainnet — manual operator onboarding)"
        ;;
esac
```

### 5.2 RPC 变量映射

deploy-core 通过 `${ENV_CLEAN}_RPC_URL` 推导 RPC：
- `op-mainnet` → `OP_MAINNET_RPC_URL`（`-` 替换为 `_`，转大写）
- `.env.op-mainnet` 里必须有 `OP_MAINNET_RPC_URL=...`

### 5.3 Etherscan 验证 URL

`verify-all.sh` 需要增加 `op-mainnet` 分支：
```bash
op-mainnet) VERIFIER_URL="https://api-optimistic.etherscan.io/api" ;;
```

---

## 六、TestAccountPrepare 适配（mainnet 跳过但需兼容）

TestAccountPrepare 目前读 `PRIVATE_KEY_ANNI`（明文 fallback Anvil key）。  
主网不运行 prepare-test，但 prepare-test 脚本本身需要改造：

```solidity
// 当前（不安全用于主网）
uint256 anniPK = vm.envOr("PRIVATE_KEY_ANNI", ANVIL_ANNI_PK);

// 主网兼容方向：改为从 ANNI_ACCOUNT keystore 读取
// （Forge script 目前 --account 只支持一个 signer，多签名需要分步骤广播）
```

> **当前结论**：主网 Anni 相关操作（注册 Mycelium 社区、部署 V4 proxy）通过独立的手工脚本完成，不依赖 prepare-test。

---

## 七、社区注册流程（主网人工操作，替代 prepare-test）

主网不运行 prepare-test，需要一个独立的社区注册脚本（`InitializeOfficialCommunities.s.sol` 或改造 `InitializeTestCommunities.s.sol`）：

### 步骤顺序

```
1. AAStar 社区注册
   forge script ... --account optimism-deployer --broadcast
   - registry.safeMintForRole(ROLE_COMMUNITY, deployer, aaStarData)
   - registry.registerRole(ROLE_PAYMASTER_AOA, deployer, "")
   - xpntsFactory.deployxPNTsToken("AAStar PNTs", "aPNTs", ...)
   - pmFactory.deployPaymaster("v4.2", initData)
   - setTokenPrice(aPNTs, 2_000_000)   // $0.02
   - EntryPoint.depositTo{value: 0.05 ether}(aPNTsProxy)

2. Mycelium 社区注册（deployer 代付 stake，然后 anni 操作）
   forge script ... --account optimism-deployer --broadcast
   - registry.safeMintForRole(ROLE_COMMUNITY, anniAddr, mycData)
   - registry.registerRole(ROLE_PAYMASTER_AOA, anniAddr, "")

   forge script ... --account optimism-anni --broadcast
   - xpntsFactory.deployxPNTsToken("Mycelium PNTs", "PNTs", ...)
   - pmFactory.deployPaymaster("v4.2", initData)
   - setTokenPrice(PNTs, 2_000_000)   // $0.02
   - EntryPoint.depositTo{value: 0.05 ether}(pNTsProxy)

3. 写入 config.op-mainnet.json 并 sync_to_sdk.sh
```

---

## 八、Chainlink Price Feed 核实

| 网络 | ETH/USD Feed 地址 |
|---|---|
| Sepolia | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| OP 主网（当前配置） | `0x13e3Ee699D1909E989722E753853AE30b17e08c5` |

**待核实**：`0x13e3...` 是否是 OP 主网正确的 Chainlink ETH/USD feed。  
参考：https://docs.chain.link/data-feeds/price-feeds/addresses?network=optimism

---

## 九、信用档（Credit Tier）配置

当前 Registry 默认值（部署时写入，可通过 `setCreditTier()` 修改）：

| Tier | 额度 | 对应场景 |
|---|---|---|
| 1 | 100 ether | 普通用户（默认） |
| 2 | 100 ether | 初级用户 |
| 3 | 300 ether | 中级 |
| 4 | 600 ether | 高级 |
| 5 | 1000 ether | VIP |
| 6 | 2000 ether | 超级用户 |

**主网策略**：初期用默认值（tier 1/2 = 100 aPNTs），运营稳定后按实际数据调整。  
调整命令：`cast send <registry> "setCreditTier(uint256,uint256)" 1 200ether --account optimism-deployer`

---

## 十、部署命令序列

### 10.1 Op-sepolia 演习（主网前必做）

```bash
# 演习：全新部署到 op-sepolia，验证流程
source .env.op-sepolia
./deploy-core op-sepolia --fresh-deploy
./prepare-test op-sepolia          # op-sepolia 有 prepare-test
./run_full_regression.sh           # 或手工跑 E2E
```

### 10.2 OP 主网正式部署

```bash
# Step 1: 核实 keystore 已导入（两个账户都需要）
cast wallet list
# 应看到: optimism-deployer, optimism-anni

# Step 2: 部署核心合约（自动跳过 prepare-test，打印社区注册指引）
source .env.op-mainnet
export ENV=op-mainnet
./deploy-core op-mainnet --fresh-deploy
# → 弹出 "Type 'yes' to confirm fresh deployment on op-mainnet"
# → 弹出 keystore 密码框（optimism-deployer）
# → 完成后自动运行 audit-core 验证 + verify-all.sh 验证

# Step 3: AAStar 社区注册（deployer 签名）
forge script contracts/script/v3/InitializeAAStar.s.sol:InitializeAAStar \
  --rpc-url $RPC_URL --account optimism-deployer --broadcast --slow -vv
# → 写入 config.op-mainnet.json: .aPNTs, .aPNTsPaymasterV4

# Step 4a: Mycelium 社区预备（deployer 签名，为 Anni 授权 + 抵押）
forge script contracts/script/v3/InitializeMyceliumPrep.s.sol:InitializeMyceliumPrep \
  --rpc-url $RPC_URL --account optimism-deployer --broadcast --slow -vv

# Step 4b: Mycelium 社区部署（Anni 签名）
forge script contracts/script/v3/InitializeMycelium.s.sol:InitializeMycelium \
  --rpc-url $RPC_URL --account optimism-anni --broadcast --slow -vv
# → 写入 config.op-mainnet.json: .pnts, .pNTsPaymasterV4

# Step 5: 同步地址到 SDK
./sync_to_sdk.sh

# Step 6: 链上版本核实
./version-check-onchain.sh $RPC_URL
```

---

## 十一、主网前**必须完成**项（阻塞项）

> 下列任何一项未关闭，均不得启动 OP 主网部署。
> **开发计划**：S2/S3 在 `fix/pre-mainnet-blockers` 分支下并行 worktree 修复，各自提 PR 合入该分支后，整体再合入 main。

### 11.1 安全审计阻塞项

| # | Issue | 问题描述 | 优先级 | 状态 | 负责分支 |
|---|---|---|---|---|---|
| S1 | #249 | operator 可抢跑 `withdraw` 规避 Tier-1 slash | 🔴 合约安全 | ✅ 已修，PR #312 待 review | `fix/pre-mainnet-blockers` |
| S2 | #255 D-H2 | deploy-core check 失败不阻塞 + config 先写后验 | 🔴 部署事故 | ✅ 已修，PR #312 待 review | `fix/pre-mainnet-blockers` |
| S3 | #255 D-H4 | DeployLive wiring 步骤无完整性断言 | 🔴 部署事故 | ✅ 已修，PR #312 待 review | `fix/pre-mainnet-blockers` |

#### S1 详解 — operator 提款可逃罚款

**问题位置**：`SuperPaymaster.sol:771-782`（`withdraw` 函数）

**问题**：operator 如果知道自己要被 slash（罚没 aPNTs），可以在 slash 执行前抢先调 `withdraw()` 把余额全取走，Tier-1 的罚款就落空了。

**修复方向**：在 `withdraw()` 里加一行检查——
```solidity
require(pendingSlashAmount[operator] == 0, "SP: pending slash exists");
```
或引入 24h 提款延迟队列（类似项目已有的 TimelockController 模式）。需要加 forge 测试覆盖此路径。

#### S2 详解 — 部署脚本出错但假装成功

**问题**：`deploy-core` 目前流程是：
1. 部署合约 → `save_config`（立即写入新地址）→ `run_checks`（验证）
2. `run_checks` 里每个 check 都加了 `|| true`，即使全挂也不退出

**后果**：部署完成但 Check01-08 全部失败，config 里已经是新地址，下次 srcHash 匹配直接跳过重部署——**相当于带着错误的配置上线**。

**修复方向**（`deploy-core`）：
- 删除 `run_checks` 里的所有 `|| true`
- 将 `save_config` 移到 `run_checks` 之后
- 任意一个 check 失败则整体 `exit 1`

#### S3 详解 — 合约连线成功与否无法感知

**问题位置**：`DeployLive.s.sol` 部署完各合约后调用 `setStaking()` / `setMySBT()` / `setSuperPaymaster()` 等 wiring 步骤，**执行后没有任何断言验证连线是否真的成功**。

**后果**：某个 `set*()` 调用悄悄 revert 或 no-op，脚本继续跑完，上链，配置里写着新地址，但合约内部并没有接好——直到用户发起真实交易才会发现。

**修复方向**（`DeployLive.s.sol` 末尾加 `_assertWiring()` 函数）：
```solidity
function _assertWiring() internal view {
    require(registry.GTOKEN_STAKING() == address(staking), "wiring: staking");
    require(registry.MY_SBT() == address(mySBT), "wiring: mySBT");
    require(registry.SUPER_PAYMASTER() == address(sp), "wiring: superPaymaster");
    // ... 其他关键连线
}
```
在 `run()` 末尾调用 `_assertWiring()`。

---

### 11.2 测试与验证阻塞项

| # | 任务 | 详细说明 | 状态 |
|---|---|---|---|
| T1 | credit/debt repay E2E | 场景：operator 欠费（credit 透支）→ `repayDebt()` 还款 → 余额回归正常。主网前须有 1 条 Sepolia 真实 TX hash 证明 | ✅ 完成（2026-06-27，I1 Credit Ceiling 13/13 PASS）|
| T2 | agent 双通道赞助 E2E | 场景：用户无 SBT 但注册为 agent → `isEligibleForSponsorship()` 走 AgentIdentityRegistry 通道 → 跑真实 gasless TX。须有真实 TX 证明 | ✅ 完成（2026-06-27，G2 Agent Sponsorship 10/10 PASS）|
| T3 | Mycelium Sepolia 脚本演练 | 用 Anni 账户在 Sepolia 跑 `InitializeMycelium.s.sol`，写入 config.sepolia.json | ✅ 完成（2026-06-27，pntsPaymasterV4=0xd998..，价格修正 $1→$0.02）|
| T4 | Sepolia 全新部署演习 | `./deploy-core sepolia --fresh-deploy` 完整跑通，验证 S1/S2/S3 修复在真实网络端到端可行 | ⬜ 待做（PR #312 合并后执行）|

---

### 11.3 基础设施阻塞项

| # | 任务 | 详细说明 | 状态 |
|---|---|---|---|
| I1 | PR #306 合并 | op-mainnet 部署脚本已合并 ✅ | ✅ 完成 |
| I2 | OP 主网 Chainlink ETH/USD feed 核实 | `0x13e3Ee699D1909E989722E753853AE30b17e08c5` — 链上验证：`latestRoundData()` 返回 `158,152,000,000`（$1,581.52），timestamp 对应今日，feed 活跃 | ✅ 已核实（2026-06-27）|
| I3 | Foundry keystore 导入 | 部署机器上运行：`cast wallet import optimism-deployer --interactive` + `cast wallet import optimism-anni --interactive`，验证 `cast wallet list` 看到两个账户 | ⬜ 待做（人工操作） |
| I4 | 基础信用档值 | tier 1/2 = 100 ether 已确认，部署后可调 | ✅ 已确认 |

---

## 十二、主网前**建议完成**项（非阻塞，强烈推荐）

> 以下项目不阻塞部署，但会显著降低上线风险或后期维护成本，建议在 beta 稳定期内顺带处理。

### 12.1 代码质量与审计（顺带做）

| # | Issue | 说明 | 工作量 | 建议时机 |
|---|---|---|---|---|
| Q1 | #255 D-H1 | srcHash 覆盖不足：只 hash `contracts/src/*.sol`，不含 lib/foundry.toml/部署脚本，升级依赖后会被误判跳过 | 小 | 修 S2 时顺带 |
| Q2 | #255 D-H3 | DeployAnvil/DeployLive 参数手写易漂移，建议抽共享 `_deployCore()` | 中 | 下次部署脚本改动时 |
| Q3 | #255 D-H5 | config↔链上无自动对账，建议 CI 加每日 diff 报警 | 小 | CI 闲时 |
| Q4 | #256 | version 命名统一 + 事件 indexed — 影响链上索引和 SDK 事件订阅 | 小 | beta 期间 |
| Q5 | #259 | Info 代码卫生（命名/注释/死代码） | 小 | beta 期间随手 |
| Q6 | #257 | 测试 gap 剩余 — 目前缺少 slash/DVT 集成测试 | 中 | beta 期间 |

### 12.2 功能与 UX（顺带做）

| # | Issue/PR | 说明 | 建议时机 |
|---|---|---|---|
| F1 | #299 | Registry struct 补全（website/description/logoURI）— 社区展示信息，影响前端和 SDK | 主网部署后第一次 UUPS upgrade 时加入 |
| F2 | #300 | ERC-7677 paymaster web 服务（MetaMask 智能账户 gasless 买 GToken）— 扩大用户入口 | v5.5 特性 |
| F3 | #286 | x402-facilitator-node 迁出合入 aNode monorepo | v5.4 稳定后 |

### 12.3 依赖维护（建议主网前合并）

| PR | 内容 |
|---|---|
| #302 | bump `actions/checkout` v6→v7（CI 动作） |
| #303 | bump x402-facilitator-node 依赖组 |
| #304 | bump undici `5.25.1→6.27.0`（openzeppelin-contracts-v5.0.2 子模块，安全修复） |
| #305 | bump undici `6.22.0→6.27.0`（openzeppelin-contracts-v5.1.0 子模块，安全修复） |

> undici CVE 相关安全修复（#304/#305）建议合并后跑一次 `forge build` 确认无编译变化。

### 12.4 运营基础设施（主网 Day-0 前准备好）

| # | 任务 | 说明 |
|---|---|---|
| O1 | 价格 keeper 上线 | 主网需定期调用 `updatePrice()`（SuperPaymaster + 两个 V4 proxy），否则触发 AA32 价格过期错误；使用 AAStar SDK `keeper run keep` 脚本配私钥运行 |
| O2 | EntryPoint 余额监控 | 两个 V4 proxy 的 ETH deposit < 0.05 ETH 时告警并自动补充 |
| O3 | 多签治理准备 | 主网 `owner` 建议转移至 Gnosis Safe 多签（deployer 暂时 owner 可接受，但应有转移计划） |
| O4 | 社区扩展流程文档 | 第三方社区 `safeMintForRole(ROLE_COMMUNITY)` 的权限管理机制文档化，避免无序接入 |

---

## 十三、发布后运营事项

1. **价格 keeper**：主网需要定期调用 `updatePrice()` 或配置链下 keeper 自动刷新价格缓存（否则 AA32 到期错误）
2. **EntryPoint 余额监控**：两个 V4 proxy 的 ETH 余额低于阈值时自动告警并补充
3. **信用档调整**：观察 ~2 周真实用量后，按运营数据决定是否上调 tier 1/2 的默认额度
4. **community 社区扩展**：第三方社区自助注册流程（需要 Registry.safeMintForRole 权限管理机制完善）

---

## 附录：补充说明（可追加）

> 本节用于记录后续决策、变更和补充信息。

- **2026-06-24**：初稿创建，基于 Sepolia v5.4.0-beta.1-redeploy 现状分析。
- **2026-06-24**：增加 Section 11/12 — 必须完成项（安全/测试/基础设施）+ 建议完成项（代码质量/功能/依赖/运营）。
- OP 主网 Anni 地址待确认后填入 `ANNI_ADDRESS`。
- `InitializeMyceliumPrep.s.sol` + `InitializeMycelium.s.sol` 已创建（PR #306），待 Sepolia 演练验证。
