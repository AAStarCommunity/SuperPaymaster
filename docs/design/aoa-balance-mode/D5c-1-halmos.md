# D5c-1 · 有界符号验证（Halmos）：CAP-1、A-3、I2、I6

> **状态（2026-09-15，最终）**：全部证据由加固后的判定脚本 `script/halmos/verify-d5c1.py` 判定——**ALL EXPECTATIONS MET（151 行，退出码 0）**，输出存档 `data/halmos/verify-final.txt`。每条日志都绑定到当前源码与字节码（源码集 sha256 + 被测字节码哈希 + `dirty_src = 0`，头尾两次绑定一致），分区集合与当前 ABI 逐一相等；有界（TIMEOUT）只允许出现在`script/halmos/d5c1-expectations.json` 的白名单分区上，每个都写明原因和替代证据。2026-09-13 暂停前的 RESUME 记录已被本段取代（历史见 git log）。

> 分支 `d5c-1/halmos-token`，基线 `275abaef`（`feat/aoa-balance-mode-5.5.0` 的头）。规范：[03-final-spec.md](03-final-spec.md)（§2.3 A-3、§4 I2/I4/I6、§10.2 的 xc 公式、§10.7b GOV-4）、[apnts-capped-design.md](apnts-capped-design.md)。
> 本交付只加测试和脚本，本身不改 `contracts/src/`（五个变异都在树的临时副本里做，逐字节恢复并用 sha256 校验，见 §5）。唯一的源码变化是协调方针对本交付发现 F-D5c1-1 的修复 `3c28ec21`（fast-forward 进本分支，§F）。
> 证据登记：[EVIDENCE-INDEX.md](EVIDENCE-INDEX.md) 的 H-01…H-06 行（合入 feat 时登记；S- 前缀已用于规范冻结）；原始日志在 `data/halmos/`。

## 0. 结论

| 性质 | 结论 | 说明 |
|---|---|---|
| **CAP-1**（APNTsCapped 上限） | **PROVEN**（单步归纳，任意前置状态，`bounds: []`） | 3 个 check 全 PASS；witness 按预期给出反例 |
| **R**（汇率 ∈ [1e14, 1e22]，单笔上限 ≤ 50,000e18） | **PROVEN**（基础情形 + 归纳步） | 基础情形：`initialize` 与真实工厂路径（初始汇率取满 `uint256`）；归纳步 core 15/15、ext 44/44 |
| **A-3**（SP / 历史 SP 不能转走、只能按记录销毁） | **BOUNDED**：core 15/15 PASS，ext 43/44 PASS；`mint` 分区 TIMEOUT | `mint` 分区拆开：`debts(v) = 0` 的变体 PASS；`debts(v) > 0` 归结为引理 M（纸面证明 + fuzz） |
| **A3x**（精确向上取整界 `dec ≤ ceil(c·x0/a0)`） | **BOUNDED**（`settleLocked` 在 600 s 墙钟上限处 TIMEOUT） | 替代：`D5c1BoundedFuzzTest.testFuzz_D5c1_I2_settleLocked` 断言 A3x 位掩码（10,000 次） |
| **I2**（额度累计 ≤ cap） | **BOUNDED**：core 12/15、ext 42/44 PASS | TIMEOUT 分区：core `burn(address,uint256)` / `transferFrom` / `tryLockForGas`，ext `transferFrom` / `mint`；替代：各自的 10,000 次 fuzz（`D5c1BoundedFuzzTest`）与 `mint` 的 `debts = 0` 变体 PASS |
| **I6 / I6-J**（恶意 SP 只能销毁；新债 ≤ 申请上限） | **PROVEN**（core 15/15、ext 44/44，两者都是） | 含 `mint` 分区 |
| **引理 M**（`mint` 自动抵债不降低收款人余额） | **BOUNDED**（M、M1–M3 都在 540 s 求解器上限处 TIMEOUT） | 唯一不是符号证明的环节：纸面证明（§7）+ 真实代码路径上的 fuzz（`MintRepayLemmaFuzzTest`，10,000 次） |

- **可达性对照**：5 个 witness 与 `XPNTsV2I2NoRHalmosTest`（去掉 R 的负对照）都按预期给出反例，说明 harness 不是空洞地通过。
- **变异**：M-CAP1、M-A3、M-I2、M-I6、M-F1 五个 Halmos 变异都在指名的 check / 分区上给出反例，对应的场景测试变红，源码按 sha256 逐字节恢复；fuzz 替代证据的变异 M-I2、M-PULL、M-BURNALL、M-REPAY 都让指名的 fuzz 测试变红，未变异时全绿（§5）。
- **发现**：F-D5c1-1（初始汇率不设范围 → `uint128` 截断 → I4 失效）是真实、可达的缺陷，已在 `3c28ec21` 修复并有回归测试与变异 M-F1（§F）。
- **口径**：本交付是**有界符号验证**（bounds 与抽象见 §2.5、§8），不是对全部输入的完整证明；BOUNDED 的分区由写明的 fuzz 或纸面证明替代，论文里按"有界 / 仅 fuzz"如实标注。

## F. 发现（Findings）

### F-D5c1-1：初始汇率不设范围 → `uint128(x)` 截断 → I4 失效（真实、可达；已修复于 `3c28ec21`）

