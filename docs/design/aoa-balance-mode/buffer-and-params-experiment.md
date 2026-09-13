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

> **Codex 结论**：Part A（`31921fbc`）APPROVE；Part B（`d7ae5099`）REQUEST CHANGES，已在 B2 修复（见文末「B2：Codex 第 1 轮修复」）；Codex 第 2 轮确认第 1 轮的问题全部关闭，但提出一个新的 HIGH（12 字 context 导致 bundle 中途升级时出错），已在 B3 修复；Codex 第 3 轮又提出一个 HIGH（B3 的打包方式导致 bundle 中途**回滚**到 5.5.0 时出错），已在 B4 修复。**`e0cf0dc8`（12 字，快照是第 12 个字但没有长度判断）和 `fb64e7eb`（快照打包进第 9 个字）都是中间格式，永远不得部署；这两者之间在语义上互不兼容。****B.1–B.5 描述的是 `d7ae5099` 时的状态，凡与 B2 冲突的地方以 B2 为准**（尤其是：execute 的安全论证、C_POSTOP/C_WRAP 下限、默认 C_POSTOP、体积与 gas 数字）。

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

## B2：Codex 第 1 轮修复（B 的第二个 commit，建在 `d7ae5099` 之上）

### 1. HIGH：验证与 postOp 之间的参数竞争（TimelockController + 开放 executor）

**问题（成立）**：验证期读的是旧的 `minPostOpGas`，postOp 读的却是当时的 `settleGasBound`、`cPostop`、`cWrap`。`d7ae5099` 用"execute 只允许 owner 调用"来论证安全，但如果 owner 是一个 executor 角色开放的 TimelockController（GOV-1 允许这样配置），任何账户都可以在一笔 UserOp 里触发 `timelock.execute`，时间点正好在 bundle 的验证之后、postOp 之前。于是已经通过验证的 op（limit 200k）会撞上 `gasleft() < 1M`，postOp 回滚，执行被撤销，gas 由 SP 的押金承担，这就构成了 griefing。

**修复**：验证时把 `settleGasBound`、`cPostop`、`cWrap` 打包成一个字写进 context，也就是 `OpCtx.gasSnap = settle | cPostop<<32 | cWrap<<64`。postOp 的入口检查直接从 context 的第 11 个字读 settle（在解码之前读），计费也用 context 里的 cPostop 和 cWrap。这样，通过验证的 op 一定按它验证时的那组参数结算。`minPostOpGas` 只在验证期使用，不需要快照。合约的安全性**不再依赖** onlyOwner；`executeGasParams` 的注释也已改写。
- **为什么打包成一个字**：先试过写成 3 个独立字段，SP runtime 变成 **24,908 B，超过 EIP-170（差 332 B）**，全部测试照样是绿的，因为 forge 测试不检查 EIP-170。打包成一个字之后是 **23,497 B（余量 1,079，高于 1,024 的门槛）**。**这说明需要单独的体积门槛，测试全绿不能代表可以部署。**
- **真实复现测试** `SuperPaymasterV55ParamRace.t.sol`：规范 EntryPoint；SP 的 owner 是 OpenZeppelin `TimelockController`（proposer 是 multisig，executor 是 `address(0)`，也就是开放的）。先经 timelock 执行 queue(MIN 1.1M, SETTLE 1M, C_WRAP 50k, C_POSTOP 1M)，等 SP 的 48 h，再把 `executeGasParams` 放进 timelock 并等到可执行。bundle 里第一笔是攻击者的 op（自付 gas，不经过 SP，所以 SP 这边没有任何东西能回滚它），它通过开放的 executor 执行这次参数修改；后面两笔是 SP 赞助的受害者 op（limit 200k）。断言：参数确实在 bundle 中途变了；受害者的 postOp **没有一笔失败**，都已结算，执行结果都保留；它们按**验证时**的 buffer 计费（`aGas` 按快照价格换算后落在 [G, G + (175k + 10% + 5k)·fee] 之内）；对照：一笔新 op 用 200k 的 limit 会被 AA34 拒绝，证明新参数确实生效了。
- **变异**：postOp 改回读实时的 settle → `B-HIGH-1: no admitted op's postOp fails …` 变红（2 笔失败）；计费改回读实时的 cPostop/cWrap → `B-HIGH-1: charged with the VALIDATION-time C_POSTOP / C_WRAP` 变红。
- **纵深防御**：GOV-1 仍然应当把 executor 角色限定为 multisig，但合约的正确性不依赖这一点。

