# D3 交付追溯（测试矩阵）

分支 `feat/aoa-balance-mode-5.5.0`。D3 只动测试和文档，不改 `contracts/src/`。本文件随各部分交付逐节补全。

## 1. O1 补测清单（D2 验收时遗留）— `093bf37e`

文件：`contracts/test/v2/xPNTsTokenV2D3.t.sol`，共 41 个测试。

| 规范行 | 测试 |
|---|---|
| A-7：每个 sender 在一个 bundle 里最多续期一次，且续期必须排第一 | `test_A7_renewal_after_a_lock_in_same_bundle_is_rejected_and_writes_nothing`、`test_A7_renewal_first_then_plain_ops_ok_second_renewal_rejected`、`test_A7_renewal_after_credit_reservation_is_rejected` |
| A-10：propagate 只发起提议；创世 spender | `test_A10_propagate_only_proposes_and_community_can_cancel`、`test_A10_propagate_does_not_override_community_proposal`、`test_A10_propagated_proposal_activates_after_timelock`、`test_A10_genesis_spender_default_cap_zero_until_user_opts_in`、`test_A10_genesis_spender_must_be_on_allowlist` |
| E-3：重新启用不重置 `used` | `test_E3_reenable_does_not_reset_used`、`test_E3_reenable_by_signature_does_not_reset_used` |
| E-4：`releaseAndDisable` 是原子的 | `test_E4_releaseAndDisable_atomic_after_tx`（isolate）、`test_E4_releaseAndDisable_reverts_whole_while_live`、`test_E4_releaseAndDisable_without_record_just_disables` |
| C-4：撤销只影响新的预留 | `test_C4_user_revoke_…`、`test_C4_owner_lowers_approval_…`、`test_C4_tier_drop_…`、`test_C4_policy_off_…` |
| C-5：切换分档源 | `test_C5_switch_timelocked_and_bumps_epoch`、`test_C5_queue_rejects_unlisted_and_nonowner`、`test_C5_execute_rechecks_allowlist` |
| C-0 / §9：`tierOf` 出错时一律 fail closed | `test_tierOf_revert_is_zero`、`…_wide_return…`（64 字节）、`…_short_return…`（31 字节）、`…_empty_return…`、`…_gas_exhaustion_is_zero_and_bounded`；正对照 `…_positive_control_huge_tier…` |
| X5：spender 白名单的各条拒绝路径 | `test_X5_unlisted_code_rejected`、`…_upgradeable_proxy_to_listed_impl_rejected`、`…_noncanonical_45_byte_lookalike_rejected`、`…_eoa_and_sp_rejected`、`…_canonical_clone_accepted_and_activation_rechecks`、`…_spender_becoming_sp_cannot_be_activated` |
| R2 / ERC-1271 | `test_1271_wallet_action_by_relayer`、`…_wallet_rejection_reverts_and_keeps_nonce`、`…_wrong_key_and_expired_rejected`、`…_signature_bound_to_token_domain` |
| S-2 / S-3 | `test_S2_cancel_authority`、`test_S3_timelock_boundary`、`test_S3_rechecks_registry_at_activation`、`test_S3_community_proposal_activates_during_emergency_without_clearing_it`、`test_S3_old_sp_cannot_act_after_rotation` |

**变异**：共 20 个，逐个执行"应用变异 → 跑测试 → 还原"，每个都在上面指名的断言上变红：A7、A7c、E3、E4、C4、C5、C5e、TLEN、TGAS、X5、X5a、X5r、S2、S3r、S3t、S4k、A10p、A10g、R2e（只接受 ECDSA）、去掉 EIP-712 domain。结束时 `git status contracts/src` 为空。

## 2. DSR 在 D2 验收时提的两条 Low — `093bf37e`

- Low-1：`test_R10M3_charge_uses_validation_price_snapshot` 新增三条断言，要求快照里的 `price`、`decimals`、`aPriceUSD` 与验证那一刻的 `cachedPrice` 和 `aPNTsPriceUSD` 逐项相等。M7a 的两个变体（价格 ×1.1、aPNTs 价 ×1.1）现在单跑 v2 套件就会变红，失败信息分别是 "snapshot price == …" 和 "snapshot aPNTs price == …"。
- Low-2：`Coverage_Supplement` 里旧格式 context 的那条 postOp 用例，改为 `expectRevert(bytes(""))`，也就是 `abi.decode` 失败时的精确空 revert。

## 3. G 层：`C_WRAP` 的推导（spec §9 "G gas"、§11 R10-M3）