| 项 | 内容 |
|---|---|
| 怎么发现的 | 编写 I2-8 / I4-L 谓词（"创建记录时 `lockedOf` 增加量 == 记录的 `xLocked`"）时，核对 `tryLockForGas` 的写入发现 `lockedOf` 加的是完整 `x`（`xPNTsTokenV2.sol:237`，基线 `275abaef`），记录存的是 `uint128(x)`（`:238`）；随后追溯 `exchangeRate` 的所有写入点。**如实说明：这是推理发现、forge 具体回放确认的；Halmos 对应的反例见下面"符号侧"一行** |
| 根因 | `exchangeRate` 的范围 `[1e14, 1e22]` 只在 `updateExchangeRate` 检查（`Ext:371`）；`initialize`（`xPNTsTokenV2.sol:81`）与 `xPNTsFactoryV2.deployxPNTsToken`（`:258`）只拒绝 0。`x = ceil(a0 · rate / 1e18)`，当 `x ≥ 2^128`（`a0 = 5,000e18` 时 rate ≳ 6.8e34；`a0 = 1e18` 时 ≳ 3.4e38）记录被截断 |
| 受影响的不变量 | **I4**（`lockedOf = Σ 未结清记录的 xLocked`）。**不是** I2 的 cap 上界、A-3 或 I6 的上界：截断只会让收费更少、限制更严 |
| 影响 | 结算 / stale release 只减掉截断后的值，`lockedOf` 留下一段没有任何记录对应的残值：这部分余额被 A-1 永久冻结；`_renew` 要求 `lockedOf == 0`，用户永远不能再续期；结算按截断后的 `x0` 烧币（用户少付）。触发条件是社区以极端初始汇率部署（工厂允许） |
| 修复前的具体回放 | 基线 `275abaef`：`data/halmos/finding-F-D5c1-1-prefix-275abaef-replay.log`（测试源码存档 `data/halmos/finding-F-D5c1-1-prefix-replay-test.sol.txt`）：真实工厂、rate `1e40`、锁 1 aPNT → `x = 1e40`，记录 `xLocked = 1e40 mod 2^128`，结算后 `lockedOf` 残值 `1e40 − (1e40 mod 2^128) > 0`，全额转出 `BalanceLocked` revert |
| 修复 | `3c28ec21`（协调方提交，已 fast-forward 进本分支）：`initialize` 对 `exchangeRate` 施加 `[_RATE_MIN, _RATE_MAX] = [1e14, 1e22]`；常量移到 `xPNTsV2Base`（`Ext` 的公开 getter 不变）。结合 `maxSingleTxLimit ≤ 50,000e18`，`x ≤ 5e26 < 2^128` |
| 回归测试 | `D5c1ReplayTest.test_D5c1_REGRESSION_F1_rateOutOfRangeRejectedAtInit`（同一条真实工厂路径，rate `1e40` → `ExchangeRateOutOfRange(1e40, 1e14, 1e22)`）与 `test_D5c1_REGRESSION_F1_maxRateMaxLockIsExact`（rate `1e22`、锁 `maxSingleTxLimit`：记录精确、结算后 `lockedOf = 0`）；另有协调方的 `xPNTsTokenV2D3Test.test_I4_*` |
| 回归测试是活的 | 变异 **M-F1**（删掉 `initialize` 里的范围检查）：见 §5，回归测试与 Halmos 的基础情形检查 `check_RATE_base_initialize` 都变红 |
| 为什么 fuzz 没抓到 | G1 / G2 fuzz、D3 的有状态不变量套件（`xPNTsTokenV2Invariant.t.sol`）和所有单元测试都只用**合法范围内**的汇率创建 token（fixture 里写死 `1 ether` 一类的值，`updateExchangeRate` 的处理器也受范围约束），所以"`initialize` 收到越界汇率"这条路径在这些套件里**结构上不可达**——不是 fuzz 次数不够，而是生成器从不产生这种输入。**一般规则**：部署 / `initialize` 的参数必须在**整个类型域**上做 fuzz 或符号探索，而不是只在"合法范围"内；合法范围本身正是要被验证的对象。本交付据此加了 `check_RATE_base_realFactory`：初始汇率在完整的 `uint256` 上取符号值，走真实的 `xPNTsFactoryV2.deployxPNTsToken`（clone + `initialize`），断言"部署 revert，或新 token 满足 R"（PASS，5 条路径）；M-F1 下它变红（§5） |
| 同类修复（仅记录） | 协调方另在 feat 上提交了 `cbcb7045`（`SP.initialize` 的 `priceStalenessThreshold` 限定在 `[60, 86400]`），同一条规则的另一个实例；本交付不涉及 |
| 符号侧 | 修复后，汇率范围不再作为自由假设：`R := 1e14 ≤ exchangeRate ≤ 1e22 ∧ 0 < maxSingleTxLimit ≤ 50,000e18` 由 `XPNTsV2RateHalmosTest` 证明为归纳不变量（基础情形：`initialize`；归纳步：core + ext 全部选择器、任意发送者），I2 检查以 R 为前置条件。去掉 R 的变体 `XPNTsV2I2NoRHalmosTest` 预期在 bit 7 / bit 10 给出反例——这就是本发现在 Halmos 里的样子（§3.3） |

## 1. 工具、版本与编译设置

| 项 | 值 |
|---|---|
| Halmos | 0.3.3（`uv tool install halmos`；自带 z3 4.12.6、yices 2.6.4） |
| forge / solc | forge 1.7.1（`4072e487`）；solc 0.8.33 |
| 编译 profile | Halmos 自己执行 `forge build --ast --extra-output storageLayout metadata`，不设 `FOUNDRY_PROFILE`，即 `[profile.default]` |
| 与部署产物一致 | `python3 script/halmos/artifact-parity.py`（日志 `data/halmos/artifact-parity.log`）：被测合约（`APNTsCapped`、`xPNTsTokenV2`、`xPNTsTokenV2Ext`、`AOAProtocolRegistry`、`xPNTsFactoryV2`、`GlobalTierSource`）在 `out/<X>.sol/<X>.json`（default profile）里的 creation code，**逐字节**出现在每个 harness 的 creation code 里（Halmos 执行的正是 harness 里嵌入的这份代码）；两边 metadata 都是 `optimizer: true, runs: 500, viaIR: true, evmVersion: cancun, bytecodeHash: none`。**负对照**：同一合约的 `registry-size` 产物（runs 200，与 default 共用 `out/`）与 default 不同，且**不**出现在任何 harness 里——说明这个检查能区分两个 profile |
| 最终 `forge build` 之后复核 | 同一脚本在普通 `forge build`（不带 `--ast`）之后再跑一次，结果相同（见 `artifact-parity.log` 两段） |
| `forge test` 不运行 `check_*` | forge 只运行 `test*` / `invariant*`；harness 合约里只有 `check_*`，全量 `forge test` 的计数里没有它们（§9） |

## 2. 方法

### 2.1 归纳步（inductive step）

每条性质都写成**单步引理**：被测合约的**全部存储槽都是符号值**（`svm.enableSymbolicStorage`，任意前置状态），只加 §2.2 列出的良构假设；然后由**任意发送者**（A-3 限定为当前 SP 或历史 SP）发起**一次任意调用**（`svm.createCalldata` 覆盖整个 ABI 的所有非 view 选择器，外加空 calldata 和一个与所有选择器都不同的符号选择器输入），断言调用前后状态之间的关系。

- 这样得到的 PASS 对**所有**满足前置假设的状态成立，包括实际不可达的状态，所以它比"从部署状态出发走 k 步"更强：不需要深度界。代价是：不可达状态上的反例会是假反例，只能靠加强前置假设排除（§2.2 每条都说明为什么可达状态一定满足它）。
- 需要对无界集合求和的性质（例如"累计消费 = Σ 各笔预留"）不能直接写成单步引理。本交付的做法是：把这类性质拆成**逐步守恒引理**（每一步只改动它创建或删除的那一条记录，改动量正好是那条记录的数额），再在 §7 用对步数的归纳（从 genesis 全零状态出发）把它们组合成累计性质。I6 的信用部分找到了一个**不含求和**的归纳不变量 J(B)，直接被 Halmos 证明（§3.4）。

### 2.2 前置状态的良构假设