### 2. HIGH：硬边界允许违反规则的配置

**修复**：提高下限，使**所有能通过边界检查的配置**都满足当前的 G 层规则：

| 参数 | 旧范围（d7ae5099） | 新范围 | 依据 |
|---|---|---|---|
| C_POSTOP | [150k, MIN] | **[175k, MIN]** | W_postop（B2 实测）146,817，×1.15 = 168,840，175k 还留出 +3.6% 的漂移空间。**默认值也从 170k 提到 175k**，因为默认值必须落在边界之内 |
| C_WRAP | [2k, 50k] | **[5k, 50k]** | 12 字 context 下 wrap 实测 1,770，余量 2.8 倍 |
| SETTLE_GAS_BOUND | [155k, 1M] | 不变 | 重新扫描：下限值 155k 上没有 OOG 区间（最坏的 CREDIT 路径，op limit 就取下限 MIN 175k） |
| MIN_POST_OP_GAS | [SETTLE + 20k, 2M] | 不变 | 全部取下限时 MIN = 175k = C_POSTOP 的下限，关系一致；SETTLE 取 155k 时 max minLimit 为 162,334 ≤ 175k |

**全下限组合 (MIN 175k, SETTLE 155k, C_WRAP 5k, C_POSTOP 175k)** 都经过真实的 queue/execute 配置上去，再分别跑两道检查：
- G 层规则 `test_rule_under_all_floor_params`：W 146,817，175k ≥ 168,840，wrap 1,770 ≤ 5k，MIN 175k ≥ minLimit 162,334，全部通过；
- G2 `testFuzz_G2_floor_params`（1000 runs，seed `0xd5c4`）和 `test_G2_coverage_replay_floor_params`（1000 个固定种子）：补贴 0 笔，其余断言全绿。

另外 G2 的判定常量改为从 `gasParams()` 读，并逐笔断言 context 里的快照等于验证时的参数。
- **变异**：C_POSTOP 下限改回 150k → `test_bounds_checked_at_queue` 变红。
- **R-AMS**：Amsterdam 会让 W_postop 和 wrap 都上升，所以一旦 Amsterdam 的激活时间公布，就必须重测，必要时通过 UUPS 升级提高这些**硬编码下限**；参数本身不能突破硬边界。

### 3. MEDIUM：版本号变更导致发布脚本失效

新增 `contracts/script/v3/SPReleaseVersion.sol`，这是版本号的**唯一来源**（`SP = "SuperPaymaster-5.5.1-exp"`，`LENS = "SuperPaymasterLens-1.1.0-exp"`）。改为引用它的有：`V55Bootstrap.SP_V55_VERSION` / `LENS_VERSION`（UpgradeToV5_5_0、DeployAnvil、DeployLive、TestAccountPrepare、InitializeTestCommunities、L4GaslessTest、DeployRepCreditSepolia 都继承它），以及 Check08、Check09、InitializeAAStar 里原来写死的字符串。新增 `SPReleaseVersionPin.t.sol` 断言 `SP.version()`、lens 的 `version()`、`lens.EXPECTED_SP_VERSION` 三者都和这个常量一致，所以 UpgradeToV5_5_0 第 5 步的读回（`sp.version() == SP_V55_VERSION`）和 lens 的读回都不会再中止。这些脚本都已单独编译通过。第 5 步读回还会逐字节比较 0..SNAPSHOT_SLOTS 的原始槽，新增的 slot 38/39 在升级后仍然是 0（使用默认值），所以不受影响。**真正发布时，只需要在这个文件里改成最终的版本号**，SP 和 lens 的字符串要同步改，pin 测试会守住三者一致。本轮**没有**在 fork 上重跑 UpgradeToV5_5_0，只做了静态核对，外加 pin 测试和脚本编译。

### 4. 重跑结果（B2 最终状态）

