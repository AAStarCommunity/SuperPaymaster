# D5c-1 · 有界符号验证（Halmos）：CAP-1、A-3、I2（含 I2-F）、I4-B、I6

> **状态（2026-09-16，最终，DSR 已核实）**：全部证据由加固后的判定脚本 `script/halmos/verify-d5c1.py` 判定——**ALL EXPECTATIONS MET（266 行，退出码 0）**，输出存档 `data/halmos/verify-final.txt`。每条日志都绑定到当前源码与字节码（源码集 sha256 + 被测字节码哈希 + `dirty_src = 0`，头尾两次绑定一致），分区集合与当前 ABI 逐一相等；有界（TIMEOUT）只允许出现在`script/halmos/d5c1-expectations.json` 的白名单分区上，每个都写明原因和替代证据。本版在 2026-09-15 的 151 行版本之上补齐了 DSR 要求的两项：**I2-F**（单步性质，§3.3、§7(c)）与 **I4-B**（余额 ≥ 锁定量，§3.5），并把整套证据（含这两项）重跑到最终状态；2026-09-13 暂停前的 RESUME 记录已被本段取代（历史见 git log）。

> 分支 `d5c-1/halmos-token`，基线 `275abaef`（`feat/aoa-balance-mode-5.5.0` 的头）。规范：[03-final-spec.md](03-final-spec.md)（§2.3 A-3、§4 I2/I4/I6、§10.2 的 xc 公式、§10.7b GOV-4）、[apnts-capped-design.md](apnts-capped-design.md)。
> 本交付只加测试和脚本，本身不改 `contracts/src/`（8 个变异都在树的临时副本里做，逐字节恢复并用 sha256 校验，见 §5）。唯一的源码变化是协调方针对本交付发现 F-D5c1-1 的修复 `3c28ec21`（fast-forward 进本分支，§F）。
> 证据登记：[EVIDENCE-INDEX.md](EVIDENCE-INDEX.md) 的 H-01…H-05 行（合入 feat 时登记；S- 前缀已用于规范冻结）；原始日志在 `data/halmos/`。

## 0. 结论

| 性质 | 结论 | 说明 |
|---|---|---|
| **CAP-1**（APNTsCapped 上限） | **PROVEN**（单步归纳，任意前置状态，`bounds: []`） | 3 个 check 全 PASS；witness 按预期给出反例 |
| **R**（汇率 ∈ [1e14, 1e22]，单笔上限 ≤ 50,000e18） | **PROVEN**（基础情形 + 归纳步） | 基础情形：`initialize` 与真实工厂路径（初始汇率取满 `uint256`）；归纳步 core 15/15、ext 44/44 |
| **A-3**（SP / 历史 SP：`from ≠ sender` 才拒绝；只能按记录销毁，见 §F D-A3-2） | **PROVEN**（最终口径）+ 1 项 BOUNDED | `check_A3_coreAbi` 14/15 PASS，`burn` 分区是**已记录的 discrepancy**（不是 TIMEOUT）：D-A3-2 的具体情形，`check_A3_selfBurnDiscrepancy` 按预期 FAIL 复现它；`XPNTsV2A3NoSelfBurnHalmosTest`（最终口径：`from ≠ sender`）该分区独立 PASS。`check_A3_extAbi` 43/44 PASS，`mint` BOUNDED（`debts(v) = 0` 变体 PASS，`debts(v) > 0` 归结为引理 M） |
| **A3x**（精确向上取整界 `dec ≤ ceil(c·x0/a0)`） | **BOUNDED**（`settleLocked` 在 600 s 墙钟上限处 TIMEOUT） | 替代：`D5c1BoundedFuzzTest.testFuzz_D5c1_I2_settleLocked` 断言 A3x 位掩码（10,000 次） |
| **I2**（自动额度累计 ≤ 生效过的最大 cap；**I2-F**：单步增量 ≤ `max(0, cap_now − used)`） | **BOUNDED**：core 11/15、ext 42/44 PASS | TIMEOUT 分区：core `burn(address,uint256)` / `settleLocked` / `transferFrom` / `tryLockForGas`，ext `mint` / `transferFrom`；替代：各自的 10,000 次 fuzz（`D5c1BoundedFuzzTest`，探针已含 I2-F）与 `mint` 的 `debts = 0` 变体 PASS。**I2-F**（bit 15/16）在所有能跑完的分区上成立；变异 M-I2 同时把 bit 0 与 bit 15 弄红（位掩码 32769），是 I2-F 的派生变异覆盖，无需单开 |
| **I4-B**（`balanceOf(u) ≥ lockedOf(u)`，DSR 要求新增） | **BOUNDED**：core 11/15、ext PASS 44/44 | 基础情形（`initialize`、真实工厂）PASS；归纳步 TIMEOUT 分区与 I2 相同的四个 core 分区，替代同上（fuzz 探针同时断言 I4-B 位掩码）。详见 §3.5 |
| **I6 / I6-J**（恶意 SP 只能销毁；新债 ≤ 申请上限） | **PROVEN**（core 15/15、ext 44/44，两者都是） | 含 `mint` 分区 |
| **引理 M**（`mint` 自动抵债不降低收款人余额） | **BOUNDED**（M、M1–M3 都在 540 s 求解器上限处 TIMEOUT） | 唯一不是符号证明的环节：纸面证明（§7）+ 真实代码路径上的 fuzz（`MintRepayLemmaFuzzTest`，10,000 次） |

- **可达性对照**：8 个 witness（含 §3.5 I4-B 的 `check_witness_I4B_outgoingWithLock`、I2 显式额度的 `check_witness_I2_explicitPull`）与 `XPNTsV2I2NoRHalmosTest`（去掉 R 的负对照）都按预期给出反例，说明 harness 不是空洞地通过（§4）。
- **变异**：8 个 Halmos 变异——M-CAP1、M-A3、**M-A3TF**、**M-A3BF**（分别只破坏 transferFrom / burn(from) 防火墙，互不影响，见 §5）、M-I2、**M-I4B**、M-I6、M-F1——都在指名的 check / 分区上给出反例，对应的场景测试变红，源码按 sha256 逐字节恢复；6 个 fuzz 替代证据的变异 M-I2、M-PULL、**M-EXPL**、M-BURNALL、M-REPAY、**M-REPAYLOCK** 都让指名的 fuzz 测试变红，未变异时（正对照）全绿（§5）。
- **发现**：F-D5c1-1（初始汇率不设范围 → `uint128` 截断 → I4 失效）是真实、可达的缺陷，已在 `3c28ec21` 修复并有回归测试与变异 M-F1（§F）；D-A3-2（规范说 SP 的 `burn` 一律拒绝，代码允许 SP 烧自己的余额）经 DSR 与作者核实，规范表述已改（03 v4.1，S-03），A-3 的最终口径见上（§F）。
- **口径**：本交付是**有界符号验证**（bounds 与抽象见 §2.5、§8），不是对全部输入的完整证明；BOUNDED 的分区由写明的 fuzz 或纸面证明替代，论文里按"有界 / 仅 fuzz"如实标注。I2 的口径（排除显式 approve、I2-F、"累计 ≤ 生效过的最大 cap"）已由 DSR 复核确认，写入 03 v4.1（S-03），不再是待定项。

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