| # | 假设 | 用在 | 为什么可达状态一定满足 |
|---|---|---|---|
| W0 | APNTsCapped：`balanceOf(sender) ≤ totalSupply` | CAP-1 | OZ ERC20 的守恒：每次 `_update` 对余额和 totalSupply 做同额变化；burn 先检查余额，再对 totalSupply 做 `unchecked` 减法，所以违反 W0 的状态不可达（在这种状态上 burn 会让 totalSupply 回绕，是假反例的来源） |
| W1 | xPNTs：clone 已初始化（ERC-7201 Initializable 槽的 `_initialized ≠ 0`） | 所有 xPNTs 检查 | 工厂在创建 clone 的同一笔交易里调用 `initialize`（`xPNTsFactoryV2.deployxPNTsToken`）；未初始化的 clone 不存在于任何可达状态 |
| W2 | `exchangeRate ≠ 0` | 所有 xPNTs 检查 | `initialize` 写入 `> 0`（`xPNTsTokenV2.sol:81`），`updateExchangeRate` 拒绝 0（`Ext:370`） |
| W3 | 这一步可能动到的账户（受害者、发送者、ABI 前两个字按地址解读——`transfer/transferFrom/burn/mint/transferAndCall/settleLocked` 只在这些账户之间移动余额）：各自余额 ≤ totalSupply，且**任意两个不同账户之和** ≤ totalSupply | 所有 xPNTs 检查 | ERC20 守恒（所有余额之和 = totalSupply，mint 的 `_totalSupply += value` 是 checked）。第一版只约束了受害者与发送者这一对，Halmos 在 `transferFrom(from, to = 受害者)` 上给出反例：`from` 与受害者合计超过 totalSupply，OZ 对收款方的 unchecked 加法回绕，受害者余额“减少”。该反例已在 forge 里具体回放，确认只存在于不可达状态（§6），于是把 W3 加强为所有两两组合 |
| R | `1e14 ≤ exchangeRate ≤ 1e22` 且 `0 < maxSingleTxLimit ≤ 50,000e18`（**只用在 I2 检查**） | I2 | **不是自由假设**：`XPNTsV2RateHalmosTest` 证明它是归纳不变量——基础情形 `check_RATE_base_initialize`（修复 `3c28ec21` 之后 `initialize` 对汇率做范围检查），归纳步 `check_RATE_step_{core,ext}Abi`（任意发送者、全部选择器）。修复前它不成立（发现 F-D5c1-1），去掉它的 `XPNTsV2I2NoRHalmosTest` 保留作为对照 |
| W4 | 信用预热的检查里 `creditTierSource == SymTierSource`（其 `tierOf` 返回任意值） | I6、I6-J | 只是缩小"分档源是谁"，不缩小"分档源返回什么"：返回任意值已经覆盖了 `_tierOf` fail-closed 得到的 0。没有覆盖的只是"分档源 revert / 返回畸形数据"这条代码路径本身（它的结果 0 被覆盖），由 D3 的单元测试守住 |

### 2.3 瞬态存储与"预热"（priming）

Halmos 每个测试交易开始时瞬态存储为空。`settleLocked` / `settleCredit` 要求活标记为 1（L-3），所以**如果不做任何处理，所有结算路径都不可达，检查会"绿"得毫无意义**（这正是 §4 可达性对照要排除的情形）。

处理（最终版本）：目标是"**任意**符号前置状态 + (v, h) 这一个活标记"。活标记只能由 token 自己 TSTORE，所以仍然让当前 SP（符号布尔决定是否预热）真实调用一次 `tryLockForGas(v, h, 1e18, false)`（A-3、I2）或 `tryReserveCredit(v, h, 1e18)`（I6、I6-J），`h` 取任意调用的 opHash 参数。为了让这次调用只走一条路径：先保存它读写的每一个槽（记录两槽、`lockedOf`、额度格子、总额、余额、汇率、单笔上限、急停字、停用标志；信用这边还有策略/epoch、申请、分档源、债务、预留，以及分档源合约里的 `t[v]`），写入一组固定的可准入取值，调用（必须返回 OK），然后把**每一个**保存的槽恢复成原来的符号值。净效果：存储**完全不变**，只多了 (v, h) 的活标记。因此记录本身、`lockedOf`、计数、余额都和不预热时一样任意——包括"记录的 locker 是历史 SP""锁定之后同一交易里别的调用改过这些槽"等情形，比"保留预热调用写入的值"更一般。`D5c1PrimingTest` 在具体 token 上验证了这两点（快照逐字段不变；原来 `NotLive` 的结算在预热后成功）。

第一版（在符号状态上用符号参数直接预热、保留它写入的值）路径数爆炸：仅 `settleLocked` 一个选择器就超过 20 分钟没有结束；改成上面的"保存—固定—调用—恢复"之后的计时见 §3。

**只在任意调用是对应的结算函数时预热**（A-3 / I2：`settleLocked`；I6 / I6-J：`settleCredit`）。理由：只有结算函数能在活记录上**成功**（要求 live == 1）；stale release 与 `releaseAndDisable` 在活记录上 revert（`StillLive`，不改任何状态）；其他函数根本不读瞬态存储。所以对其他选择器，预热不增加任何覆盖，只增加路径。"调用前"快照取在预热**之后**。

覆盖边界：同一交易里同一用户**另有其他活记录**的情形没有单独枚举。被调用的结算函数只读取它自己那条 (v, h) 记录的活标记，其他记录的活标记对这一步不可观测，所以对单步引理没有影响。

### 2.4 调用面

- **CAP-1**：`svm.createCalldata("APNTsCapped", true)`——APNTsCapped 的全部选择器，**含 view**。
- **xPNTs v2**：两套 calldata 分别跑：`createCalldata("xPNTsTokenV2")`（core ABI）与 `createCalldata("xPNTsTokenV2Ext")`（extension ABI）。**两者都发往 clone**，所以 extension 的选择器经过 core 的 `fallback()` → `DELEGATECALL` 真实路由到达，与生产完全一致（EIP-1167 clone → core → extension）。
- **分区并行**（`script/halmos/run-partitioned.py`；harness 的 `_partition` 读环境变量 `D5C1_PART`）：每个 ABI 拆成“每个非 view 选择器一个分区”加一个 `OTHER` 分区，分区之间互不相交、并集等于整个调用面，只限制 calldata、不限制前置状态。`OTHER` = 空 calldata + 选择器**不属于** core ∪ extension 任何函数（含 view，共 148 个；列表由 `script/halmos/gen-selectors.py` 从产物生成，`test_D5c1_selectorListMatchesArtifacts` 防止过期）的 1024 字节任意输入——这些输入经 core 的 fallback 进入 extension，没有匹配的函数而 revert。**已知选择器配任意（非规范编码）参数字节**没有探索：Halmos 无法执行符号化的 ABI offset（`NotConcreteError`），而规范编码的调用已由各自的分区覆盖。M-A3 表明 `OTHER` 分区是活的：变异加入的新选择器不在列表里，`OTHER` 分区经 fallback 打到它并变红。
- xPNTs 不含 view 函数：Solidity 编译期保证 view 函数没有 SSTORE（本合约里没有内联汇编写存储的 view），不可能改变任何被断言的状态。

### 2.5 抽象与边界