| 项 | 结果 |
|---|---|
| 存储布局 | `check_storage_layout.py`：OK（40 个条目，与 d7ae5099 的快照相同；只有声明过的 slot 38/39，`__gap` 25，结束槽不变） |
| 体积 | SP runtime **23,497 B**，余量 **1,079**（A 为 21,747；d7ae5099 为 23,452）。source keccak 与源码一致 |
| gas | 验证 232,429（A 为 229,557，**+2,872**：一次冷 SLOAD 加上多编码一个字）；postOp 140,403（A 为 140,186，**+217**） |
| W_postop / 规则 | 146,817；默认参数和全下限组合都满足 175,000 ≥ 168,840（余量 19.2%）；wrap 1,770 ≤ 5,000 |
| G2（默认参数） | 1000 runs 加 1000 个固定种子，补贴 0。多付率：≤ MIN+50k 为 24.8% / 39.7% / 47.1%，1.0–1.5M 为 19.2% / 29.8% / 33.7% |
| G2（全下限组合） | 同上，补贴 0。多付率：25.0% / 40.0% / 47.9%；19.3% / 29.8% / 33.7% |
| 负对照 | 默认 C_POSTOP 设为 73,400（约 W/2，fuzz 判定跟随 getter）→ fuzz 和覆盖测试都在 `DSR no-subsidy …` 上变红；计数模式下 4,407 笔中 2,625 笔被补贴 |
| 全量测试 | cancun 129 个 suite，1586 通过 / 0 失败 / 49 跳过；**prague 最后跑**，1495 通过 / 0 失败 / 21 跳过；之后又跑了一次 `forge build`（cancun 产物），体积数字取自这份产物 |

多付率比 A 高出约 1 个百分点，原因是默认 C_POSTOP 从 170k 提到了 175k。

## B3：Codex 第 2 轮修复（建在 `e0cf0dc8` 之上）

**Codex 第 2 轮**：第 1 轮的三项全部 CLOSED；新增 **HIGH**，已成立。B2 把 context 扩成了 12 个字，postOp 无条件读取 `context[352:384]`。假设受害者的 op 在**旧实现**（5.5.0，11 字 = 352 B context）下通过了验证，而同一个 handleOps 里，一笔自付 gas 的攻击者 op 通过 TimelockController 开放的 executor 执行一个已经可以执行的 `upgradeToAndCall(newImpl, "")`，那么受害者的 postOp 就会在新实现上越界读取并 panic：执行被撤销，gas 由 SP 押金承担，和第 1 轮是同一类 griefing。**B2 里"打包成一个独立的第 12 个字"的做法因此作废。**

### 修复

- **context 保持 5.5.0 的 11 字 / 352 B 布局不变**。快照放进第 9 个字，也就是原来的 `decimals` 字：`decSnap = decimals | settle<<8 | cPostop<<40 | cWrap<<72`。结构体里这个字段的类型从 `uint8` 改成 `uint256`，其余 10 个字的位置和类型都不变。5.5.0 产生的 context 在这个字里只有 `decimals`（等于 8），快照位是 0，按新结构体解码不会出错。
- **5.5.0 context 的回退规则（快照为 0 时）**：入口检查用 `LEGACY_SETTLE_GAS_BOUND = 160_000`；buffer **按 5.5.0 的原公式** `postOpGasLimit + ⌈10%·(callGas+postOpGas)⌉ + LEGACY_C_WRAP_GAS 30_000` 计算。理由有三：① 这正是这笔 op 被准入和被报价时依据的公式，a0 也是按它预留的；② 这个公式比新公式更保守（G2 在旧公式下同样零补贴，见 A.4），不存在少收的风险；③ 如果回退到新常量（175k + 5k），同一笔 op 会在实现切换的一瞬间被换一套报价方式，没有必要。新实现产生的 context 总是带非零快照（SETTLE 下限是 155k）。
- 入口检查在解码之前读第 9 个字（`context[288:320]` 右移 8 位），不再读取第 352 字节之后的任何数据。

### 测试

