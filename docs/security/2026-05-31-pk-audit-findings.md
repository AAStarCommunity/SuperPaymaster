# SuperPaymaster v5.3.3 — Pre-Mainnet Security Findings (Codex × local-model PK)

> 2026-05-31 · branch `security/pre-mainnet-hardening` · contract `SuperPaymaster-5.3.3`
>
> Method: an adversarial source audit (Codex) was run in parallel with an
> independent coverage-gap analysis (local model). **Every CRITICAL below was
> then re-verified line-by-line against the source by the local model** — none
> are taken on trust. Items Codex raised that did not survive verification, or
> that are already fixed, are listed in §"Not confirmed / already fixed".

## ⚠️ Headline

The unit/E2E suites pass, but they **do not cover** the x402 settlement, credit/debt,
and postOp-revert paths — which is exactly where the confirmed fund-loss bugs live.
"Tests pass" did not mean "no bugs"; it meant "the bugs are in untested branches".

---

## CONFIRMED — must fix before mainnet (and before enabling x402 on any network)

### C-01 · No credit/debt ceiling in `validatePaymasterUserOp` → operator drain
- **Where**: `SuperPaymaster.sol` validate body (1017–1095); credit view exists at `:797 getAvailableCredit` but is **never called** in validation.
- **Verified**: validate checks configured / paused / eligibility / blocked / rate-limit / rate-commitment / **operator** solvency — but never `getCreditLimit(user)` vs `getDebt(user)+pendingDebts`. A user with SBT/agent eligibility, 0 xPNTs and 0 credit limit can submit UserOps repeatedly; each deducts the operator and records unbounded user debt in postOp. The operator is drained by a non-paying user; the credit-limit mechanism that was meant to cap this is not enforced.
- **Fix**: in validate, require `getDebt(user) + pendingDebts[token][user] + estimatedFinalCharge <= REGISTRY.getCreditLimit(user)`. Test: credit==0 ⇒ validate reverts.
jhf：确认，必须加`getCreditLimit(user)` vs `getDebt(user)+pendingDebts`来check，顺便说一下，在涉及花销的地方，如果使用credit payment，那都需要调用这个呃先检查credit limit，然后呢再检查ending date和这样的话是不是就能得出来用户能够这个享受的透支额度了，对不对？是不是三个都必须要调用啊，那干脆那么整合成一个快捷的方法，全局如果多个地方需要用的话，但如果所有的出口都在一个地方的话，那把这三个就都调用好就行了，组合好。


### C-02 · `settleX402PaymentDirect` pulls any user's xPNTs with no user authorization
- **Where**: `SuperPaymaster.sol:1534–1558`; auto-allowance in `xPNTsToken.sol allowance():351-359` (`autoApprovedSpenders[SP]⇒type(uint256).max`, SP added at `:604`).
- **Verified**: caller needs `ROLE_PAYMASTER_SUPER` + `approvedFacilitators[caller]`. Because SP holds an unlimited auto-allowance over **every** holder, `safeTransferFrom(victim, SP, amount)` succeeds with **no signature from the victim**. A malicious/compromised approved-facilitator can drain any community member's xPNTs to an arbitrary `to`.
- **Severity note**: gated by the community-granted facilitator role (not permissionless), but the capability — pull any user without consent — is far broader than the feature needs.
- **Fix**: require a user EIP-712 authorization binding `(from,to,asset,amount,nonce,validBefore,operator,chainId)`; or remove the direct path.
jhf：首先呢我们superpaymaster具备呃无线的这个呃allowance。对，这是工厂内置的pinnder。对你也看到这个代码，呃当时涉及它最初的呃目标呢是superpay masterster它有一系列的安全保障。比如说呃它会根据是不是具备user operation的累一的哈希来去确定你是不是可以免appro，不用appro的方式去呃从账户中扣除你的gas。对，这是当时的路径。那我们在这个基础上又增加了这个purchase或者是payment，不仅仅是gas payment。而是几种不同的payment。比如说miccropayment channel。对，或者说X02payment to act或者是credit paymentment对。那这些呢啊都需要这个superpaymaster作为一个工厂内置的allowance max的pender来去啊解决这个从用户账户转移前的问题。但我们在ga上的支付呢是要求必须啊就是superpaymaster只能转移到自己的账户中。对，换句话说，它也不能转出，而且每一次转移的都要有user operation的哈西，而且都要记账啊，多重的这个防火墙保护啊，阻止了superpaymaster作恶的可能，它只能用它来转移到自己内部啊，来支付这个呃当次的user operation哈希对的这个ga payment，这是当时的一个安全措施。那现在呢就是我们启用了X402payment direct。那我们。实际上要在授权这个faciator的时候啊，要着重注意。我认为它是一个三方交互的过程。对，faciator呢，实际上是提供了一个呃支付的便利服务。他必须保证啊请求的这个呃请求的这个页面。啊，比如说请求页面要求要比如说10个积分，才能够访问我这个页面或者资源。这个呢我们希望是作为一个唯一的哈希存下来。啊，未来可能可以能否改造成这个ZK proof。换句话说，我们能证明这个页面确实需要实积分才能够访问。啊呃这个faciator拿到这个凭证之后呢，就需要这个呃提供给这个用户或者说他。来验证，我们假设是信任这个fa dictator，他来验证啊这个UIL请求资源要求，确实是10个积分。那他才去用这个凭证去找superpayster请求账户转移那superpayma类似像是银行，他接到这个这个如果用户请求了这个啊资源。啊这个资源又证明必须支支付10积分，他这两个方向的请求，经过对比确认是一致的话，那他就要执行从用户的钱包啊，转移10个积分给这个faili dictator。对呃，我叙述的这个过程你应该能理解。换句话说，这里边缺少了一个就是凭证和验证的问题。你看能不能帮我解决。对，如果ZK啊这个叉402的请求能够在这个fa dictator上用最简单。最轻的方式证明自己啊，确实需要这么多钱，而且也有记账的记录啊，那就啊这个证明给super看，然后完成这个呃双方的撮合。对啊，另外一方呢就是用户请求方。那确实要请求这个资源。啊这两个都验证通过之后呢，就要从用户的请求里去啊用户的钱包里去拿走实积分支付给这个faacilitator。啊，我说的这个逻辑，你帮我分析一下，看看有什么漏洞，能否解决这个安全问题。