| 项 | 取值 | 含义 |
|---|---|---|
| 非线性运算 | Halmos 默认：符号×符号的乘法、除以符号数、取模用未解释函数抽象；发现候选反例时自动"细化"（refine）为真实位向量语义再求解 | PASS 在抽象下是可靠的（抽象是过近似）；**任何**反例都必须在 forge 里用具体值回放（§6） |
| 循环展开 | `--loop 2`（默认）；每个 PASS 行的 `bounds: []` 表示没有任何循环达到展开界 | `bounds: []` 时结果与展开界无关 |
| 动态长度 | CAP-1：默认 `0,65,1024`；xPNTs：`--default-bytes-lengths 0,65` | xPNTs 里只有 `executeBySig(params, sig)`、`transferAndCall(…, data)`、`initialize` 的字符串用到 bytes/string；65 字节足以让 `executeBySig` 的每一种 `params` 解码成功（最长 `(address,uint256)` = 64 字节），`initialize` 在 W1 下必然 revert |
| 符号地址上的代码 | Halmos 把符号地址别名到已部署的合约之一，或视为空账户（调用成功、返回空） | 分档源、ERC-1271 签名者、`transferAndCall` 的接收者只可能是已部署的合约或空账户；没有覆盖"任意恶意外部合约的重入"（§8） |
| `ecrecover` | 未解释函数 | 可以"伪造"任何人的 ECDSA 签名。对单步引理这是过近似（更强）；在 I2 里 `executeBySig(user = v, …)` 因此被当作用户本人的操作（与规范 I2 的"用户亲自操作"一致，现实中需要 EUF-CMA 假设） |
| 求解器 | Halmos 0.3.3 默认（分支可行性 z3，断言 yices）；断言查询超时 **300 s**（`--solver-timeout-assertion 300000`；引理 M 的四个 check 用 540 s）；每个分区**墙钟上限 600 s**（超过即杀掉整个进程组，记为 TIMEOUT-WALL）；**不重跑**（每个分区恰好一份日志） | TIMEOUT / TIMEOUT-WALL 从不算作 PASS；只有列在允许表里、写明理由和替代证据的分区可以是 BOUNDED（§2.6） |
| `mint` 分区 | 受害者有债时断言查询超时：mint 的自动抵债 `repayX = ceil(min(floor(m·1e18/r), debt)·r/1e18)`，要证 `repayX ≤ m`（非线性 256 位除法）。拆成两半：`debts(v) = 0` 时没有抵债、这一步是线性的，由 `XPNTsV2*MintNoDebtHalmosTest` 在 `mint` 分区证明；`debts(v) > 0` 归结为引理 M（`MintRepayLemma.t.sol`）——Halmos 在它上面同样超时（孤立的算术，甚至拆成三个标准位向量事实也超时，§3.2），所以由纸面证明 + 真实代码路径上的 fuzz（10,000 次）承担 | 这一格是本交付里唯一不是符号证明的环节，结论标为“PASS（模引理 M）” |
| 断言 panic | `--panic-error-codes '*'` | harness 自己的任何 Panic（例如断言里的算术溢出）都算失败，不会让一条路径静默消失 |
| 性能设计 | 快照用 `vm.load` 直接读原始存储槽，谓词全部**无分支**计算（0/1 位运算，受谓词本身保护的 unchecked 算术），一个检查的所有谓词折叠成位掩码 `bad`，只有一个 `assert(bad == 0)` | 避免 harness 自身的 `if`/`&&` 让路径数指数增长（第一版每个选择器 1,259 条路径、10 分钟）。槽位公式在 `D5c1ReplayTest.test_D5c1_layout_*` 里逐一与公开 getter 对照 |

### 2.6 证据绑定与判定（哪些日志算数）

判定只由 `script/halmos/verify-d5c1.py` 给出（编排脚本以它的退出码退出），它只读证据、不重跑，对照**当前树**逐条检查：

| 检查 | 规则 |
|---|---|
| 绑定 | 每份日志开头（运行前）和结尾（Halmos 自己 build 之后）各有一行 `# binding: {json}`（`script/halmos/d5c1_binding.py`）：被测合约源码集合里每个 `contracts/src` 文件的 sha256（手写清单 ∪ 编译器 metadata 里的 import 闭包）、库文件树哈希、harness 树哈希、default profile 的运行时字节码哈希、`out/` 是否就是当前源码的 build（metadata 里的 keccak256 与磁盘文件比对）、`dirty_src`、git head。结尾那一行说了算；开头与结尾在源码 / 库 / harness 上必须一致（运行期间源码没变）。没有绑定行 = UNBOUND，哈希与当前树不同 = STALE，`dirty_src ≠ 0` = DIRTY，都判 MISMATCH，没有豁免 |
| 完整性 | 期望的分区集合**从当前 build 的 ABI 现场生成**（与运行器用的是同一个生成器 `partition_specs`：`OTHER` + 每个非 view 函数一个分区）；目录里的分区日志集合必须**恰好等于**它——少一个、多一个（包括残留的 `.retry.log`）都判 MISMATCH。不分区的日志：日志里出现的 check 集合必须恰好等于期望表列出的集合 |
| 期望 | PASS：每个分区 PASS，只有允许表里的分区可以是 TIMEOUT / TIMEOUT-WALL（报为 BOUNDED，附理由和替代证据）；允许表的键必须是当前存在的分区，且 FAIL 期望（witness / 负对照）**不允许**有允许表。FAIL：至少一个分区 FAIL **且带反例**，没有中止的分区 |
| 墙钟与结果 | 结果行出现在墙钟上限之后（Halmos 的 `[time] total` ≥ 600 s）不算，按 TIMEOUT-WALL 处理；结果与 `Symbolic test result` 汇总都在上限之内打印、只是进程退出阶段被杀的，结果算数并单独列一行说明（本次：I2 core `settleLocked`，见 §3.3） |
| 变异 | 变异日志必须绑定到“当前源码 + 存档的 diff”（在临时副本里重算），`binding-mutated.json` 的字节码与原树不同；恢复后的 `binding-restored.json` 在源码 / 库 / harness / 字节码上与当前树相同；`apply.txt` 的原始文件 sha256 = 恢复后的 sha256 = 当前文件 |
| 期望表 | `script/halmos/d5c1-expectations.json` 的 sha256 打印在每次判定的第一行，并写进 §0 的结果表 |

**判定器自己的对照**（`script/halmos/verify-selftest.py`，日志 `data/halmos/verify-selftest.log`）：在一棵假树（自带 git、源码、harness、带 ABI 与 metadata 的 `out/` 产物）上造出绑定真实的假证据，每个对照只扰动一处，检查退出码；负对照还必须**因为它自己的原因**失败（一个正则必须命中某一条 MISMATCH 行，被别的行弄红不算）。共 29 个：P1/P2/P4 正对照；N1–N23 负对照（分区 FAIL、witness PASS、witness 无反例、TIMEOUT 不在允许表、中止、变异存活、变异未恢复、fuzz 变异存活、未变异 fuzz 变红、缺分区、多分区、源码哈希不符、`dirty_src`、字节码哈希不符、允许表的键不存在、无绑定、残留 retry 日志、变异日志绑定到原树、多出的 check、`out/` 不是当前源码的 build、开头结尾绑定不一致、FAIL 期望带允许表、结果行在墙钟之后）；O1/O2 编排入口；P3 = 真实证据对真实树退出 0。

## 3. 逐项结果

### 3.1 CAP-1（APNTsCapped）

