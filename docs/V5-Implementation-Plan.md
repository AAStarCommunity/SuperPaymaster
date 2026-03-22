# SuperPaymaster V5 Implementation Master Plan

> Version: 1.1.0 | Date: 2026-03-22 | Status: Pre-Implementation
>
> **Related Documents**:
> - [V5 Roadmap](./V5-Roadmap.md) — Version roadmap and business analysis (v1.4.0)
> - [V5 Design Doc](./SuperPaymaster-V5-Design.md) — Architecture design (v0.6.0)
> - [Ecosystem Evaluation](./evaluate-roadmap.md) — Competitive assessment (v1.1.0)
> - [Tempo/MPP Research](./research-stripe-tempo-mpp.md) — Stripe Tempo deep research (v1.1.0)
> - [V5.1 Plan](./V5.1-Plan.md) | [V5.2 Plan](./V5.2-Plan.md) | [V5.3 Plan](./V5.3-Plan.md)

---

## 1. Executive Summary

SuperPaymaster V5 transforms the project from a Gas sponsorship system into a **full-stack community payment infrastructure** for Agent Economy. The implementation is split into three parallel workstreams (V5.1/V5.2/V5.3) with serial integration phases.

**Current State**: V4.1.0 on `feature/uups-migration` — UUPS proxy deployed on Sepolia, 318 tests passing.

**Target State**: V5.3.0 — Gas + Micropayment + x402 Facilitator + Payment Channel + ERC-8004 + Agent Discovery.