### D-A3-2：规范说 SP 的 `burn(address,uint256)` 一律拒绝，代码允许 SP 烧自己的余额（规范—代码不一致；Codex M4 复审时按字面断言后暴露）

| 项 | 内容 |
|---|---|
| 规范 | 03 §2.3 A-3："`transferFrom` 与 `burn(address,uint256)`：当 `msg.sender == 当前 SP` 或 `historicalSP[msg.sender]` 时，不论是否有显式 approve，一律拒绝"；§2.5 权限："`historicalSP` 里的地址永远不能使用 `transferFrom` 和 `burn(from)`" |
| 代码 | `xPNTsTokenV2.sol:134`：`if (msg.sender != from) _spendV2(from, msg.sender, amount, msg.sender);`。防火墙（`SPCannotTransfer`）在 `_spendV2` 里（`:146`），`from == msg.sender` 时整个 `_spendV2` 被跳过，所以当前 SP 或历史 SP 调 `burn(自己, x)` 会成功，效果等同 `burn(uint256)` |
| 怎么发现的 | 按 Codex M4 的要求把 A3-2（bit 1）改成规范的字面形式（不再限定 `from ≠ sender`）。`check_A3_coreAbi` 的 `burn(address,uint256)` 分区随即 FAIL；`check_A3_selfBurnDiscrepancy`（只断言字面 bit 1，限定 `from == sender`）给出反例；`XPNTsV2A3NoSelfBurnHalmosTest`（bit 1 限定为 `from ≠ sender`，其余位不变）在同一分区 PASS——所以字面 A-3 失败的**唯一**方式就是 SP 烧自己的余额 |
| 具体回放 | `D5c1ReplayTest.test_D5c1_DISCREPANCY_A3_2_spBurnsOwnBalance`（绿，记录代码现状）：当前 SP 持有 5 xPNTs，`burn(sp, 1e18)` 成功、totalSupply 同额减少；harness 位掩码恰好是 bit 1（字面 A3-2），NoSelfBurn 位掩码为 0；SP 轮换之后，历史 SP 同样可以烧自己的余额；同一个 SP 对用户调 `burn(user, x)` 仍然 `SPCannotTransfer` |
| 影响 | 没有安全影响：只动 SP 自己的余额，不触及任何第三方，A-3 的目的（SP 不能转走或烧掉用户的币）完整成立（NoSelfBurn 变体 PASS、I6 余额部分不变）。它是规范文字与代码的不一致 |
| 处理 | **没有弱化断言**：`REQUIRED` 把该分区列为 `expect_fail_parts`（必须 FAIL 且带反例），判定表单列一行 "discrepancy"。DSR 与作者已核实并决定：**改规范、不改合约**——03 v4.1（S-03）把 A-3 改为"`from ≠ msg.sender` 时一律拒绝，SP 自烧不受约束"，与代码现状一致；`contracts/src` 未改动 |

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

判定只由 `script/halmos/verify-d5c1.py` 给出（编排脚本以它的退出码退出），它只读证据、不重跑，对照**当前树**逐条检查。下面是 Codex 复审 H3 之后的版本：

| 检查 | 规则 |
|---|---|
| 强制套件 | **要求哪些项写死在 `verify-d5c1.py` 的 `REQUIRED` 里**，不放在可编辑的 `script/halmos/d5c1-expectations.json` 里。JSON 必须逐字重复每一项的固定字段，只额外提供文字（BOUNDED 的理由与替代证据、discrepancy 的说明）；多一项、少一项、改一个字段（例如把 FAIL 期望改成 PASS）都判 MISMATCH。一个分区能不能是 BOUNDED 由 `REQUIRED` 的 `bounded_ceiling` 决定，JSON 只能在这个上限内给理由。所以"从 JSON 里连同证据一起删掉一条性质"会让判定失败。强制套件的 sha256 打印在每次判定的第一行；只有环境变量 `D5C1_REQUIRED`（自检用）能替换它，这时判定行写明 "OVERRIDE … not a release verdict" |
| 日志身份（H3） | 每份日志（分区的、不分区的、变异下的）都由**它自己的**头尾来绑定，不看文件名。运行器在启动 Halmos 之前写 `# meta: {json}`：runner、合约、check、ABI（core/ext）、分区标签、`D5C1_PART` 选择器（必须等于当前 ABI 给这个标签的选择器）、墙钟上限、**完整的 Halmos 参数表**。参数表必须等于 `d5c1_binding.halmos_argv(该项)`：参数只来自 `d5c1_binding.PROFILES` 的固定档（`xp`：`--loop 2 --default-bytes-lengths 0,65 --statistics --solver-timeout-assertion 300000`；`lemma`：`--loop 2 --statistics --solver-timeout-assertion 540000`；`cap1`：`--default-bytes-lengths 0,65,1024`），`--early-exit` **只允许**出现在 FAIL 期望的项上。Halmos 自己打印的 `Running N tests for <文件>:<合约>` 必须是该项的合约，所有结果行必须是该项的 check。所以拷贝到别的分区或别的 check 名下的日志会被拒 |
| 绑定 | 头（运行前）尾（Halmos 自己 build 之后）两行 `# binding:`（`script/halmos/d5c1_binding.py`）：被测源码集合每个文件的 sha256（手写清单 ∪ 编译器 metadata 的 import 闭包）、库树哈希、harness 树哈希、default profile 运行时字节码哈希、`out/` 是否就是当前源码的 build、`dirty_src`。尾行另有 **harness 合约的创建字节码哈希**（Halmos 部署并执行的就是它，§1），必须等于当前 build 里该合约的哈希。头尾在源码 / 库 / harness 上必须一致（运行期间没有改树）。没有绑定 = UNBOUND，哈希不同 = STALE，`dirty_src ≠ 0` = DIRTY，都判 MISMATCH，没有豁免 |
| 退出码与 bounds | `# exit_code:` 必须与结果一致（PASS 0，FAIL / TIMEOUT 1，墙钟杀掉 −9）；PASS 只有在结果行是 `bounds: []`（没有循环达到展开界）时才算 |
| 完整性 | 分区集合从当前 build 的 ABI 现场生成（与运行器用同一个生成器 `partition_specs`），目录里的分区日志集合必须**恰好等于**它。不分区的日志：出现的 check 集合必须恰好等于该项的 check 集合 |
| 期望 | PASS：每个分区 PASS，只有 `bounded_ceiling` 内、JSON 给了理由和替代证据的分区可以是 TIMEOUT / TIMEOUT-WALL（报为 BOUNDED）；`expect_fail_parts` 内的分区**必须** FAIL 且带反例（已记录的规范—代码不一致，§F D-A3-2）。FAIL（witness / 负对照）：至少一个分区 FAIL 且带反例、没有中止，也不允许有 BOUNDED 上限 |
| 墙钟 | 结果行出现在墙钟上限之后（Halmos 的 `[time] total` ≥ 600 s）不算，按 TIMEOUT-WALL 处理；结果与汇总都在上限内打印、只是进程退出阶段被杀的，结果算数并单列一行 |
| 变异 | 变异日志绑定到"当前源码 + 存档 diff"（在临时副本里重算）和变异后的 harness 产物（`binding-mutated.json` 含全部 harness 合约的字节码哈希）；要求变红的分区 FAIL 且带反例，`green_parts`（独立性对照）在变异下仍然 PASS；恢复后的 `binding-restored.json` 与当前树相同；`apply.txt` 的原始 sha256 = 恢复后的 = 当前文件的 |
| 存档（M6） | 强制项：`artifact-parity.log`（两遍，都是 `RESULT: OK`，绑定当前树和 harness 产物）；`verify-selftest.log`（第一行记录被测脚本的 sha256，必须等于当前的 `verify-d5c1.py` / `verify-selftest.py` / `d5c1_binding.py`；最后一行的对照数必须等于 `ok` 行数，也必须等于下面引用的数字）；`forge-halmos-suite.log`（replay / layout / priming / 边界 / fuzz 替代的 forge 套件：全绿、点名的测试都在、绑定当前树）；§3.1 引用的 CAP-1 路径数与时间必须与最终 `cap1.log` 逐字一致 |