文件：`contracts/test/v2/SuperPaymasterV55Gas.t.sol`。

**用哪份 EntryPoint 字节码**：从链上取回的**规范** EntryPoint v0.7 运行时字节码，存为 `contracts/test/fixtures/entrypoint-v0.7.runtime.hex`，同时存了 SenderCreator。codehash 是 `0x8db5ff69…fc58`，已核对 Sepolia、OP Sepolia、OP mainnet 三条链完全相同，测试里用 `assertEq` 固定。测试没有使用仓库按 via_ir、runs=500 重新编译的 EntryPoint，因为包裹开销取决于 EntryPoint 自己的字节码。

**模型**（EntryPoint v0.7 `_postExecution`）：从 SP 押金里扣的最终 gas F = P + seg + penalty。其中 P 是调用 postOp 时已经计入、作为 `actualGasCost` 传进来的部分；seg = wrap + postOp 帧自身的消耗；penalty = 未用执行 gas 的 10%。SP 的 buffer 是 `postOpGasLimit + ⌈(callGas+postOpGas)·10%⌉ + C_WRAP`，所以 **C_WRAP 需要覆盖的是 wrap**，即 EntryPoint 在 postOp 调用前后自己的开销：ABI 编码 context、CALL、处理返回、记账。

**Part 1 的测量方法**：用一个探针 paymaster。它的 context 与 SP 的 OpCtx 等长（11 个字），postOp 记下 P 之后把自己的帧烧到只剩 ≤ 300 gas。于是 wrap ≤ F − P − postOpGasLimit + 300；penalty 只会让这个估计偏大，所以它仍是上界。

| 场景 | wrap 上界（gas） |
|---|---|
| opSucceeded，postOpGasLimit 200k | 1,689 |
| opSucceeded，postOpGasLimit 1M | 1,687 |
| opReverted（用户调用 OOG），200k | 1,702 |
| bundle 第 0–3 位 | 1,689 / 1,701 / 1,701 / 1,701 |
| 对照：留 3M 未用的 callGas（penalty 被计入估计） | 301,546 |

测得 wrap 的上界约 **1.7k gas**，`C_WRAP = 30,000` 约有 **17 倍**余量。测试断言了三点：wrap ≤ C_WRAP；wrap×5 ≤ C_WRAP；postOpGasLimit 取 200k 和 1M 时估计相差不超过 2k，说明帧确实烧到了上限，估计与 limit 无关。另有 penalty 对照，证明这个估计是上界而不是被 penalty 掩盖的值。

**Part 2（在 SP 上验证运营性质）**：同样用规范 EntryPoint，走最坏的 postOp 路径（`minTxInterval > 0`，要冷写 lastTimestamp）。断言是：用户被收的 charge ≥ 以验证时快照价格计算的最终成本 F×fee×(1+protocolFee)，并且 charge < a0，也就是没有被 a0 封顶掩盖。三个场景都通过，charge 与所需额之比约 1.26–2.56。

**变异**：
- `C_WRAP_GAS` 从 30k 改成 1k → `test_R10M3_…` 以精确值断言变红（49.61e18 ≠ 52.80e18）。这一条把源码常量与测试常量绑在一起。
- `bufWei = 0` → Part 2 的三个测试全部在 "user charge covers …" 这条断言上变红。
- buffer 去掉 postOpGasLimit 这一项 → 同样三红。

**结论（DSR 已确认：C_WRAP 保持 30k）**：
1. **在当前参数下，buffer 主要由 postOpGasLimit 项决定，C_WRAP 不起决定作用。** 把 C_WRAP 改成 1k，Part 2 依然通过，因为 `postOpGasLimit` 项（至少 200k，而 postOp 实际只用约 80k）已经远大于 wrap（约 1.7k）。C_WRAP 是第二重保险，30k 相对实测值有约 17 倍余量。改它要同时动合约常量和规范，不值得，所以不改。用户多付的主要来源是 postOpGasLimit 项；论文据此解释多付的来源（B-9 / R1-8），多付量的实测分布（均值、P95、最大值）放到 P2、P4 采集。
2. OP 主网的 L1 数据费不经过 EntryPoint 的记账，由 bundler 通过 preVerificationGas 回收。PVG 已经计入 P，所以不在 C_WRAP 需要覆盖的范围内。

## 4. A 层：SP 级对抗测试 — `74034e66`（及本节追加）

文件：`contracts/test/v2/SuperPaymasterV55Adversarial.t.sol`。

