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

入口：`inventory(address[])`、`inventoryDebts(address[],address[])`（第 0 步）；`executePendingAPNTs()` / `cancelPendingAPNTs()`（第 1 步，**需要作者决定**：不设 `V55_APNTS_DECISION=execute|cancel` 就拒绝执行，5.4.2 确有这两个函数）；`clearPendingDebts(...)`（第 2 步，D-21 核销，仅 5.4.2）；`pauseOperators(address[])`（第 3 步）；`run()`（第 4 → 5 → 5b → 6 步）；`ensureStake()`（单独执行 5b）；`issueCommunityToken(...)`（7a，社区广播）；`configureOperatorV2(token, treasury)`（7c-1，operator 广播，先 `updatePrice` 并读回）；`unpauseOperator(op)`（7c-2，SP owner 广播）。
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

1. **deploy-core 实际部署的是 runs=200 的字节码**。`foundry.toml` 对 `Registry.sol` 的 `compilation_restrictions` 会让 import 了 `Registry.sol` 的源文件连同整个依赖闭包都用 `registry-size`（runs=200）profile 编译。DeployAnvil / DeployLive 都 import 了 Registry，于是它们 `new` 出来的 SP、v2 模板等都是 `*.registry-size.json` 那一份（实测 SP 22,756 B，而 profile.default 是 22,915 B；xPNTsTokenV2 19,435 B vs 19,851 B）。这与 CLAUDE.md 里"deploy-core 编译的就是 [profile.default]、这就是上线的字节码"的说法不符，也意味着 D2 的体积/ABI 字节码证据测的不是 deploy-core 部署的那份。`UpgradeToV5_5_0` 刻意不 import Registry，并断言新 impl 等于 default artifact。是否让 DeployLive 也改成这样，需要决定。
2. **deploy-core 的 ABI 同步会改写已提交的 `abis/*.json`**：它用 `jq '.abi'` 把 `{abi, bytecode}` 格式的 bundle 覆盖成纯数组，并且用 `find | head -1` 选 artifact（D2 已在 `extract_v3_abis.sh` 修过同类问题）。而 audit-core 的选择器检查恰恰只认纯数组——提交的 bundle 格式会让它"无法解析、跳过"。本次运行后已 `git checkout -- abis/` 还原，未提交这些改动。两处要统一，另开项。
3. `L4GaslessTest` 必须带 `--gas-estimate-multiplier 400`（§4）。
4. v2 代币上的 X402Facilitator：TestAccountPrepare 已跳过（原逻辑会 revert）。要在 v2 代币上启用 x402，需要把 facilitator 的实现 codehash 加入 AOA registry 的 KIND_SPENDER（registry 已 seal，所以要走 48 h 的 propose/execute），再由社区 `proposeSpender` + 48 h `activateSpender`。
5. AOA registry 与 factoryV2 的 owner：DeployLive 在设了 `GOVERNANCE_OWNER` 时移交并过闸；`UpgradeToV5_5_0` 在 Sepolia 上 owner 是 EOA，只打印提醒，没有移交。
6. RepCredit 实验在 5.5.0 下的信用开通流程（按代币的 AUTO 策略 + 48 h + 用户 `requestCredit`）不在本次范围，`DeployRepCreditSepolia` 只做部署与接线。
7. 下游（repo:sdk、repo:dvt、YAAA）：新的 paymasterAndData、Lens、v2 代币 ABI，按约定在 D5/D7 完成后开 issue。