**判定器自己的对照**（`script/halmos/verify-selftest.py`，日志 `data/halmos/verify-selftest.log`）共 57 个。做法：在一棵假树上（自带 git、源码、harness 产物、带 ABI 与 metadata 的 `out/` 产物、假的强制套件）造出绑定真实的假证据，每个对照只扰动一处，然后检查退出码；负对照还必须**因为它自己的原因**失败（一个正则必须命中某一条 MISMATCH 行）。正对照：P1（全部满足）、P2（上限内的 TIMEOUT）、P4（上限内打印、退出时被杀）、O2（编排入口）、P3（真实证据对真实树，存档项除外，因为这份日志本身就是存档项）。负对照 N1–N51 与 O1；H3 新增的有：拷贝到别的分区名下的日志（N24）、别的 check 的日志（N25）、错误的 Halmos 参数（N26）、PASS 项带 `--early-exit`（N27）、FAIL 项不带（N28）、Halmos 实际跑的是别的合约（N29）、选择器与 ABI 不符（N30）、墙钟上限不符（N31）、退出码与结果不符（N32）、PASS 但循环达到展开界（N33）、强制项连同证据一起被删（N35）、JSON 多出非强制项（N36）、BOUNDED 超出强制上限（N37）、JSON 改了固定字段（N38）、BOUNDED 缺替代证据（N39）、discrepancy 分区却 PASS（N42）、harness 产物被编译成别的字节码（N22）、尾行点名别的 harness 合约（N23）；M6 新增：存档缺失、parity 只有一遍、自检日志不是当前脚本的、对照数与报告不符、forge 套件不绿、报告引用的 CAP-1 数字与日志不符、parity 日志对应别的 harness build（N44–N51）。

## 3. 逐项结果

### 3.1 CAP-1（APNTsCapped）

**形式化陈述**。记 `σ` 为 `APNTsCapped` 的任意存储状态，满足 W0（`balanceOf_σ(s) ≤ totalSupply_σ`），`s` 为任意发送者，`d` 为 APNTsCapped ABI 上的任意 calldata（含 view、空 calldata、未知选择器），`σ'` 为执行 `call(s, d)` 之后的状态（revert 时 `σ' = σ`）。则

- (a) `supply(σ') ≤ supply(σ)` 或 `supply(σ') ≤ cap(σ')`；
- (b) `supply(σ') > supply(σ)` ⇒ `sel(d) = mint` 且 `s = minter(σ)`；
- (c) `supply(σ') > supply(σ)` ⇒ `cap(σ') = cap(σ)`。

`lowerCap` 可以把 `cap` 调到 `supply` 以下；此时由 (a)，下一步 `supply` 不可能增加。由 (a)–(c) 对步数归纳：从部署状态（`supply = 0 ≤ cap`）出发，**`totalSupply` 只能经 minter 的 `mint` 增加，并且增加后的值永远不超过当时的 `cap`**。

**Harness**：`contracts/test/halmos/APNTsCappedHalmos.t.sol`，`APNTsCappedHalmosTest.check_CAP1_a_* / _b_* / _c_*`（每条断言各自一个 check，红了就能直接指名）。

**边界与抽象**：全部存储符号化；calldata 覆盖 APNTsCapped 的**全部**选择器（含 view、空 calldata、未知选择器）；`--loop 2`，三个 check 的结果行都是 `bounds: []`（没有任何循环达到展开界）；bytes 长度 `0,65,1024`（`permit` 以外没有动态参数，`transferAndCall(address,uint256,bytes)` 的回调只可能打到已部署合约或空账户）。

**结果：PROVEN（归纳步，对任意前置状态）**。`data/halmos/cap1.log`：(a) PASS，108 条路径，1.37 s；(b) PASS，107 条路径，2.26 s；(c) PASS，107 条路径，1.31 s。可达性对照 `check_witness_CAP1_supplyCanIncrease` 按预期 FAIL（`cap1-witness.log`）。

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

**发现 D-A3-2、最终口径（v4.1，见 §F）**：代码允许 SP 调 `burn(SP 自己, x)`（`from == msg.sender`，等同 `burn(x)`）——这烧的是 SP 自己的余额，不是第三方路径。这与"A3-2 一律拒绝"的字面文字不符；DSR 与作者核实后，**改规范不改合约**：A3-2 的最终形式改为 `from ≠ s ⇒ 调用失败`（自烧不受约束）。下表的 A3-2 就是这个最终形式；`XPNTsV2A3HalmosTest`（默认 `_literalBurn() = true`）额外提供**字面**旧文字的断言，用于在 `burn` 分区上具体复现 D-A3-2（预期在那一个分区 FAIL，其余分区仍 PASS），`XPNTsV2A3NoSelfBurnHalmosTest`（`_literalBurn() = false`）是只按最终口径断言的版本。`XPNTsV2A3Bit0HalmosTest` / `XPNTsV2A3Bit1HalmosTest` 把 bit 0、bit 1 拆成独立 check，配合 §5 的 M-A3TF / M-A3BF 证明两条防火墙互相独立。