| 规范行 | 测试 |
|---|---|
| §8/§9 恶意 SP：当前 SP 调用全部 selector | `test_maliciousSP_current_calls_every_selector` |
| 同上，SP 轮换后的历史 SP | `test_maliciousSP_historical_calls_every_selector` |
| 预留 → 直接记债 → 结算（v2 里 3 个 3.x selector 必须不存在） | `test_maliciousSP_reserve_then_direct_debt_then_settle` |
| 全量调用所用 ABI 与编译产物一致 | `test_abi_fixture_matches_compiled_token_and_has_no_3x_debt_selectors`、`test_sweep_encoder_matches_abi_encode` |
| T-R14-01 Sybil | `test_TR1401_sybil_each_account_pays_own_lock_unbacked_zero_flat_in_N`（N=1/3/6） |
| T-R14-02 同账户多个 nonce key | `test_TR1402_same_account_multi_nonce_keys_kth_rejected_when_free_balance_below_x0` |
| T-R14-03 过期黑名单 | `test_TR1403_stale_blacklist_admitted_ops_settle_new_op_rejected` |
| T-R14-04 用户执行 revert | `test_TR1404_user_execution_revert_still_pays_and_clears_lock` |
| T-R14-05 postOp 回滚（含罚金） | `test_TR1405_postOp_revert_undoes_execution_operator_loss_le_a0_attacker_gain_zero` |
| T-R14-06 信用策略 OFF | `test_TR1406_credit_off_debts_never_increase_on_any_path` |
| T-R14-07 调 gas 攻击 | `test_TR1407_postOpGasLimit_sweep_via_entrypoint`、`test_TR1407_bundler_gas_sweep_never_keeps_unpaid_execution`、`test_TR1407_direct_postOp_gas_sweep_returns_only_when_settled`（本节追加断言：检查通过之后不存在 OOG） |
| T-R14-08 同 bundle 信用超额 | `test_TR1408_credit_bundle_over_cap_kth_rejected_at_validation` |
| T-R14-09 | 已在 D2：`SuperPaymasterV55Test.test_TR1409_*` |
| 路线 A：自抽干、maxCost 超上限 | `test_RouteA_self_drain_blocked_by_escrow_user_still_pays`、`test_RouteA_maxCost_above_single_tx_limit_rejected_not_truncated`、`test_RouteA_maxCost_above_auto_cap_rejected_not_truncated`；同 bundle 和多 nonce key 见 T-R14-01/02，postOp 回滚见 T-R14-05 |
| 旧代币 operator 得到 AA34 而不是 AA33 | `test_migration_legacy3x_token_operator_gets_sigFail_AA34_not_AA33`；`configureOperator` 拒绝 3.x 代币已由 `SecurityFixes_M4_M5_M7.t.sol::test_M4_*` 覆盖 |
| 验证期读汇率也要 try/catch（§3.3） | 本节追加 `test_token_without_exchangeRate_gets_sigFail_not_revert` |
| 只有 INSUFFICIENT 才转去信用 | `test_routing_invalid_renewal_never_falls_back_to_credit` |
| R1-3 六类 | 被盗 owner：`test_R13_stolen_owner_cannot_take_user_funds`；恶意工厂：`test_A9_*`、`test_A10_*`；重复转账：`test_R13_repeated_pulls_bounded_by_caps`；替换 SP：`test_R13_sp_replacement_pending_cannot_lock_old_sp_fails_closed`、`test_S*`；撤权：`test_R13_revocation_user_disable_and_emergency_reject_via_entrypoint`、`test_E*`、`test_C4_*`；批处理：`test_A7_*`、T-R14-01/02/08 |

**恶意 SP 全量调用的做法**：运行时解析 `abis/xPNTsTokenV2.full.json` 里的 148 个函数；53 个非 view 函数有显式分类表，ABI 多出或少了函数都会让测试失败。每个场景 1,599 次调用，每次都在快照里执行。管理员、签名、拉取、view 类调用要求 token 的全部存储都不变；只作用于调用者自身的函数，比对受害者状态和社区配置的摘要；四个特权入口按 I6 上界检查，并确认至少成功调用过一次（排除空转）。

**变异**（9 个，每个都在指名断言上变红）：a1 INSUFFICIENT 不再转去信用；a2 任何非 OK 都转去信用；b postOp 结算包 try/catch 吞掉失败（T-R14-05 变红）；c 去掉 `balance − locked < x` 检查；d 去掉 EXCEEDS_CAP；e 验证期不查 isBlocked；f SP 调 tryLockForGas 不包 try（→ AA33，变红）；g token 允许 SP 走 `_spendV2`；h 历史 SP 可以加锁。