### C-03 · `settleX402Payment` recipient (`to`) is not covered by the EIP-3009 signature → redirect
- **Where**: `SuperPaymaster.sol:1500–1509`.
- **Verified**: `transferWithAuthorization(from, address(this), amount, …, signature)` (`:1505`) authorizes only `from → SuperPaymaster`. The downstream `safeTransfer(to, amount-fee)` (`:1506`) uses a **caller-supplied `to`** that the user never signed. Any party holding the user's EIP-3009 auth (e.g. lifted from the x402 flow) can settle to an attacker address.
- **Fix**: bind `to`/facilitator/fee/asset/amount/nonce/validity/chainId into a second SuperPaymaster EIP-712 signature.
- jhf：嗯，你说这个风险是用户签了名了之后，因为他这个收收款方的地址是可以被改写的。因为他没做验证（参数没有，无法验证）。所以呢就有可能没有打到我们要求的收款方，而是嗯被转移到了别处。嗯，嗯绑定这些指定的比如说facciiliator，或者说嗯对，主要是faciliator。嗯，然后呢去确保收款方是我们要求指定的收款方。实际上就是对EIEIP72签名的一个嗯应该是参数的一个增加吧，对吧。这个可以的，增加这个之后就不能转移到啊这个其他方了。

### C-04 · `postOpReverted` early-returns with no reconciliation → operator overpay + `protocolRevenue` overstated + user free-ride
- **Where**: `SuperPaymaster.sol postOp`, `if (mode == PostOpMode.postOpReverted) return;` (≈:1217); refund logic that it skips is at ≈:1242-1255.
- **Verified**: validation optimistically moves `initialAPNTs` from `operator.aPNTsBalance` into `protocolRevenue`. On `postOpReverted` the function returns **before** the refund/burn/debt logic — so the operator is never refunded the unused portion, no xPNTs is burned, no debt is recorded (user pays nothing), and `protocolRevenue` stays inflated (owner can later withdraw it). Breaks the INV-03 solvency invariant. An attacker can force this with a deliberately low `paymasterPostOpGasLimit`.
- **Fix**: reject too-low `paymasterPostOpGasLimit` in validate; in the `postOpReverted` branch do a **bounded** reconciliation (no external token calls) that at minimum returns `initialAPNTs` to the operator and decrements `protocolRevenue`.
jhf：`if (mode == PostOpMode.postOpReverted) return`，你帮我确认一下这句代码它究竟当时是为什么为什么加这句代码。对，如果mod它它是一个什么模式吗？那post op mode等一个post op reverted，是不是就是不用，就是不用退款还是什么着，为什么加这个能不能帮我去检查一下代码上下文呼应它呼应它这段代码的逻辑？对，如果按这个代码本身解读，就像你说的这样，这个嗯，退款可能就发生就被就被revert，因为钱不够，是这意思吗？paymasterPostOpGasLimit，这个参数是用户可以设定的吗？你确认一下，如果这个参数太低的话，实际上就代表了这个资金不足？。你帮我分析透彻一点，我担心嗯可能有一些上下文没有被考虑到，分析到嗯你分析透彻了才能确定这的话嗯是不是会产生这个后果。
---