**Harness**：`XPNTsV2A3HalmosTest.check_A3_{core,ext}Abi`（字面口径，`burn` 分区预期 discrepancy）、`check_A3_selfBurnDiscrepancy`（预期 FAIL，D-A3-2 的具体回放）、`XPNTsV2A3NoSelfBurnHalmosTest.check_A3_coreAbi`（最终口径，`burn` 分区独立 PASS）、`XPNTsV2A3Bit0/Bit1HalmosTest.check_A3_coreAbi`（独立防火墙位）、`XPNTsV2A3xHalmosTest.check_A3x_exactCeilBound`（只探索 `settleLocked`，A3-4 已证明它是唯一能减少受害者余额的路径）、`XPNTsV2A3MintNoDebtHalmosTest`（`mint` 分区，§2.5）。

**结果：最终口径 PROVEN，加 1 项 BOUNDED**。`check_A3_coreAbi`（字面口径）14/15 PASS，`burn-9dc29fac` 分区是**已记录的 discrepancy**——`check_A3_selfBurnDiscrepancy` 按预期 FAIL（`FAIL+cex in burn-9dc29fac`），复现 D-A3-2 的具体反例；`XPNTsV2A3NoSelfBurnHalmosTest.check_A3_coreAbi`（最终口径）该分区 PASS，`XPNTsV2A3Bit0HalmosTest`（`transferFrom`）与 `XPNTsV2A3Bit1HalmosTest`（`burn`，最终口径）各自独立 PASS。`check_A3_extAbi` 43/44 PASS，`mint` 分区 BOUNDED（300 s 断言上限）——拆开后 `XPNTsV2A3MintNoDebtHalmosTest`（`debts(v) = 0`）PASS，`debts(v) > 0` 归结为引理 M（§7）。A3x（`check_A3x_exactCeilBound`，只探索 `settleLocked`）在 600 s 墙钟上限处 TIMEOUT，替代证据为 `testFuzz_D5c1_I2_settleLocked`（断言 A3x 位掩码，10,000 次）。可达性对照 `check_witness_A3_spSettleBurnsVictim` 给出反例（按预期）。

### 3.3 I2（额度累计 ≤ cap）

**规范**（03 §4 I2，v4.1 更正）：对任意 (user, spender)，自上次合法重置以来经 `transferFrom`、`burn(from)`、`settleLocked` 的**自动额度**累计 ≤ 窗口内生效过的最大 cap；各 spender 的累计之和 ≤ 总额上限；两次用户亲自操作之间 SP 转述的续期 ≤ K（K = 1）；用户显式 ERC-20 `approve` 的额度不计入 I2（普通授权，由用户负责；按 A-3 这项排除只与非 SP 的 spender 有关）；**I2-F**：任意一步中 `used_after − used_before ≤ max(0, cap_now − used_before)`（`_auto`、`_budget` 各一份）——这是"调低或撤销额度立刻在下一步生效"这条论文主张的直接依据。

**形式化陈述（单步引理）**。σ 满足 W1–W3 与 R；s 任意；v、e（spender 格子）任意；d 任意。位 0–14 见 `XPNTsV2Halmos.t.sol` 中 I2 注释块（I2-1 … I2-9、I4-L、I2-7E/7A/7U），语义见 §7 (c)(d) 的事实表 S1–S5/E1–E2/P；累计性质由 §7 的归纳得到。

**I2-F 的形式化陈述**：`_i2F(a, b)`（bit 15 = `_auto`、bit 16 = `_budget`）：`b.usedA > a.usedA ⇒ b.usedA − a.usedA ≤ max(0, b.capA − a.usedA)`（`_budget` 同形）。`cap_now` 取步后的 cap：由 bit 0/1 的注释，cap 变化从不与 `used` 增长同一步发生，所以增长时 `a.capA == b.capA`，`cap_now` 用哪一个都一样；这个写法额外覆盖了"cap 在**另一步**已经被调低到 `used` 以下"的边界——此时 `max(0, cap_now − used) = 0`，本步增长必须为 0。

**Harness**：`XPNTsV2I2HalmosTest.check_I2_{core,ext}Abi`（以 R 为前置条件，`_i2()` 调用 `_i2counters | _i2pull | _i2create | _i2reset | _i2F`，I2-F 随主检查一起跑）、`XPNTsV2I2NoRHalmosTest`（去掉 R，发现 F-D5c1-1 的符号侧）、`XPNTsV2I2MintNoDebtHalmosTest`、`XPNTsV2RateHalmosTest`（R 的基础情形与归纳步）。fuzz 替代证据的探针 `XPNTsV2HalmosProbe.i2Bits` 已同步加入 `_i2F`（H3 复核时发现的遗漏，已修，见 §5）。

**结果：BOUNDED**（含 I2-F）。R 的基础情形（`rate-base.log`：`initialize`、真实工厂各 PASS）与归纳步（core 15/15、ext 44/44）全部 PASS。`check_I2_coreAbi` **11/15** PASS，`burn(address,uint256)`、`settleLocked`、`transferFrom`、`tryLockForGas` 四个分区 TIMEOUT；`check_I2_extAbi` 42/44 PASS，`mint`（300 s 断言上限）与 `transferFrom`（600 s 墙钟上限）TIMEOUT。**I2-F（bit 15/16）在全部能跑完的分区上都成立**，包括 TIMEOUT 分区之外的所有 core/ext 选择器。替代：`D5c1BoundedFuzzTest` 对 `tryLockForGas`、`settleLocked`、`transferFrom`、`burn(from)` 各 10,000 次，断言与 harness 相同的谓词位掩码为 0（含 I2-F 的位）；`mint` 的 `debts = 0` 变体 PASS。负对照 `XPNTsV2I2NoRHalmosTest`（去掉 R）在 `tryLockForGas` 给出反例——即 F-D5c1-1 在符号侧的样子。可达性对照 `check_witness_I2_spRenewIncrements`、`check_witness_I2_meteredPull`、`check_witness_I2_explicitPull` 给出反例（按预期）。**I2-F 的变异覆盖**：M-I2（删掉 `tryLockForGas` 的剩余额度检查）在最终 harness 上同时把 bit 0 与 bit 15 弄红（位掩码 32769 = bit 0 | bit 15），说明这一处代码缺陷会同时破坏旧的"used ≤ cap"检查和新的 I2-F 检查，I2-F 因此获得了这个既有变异的派生覆盖，判定脚本的期望消息已同步更新为 `32769 != 0`（原因见对应 commit）。

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

### 3.5 I4-B（`balanceOf(u) ≥ lockedOf(u)`，DSR 要求新增）

**规范依据**（03 §4 I4）：`lockedOf(u)` 是用户 `u` 名下未结清锁定记录的 `xLocked` 之和；这部分余额被 A-1 冻结、不能转出。I4-B 是 I4 的一个必要推论——如果它不成立，`lockedOf` 会把用户的余额记账记到超过其实际持有量，A-1 的"冻结"检查（`balance − locked ≥ transferAmount`）就会对某些应该被允许的转账产生错误的下溢或错误的拒绝。I4-B 本身不是 I4 求和性质的替代，而是 I4 隐含的、可以直接写成单步归纳不变量的下界。