**形式化陈述**。记 `σ` 为 `APNTsCapped` 的任意存储状态，满足 W0（`balanceOf_σ(s) ≤ totalSupply_σ`），`s` 为任意发送者，`d` 为 APNTsCapped ABI 上的任意 calldata（含 view、空 calldata、未知选择器），`σ'` 为执行 `call(s, d)` 之后的状态（revert 时 `σ' = σ`）。则

- (a) `supply(σ') ≤ supply(σ)` 或 `supply(σ') ≤ cap(σ')`；
- (b) `supply(σ') > supply(σ)` ⇒ `sel(d) = mint` 且 `s = minter(σ)`；
- (c) `supply(σ') > supply(σ)` ⇒ `cap(σ') = cap(σ)`。

`lowerCap` 可以把 `cap` 调到 `supply` 以下；此时由 (a)，下一步 `supply` 不可能增加。由 (a)–(c) 对步数归纳：从部署状态（`supply = 0 ≤ cap`）出发，**`totalSupply` 只能经 minter 的 `mint` 增加，并且增加后的值永远不超过当时的 `cap`**。

**Harness**：`contracts/test/halmos/APNTsCappedHalmos.t.sol`，`APNTsCappedHalmosTest.check_CAP1_a_* / _b_* / _c_*`（每条断言各自一个 check，红了就能直接指名）。

**边界与抽象**：全部存储符号化；calldata 覆盖 APNTsCapped 的**全部**选择器（含 view、空 calldata、未知选择器）；`--loop 2`，三个 check 的结果行都是 `bounds: []`（没有任何循环达到展开界）；bytes 长度 `0,65,1024`（`permit` 以外没有动态参数，`transferAndCall(address,uint256,bytes)` 的回调只可能打到已部署合约或空账户）。

**结果：PROVEN（归纳步，对任意前置状态）**。`data/halmos/cap1.log`：(a) PASS，109 条路径，1.93 s；(b) PASS，108 条，3.02 s；(c) PASS，107 条，1.83 s。可达性对照 `check_witness_CAP1_supplyCanIncrease` 按预期 FAIL（`cap1-witness.log`）。

**变异**：M-CAP1（删掉 `mint` 的上限检查）→ 只有 (a) 变红，场景测试变红（§5）。

### 3.2 A-3（xPNTs v2，SP / 历史 SP 为调用方）

**规范**（03 §2.3 A-3、§2.5）：`transferFrom` 与 `burn(address,uint256)` 在 `msg.sender == 当前 SP` 或 `historicalSP[msg.sender]` 时一律拒绝；I6 的余额部分：恶意 SP 对用户余额"只能销毁、不能转走"，烧毁量 ≤ `xc = min(x0, ceil(c·x0/a0))`（§10.2）。

**形式化陈述**。σ 满足 W1–W3（§2.2）；s 满足 `s = SUPERPAYMASTER_ADDRESS(σ)` 或 `historicalSP_σ[s]`；v ≠ s 为任意受害者；d 为 core 或 extension ABI 上的任意规范编码调用（或空 / 未知选择器）；可选地 (v, h) 的记录在本交易内是活的（§2.3）。σ' = 执行后的状态。令 `dec = bal_σ(v) − bal_σ'(v)`，(x0, a0, locker) 为 σ 中 `_locks[h][v]`。

| 位 | 断言 |
|---|---|
| A3-1（bit 0） | `sel = transferFrom` ⇒ 调用失败 |
| A3-2（bit 1） | `sel = burn(address,uint256)` 且 `from ≠ s` ⇒ 调用失败 |
| A3-3（bit 2） | `dec > 0` ⇒ totalSupply 至少减少 `dec`（销毁，不是转走） |
| A3-4（bit 3） | `dec > 0` ⇒ `sel = settleLocked`、`user = v`、`locker = s` |
| A3-5（bit 4） | `dec > 0` ⇒ `dec ≤ x0` |
| A3-6（bit 5） | `dec > 0` ⇒ `lockedOf(v)` 正好减少 x0，记录被删除 |
| A3x（bit 6，单独的 check） | `dec > 0` ⇒ `dec ≤ x0` 且 `dec = 0 ∨ (dec − 1)·a0 < c·x0`，`c = min(charge, a0)`（即 `dec ≤ ceil(c·x0/a0)`） |

说明：代码允许 SP 调 `burn(SP 自己, x)`（`from == msg.sender`，等同 `burn(x)`）——这烧的是 SP 自己的余额，不是第三方路径；A3-2 按规范的意图写成 `from ≠ s`。

**Harness**：`XPNTsV2A3HalmosTest.check_A3_{core,ext}Abi`、`XPNTsV2A3xHalmosTest.check_A3x_exactCeilBound`（只探索 `settleLocked`，A3-4 已证明它是唯一能减少受害者余额的路径）、`XPNTsV2A3MintNoDebtHalmosTest`（`mint` 分区，§2.5）。

**结果：BOUNDED**。`check_A3_coreAbi` PASS（15/15 分区）；`check_A3_extAbi` 43/44 PASS，`mint` 分区 TIMEOUT（300 s 断言上限，71 条路径）——拆开后 `XPNTsV2A3MintNoDebtHalmosTest`（`debts(v) = 0`）PASS，`debts(v) > 0` 归结为引理 M（§7）。A3x（`check_A3x_exactCeilBound`，只探索 `settleLocked`）在 600 s 墙钟上限处 TIMEOUT，替代证据为 `testFuzz_D5c1_I2_settleLocked`（断言 A3x 位掩码，10,000 次）。可达性对照 `check_witness_A3_spSettleBurnsVictim` 给出反例（按预期）。

### 3.3 I2（额度累计 ≤ cap）

**规范**（03 §4 I2）：对任意 (user, spender)，自上次合法重置以来经 `transferFrom`、`burn(from)`、`settleLocked` 的累计 ≤ cap；各 spender 的累计之和 ≤ 总额上限；两次用户亲自操作之间 SP 转述的续期 ≤ K（K = 1）。

**形式化陈述（单步引理）**。σ 满足 W1–W3 与 R；s 任意；v、e（spender 格子）任意；d 任意。位 0–10 见 `XPNTsV2Halmos.t.sol` 中 I2 注释块（I2-1 … I2-9、I4-L），语义见 §7 (a)–(d)。累计性质由 §7 的归纳得到。

**Harness**：`XPNTsV2I2HalmosTest.check_I2_{core,ext}Abi`（以 R 为前置条件）、`XPNTsV2I2NoRHalmosTest`（去掉 R，发现 F-D5c1-1 的符号侧）、`XPNTsV2I2MintNoDebtHalmosTest`、`XPNTsV2RateHalmosTest`（R 的基础情形与归纳步）。

**结果：BOUNDED**。R 的基础情形（`rate-base.log`：`initialize`、真实工厂各 PASS）与归纳步（core 15/15、ext 44/44）全部 PASS。`check_I2_coreAbi` 12/15 PASS，`burn(address,uint256)`、`transferFrom`、`tryLockForGas` 三个分区 TIMEOUT；`check_I2_extAbi` 42/44 PASS，`transferFrom`（600 s 墙钟上限）与 `mint`（300 s 断言上限）TIMEOUT。替代：`D5c1BoundedFuzzTest` 对 `tryLockForGas`、`settleLocked`、`transferFrom`、`burn(from)` 各 10,000 次，断言与 harness 相同的谓词位掩码为 0；`mint` 的 `debts = 0` 变体 PASS。负对照 `XPNTsV2I2NoRHalmosTest`（去掉 R）在 `tryLockForGas` 给出反例——即 F-D5c1-1 在符号侧的样子。可达性对照 `check_witness_I2_spRenewIncrements`、`check_witness_I2_meteredPull` 给出反例（按预期）。

### 3.4 I6（恶意 SP：只能销毁不能转走；新债 ≤ 用户申请上限）

**规范**（03 §4 I6）。余额部分即 A-3（§3.2）。信用部分：(i) 新预留只在当期 epoch 内准入，额度 ≤ `max(0, min(requestedCap, CEILING) − debts − reserved)`；(ii) 失效后不再准入，此前已准入的预留每笔只能转成 ≤ 其 amount 的债务。

**形式化陈述**。σ 满足 W1–W4；s、v 任意；可选地 (v, h) 的信用预留在本交易内是活的。

| 位 | 断言 |
|---|---|
| I6-1（bit 0） | `reserved(v)` 增加 ⇒ `sel = tryReserveCredit`、`s = 当前 SP`、`user = v`、`policy ≠ OFF`、申请的 epoch = 当前 epoch、`debts` 不变、`debts + reserved' ≤ min(requestedCap, CEILING)` |
| I6-2（bit 1） | `debts(v)` 增加 ⇒ `sel = settleCredit`、`user = v`、`locker = s`、增加量 ≤ amount、`reserved` 正好减少 amount、预留被删除 |
| I4-C（bit 2） | `reserved(v)` 只随本调用创建/删除的 (v, h) 预留变化，变化量 = 其 amount |
| I6-J（bit 3，单独的 check） | 前置 `debts + reserved ≤ B` 且 `requestedCap ≤ B`；后置：若 `requestedCap' ≤ B` 则 `debts' + reserved' ≤ B`（任意发送者，含用户本人） |

