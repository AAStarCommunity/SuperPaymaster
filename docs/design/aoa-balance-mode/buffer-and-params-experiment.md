# buffer 收紧 + 参数治理 实验（分支 `exp/buffer-and-params`，2026-09-13）

> 状态：**实验原型**，基线 `215fb340`。不合并，除非作者批准。依据：`buffer-tightening-eval.md` §2、§5（DSR 条件），`03-final-spec.md` §10.1、§10.8b R-AMS、§11 R10-M3。
> 所有数字都在本分支实测：forge 1.7.1，solc 0.8.33，via_ir，optimizer 500，cancun（G2 另跑了 prague），规范 EntryPoint v0.7 字节码（codehash `0x8db5ff69…`）。

## Part A：buffer 收紧（commit A）

### A.1 改动

```
旧：bufWei = (postOpGasLimit + ⌈(callGas + postOpGas)·10/100⌉ + C_WRAP 30k) × feePerGas
新：bufWei = (C_POSTOP 170k + ⌈(callGas + postOpGas)·10/100⌉ + C_WRAP 5k) × feePerGas
charge = min(a0, ⌈calc_snap(actualGasCost + bufWei) × (BPS + fee) / BPS⌉)   （不变）
```

- `SuperPaymaster.sol`：新增常量 `C_POSTOP_GAS = 170_000`，`C_WRAP_GAS` 从 30,000 改为 5,000，buffer 里的 `c.postOpGas` 换成 `C_POSTOP_GAS`。惩罚项不变。`MIN_POST_OP_GAS = 200k ≥ C_POSTOP`，所以 `min(postOpGasLimit, C_POSTOP) == C_POSTOP`。
- 测试：新增 `SuperPaymasterV55PostOpBound.t.sol`（G 层规则）；D3 探针移到 `contracts/test/helpers/V55GasProbes.sol`，两个测试共用；以下测试的公式常量同步更新：`SuperPaymasterV55.t.sol`（R10M3）、`SuperPaymasterPricingV2.t.sol`、`SuperPaymasterV3_Pricing.t.sol`（精确数值），`SuperPaymasterV55Gas.t.sol`（C_WRAP 改为 5k，余量断言从 ≥5 倍改为 ≥2 倍），G2 fuzz 的精确判定。
- 体积：SP runtime **21,747 B**，余量 2,829 B；基线 22,915 B，余量 1,661 B。产物的 source keccak 与源码一致。体积**减少了 1,168 B**，这主要是 via_ir 内联决策变化带来的（D3 已经记录过这种波动），不能当作这个改动的"收益"，下一次改动之后要重新实测。

### A.2 G 层规则：`C_POSTOP ≥ W_postop × (1 + m)`，m = 15%

`W_postop` 在测试里现场测量，不抄常数。postOp 的调用方式和 EntryPoint v0.7 `_postExecution` 相同：从 EntryPoint 地址发起 `postOp{gas: limit}(mode, context, actualGasCost, gasPrice)`，与产生这个 context 的验证在**同一笔交易**里（和生产环境一样，验证带来的 EIP-2929 热访问是真实存在的，活标记也还在），而且调用的是 SP 代理，所以 delegatecall 也计入在内。

每条路径测两个量：
- **consumed**：postOp 这次 CALL 让调用方付出的 gas（被调帧 + CALL 自身开销），预算 1M。这是 EntryPoint **实际计费**的量：SP 调 token 时 63/64 规则预留下来的那部分 gas 没有被消耗，会退回。所以 `W_postop = max(consumed)`。
- **minLimit**：能让调用成功的最小 `{gas: g}`。它**不计费**。在所有路径上它都等于 SETTLE_GAS_BOUND（160k）加上入口检查之前的开销，也就是由入口检查决定的，所以拿它去对照 `MIN_POST_OP_GAS`，而不是对照 C_POSTOP。