## CONFIRMED — High

### H-01 · Over-limit `pendingDebts` can never be retried (M-04 still open)
- **Where**: `SuperPaymaster.sol:1290-1294` (pendingDebts accumulate), `:1306-1311 retryPendingDebt`; `xPNTsToken recordDebtWithOpHash` reverts on `> maxSingleTxLimit`.
- **Verified path**: a charge `> maxSingleTxLimit` makes both `burnFromWithOpHash` and `recordDebtWithOpHash` revert; SP parks it in `pendingDebts`. `retryPendingDebt` calls `recordDebt(user, sameAmount)` → reverts again, forever. Combined with C-01 the debt is also invisible to validate.
- **Fix**: chunk retries to `<= maxSingleTxLimit`; include pendingDebts in the C-01 credit check.
jhf：你说的这种情况是充值大于max single transaction limitit，就造成永远不会记录债务和b from oprs，是这个意思吗？你把这个给我解释清楚。

### H-02 · BLS registration without Proof-of-Possession → rogue-key attack
- **Where**: `BLSAggregator.sol` register (`:215-240`) + verify (`:536-560,582-592`).
- **Assessment**: requires a malicious validator to register `Pm = xG − Σ(honest pubkeys)`; with that slot in the signerMask the reconstructed `pkAgg == xG` and the attacker alone can satisfy the pairing while `signerCount` reaches quorum. Plausible; needs validator onboarding. **Recommend deeper verification + a dedicated test** (this overlaps the BLS.sol 102-line coverage gap).
- **Fix**: require on-chain (or recorded off-chain) Proof-of-Possession at `registerBLSPublicKey`.
jhf: 我们应该有这个呃注册的机制啊，首先它应该有这个ro，这个ro就是角色，是在regitry注册的那当怎么证明它有这个呃资格的时候，首先要证明它这个地址是有这个角色。啊拥有这个角色呢是需要去take啊，是需要take governance token对，而且take之后呢，才能去把自己的public key注册到我们的public key收集的地方，这是我记得的流程。确保就是我们有一个public key的注册表。那你说这个register bIS publiclic key。应该就是那个呃但你现在说这个问题是什么？就是没有去证明自己呃拥有这个。拥有的凭证，那我记得就是用角色来去证明的对，然后证明这个角色之后呢，就证明呃他take了该足够的governance token。然后呢，因为注册的流程是保证你啊take之后呢，就要注册一个public key在这个register bS publicublic key或者regtry某一个地方。这个你帮我确认一下，我记得不是那么清楚了。对吧我梳理一下这个流程是不是按照我想象设计的啊完成这个过程的。
---

## Coverage corroboration (local-model side of the PK)

The confirmed bugs sit in the **least-tested** code (forge lcov, uncovered lines):
- `utils/BLS.sol` — **102** uncovered (→ H-02)
- `SuperPaymaster.sol` — 42 uncovered, incl. `onTransferReceived`(8), `_slash`(6), `retryPendingDebt`/`clearPendingDebt`(9), x402 settle paths, validate branches (→ C-01/C-04/H-01)
- `xPNTsToken.sol` — 21 uncovered incl. `recordDebtWithOpHash`
- `BLSAggregator.sol` — 20 uncovered
jhf：你说这些都是没覆盖的测试，对不对？那你帮我把这些测试补充完整，如果发现bug的话，就给出bug的定位和分析以及解决方案。我评估一下之后可以进行修复。
---

