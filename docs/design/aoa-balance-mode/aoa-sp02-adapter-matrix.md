# AOA-SP-02 第 1 项：SP / VPM / TPM 三臂对照表

依据：DSR `AOA_Parallel_Work_Orders_2026-10-26.md` §AOA-SP-02 子任务 1；作者决定 W-1/W-2（2026-10-27）。
本表描述**当前仓库里的采集器**（`script/a6-collector/collector.mjs`、`deploy-baselines.mjs`、`build-baseline.sh`，
main @ `92d1511b`）实际怎样驱动三臂。正式 A6 尚未开窗，正式运行身份（链、RPC A/B、bundler、窗口）
由 SP-01/M2 提供后才能填，见 §4。本文不是 A6 证据，也不改变 [A6-SOP](../../../script/a6-collector/A6-SOP.md)。

## 1. 对照表

| 维度 | SP（SuperPaymaster） | VPM（VerifyingPaymaster） | TPM（TokenPaymaster） | 三臂一致？ |
|---|---|---|---|---|
| 合约来源 | 本仓库 `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`，`version()` = `SuperPaymaster-5.5.0` | eth-infinitism v0.7 `samples/VerifyingPaymaster.sol`，**未修改**；源码 sha256 `fd6c9b76…45f6bd` | 同仓 `samples/TokenPaymaster.sol`，**未修改**；源码 sha256 `6a1bc069…bc7301` | 否（必要差异：被比较对象） |
| 编译设置 | solc 0.8.33，optimizer 500 runs，via_ir，cancun（`foundry.toml` default profile） | solc 0.8.33，optimizer 1e6 runs，**无** via_ir，cancun（`build-baseline.sh`） | 同 VPM | 否，见 §2 N-1 |
| 部署 | `deploy-core` 全栈（UUPS proxy） | `deploy-baselines.mjs` 直接部署 | 同 VPM，外加测试代币 `F1TestToken`、1:1 `F1Oracle` | 否（必要） |
| EntryPoint | 部署配置里的 `entryPoint`；Passport 读回 `entryPoint()` 并要求三臂相同 | 构造参数 EP，同左 | 同左 | **是**（collector 不一致即停，退出码 26） |
| EP 押金 / 质押 | 押金由 `deploy-core`/`prepare-test` 设定，collector 每次发送前读 `balanceOf(SP)` 做押金下限检查（RDR-6 ①）；**本地演练里 SP 未质押**（Passport 记录 `staked=false, stake=0`，见 §2 U-6） | 押金 10 ETH，质押 1 ETH / 86400 s | 同 VPM | **否**：质押不一致，见 U-6；押金额本来就不要求相同 |
| 账户 | 同一个 SimpleAccount：`simpleAccountFactory.getAddress(owner, salt=9001)`，owner = 本地 key #0；Passport 记账户与 implementation 的 codehash | 同左 | 同左 | **是** |
| nonce | 同一 sender、nonce key 0，三臂按 SP→VPM→TPM 顺序轮流使用 | 同左 | 同左 | 是（顺序递增，不复用） |
| 目标 calldata | `SimpleAccount.execute(0x…dEaD, 0, 0x)`；记录 `callDataHash` | 同左 | 同左 | **是** |
| UserOp gas 字段 | callGas 100k，verificationGas 300k，PVG 60k，maxFee 20 gwei，maxPriority 2 gwei | 同左 | 同左 | **是** |
| paymaster gas limit（ver / postOp） | 400k / 200k（D7：5.5.0 验证需 >150k） | 100k / 50k | 150k / 120k（`refundPostopCost` 40k 须小于 postOp limit） | 否，见 §2 N-2 |
| paymasterData | operator 地址 ‖ maxRate = 2²⁵⁶−1 ‖ xPNTs 代币地址 ‖ `0x00` | `abi.encode(validUntil=0, validAfter=0)` ‖ verifyingSigner 签名 | 空 | 否（必要：各自协议） |
| 链下签名 | 无 | verifyingSigner = 本地 key #2，collector 自己签 | 无 | 否，见 §2 U-2 |
| 代币 / 付费状态 | 用户 xPNTs 铸到 40,000；`setUserTotalCap`、`setAutoAllowance(SP)` = 50,000；operator aPNTs 押入 SP 补到 ≤ 20,000；SBT 资格经模拟 Registry 调 `updateSBTStatus`；开窗前 `updatePrice` 刷价 | 无代币（ETH 赞助） | 测试代币铸 40,000，`approve(TPM, max)`；1:1 oracle，`priceMarkup` = 1e26（等于分母，即无加成）；`minEntryPointBalance` = 0，postOp 不触发换币补押金 | 否；DSR 接收格式只要求 `tokenStateProtocol` 同组一致，不要求余额字节相同 |
| bundler | 同一 EOA（本地 key #1）直接调 `EntryPoint.handleOps`，beneficiary = 该 EOA；每笔 bundle 只含 1 个 op（B_max 由 `--b-max` 指定） | 同左 | 同左 | **是**（但不是生产 bundler，见 §2 U-1） |
| 成功判定 | 逐 UOE（`UserOperationEvent.success`）；receipt 成功是前提但单独不够（`gauge-lib.mjs` `classifyAttempt`） | 同左 | 同左 | **是** |
| 额外解码 | `TransactionSponsored`、xPNTs 锁定/结算、credit 事件；SP 守恒检查 | 只有 EP 押金变化 | 只有 EP 押金变化 | 否（必要：SP 有内部账） |

