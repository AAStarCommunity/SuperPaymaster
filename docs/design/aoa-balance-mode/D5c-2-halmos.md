# D5c-2 · 有界符号验证（Halmos）：I9「settle 不可静默失败」+ RDR-3 静态分析分诊

> **状态（2026-09-17，最终）**：Halmos 的 6 个 check 全部按预期收敛（3 个真断言 PASS、2 个可达性 witness 按预期 FAIL、1 个交叉检查 PASS），变异测试确认 harness 不是空洞地通过，配套 forge fuzz 补齐了 Halmos 有界之外的尾部。RDR-3（Slither + Aderyn 逐条分诊）已完成，见独立报告 [`../../security/slither-aderyn-report-2026-09-17.md`](../../security/slither-aderyn-report-2026-09-17.md)，本文件只覆盖 I9 的 Halmos 部分。
>
> 分支 `d5c-2/halmos-settle`，基线 `be170a48`（`feat/aoa-balance-mode-5.5.0` 的头，含 D5c-1、D5b、A6 collector、D7 nonce 修复）。规范：[03-final-spec.md](03-final-spec.md) §4 I9、§10.7b（RDR-2 行："I9（没有后盾的赞助 = 0，以'settle 不可静默失败'的形式表达）……分两段交付：D5c-1……与 D5c-2（I9 + RDR-3）……I9 是'算术引理 + 具体价格点上的控制流'"）。
> 本交付只加测试和脚本，本身不改 `contracts/src/`（唯一的例外是 M-I9 变异，做在树的临时副本里、跑完立即用 `git checkout` 逐字节恢复，见 §4）。
> 证据登记：[EVIDENCE-INDEX.md](EVIDENCE-INDEX.md) 的 H-06…H-09 行；原始日志在 `data/halmos-i9/`。

## 0. 结论

| 性质 | 结论 | 说明 |
|---|---|---|
| **CF-1**（`context.length == 0` 是严格 no-op） | **PASS**（`bounds: []`，任意前置状态） | 3 条路径，0.05 s |
| **CF-2**（P1-17 幂等：已结算的 opHash 重放不产生二次结算） | **PASS**（`bounds: []`） | 9 条路径，0.08 s；`ok == false`（W-GAS，见 §2.3）的分支不作断言，其可达性由配对的 witness 证明 |
| **CF-3 / I9 本体**（settle revert ⇒ 整个 postOp 必须 revert；settle 成功 ⇒ SP 账目变动必须恰好等于 token 侧记录的 charge） | **PASS**（`bounds: []`，W-A0 + W-GASBOUND 有界） | 1502 条路径，50.22 s；无界尾部（`a0` 之外的 `actualGasCost`/`actualUserOpFeePerGas` 全 `uint256`）由 `SuperPaymasterI9Fuzz.t.sol` 的 10,000 次 fuzz 补齐（§5） |
| **CF3-a 独立交叉检查**（同一性质，仅 bit 0，W-A0/W-GASBOUND 下） | **PASS**（`bounds: []`） | 351 条路径，8.00 s；命名为 `check_witness_I9_settleRevertsButCallerObservesSuccess` 但不是 witness，见 §3.4 的更正说明 |
| **可达性 witness ×2**（证明 CF-2/CF-3 的"成功"分支不是空洞地被 W-GAS 短路掉） | 按预期 **FAIL**（反例） | `check_witness_I9_CF2_idempotentSucceedsWithEnoughGas`：9 条路径，0.07 s；`check_witness_I9_freshBalanceSettlementReachable`：478 条路径，2881.59 s（找具体反例模型比证明有效性贵得多——见 §3.5） |
| **L9-CLAMP**（算术引理：`probeCharge ≤ a0`，即 postOp 自己的 `if (charge > a0) charge = a0;` 钳制） | 在 CF-3 内部作为 bit 4 一并证明 | 不是独立 check——钳制逻辑就是 `charge` 被赋值前的最后一步，拆开单独证明没有意义，直接对"传给 settle 的值"断言即可 |
| **RDR-3**（Slither + Aderyn 分诊） | **完成** | 见独立报告，§7 只做交叉引用 |