**Harness**：`XPNTsV2I6HalmosTest.check_I6_{core,ext}Abi`、`check_I6J_{core,ext}Abi`、`XPNTsV2I6MintNoDebtHalmosTest`。

**结果：PROVEN**。`check_I6_coreAbi` 与 `check_I6J_coreAbi` 各 15/15 PASS，`check_I6_extAbi` 与 `check_I6J_extAbi` 各 44/44 PASS（含 `mint` 分区）；`mint` 的 `debts = 0` 变体两者也都 PASS。可达性对照 `check_witness_I6_reservationAdmitted`、`check_witness_I6_debtGrows` 给出反例（按预期）。

## 4. 可达性对照（witness）

"断言绿"可能只是因为断言的前件在这个 harness 里根本到达不了（例如没做 §2.3 的预热，所有结算路径都不可达）。所以每条性质都配了一个**反向**的 witness 检查：它断言"某个前件不可达"，**预期 Halmos 给出反例**。反例 = 该前件可达 = 对应的正向检查不是空洞的。

| witness（Halmos，预期 FAIL） | 证明可达的前件 | 用在 | 具体回放（forge，绿） |
|---|---|---|---|
| `APNTsCappedWitnessHalmosTest.check_witness_CAP1_supplyCanIncrease` | 供应量增加 | CAP-1 (b)(c) | `test_D5c1_CAP1_scenario_mintBeyondCapReverts` 第一步 mint 成功 |
| `XPNTsV2WitnessPinnedHalmosTest.check_witness_A3_spSettleBurnsVictim`（钉住 x0 = a0 = charge = 1e18，见下） | SP 的 settle 真的烧了受害者的币（预热让记录变活） | A-3 bit 2–6 | `test_D5c1_witness_spRenewLockThenSettle` |
| `…check_witness_I2_spRenewIncrements` | SP 续期真的让 `autoRenewUsed` 增加 | I2-3 | 同上第一步 |
| `XPNTsV2WitnessPinnedHalmosTest.check_witness_I2_meteredPull`（钉住汇率 = value = 1e18、显式授权 = 0，见下） | 第三方 spender 真的按自动额度拉走了余额 | I2-7 | `test_D5c1_witness_meteredPull` |
| `…check_witness_I6_reservationAdmitted` | 新预留真的被准入 | I6-1 | `test_D5c1_witness_creditReserveThenSettle` |
| `…check_witness_I6_debtGrows` | 债务真的增加 | I6-2、I6-J | 同上 |

**两个 witness 为什么钉住了取值**：它们的前件都经过 OpenZeppelin `Math.mulDiv`（512 位乘除，分支很多且全是非线性）——`settleLocked` 算 `mulDiv(charge, x0, a0, Ceil)`，`transferFrom` 的计量分支算 `mulDiv(rest, 1e18, rate, Ceil)`。第一次完整运行（harness 修改之前）里，输入全是符号值的这两个 witness 都没有在 10 分钟墙钟内给出反例（两个分区都是 TIMEOUT-WALL；按 §2.6 这就是失败，不能当作"可达"）。witness 只需要**一个**前件实例，所以把 `mulDiv` 的输入钉成具体值（`_extraAssumptions` 按分区的具体选择器决定钉哪些），其余状态（余额、`lockedOf`、locker、各计数与额度、发送者、§2.3 的预热）仍然全是符号值。钉住之后反例在一两分钟内出现（§0 表）。这一改动改变了 harness，于是**所有**日志的 harness 哈希失效，全部检查在新 harness 上重跑了一遍（§0 的数字都来自这次重跑）。钉值只出现在这两个 witness 里，正向检查一个都没有钉。

具体回放不只证明前件可达，还用 `XPNTsV2HalmosProbe` 在同一步上**计算 harness 自己的谓词位掩码**，断言为 0——谓词接受真实行为，不是恒假的。

## 5. 变异

每条性质一个源码变异（`script/halmos/d5c1-mutations.py`：精确文本替换，锚点必须恰好出现一次；`apply` 先保存原文件，`revert` 逐字节恢复并核对 sha256）。每个变异做三件事：

1. 在变异后的源码上跑对应的 Halmos 检查，记录**哪个 check、哪一位断言**变红（位掩码 `bad` 由 `D5C1_BAD` 事件和具体回放给出）；
2. 在变异后的源码上跑 `D5c1ReplayTest` 的对应**场景测试**，它必须变红——证明变异在目标场景里确实改变了行为（Halmos 的红不是抽象造成的假象，绿也不会是"没被扰动"）；
3. `revert` 之后 `git status --porcelain contracts/src` 为空。

变异在树的一份**临时副本**里跑（`script/halmos/run-mutations-all.sh`；副本与主树只差被变异的那一行，`diff` 存档在 `data/halmos/mutations/<ID>/<ID>.diff`），这样主树里同时进行的证据运行永远不会编译到变异后的源码。Halmos 用 `--early-exit`（只需要知道哪一位变红）。