## 2. 必要差异与不可归因部分

**N-1 编译设置不同。** 基线按 eth-infinitism 样本的常见做法用 1e6 runs、不开 via_ir；SP 用本仓库发布设置
（500 runs + via_ir，受 EIP-170 约束不能改）。两者 gas 差里有一部分来自编译器而非机制。本表不尝试分离这部分，
论文若比较 gas 绝对值须写明此条。

**N-2 paymaster gas limit 不同，而且会直接改变 `actualGasUsed`。** 各臂按自己验证/postOp 的需要设置。
EntryPoint v0.7 对执行段未用完的 gas 收 10% 罚金：`unused = (callGasLimit + paymasterPostOpGasLimit) − executionGasUsed`，
`actualGas += unused × 10%`（`singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol:718-730`），罚金算进 UOE 的 `actualGasUsed` 和 `actualGasCost`。
每臂的罚金 = 10% × 该臂自己的未用执行 gas，取决于两件事：limit（callGasLimit 三臂都是 100k，postOp limit 为
SP 200k、VPM 50k、TPM 120k；VPM 不返回 context、不跑 postOp，但 50k 仍计入基数）和该臂执行段的实际消耗（SP 的 postOp
结算比 TPM 的重）。两项都因臂而异，罚金差 ≈ 10% × (Δlimit − Δ实际执行消耗)。只看 limit 只能给出宽松范围：每臂罚金在
[0, 10% × (callGasLimit + postOp limit)] 内，即 SP ≤ 30,000、VPM ≤ 15,000、TPM ≤ 22,000 gas，SP 与 VPM 之差在 [−15k, +30k]；
三臂改用同一个 limit 也消不掉，因为实际消耗仍不同。所以 `actualGasUsed` **不能直接当机制成本比较**：
需要逐臂把罚金分离出来报告（执行段实际消耗要靠 trace 取得），
或者把每臂的 limit 收紧到各自实测上界、让未用量接近 0 并报告残余。用哪种由 DSR 在采样前定（§4）。
prefund 不同另外影响押金下限计算（RDR-6 的 F 按各臂自己的 limit 求和）。

**U-1 bundler 不是生产实现。** collector 用一个 EOA 直接 `handleOps`，不经 Rundler/Alto 的模拟与 ERC-7562 检查。
PVG 固定为 60k，不是 bundler 估算值；bundle 内只有 1 个 op，不能代表多 op 分摊。正式窗口若换成生产 bundler，
本行要重填，且 bundler 配置哈希进 `bundlerConfigHash`。

**U-2 VPM 的签名服务是本地自签。** 真实 VerifyingPaymaster 依赖链下签名服务，其延迟、可用性和费用不在链上 gas 里，
本对照不覆盖。

**U-3 TPM 的价格与补押金路径被简化。** 固定 1:1 oracle、无加成、`minEntryPointBalance = 0`，所以 postOp 从不走
Uniswap 换币补 EP 押金。真实部署的 TPM 会周期性付这笔 gas，本对照测不到。

**U-4 SP 的准入状态靠本地手段造出。** SBT 资格用模拟 Registry 写入，而不是走 `Registry.safeMintForRole` 全流程；
价格缓存开窗前刷新一次。这些步骤的成本不计入逐 op gas。正式链上不能用模拟，见 A6-SOP 的 SP TODO。

**U-6 本地演练里 SP 没有质押，基线各质押 1 ETH。** `docs/design/aoa-balance-mode/data/a6-gauge-local/` 里带 `run_start` 的 8 个运行
（含 `n50-mechanism.jsonl`；`old-*.jsonl` 两份是旧格式，没有这个字段）Passport 都是 SP `staked=false, stake=0`、VPM/TPM `stake=1e18, unstakeDelaySec=86400`。
原因是 `DeployAnvil` 不给 SP 质押（`DeployLive` 给 0.1 ETH），而 `deploy-baselines.mjs` 给基线 1 ETH。
直接 `handleOps` 不检查质押，所以逐 op gas 不受影响；但生产 bundler 会按 ERC-7562 拒绝读全局槽而未质押的 SP，
本地结果因此对「SP 能否被生产 bundler 接纳」没有说明力。`validate.mjs` 只检查这几个字段的类型和运行中是否漂移，
**不检查质押门槛或三臂一致**。正式窗口前 SP 要按 W-1 质押到 ≥ 1 ETH / 86400 s，并补一条校验或列入 DSR 核对项（§4）。

**U-5 三臂共用一个 sender。** nonce 顺序递增，三臂的 op 落在不同块。块间的 base fee 差异进入
`effectiveGasPrice`，所以比较应以 gas 量（`actualGasUsed`）为主，费用（wei）为辅。