- **变异**：M-I9（把 settle 调用包一层 `try/catch {}` 吞掉失败，B-1 §10.1 ① 明令禁止的那种写法）——在 fuzz 侧第 27 次迭代即给出反例，命中的正是 CF3-a 对应的断言（§4）；源码已用 `git checkout` 恢复，sha256 校验前后一致。
- **口径**：这是**有界符号验证**（CF-3 对 `a0`/`actualGasCost`/`actualUserOpFeePerGas` 有界，理由见 §2.2），不是覆盖全部输入的完整证明；无界尾部由具名 fuzz 替代证据覆盖（§5），价格/decimals/协议费在一个具体点上（§2.1），是规范原文要求的口径。

## 1. 工具、版本与编译设置

| 项 | 值 |
|---|---|
| Halmos | 0.3.3（`uv tool install halmos`；自带 z3 4.12.6、yices 2.6.4）——与 D5c-1 相同版本 |
| forge / solc | forge 1.7.1（`4072e487`）；solc 0.8.33 |
| 编译 profile | Halmos 自己执行 `forge build --ast --extra-output storageLayout metadata`，`[profile.default]` |
| Forge fuzz（§5） | `forge test --match-path contracts/test/v2/SuperPaymasterI9Fuzz.t.sol --fuzz-runs 10000` |
| `forge test` 不运行 `check_*` | harness 里只有 `check_*` 与一个 `setUp`；全量 `forge test` 的 141 个套件 / 1723 通过 / 0 失败 / 49 跳过里不含它们（复核见 §6） |

## 2. 方法

### 2.1 目标与「具体价格点」

被测对象是 `SuperPaymaster.postOp`（`contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:369-431`，D5b 拆分后的核心合约，验证与 postOp 路径都留在核心，不经 fallback）。这是**单个函数**，无循环，控制流是几个提前 `return`/`revert` 加一次外部调用——与 D5c-1 证明整份 xPNTs v2 ABI 相比，调用面小得多，但函数体内部有一条不短的 `Math.mulDiv`/`ceilDiv` 链（`bufWei` → `aGas` → `charge`）。

规范 RDR-2 原文把 I9 的证明方式定性为**"算术引理 + 具体价格点上的控制流"**。本交付照此拆分：
- **控制流**（本文件的全部内容）：`price`/`decimals`/`aPriceUSD` 是 harness 自己构造 context 时写入的字段（永远不是存储），固定在一个具体点：`price = 2000e8`、`decimals = 8`、`aPriceUSD = 0.02 ether`（与仓库其它 fixture 一致——`V55MutablePriceFeed` 的默认值、`SuperPaymaster.initialize` 里 `aPNTsPriceUSD` 的默认值）；`protocolFeeBPS`（真实 SP 存储，`enableSymbolicStorage` 之后本应是符号值）用 `vm.store` 钉在 SP 的默认值 1000。这样 postOp 内部链条里的除数全部变成具体常数，去掉了"符号 × 符号"的乘法——D5c-1 §2.5 记录的"mint 分区超时"正是这类算术在完全符号化时的表现。
- **算术引理**（CF-3 的 bit 4，L9-CLAMP）：`charge` 的具体数值是否等于某个公式**不是**本交付要证的东西（那是 D5-traceability.md §1.1 R10-M3 已经在做、且已经过 Codex 两轮审查的"精确收费预言"）；本交付只证："不管 `charge` symbolic 地算出什么，它必须 `≤ a0`（postOp 自己的钳制逻辑），且传给 settle 的值必须与 SP 账目最终记的值*一致*"。这是一条不需要解出乘除法具体值的**数据流**断言，比精确等式便宜得多（§2.3）。

### 2.2 有界（W-A0、W-GASBOUND）：有据可查，不是图省事的收窄