**形式化陈述（基础情形 + 归纳步）**。记 `bal_σ(u)`、`locked_σ(u)` 为状态 σ 中 u 的余额与锁定量。

- **基础情形**：clone 刚被 `initialize`（`check_I4B_base_initialize`，`initRate` 为完整 `uint256` 上的符号值）或经真实工厂路径 `xPNTsFactoryV2.deployxPNTsToken`（`check_I4B_base_realFactory`，`deployRate` 同为符号值）之后，对任意用户 `u`：`bal(u) = 0 = locked(u)`，I4-B 平凡成立。
- **归纳步**（`XPNTsV2I4BHalmosTest.check_I4B_{core,ext}Abi`）：σ 满足 W1–W3 且 `bal_σ(u) ≥ locked_σ(u)`（归纳假设，`_preAssume` 对任意符号用户 `u` 施加）；s 为任意发送者；d 为 core 或 extension ABI 上任意规范编码调用（含预热 `PRIME_LOCK`，§2.3）；σ' 为执行后的状态。断言：`bal_σ'(u) ≥ locked_σ'(u)`（bit 0，`_i4bbits`）。

由基础情形 + 归纳步对步数归纳：**从部署状态出发，任意长度的交易序列之后，每个用户的余额始终不低于其被锁定的量**——这正是 A-1 冻结检查不会因为记账错误而产生下溢或误判所依赖的前提。

**Harness**：`XPNTsV2I4BHalmosTest.check_I4B_{core,ext}Abi`（归纳步）、`check_I4B_base_initialize` / `check_I4B_base_realFactory`（基础情形，见 `contracts/test/halmos/XPNTsV2Halmos.t.sol:844-896`）、`XPNTsV2I4BMintNoDebtHalmosTest`（`mint` 分区、`debts(v) = 0` 的线性半边，§2.5 同款拆分）。

**结果：BOUNDED**。基础情形两个 check（`i4b-base.log`）均 PASS。归纳步 `check_I4B_coreAbi` **11/15** PASS，`burn(address,uint256)`、`settleLocked`、`transferFrom`、`tryLockForGas` 四个分区 TIMEOUT-WALL（与 I2 完全相同的四个分区，同样源于 `mulDiv` 的非线性求解代价）；`check_I4B_extAbi` **PASS 44/44**（`mint`、`transferFrom` 两个原本预期的上限分区实际都在时限内求解完成）；`XPNTsV2I4BMintNoDebtHalmosTest` 的 `mint` 分区 PASS（1/1）。替代：`D5c1BoundedFuzzTest` 对 `tryLockForGas`、`settleLocked`、`transferFrom`、`burn(from)` 各 10,000 次，断言与 harness 相同的谓词位掩码（含 I4-B 的 bit 0）为 0；`testFuzz_D5c1_I4B_mintWithDebt` 单独覆盖 `mint` 有债路径（10,000 次，PASS）。可达性对照 `check_witness_I4B_outgoingWithLock` 给出反例（按预期，见 §4）：v 持有锁定记录时，v 自己发起的一次调用真的能让余额减少（说明"归纳步"不是因为"余额永不减少"而空洞成立）。

**变异覆盖**：M-I4B（见 §5）在 `check_I4B_coreAbi` 的 `transfer` 分区上给出反例（`red ['transfer-a9059cbb']`），证明 I4-B 这条不变量确实依赖对应的代码检查，不是恒真的谓词。

## 4. 可达性对照（witness）

"断言绿"可能只是因为断言的前件在这个 harness 里根本到达不了（例如没做 §2.3 的预热，所有结算路径都不可达）。所以每条性质都配了一个**反向**的 witness 检查：它断言"某个前件不可达"，**预期 Halmos 给出反例**。反例 = 该前件可达 = 对应的正向检查不是空洞的。

| witness（Halmos，预期 FAIL） | 证明可达的前件 | 用在 | 具体回放（forge，绿） |
|---|---|---|---|
| `APNTsCappedWitnessHalmosTest.check_witness_CAP1_supplyCanIncrease` | 供应量增加 | CAP-1 (b)(c) | `test_D5c1_CAP1_scenario_mintBeyondCapReverts` 第一步 mint 成功 |
| `XPNTsV2WitnessPinnedHalmosTest.check_witness_A3_spSettleBurnsVictim`（钉住 x0 = a0 = charge = 1e18，见下） | SP 的 settle 真的烧了受害者的币（预热让记录变活） | A-3 bit 2–6 | `test_D5c1_witness_spRenewLockThenSettle` |
| `…check_witness_I2_spRenewIncrements` | SP 续期真的让 `autoRenewUsed` 增加 | I2-3 | 同上第一步 |
| `XPNTsV2WitnessPinnedHalmosTest.check_witness_I2_meteredPull`（钉住汇率 = value = 1e18、显式授权 = 0，见下） | 第三方 spender 真的按自动额度拉走了余额 | I2-7 | `test_D5c1_witness_meteredPull` |
| `XPNTsV2WitnessHalmosTest.check_witness_I2_explicitPull`（其余状态仍全符号；只在 `transferFrom` 分区上额外假设 `explicitAllow ≥ value`，收窄到显式授权分支，避开 mulDiv 分支——不钉具体数值，与下面两个"钉住取值"的 witness 不同） | 第三方 spender 真的靠**显式** ERC-20 授权拉走了余额（bit 11 的前件） | I2-7E | 无独立 forge 场景；Halmos 反例本身给出满足前件的具体赋值（`FAIL+cex in transferFrom-23b872dd`） |
| `…check_witness_I4B_outgoingWithLock` | v 持有锁定记录时，v 自己发起的调用真的能让余额减少 | I4-B | 无独立 forge 场景；Halmos 反例本身给出满足前件的具体赋值（`FAIL+cex in transfer-a9059cbb`） |
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
| M-A3TF | `transferFrom` 的 SP 防火墙加一个 `!historicalSP[msg.sender]` 豁免（只影响 transferFrom 这一条通道） | `XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi` 分区 `transferFrom` **FAIL**；`XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi` 分区 `burn` 仍 **PASS**（独立性对照：这个变异不影响 burn 通道） | `1` = bit 0（A3-1：transferFrom 应当失败却成功了） | `test_D5c1_A3_scenario_spFirewallBits`：`A-3 firewall bits (bit0 transferFrom, bit1 burn(from)): 1 != 0` | sha256 一致 |
| M-A3BF | `burn(address,uint256)` 的防火墙条件从 `from ≠ sender` 加一个 `&& !historicalSP[msg.sender]` 豁免（只影响 burn(from) 这一条通道） | `XPNTsV2A3Bit1HalmosTest.check_A3_coreAbi` 分区 `burn` **FAIL**；`XPNTsV2A3Bit0HalmosTest.check_A3_coreAbi` 分区 `transferFrom` 仍 **PASS**（独立性对照） | `2` = bit 1（A3-2：`from ≠ sender` 的 burn 应当失败却成功了） | `test_D5c1_A3_scenario_spFirewallBits`：`A-3 firewall bits (bit0 transferFrom, bit1 burn(from)): 2 != 0` | sha256 一致 |
| M-I2 | `_lockDecision` 删掉剩余额度检查 | `check_I2_coreAbi` 分区 `tryLockForGas` **FAIL**（65 条路径，51.7 s；说明：在最终 harness 之前的一次试跑里，同一配置第一次以断言查询 TIMEOUT 结束、重跑才给出反例——求解器超时有不确定性，TIMEOUT 从不被当成 PASS） | `32769` = bit 0（I2-1：`used` 超过 cap）+ bit 15（I2-F：单步增量超过 `max(0, cap_now − used)`，见 §3.3） | `test_D5c1_I2_scenario_lockBeyondSpCapRejected`：`I2 predicate bitmask on the over-cap lock attempt: 32769 != 0` | sha256 一致 |
| M-I4B | `xPNTsV2Base._update` 删掉 A-1 的锁定检查（`bal < value \|\| bal − value < locked` revert） | `check_I4B_coreAbi` 分区 `transfer` **FAIL** | `1` = bit 0（I4-B：转账后余额低于锁定量却没有被拒绝） | `test_D5c1_I4B_scenario_transferBelowLockedRejected`：`I4-B predicate bitmask on the over-lock transfer: 1 != 0` | sha256 一致 |
| M-I6 | `effectiveCreditCap` 忽略用户的 `requestedCap`（改用协议上限） | `check_I6_coreAbi` 与 `check_I6J_coreAbi` 分区 `tryReserveCredit` 均 **FAIL** | `1` = bit 0（I6-1：预留超过 `min(requestedCap, CEILING) − debts`）；I6-J 同样变红 | `test_D5c1_I6_scenario_reservationBoundedByRequestedCap`：`I6 predicate bitmask on the over-request reservation: 1 != 0` | sha256 一致 |
| M-F1 | 删掉 `initialize` 的汇率范围检查（`3c28ec21` 的修复） | `check_RATE_base_initialize`（bit 0）与 `check_RATE_base_realFactory`（bit 2）均 **FAIL** | R 的基础情形 | `test_D5c1_REGRESSION_F1_rateOutOfRangeRejectedAtInit`：`next call did not revert as expected`（另一条 `…maxRateMaxLockIsExact` 仍绿，符合预期：它测的是合法的最大汇率） | sha256 一致 |