- `SuperPaymasterV55UpgradeRace.t.sol`：**当前 5.5.0 实现**的字节码作为固定文件入库（`contracts/test/fixtures/superpaymaster-5.5.0-impl.creation.hex`，由 feat/aoa-balance-mode-5.5.0 的 SP 源码构建，source keccak `0xab8309da…`，runtime 22,915 B，与 D3 的记录一致）。代理最初指向这个实现，owner 是 OpenZeppelin TimelockController（executor 开放）。bundle 的第一笔是攻击者的自付 op，它通过开放的 executor 执行 `upgradeToAndCall(实验版实现, "")`；后面两笔受害者 op 都是由 **5.5.0 实现**验证的。断言：升级确实在 bundle 中途发生了（`version()` 和 ERC1967 实现槽都已读回）；**两笔受害者的 postOp 都没有失败**，都已结算，执行结果都保留；计费落在**验证时（5.5.0 公式）**的上下界之内。
- **变异**：新实现换成 `e0cf0dc8` 的 12 字版本 → `round 2: no victim postOp fails …` 变红（2 笔失败），这正是 Codex 描述的场景；回退分支改成"不给 buffer" → `charge covers the op's cost` 变红（出现补贴）；第 1 轮的两个参数竞争变异在新代码上重跑，仍然变红。
- G2 的判定改为从 `decSnap` 读快照（`decimals = uint8(decSnap)`，并断言 104 位以上没有多余的位）。

### 规范规则（建议并入 03-final-spec；DSR 已在 `40ed8c0f` 写入规范）

> **OpCtx 布局是升级兼容面**：任何一次 SP 升级，都必须保证**上一版实现产生的 context 能被新实现正确结算**，包括长度、每个字的位置和类型，以及缺少新字段时有明确的回退语义。**必须有测试覆盖"从上一个发布版本在 bundle 中途升级"**：规范 EntryPoint；owner 是 executor 开放的 TimelockController；由上一版验证、由新版结算，断言 postOp 不失败，计费落在验证时的界限之内。

**纵深防御**：GOV-1 应当把 timelock 的 executor 限定为 multisig。但合约的正确性不依赖这一点，也就是说，参数修改（B2）和升级（B3）即使在 bundle 中途执行，也都已经被证明是无害的。

### 重跑结果（B3 最终状态）

| 项 | 结果 |
|---|---|
| 体积 | SP runtime **23,532 B**，余量 **1,044**（高于 1,024 的门槛，只多 20 B）；source keccak 与源码一致 |
| 存储布局 | OK（40 个条目，与 d7ae5099 的快照相同） |
| gas | 验证 232,364（A 为 229,557，+2,807）；postOp 140,354（A 为 140,186，+168） |
| W_postop / 规则 | 146,768；默认参数和全下限组合都满足 175,000 ≥ 168,784（余量 19.2%）；wrap 1,702 ≤ 5,000（context 恢复为 11 字） |
| G2 | 默认参数和全下限组合都是 1000 runs 加 1000 个固定种子，**补贴 0**。多付率 ≤ MIN+50k 为 24.9% / 39.7% / 47.2%，1.0–1.5M 为 19.3% / 29.9% / 33.7% |
| 负对照 | 默认 C_POSTOP 设为 73,400 → 4,407 笔中 2,620 笔被补贴，`DSR no-subsidy` 断言变红 |
| 两个竞争测试 | 参数竞争（B2）和升级竞争（B3）都通过 |
| 全量测试 | cancun 130 个 suite，1587 通过 / 0 失败 / 49 跳过；**prague 最后跑**，1496 通过 / 0 失败 / 21 跳过；之后又跑了一次 `forge build`，体积取自这份产物 |

**体积警示**：SP 只剩 20 B 的富余，任何新增的代码都会让它跌破 1,024 的门槛。另外，把快照写成 3 个独立字段的那一版编出来是 24,908 B，但测试照样全绿（见 B2）。建议给 SP 单独加一道体积门槛（CI 跑体积检查脚本），因为 forge 测试不会检查 EIP-170。

## B4：Codex 第 3 轮修复（建在 `fb64e7eb` 之上）

**Codex 第 3 轮**：B3 的其余部分都已核对无误（正向解码逐字段兼容；旧 context 的回退与 5.5.0 完全一致；新 context 的快照不会为 0；打包没有重叠；lens 一致；固定字节码确实就是 5.5.0 源码，hash `0xab8309da…fe4`；23,532 B / 余量 1,044）。新增 **HIGH**，已成立：B3 把快照打包进了第 9 个字（`decimals` 的高位）。如果在 bundle 中途**回滚**到 5.5.0（`docs/deployment/2026-06-01-security-upgrade-checklist.md:117` 明确支持回滚），5.5.0 的 `abi.decode(context, (OpCtx))` 会在 uint8 字段上发现高位不干净，于是 revert（solc 0.8.33 的 `validator_revert_uint8`）。结果是每一笔受害者 op 的 postOp 都失败，gas 由 SP 承担。