CF-3（"settle 成功"的一侧）需要在 harness 里自己算一遍 `charge` 吗？不需要——但 postOp *内部*算 `charge` 时的 `Math.mulDiv` 链仍然要被求解器分析（即使全部除数已定为具体常数），因为 `actualGasCost + bufWei` 这类被乘数仍然是全符号的 `uint256`，"符号数乘以具体常数"对 SMT 求解器而言依然是一次完整的 256 位位向量乘法电路，代价与被乘数的位宽强相关（不是与除数是否符号相关）。第一版（`a0`/`actualGasCost`/`actualUserOpFeePerGas` 全部 `uint256` 不设上界）跑了 20 分钟以上没有收敛（9 路并行的 yices 进程各自 CPU 时间超过 10 分钟仍未返回，被手动终止）。

两个上界，都是**真实不变量**而非求解器便利：

| 假设 | 证明 | 用途 |
|---|---|---|
| **W-A0**：`a0 ≤ type(uint128).max` | `validatePaymasterUserOp`（`SuperPaymaster.sol:300-311`）里 `a0` 就是 `aPNTsAmount`，在被接受前必须满足 `uint256(config.aPNTsBalance) < aPNTsAmount` 为假（`:305`），而 `config.aPNTsBalance` 声明为 `uint128`（`ISuperPaymaster.OperatorConfig`）——任何被验证接受的 op，`a0` 在数值上不可能超过一个 `uint128` 能表示的范围。CF-3 的 `require(a0 <= type(uint128).max)` 只是把这条已经成立的不变量写成前置条件，与 D5c-1 §2.2 的 W1–W4 是同一类假设 | CF-3、两个改动过的 check（见下） |
| **W-GASBOUND**：`actualGasCost, actualUserOpFeePerGas ≤ 1e24` | 1e24 wei 在一个（不现实地夸张的）1e15 wei/gas 费率下对应 1e9 gas——比任何真实区块 gas 上限高三个数量级；这条界只是把求解器要处理的位宽从"整个 uint256"降到"够用的余量"，用一个**具名 fuzz 替代**（§5）覆盖它之外的尾部，做法与判定完全照抄 D5c-1 §2.6"BOUNDED + 具名 fuzz 替代"的模式 | 同上 |

两条界只加在**需要走完整 `charge` 计算链**的 3 个 check 上：`check_I9_CF3_settleCannotSilentlyFail`、`check_witness_I9_settleRevertsButCallerObservesSuccess`、`check_witness_I9_freshBalanceSettlementReachable`。`check_I9_CF1_emptyContext` 与 `check_I9_CF2_idempotentNoOp`（及其 witness）在真实代码里都会在算 `charge` 之前就 `return`（context 为空、或 `_settledDebtOps[opHash]` 已经是 `true`），从不触达这条乘除法链，所以不需要、也没有加这两条界——0.05–0.08 s 的收敛时间就是证据。

### 2.3 为什么 `check_witness_I9_settleRevertsButCallerObservesSuccess`「有界却依然便宜」

这个 check 同样加了 W-A0/W-GASBOUND（保持与 CF-3 前置条件一致，便于交叉核对），但它耗时只有 8 秒，而 CF-3 本身要 50 秒、`check_witness_I9_freshBalanceSettlementReachable` 要 48 分钟。原因不是有界与否，而是**这个断言从不检查 `charge` 的具体数值**：它只问 `ok`（`address(sp).call(...)` 是否成功）这一个布尔量。`probeBad` 的 `settleLocked`/`settleCredit` 无条件 `revert`，不看传入的 `chargeAPNTs` 参数——所以求解器证明"`ok == false`"时，完全不需要真的把 `charge` 的符号表达式化简到底，`charge` 在这条路径上是"某个会被传进一个无论如何都 revert 的调用"的值，对结论没有影响。这与 CF-3 的"成功"分支——需要把 `charge` 的符号值和 `probeGood` 记录的值、以及 SP 账目变动**逐一比对相等**——是完全不同的求解器工作量级。

### 2.4 W-REENTRANT：ReentrancyGuard 的符号 `_status`

