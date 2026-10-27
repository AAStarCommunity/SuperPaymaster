# AOA-SP-02 第 4 项：安全测试 → 最终 artifact / 目标环境映射与缺口

依据：DSR `AOA_Parallel_Work_Orders_2026-10-26.md` §AOA-SP-02 子任务 4，以及 `AOA_Resubmission_Milestones_2026-10-25.md` M2.5。
本文**没有跑任何测试**。它把仓库里已有的证据逐类对到最终 artifact，并判断哪些可以沿用、哪些要重跑、哪些从未覆盖。
原则是 DSR 定的：只重跑受改动影响或缺覆盖的项目，不用源码索引冒充测试通过。

## 1. 最终 artifact 与判据

- **SP / Registry / xPNTs v2 的实现**：候选 `fbd74fb1`（rc.4，#513 合并）。依据：`docs/release/a3a-newpin-11995523/README.md` 中的「Upgrade rehearsal」，以及 `boot/plan.json` 的 `rebuild`。
- **A3a 的 TimelockController 与 APNTsCapped**：在 `66df75ee` 构建（`a3a-plan/plan.json` 的 `rebuild`）。
  `git diff fbd74fb1 66df75ee -- contracts/src foundry.toml` 为空，所以两棵树的合约源码与编译配置相同。
- **目标环境**：Sepolia，运行时已是 Amsterdam 硬分叉；EntryPoint v0.7。编译目标仍是 Cancun，用 Forge 1.7.1 的 profile.default。
  Amsterdam 是运行时的要求，不是改编译设置的理由。

每条证据的判据是：`git diff --name-only <证据所在的树> fbd74fb1 -- contracts/src foundry.toml remappings.txt`。下表 Δ 一列记录结果，各 commit 都已逐个复核过。

- **Δ0**：源码与配置和最终 artifact 相同。下列各树都属于这一类：`1ac0e1c5`、`4f6d5084`、`79c0c6ff`、`c3eb1011`、`ec8f2c0c`、`c2503550`、`1ef7bede`、`66df75ee`。
- **Δold**：差 15 个文件，涉及 Registry、SP 的 core/admin/storage/lens/base、token-v2 全套、APNTsCapped、namespaced ownership。下列各树属于这一类：`0044bc95`、`b9a9e511`、`7fa7b705`、`df941d57`、`31921fbc`、`6c3a9a0e`、`4ba1d546`、`c0d9e350`。
- **Δstatic**：`be170a48`，差 10 个文件。

源码相同不等于字节相同。只有逐项核对过发布字节的条目（R-AMS G/B，见 `data/rams-f4/REPORT.md`），才算覆盖了最终字节。

判定的取值：
- **COVERS-FINAL**：在其声明的有界范围内覆盖最终 artifact 与目标环境。
- **ENV-GAP**：代码是最终的，环境不是 Amsterdam。
- **RERUN-NEEDED**：所在的树受改动影响。
- **NOT-COVERED**：没有覆盖。

## 2. 映射表

