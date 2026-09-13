# D5.2 交付：部署脚本迁移到 SuperPaymaster 5.5.0 + xPNTs v2

分支 `feat/aoa-balance-mode-5.5.0`，基线 `32d5b121`。只改 `contracts/script/`、`deploy-core` / `prepare-test` / `audit-core`、`deployments/config.anvil.json`、README 一段；**`contracts/src/` 零改动**。
全部运行只在本地：全新 anvil（127.0.0.1:28545）和 Sepolia fork（127.0.0.1:28546，`anvil --fork-url https://ethereum-sepolia-rpc.publicnode.com`，fork 块 11692133）。没有向任何公网广播，只用 anvil 默认私钥和 fork 上的 impersonate。

## 1. 设计要点

| 问题 | 结论 |
|---|---|
| 3.x 工厂还要不要 | **保留**。它部署协议 aPNTs（SP 的 `APNTS_TOKEN`，operator 的**存款资产**，SP 的 `deposit` 用 `transferFrom` 拉它）；`GTokenAuthorization` 的构造参数里绑死了它；`X402Facilitator` 的白名单也读它。v2 代币的 `_spendV2` 对 SP 一律 `SPCannotTransfer`，所以 aPNTs 不能换成 v2 代币，否则 `deposit` 失效。 |
| SP 的工厂指针 | `SP.setXPNTsFactory(xPNTsFactoryV2)`（runbook 第 6 步）。3.x 工厂仍然 `setSuperPaymasterAddress(SP)`，Check08 继续检查这两条绑定。 |
| operator 代币 | 一律由 `xPNTsFactoryV2` 发行的 v2 代币。AAStar（deployer）不再用 aPNTs 当 operator 代币，改为自己的 v2 代币 `aXPNTs`（配置键 `aastarXPNTsV2`）；Anni 的 `pnts` 改为 v2 代币。 |
| 共享实现 | 新文件 `contracts/script/v3/V55Bootstrap.sol`：`_ensureV55Stack`（部署或续跑，逐个组件复用/重建）、`_verifyV55Stack`、`_wireSPFactory`、`_issueV2Token`/`_verifyV2Token`、`_configureOperatorV2`/`_verifyOperatorV2`、`_verifyPriceFresh`、`_pmdV55`、`_artifactMatch`。每一步都读回并 `require`。 |
| 模板 codehash 与 artifact 比对 | 不能用"同参数再部署一个参考实例比 codehash"：v2 模板带 `address(this)` 类 immutable（EIP-712 域缓存），两个正确实例的 codehash 本来就不同（第一次实现就因此失败）。改为按 artifact 的 `immutableReferences` 把 immutable 区间置零后逐字节比对 runtime code，构造参数另由 immutable getter 读回。 |
| 新配置键 | `aoaProtocolRegistry`、`globalTierSource`、`xPNTsTokenV2Ext`、`xPNTsTokenV2Impl`、`xPNTsFactoryV2`、`superPaymasterLens`、`aastarXPNTsV2`；DeployAnvil 另写 `spImpl`、`registryImpl`。**没有删除任何旧键**（新旧 `config.anvil.json` 键集合 diff 只有新增）。 |

## 2. 逐个脚本