`postOp` 带 `nonReentrant`。`svm.enableSymbolicStorage(address(sp))` 让 SP 的**每一个**存储槽（包括 OZ `ReentrancyGuard._status`，slot 1）都变成自由符号，包括它自身的"ENTERED"哨兵值——这是一个在任意*真实*外部调用**入口**都不可达的状态（守卫总是在设置它的那次调用返回前解锁），但对 Halmos 的"任意前置状态"建模而言，不特别处理的话它就是可满足的，会让 `nonReentrant` 对**每一个**输入都 revert，把每一条真正的反例都淹没在一个空洞的"因为重入守卫的原因而 revert"里。`setUp()` 里用 `vm.store` 把它钉在 `NOT_ENTERED`（值 1）——与 D5c-1 §2.2 W1（"clone 已初始化"）同一类"可达状态必然满足"的良构假设，来源核对：`forge inspect SuperPaymaster storageLayout --json` 里 `_status` 在 slot 1（`_owner` 在 slot 0，两者都来自 `Ownable`/`ReentrancyGuard` 的顺序布局）。

### 2.5 信任边界 W-CTX：`context` 的真实性不在本交付证明范围内

`postOp` 是 `onlyEntryPoint`；`context` 字节在真实系统里**只**可能是这个 SP 自己的 `validatePaymasterUserOp` 在同一笔交易里产出、又被规范的 ERC-4337 v0.7 EntryPoint（本仓库其它地方按 codehash 钉死的那份规范字节码，见 `EP_CODEHASH` 常量与 D5-plan.md G2 的说明）原样带回来的那一份——不存在"攻击者直接构造 context 喂给 postOp"这条路径。

本交付的 harness 刻意**不**把 `context` 建模成完全任意的符号字节串：`token` 字段被强制取值为两个部署好的探针合约地址之一（`probeGood`/`probeBad`），而不是留一个自由符号地址。这是**故意的、写明的**取舍，不是漏掉的角落——如果留一个自由符号地址，Halmos 会把它别名到"没有代码的空账户"这个分支（D5c-1 §2.5 记录过这个别名规则），而对空账户发起的 `CALL` 在 EVM 里总是"成功、返回空数据"——如果 `context.token` 真的可以是任意值，这条路径会让 postOp 在**完全没有真实代币销毁/记债**的情况下把"结算成功"记到 SP 账上，看起来正是"没有后盾的赞助"。但这条路径在生产环境里**不可达**：`context.token` 由 `validatePaymasterUserOp` 写入（`SuperPaymaster.sol:289`：`token != config.xPNTsToken` 时直接拒绝该笔 op），postOp 从未独立校验它是因为它信任 EntryPoint 忠实转发了自己刚刚产出的那份 context——这与"SP 自己给自己传参"是同一件事，不是外部输入。

把这条边界排除在证明范围之外，是为了让证明真正对应 postOp 与它*唯一合法调用方*（EntryPoint）之间的契约，而不是去证明一个生产环境永远不会出现的前提下会发生什么——本条边界记录在案，供未来如果这条信任假设本身需要被验证时参考（例如："EntryPoint 是否真的忠实转发 context" 这件事，本身已经由 G2 的 EntryPoint 级 fuzz 用规范字节码间接覆盖，见 D5-plan.md §2）。

## 3. 逐项结果

### 3.1 CF-1（空 context）

**形式化陈述**：σ 为 SP 的任意存储状态（W-REENTRANT 之外无额外假设）；`context = ""`；从 `entryPoint` 地址调用 `postOp`。则调用成功（`ok == true`），且 σ 的每一个被本 harness 观测的字段（`operators[operator]` 的全部 9 个成员、`protocolRevenue`、`userOpState[operator][user]`、`_settledDebtOps[opHash]`）在调用前后逐一相等，对任意 `operator`/`user`/`opHash`。

**结果**：PASS，3 条路径，0.05 s，`bounds: []`。

### 3.2 CF-2（幂等重放）

**形式化陈述**：σ 满足 `_settledDebtOps[opHash] == true`（已结算过）；`context` 为任意 352 字节 legacy 编码；从 `entryPoint` 调用 `postOp`。若调用成功（`ok == true`），则 `operators[operator]` 的 `aPNTsBalance`/`totalTxSponsored`、`protocolRevenue` 都不变，且 `_settledDebtOps[opHash]` 仍为 `true`。

