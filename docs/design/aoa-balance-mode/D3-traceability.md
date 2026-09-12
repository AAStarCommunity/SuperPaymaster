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

**需要作者或 DSR 知悉的结论**：
1. `C_WRAP` 在当前参数下**不承重**。把它改成 1k，Part 2 依然通过，因为 buffer 里的 `postOpGasLimit` 项（至少 200k，而 postOp 实际只用约 80k）已经远大于 wrap。C_WRAP 是第二重保险，30k 相对实测值很保守。要不要收紧（比如改成 5k，仍有 3 倍余量），是参数取舍，会改动合约常量，本次不改。
2. OP 主网的 L1 数据费不经过 EntryPoint 的记账，由 bundler 通过 preVerificationGas 回收。PVG 包含在 P 里，所以不属于 C_WRAP 需要覆盖的范围。