## 3. W-1 / W-2 的依据

两项都是作者 2026-10-27 在本会话里定下的（SP 已在 Seeder CC-125 评论 `8bda8294` 转告 DSR）：

- **W-1（主网 SP 质押暴露）：保持 ≥ 1 ETH。** 与 `03-final-spec.md` 第 5b 行（D-9：Rundler v0.11.0 默认
  1 ETH / 86400 s）一致，不为 SP 调低 bundler 的 minStake。本仓库没有 OP 主网 V5 SP 的部署记录
  （`deployments/config.op-mainnet.json` 是空 stub）；这只说明仓库里没有登记，**不证明链上不存在**，下面的 W-2 读数也只覆盖旧 SP
  和旧工厂。W-1 约束的是研究用的那次部署：部署后用 `EntryPoint.getDepositInfo(SP)` 读回 `stake ≥ 1e18`、
  `unstakeDelaySec ≥ 86400`，在研究窗口开窗前做。
- **W-2（OP 主网旧实例）：保持不动，写明不在研究部署范围内，并列出现有押金。** 列表如下，用两个不同运营方的公共端点
  （OP Labs `mainnet.optimism.io`、Allnodes publicnode）在区块 **158,749,238**
  （hash `0x2c0b5b46…6b8062a2`）读取，两边逐值一致：

  | 实例 | 地址 | version() | EP 押金 | 质押 / unstakeDelay | owner（无代码 = EOA） |
  |---|---|---|---:|---|---|
  | 旧 SP（V3） | `0xA2c9A6e95f19f5D2a364CBCbB5f0b32B1B4d140E` | SuperPaymaster-3.2.2 | 0.089012729856682592 ETH | 0.1 ETH / 86400 s，未解锁 | `0x51Ac6949…b8A3`，EOA |
  | V4（工厂第 0 个） | `0x67a70a578E142b950987081e7016906ae4F56Df4` | PMV4-Deposit-4.3.0 | 0.045097812963108079 ETH | 0.1 ETH / 86400 s，未解锁 | `0x51Ac6949…b8A3`，EOA |
  | 合计 | 2 个 | | 0.134110542819790671 ETH | 0.2 ETH | |

  原始读数：[`data/aoa-sp02/w2-op-mainnet-exposure-158749238.json`](data/aoa-sp02/w2-op-mainnet-exposure-158749238.json)。
  复现：

  ```sh
  RPC_A=https://mainnet.optimism.io RPC_B=https://optimism-rpc.publicnode.com \
    python3 script/evidence/w2-op-mainnet-exposure.py 158749238
  python3 script/evidence/test_w2_op_mainnet_exposure.py   # 16 个离线对照
  ```

  publicnode 只保留近期状态，几分钟后再读这个块会被当作归档请求拒绝（要 token）；按固定块复现需要两个归档端点。
  不指定块时脚本读「最新块 − 64」，两边仍须逐值一致。

  **范围限制。** V4 实例只从旧 `PaymasterFactory`（`0x58A7…eB8`，`getPaymasterCount` = 1）枚举；不经工厂直接部署的
  paymaster 这里找不到。两个端点一致只说明两家运营方给出同一答案，不证明后端独立。owner 是 EOA，
  这两个实例的押金和质押在 owner key 失守时可被提走，这是 W-2 明确接受的暴露。

  离线对照共 16 条。14 个变异探针各去掉一条检查（端点一致、链 id、列表长度 = count、数据不短于长度字、
  动态偏移必须为 32、bool 只能 0/1、uintN 不溢出、地址高位清零、getCode 答复格式、块哈希格式、eth_call 结果须带 0x、链 id 与块号的 quantity 格式（两个探针）、畸形答复不回显），
  每个都只让针对该检查的测试转红；端点一致有两条测试（押金不同、块哈希不同），去掉它时两条同时转红。

## 4. 采样前仍待定（不由 SP 代决）

| 项 | 现状 | 由谁定 |
|---|---|---|
| 正式窗口的目标链 | 采集器只接受本地 anvil；正式链和账户准备路径缺失（A6-SOP「SP TODO」第 1 条） | 作者 / DSR，M2 后 |
| bundler | 当前为 EOA 直调 `handleOps`；换生产 bundler 后要重填 §1 的 bundler 行和 U-1 | 作者 / DSR |
| RPC A/B 身份与独立性依据 | 未登记 | SP 交，DSR 核 |
| 各臂押金上限 D_cap 与下限 F | RDR-6 公式已定，数值待 Sepolia A4 P95 | SP 算，DSR 核 |
| 是否需要分离编译器影响（N-1） | 本表只标出 | DSR |
| 未用 gas 罚金的处理（N-2） | 罚金随各臂 limit 与实际执行消耗变化，统一 limit 也消不掉 | DSR 定：逐臂分离报告，或收紧到实测上界并报告残余 |
| SP 质押门槛（U-6） | 本地演练 SP 未质押；校验器不查门槛 | SP 补校验或 DSR 核对；质押额按 W-1 |
