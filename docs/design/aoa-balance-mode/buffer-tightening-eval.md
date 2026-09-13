# postOp 计费 buffer 收紧评估（DSR 设计项，2026-09-13，草案）

> 状态：**评估中**。还没改合约。实验数据要等 G2 fuzz 按 Codex 意见修完之后再测（届时用修好的 fuzz 同时给出多付分布和"不补贴"断言）。结论要过一轮 Codex，最后由作者拍板（这是对 §11 R10-M3 计费公式的修改）。

## 1. 现在的公式（R10-M3）

```
bufWei = (postOpGasLimit + ⌈(callGasLimit + postOpGasLimit)·10/100⌉ + C_WRAP) × feePerGas
charge = min(a0, ⌈calc_snap(actualGasCost + bufWei) × (BPS + fee) / BPS⌉)
```

EntryPoint 最终从 SP 押金里扣的是 `G = P + wrap + postOpFrameUsed + penalty`（D3 §3）。所以按 gas 计，用户多付的部分由三项组成：

| 项 | 超出量 | 实测量级 |
|---|---|---|
| (a) postOp 项 | `postOpGasLimit − postOpFrameUsed` | limit 至少 200k；postOp 实际最坏约 137k（入口检查之后）+ 约 7k（入口检查之前）；limit 为 1–1.5M 时这一项会多出 100 万 gas 以上 |
| (b) 惩罚项 | `⌈10%·(callGas + postOpGas)⌉ − penalty_actual`，其中 `penalty_actual = ⌊10%·max(0, callGasLimit + postOpGasLimit − executionGasUsed)⌋` | ≈ 10% × 实际用掉的执行 gas（这是 EntryPoint 真实收取的费用；postOp 拿不到 `preOpGas`，所以没法精确算） |
| (c) C_WRAP | `30k − wrap` | wrap 实测约 1.7k（D3 §3）→ 多出约 28k |

G2 第一版数据（修复前，仅供参考）：全部 op 的多付均值 75.9%、P95 251%、最大 342%；postOpGasLimit ≤ MIN+50k 的 op 为 36.6% / 58.6% / 76.6%。可以看出主因是 (a)。

## 2. 方案

```
bufWei' = (C_POSTOP + ⌈(callGasLimit + postOpGasLimit)·10/100⌉ + C_WRAP') × feePerGas
```

- **C_POSTOP**：postOp 整帧 gas 的最坏上界，常量。它必须 ≥ postOp 在所有路径上的实测最坏值（BALANCE 或 CREDIT；首次写 lastTimestamp、幂等位、usedOpHash；SP 代理的 delegatecall；以及 SP 调 token 时 63/64 转发之后的开销），外加余量。现有实测：直接调用时最小成功 gas 约 144k（`test_B1_no_oog_band_above_entry_guard` 的扫描）。**候选值 170k**（约 18% 余量）。因为 `MIN_POST_OP_GAS = 200k ≥ C_POSTOP`，写 `min(postOpGasLimit, C_POSTOP)` 和直接写常量效果相同，所以直接用常量。
- **C_WRAP'**：从 30k 降到 **5k**（约为实测 1.7k 的 3 倍）。原来"C_WRAP 不承重"的前提是 (a) 项足够大；(a) 收紧之后 C_WRAP 会开始承重，所以要按实测重新定一个带余量的值。
- **惩罚项**：维持原样。它对应的是 EntryPoint 真实收取的费用。上界 `10%·(callGas + postOpGas)` 与实际值之差约等于 10% × 已用执行 gas。要进一步收紧，就得在 postOp 里知道 `preOpGas`，而 v0.7 没有提供；在 context 里带验证期的上界也只能给出更松的界。**结论：不收紧。**

**正确性（I9 不补贴）怎么守**：
1. G 层新增断言：postOp 整帧最坏 gas ≤ C_POSTOP（在规范 EntryPoint 字节码上测，覆盖两种模式、冷写和热写、代理），wrap ≤ C_WRAP'；并且保留"源码常量改小一档就变红"的变异。
2. G2 fuzz 的"不补贴"断言（每笔 `eth ≥ actualGasCost`）用新公式重跑一遍，要求全绿。
3. R-AMS：Amsterdam 会让 postOp 变贵，C_POSTOP 的重测已纳入 §10.8b 的触发条件；这个常量写死在字节码里，需要改时通过 UUPS 升级下发。

**风险**：C_POSTOP 一旦低于实际值，就会少收，也就是 I9 意义上的补贴。它的安全边际完全依赖 G 层测量覆盖到了最坏路径。postOp 的工作量是有界的（结算没有外部调用，SETTLE_GAS_BOUND 已经保证入口检查之后一定能跑完），攻击者没有办法让它多做事。postOpGasLimit 调得再大，也不会再抬高收费。

## 3. 预期多付（待测，粗估）

- postOpGasLimit 在 MIN 附近：(a) 从约 63k 降到约 26k，(c) 从约 28k 降到约 3k，典型多付估计从约 37% 降到 **约 12–18%**。
- limit 为 1–1.5M：(a) 从 100 万以上降到约 26k；(b) 本来就对应真实惩罚，差额不大。多付估计从 250%+ 降到 **约 15–25%**。
- 实际数字以修复后的 G2 fuzz 重测为准（均值、P95、最大值；两组分开）。

## 4. 下一步

1. G2 修完之后，在实验分支上改这两个常量，重跑 G2 fuzz，拿到多付分布，同时确认"不补贴"全绿。
2. G 层补上"postOp 最坏 gas ≤ C_POSTOP"的测量断言和变异。
3. 送 Codex 挑战（重点：C_POSTOP 的最坏路径是否覆盖完整；有没有让 postOp 超过 C_POSTOP 的输入）。
4. 结论和数据交 DSR 和作者：接受就实施（改 SP 常量和 §11 公式，G 层、G2 重跑，体积重测）；不接受就在论文里如实报告现在这组数字。