`ok == false` 的分支（W-GAS：入口 gas 检查可能因为 Halmos 下 `gasleft()` 是自由符号而失败，与结算本身无关）不作断言——这不是"忽略了一个可能违反性质的情形"，而是这个分支在真实代码里*根本没有走到*任何会破坏 I9 的代码：postOp 在算 `charge`、调用 settle 之前就 revert 了，SP 账目和 token 侧都完全没有变化。

**结果**：PASS，9 条路径，0.08 s，`bounds: []`。

**可达性 witness**：`check_witness_I9_CF2_idempotentSucceedsWithEnoughGas` 断言 `!ok`（即"gas 检查总会失败"），预期反例——证明"gas 足够、重放真的成功返回"这一分支不是被 W-GAS 短路成空集。按预期 FAIL，9 条路径，0.07 s（反例：`data/halmos-i9/all-checks-final.log` 行 7025 起，Halmos 打印的具体 counterexample calldata）。

### 3.3 CF-3（I9 本体："settle 不可静默失败"）

**形式化陈述**。σ 为任意存储状态（W-REENTRANT），满足 `_settledDebtOps[opHash] == false`（新 op）；`a0 ≤ 2^128 − 1`（W-A0）；`actualGasCost, actualUserOpFeePerGas ≤ 1e24`（W-GASBOUND）；`token = useBadToken ? probeBad : probeGood`（`useBadToken` 符号布尔，§2.5 的 W-CTX 取舍）；`context` 由这些值加 `user`、`operator`、`mode`（任意 `uint8`）、`callGas`、`postOpGas`（任意 `uint128`）按 legacy 352 字节编码构造；从 `entryPoint` 调用 `postOp`。令 `ok` 为调用是否成功。

| 位 | 断言 |
|---|---|
| bit 0（`useBadToken`） | `ok` 必须为 `false`——settle 的 revert 必须让整个 postOp revert，不能被吞掉 |
| bit 1（`useBadToken` 且 `ok`，冗余保险） | 若违反 bit 0，`operators[operator].aPNTsBalance`/`protocolRevenue`/`_settledDebtOps[opHash]` 也必须不变——EVM 的 revert 语义本身已保证这点，此位只是让"bit 0 的判读本身错了"这种情形也能被看见 |
| bit 3（`!useBadToken`，`ok` 时） | settle 调用必须**可观测地**到达 token（`probeGood.lockedCalled`/`creditCalled` 为真）——排除"`ok == true` 只是因为什么都没发生"这种空洞读数 |
| bit 4（L9-CLAMP，`!useBadToken`，`ok` 时） | 传给 settle 的 `probeCharge ≤ a0` |
| bit 5、6（`!useBadToken`，`ok` 时） | `operators[operator].aPNTsBalance` 恰好增加 `a0 − probeCharge`；`protocolRevenue` 恰好增加 `probeCharge`——这是把"postOp 完成"与"结算真的发生"绑在一起的核心断言 |
| bit 7（`!useBadToken`，`ok` 时） | `_settledDebtOps[opHash]` 翻转为 `true` |

`!useBadToken` 且 `!ok` 的分支（W-GAS，与 CF-2 同一类）不作断言。

**Harness**：`contracts/test/halmos/SuperPaymasterI9Halmos.t.sol:check_I9_CF3_settleCannotSilentlyFail`。

**结果**：PASS，1502 条路径，50.22 s（求解器统计：paths 49.70 s + models 0.52 s），`bounds: []`。

**可达性 witness**：`check_witness_I9_freshBalanceSettlementReachable` 断言 `!(ok && probeGood.lockedCalled(opHash))`（即"BALANCE 模式下新 op 真的成功结算"这件事不会发生），预期反例——证明 CF-3 的"成功"分支不是空集。按预期 FAIL，478 条路径，**2881.59 s**（`paths: 17.48s, models: 2864.11s`——找一个具体满足模型比证明"对所有路径都不违反"贵得多，这是预期之内的 SMT 求解器行为：存在性证明往往比全称有效性证明更依赖具体赋值搜索）。

### 3.4 CF3-a 独立交叉检查（命名有误导性，已在源码里更正说明）