| 脚本 | 改了什么 |
|---|---|
| `v3/V55Bootstrap.sol`（新） | 见上。部署顺序与 `contracts/test/helpers/V2TokenDeployer.sol` 一致：GlobalTierSource → AOAProtocolRegistry（bootstrap：SP 代理地址 + tier source codehash）→ seal → ext → 模板 → factoryV2(SP, registry, 模板, tier source) → Lens。已 seal 但缺批准时拒绝继续（需要 48 h 的 proposeApproval，不假装成功）。 |
| `v3/DeployAnvil.s.sol` | SP 代理之后部署 v2 栈；`setXPNTsFactory(factoryV2)`；deployer 发 `aXPNTs` 并 `configureOperator`；Anni 的 dPNTs 改由 factoryV2 发行，mint 走扩展；末尾读回第 4/6/7a/7c 步 + `version()=="SuperPaymaster-5.5.0"`；写入新键和 `spImpl`/`registryImpl`（后两者让 audit-core 的 ERC-1967 与 ABI 选择器检查终于有对照值）。 |
| `v3/DeployLive.s.sol` | 同样的 v2 栈（Step 3b）；`_assertWiring` 改为要求 `SP.xpntsFactory == factoryV2`；Mycelium 的 PNTs 改为 v2；`_settleTokenGovernance` 把 factoryV2、AOA registry 也交给 `GOVERNANCE_OWNER`，并用同一个 `GovernanceOwnerGate` 把关；写新键。 |
| `v3/TestAccountPrepare.s.sol` | 读 SP 版本：5.5.0 时 operator 代币工厂 = `config.xPNTsFactoryV2`（并要求等于 `SP.xpntsFactory()`），deployer 用 `aastarXPNTsV2`，Anni 的 `pnts` 为 v2；v2 代币跳过 X402Facilitator 接线（v2 的 spender 需要 codehash 白名单 + 48 h，`addAutoApprovedSpender` 不存在，旧逻辑会 revert）；新增 Phase 2.4b 读回（两个 operator 都在 v2 代币上、价格缓存新鲜）。5.5.0 之前的 SP 保持原路径。 |
| `v3/InitializeAAStar.s.sol` | 5.5.0 时 operator 代币改为 factoryV2 发行的 `aXPNTs`（写 `aastarXPNTsV2`），aPNTs 仍是存款资产；configureOperator 之后读回。 |
| `v3/InitializeTestCommunities.s.sol` | 重写。原文件**本来就编不过**（`CommunityRoleData` 已没有 website/description/logoURI，`configureOperator` 已没有第三个参数）。现在幂等、两社区都用 v2 代币、读回。 |
| `v3/DeployRepCreditSepolia.s.sol` | 部署 v2 栈、operator 用 v2 代币 `rcXPNT`（rcAPNT 仍是存款资产）、读回、写新键。顺带修了两处**早已存在的编译/断言错误**：`blsAggregator.REGISTRY()` 现在返回 `IRegistry`（需要 `address(...)`），版本断言 `BLSAggregator-4.11.0` 已过时（当前 4.12.0）。注：5.5.0 下信用是按代币、按用户开通（`creditPolicy` 初始 OFF，AUTO 要排队 48 h），脚本只部署不开通，实验步骤另做。 |
| `v3/L4GaslessTest.s.sol` | 重写。原文件指向 OP 主网、读一个已不存在的 `.contracts.*` 配置形状、用旧的 pmd（没有 token/flags）、并把所有失败吞进 try/catch。现在：读 `config.<ENV>.json`，建 AA 账户、Anni 代注 ENDUSER（SBT）、铸 v2 代币、`updatePrice`、用新 pmd 构造并签名、先调 Lens `dryRunValidation`、`handleOps`、读回；`verify()` 在不广播的情况下从链上状态复核。T3（经 SP 代付的 SBT mint）删除：没有 SBT 的账户不满足赞助资格，这笔 op 永远过不了验证。 |
| `v3/UpgradeToV5_5_0.s.sol`（新） | 见 §4。 |
| `deployment/08b_WireUpToken.s.sol` | 按代币类型分支：v2 代币走 SP 状态机（`proposeSP` → 48 h → `activateSP`，工厂发行的已有 genesis SP 则直接确认）；3.x 代币只剩 aPNTs 这一种（存款资产），保留 `setSuperPaymasterAddress`，去掉为 `burnFromWithOpHash` 设的 auto-approve。读回。 |
| `deployment/11_ConfigureOperator.s.sol`、`11_1_ConfigureBreadOperator.s.sol` | 两参数 `configureOperator(token, treasury)`（原三参数版本编不过）；预检代币是 v2 且确由 SP 当前工厂发给该 operator；读回。 |
| `checks/Check08_Wiring.s.sol` | SP 为 5.5.0 时：`SP.xpntsFactory == config.xPNTsFactoryV2`、factoryV2 → SP / Registry、AOA registry 已 seal 且批准了 SP 与默认 tier source、模板 `BALANCE_MODE_VERSION==1`；3.x 工厂的两条绑定照旧检查。 |
| `checks/Check09_TestAccounts.s.sol` | SP 为 5.5.0 时：Anni 的 operator 代币是 v2、确由 SP 当前工厂发行、operator 未暂停且有存款、价格缓存新鲜。 |
| 其余 checks（01/02/03/04/07/10/11、VerifyV3_1_1） | 逐个检查过，没有调用已删除的接口，未改动；在 5.5.0 部署上全部通过。 |
| `contracts/script/archive/*` | 已归档，未改。 |

### 2.1 顺带修的 shell 工具问题（最小改动）

| 文件 | 问题 | 修复 |
|---|---|---|
| `deploy-core` / `prepare-test` / `audit-core` | anvil 的 RPC 硬编码 `127.0.0.1:8545`，无法指向别的端口 | 支持 `ANVIL_RPC_URL`（缺省仍是 8545） |
| `audit-core` | `run_forge_check` 最后一行 `[ "$ENV" != "anvil" ] && sleep 2` 在 anvil 上返回 1，`set -e` 让整个审计在**第一个检查之后就退出**——也就是说 anvil 上的 audit-core 此前从未跑完过 | 改成 `if … fi; return 0` |
| `audit-core` | `SP.entryPoint` 期望写死规范地址前缀 `0x00000000717`；DeployAnvil 部署的是自己的 EntryPoint | anvil 上改为读 `config.entryPoint` |
| `audit-core` | ABI 选择器检查用 `grep` 在字节码里找 4 字节选择器；前导 `00` 的选择器（`seedCreditPopulation` = `0x00166507`）被 solc 用更短的 PUSH 编码，于是被误报为缺失 | 比较前去掉整字节的前导零 |

## 3. 验收 1：全新 anvil 上 `./deploy-core anvil --force`

```
anvil --port 28545 --accounts 10 --balance 10000 --gas-limit 30000000      # 未加 --disable-code-size-limit
ANVIL_RPC_URL=http://127.0.0.1:28545 ./deploy-core anvil --force           # exit 0
ANVIL_RPC_URL=http://127.0.0.1:28545 ./prepare-test anvil                  # exit 0（第二次，幂等）
```

> 下面是第一轮（commit `0fe77567`）的输出，当时 5.5.0 合约还是 registry-size 字节码。AUD-4 修复之后的重跑结果见 §8。

deploy-core 输出尾部（节选）：

```
    [v55] template code == artifact: out/xPNTsTokenV2.sol/xPNTsTokenV2.registry-size.json
    [v55] step-4 read-back OK (sealed registry, approvals, template codehash, factory->SP)
    SP impl artifact: registry-size (runs=200)
  Check: Check04_Registry / Check01_GToken / Check02_GTokenStaking / Check03_MySBT /
         Check07_SuperPaymaster / Check08_Wiring / Check10_V54 / Check11_AggregatorPointers / VerifyV3_1_1
    SP 5.5.0 -> xPNTsFactoryV2: 0x7a2088a1bFc9d81c55368AE168C2C02570cB814F
  ✓ SuperPaymaster: all local ABI selectors present on-chain
  ✓ Registry: all local ABI selectors present on-chain
  ✓ SP.version  ← "SuperPaymaster-5.5.0"
  ✓ SuperPaymaster proxy → 0x9a9f…63ae (matches config)
✅ All audit dimensions passed!
━━━ Phase 2.5) Prepare Test Accounts
  [Phase 2.2] PNTs is xPNTs v2: X402Facilitator wiring skipped (needs spender allowlist + 48h)
  [Phase 2.4b] 5.5.0 read-back OK: both operators on v2 tokens, price cache fresh
  === Phase 2 Verification Success ===      (Check09)
✅ deploy-core finished for env=anvil
```