| 路径 | consumed | minLimit |
|---|---|---|
| BALANCE，首次用户，限频时间戳冷写 | 132,589 | 167,388 |
| **CREDIT，首次用户，限频时间戳冷写，首笔债务** | **146,600** | 167,388 |
| BALANCE，急停期间结算（E-2） | 132,589 | 167,388 |
| CREDIT，急停期间结算（E-2） | 146,600 | 167,388 |
| BALANCE，SP 更换后由旧 locker 结算（L-3） | 132,589 | 167,388 |
| CREDIT，SP 更换后由旧 locker 结算（L-3） | 146,600 | 167,388 |
| BALANCE，不写限频时间戳（对照） | 112,257 | 167,388 |
| BALANCE，charge 被 a0 截顶、没有退款分支（对照） | 131,237 | 167,388 |

- 每条路径都在全新状态（operator 计数、protocolRevenue、用户各槽都是第一次写）上测，用 snapshot 恢复。context 永远是 11 个静态字（352 B），所以"最长的实际 context"就是它，测试里有断言。
- 每次测量都带正对照：这次调用确实完成了结算（`usedOpHashes[h]` 为真，记录已被消费）。
- **W_postop = 146,600**（CREDIT）。`W × 1.15 = 168,590 ≤ C_POSTOP_obs = 170,000`，**规则通过**，实际余量 15.96%（很紧）。
- `C_POSTOP_obs` 不是抄的常数，而是从 SP 自己的 charge 反解出来的。价格取 ETH 2000、aPNTs 0.02、fee 10%、1 gwei，这样每一步取整都是精确的，可以得到 `C_POSTOP + C_WRAP = 175,000`，再减去 C_WRAP 的规范值 5k。源码里任一常量调低，这个和就会变小，只会让规则变红。
- `wrap`（EntryPoint 在 postOp 调用外面的开销，D3 探针，规范字节码）实测上界 1,702，满足 ≤ C_WRAP 5k。
- 非计费要求：`MIN_POST_OP_GAS 200k ≥ max minLimit 167,388`。

**变异**：`C_POSTOP_GAS` 改为 160k → `rule: C_POSTOP >= W_postop x (1 + m)` 变红（160,000 < 168,590），逐路径断言也变红（CREDIT 路径）。`C_WRAP_GAS` 改为 3k → 同一条规则变红（168,000 < 168,590）。

### A.3 G2 fuzz（新公式）

精确判定改成新公式（`C_POSTOP + 惩罚上界 + C_WRAP`）。"不补贴"（每笔 `eth ≥ actualGasCost`）是零容忍门槛，现在放在每笔检查的**最前面**。
- 结果：1000 runs（seed `0xd5c2`）加 1000 个固定种子，cancun 和 prague 都全绿。**补贴 0 笔**，I9 无后盾赞助 0 / 0，其余覆盖下限不变（已结算 BALANCE 3,271 笔、CREDIT 1,127 笔，注入失败 1,671 笔，精确比对 4,398 次等）。
- 全量 `forge test`：cancun 125 个 suite，1569 通过 / 0 失败 / 49 跳过；prague 1478 通过 / 0 失败 / 21 跳过。

**负对照**（DSR 要求；源码常量和 fuzz 判定里的常量同步改；`G2_COUNT_SUBSIDY=true` 时逐笔计数，不在第一笔就停）：

| C_POSTOP | 结果 |
|---|---|
| 73,300（= W/2），严格模式 | fuzz 和覆盖测试都在 `DSR no-subsidy: net-of-fee charge … >= op's actualGasCost` 上**变红** |
| 73,300，计数模式 | 4,407 笔中 **2,620 笔被补贴**，合计 0.116 ETH，单笔最多少收 13.4%；`subsidised settled ops over the campaign == 0` 变红 |
| 115,000 | 230 笔被补贴，变红 |
| 120,000 | 59 笔被补贴，变红 |
| 126,600（= W − 20k） | **0 笔，保持绿** |

**需要注意的结论**：fuzz 只能发现"低于 W 大约 25k 以上"的错误。原因是还有两块结构性余量没有收紧：一是惩罚项的上界 `10%·(callGas + postOpGas)` 比 EntryPoint 实际收取的惩罚至少多出 `10% × 已用执行 gas`，而已用执行 gas 包含 postOp 帧本身，所以这块余量至少约 13–15k；二是 C_WRAP 比实测 wrap 多出约 3.3k。所以 W − 20k 时仍然没有补贴。**真正卡住 C_POSTOP 下限的是 G 层规则**（W − 20k 会让规则变红）。fuzz 的负对照证明它能看见补贴，但它是第二道、更宽松的防线。