| 类别 / 证据 | 覆盖什么 | 树 | 环境 | Δ | 判定 |
|---|---|---|---|---|---|
| Forge 全量（`data/ci-final-4f6d5084/`，CI run 39392135141） | 149 套件，**1791 通过 / 0 失败 / 49 跳过** | `4f6d5084` | Forge 1.7.1，Cancun，本地 | Δ0 | ENV-GAP |
| Prague 门禁（`contracts/test/paper7`；`data/rams-2a/` 中的 nightly prague） | 真 EIP-2537 预编译下的 BLS 路径；全量 **1671 / 0 / 23** | `79c0c6ff` | nightly `926eb1d`，Prague | Δ0 | ENV-GAP |
| **Amsterdam 全量诊断**（`data/rams-2a/REPORT.md` §2，`result_diffs.md`） | 同一全量：**1617 通过 / 54 失败 / 23 跳过**，按原因分 5 类（见 §3 G-7） | `79c0c6ff` | nightly `926eb1d`，Amsterdam | Δ0 | ENV-GAP，且**未通过** |
| 代币状态不变量 I1–I7（`D3-traceability.md` §6；`xPNTsTokenV2Invariant.t.sol`） | 授权扣减、预算、债务来源、锁与预留守恒、stale/live 分离、恶意 SP 上界、credit 上限 | 原始 `b9a9e511`；后来在 `4f6d5084` 的 CI 里跑过 | Forge 1.7.1，Cancun | 后者 Δ0 | ENV-GAP |
| EntryPoint 级不变量 fuzz I8–I10（`D5-traceability.md` §1；`data/i9-rc2-final/`） | 执行保留即结算、零无担保赞助、stale 恢复；真 EP v0.7 字节码 | 后来在 `4f6d5084`；I9 专项在 `1ac0e1c5` + 记录在案的测试 overlay | Forge 1.7.1，Cancun；I9 跑 10,000 轮 | Δ0 | ENV-GAP（RR 子集见下） |
| 六类对抗（`docs/release/v5.5.0-rc.2-review-pack/R1-3-ADVERSARIAL-INDEX.md`） | 被盗 owner、恶意工厂、重复拉取、SP 替换、撤销、批量 | 按测试名在 `4f6d5084` CI 日志里有执行记录 | Forge 1.7.1，Cancun | Δ0 | ENV-GAP；另有各类自己声明的覆盖缺口，Amsterdam 重跑也补不上（G-10） |
| T-R14-01…07（`D3-traceability.md` §4） | Sybil、多 nonce key、stale 黑名单、用户 revert 仍付费、postOp 回滚、credit OFF、gas 操纵与 sweep | `4f6d5084` | Forge 1.7.1，Cancun | Δ0 | ENV-GAP；Amsterdam 诊断里有 15 个对抗测试失败（旧 gas 参数） |
| 变异测试（D3 迁移/对抗/状态、D5 G2；`D3-M-layer.md`、`EVIDENCE-INDEX.md` §2.4） | 迁移 105/107 被杀；代币不变量 13；对抗 9；G2 10 | `0044bc95`、`b9a9e511`、`7fa7b705`；部分子活动的树不详 | 本地 Forge | **Δold** | **RERUN-NEEDED** |
| Halmos D5c-1（`data/d5c1-rc2-serial/`） | CAP-1、汇率界、A3 防火墙、I2/I4/I6、还款引理，含预期反例与变异敏感性 | `1ac0e1c5` + 一个负例 overlay | Halmos 0.3.3，有界；8 个分区用 fuzz 替代 | Δ0 | 有界功能证据可沿用；不含 Amsterdam gas 模型 |
| Halmos D5c-2 / I9（`data/i9-rc2-final/`） | CF-3 结算不能静默失败；2 PASS + 3 个预期反例见证 | `1ac0e1c5` + 4 个 overlay | Halmos 0.3.3，`--loop 2` | Δ0 | 同上 |
| G2 多付与 buffer 实验（`data/g2-*`、`buffer-and-params-experiment.md`） | 精确收费、多付分布、旧公式与 Part A/B | `df941d57`、`31921fbc`、`6c3a9a0e` | Cancun 时期 | **Δold** | **RERUN-NEEDED**（论文若引用百分比） |
| R-AMS G/B gas 对账（`data/rams-f4/`、`rams-f2/`） | 发布字节下 postOp/验证上界、冷热差、PVG | G 重跑表头钉 `fbd74fb1` | Amsterdam nightly `926eb1d` | 发布字节已核 | **COVERS-FINAL**（仅 R0 与所测夹具） |
| D7 JS E2E（`data/d7-final-4f6d5084/`） | 部署、gasless 流程、credit 上限与紧急停止；**31 通过 / 4 失败 / 2 跳过** | `4f6d5084` | 新 Anvil 1.7.1，Prague | Δ0 | ENV-GAP，且非全绿 |
| RR 引擎：receipt 重放（`data/rams-rr/`） | 10 笔真实高 gas 交易按 receipt 重放 | `c2503550` | Sepolia fork，nightly `926eb1d` | Δ0 | NOT-COVERED（外部交易，不是 SP 测试）。只比 receipt，对 RR 不够：严格帧校准下 `926eb1d` 是 0/10 |
| RR 引擎：严格帧校准（`data/rams-rr-matrix/frame-calibration/`） | 同一批交易的**首步**帧 gas 与 reservoir 比对（后续帧没比，`data/rams-rr-matrix/REPORT.md:11`） | 见该目录 | `4e8874b` 10/10，`926eb1d` 0/10 | — | NOT-COVERED（同上）；它是 RR 矩阵可用 `4e8874b` 的前提 |
| **RR 矩阵**（`data/rams-rr-matrix/phase2/`） | **1080 记录 / 360 格**：balance/credit、冷热/位置、成功/revert/耗尽/退款；I9/I10、收费、gas guard、R0 对 RR | `1ef7bede`，dirty 0 | 新 Amsterdam Anvil `4e8874b`；激活参数 440k/420k/5k/340k | Δ0 | **COVERS-FINAL**（有界矩阵范围） |
| A2 治理/恢复演练（`data/d5b/a2-final-11885120-4f6d5084/`） | 升级、所有权、角色、guardian、fail-closed：370 检查，65 个预期否定 | `4f6d5084` | Sepolia fork 11,885,120，Forge 1.7.1；硬分叉标志不详 | Δ0 | ENV-GAP |
| Route-A 治理缺口 + 变异（`data/rams-a/`） | 冻结新 SUPER 授权、暂停现有持有者、残余持有者自激活、Safe 等待窗口攻击；16/16，M1–M21 | `ec8f2c0c` | Sepolia fork 11,974,561，Amsterdam | 源码 Δ0；但其 README 写明**部署的 Registry 字节未与具体 commit 核对**，R0 是运行假设（`data/rams-a/README.md:63,91`） | **COVERS-FINAL 只到源码层面的所建模过渡**；不覆盖已部署字节，也不证明 R0 |
| A3a Safe/Timelock（`docs/release/a3a-newpin-11995523/a3a-sim/`） | 角色排他、approve/execute 顺序、nonce、延迟、owner；4 个负对照 | `66df75ee` | Sepolia fork 11,995,523，Amsterdam `4e8874b` | 精确重建 | **COVERS-FINAL**（本地演练） |
| 升级演练（`boot/`、`indep/`） | 16 步；safeMint 正负、暂停读回失败、取消重排、非 Safe 执行、提前升级/激活 | 执行器 `66df75ee`，候选 `fbd74fb1` | 同上；SP 部署 52,389,391 gas（RR） | 精确 | **COVERS-FINAL**（仅所列升级范围，不是 Registry/xPNTs 全量回归） |
| ERC-7562（Rundler 0.11.0 / Alto 1.2.5；`b-layer/`、`data/rams-f2/`） | 验证期禁用访问、质押、sender、续期、initCode；估算是否够用 | 历史 `4ba1d546`、`c0d9e350`；Amsterdam 版本来自 `c3eb1011` | 本地 Amsterdam `926eb1d` | Amsterdam 版 Δ0 | **COVERS-FINAL**（本地、R0、所配置用例）；公网 RR 未覆盖；本地也有未测项（G-11） |
| CC48 credit/治理回归（`docs/security/CC48-round9-changes.md`） | tier 重定价、重播种、基线、单调 tier、原子迁移 | 后来在 `4f6d5084` | Forge 1.7.1，Cancun | Δ0 | ENV-GAP |
| Echidna（`contracts/echidna/README.md`） | 历史 V2 性质 | 无可用的最终活动；配置已失效，不在 CI | — | — | **NOT-COVERED** |
| Slither / Aderyn（`docs/security/slither-aderyn-report-2026-09-17.md`） | 静态检测 | `be170a48` | Slither 0.11.5 | **Δstatic** | **RERUN-NEEDED** |