## Not confirmed / already fixed (did not survive verification)
- M-02 (operator keeps `isConfigured` after role exit): plausible, needs confirming role-exit doesn't clear it — flagged for follow-up, not yet verified.
- jhf：呃，这个应该是我知道这个问题。对，但因为它的呃这个如果exit的话，它的这个take就会被啊退回。换句话说，它的角色也就没了。但是可能有一些配置文件还会有它的历史的配置。但因为我们check的主要是角色，所以说这主属于呢就是需要清理的数据。你看清了，如果成本不高，能够exit时顺便清理，我觉得也okK。对。
- EIP-1153 transient cache: Codex found no `tload/tstore` in the audited files — **no finding**.
- jhf：这个你再check一下，它没有这个transientc，嗯，是是会有什么后果吗，有什么问题吗？我不太确定codeex说的这个意思。
- Prior 2026-04-25 highs H-01/B2-N1/B2-N12 + Chainlink answeredInRound: **verified fixed** (P0-14, timelock, onlyOwner, answeredInRound check).
- jhf：这个你再check一下啊，如果没有confirm，就check一下，确认一下。

---

## P0 — Pre-mainnet must-fix (PK-agreed)
1. Enforce credit/debt ceiling (incl. pendingDebts) in `validatePaymasterUserOp` — **C-01**.
jhf：不是必须设置一个credit或date的这种se令吗因为我总能给它无限的这种d的权限嘛，这有什么问题吗？
2. Add user EIP-712 authorization to `settleX402PaymentDirect`, or remove it — **C-02**.
jhf：嗯，事实上，我们不需要用户去嗯EIP702授权，这也是积分的好处。或者说它的优点。就是我们在自己密闭的体系中呢，是可以啊通过一个安全的方式从用户手里划赚钱。这跟你这个同意这次交易，你已经做了签名了。对，就不用再次签名的。这个可以讨论一下。对，可以外外置的再加一次签名确认对。
3. Bind recipient/fee/operator into a second EIP-712 signature in `settleX402Payment` — **C-03**.
jhf：嗯，这应该刚才讨论过了。对嗯，添加一个签名的验证。不过你说second就第二次签名，这个我有点疑义啊，啊可以讨论一下，确认一。
4. Bounded reconciliation in the `postOpReverted` branch + reject too-low postOpGasLimit — **C-04**.
5. Chunk `pendingDebts` retries to `maxSingleTxLimit` — **H-01**.
6. Require Proof-of-Possession in BLS registration + dedicated BLS.sol tests — **H-02**.
jhf：其他的我都在对应的问题上回复了，我们挨个讨论一下之后再确认，你帮我分析评估嗯，跨文件的去看一下系统这个业务的上下班。

Each fix ships with a regression test that **fails on current code and passes after the fix** (the tests are also the coverage the suite is missing).

---

## Resolution & verified verdicts (2026-05-31, post deep-dive + PK on jhf review)

| Finding | Verdict after deep-dive | Note |
|---|---|---|
| **C-01** | ✅ REAL — confirmed | Fix in ONE place (`validatePaymasterUserOp`); only credit-debt exit on main is postOp `_recordDebt`. Consolidate into `_assertCreditAvailable(user,token,charge)` = `getDebt + pendingDebts + charge <= getCreditLimit`. **Credit expiry ("ending date") does NOT exist today — by jhf decision, NOT adding it** (3-dim only). |
| **C-02** | ✅ REAL — confirmed (faithful PoC) | Fix: user EIP-712 `X402Authorization` (supports EOA + agent ERC-1271 via SignatureCheckerLib). Keep SP auto-allowance + gas-payment firewalls intact; only add the x402 user-auth gate. |
| **C-03** | ✅ REAL — confirmed (faithful PoC) | Same EIP-712 scheme binds `to`/facilitator. **EIP-3009 transferWithAuthorization stays** (it pulls into SP); SP-712 layered on top, not replaced. |
| **C-04** | ✅ REAL — but RE-CHARACTERIZED | Original "postOpReverted early-return" mechanism was a **FALSE LEAD** — that line is **dead code in EntryPoint v0.7** (`_postExecution` never calls postOp with `postOpReverted`). The OLD PoC (direct call) was removed. **The REAL bug**: `paymasterPostOpGasLimit` is user-controlled and `validate` enforces no minimum → an attacker forces postOp OOG → validation's optimistic operator debit is never refunded, `protocolRevenue` inflated, no user debt recorded. **New PoC `PoC_C04_ForcedPostOpOOG.t.sol` proves it via real `handleOps`** (operator over-charged ~7× vs baseline, with PostOpRevertReason confirming the OOG and a false-positive guard). **Fix**: in `validate`, `require(paymasterPostOpGasLimit >= MIN_POST_OP_GAS)` (floor from baseline postOp gas), and/or make the postOp aPNTs reconciliation OOG-safe. |
| **H-01** | ⬇️ DOWNGRADED to edge-case | `maxSingleTxLimit = 5000 aPNTs`; a normal gas charge is ~100–150 aPNTs → the guard is **never hit in normal operation**. Only a single op whose gas cost exceeds 5000 aPNTs (~$100 gas, L1 extreme congestion) triggers it. The "stuck pendingDebt retry" bug is real **only** in that edge case. Not a practical High. |
| **H-02** | ⏳ needs deeper verification | BLS rogue-key — overlaps the `BLS.sol` 2.86% coverage gap; verify with a dedicated BLS test before concluding. |