### A.4 多付率 (eth − G)/G：新旧对照

同样 1000 个固定种子；eth 是扣掉协议费、按验证期价格快照换算成 ETH 的收费。

| 公式 | 分组 | 笔数 | 均值 | P95 | 最大 |
|---|---|---|---|---|---|
| **旧**（limit + 10% + 30k） | 全部 | 4,389 | 83.2% | 269.6% | 371.1% |
| | postOpGasLimit ≤ MIN+50k | 3,489 | 41.8% | 61.3% | 81.5% |
| | postOpGasLimit 1.0–1.5M | 900 | 243.4% | 305.3% | 371.1% |
| **新**（C_POSTOP 170k + 10% + 5k） | 全部 | 4,398 | 22.6% | 37.4% | 45.6% |
| | postOpGasLimit ≤ MIN+50k | 3,492 | 23.7% | 38.3% | 45.6% |
| | postOpGasLimit 1.0–1.5M | 906 | 18.3% | 28.8% | 32.5% |

m 对新公式多付率的影响（C_POSTOP = ⌈W × (1+m) / 1k⌉ × 1k，W = 146,600；每个 m 都重跑了一遍 1000 个种子，补贴都是 0）：

| m | C_POSTOP | ≤ MIN+50k 均值 / P95 / 最大 | 1.0–1.5M 均值 / P95 / 最大 |
|---|---|---|---|
| 10% | 162,000 | 21.6% / 35.7% / 42.5% | 16.7% / 26.8% / 30.4% |
| 15% | 169,000 | 23.4% / 38.0% / 45.2% | 18.1% / 28.5% / 32.3% |
| （本分支） | 170,000 | 23.7% / 38.3% / 45.6% | 18.3% / 28.8% / 32.5% |
| 25% | 184,000 | 27.3% / 42.9% / 50.8% | 21.2% / 32.2% / 36.2% |

- 旧公式在大 limit 那组的多付（均值 243%）几乎完全消失了。剩下约 20% 的多付主要来自惩罚项的上界：它按 limit 而不是按实际未用量计算，这一项按设计保持不变（eval §2）；其次才是 C_POSTOP 相对 W 的余量和 C_WRAP 的余量。
- 本分支取 170k 时 m 实际约为 16%。作者如果要取 m = 15%，按规则应当是 169k；二者对多付率的影响只有约 0.3 个百分点。
- **R-AMS**：Amsterdam（EIP-8037/8038）会让 SSTORE、SLOAD、CALL 变贵，W_postop 随之上升。一旦目标链公布 Amsterdam 的激活时间，必须在 Amsterdam 级的链上重跑 `SuperPaymasterV55PostOpBound`（W_postop 和规则）；规则不满足时，Part A 只能通过 UUPS 升级下发新常量（Part B 把它改成了带 48 h 时间锁的参数）。

## Part B：把 gas 参数改成治理参数（commit B，建在 A 之上，可以单独评判）

### B.1 改动