| 变异 | 源码改动 | Halmos：变红的 check（分区） | 变红的断言位（具体回放给出的位掩码） | 场景测试（变异下） | 恢复 |
|---|---|---|---|---|---|
| M-CAP1 | `APNTsCapped.mint` 删掉 `CapExceeded` 检查 | `check_CAP1_a_supplyIncreaseStaysUnderCap` **FAIL**；(b)(c) 仍 PASS（这个变异不影响"谁能铸"和"铸币不动 cap"） | CAP-1 (a) | `test_D5c1_CAP1_scenario_mintBeyondCapReverts`：`next call did not revert as expected`（超出 cap 的 mint 成功了） | sha256 一致 |
| M-A3 | extension 加一个 SP 可调用的 `spPull(from, amount)`（内部 `_transfer`） | `check_A3_extAbi` 分区 `spPull` **FAIL**；`check_A3_coreAbi` 分区 `OTHER` 也 **FAIL**（core ABI 的未知选择器经 fallback 进入 extension，打到新函数） | `28` = bit 2（A3-3：总供应没降，是转走不是销毁）+ bit 3（A3-4：不是 settleLocked）+ bit 4（A3-5：超过 x0） | `test_D5c1_A3_scenario_spCannotMoveUserTokens`：`A-3 predicate bitmask on the SP pull attempt: 28 != 0` | sha256 一致 |
| M-I2 | `_lockDecision` 删掉剩余额度检查 | `check_I2_coreAbi` 分区 `tryLockForGas` **FAIL**（65 条路径，51.7 s；说明：在最终 harness 之前的一次试跑里，同一配置第一次以断言查询 TIMEOUT 结束、重跑才给出反例——求解器超时有不确定性，TIMEOUT 从不被当成 PASS） | `1` = bit 0（I2-1：`used` 超过 cap） | `test_D5c1_I2_scenario_lockBeyondSpCapRejected`：`I2 predicate bitmask on the over-cap lock attempt: 1 != 0` | sha256 一致 |
| M-I6 | `effectiveCreditCap` 忽略用户的 `requestedCap`（改用协议上限） | `check_I6_coreAbi` 与 `check_I6J_coreAbi` 分区 `tryReserveCredit` 均 **FAIL** | `1` = bit 0（I6-1：预留超过 `min(requestedCap, CEILING) − debts`）；I6-J 同样变红 | `test_D5c1_I6_scenario_reservationBoundedByRequestedCap`：`I6 predicate bitmask on the over-request reservation: 1 != 0` | sha256 一致 |
| M-F1 | 删掉 `initialize` 的汇率范围检查（`3c28ec21` 的修复） | `check_RATE_base_initialize`（bit 0）与 `check_RATE_base_realFactory`（bit 2）均 **FAIL** | R 的基础情形 | `test_D5c1_REGRESSION_F1_rateOutOfRangeRejectedAtInit`：`next call did not revert as expected`（另一条 `…maxRateMaxLockIsExact` 仍绿，符合预期：它测的是合法的最大汇率） | sha256 一致 |

**Halmos 的反例怎么回放**：变异下 Halmos 给出的反例（日志里的 `Counterexample:` 块）只列出调用参数和发送者，不列出符号存储；它对应的具体情形由场景测试逐一复现，场景测试在同一步上用 harness 自己的谓词代码（`XPNTsV2HalmosProbe`）算出位掩码——这就是"哪一条断言变红"的具体证据。

## 6. 反例回放

原则：Halmos 给出的**每一个**反例都在 forge 里用具体值回放，然后才下结论。全部回放测试在 `contracts/test/halmos/D5c1Replay.t.sol`（`D5c1ReplayTest`、`D5c1PrimingTest`）与 `MintRepayLemma.t.sol`，都在普通 `forge test` 里运行。

| Halmos 反例 | 结论 | 具体回放 |
|---|---|---|
| `check_I2_extAbi` 分区 `transferFrom`（第一次完整运行，W3 只约束受害者—发送者一对；日志 `data/halmos/spurious/I2-extAbi-transferFrom-before-W3-pairs.log`，4 个反例，均为 `transferFrom(from ≠ 受害者, to = 受害者, value ≥ 2^255 附近)`） | **假反例**（不可达状态）：`from` 与受害者余额之和超过 totalSupply，OZ 给收款方的 `unchecked` 加法回绕 | `test_D5c1_replay_I2_transferFrom_wrapNeedsUnreachableState`：用 `vm.store` 造出 `bal(from) = bal(受害者) = totalSupply = 2^255`，同样的调用让受害者余额回绕为 0，harness 位掩码**恰好是 bit 6**（I2-7），与 Halmos 一致；同一测试断言该状态违反守恒（`bal(受害者) > totalSupply − bal(from)`）。W3 随后加强为两两组合（§2.2） |
| `XPNTsV2I2NoRHalmosTest`（去掉 R；见 §3.3） | **真实**（修复前可达）：发现 F-D5c1-1 | 修复前：`data/halmos/finding-F-D5c1-1-prefix-275abaef-replay.log`（真实工厂、rate `1e40`）；修复后：`test_D5c1_REGRESSION_F1_*` |
| 五个 witness（预期的反例） | 前件可达 | §4 表中的 `test_D5c1_witness_*`（同一步上谓词位掩码 = 0） |
| 五个变异下的反例 | 变异确实改变了目标行为 | §5 表中的场景测试（位掩码指名变红的断言） |
| 引理 M 的第一版 `check_LEMMA_M3`（`(x + 1e18) − 1` 在 harness 里溢出，`--panic-error-codes '*'` 把 harness 自己的 Panic 记为失败） | **harness 缺陷**，不是引理的反例：反例 `x = 2^256 − 1e18` 让 harness 的 checked 加法溢出；合约里同一表达式在同样的输入下会 revert（mint 失败，余额不变）。修正为与合约一致的前提 `x ≤ max − 1e18` | 由算术直接核对：`x = 2^256 − 1e18`，`m = ⌊(2^256−1)/1e18⌋` 满足 `x ≤ m·1e18`，但 `x + 1e18 = 2^256` 溢出（第一版日志保留在 `data/halmos/spurious/lemmaM3-harness-overflow.log`） |

## 7. 从步引理到累计性质（组合论证）

单步引理对任意前置状态成立，所以可以在任意可达轨迹上逐步套用。下面的归纳都从 genesis 出发（新 clone：所有计数、锁、预留、债务为 0）。**这一节是纸面论证，不是 Halmos 的输出**；它用到的每一条引理都标了出处。

**(a) I4（锁这一半）**。前提：不变量 R（汇率 ∈ [1e14, 1e22]、`0 < maxSingleTxLimit ≤ 50,000e18`）由 `XPNTsV2RateHalmosTest` 证明为归纳不变量（基础情形 `initialize`，归纳步覆盖全部选择器），I2 检查以 R 为前置条件；没有 R 时这一步不成立（发现 F-D5c1-1，§F）。由 I4-L（I2 检查 bit 10）：`lockedOf(v)` 只在创建或删除 (v, h) 记录的那一步变化，变化量正好是该记录的 `x0`；由 I2-8 / I2-8b（bit 7、8）：记录只由当前 SP 的 `tryLockForGas` 创建，且从不原地覆盖。对步数归纳：任何时刻 `lockedOf(v) = Σ_{未结清的 (v,·) 记录} x0`。信用这一半同理，用 I4-C（I6 检查 bit 2）：`creditReservedOf(v) = Σ 未结清预留的 amount`。