**Competitive Score**: 22/50 → 36/50 (surpassing Tempo's 35/50).

---

## 2. High-Level Schedule

```
Week   1    2    3    4    5    6    7    8    9   10   11   12   13   14   15   16
       ├────────────────┤
       │   V5.1 Dev     │
       │  (4 weeks)     │
       │  Consume+Micro │
       ├────────────────┤
                        ├─┤ V5.1 Integration
                          │ merge → test
       │                  │
       ├──────────────────────────────────┤
       │         V5.2 Dev (6 weeks)       │
       │   x402 + Channel + Operator Node │
       ├──────────────────────────────────┤
                                          ├─┤ V5.2 Integration
                                            │ merge → test
       │                                    │
       ├──────────────────────────────────────────────────────┤
       │            V5.3 Dev (6 weeks)                        │
       │   ERC-8004 + SKILL.md + CLI + Discovery              │
       ├──────────────────────────────────────────────────────┤
                                                              ├──┤ V5.3 Integration
                                                                 │ merge → full regression
                                                                 │
                                                              Week 16: V5.3 Release
```

**Key Milestones**:

| Milestone | Week | Deliverable | Score |
|-----------|------|-------------|-------|
| **M0: Baseline** | 0 | V4.1.0 stable on Sepolia | 22/50 |
| **M1: V5.1 Done** | 4 | `_consumeCredit()` + `chargeMicroPayment()` E2E | 26/50 |
| **M2: V5.1+V5.2 Integration** | 11 | x402 settle + Payment Channel E2E | 33/50 |
| **M3: Full V5 Integration** | 16 | ERC-8004 + SKILL.md + CLI + full regression | 36/50 |
| **M4: Mainnet Ready** | 18 | Audit + mainnet deployment | 36/50 |

**Parallel Development Window**: Weeks 1-10 — all three V5.x branches can develop in parallel. Integration starts at Week 5 (V5.1 merge).

---

## 3. Worktree Strategy

### 3.1 Branch Structure

```
feature/uups-migration (V4.1.0 stable baseline)
    │
    ├── feature/v5.1-consume-credit     ← worktree: .claude/worktrees/v5.1
    │   Scope: SuperPaymaster.sol refactor + new functions
    │   Files: SuperPaymaster.sol, ISuperPaymaster.sol, tests
    │
    ├── feature/v5.2-x402-facilitator   ← worktree: .claude/worktrees/v5.2
    │   Scope: New contract + SuperPaymaster extensions
    │   Files: MicroPaymentChannel.sol (NEW), SuperPaymaster.sol (additive), tests
    │
    └── feature/v5.3-erc8004-discovery  ← worktree: .claude/worktrees/v5.3
        Scope: Config functions + off-chain deliverables
        Files: SuperPaymaster.sol (additive), SKILL.md, CLI (off-chain)
```

### 3.2 Conflict Analysis

| V5.x | File | Change Type | Conflict Risk |
|------|------|-------------|---------------|
| V5.1 | `SuperPaymaster.sol` | Refactor `postOp`, extract `_consumeCredit()`, add `chargeMicroPayment()` | **Anchor — merge first** |
| V5.2 | `SuperPaymaster.sol` | Add `verifyX402Payment()`, `settleX402Payment()`, `facilitatorFeeBPS` | Low (new functions) |
| V5.2 | `MicroPaymentChannel.sol` | **New contract** | None |
| V5.3 | `SuperPaymaster.sol` | Add `isRegisteredAgent()`, `agentPolicies`, `setAgentRegistries()` | Low (new functions) |
| V5.3 | SKILL.md, CLI | **Off-chain deliverables** | None |

**Conclusion**: V5.1 refactors existing code (must merge first). V5.2 and V5.3 only add new functions/contracts — minimal conflict risk. **Three branches can develop in parallel, integrate serially**.

### 3.3 Worktree Commands

```bash
# Create worktrees from feature/uups-migration
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster
git worktree add .claude/worktrees/v5.1 -b feature/v5.1-consume-credit
git worktree add .claude/worktrees/v5.2 -b feature/v5.2-x402-facilitator
git worktree add .claude/worktrees/v5.3 -b feature/v5.3-erc8004-discovery

# Work in each worktree independently
cd .claude/worktrees/v5.1  # V5.1 development
cd .claude/worktrees/v5.2  # V5.2 development
cd .claude/worktrees/v5.3  # V5.3 development
```

### 3.4 Future Ecosystem Worktrees

V5 also requires SDK and AirAccount contributions. These will use separate worktrees in their respective repositories:

```
../aastar-sdk/
    ├── feature/v5.1-abi-update        ← @aastar/core ABI + EIP-712 util
    ├── feature/v5.2-x402-channel      ← @aastar/x402 + @aastar/channel + operator-node
    └── feature/v5.3-discovery-cli     ← @aastar/discovery + @superpaymaster/cli

../airaccount-contract/
    ├── feature/v5.1-micropay-e2e      ← chargeMicroPayment E2E test
    ├── feature/v5.2-session-voucher   ← Session Key EIP-712 Voucher E2E
    └── feature/v5.3-erc8004-agent     ← ERC-8004 → isRegisteredAgent integration
```

---

## 4. Serial Integration Strategy

### Phase 1: V5.1 Integration (Week 5)

```
feature/v5.1-consume-credit → merge to feature/uups-migration
```

**Pre-merge Checklist**:
- [ ] `forge test` — all 318+ tests pass (existing + new)
- [ ] `_consumeCredit()` unit tests (10+ cases)
- [ ] `chargeMicroPayment()` unit tests (8+ cases)
- [ ] EIP-1153 transient storage tests
- [ ] `postOp` regression — identical gas behavior to V4.1.0
- [ ] Storage layout verified: `forge inspect SuperPaymaster storage-layout`
- [ ] Gas snapshot comparison: V5.1 vs V4.1.0

**Post-merge**:
- Rebase V5.2 and V5.3 branches onto updated `feature/uups-migration`
- Run full test suite in V5.2/V5.3 worktrees

### Phase 2: V5.2 Integration (Week 11)

```
feature/v5.2-x402-facilitator → merge to feature/uups-migration (contains V5.1)
```

**Pre-merge Checklist**:
- [ ] All V5.1 tests still pass
- [ ] `verifyX402Payment()` + `settleX402Payment()` tests (12+ cases)
- [ ] `MicroPaymentChannel.sol` tests (15+ cases)
- [ ] Payment Channel + Session Key E2E (with AirAccount)
- [ ] Facilitator fee configuration tests
- [ ] Storage layout verified (no slot collisions with V5.1)
- [ ] x402 Operator Node integration test (off-chain → on-chain)

**Post-merge**:
- Rebase V5.3 branch
- Sepolia deployment + E2E gasless tests

### Phase 3: V5.3 Integration (Week 16)

```
feature/v5.3-erc8004-discovery → merge to feature/uups-migration (contains V5.1+V5.2)
```

**Pre-merge Checklist**:
- [ ] All V5.1 + V5.2 tests still pass
- [ ] `isRegisteredAgent()` + `agentPolicies` tests (8+ cases)
- [ ] `setAgentRegistries()` configuration tests
- [ ] Dual-channel validation (SBT OR ERC-8004) E2E
- [ ] SKILL.md serving + content validation
- [ ] CLI tool functional tests
- [ ] Full regression: `run_full_regression.sh` + gasless E2E

### Phase 4: Release (Week 17-18)

```
feature/uups-migration (V5.3 complete) → PR to main
```

- [ ] Full Foundry test suite (350+ tests expected)
- [ ] Sepolia UUPS upgrade test
- [ ] Storage layout diff: V4.1.0 → V5.3.0
- [ ] Gas report comparison
- [ ] Security audit (external or internal)
- [ ] Mainnet deployment plan

---

## 5. Scoring Checkpoints

After each V5.x integration, re-evaluate competitive scores:

```
Dimension          V4.1  V5.1  V5.2  V5.3  Tempo  Coinbase
──────────────────────────────────────────────────────────
Gas Elimination     4     4     4     4      5       3
Single Payment      0     2     4     4      4       4
Streaming Micropay  0     0     4     4      5       0
Identity/Discovery  2     2     2     5      3       3
Decentralization    5     5     5     5      2       1
Account Security    5     5     5     5      3       3
SDK Maturity        2     3     4     4      5       4
Ecosystem Adoption  1     1     2     3      4       5
Fiat Support        0     0     0     0      5       4
Multi-chain         5     5     5     5      1       2
──────────────────────────────────────────────────────────
Total (/50)        22    26    33    36     35      28
vs Tempo           -13   -9    -2    +1
vs Coinbase         -6   -2    +5    +8
```

**Key Inflection**: V5.2 is the critical milestone — first time within striking distance of Tempo (33 vs 35). V5.3 surpasses Tempo (36 vs 35).

### Scoring Verification Method

After each phase merge, fill in the scoring evidence table:

| Dimension | Claimed Score | Evidence | Verified |
|-----------|--------------|----------|----------|
| Gas Elimination | 4 | `postOp` E2E on Sepolia | [ ] |
| Single Payment | N | `chargeMicroPayment` / `settleX402Payment` E2E | [ ] |
| ... | ... | ... | [ ] |

---

## 6. Three-Project Coordination

### 6.1 SuperPaymaster → SDK Interface Contract

```
SuperPaymaster publishes:
  1. Updated ABI files in contracts/abis/ (sync via sync_to_sdk.sh)
  2. Deployed addresses in deployments/config.<network>.json
  3. EIP-712 TypeHash constants in ISuperPaymaster.sol

SDK consumes:
  1. ABI files → generate typed actions
  2. Config addresses → pre-configured clients
  3. TypeHash → client-side signing utilities
```

**Timeline**: ABI published within 24h of new function deployment. SDK update within 48h.

### 6.2 SuperPaymaster → AirAccount Interface Contract

```
SuperPaymaster provides:
  1. MicroPaymentChannel address for callTargetAllowlist
  2. EIP-712 Voucher domain/types for Session Key signing
  3. isRegisteredAgent() for ERC-8004 identity check

AirAccount provides:
  1. Session Key addresses as authorizedSigner
  2. ERC-8004 agent registration (setAgentWallet)
  3. E2E validation scripts
```

**Timeline**: Interface definitions stable by V5.2 start. E2E tests by V5.2 integration.

### 6.3 Coordination Schedule

```
                    SuperPaymaster        SDK (@aastar)          AirAccount
Week 1-4 (V5.1):
  · _consumeCredit refactor      · ABI update (@core)         · V5 compat E2E
  · chargeMicroPayment           · EIP-712 signing util       ·
  · EIP-1153 optimization        ·                            ·

Week 1-10 (V5.2):
  · verifyX402Payment            · @aastar/x402 package       · Session Key +
  · settleX402Payment            · @aastar/channel package    ·   Voucher E2E
  · MicroPaymentChannel.sol      · Operator Node framework    · AgentKey config
  · facilitatorFeeBPS            ·                            ·

Week 1-14 (V5.3):
  · isRegisteredAgent            · @aastar/discovery package  · ERC-8004 →
  · agentPolicies                · @superpaymaster/cli        ·   isRegistered
  · setAgentRegistries           · enduser ERC-8004 check     · x402 client E2E
  · SKILL.md metadata            ·                            ·
```

---

## 7. Capability Reuse Matrix (Design Doc §7.5)

V5 的核心低风险论据：**80%+ 功能基于已有模块复用**。

| V5 新能力 | 复用的已有模块 | 新增代码 |
|----------|--------------|---------|
| `_consumeCredit()` | `postOp` 步骤 5-8 提取 | ~40 行 |
| EIP-712 签名验证 | **solady EIP712** (已有依赖 `contracts/lib/solady/`) | ~30 行 |
| `chargeMicroPayment()` 签名验证 | **solady SignatureCheckerLib** (EOA + ERC-1271) | ~10 行 |
| `microPaymentNonces` | 新建 mapping | ~5 行 |
| x402 verify/settle (xPNTs 路径) | `_consumeCredit()` + 签名验证 | ~50 行 |
| x402 settle (USDC 路径) | **EIP-3009 / Uniswap Permit2** (外部标准) | ~80 行 |
| Payment Channel | **Tempo TempoStreamChannel** 模式 (Apache 2.0) | ~200 行 |
| HMAC Challenge | **MPP mppx Challenge.ts** 模式 (Apache 2.0) | ~50 行 |
| Operator Node | **Hono** (MIT) + mppx 中间件架构模式 | ~300 行 |
| ERC-8004 身份查询 | `sbtHolders` 逻辑扩展 + **ERC-8004 标准接口** | ~20 行 |
| SKILL.md | **Tempo SKILL.md** 格式 (CC0) | 文档 |
| Rate limiting | `userOpState` + `minTxInterval` (**完全复用**) | 0 行 |
| Debt recording | `xPNTsToken.recordDebt()` (**完全复用**) | 0 行 |
| Oracle pricing | `_calculateAPNTsAmount()` (**完全复用**) | 0 行 |
| Operator config | `operators` mapping (**完全复用**) | 0 行 |

### 站在巨人肩膀上：开源技术栈借鉴

| 技术来源 | 借鉴内容 | 许可证 | 用于 V5.x |
|---------|---------|--------|----------|
| **solady** (Vectorized) | EIP712 基类 + SignatureCheckerLib | MIT | V5.1 |
| **Tempo TempoStreamChannel** | Payment Channel 数据结构 + 累积式 Voucher + authorizedSigner | Apache 2.0 | V5.2 |
| **MPP mppx** | HMAC-SHA256 无状态 Challenge + Method 插件架构 + Transport 抽象 | Apache 2.0 | V5.2 |
| **Uniswap Permit2** | 通用 ERC-20 签名转账 | MIT | V5.2 |
| **EIP-3009** (USDC) | `transferWithAuthorization` 标准 | CC0 | V5.2 |
| **ERC-8004** (MetaMask/Google/EF) | Identity + Reputation + Validation Registry | CC0 | V5.3 |
| **Tempo SKILL.md** | Agent 技能描述文件格式 | CC0 | V5.3 |
| **OpenZeppelin v5** | ReentrancyGuard + SafeERC20 + UUPS | MIT | 全版本 |
| **Chainlink** | ETH/USD Price Feed | MIT | 已有 |
| **AirAccount** (自有生态) | SessionKeyValidator + AgentSessionKey + ERC-8004 setAgentWallet | 自有 | V5.2-V5.3 |
| **@aastar/sdk** (自有生态) | 15 packages + L1-L4 架构 + 27 ABI | 自有 | 全版本 |

**所有外部引用均为 Apache 2.0 / MIT / CC0，无运行时依赖，提取模式不引入代码耦合。**

---

## 8. Forward Compatibility: V5.4-V5.5 (Design Doc §7.6)

V5.4 (dShop) 和 V5.5 (dEscrow) 是**独立合约**，不修改 SuperPaymaster：

| 未来集成 | 机制 | SuperPaymaster 改动 |
|---------|------|-------------------|
| Shop 购买 Gas 赞助 | 用户通过 UserOp 调用 `shop.purchase()` → postOp → `_consumeCredit()` | **零改动** |
| Shop 商品支付 | Shop 合约直接调用 ERC-20 `transferFrom` | **零改动** |
| Escrow 资金锁定/释放 | ShopEscrow 独立处理 | **零改动** |
| DVT 仲裁 | 复用 `DVTValidator` + `BLSAggregator` | **零改动** |

`_consumeCredit()` 的 `preDeducted` 参数 + permissionless `chargeMicroPayment()` 已为 V5.4-V5.5 预留了足够灵活性。

---

## 9. Risk Mitigation

| Risk | Impact | Mitigation | Owner |
|------|--------|-----------|-------|
| 开源借鉴代码质量 | Medium | 所有借鉴均从 Apache 2.0/MIT/CC0 代码中提取模式，非直接 import；solady/OZ 已审计 | All |
| V5.1 `postOp` regression | Breaks existing gasless flow | Comprehensive regression tests + gas snapshot comparison | V5.1 lead |
| Storage slot collision | Proxy state corruption | `forge inspect storage-layout` at every merge gate | All |
| V5.2 rebase conflicts | Merge failures | V5.2 only adds new functions, avoids modifying V5.1 code | V5.2 lead |
| ERC-8004 spec change | Interface breaking | Adapter pattern isolates ERC-8004 calls | V5.3 lead |
| Payment Channel security | Fund loss | Dispute window + AirAccount spendCap + audit | V5.2 lead |
| SDK delivery delay | No client-side tools | Prioritize core contract work, SDK follows | SDK lead |

---

## 10. Definition of Done

### V5.1 Done
- [ ] `_consumeCredit()` extracted and all callers use it
- [ ] `chargeMicroPayment()` deployed and E2E tested
- [ ] EIP-1153 optimization measured (gas savings quantified)
- [ ] All 318+ existing tests pass unchanged
- [ ] Sepolia upgrade successful
- [ ] Score: 26/50

### V5.2 Done
- [ ] x402 verify/settle functions deployed
- [ ] `MicroPaymentChannel.sol` deployed
- [ ] Payment Channel open/sign/settle E2E with AirAccount Session Key
- [ ] Operator Node prototype running
- [ ] Sepolia upgrade successful
- [ ] Score: 33/50

### V5.3 Done
- [ ] ERC-8004 dual-channel identity working
- [ ] `agentPolicies` configurable per operator
- [ ] SKILL.md hosted and parseable by AI agents
- [ ] CLI tool installable via `pnpm add -g`
- [ ] Full regression on Sepolia
- [ ] Score: 36/50

### Release Done
- [ ] All 350+ tests pass
- [ ] Security review complete
- [ ] Mainnet deployment plan documented
- [ ] README and docs updated
- [ ] Score verified: 36/50 (surpasses Tempo 35/50)

---

## Appendix: Document Index

| Document | Path | Content |
|----------|------|---------|
| **This Plan** | `docs/V5-Implementation-Plan.md` | Master plan, schedule, worktree strategy |
| **V5.1 Plan** | [docs/V5.1-Plan.md](./V5.1-Plan.md) | `_consumeCredit` + `chargeMicroPayment` detailed tasks |
| **V5.2 Plan** | [docs/V5.2-Plan.md](./V5.2-Plan.md) | x402 + Payment Channel detailed tasks |
| **V5.3 Plan** | [docs/V5.3-Plan.md](./V5.3-Plan.md) | ERC-8004 + SKILL.md + CLI detailed tasks |
| V5 Roadmap | [docs/V5-Roadmap.md](./V5-Roadmap.md) | Business context and version planning |
| V5 Design | [docs/SuperPaymaster-V5-Design.md](./SuperPaymaster-V5-Design.md) | Architecture and code-level design |
| Evaluation | [docs/evaluate-roadmap.md](./evaluate-roadmap.md) | Competitive assessment and ecosystem analysis |
| Research | [docs/research-stripe-tempo-mpp.md](./research-stripe-tempo-mpp.md) | Tempo/MPP deep research |