CI 的覆盖范围：
- 当前 CI 只跑 Cancun 全量、`--fuzz-runs 10000` 和一次 Prague。
- Slither 带 `continue-on-error`，只作参考。
- **没有** Amsterdam、Halmos、RR 矩阵或可用的 Echidna 门禁。

依据：`.github/workflows/{test.yml,security.yml}`。

## 3. 缺口

| # | 缺口 | 现状 | 依据 |
|---|---|---|---|
| G-1 | **RR guard-fail 路径** | 未覆盖。按设计 MIN 440k > SETTLE 420k，矩阵里没有任何被接纳的 op 会触发 `gasleft() < snapSettle`。720 次 R0↔RR 比较只说明 RR 不会把通过变成失败，没说明 guard 失败时的行为。MIN−1 的行在验证期就被拒，不能替代这条路径 | `data/rams-rr-matrix/phase2/REPORT.md:73-74` |
| G-2 | **legacy160** | 刻意排除，不是通过。rc.4 只接受 352/384 字节，矩阵发 384。历史上 5.4.2→rc.2 同 bundle 测试显示 160 字节不兼容、回滚、operator 预留未恢复 | `data/rams-rr-matrix/REPORT.md`；`EVIDENCE-INDEX.md` 的 A2-C2-rc2 |
| G-3 | **冷验证 op 3/3** | 在该矩阵里不适用：前面的 op 已把共享的 SP 预热，postOp 天然是热的 | 同上 |
| G-4 | **公网 bundler 对 >2²⁴ 的行为** | 未覆盖。本地 RR 显示 EP v0.7 少补偿；本地 Rundler/Alto 接纳不代表公网的策略、打包与补偿 | 同上 |
| G-5 | **用户 revert ≠ postOp 失败** | T-R14-04：用户执行 revert 后仍结算并收费。T-R14-05：执行回滚，之后做 stale 清理。RR 的「postOp 耗尽」注入的是代币结算子调用 OOG 的夹具，不是代币自然耗尽，也不是 guard 失败 | `03-final-spec.md`；`D5-traceability.md` §1.1 |
| G-6 | **代币账恢复 ≠ ETH 恢复** | I10 恢复 operator 的 a0、释放代币预留，失败 op 不进协议收入；但 **SP 在 EntryPoint 的 ETH 押金仍付了 actualGasCost**，验证期的 nonce、状态和 `totalSpent` 也可能留下 | `03-final-spec.md`；RR 矩阵 REPORT |
| G-7 | **Amsterdam 全量回归没过** | 54 个失败分五类：18 个是测试固定的 `paymasterVerificationGasLimit = 700k`，首个 balance 模式 op 需要 820,305；3 个是 no-OOG 带；27 个是 postOp 在 `MIN_POST_OP_GAS = 200k` 下结算不了（经 EntryPoint 最小可结算约 365k–370k）；5 个是探针夹具问题；1 个是 postOp 实测超过 200k。挑选出来的 G/B 与 RR 结果**不能**替代全量。R2-F2 的参数是实测候选，不是已接受的默认值 | `data/rams-2a/REPORT.md` §2；`data/rams-f2/REPORT.md` |
| G-8 | 证据完整性有界 | 部分历史变异日志缺失；部分运行的树没记录；Halmos 有界且部分分区用 fuzz 替代；RR 全量 trace 在仓库外，只入库了归档与逐 trace 哈希和 12 个样本 | `EVIDENCE-INDEX.md` §3 |
| G-10 | **六类对抗各自声明的缺口**（`R1-3-ADVERSARIAL-INDEX.md` 的 GAP 列；下面是摘要，**完整内容以原表为准**，M2.5 报告应整列引用） | ① 被盗社区 owner 仍可 mint、改上限/policy、提议 SP、用已指定的 standby 紧急切换，没有公链演练和完整符号证明；② 工厂 owner / registry 失守与代币 owner 失守**组合**未穷举；③ 显式 ERC-20 approval 独立于自动额度，有限额 approval 被替换时的扣用顺序没测；⑤ `disableSpenderForSelf` 与降低自动额度都不减已有显式 approval，disable 之后用显式 approval 拉款、以及公网 bundler 下的撤销竞态都没测；④ `test_old_locker_settles_only_in_original_tx_after_rotation` **名不副实**：不轮换、不用旧 locker 结算，没有测试证明旧 locker 的结算顺序；被盗 owner 利用 standby 的时序也没测；⑥ 只有本地 EntryPoint 夹具，5.4.2→rc.2 同 bundle 不兼容，credit 模式的升级竞态没测。这些不是换环境重跑能补的 | `docs/release/v5.5.0-rc.2-review-pack/R1-3-ADVERSARIAL-INDEX.md` |
| G-11 | **本地 bundler 层的未测项** | 没有 SimpleAccount 的 B 层运行（用的是 MockAirAccount）；Rundler 默认上限下 initCode op 的 PVG 接纳没测出来；新 beneficiary 的 bundle 组合、L2 链参数、非默认 `pre_verification_gas_accept_percent` 下的 PVG 没测；Alto B6 在 v 150k 时的接纳与估算器抛错原因未定；B 层探针不搜 MIN 以下；非首个 op 的 PVG 余量没拆解；没有 geth 交叉核对（只校准了 anvil nightly） | `data/rams-f2/REPORT.md` §6 |
| G-9 | 治理演练不是链上验收 | 升级演练接在模拟的 A3a 之后；A3a 真执行后要从链上状态重生成升级包（即 IG-08）。其对照不扩展为 Registry/xPNTs 全量回归 | `docs/release/a3a-newpin-11995523/README.md` |