- `MIN_POST_OP_GAS`、`SETTLE_GAS_BOUND`、`C_WRAP`、`C_POSTOP` 四个值改成 owner 可设的存储参数，放在一个槽里（4 个 uint32，`GasParams`，slot 38）。待生效值加上 eta 放在另一个槽里（`PendingGasParams`，slot 39）。这两个槽追加在 `_inflight`（slot 37）之后，`__gap` 从 27 改为 25；`storage-layout/SuperPaymaster.json` 已经用 `scripts/check_storage_layout.py update` 更新，重新检查结果为 OK（40 个条目）。
- **槽全为 0 时使用默认值**（200k / 160k / 5k / 170k，也就是原来的常量，SP `_gp()` :1416）。所以原地升级不需要额外的初始化步骤，旧代理升级之后行为不变。
- `queueGasParams`（onlyOwner，:1431）→ 48 h → `executeGasParams`（:1440）→ 可以 `cancelGasParams`。硬编码的上下界在 queue **和** execute 两处都检查，关系约束也包含在同一个检查里。事件：`GasParamsQueued`、`GasParamsExecuted`、`GasParamsCancelled`。查询：`gasParams()` 返回当前生效值（未设置时返回默认值）和待生效的提议。
- **execute 只允许 owner 调用**（没有做成任何人都能调）。原因：如果任何人都能调，就可以在某个 bundle 里由一笔 user op 的执行去调用它，时间点正好在这个 bundle 的验证之后、postOp 之前。这样一来，已经通过验证的 op 在 postOp 时会遇到新的 SETTLE_GAS_BOUND：如果调高了，这些 postOp 会触发 PostOpGasTooLow，也就是 I10 情形，赞助失败；如果 C_POSTOP 变了，charge 也会跟着变（仍然受 a0 封顶）。
- 验证期读 `_gasParams.minPostOpGas`（:1256）：这是一次冷 SLOAD，读的是 SP 自己的槽。SP 是质押过的，所以符合 STO-031。postOp 在入口检查之前读整个 `GasParams`（:1370），此时这个槽已经是热的。
- `SuperPaymasterLens` 不再保留 MIN_POST_OP_GAS 的副本，改为从 SP 的 `gasParams()` 读。lens 绑定的 SP 版本改为 `"SuperPaymaster-5.5.1-exp"`，SP 的 `version()` 也同步修改（**只在本分支**）；lens 自己的版本为 `SuperPaymasterLens-1.1.0-exp`。`contracts/script/` 里还有 6 处写死了 `"SuperPaymaster-5.5.0"` 的读回校验，本实验没有改，所以部署脚本在这个分支上会拒绝这个版本号；如果采纳，需要一起更新。

### B.2 上下界及其依据（在本分支实测）

| 参数 | 硬编码范围 | 依据 |
|---|---|---|
| SETTLE_GAS_BOUND | **[155k, 1M]** | 在 SETTLE 取不同值时，对最坏路径（CREDIT、首笔债务、限频时间戳冷写）扫描 postOp 可用 gas：**143k 时仍有 OOG 区间（入口检查通过、结算中途耗尽），144k 起没有了**。取 155k 留出 7.6%。**建议里的 120k 不安全**（140k 时实测 39 个采样点落在 OOG 区间）。`test_settle_floor_keeps_no_oog_band` 在下限值上重新扫描，守住这一点 |
| MIN_POST_OP_GAS | [SETTLE + 20k, 2M] | 入口检查之前的开销实测约 8.1k（minLimit 168,139 − 160k），20k 约为它的 2.5 倍 |
| C_POSTOP | [150k, MIN_POST_OP_GAS] | 下限高于实测 W_postop（B 为 147,478）；上限 ≤ MIN，保证 `min(limit, C_POSTOP) == C_POSTOP`。**注意**：下限 150k **不满足** m = 15% 的规则（规则要求 169.6k）。规则由 G 层测试守住，而 G 层测试测的是当前生效的参数值。按 A.3 的负对照，C_POSTOP ≥ 约 W − 20k 时实际不会产生补贴，所以 150k 仍然不会造成补贴；但到了 Amsterdam，W 会上升，这个下限就保护不了 |
| C_WRAP | [2k, 50k] | EntryPoint 的 wrap 实测 1.7k |

测试 `SuperPaymasterV55GasParams.t.sol`（11 个）：默认值和槽位置（slot 38 为 0 表示默认值；slot 38/39 的打包方式）；queue、execute、cancel、时间锁、事件、重新 queue 会重新计时；非 owner 调用被拒；每个上下界的边缘值被接受、越界 1 被拒；execute 时重新检查上下界（用篡改存储的方式验证）；MIN 参数确实驱动验证和 lens；SETTLE 参数确实驱动 postOp 的入口检查；C_POSTOP 和 C_WRAP 参数确实驱动 charge（精确值）；参数取到最大值时 charge 仍然被 a0 封顶；SETTLE 取下限值时没有 OOG 区间。

### B.3 体积和 gas