### 修复（按 Codex 提出的方案）

- **context 里的每个字都保持它在 5.5.0 中的 ABI 规范类型**：第 9 个字恢复为 `uint8 decimals`。**以后任何时候都不得把数据打包进窄类型的字。**
- **新实现输出 384 B 的 context**：原来的 11 个字一个不改，后面追加第 12 个字，内容是验证时的 GasParams 槽（`minPostOpGas | settle<<32 | cWrap<<64 | cPostop<<96`，因为会代入默认值，所以永远不为 0）。编码用一个 12 字段的 `OpCtxOut` 结构体；解码只用 `OpCtx`（11 字段，末尾多出的字会被忽略）。
- **新实现按长度判断格式**：长度恰好是 384 → 读快照，而且**只在这种情况下**才读第 12 个字（用汇编 `calldataload`）；其他长度（5.5.0 的 context 是 352 B）→ 没有快照，按 5.5.0 的规则处理（SETTLE 160k，buffer 用旧公式，仍然受 a0 封顶）。
- **5.5.0 解码 384 B 的 context**：静态结构体的 `abi.decode` 会忽略末尾多出的字节。**这一点由回滚测试实际证明**，没有靠推断。
- 体积：把"追加一个字"写成 `bytes.concat(...)`，或者对 context 做切片读取，编出来都**超过了 EIP-170**（分别是 24,848 B 和 24,804 B）。改成用 `OpCtxOut` 编码、用汇编读取、快照直接取整个 GasParams 槽（验证期不再在内存里拼结构体），最后是 **23,541 B，余量 1,035**（高于 1,024 的门槛，只多 11 B）。

### 测试（`SuperPaymasterV55UpgradeRace.t.sol`）

两个方向都用规范 EntryPoint 和真实的 TimelockController（executor 开放），由自付 gas 的攻击者 op 在 bundle 中途执行升级：
- **正向**（5.5.0 固定字节码 → 实验版，保留原测试）：受害者由 5.5.0 验证、由实验版结算；postOp 都没有失败，执行结果都保留，按 5.5.0 公式计费。
- **回滚**（新增）：代理最初指向实验版，受害者由实验版验证（事先探测：context 长度 384，第 9 个字等于 8，是干净的 uint8），攻击者 op 回滚到已入库的 5.5.0 字节码。断言：`version()` 和实现槽都已读回为 5.5.0；**两笔受害者的 postOp 都没有失败**，都已结算，执行结果都保留；按 5.5.0 公式计费（落在上下界之内）；**守恒成立**：operator 减少的量 = 两笔 charge 之和 = revenue 增加的量 = 供应量减少的量 = LockSettled 里 xBurned 之和；在途记录和锁都已清空。探测到的格式断言放在结算断言**之后**，这样格式出错时，最先变红的是指名的结算断言。

### 变异（每个变异都在正向、回滚、参数竞争、精确计费四列上各跑一遍；表内每行只该让一列变红，其余几列是它本不该影响的对照）