## 4. 建议重跑（只限受影响或缺覆盖的项）

| # | 重跑什么 | 为什么 | 不重跑什么 |
|---|---|---|---|
| RR-1 | 用 Amsterdam（引擎 `4e8874b` 或之后经正对照的版本）在 `fbd74fb1` 上跑全量，测试里的 gas 参数改用将部署的参数组；**并核对被测字节就是发布字节**：同源码的测试可能跑的是 runs-200 变体而非发布的 runs-500（`data/rams-f4/REPORT.md`），所以要么从发布 artifact 部署，要么逐合约比对执行字节 | G-7：目标环境下全量未通过，而失败集中在 gas 参数；要先区分「夹具参数过时」与「机制在 Amsterdam 下不成立」，而且结论只对发布字节有效 | Cancun / Prague 全量（Δ0，结论不变） |
| RR-2 | 变异活动在最终树上重跑（至少 G2 的 10 个与代币不变量的 13 个） | 原活动在 Δold 树上，被变异的合约正是改过的 | 迁移 105/107 若论文不再引用可不跑 |
| RR-3 | G2 多付统计在最终树 + Amsterdam 上重算 | Δold，且 gas 规则变了；论文若引用百分比，旧值不能用 | — |
| RR-4 | Slither 在 `fbd74fb1` 上重跑 | Δstatic，成本低 | Aderyn 可选 |
| RR-5 | G-1 guard-fail：加一个让 `gasleft()` 恰低于 `snapSettle` 的专门用例，在 R0 与 RR 下各跑 | 现有矩阵按设计碰不到 | — |
| — | Echidna：不重跑，论文不引用 | 配置已失效，迁移到 forge invariant 的部分已被覆盖 | — |

Halmos、A3a/升级演练、RR 矩阵、R-AMS G/B 都是 Δ0 或精确字节，**不需要**重跑。Route-A 也不需要因源码改动重跑，
但它的结论只到源码层面；已部署 Registry 的字节核对和 R0 的证明另算，不在本表的重跑清单里。G-10、G-11 要的是新用例，不是重跑。

## 5. 核对

上表的 Δ 分类由 `git diff --name-only` 逐个复核。CI 的 1791/0/49 取自 `data/ci-final-4f6d5084/run-log.txt.gz`。
Amsterdam 的 1617/54/23 是 `rams-2a/REPORT.md` §2 合并 `./out` 重跑后的数，原始日志 `n_amsterdam.log` 为 1602/55/23。
RR guard 的结论取自 `rams-rr-matrix/phase2/REPORT.md:73-74`。其余条目引自所列证据，本文没有重跑它们。