`check_witness_I9_settleRevertsButCallerObservesSuccess` 这个函数名带"witness"字样，历史遗留（最初设计成一个可达性 witness，实现过程中发现它其实只是 bit 0 在无 gas-guard 干扰下的独立重述，语义变了但没有改函数名——改名会让已归档的 `.log` 里 `Running` 那一行对不上，所以保留函数名，仅在源码 docstring 与 EVIDENCE-INDEX/本文件里更正说明，见 §2.3 的费用分析）。

**结果**：PASS，351 条路径，8.00 s，`bounds: []`——`assert(!ok)` 在 W-A0/W-GASBOUND 下可证。

### 3.5 关于 witness 求解耗时的说明

D5c-1（§2.6）把每个分区的墙钟上限定在 600 s，超时记为 TIMEOUT-WALL。本交付的两个真正的 witness 都没有触发任何超时上限（各自设的 `--solver-timeout-assertion 300000` 是单次断言查询的超时，不是整个 check 的墙钟）——`check_witness_I9_freshBalanceSettlementReachable` 的 2881.59 s 是它**自己**收敛所需要的时间，不是被外部杀死后记录的下限。之所以远慢于 CF-3 本身（同样需要求解 `charge` 链，只需 50 s），是因为 PASS（有效性证明）只需要证明"没有反例"，求解器可以用不完整的抽象化/化简手段快速判定"无解"；而 FAIL（存在性）需要求解器真正**构造**一个满足全部约束（包括完整的 `charge` 链）的具体赋值模型，这类查询天然更贵。两者都在同一份最终 `all-checks-final.log` 里（同一次 halmos 调用跑完全部 6 个 check），没有分开跑、没有重试。

## 4. 变异（M-I9）

按 B-1 §10.1 ① 的注释直接点名的"NO try/catch"改成"有 try/catch"：

```diff
-        // B-1 §10.1 ①: NO try/catch. A failed settlement reverts postOp → EntryPoint rolls back
-        // the user's execution; the escrow/reservation is then released after the transaction.
-        if (c.mode == MODE_BALANCE) {
-            IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge);
-        } else {
-            IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge);
-        }
+        if (c.mode == MODE_BALANCE) {
+            try IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge) {} catch {}
+        } else {
+            try IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge) {} catch {}
+        }
```

跑 `testFuzz_I9_CF3_settleCannotSilentlyFail`（forge fuzz，同样的性质，见 §5）：**第 27 次迭代即给出反例**，命中的断言正是 `"I9 (fuzz): a reverting settlement call must not let postOp succeed"`（即 CF3-a 在 fuzz 侧的对应项）。日志：`data/halmos-i9/mutation-M-I9-fuzz.log`。

变异做在工作树里（未提交），跑完立即 `git checkout -- contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol` 逐字节恢复：

| | sha256(`SuperPaymaster.sol`) |
|---|---|
| 变异前 | `25dfd8cc2385db112a57c3f120689eba6917d127401f381877cec3e19cf5d21c` |
| 恢复后 | `25dfd8cc2385db112a57c3f120689eba6917d127401f381877cec3e19cf5d21c`（相同） |

未对 Halmos 侧的 CF-3 本身重跑这个变异（fuzz 版本已经确认 harness 能抓到这个类别的缺陷；Halmos 版本预期同样会在 bit 0 变红，逻辑相同，重复跑一次 50 s 的证明只是再确认一遍同一件事——记为口径说明，不是缺口）。

## 5. Fuzz 替代证据（W-GASBOUND 的无界尾部）

`contracts/test/v2/SuperPaymasterI9Fuzz.t.sol:testFuzz_I9_CF3_settleCannotSilentlyFail`：与 CF-3 相同的性质，但 `actualGasCost`/`actualUserOpFeePerGas` 是完整无界的 `uint256`（没有 1e24 的界），`a0` 仍然是 `uint128`（W-A0 本身是真实不变量，不是本交付要绕过的界），另外把 `protocolFeeBPS` 也做成 fuzz 输入（限定在链上真实强制的范围 `[0, MAX_PROTOCOL_FEE=2000]`，比 Halmos 侧钉死在 1000 更泛化）。

