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

## 十一、Beta 阶段必须完成的前置条件

在启动主网部署前，以下 Sepolia beta 任务必须关闭：

| # | 任务 | 状态 | 关联 |
|---|---|---|---|
| B1 | Registry struct 补全（website/description/logoURI） | ⬜ 待做 | Issue #299 P1+P3 瘦身后 |
| B2 | `version()` GA blocker 修复 | ⬜ 待做 | E2E 报告 |
| B3 | credit/debt repay E2E 覆盖 | ⬜ 待做 | E2E owed 项 |
| B4 | agent 双通道赞助 E2E | ⬜ 待做 | E2E owed 项 |
| B5 | Mycelium V4 proxy 部署（Sepolia） | ⬜ 待做 | 需 PRIVATE_KEY_ANNI |
| B6 | 基础信用档值确认 | ✅ 确认 | tier 1/2 = 100，可运营后调 |
| B7 | deploy-core 增加 op-mainnet 路由 | ⬜ 待做 | Section 5 |
| B8 | InitializeOfficialCommunities 脚本 | ⬜ 待做 | Section 7 |
| B9 | op-sepolia 全新部署演习 | ⬜ 待做 | Section 10.1 |
| B10 | OP 主网 Chainlink feed 地址核实 | ⬜ 待做 | Section 8 |

---

## 十二、发布后运营事项

1. **价格 keeper**：主网需要定期调用 `updatePrice()` 或配置链下 keeper 自动刷新价格缓存（否则 AA32 到期错误）
2. **EntryPoint 余额监控**：两个 V4 proxy 的 ETH 余额低于阈值时自动告警并补充
3. **信用档调整**：观察 ~2 周真实用量后，按运营数据决定是否上调 tier 1/2 的默认额度
4. **community 社区扩展**：第三方社区自助注册流程（需要 Registry.safeMintForRole 权限管理机制完善）

---

## 附录：补充说明（可追加）

> 本节用于记录后续决策、变更和补充信息。

- **2026-06-24**：初稿创建，基于 Sepolia v5.4.0-beta.1-redeploy 现状分析。
- OP 主网 Anni 地址待确认后填入 `ANNI_ADDRESS`。
- `InitializeOfficialCommunities.s.sol` 待创建（参考 `TestAccountPrepare.s.sol` Phase 2.0.5 + Phase 2.2 逻辑，去掉 Anvil fallback，全部走 keystore）。