部署出的关键地址（`deployments/config.anvil.json`，已提交）：SP `0x68B1…1aed`（impl `0x9A9f…63AE`），AOAProtocolRegistry `0xc6e7…4e7d`，GlobalTierSource `0x3Aa5…443c`，xPNTsTokenV2Ext `0xa852…338f`，模板 `0x4A67…5319`，xPNTsFactoryV2 `0x7a20…814F`，Lens `0x0963…ceBef`，AAStar v2 `0xDC17…20F4`，Anni v2（`pnts`）`0x2C47…0700`。

其他脚本的冒烟（同一条链）：`InitializeTestCommunities`（复用两枚 v2 代币，读回通过）、`08b`（v2 分支："already bound"；3.x 分支：aPNTs 绑定读回）、`11`、`11_1` 全部 exit 0；**反例**：`11` 传入 3.x aPNTs → `11: token is not an xPNTs v2 token`，正确拒绝。
DeployLive 另在 Sepolia fork 上做了纯模拟（不广播，anvil 测试私钥 + `TESTNET_EOA_OWNER_ACK=true`）：v2 栈、Mycelium v2 PNTs、operator 配置与全部读回通过。

## 4. 验收 2：真实的余额模式 gasless UserOperation

```
ENV=anvil forge script contracts/script/v3/L4GaslessTest.s.sol:L4GaslessTest \
  --rpc-url http://127.0.0.1:28545 --private-key <anvil #0> --broadcast --slow --gas-estimate-multiplier 400
ENV=anvil forge script contracts/script/v3/L4GaslessTest.s.sol:L4GaslessTest --sig "verify()" --rpc-url http://127.0.0.1:28545
```

- op：SimpleAccount `0x6503…ef88`（owner = anvil #3），callData = `execute(Anni, 0, "")`（不碰 xPNTs，余额变化只来自结算），pmd = `[SP][300k][300k][Anni][rate 1e18][pnts][0x00]`。Lens `dryRunValidation` 预检 ok。
- `handleOps` tx `0xcbb18379…7fe2` status 1；`UserOperationEvent`（opHash `0xb3cccf5c…8452`）success = 1，actualGasUsed = 490,496。
- `verify()` 从链上读回（相对记录的升级前快照）：

| 量 | 值 |
|---|---|
| 用户 xPNTs 烧毁 | 78.363212511245200000 |
| `lockedOf(user)` | 0 |
| operator `aPNTsBalance` 减少 | 78.363212511245200000 |
| `protocolRevenue` 增加 | 78.363212511245200000（与上一行严格相等） |
| `usedOpHashes[opHash]` / SP in-flight 记录 | true / 已清除 |

模拟里的烧毁量是 70.94，链上是 78.36：charge 按 EntryPoint 实际收取的 gas 价（上链时的 base fee）计价，与模拟块不同，所以 `verify()` 复核的是不变量，不是逐位等于模拟值。

**踩到的坑**：forge 按模拟用掉的 gas（约 0.5M）给 `handleOps` 定 gas limit，而 EntryPoint v0.7 的 `innerHandleOp` 要求 `gasleft ≥ callGasLimit + paymasterPostOpGasLimit + overhead`，于是模拟通过、链上 AA95 失败（第一次运行 tx `0xeeebcc19…` status 0）。脚本头注释已写明必须带 `--gas-estimate-multiplier 400`；真实 bundler 按 op 的各项 limit 定 gas，不受影响。

## 5. 验收 3：`UpgradeToV5_5_0.s.sol` 在 Sepolia fork 上演练

入口：`inventory(address[])`、`inventoryDebts(address[],address[])`（第 0 步）；`executePendingAPNTs(address[] ops)` / `cancelPendingAPNTs()`（第 1 步，**需要作者决定**：不设 `V55_APNTS_DECISION=execute|cancel` 就拒绝执行，5.4.2 确有这两个函数；execute 分支是完整的清空→切换→重存迁移，见 §9）；`clearPendingDebts(...)`（第 2 步，D-21 核销，仅 5.4.2）；`pauseOperators(address[])`（第 3 步）；`run()`（第 4 → 5 → 5b → 6 步）；`ensureStake()`（单独执行 5b）；`issueCommunityToken(...)`（7a，社区广播）；`configureOperatorV2(token, treasury)`（7c-1，operator 广播，先 `updatePrice` 并读回）；`unpauseOperator(op)`（7c-2，SP owner 广播）。
脚本**不 import `Registry.sol`**，所以新 impl 是 profile.default（runs=500）的产物，第 5 步要求 `_artifactMatch == default`（见 §7 第 1 条）。

```
anvil --fork-url https://ethereum-sepolia-rpc.publicnode.com --port 28546
cast rpc anvil_impersonateAccount 0xb5600060e6de5E11D3636731964218E53caadf0E   # SP owner（EOA，fork 上保留真实余额 2.57 ETH）
cast rpc anvil_impersonateAccount 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9   # Anni
ENV=sepolia V55_OUT_CONFIG=cache/d5-rehearsal/config.sepolia-fork.json \
V55_OPERATORS=<owner>,<anni> V55_SAMPLE_USERS=<anni>,<owner>,0x92EA…92e8 V55_SAMPLE_OPERATOR=<anni> \
forge script …UpgradeToV5_5_0 [--sig …] --rpc-url http://127.0.0.1:28546 --unlocked --sender <…> --broadcast
```