| 项 | A（常量） | B（存储参数） | 差 |
|---|---|---|---|
| SP runtime（default profile，source keccak 已核对） | 21,747 B | **23,452 B** | +1,705 B |
| 余量（相对 24,576） | 2,829 | **1,124** | 仍然 ≥ 1,024 的发布门槛，但只剩 100 B 富余 |
| 相对原基线 22,915 / 1,661 | — | +537 B | — |
| validatePaymasterUserOp（首次用户） | 229,557 | 231,693 | **+2,136**（一次冷 SLOAD 2,100 加少量解包） |
| postOp（BALANCE，限频时间戳冷写） | 140,186 | 141,064 | **+878** |

体积上 A 到 B 的 +1,705 B 里有一部分是 via_ir 内联决策变化带来的（A 本身比基线小了 1,168 B，也是同样的原因），但 B 的余量是实打实的 1,124 B。**如果采纳 B，之后的特性就几乎没有体积空间了。**

### B.4 重测 W_postop 和规则（B）

postOp 多了 878 gas，W_postop 从 146,600 升到 **147,478**（每条路径都增加了同样的量）。规则 `170,000 ≥ 147,478 × 1.15 = 169,600` **通过，余量 15.27%，已经贴着 15% 的线**。如果采纳 B，建议把默认 C_POSTOP 设为 175k 左右，否则下一次 postOp 稍微变重，规则就会变红。测试同时校验：getter 返回的 `C_POSTOP + C_WRAP` 等于 SP 实际计费用的值（175,000）；wrap 1,702 ≤ 5k；`MIN 200k ≥ max minLimit 168,139`。变异：默认 C_POSTOP 改为 165k，规则变红（165,000 < 169,600）。G2 fuzz 在 B 上（判定用的参数来自 `gasParams()`，并断言与判定常量一致）1000 runs 加 1000 个固定种子全绿，补贴 0，多付率（≤ MIN+50k）为 23.4% / 37.9% / 45.1%。全量 `forge test`：cancun 127 个 suite，1581 通过 / 0 失败 / 49 跳过；prague 1490 通过 / 0 失败 / 21 跳过。

### B.5 信任面

- **每笔多收不会超过 a0**：`charge = min(a0, …)`（SP `:1394`，`if (charge > c.a0) charge = c.a0`），而 a0 是在验证期按用户签名承诺的 maxCost 预留的。所以把 C_POSTOP 或 C_WRAP 调大，最多让每笔收到 a0，不可能超过。测试 `test_charge_capped_at_a0_even_at_max_parameters` 把四个参数都设到最大值来验证这一点。
- **比现状更窄**：owner 现在就可以立即做 UUPS 升级（`BasePaymasterUpgradeable.sol:42`，`_authorizeUpgrade … onlyOwner`，没有时间锁），可以直接把这些常量换掉，甚至换掉整个计费逻辑。改成参数之后，owner 可以在不升级的情况下调整它们，但必须经过 48 h 公示，而且只能在硬编码范围内调整。所以这个参数只会**缩小**实际的信任面，不会扩大（前提是 UUPS 升级权本身不变；信任矩阵 §10.7 对升级权的建议仍然适用）。
- 调小的方向同样有界：SETTLE ≥ 155k 守住了 no-OOG；C_POSTOP ≥ 150k、C_WRAP ≥ 2k 在当前 gas 规则下不会造成补贴（见 B.2 注意事项）；MIN ≥ SETTLE + 20k 保证 postOp 能开始执行。

## 需要作者关注的地方

1. **建议的 SETTLE 下限 120k 不安全**：实测 143k 时仍然有 OOG 区间，本分支改为 155k。
2. **W_postop 用"消耗"而不是"最小可用 limit"**：minLimit 在所有路径上都是 167–168k，它是由入口检查（SETTLE）决定的，不是结算本身的开销，而且 EntryPoint 不按它计费。如果用它作为 W，170k 会不满足规则（需要 192.5k），但那样取值是错的。
3. **规则余量非常紧**：A 为 15.96%，B 为 15.27%。如果 m 取 15%，建议 C_POSTOP 取 175k（多付率增加不到 1 个百分点）。
4. **fuzz 负对照的灵敏度**：只有低于 W 大约 25k 时才会报补贴，W − 20k 时仍然是绿的，原因是惩罚上界和 C_WRAP 的结构性余量。所以 G 层规则才是第一道防线。
5. **B 的体积余量只剩 1,124 B**。