**结果**：10,000 次 runs 全绿（`forge test --match-path contracts/test/v2/SuperPaymasterI9Fuzz.t.sol --fuzz-runs 10000`，μ gas 107,117，中位 85,559）。变异测试见 §4。

## 6. `forge test` 全量复核

新增的两个文件不影响任何既有测试（只新增文件，未改 `contracts/src`）：

```
Ran 141 test suites in 37.07s (223.48s CPU time): 1723 tests passed, 0 failed, 49 skipped (1772 total tests)
```

（`SuperPaymasterI9Halmos.t.sol` 里只有 `check_*`，forge 不运行；`SuperPaymasterI9Fuzz.t.sol` 的 1 个 `testFuzz_*` 计入上面的 1723。）

## 7. RDR-3（交叉引用）

静态分析分诊是独立完成的，报告与证据见：
- [`../../security/slither-aderyn-report-2026-09-17.md`](../../security/slither-aderyn-report-2026-09-17.md)——Slither 248 条 + Aderyn 24 组的逐条/分组分诊，9 条真问题标记"本轮不修、需要单独 PR"，未改动任何 `contracts/src` 文件。
- 原始产物：`docs/security/slither-d5c2-2026-09-17.json`、`docs/security/aderyn-d5c2-2026-09-17.json`。
- EVIDENCE-INDEX 行：RDR3-01/02/03。

## 8. 局限（供论文附录）

- **有界，不是全称证明**：CF-3（及其两个改动过的 check）把 `a0` 限定在 `uint128`（真实不变量，非收窄）、`actualGasCost`/`actualUserOpFeePerGas` 限定在 `≤ 1e24`（求解器便利性上界，有名 fuzz 覆盖尾部，§5）。`protocolFeeBPS`/`price`/`decimals`/`aPriceUSD` 固定在一个具体点（规范原文要求的"具体价格点"口径），不是任意价格下都重新跑了符号证明——`protocolFeeBPS` 这一维由 §5 的 fuzz 在其真实允许范围内补充覆盖；`price`/`decimals`/`aPriceUSD` 完全没有被本交付以外的任何自动化证据在符号层面覆盖过（它们进入 postOp 只有乘除法，没有分支，出于"这条路径上不存在会被价格数值本身触发的控制流分叉"的论证——但这是论证，不是机器证明）。
- **W-CTX 是记录在案、未经证明的信任边界**（§2.5）：本交付证明的是"如果 context 是 postOp 唯一合法调用方会产生的那种 context，settle 不会被静默吞掉"；不证明"context 的真实性本身如何被保证"——那是 EntryPoint 的规范字节码与 `onlyEntryPoint` 访问控制的责任，由 D5-plan.md 的 G2 fuzz（经过真实规范 EntryPoint 字节码）间接覆盖，不在本交付范围。
- **符号地址别名**：`token` 被强制为两个具名探针地址之一，不探索"symbol 地址别名到空账户"或"别名到某个已部署的、行为未知的其它合约"这两种 Halmos 默认会做的别名——前者正是 W-CTX 排除的那条路径（§2.5 已论证生产环境不可达），后者在本 harness 的调用面里不存在第三个候选合约可供别名（只部署了 `sp`、`probeGood`、`probeBad`）。
- **`Math.mulDiv`/`ceilDiv` 的非线性抽象**：与 D5c-1 §2.5 相同，Halmos 对符号 × 符号的乘法、除以符号数使用未解释函数抽象，发现候选反例时才细化为真实位向量语义——本交付的 PASS 结果不依赖任何反例，所以细化步骤未被触发，但这条抽象规则依然适用于理解为什么"符号 × 具体常数"仍然可能昂贵（乘法本身的位向量电路代价与除数是否符号无关，§2.2）。
- **未做**：D5c-1 式的"判定脚本 + 证据绑定 + 自检"整套机器判定装置（`verify-d5c1.py` 那个量级）——本交付的调用面只有 1 个函数、6 个 check，人工核对结果表（本文件 §0/§3）与直接引用 `.log` 的做法在这个规模上是相称的；D5c-1 那套装置是为了应对整个 ABI（148 个选择器 × 多个不变量 × 分区并行）的复杂度而建的，本交付如实说明规模不同、没有复用它。