**Halmos 的反例怎么回放**：变异下 Halmos 给出的反例（日志里的 `Counterexample:` 块）只列出调用参数和发送者，不列出符号存储；它对应的具体情形由场景测试逐一复现，场景测试在同一步上用 harness 自己的谓词代码（`XPNTsV2HalmosProbe`）算出位掩码——这就是"哪一条断言变红"的具体证据。

## 6. 反例回放

原则：Halmos 给出的**每一个**反例都在 forge 里用具体值回放，然后才下结论。全部回放测试在 `contracts/test/halmos/D5c1Replay.t.sol`（`D5c1ReplayTest`、`D5c1PrimingTest`）与 `MintRepayLemma.t.sol`，都在普通 `forge test` 里运行。

| Halmos 反例 | 结论 | 具体回放 |
|---|---|---|
| `check_I2_extAbi` 分区 `transferFrom`（第一次完整运行，W3 只约束受害者—发送者一对；日志 `data/halmos/spurious/I2-extAbi-transferFrom-before-W3-pairs.log`，4 个反例，均为 `transferFrom(from ≠ 受害者, to = 受害者, value ≥ 2^255 附近)`） | **假反例**（不可达状态）：`from` 与受害者余额之和超过 totalSupply，OZ 给收款方的 `unchecked` 加法回绕 | `test_D5c1_replay_I2_transferFrom_wrapNeedsUnreachableState`：用 `vm.store` 造出 `bal(from) = bal(受害者) = totalSupply = 2^255`，同样的调用让受害者余额回绕为 0，harness 位掩码**恰好是 bit 6**（I2-7），与 Halmos 一致；同一测试断言该状态违反守恒（`bal(受害者) > totalSupply − bal(from)`）。W3 随后加强为两两组合（§2.2） |
| `XPNTsV2I2NoRHalmosTest`（去掉 R；见 §3.3） | **真实**（修复前可达）：发现 F-D5c1-1 | 修复前：`data/halmos/finding-F-D5c1-1-prefix-275abaef-replay.log`（真实工厂、rate `1e40`）；修复后：`test_D5c1_REGRESSION_F1_*` |
| 8 个 witness（预期的反例） | 前件可达 | §4 表中的 `test_D5c1_witness_*` 或 Halmos 反例自身给出的具体赋值（同一步上谓词位掩码 = 0） |
| 8 个变异下的反例 | 变异确实改变了目标行为 | §5 表中的场景测试（位掩码指名变红的断言） |
| 引理 M 的第一版 `check_LEMMA_M3`（`(x + 1e18) − 1` 在 harness 里溢出，`--panic-error-codes '*'` 把 harness 自己的 Panic 记为失败） | **harness 缺陷**，不是引理的反例：反例 `x = 2^256 − 1e18` 让 harness 的 checked 加法溢出；合约里同一表达式在同样的输入下会 revert（mint 失败，余额不变）。修正为与合约一致的前提 `x ≤ max − 1e18` | 由算术直接核对：`x = 2^256 − 1e18`，`m = ⌊(2^256−1)/1e18⌋` 满足 `x ≤ m·1e18`，但 `x + 1e18 = 2^256` 溢出（第一版日志保留在 `data/halmos/spurious/lemmaM3-harness-overflow.log`） |

## 7. 从步引理到累计性质（组合论证）

单步引理对任意前置状态成立，所以可以在任意可达轨迹上逐步套用。下面的归纳都从 genesis 出发（新 clone：所有计数、锁、预留、债务为 0）。**这一节是纸面论证，不是 Halmos 的输出**；它用到的每一条引理都标了出处。

**(a) I4**。
- 锁这一半：前提是不变量 R（汇率 ∈ [1e14, 1e22]、`0 < maxSingleTxLimit ≤ 50,000e18`），它由 `XPNTsV2RateHalmosTest` 证明为归纳不变量（基础情形 `initialize` 与真实工厂，归纳步覆盖全部选择器），I2 检查以 R 为前置条件；没有 R 时这一步不成立（发现 F-D5c1-1，§F）。由 I4-L（I2 检查 bit 10）：`lockedOf(v)` 只在创建或删除 (v, h) 记录的那一步变化，变化量正好是该记录的 `x0`；由 I2-8 / I2-8b（bit 7、8）：记录只由当前 SP 的 `tryLockForGas` 创建，且从不原地覆盖。对步数归纳：任何时刻 `lockedOf(v) = Σ_{未结清的 (v,·) 记录} x0`。
- 信用这一半同理，用 I4-C（I6 检查 bit 2）：`creditReservedOf(v) = Σ 未结清预留的 amount`。
- **余额这一半（H2 新增）**：`balanceOf(u) ≥ lockedOf(u)` 本身就是 Halmos 证明的归纳不变量，不需要求和：基础情形 `check_I4B_base_initialize` / `check_I4B_base_realFactory`（部署之后对任意 u 成立），归纳步 `check_I4B_{core,ext}Abi`（任意前置状态满足 `bal(v) ≥ locked(v)`、任意发送者、全部选择器，含预热后的 `settleLocked` 与 mint 的自动抵债）。归纳步里 BOUNDED 的分区见 §3.5，由写明的替代证据承担。