| 顺序 | 入口 | 结果 |
|---|---|---|
| 1 | `inventory` | 5.4.2，impl `0xe25f…2C27`；`pendingAPNTsToken = 0xBb46…9883`（ETA 1789099908）；价格缓存 1788255708（过期）；EP deposit 0.0935 ETH，stake 0.1 ETH / 86400 s；两个 operator（owner、Anni）都已配置、未暂停、代币非 v2 |
| 2 | `cancelPendingAPNTs`（未设决定变量） | **拒绝**：`V55: AUTHOR DECISION REQUIRED (V55_APNTS_DECISION=cancel)`（反例） |
| 3 | `run`（严格模式） | **拒绝**：`V55 precondition (runbook 1): pendingAPNTsToken != 0`（反例） |
| 4 | `pauseOperators([owner, anni])` | 两个都 `isPaused == true` |
| 5 | `run`，`V55_REHEARSAL_SKIP_PRECONDITIONS=true`（只为跳过未做的第 1 步，日志里醒目标出） | 见下 |
| 6 | `run` 再跑一次 | 全部 reuse，impl 跳过，stake 跳过，`No transactions to broadcast`；此次读回针对的是 fork 上真实的链上状态 |
| 7 | `issueCommunityToken("Mycelium PNTs","PNTs",…)`（Anni） | v2 代币 `0x493C…F76e`；codehash 等于模板、默认 tier source、genesis SP、creditPolicy OFF；operator 仍暂停 |
| 8 | `configureOperatorV2(0x493C…, Anni)`（Anni） | 先 `updatePrice` → 读回 `updatedAt` 新鲜 → configure → 读回 |
| 9 | `unpauseOperator(Anni)`（owner） | 价格新鲜、operator 在 v2 代币上 → 取消暂停，读回 `isPaused == false` |

第 5 步的输出（节选）：

```
  [v55] new   GlobalTierSource 0x0a33…DAd9 / AOAProtocolRegistry 0x3e3f…d680 / xPNTsTokenV2Ext 0x7E2f…7eDd
  [v55] new   xPNTsTokenV2 impl 0x39d9…72c5 / xPNTsFactoryV2 0x769F…4C4D / SuperPaymasterLens 0x42B5…2d2A
  [v55] template code == artifact: out/xPNTsTokenV2.sol/xPNTsTokenV2.json
  [v55] step-4 read-back OK (sealed registry, approvals, template codehash, factory->SP)
  new impl: 0x40902201B582eDEd5c4AF1918fdD0db14853a26d   runtime bytes: 22915
  sample ok 0xEcAA…33c9 true / 0xb560…df0E true / 0x92EA…92e8 false
  step-5 read-back OK: 5.5.0, immutables, BLS legs, named state, EP stake; raw slots: 96
  before: staked / stake / unstakeDelay: true 100000000000000000 86400, withdrawTime 0
  addStake shortfall (wei) / delay: 900000000000000000 86400
  step-5b read-back OK: stake (wei) / delay: 1000000000000000000 86400
  === Steps 4-5b-6 complete; SP version: SuperPaymaster-5.5.0 ===
```

第 5 步读回的内容：版本；ERC-1967 impl 槽；新 impl 的三个 immutable（在 swap 之前）和代理读出的三个 immutable（在 swap 之后）都等于 5.4.2 的实时值（REGISTRY `0xf5Bf…8E71`、ETH/USD feed `0x694A…5306`、EntryPoint `0x0000…a032`，并与 config 交叉核对）；BLS 三腿（SP / Registry / DVTValidator）不变；owner、APNTS_TOKEN、xpntsFactory、treasury、fee、aPNTs 价格、staleness、totalTrackedBalance、protocolRevenue、pendingAPNTsToken 不变；EntryPoint deposit/stake 不变；代理的**原始存储槽 0–95 逐字节不变**（布局 0–37 + `__gap[27]` 到 64，多扫 31 个）；`sbtHolders` / `userOpState` 抽样与 swap 前的读数相同；runtime ≤ 24,576；impl 代码 = profile.default artifact。
第 5b 步（按协调方追加的 DSR 要求）：目标 stake 参数化（`V55_MIN_STAKE_WEI`，缺省 1 ether；`V55_MIN_UNSTAKE_DELAY` 缺省 86400），差额 0.9 ETH 由 SP owner 的真实余额支付，读回 `staked == true`、stake = 1 ETH、delay = 86400、`withdrawTime == 0`、gas deposit 未动。

之后用 cast 独立读回（fork）：`version() = "SuperPaymaster-5.5.0"`；impl 槽 = `0x4090…a26d`；`xpntsFactory = factoryV2 = 0x769F…4C4D`；`factoryV2.SUPERPAYMASTER = SP`；`AOA.sealed_ = true`、`isApprovedSP(SP) = true`、`isApprovedImpl(2, tierSource) = true`；`lens.EXPECTED_SP_VERSION = keccak("SuperPaymaster-5.5.0")`；`getDepositInfo(SP) = (0.09347 ETH, true, 1 ETH, 86400, 0)`；Anni operator = (844.54 aPNTs, configured, 未暂停, `0x493C…F76e`)；`pendingAPNTsToken` 仍是 `0xBb46…9883`（第 1 步未做，按规范它跨升级保留且仍可执行）。

**未做的（按要求）**：第 1 步 execute/cancel 的决定、第 2 步 pendingDebts 的逐条对账（需要 D5.3 的归档日志扫描）；owner 自己那个 operator 的 7a/7c；fork 上的余额模式 op 与 AUTO 信用 op（D5.3 的 7c 验收）。

## 6. 验收 4：build / test

- `forge build`：`No files changed, compilation skipped`（全树已编译，含全部迁移脚本；另用 `forge build <22 个脚本>` 单独编译通过）。
- `forge test`（Cancun）：**123 个套件，1564 passed / 0 failed / 49 skipped**（与 D5 基线 1564/0/49 一致）。
- `forge test --evm-version prague`（单独的 out/cache 目录，避免覆盖脚本用的 Cancun 产物）：**123 个套件，1473 passed / 0 failed / 21 skipped**（与基线 1473/0/21 一致）。
- `git diff --stat -- contracts/src` 为空。