### Cleanup to bundle with the fixes (jhf request)
- Remove the dead `if (mode == PostOpMode.postOpReverted) return;` (and its stale "avoid double charging" comment) since v0.7 never reaches it.
- Any other dead/unused code surfaced during the fix.

### PoC inventory (current)
- `PoC_C01_CreditCeiling.t.sol` ✅ faithful (validate+postOp opSucceeded loop)
- `PoC_C02_UnsignedDrain.t.sol` ✅ faithful (real xPNTs auto-allowance)
- `PoC_C03_RecipientRedirect.t.sol` ✅ faithful (real EIP-3009 sig)
- `PoC_C04_ForcedPostOpOOG.t.sol` ✅ faithful (real EntryPoint handleOps; replaces the removed dead-code PoC)

---

## Final resolution (2026-06-01) — fixes landed + per-fix Codex challenge review

| Finding | Status | Commit / note |
|---|---|---|
| **C-04** | ✅ FIXED (3 Codex rounds clean) | `MIN_POST_OP_GAS = 200_000` floor in validate + dryRun; dead `postOpReverted` branch removed. 200k measured (postOp ~141k), not Codex's 250k over-estimate. |
| **C-01** | ✅ FIXED | `b9c13af7`. Balance-aware `_creditExceeded`: pay-from-balance → allowed; else `getDebt + pendingDebts + charge <= getCreditLimit`. **TOCTOU (balance moved between validate and postOp) ACCEPTED by jhf** as a bounded one-op overrun — recovery via mint auto-repayment (`xPNTsToken._update`, mint-only = B1) + manual `repayDebt`. exchangeRate read from `xPNTsToken.exchangeRate()` (consistent with AirAccount #10). |
| **C-02** | ✅ FIXED — Codex approved mainnet | `d7df0c3e`. `settleX402PaymentDirect` requires payer EIP-712 `X402PaymentAuthorization(from,to,asset,amount,maxFee,validBefore,nonce)`, domain `verifyingContract = SP proxy`, `SignatureCheckerLib` (EOA + ERC-1271). |
| **C-03** | ✅ FIXED — Codex approved mainnet | `d7df0c3e`. `settleX402Payment` binds recipient via `nonce = keccak256(to, salt)` — reuses the payer's EIP-3009 signature, no second sig. |
| **L-01** | 📝 ACCEPTED as a feature (not fixed) | Codex flagged: X402 auth not bound to `msg.sender` → another approved facilitator can front-run the fee (payer funds 100% safe; only fee attribution). **jhf decision: keep it — decentralized facilitator competition is the intended model; you sign once, whoever serves first earns.** `facilitator` deliberately NOT bound into the signature (preserves flexible routing). |
| **I-01** | ↪ off-chain WYSIWYS, see below | On-chain nonce/recipient binding is tamper-evident; the residual "malicious UI" risk is solved off-chain (passkey-bound signing + clear-signing display). Converges with AirAccount KMS #16. |

### Verification
- 969 forge tests pass / 0 failed. SuperPaymaster 24,093 bytes (EIP-170 OK, 483 spare).
- PoC_C02/PoC_C03 rewritten as fix regressions (no-sig drain reverts; redirect reverts; valid-sig happy paths pass).
- AirAccount KMS EIP-712 digest is standard `keccak256(0x1901 || domainSeparator || hashStruct)` — **compatible with SP `_verifyX402Auth`**.

### Cross-repo dependencies
- **aastar-sdk #39** (filed): client must sign `X402PaymentAuthorization` (direct) + derive EIP-3009 `nonce = keccak256(to, salt)` (USDC). Canonical x402 integration lives in the SDK; in-repo `packages/x402-facilitator-node` is deprecated.
- **AirAccount KMS #16** (their repo): host-compromise → arbitrary `sign_typed_data` would let a forged X402 authorization pass SP's on-chain check for AirAccount (ERC-1271) users. SP's C-02 gate is necessary but end-to-end security for AirAccount accounts ALSO needs KMS passkey-bound JWT issuance (their fix A). **On-chain fix + KMS fix together = complete.**