> **更正（Codex 第 4 轮，LOW，证据问题）**：本表原来的 (b) 写作"不做长度判断直接读第 12 个字 → 正向变红"，**这个说法不对**。当时实际做的改动是把整个 `if` 替换成**带越界检查的 Solidity 切片** `snap = uint256(bytes32(context[352:384]));`，352 B 的 context 在切片时越界 revert，所以正向变红。那是另一个变异，现在标为 **(b-slice)**。按字面意思"只删掉长度条件、保留汇编读取"（**b-nolen-asm**）是一个**等价变异**，四列全绿。原因是：EntryPoint 用标准 ABI 编码调用 `postOp`，`context` 是 calldata 里最后一个动态尾部，352 B 又是 32 的整数倍，所以 `calldataload(context.offset + 352)` 正好从 calldatasize 开始读；越界的 CALLDATALOAD 返回 0，快照为 0，于是走旧规则，结果与有长度判断时完全相同。**因此长度判断是纵深防御**：只有 context 不是 calldata 尾部，或者长度既不是 352 也不是 384 时，它才会起作用；而 `onlyEntryPoint` 加上 EntryPoint 的标准编码使这两种情况在实际中都不会出现。**长度判断保留，合约代码不改。** 本轮没有新增"强行读取非零第 12 个字"之类的变异，因为它对应不到任何真实的调用路径。
>
> 可复现的 patch 和四列日志放在 `data/mutations/`：`b-nolen-asm.patch/.columns.log`、`b-slice.patch/.columns.log`、`c-384-as-legacy.patch/.columns.log`，都是在 `6c3a9a0e` 的 SP 源码上生成的（日志头里写的是 `8241349b`，这个 commit 只加了数据文件，SP 源码与 `6c3a9a0e` 相同）。

| 变异 | 正向 | 回滚 | 参数竞争 | 计费（精确值） |
|---|---|---|---|---|
| (a) 快照放回第 9 个字（也就是 `fb64e7eb` 的实现） | 绿 | **红**：`rollback: no victim postOp fails after a mid-bundle upgrade: 2 != 0` | 绿 | 绿 |
| (b-nolen-asm) 只删掉长度条件（仍用汇编 `calldataload` 读第 12 个字） | 绿 | 绿 | 绿 | 绿（G2 的精确判定也是绿）——**等价变异**，见上面的更正 |
| (b-slice) 无条件用带越界检查的 Solidity 切片 `context[352:384]` 读取（原表误标为 (b) 的那个改动） | **红**：`forward: no victim postOp fails after a mid-bundle upgrade: 2 != 0` | 绿 | 绿 | 绿（G2 的精确判定也是绿） |
| (c) 384 B 的 context 也按旧格式处理 | 绿 | 绿 | 绿（它的计费断言只检查上界，看不出这个差别） | **红**：`test_c_postop_and_c_wrap_parameters_drive_the_charge`，报 `defaults: 40.7e18 != 35.2e18`；G2 的精确判定也红：`R10-M3: aGas == … (exact)` |

### 重跑结果（B4 最终状态）

| 项 | 结果 |
|---|---|
| 体积 | SP runtime **23,541 B**，余量 **1,035**；source keccak 与源码一致 |
| 存储布局 | OK（40 个条目，没有变化） |
| gas（对比 A） | 验证 231,786（+2,229）；postOp 140,439（+253） |
| W_postop / 规则 | 146,853；175,000 ≥ 168,881（余量 19.2%），默认参数和全下限组合都成立；wrap 1,770 ≤ 5,000（context 为 12 字） |
| G2 | 默认参数和全下限组合都是 1000 runs 加 1000 个固定种子，**补贴 0**。默认参数下的多付率：全部 23.7% / 38.8% / 47.2%；≤ MIN+50k 为 24.9% / 39.7% / 47.2%；1.0–1.5M 为 19.3% / 29.9% / 33.7% |
| 负对照 | 默认 C_POSTOP 设为 73,400 → 2,639 笔被补贴，`DSR no-subsidy` 断言变红 |
| 全量测试 | cancun 130 个 suite，1588 通过 / 0 失败 / 49 跳过；**prague 最后跑**，1497 通过 / 0 失败 / 21 跳过；之后又跑了 `forge build`，体积取自这份产物 |

**规范规则的补充**（在 B3 的规则上增加）：OpCtx 在**两个方向**上都是兼容面。正向要求新实现能结算旧格式；回滚要求旧实现能解码新格式：每个字都保持 ABI 规范类型，新增内容只能追加在末尾，而且新实现只在长度匹配时才读新增的字。测试必须同时覆盖"从上一个发布版本升级"和"回滚到上一个发布版本"这两种 bundle 中途的切换。GOV-1 仍应把 executor 限定为 multisig，作为纵深防御。

**G2 导出钩子**：已把 `feat/aoa-balance-mode-5.5.0@501eb0d6` 的 `_exportOp` 移植过来（除了 bufGas 那一行和 formula 标签之外，其余逐字相同；默认关闭）；数据文件另见数据 commit。