## 7. 遗留问题（需要决定或另开工作项）

1. **（已全部解决：5.5.0 范围见 §8，整套部署见 §8.1 T-4；以下为原始发现）deploy-core 实际部署的是 runs=200 的字节码**。`foundry.toml` 对 `Registry.sol` 的 `compilation_restrictions` 会让 import 了 `Registry.sol` 的源文件连同整个依赖闭包都用 `registry-size`（runs=200）profile 编译。DeployAnvil / DeployLive 都 import 了 Registry，于是它们 `new` 出来的 SP、v2 模板等都是 `*.registry-size.json` 那一份（实测 SP 22,756 B，而 profile.default 是 22,915 B；xPNTsTokenV2 19,435 B vs 19,851 B）。这与 CLAUDE.md 里"deploy-core 编译的就是 [profile.default]、这就是上线的字节码"的说法不符，也意味着 D2 的体积/ABI 字节码证据测的不是 deploy-core 部署的那份。`UpgradeToV5_5_0` 刻意不 import Registry，并断言新 impl 等于 default artifact。是否让 DeployLive 也改成这样，需要决定。
2. **deploy-core 的 ABI 同步会改写已提交的 `abis/*.json`**：它用 `jq '.abi'` 把 `{abi, bytecode}` 格式的 bundle 覆盖成纯数组，并且用 `find | head -1` 选 artifact（D2 已在 `extract_v3_abis.sh` 修过同类问题）。而 audit-core 的选择器检查恰恰只认纯数组——提交的 bundle 格式会让它"无法解析、跳过"。本次运行后已 `git checkout -- abis/` 还原，未提交这些改动。两处要统一，另开项。
3. `L4GaslessTest` 必须带 `--gas-estimate-multiplier 400`（§4）。
4. v2 代币上的 X402Facilitator：TestAccountPrepare 已跳过（原逻辑会 revert）。要在 v2 代币上启用 x402，需要把 facilitator 的实现 codehash 加入 AOA registry 的 KIND_SPENDER（registry 已 seal，所以要走 48 h 的 propose/execute），再由社区 `proposeSpender` + 48 h `activateSpender`。
5. AOA registry 与 factoryV2 的 owner：DeployLive 在设了 `GOVERNANCE_OWNER` 时移交并过闸；`UpgradeToV5_5_0` 在 Sepolia 上 owner 是 EOA，只打印提醒，没有移交。
6. RepCredit 实验在 5.5.0 下的信用开通流程（按代币的 AUTO 策略 + 48 h + 用户 `requestCredit`）不在本次范围，`DeployRepCreditSepolia` 只做部署与接线。
7. 下游（repo:sdk、repo:dvt、YAAA）：新的 paymasterAndData、Lens、v2 代币 ABI，按约定在 D5/D7 完成后开 issue。
8. 新 aPNTs `0xBb46…9883` 的 `communityOwner` 就是 SP owner EOA `0xb560…df0E`（fork 上读回）。xPNTs 3.5.0 的 `mint` 没有上限检查，所以执行分支之后，协议存款资产的增发权在一把热钥匙上。见 §9。

## 8. AUD-4 / R10-M5：部署出的字节码 = 审计/测量过的字节码（profile.default）

**决定**（SP 技术设计）：5.5.0 范围内的合约——SuperPaymaster impl、AOAProtocolRegistry、GlobalTierSource、xPNTsTokenV2Ext、xPNTsTokenV2（模板）、xPNTsFactoryV2、SuperPaymasterLens——一律按**显式 artifact 路径**部署 profile.default 产物，部署后逐个断言运行时代码等于 default artifact（immutable 区间屏蔽），不等就直接失败。`foundry.toml`、`contracts/src` 不改。

实现：
- `V55Bootstrap._deployDefault(name, args)` = `vm.deployCode("out/<name>.sol/<name>.json", args)` + `_requireDefaultArtifact`（`_codeEqArtifact` 与 default 路径比对，只接受 default）。v2 栈的 6 个组件、DeployAnvil / DeployLive / DeployRepCreditSepolia / UpgradeToV5_5_0 的 SP impl 都改走这条路径。
- `_verifyV55Stack` 对 6 个组件逐个 `_requireDefaultArtifact`，所以续跑时**复用**的组件也会被检查。DeployAnvil / DeployLive 另外要求代理的 ERC-1967 impl == 刚部署的 impl，并且它是 default 产物。
- `_codeEqArtifact`：没有 immutable 的合约（AOAProtocolRegistry）的 `immutableReferences` 为空，`parseJsonKeys` 会报错，改为"没有需要屏蔽的区间"。
- `deploy-core`：在 `forge script` 之前先 `forge build`。`forge script` 只编译脚本自己的依赖闭包（而且因为脚本 import 了 Registry，用的是 registry-size profile），按路径部署的 default artifact 必须先保证是最新的。

**重跑验收 1**（全新 anvil 28545，`ANVIL_RPC_URL=… ./deploy-core anvil --force` exit 0，随后 `./prepare-test anvil` exit 0）：

```
    [v55] artifact default (runs=500): SuperPaymaster 0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE 22915
    [v55] artifact default (runs=500): GlobalTierSource 0x3Aa5…443c 542
    [v55] artifact default (runs=500): AOAProtocolRegistry 0xc6e7…4e7d 2554
    [v55] artifact default (runs=500): xPNTsTokenV2Ext 0xa852…338f 21922
    [v55] artifact default (runs=500): xPNTsTokenV2 0x4A67…5319 19851
    [v55] artifact default (runs=500): xPNTsFactoryV2 0x7a20…814F 6899
    [v55] artifact default (runs=500): SuperPaymasterLens 0x0963…ceBef 4731
    [v55] step-4 read-back OK …
  Check04/01/02/03/07/08/10/11/VerifyV3_1_1 → Script ran successfully
  ✓ SuperPaymaster / Registry: all local ABI selectors present on-chain
  ✓ SuperPaymaster proxy → 0x9a9f…63ae (matches config)
✅ All audit dimensions passed!   [Phase 2.4b] 5.5.0 read-back OK   === Phase 2 Verification Success ===
```

