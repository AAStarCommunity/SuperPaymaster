# SuperPaymaster Backlog Triage + 版本规划

> 生成于 2026-06-14 · 方法:Opus 深度探索 36 个 open issue + 代码/git 核对 + 对抗判断 · 当前 HEAD = #277 merge

## 1. 当前状态

| 项 | 值 |
|---|---|
| 当前版本 | **v5.3.3-beta.3** (SuperPaymaster-5.3.3 / Registry-5.3.3) |
| 刚完成 | 审计二次 review —— 6 个 PR merged(#273-#278),8 wontfix,1 defer |
| 未 tag | **#273-#278 已在 main 但还没打 beta.4 tag** |
| Milestones | #2 Mainnet Launch Blockers(1 open=tracking #272)· #1 v5.4(30 open) |
| open issues | 36 |
| 硬约束 | SuperPaymaster.sol 仅 **~126B EIP-170 余量**,碰 SP 的修复需先减肥 |

---

## 2. 立即可做的清理(DONE-CLOSE / STALE) — 把 backlog 36 → ~31

| Issue | 处置 | 证据 |
|---|---|---|
| **#245** H-1 credit ceiling | ✅ **关闭** | 已被 #273 修复,`_creditExceeded`(SP.sol:814-817)代码逐字匹配 Plan A,balance 短路已删 |
| **#209** H-7 burn 日限 | ✅ **核对后关闭** | P0-8 per-spender 日限已存在(xPNTsToken.sol:121-131,默认 50k),H-2 已接入 transferFrom self-pull;burnFromWithOpHash 已 gated |
| **#95** ENDUSER 注册测试覆盖 | ✅ **核对后关闭** | accountToUser 早已移除;ENDUSER/safeMintForRole 测试散布 10+ 文件 |
| **#223** KMS TEE session-key | 🗑 **关闭(info)** | 自标 "inform: no immediate action";AirAccount KMS 的告知性通知,无 SP 可执行项 |
| **#248** M-2/M-3 | ✅ 已关(wontfix,无许可 by design) | 本轮已处理 |

---

## 3. ⚠️ 需要复审的隐藏项 — #201 workstream

**Opus 挖出一个张力点,需要你决策是否再深入:**

- **#201 C-1 retryPendingDebt replay** — 标着 "v5.4 carryover",但 `retryPendingDebt`(SP.sol:1388)仍调用**无 opHash 去重**的 legacy `recordDebt(user,amount)`。
- 我在本轮把 **L-1**(同一 recordDebt)判为 **SKIP/wontfix**,理由:retryPendingDebt 是 onlyOwner + 先扣 pendingDebts 再记债,无 double-record 路径。
- **但** #273(H-1)改变了语义:over-ceiling debt 现在写进 `pendingDebts`,而 retryPendingDebt 又通过 legacy recordDebt 重新落账 —— Opus 认为 **#201 + #215(cumulative cap+TTL) + L-1** 是**同一个 workstream**,且 #201 可能是真未修的问题,不只是 cosmetic。
- **复审结论(2026-06-14,Opus 严格追踪 accounting invariant):全部 SKIP,无隐藏 Critical。**
  - `getDebt + pendingDebts` 在 `retryPendingDebt` 中**原子守恒**(SP.sol:1387 `pendingDebts -= amount` 与 xPNTsToken.sol:488 `debts += amount` 同一 tx);amount 在任一 committed 状态只存在于 {pendingDebts, debts} 之一。
  - 三重 replay 防护:postOp `_settledDebtOps[opHash]`(SP.sol:1271)、token cross-hash(`usedOpHashes`/`usedDebtHashes`,xPNTsToken:441/511)、`retryPendingDebt` 的 pre-decrement(SP.sol:1387)。legacy `recordDebt` 只搬运已隔离的 value,不凭空铸债。
  - `isBlocked`(首次 over-ceiling drain 时设,SP.sol:1359)gate 住 SBT + agent 两条路径,攻击不可重复 → `pendingDebts` 不会无界增长。
  - TTL 反而**有害**(静默过期真实欠款,破坏守恒不变式);cumulative cap 与 `isBlocked` 冗余。
  - **处置:#201 可关(确认 SKIP);#215 降级为 off-SP 的 low defense-in-depth(或关);L-1 维持 wontfix。** 不碰 SP 字节。

---

## 4. 版本规划

### 建议:现在 cut `v5.3.3-beta.4`(不要等 v5.4)

6 个审计 fix(#273-#278)全是 **UUPS in-place** 或纯 docs/ABI:
- #273 H-1 / #274 M-1 / #275 M-6 / #277 L-7 = SP/Registry impl 逻辑 → UUPS 升级,无 storage 重排
- #276 L-9 = MicroPaymentChannel(独立合约,单独重部署)
- #278 M-4 = docs only

**理由:把安全修复折进 3 个月后的 v5.4 重部署,等于让 Sepolia 一直跑 known-vuln bytecode。** 应单独打 beta.4 + Sepolia UUPS 升级。

### UUPS-fixable(可进 beta.x,in-place)
#201 C-1 · #208 H-6(有字节成本)· #206/#213(待 #210 后)· #211 batch · #258-L1 · #259-I 部分

### 必须 v5.4 重部署(storage 重排 / 拆分 / 非升级合约)
#251 god-split · #252 · #253 · #254 gas 重排 · #212 · #202 · #203 · #205 · #207 · #215(xPNTsToken)· **#210 Registry 压缩(解锁 #206/#213)**

### v5.4 scope(重部署版本,按依赖排序)
`#251 拆分(回收 EIP-170 余量,解锁所有碰 SP 的修复)` → `#252/#254 预言机去重+gas 重排` → `carryover H/M 批次(#202/#203/#205/#207/#211/#212)` → `#210 → #206/#213 链` → `卫生(#256/#259)` → `测试(#216/#257)`

---

## 5. 最近任务(按就绪度/依赖排序)

| # | 任务 | 就绪度 |
|---|---|---|
| 1 | **cut v5.3.3-beta.4** + Sepolia UUPS 升级 6 个 merged 修复;同步 #272 勾选(#245/#247/#248/#250 done) | ✅ 立即,零新代码 |
| 2 | **#269 APNTS_TOKEN migration** — **2026-06-20 01:50 UTC timelock 硬截止**。现在预备(drain operators 使 totalTrackedBalance==protocolRevenue),到点 `executeAPNTsTokenChange()` + 重跑 E2E 37/37 | ⏰ 日历硬截止 |
| 3 | **#201 + #258-L1 + #215** workstream — 先 Opus 复审(见 §3),确认要修则一个 UUPS hotfix(retryPendingDebt→recordDebtWithOpHash + gate legacy + cumulative cap) | 🔍 先复审再定 |
| 4 | **清理 housekeeping**:#245/#209/#95/#223 关闭(§2) | ✅ 立即 |
| 5 | **解锁 v5.4 设计的决策**:#238 chargeMicroPayment · #218 operator binding · #214 H-3 · #207 H-5 —— 决定 SP 增不增代码,要在 #251 拆分前定 | 💬 需决策 |
| 6 | **v5.4 启动 = #251 god-contract 拆分优先** — 回收 EIP-170 余量(当前仅 126B),解锁 #208/#249/#211 等碰 SP 的修复;#210 Registry 压缩并行(解锁 #206/#213) | 🏗 v5.4 起点 |

---

## 6. 完整 issue 判断表(36 个)

| Issue | 桶 | 一句话 | 碰SP? | 阻塞关系 |
|---|---|---|---|---|
| #245 H-1 | DONE-CLOSE | #273 已修(Plan A) | y | — |
| #209 H-7 | DONE-CLOSE | P0-8 日限已存在 | n | — |
| #95 | DONE-CLOSE | 测试早已覆盖 | n | — |
| #223 | STALE-CLOSE | info-only 通知 | n | — |
| #201 C-1 | ⚠️复审 | retryPendingDebt 仍用 legacy recordDebt | y | ↔#215/#258-L1 |
| #215 P1-35 | ⚠️复审(并 #201) | recordDebt cap+TTL | y(gate) | 并 #201 |
| #258 L checklist | 拆分:L-7/L-9 done,6 wontfix,**仅 L-1 存活** | partial | L-1↔#201 |
| #272 tracking | 保留(需同步) | live 上线 checklist | n | tracks all |
| #208 H-6 | 有价值 | postOp 汇率快照(operator 可 rug);+字节 | y | — |
| #249 M-5 | defer(已定) | Tier-2 已硬保证 | y | — |
| #269 APNTS migration | 有价值(最近,gated) | 6/20 timelock | n(ops) | 时间门 |
| #251 god-split | 有价值(v5.4 核心) | 回收 EIP-170 的关键 | y | 解锁 #208/#249/#211 |
| #210 Registry 压缩 | 有价值(enabler) | ≥150B | n(Reg) | **阻塞 #206/#213** |
| #206 H-4 cascade-revoke | 有价值(阻塞) | — | n(Reg) | 待 #210 |
| #213 M-2 exitRole sync MySBT | 有价值(阻塞) | — | n | 待 #210 |
| #252/#253/#254 | 有价值(v5.4) | 架构/gas 重排,重部署 | partial/y | #254 搭 #251 |
| #255 D deploy 健壮性 | 有价值(上线 blocker) | mainnet config 缺 | n | — |
| #211/#212 批次 | 有价值(v5.4) | UUPS/重部署批 | 部分 | — |
| #202/#203/#205/#207 | 有价值(v5.4 carryover) | 重部署/决策 | 多 n | — |
| #214/#218/#238/#207 | 有价值(决策) | 需先决策才能定 SP 形态 | 视决策 | gates #251 |
| #237 x402 e2e | 有价值 | SDK+facilitator | n(SDK) | rel #269 |
| #217 ERC-8004 | 有价值 | Sepolia config | n | — |
| #216 BLS test 合并 | 有价值(test) | — | n | — |
| #256 B 命名 | 有价值(低) | 搭下次重部署 | minor | — |
| #257 T-M test gap | 有价值 | — | n | — |
| #259 I 卫生 | 有价值(低) | I-4 回收字节有用 | 部分 | — |
| #90 SDK breaking | 有价值(SDK) | 链上已完成,仅追踪 | n | — |
| #91 updatePriceDVT bound | 有价值(低) | break-glass 偏差界 | n | — |

---

## 一句话总结

**当前 v5.3.3-beta.3 + 6 个安全修复待 tag。最该立刻做的两件:① cut beta.4 + Sepolia 升级(零新代码);② 预备 #269 APNTS 迁移(6/20 硬截止)。** 然后清 4 个已完成/过时 issue,复审 #201 workstream,再用决策(#238/#218/#214/#207)解锁 v5.4 的 #251 god-contract 拆分(这是回收 SP 字节余量、解锁后续一切的根)。