**(b) 重置时没有未结清的预留**。I2-9（bit 9）：用户续期和 SP 续期都只在 `lockedOf(v) = 0` 且 `creditReservedOf(v) = 0` 时发生；由 (a) 与 I2-8 的最后一项（`a0 > 0 ⇒ x0 > 0`），重置时不存在 `a0 > 0` 的未结清锁（`a0 = 0` 的记录结算额 `c ≤ a0 = 0`）。

**(c) I2（口径已由 DSR 复核确认，写入 03 v4.1 S-03；见 §3.3 I2-F）**。I2 只约束**自动额度**；用户显式 `approve` 的额度是普通的 ERC-20 授权，不在 I2 之内，但单独断言它的两件事。用到的逐步事实（全部是 `check_I2_{core,ext}Abi` 的位，Halmos 在 §3.3 的分区上证明，其余分区由写明的 fuzz 替代）：

| 事实 | 位 | 内容 |
|---|---|---|
| S1 | 0、1 | `_auto[e][v].used`（`_budget[v].used`）在一步里增加时，增加后的值 ≤ 这一步**之前和之后**的 cap（同一步里不会既改 cap 又增加 used） |
| S2 | 13 | `used` 只经准入增加：当前 SP 为 v 的 `tryLockForGas`（只记在 SP 自己的格子上），或 e 对 v 的 `transferFrom` / `burn(from)` |
| S3 | 7、12 | 每次准入按它的 aPNTs 额计入：锁定正好 `+a0`（格子与总额）；拉取在显式额度之外的部分 `rest` 以同一个 `du` 计入格子与总额，`du · rate ≥ rest · 1e18`（即 `du ≥ rest` 的 aPNTs 价值） |
| S4 | 4、5 | `used` 只经三种方式减少：用户续期、SP 续期（SP 格子）、消费 e 持有的那条 (v, h) 记录时的退款，退款 ≤ `a0 − c`（结算，`c = min(charge, a0)` 就是 `settleLocked` 收取的额度）或 `a0`（stale release） |
| S5 | 9 | 重置（用户或 SP 续期）只在 `lockedOf(v) = creditReservedOf(v) = 0` 时发生，见 (b) |
| E1 | 11 | 显式额度覆盖的拉取（`value ≤ E`）正好从显式额度扣掉 `value`（无限授权保持无限），而且**不碰**自动计数 |
| E2 | 14 | `_allowances[v][e]` 只能由 v 自己提高（v 的 `approve`，或 owner 为 v 的 `permit`） |
| P | 6 | 第三方让 v 余额减少（结算除外）只能经 v 的 `transferFrom` / `burn(from)`，减少量 ≤ 其 value |

论证。取一个窗口 W = 某个 (v, e) 格子两次合法重置之间。W 内 `used` 的每次增加都是一次准入（S2），按准入额计入（S3）；每次减少都是 S4 的退款，不超过对应记录"准入额 − 实际收取"。于是 W 内任意时刻 `used ≥ Σ 已结算记录的 c + Σ 未结清记录的 a0 + Σ 拉取的 du`（S4 用的是饱和减法，只会让左边更大）。设 t* 是 W 内最后一次增加：由 S1，`used(t*) ≤ cap(t*)`，这里 `cap(t*)` 是 t* 那一步之前与之后生效的 cap 中较小的一个。t* 之后的消费只能来自结算 t* 之前准入的记录，它们的 `c ≤ a0` 已经计入 `used(t*)`。所以：

> **W 内经自动额度的累计消费 ≤ cap(t*) ≤ W 内（即自上次合法重置以来）曾经生效过的 cap 的最大值。**

它不是"≤ 当前 cap"：调低 cap 不会重置 `used`，t* 之后调低的 cap 可以低于已经准入、仍在结清中的额度（03 v4.1 已按此改写"累计 ≤ 窗口内生效过的最大 cap"）。显式额度那一半：由 E1，W 内经显式额度的消费正好是 E 被扣减的量，从不超过 v 当时授予的额度；由 E2，这个额度只能由 v 自己提高；由 P，第三方拉走的余额恰好是这两部分之和的上界。对 `_budget[v]` 用同样的 S1–S4 得到跨 spender 的总额上界。

**I2-F 与 S1 的关系**：S1（bit 0、1）本身就是"同一步里 `used` 增加时 ≤ 该步前后的 cap"这条单步事实；**I2-F**（§3.3，bit 15/16）是它的字面单步形式 `used_after − used_before ≤ max(0, cap_now − used_before)`，直接可以对论文读者陈述为"调低或撤销额度在下一步立即生效"，不需要经过上面 W 窗口的组合论证——I2-F 已经是 Halmos 直接证明的归纳性质（BOUNDED 分区除外），(c) 的窗口论证只是从它推出**累计**上界，两者不是重复而是一个是逐步事实、一个是累计推论。

**(d) I2 的 K**。I2-3（bit 2）：`autoRenewUsed(v)` 只经当前 SP 的 `spRenew` 锁定增加，且不超过 K；I2-4（bit 3）：只经用户本人的续期（`renewForSelf` 或 R2 `ACT_RENEW`）减少。所以两次用户续期之间 SP 转述的续期 ≤ K = 1。

**(e) I6（恶意 SP）**。
- 余额：A-3（bit 2–5）对**任意**前置状态、当前或历史 SP 发起的任意调用成立：受害者余额只可能经 `settleLocked` 消费受害者自己的、由该 SP 持有的那条记录而减少，totalSupply 至少同额减少（只能销毁、不能转走），且减少量 ≤ x0、`lockedOf` 正好减少 x0、记录被删除；精确上界 `≤ xc = min(x0, ceil(c·x0/a0))` 见 A3x（bit 6）。SP 用 `burn(from = 自己, x)` 烧的是它自己的余额（D-A3-2，§F），不影响任何第三方。按锁定路径结算的 aPNTs 总额由 (c)(d) 给出：≤ `min(剩余 SP 额度 + K·SP cap, 剩余总额 + K·总额上限)`，其中"SP cap"按 (c) 取自上次重置以来生效过的最大值。
- 信用：I6-1 / I6-2 是规范 I6 的逐笔形式（新预留只在当期 epoch 由当前 SP 准入，额度 ≤ `min(requestedCap, CEILING) − debts − reserved`；新债只能消费一笔预留，且 ≤ 其 amount）。**累计形式由 I6-J 直接证明，不需要 (a)**：J(B) = `debts(v) + creditReservedOf(v) ≤ B` 在"调用前后 `requestedCap(v) ≤ B`"的条件下被任意调用保持。取 B = 用户历史上申请过的最大上限，从 genesis（0 ≤ B）归纳：**任何时刻用户的信用暴露（债务 + 在途预留）都不超过他本人申请过的最大上限**，与 SP 的实现、分档源、策略、epoch 切换无关。规范 I6(ii) 的"失效后新增债务 ≤ 失效那一刻的 `creditReservedOf`"由 I6-1（失效后不再准入）、I6-2（每笔 ≤ 其 amount 且删除）与 (a) 的信用一半得到。