## 5. D3 发现并修复的两处源码偏差（`contracts/src` 在 D3 里唯一的改动）

| 发现 | 修复 | 守护测试 | 变异 |
|---|---|---|---|
| `SETTLE_GAS_BOUND = 80k`，低于入口检查之后 postOp 剩余工作的实测值（约 137k；直接调用时最小成功 gas 约 144k，含入口前开销），中间存在"检查通过、随后 OOG"的区间。不构成漏洞：结算不包 try/catch，回滚会撤销用户执行；但注释说的"不开始可能半途耗尽的结算"是假的 | 改为 **160k**；注释写明覆盖范围和测量来源。`MIN_POST_OP_GAS = 200k` 在入口时仍剩约 193k，T-R14-09 经 EntryPoint 照常结算 | `SuperPaymasterV55Test.test_B1_no_oog_band_above_entry_guard`（BALANCE 和 CREDIT 两种模式，postOp gas 从 60k 扫到 260k，结果只能是 PostOpGasTooLow 或完整结算，且单调）；T-R14-07 直接扫描追加 `oog == 0` | 改回 80k → 在 "no OOG band: a postOp that passed the entry check must complete" 上变红 |
| 验证期 `IxPNTsTokenV2(token).exchangeRate()` 没有包 try/catch，与 §3.3 不符（一个没有该函数的代币会导致验证 revert，即 AA33）。目前走不到：`configureOperator` 只接受 v2 代币 | 改为 try/catch，出错返回 sigFail | `test_token_without_exchangeRate_gets_sigFail_not_revert` | 去掉 try → 在 "validation reverted (AA33 path)" 上变红 |

**体积**（按 CLAUDE.md 的纪律实测，`out/SuperPaymaster.sol/SuperPaymaster.json`，runs 500，source keccak 与当前源码一致；同目录的 `SuperPaymaster.default.json` 是 9 月 6 日的过期产物，已排除）：改动前 23,031 B，改动后 **21,857 B**（余量 2,719 B）。via_ir 的内联决策在这次改动后变了，所以体积反而变小。

## 6. I 层：不变量 I1–I7 — `b9a9e511`

文件：`contracts/test/v2/xPNTsTokenV2Invariant.t.sol`，共 8 个 `invariant_`。每个都内联配置 runs 64、depth 64、fail_on_revert；handler 往里注入过一个 revert，确认它确实会让测试失败。

- **handler 覆盖**：mint（含自动抵债）、transfer、transferAndCall、burn、两个 spender 的 transferFrom 和 burn(from)（一个是创世克隆，一个走 propose → 48h → activate）、历史 SP 和工厂的拉取（必须失败）、bundle（1–3 笔加锁或预留，中间插入执行期事件，然后在同一交易内结算）、只加锁不结算、过期结算、过期释放、releaseAndDisable、方案 A 和方案 B 续期（R2 的 8 种动作全部覆盖，含伪造签名）、用户设置、approveCredit、策略切换、分档源切换、repayDebt、updateExchangeRate、急停、备用 SP、proposeSP 和 activateSP、warp。
- **不变量**：I1 余额 = 影子；I2 各格子和总额的 used 与 cap 等于影子，窗口内的续期 ≤ K；I3 债务只来自消费已准入的预留；I4 lockedOf 和 creditReservedOf 等于记录之和，且 balance ≥ lockedOf；I5 过期结算必须 NotLive，交易内不能 release；I6 各项上界；I7 `effectiveCreditCap` 等于独立写的 C-0 计算；另有一条一致性检查（preview 与真实调用一致，状态机读回与影子一致）。
- **transient storage 的实测结果**（forge 1.7.1）：不开 isolate 时，每次 handler 调用是一笔独立交易；调用内部 TSTORE 保持有效，下一次调用时已清零。所以"验证 → 执行 → postOp"放在一次 handler 调用里完成。开 isolate 会让交易内结算全部失败，因此这个套件**不开** isolate。
- **变异**（13 个，均在指名断言上变红）：M1 去掉 `_update` 的锁检查；M2 settle 不减 lockedOf；M3a/b refund 退错格子或不退；M4 spRenew 忽略 K；M5 预留跳过 EXCEEDS_CAP；M6 记债超过预留额；M7 `_spendV2` 不记 used；M8/M9 忽略活标记（结算或释放）；M10 C-0 忽略 MANUAL；M11 有未结记录时仍能续期；M12 自动抵债多烧 1 wei；M13 settleCredit 不减 creditReservedOf。
- **由此修订规范（v3.9）**：I6 的烧毁上界改用 §10.2 的 `xc` 公式（原公式每笔会少算最多 1 wei，由 `test_I6_literalBurnBound_offByOneWei` 复现）；I2 的"用户亲自操作"澄清为用户对任意 spender 的续期。