`cast codesize <spImpl>` = **22,915**，等于 profile.default 的 SuperPaymaster（registry-size 是 22,756）。

**重跑验收 2**（同一条链，L4GaslessTest，`--gas-estimate-multiplier 400`）：`handleOps` tx `0x04901d52…8752` status 1，`UserOperationEvent` success = 1，actualGasUsed = 490,024；`verify()` 从链上读回：用户 xPNTs 烧毁 78.327792839955120000，`lockedOf` = 0，operator 余额减少 78.327792839955120000 = `protocolRevenue` 增加 78.327792839955120000。

### 8.1 T-4：整套部署都从 default artifact 部署（DSR P1 "tested == deployed"）

**仍从 registry-size 部署的合约：没有了（none remaining）。** 上一版这里列出的 10 多个旧合约（GTokenStaking、MySBT、3.x xPNTsFactory、ReputationSystem、DVTValidator、BLSAggregator、PaymasterFactory、V4 Paymaster、X402Facilitator、TimelockController、GTokenAuthorization、MicroPaymentChannel、PolicyRegistry……），现在和 5.5.0 的 7 个合约一样，都按显式 default artifact 路径部署并断言。

实现（`foundry.toml`、`contracts/src` 不改）：
- 新文件 `contracts/script/v3/DefaultArtifacts.sol`：
  - `_deployDefault(name, args)` = `vm.deployCode(<default artifact>, args)`，部署后立刻 `_requireDefaultArtifact`（immutable 区间屏蔽后逐字节比对）。
  - `_requireDefaultProxy(proxy, impl)`：代理对 ERC1967Proxy 的 default artifact，实现（从 ERC-1967 槽读出）对它自己的 artifact。
  - `_requireDefaultClone(clone, impl)`：EIP-1167 克隆（工厂发的代币、V4 paymaster）解出内嵌实现后再比对。
  - V54Bootstrap / V55Bootstrap 都继承它，所以 X402Facilitator / TimelockController / PolicyRegistry 和 v2 栈走同一条路径。
- **artifact 的解析不看文件名**。forge 的命名会随编译情况变化：只有一个 profile 编译过时叫 `X.json`，两个都编译过时叫 `X.default.json` / `X.registry-size.json`；源文件同名时还会嵌套，例如仓库里有 3 个 EntryPoint.sol，default 版本在 `out/core/EntryPoint.sol/EntryPoint.json`，而 `out/EntryPoint.sol/EntryPoint.json` 反而是 runs=200。解析器先把每个合约映射到它的源文件，尝试 forge 用过的所有布局，只接受 artifact 自己的 metadata 同时满足两点的那一份：`compilationTarget` 等于该源文件，`optimizer.runs == 500`。Registry 例外：它唯一的构建就是受限的 runs=200（`out/Registry.sol/Registry.json`，属于预期）。
- **内存隔离**。`run()` 是一个调用帧，Solidity 不释放内存。每次检查都把几百 KB 的 JSON 交给解析 cheatcode，第一版在第 5 个合约就 `MemoryOOG`；改用 forge 缓存索引查路径，每次查找约 12M gas，同样耗尽。现在的做法：查找和比对放到一个单独的 `T4ArtifactReader` 合约里，通过外部 **view** 调用（STATICCALL，不会被广播）执行，每次调用的内存在返回时释放。forge 不允许脚本里用 `address(this)`，所以不能自调用。reader 在脚本构造函数里创建，不在任何 broadcast 里。验证：dry-run 的 72 笔交易里没有一笔发往 reader。
- anvil 专用的基础设施（EntryPoint、SimpleAccountFactory/SimpleAccount、价格 mock）原来只在部署脚本的闭包里被编译，也就只有 runs=200 版本。新增 `contracts/test/helpers/AnvilMockPriceFeed.sol`：它 import 了前两者，并承接了原来写在 DeployAnvil 里的 MockPriceFeed（改名 `AnvilMockPriceFeed`），这样 `forge build` 会产出它们的 default 版本。
- DeployAnvil、DeployLive、DeployRepCreditSepolia 末尾都有 `_assertAllDefaultArtifacts()`，把本脚本创建的所有东西（直接部署的、代理、工厂克隆）再核一遍。`prepare-test` 在 anvil 上最后运行新的只读检查 `contracts/script/checks/CheckDefaultArtifacts.s.sol`；live 链上还是 T-4 之前的部署，所以不在 live 链上跑。

**验收 (1)**：全新 anvil（28545），`./deploy-core anvil --force` exit 0（deploy-core 日志里有 100 行 `default artifact OK`，每个合约在创建时和最后的 T-4 汇总里各出现一次），9 个 Check、ABI 选择器、代理指向检查全部通过，内置的 prepare-test 和 Check09 也通过；随后单独的 `./prepare-test anvil` exit 0。同一条链上的 L4 余额模式 op：链上烧毁 78.2766 = operator 余额减少 = revenue 增加，`lockedOf` = 0。

**验收 (2)**：`CONFIG_FILE=config.anvil.json forge script contracts/script/checks/CheckDefaultArtifacts.s.sol:CheckDefaultArtifacts --rpc-url <anvil>`，逐个读出 config 里的地址，与 default artifact 比对（immutable 屏蔽）：**33 / 33 一致**。