**仍然依赖、但本交付没有符号证明的环节**：(a) 里"记录由 `(opHash, user)` 唯一标识、删除后不会复活"是 Solidity 映射语义；归纳本身（对步数的求和）是纸面的；`mint` 分区在受害者有债时依赖引理 M（§2.5）；BOUNDED 分区上的步引理由 fuzz 承担（§3）。D3 的有状态不变量套件（`xPNTsTokenV2Invariant.t.sol`，I1–I7）在具体轨迹上覆盖了这些组合。

## 8. 局限（供论文附录 X）

1. **性质是 token 侧的**。SuperPaymaster 本身没有被符号执行；A-3 / I6 的上界不依赖 SP 的实现（SP 被当成任意发送者），这正是规范 I6 的"恶意 SP"模型，但 SP 自己的资产（operator 存款、EntryPoint 押金）不在范围内（03 §10.7）。
2. **单步 + 纸面组合**。累计形式的 I2、I4（前两个等式）由 §7 的归纳从逐步引理得到，归纳本身没有机器检查。被 Halmos 直接证明为归纳不变量的只有：R、I6-J（信用累计上界）、I4 的余额一半 `balanceOf ≥ lockedOf`（基础情形 + 归纳步，BOUNDED 分区除外）。
3. **I2 的口径（已由 DSR 复核确认，写入 03 v4.1 S-03）**：本交付证明的是"**自动额度**的累计消费 ≤ 自上次合法重置以来生效过的 cap 的最大值"（§7 (c)），加上单步形式 **I2-F**（§3.3）；显式 ERC-20 授权的消费不计入 I2，单独证明它只从显式额度扣、只能由用户本人提高。03 §4 I2 的正文已按这三点改写（v4.1，见 03-final-spec.md 的勘误段落）。
4. **规范—代码不一致 D-A3-2**（§F）：A-3 的字面规则没有被弱化，对应分区按预期 FAIL；它不影响任何第三方余额，DSR 与作者已核实并决定改规范（不改合约），最终口径见 03 v4.1、§3.2。
5. **瞬态存储的覆盖**：被调用触及的 (v, h) 记录要么不活、要么活，其余存储任意（§2.3）；同一交易里其他记录的活标记没有枚举（对单步不可观测）。
6. **外部代码**：符号地址只会别名到 harness 部署的合约或空账户；没有覆盖任意恶意外部合约（例如 `transferAndCall` 的接收者、ERC-1271 签名者）在回调里重入 token 的情形。重入者自己的调用是另一个发送者的另一步，单步引理对它同样成立，但"在 `_reentrancyStatus = 2` 且上半截已执行"的中间状态上的调用没有单独枚举（`_reentrancyStatus` 在符号存储里本来就是任意值，这一点部分缓解）。
7. **密码学**：`ecrecover` 是未解释函数，签名可被"伪造"；因此 I2 里 `executeBySig(user = v, ACT_RENEW)` 被当作用户本人的续期、`permit(owner = v, …)` 被当作用户本人的授权（I2-7U），其现实可靠性依赖 ECDSA / ERC-1271 的不可伪造性。
8. **非线性**：Halmos 对符号乘除做抽象，PASS 在抽象下可靠。超出求解器能力、由写明的 fuzz 或纸面证明承担的环节：A3x 的精确向上取整界、`mint` 自动抵债的引理 M（§2.5）、以及 `mulDiv` 所在的锁定 / 结算 / 计量拉取分区（§3 各表的 BOUNDED 行）。fuzz 替代的输入域见 §3.6（M5）：汇率只取已证明的 R，其余输入覆盖整个类型。
9. **编译产物**：结论针对 `[profile.default]`（solc 0.8.33、optimizer 500、via-IR、cancun、`bytecode_hash = none`）的字节码，逐字节核对见 §1；其他 profile（`registry-size`，runs 200）的字节码不同，本结论不自动适用。
10. **分档源**：I6 / I6-J 的信用检查把分档源固定为一个返回任意值的合约（W4），没有执行"分档源 revert / 返回畸形数据"那条 fail-closed 代码路径本身（它的结果 0 被覆盖）。
11. **非规范 ABI 编码**：已知选择器配任意参数字节的输入没有探索（Halmos 的 `NotConcreteError`，§2.4）；规范编码已全覆盖。
12. **bytes 长度**：xPNTs 的 bytes/string 参数只取长度 0 与 65（§2.5）。
13. **witness 的前置限制**：`check_witness_A3_spSettleBurnsVictim`、`check_witness_I2_meteredPull` 把 `mulDiv` 的输入钉成具体值，`check_witness_I2_explicitPull` 把前置状态限制为 `E ≥ value`（§4）。witness 只需要一个前件实例，这些限制只出现在 witness 里，正向检查一个都没有。

## 9. 复现

全部命令在仓库根目录执行，`export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"`。

```bash
# 1. Halmos 证据（先做一次带 AST 的构建；每个分区 600 s 墙钟上限，参数只来自固定档）
script/halmos/run-all-d5c1.sh all 6          # 或分组：cap1 rate a3 i2 i4b i6 mint lemma settle witness
# 2. 变异（在树的临时副本里跑，主树的证据运行永远不会编译变异后的源码）
rsync -a contracts singleton-paymaster standards foundry.toml foundry.lock out cache script <copy>/
(cd <copy> && script/halmos/run-mutations-all.sh $PWD/docs/design/aoa-balance-mode/data/halmos/mutations)
# 3. fuzz 替代的活性（在 git 检出里，源码干净时）
script/halmos/run-fuzz-liveness.sh docs/design/aoa-balance-mode/data/halmos/fuzz-liveness
# 4. 存档：artifact parity 两遍、halmos 目录的 forge 套件、判定器自检
script/halmos/archive-d5c1.sh all
# 5. 判定（唯一的判定者）
python3 script/halmos/verify-d5c1.py --markdown docs/design/aoa-balance-mode/data/halmos/verify-final.md \
  > docs/design/aoa-balance-mode/data/halmos/verify-final.txt
```