## 7. M 层：迁移组断言的源码变异 — `0044bc95`

详见 [D3-M-layer.md](D3-M-layer.md)（完整的 107 行变异表、加强前后对照、不可判定项）；复现脚本在 `d3m/`。

- 范围：4 个迁移提交共新增或改动 360 行断言，涉及 119 个测试函数、22 个文件。
- 第 1 轮（按迁移组原样的测试）：99 个变异里，82 个在指名断言上变红，6 个只是 revert 冒泡出来（没有落在断言上），11 个全绿。
- 加强测试之后（改了 6 个测试文件，新增 4 个测试）：107 个变异里 **105 个在指名断言上变红**，剩下 2 个不可判定，原因如下。
- 不可判定项：
  - `P_live_off`：postOp 里 `_setInflightLive(false)` 这一行没有可观测效果，因为记录已经删除，`releaseStaleSponsorship` 看到空记录直接返回。保留无害。
  - `P_gas_bound`：在迁移测试里走不到。它由 v2 套件守住：`test_B1_postOp_entry_gas_guard`，以及 D3 新增的 `test_B1_no_oog_band_above_entry_guard`（§5）。
  - `test_DryRun_IsViewOnly_NoBalanceChange`：lens 和 token 的预览函数都是 view，写状态的变异编译不过，按构造无法判定。
- 有两处"未配置 operator"的检查在迁移测试里被 5.5.0 的 token 绑定遮住，改由加强后的 `SuperPaymaster_Coverage` D8（token 字段填 0）判定。
- M 层是在 §5 两处源码修复之前做的；合并之后以 `SETTLE_GAS_BOUND = 160k` 重跑了全量，结果为全绿。

## 8. 需要作者或 DSR 知悉的观察（未改）

1. **价格缓存未初始化**（`cachedPrice.price == 0`，也就是部署后第一次 `updatePrice` 之前）：validate 以 `OracleError` revert，而不是返回 sigFail（AA33 而不是 AA34）。5.4.x 也是这样，属于既有行为。runbook 第 5 步升级后先 `updatePrice` 即可规避；原地升级时缓存本来就有值。
2. `tryLockForGas` 和 `tryReserveCredit` 接受金额为 0 或 user 为 `address(0)`，会写一条 0 额的记录。这在 I6 上界之内，SP 自己总是传 a0 > 0。
3. 规范 v3.9 的澄清（I2 的"用户亲自操作"、I6 的烧毁上界）见 §6。

## 9. D3 汇总

| 层 | 交付 |
|---|---|
| O1 补测 | 41 个测试 + 20 个变异（§1） |
| DSR 的两条 Low | §2 |
| G | C_WRAP 在规范 EntryPoint 字节码上推导，约 1.7k，17 倍余量；SP 的 charge 覆盖最终成本（§3） |
| A | 24 + 1 个 SP 级对抗测试，含恶意 SP 全量 selector、T-R14-01…08、路线 A、R1-3、旧代币 AA34；9 个变异（§4） |
| 源码修复 | `SETTLE_GAS_BOUND` 从 80k 改为 160k；`exchangeRate` 改为 try/catch；各带守护测试和变异（§5） |
| I | 8 个不变量 I1–I7 + 一致性检查；13 个变异（§6） |
| M | 迁移组断言：107 个变异里 105 个指名变红，另 2 个不可判定（§7） |
| D6 | §10.2 状态转移表按 R10-M1b 重写，每格补 file:line；§2.5 的实现位置（`7394faec`） |
| D 一致性 | lens 与 validate：`test_lens_agrees_with_validation`（D2）；preview 与真实调用：I 层的一致性不变量 |
| B | 按 DSR 的决定移到 D5，作为验收硬门槛 |

**全量回归（D3 头部）**：Cancun 1597 通过 / 0 失败 / 49 跳过；Prague 1506 通过 / 0 失败 / 21 跳过。存储布局无漂移（SP 38 项、Registry 32 项），`abis/` 与编译产物一致。**D3 里的测试和变异检查全部由本地模型完成，还没有经过 Codex 对抗审查。**