| key | 类型 | 地址 | artifact | 运行时 | 结果 |
|---|---|---|---|---|---|
| registry | ERC-1967 代理 | 0xCf7E…0Fc9 | ERC1967Proxy + impl Registry（0x9fE4…a6e0） | 100 B / 23,038 B | OK |
| registryImpl | 直接 | 0x9fE4…a6e0 | Registry（runs=200，预期） | 23,038 B | OK |
| superPaymaster | ERC-1967 代理 | 0x68B1…1aed | ERC1967Proxy + impl SuperPaymaster（0x9A9f…63AE） | 100 B / 22,915 B | OK |
| spImpl | 直接 | 0x9A9f…63AE | SuperPaymaster | 22,915 B | OK |
| gToken | 直接 | 0x5FC8…5707 | GTokenAuthorization | 6,113 B | OK |
| staking | 直接 | 0x0165…Eb8F | GTokenStaking | 9,061 B | OK |
| sbt | 直接 | 0xa513…C853 | MySBT | 12,111 B | OK |
| xPNTsFactory | 直接 | 0xDc64…F6C9 | xPNTsFactory（3.x） | 6,802 B | OK |
| aPNTs | EIP-1167 | 0xb027…9cC3 | → xPNTsToken 0x856e…8eae5 | 15,301 B | OK |
| reputationSystem | 直接 | 0xc5a5…C42d | ReputationSystem | 7,044 B | OK |
| dvtValidator | 直接 | 0x67d2…5933 | DVTValidator | 6,326 B | OK |
| blsAggregator | 直接 | 0xE6E3…e57E | BLSAggregator | 24,345 B | OK |
| paymasterFactory | 直接 | 0xc3e5…3690 | PaymasterFactory | 6,158 B | OK |
| paymasterV4Impl | 直接 | 0x84eA…7fEB | Paymaster | 10,492 B | OK |
| aPNTsPaymasterV4 | EIP-1167 | 0xa37a…D304 | → Paymaster 0x84eA…7fEB | 10,492 B | OK |
| pNTsPaymasterV4 | EIP-1167 | 0xe3AD…e672 | → Paymaster 0x84eA…7fEB | 10,492 B | OK |
| microPaymentChannel | 直接 | 0x9E54…3042 | MicroPaymentChannel | 6,117 B | OK |
| x402Facilitator | 直接 | 0x1429…F20f | X402Facilitator | 4,332 B | OK |
| policyRegistry | 直接 | 0x162A…6890 | PolicyRegistry | 6,349 B | OK |
| timelockController | 直接 | 0xB0D4…Ca07 | TimelockController | 5,458 B | OK |
| aoaProtocolRegistry | 直接 | 0xc6e7…4e7d | AOAProtocolRegistry | 2,554 B | OK |
| globalTierSource | 直接 | 0x3Aa5…443c | GlobalTierSource | 542 B | OK |
| xPNTsTokenV2Ext | 直接 | 0xa852…338f | xPNTsTokenV2Ext | 21,922 B | OK |
| xPNTsTokenV2Impl | 直接 | 0x4A67…5319 | xPNTsTokenV2 | 19,851 B | OK |
| xPNTsFactoryV2 | 直接 | 0x7a20…814F | xPNTsFactoryV2 | 6,899 B | OK |
| superPaymasterLens | 直接 | 0x0963…ceBef | SuperPaymasterLens | 4,731 B | OK |
| aastarXPNTsV2 | EIP-1167 | 0xDC17…20F4 | → xPNTsTokenV2 0x4A67…5319 | 19,851 B | OK |
| pnts | EIP-1167 | 0x2C47…0700 | → xPNTsTokenV2 0x4A67…5319 | 19,851 B | OK |
| entryPoint（anvil） | 直接 | 0xe7f1…0512 | EntryPoint（v0.7 core） | 12,143 B | OK |
| simpleAccountFactory（anvil） | 直接 | 0xa82f…CFc9 | SimpleAccountFactory（其 SimpleAccount 实现 4,768 B 在部署时已核） | 1,447 B | OK |
| priceFeed（anvil） | 直接 | 0x5FbD…0aa3 | AnvilMockPriceFeed | 142 B | OK |
| agentIdentityRegistry（anvil） | 直接 | 0x1613…78E8 | MockAgentIdentityRegistry | 1,068 B | OK |
| agentReputationRegistry（anvil） | 直接 | 0x8513…891C | MockAgentReputationRegistry | 1,422 B | OK |

对比上一版：BLSAggregator 从 23,940 B 变为 24,345 B，GTokenStaking 从 9,086 B 变为 9,061 B，MySBT 从 12,093 B 变为 12,111 B，等等。现在部署的就是测试和体积测量所用的那份字节码。
`agentValidationRegistry` 是 0 地址，不在表内。

**反例（检查器确实会变红）**：在同一条 anvil 上用 `anvil_setCode` 把 BLSAggregator 换成 registry-size 构建（23,940 B），`CheckDefaultArtifacts` 输出 `blsAggregator | … | 23940 B | MISMATCH`、`checked 33 mismatches 1`，exit 1；恢复原代码后回到 `mismatches 0`，exit 0。

**验收 (3)**：`forge build` 为 `No files changed`；`forge test`（Cancun）**124 个套件，1567 passed / 0 failed / 49 skipped**；`forge test --evm-version prague`（单独的 out/cache 目录）**1476 / 0 / 21**。