**(b) 重置时没有未结清的预留**。I2-9（bit 9）：用户续期和 SP 续期都只在 `lockedOf(v) = 0` 且 `creditReservedOf(v) = 0` 时发生；由 (a) 与 I2-8 的最后一项（`a0 > 0 ⇒ x0 > 0`），重置时不存在 `a0 > 0` 的未结清锁（`a0 = 0` 的记录结算额 `c ≤ a0 = 0`）。

**(c) I2（每个 (user, spender) 格子的累计 ≤ cap）**。取一个窗口 W = `_auto[e][v].used` 两次重置之间。在 W 内，`used` 的每次增加都是一次准入（I2-8：创建记录时正好 `+a0`；I2-7：第三方拉取时按自动额度计量），且增加后 `used ≤ 当时生效的 cap`（I2-1）；每次减少都是消费那一条记录时的退款，且不超过 `a0 − c`（结算）或 `a0`（stale release）（I2-5），`c = min(charge, a0)` 正是 `settleLocked` 收取的额度。于是 W 内任意时刻 `used ≥ Σ 已结算的 c + Σ 未结清的 a0 + Σ 计量拉取`（饱和减法只会让左边更大）。设 t* 是 W 内最后一次增加：`used(t*) ≤ cap(t*)`；t* 之后的消费只能来自结算 t* 之前准入的记录，它们的 `c ≤ a0` 已经计入 `used(t*)`。所以 **W 内累计消费 ≤ W 内各次准入时生效的 cap 的最大值**。对 `_budget[v]` 用 I2-2 / I2-6 做同样的论证，得到跨 spender 的总额上界。

**(d) I2 的 K**。I2-3（bit 2）：`autoRenewUsed(v)` 只经当前 SP 的 `spRenew` 锁定增加，且不超过 K；I2-4（bit 3）：只经用户本人的续期（`renewForSelf` 或 R2 `ACT_RENEW`）减少。所以两次用户续期之间 SP 转述的续期 ≤ K = 1。

**(e) I6（恶意 SP）**。
- 余额：A-3（bit 2–5）对**任意**前置状态、当前或历史 SP 发起的任意调用成立：受害者余额只可能经 `settleLocked` 消费受害者自己的、由该 SP 持有的那条记录而减少，totalSupply 至少同额减少（只能销毁、不能转走），且减少量 ≤ x0、`lockedOf` 正好减少 x0、记录被删除；精确上界 `≤ xc = min(x0, ceil(c·x0/a0))` 见 A3x（bit 6）。按锁定路径结算的 aPNTs 总额由 (c)(d) 给出：≤ `min(剩余 SP 额度 + K·SP cap, 剩余总额 + K·总额上限)`。
- 信用：I6-1 / I6-2 是规范 I6 的逐笔形式（新预留只在当期 epoch 由当前 SP 准入，额度 ≤ `min(requestedCap, CEILING) − debts − reserved`；新债只能消费一笔预留，且 ≤ 其 amount）。**累计形式由 I6-J 直接证明，不需要 (a)**：J(B) = `debts(v) + creditReservedOf(v) ≤ B` 在"调用前后 `requestedCap(v) ≤ B`"的条件下被任意调用保持。取 B = 用户历史上申请过的最大上限，从 genesis（0 ≤ B）归纳：**任何时刻用户的信用暴露（债务 + 在途预留）都不超过他本人申请过的最大上限**，与 SP 的实现、分档源、策略、epoch 切换无关。规范 I6(ii) 的"失效后新增债务 ≤ 失效那一刻的 `creditReservedOf`"由 I6-1（失效后不再准入）、I6-2（每笔 ≤ 其 amount 且删除）与 (a) 的信用一半得到。

**仍然依赖、但本交付没有符号证明的环节**：(a) 里“记录由 `(opHash, user)` 唯一标识、删除后不会复活”是 Solidity 映射语义；归纳本身（对步数的求和）是纸面的；`mint` 分区在受害者有债时依赖引理 M（§2.5）。D3 的有状态不变量套件（`xPNTsTokenV2Invariant.t.sol`，I1–I7）在具体轨迹上覆盖了这些组合。

## 8. 局限（供论文附录 X）

1. **性质是 token 侧的**。SuperPaymaster 本身没有被符号执行；A-3 / I6 的上界不依赖 SP 的实现（SP 被当成任意发送者），这正是规范 I6 的"恶意 SP"模型，但 SP 自己的资产（operator 存款、EntryPoint 押金）不在范围内（03 §10.7）。
2. **单步 + 纸面组合**。累计形式的 I2、I4 由 §7 的归纳从逐步引理得到，归纳本身没有机器检查；I6 的信用累计上界（I6-J）是唯一被 Halmos 直接证明的累计性质。
3. **瞬态存储的覆盖**：被调用触及的 (v, h) 记录要么不活、要么活，其余存储任意（§2.3）；同一交易里其他记录的活标记没有枚举（对单步不可观测）。
4. **外部代码**：符号地址只会别名到 harness 部署的合约或空账户；没有覆盖任意恶意外部合约（例如 `transferAndCall` 的接收者、ERC-1271 签名者）在回调里重入 token 的情形。重入者自己的调用是另一个发送者的另一步，单步引理对它同样成立，但"在 `_reentrancyStatus = 2` 且上半截已执行"的中间状态上的调用没有单独枚举（`_reentrancyStatus` 在符号存储里本来就是任意值，这一点部分缓解）。
5. **密码学**：`ecrecover` 是未解释函数，签名可被"伪造"；因此 I2 里 `executeBySig(user = v, ACT_RENEW)` 被当作用户本人的续期（规范 I2 的口径），其现实可靠性依赖 ECDSA / ERC-1271 的不可伪造性。
6. **非线性**：Halmos 对符号乘除做抽象，PASS 在抽象下可靠。两处非线性可能超出求解器能力：A3x 的精确向上取整界（结果见 §3.2）与 `mint` 自动抵债的引理 M（§2.5；纸面证明 + fuzz）。
7. **编译产物**：结论针对 `[profile.default]`（solc 0.8.33、optimizer 500、via-IR、cancun、`bytecode_hash = none`）的字节码，逐字节核对见 §1；其他 profile（`registry-size`，runs 200）的字节码不同，本结论不自动适用。
8. **分档源**：I6 / I6-J 的信用检查把分档源固定为一个返回任意值的合约（W4），没有执行“分档源 revert / 返回畸形数据”那条 fail-closed 代码路径本身（它的结果 0 被覆盖）。
9. **非规范 ABI 编码**：已知选择器配任意参数字节的输入没有探索（Halmos 的 `NotConcreteError`，§2.4）；规范编码已全覆盖。
10. **bytes 长度**：xPNTs 的 bytes/string 参数只取长度 0 与 65（§2.5）。

## 9. 复现