**验收 (4)**：在 Sepolia fork（本地 28546）上**只模拟、不广播**，使用 anvil 测试私钥，`TESTNET_EOA_OWNER_ACK=true`。两个脚本都 exit 0，并执行了 `=== T-4: all contracts == profile.default artifact ===` 段：
- DeployLive：56 行 `default artifact OK` + 3 个克隆，覆盖 26 类：AOAProtocolRegistry、BLSAggregator、DVTValidator、ERC1967Proxy（×2）、GTokenAuthorization、GTokenStaking、GlobalTierSource、MicroPaymentChannel、MySBT、Paymaster、PaymasterFactory、PolicyRegistry、Registry、ReputationSystem、SuperPaymaster、SuperPaymasterLens、TimelockController、X402Facilitator、xPNTsFactory、xPNTsFactoryV2、xPNTsToken、xPNTsTokenV2、xPNTsTokenV2Ext；克隆：aPNTs → xPNTsToken、V4 proxy → Paymaster、Mycelium PNTs → xPNTsTokenV2。
- DeployRepCreditSepolia：46 行 + 2 个克隆，覆盖 21 类（同上，去掉 V4/x402/timelock/policy/MicroPaymentChannel，加上两个 Mock agent registry）。

## 9. 第 1 步的两条分支——请作者决定

事实（fork 块 11692260 读回，与协调方给出的 step-0 盘点一致）：operator `0xEcAA…33c9` 余额 844.540702843415794600，`0xb560…df0E` 余额 1690.008712737068326800；`protocolRevenue` 399.586525633215878600；`totalTrackedBalance` 2934.135941213700000000（= 两个 operator 之和 + revenue，没有漏掉的 operator）；待切换代币 `0xBb46…9883`（xPNTs 3.5.0 的 EIP-1167 克隆，"AAStar PNTs"/aPNTs），ETA 已过；没有 `DebtRecordFailed`，也就没有 pendingDebts。

5.4.2 的 `executeAPNTsTokenChange` 要求 `totalTrackedBalance == protocolRevenue && protocolRevenue <= 0.1`。所以原来那个"只调 execute"的版本在 Sepolia 上**一定 revert**，已重写成一次完整的迁移：`executePendingAPNTs(address[] ops)` 仍然要求 `V55_APNTS_DECISION=execute`，步骤为：(1) 快照 → (2) 各 operator `withdraw` 全额 → (3) owner 把 revenue 提到 buffer → (4) 检查前置条件 → (5) execute 并读回 → (6) 各 operator 用**新**代币 approve + `deposit(snapshot × V55_APNTS_RATIO_WAD)`（旧→新比例由作者决定，默认 1:1）→ (7) 读回每个余额 = 快照 × 比例，并且 `totalTracked = Σ + revenue`。真实 operator 必须自己先拿到新代币，否则第 (6) 步明确报错。只有 fork 上的 `V55_REHEARSAL_FUND_NEW_APNTS=true` 会用新代币的 communityOwner 铸出差额。另外 inventory 的标签已改为 `pendingAPNTsTokenEta`。

两条分支各用一个**全新的** fork（端口 28546 / 28547，块 11692260），每条都完整走：inventory → 第 1 步 → pause（两个 operator）→ `run()`（第 4–5–5b–6 步，**严格前置检查**，不再需要 rehearsal 开关）→ 7a（两个社区各发一枚 v2 代币）→ 7c-1 / 7c-2（两个 operator 都配置并取消暂停）。所有步骤 exit 0，所有读回通过；两条分支里 7 个 5.5.0 合约都记录为 `artifact default (runs=500)`，SP impl 22,915 B。

| | **A：execute**（切到 `0xBb46…`） | **B：cancel**（保留 `0x696A…`） |
|---|---|---|
| 第 1 步读回 | `APNTS_TOKEN` 0x696A… → **0xBb46…**，pending = 0，ETA = 0 | pending = 0，ETA = 0，`APNTS_TOKEN` 仍是 **0x696A…** |
| (2) operator 提走的旧代币 | 0xb560：1690.008712737068326800；0xEcAA：844.540702843415794600（旧 aPNTs 回到 operator 手里） | 不发生 |
| (3) revenue | 399.486525633215878600 转到 treasury（= owner EOA `0xb560…`），留 0.1 buffer | 不变：399.586525633215878600 |
| (6) 新代币来源 | 0xb560 本来就持有足够的新 aPNTs；0xEcAA 缺 844.54，由新代币 communityOwner（**正是 SP owner EOA 0xb560**）在 fork 上铸出 | 不发生 |
| operator 余额（之前 → 之后） | 0xb560 1690.0087 → 1690.0087（新代币）；0xEcAA 844.5407 → 844.5407（新代币） | 两者都不变（旧代币） |
| `totalTrackedBalance` / `protocolRevenue`（最终） | 2534.649415580484121400 / 0.1 | 2934.135941213700000000 / 399.586525633215878600 |
| 最终 SP | 5.5.0；stake 1 ETH / 86400 / 未解锁；xpntsFactory = factoryV2 `0xF40a…e6C6` | 5.5.0；stake 1 ETH / 86400 / 未解锁；xpntsFactory = factoryV2 `0x499D…D962` |
| operator 最终状态 | 两个都在 v2 代币上（0xb560 → `0x5779…39ac`，0xEcAA → `0x7971…5E8b`），未暂停 | 两个都在 v2 代币上（0xb560 → `0x7F2e…CC48`，0xEcAA → `0x49BF…ffb6`），未暂停 |
| 剩余风险 | 留下的 0.1 revenue buffer 记在账上，但 SP 持有的是旧代币，不是新代币；新 aPNTs 的无上限增发权在一个 EOA 上；operator 手里多出一笔旧 aPNTs，需要另行处理（兑换/作废） | 待切换的新代币被放弃；如果以后还要切换，得在 5.5.0 上重新 `setAPNTsToken` 并等 7 天，再做同样的清空与重存 |

**对 RepCredit 证据的影响（两条分支相同）**：已有的 RepCredit 证据是在 SP 5.4.x + aPNTs `0x696A…` 上采集的，两条分支都**不会改写**任何历史交易或事件，冻结的证据保持原样。runbook 第 10 步的重新采集用的是当时在用的 aPNTs：选 A 就是 `0xBb46…`，选 B 就是 `0x696A…`。选 A 时，论文里要写明存款资产在两次采集之间换过一次，并附上这里的迁移读回。
