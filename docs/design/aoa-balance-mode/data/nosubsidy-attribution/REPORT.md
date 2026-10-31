# No-subsidy postOp attribution

2026-10-31; base `a941ddd9`, branch `cc127/nosubsidy-attribution`. Offline local measurements. Raw logs are regenerated from a clean committed HEAD by `script/evidence/nosubsidy-attribution-run.sh` into [`run/`](run/) (see `run/engines.txt`, `run/verdict.txt`, `run/SHA256SUMS`); the 188 MB counterexample trace is stored outside git and its hash is in `run/external-trace.sha256`. No production source, original failing test, Foundry configuration or deployment script changed; no commit or parameter change.

**The 389,218-gas counterexample is caused by first-use SuperPaymaster storage writes under Amsterdam's state-gas accounting.** It is not an expensive credit-policy/registry/oracle call. Four fresh SP slots cost 108,020 gas each, versus 20,000 on Cancun/Prague. A state-gas credit must also be included: simply summing the nonnegative costs printed by Forge overstates the frame. The full frame is reconciled below.

The uniform margin was frozen at **15%** before matrix results; see [PLAN.md](PLAN.md). The resulting Amsterdam **proposal only** is `(C_POSTOP, MIN_POST, SETTLE) = (450000, 470000, 450000)`, retaining `C_WRAP=5000`. This proposal has not been applied or used to turn the original gate green.

## Measurement method

[SuperPaymasterPostOpGasMatrix.t.sol](../../../../../contracts/test/v2/SuperPaymasterPostOpGasMatrix.t.sol) uses the canonical EntryPoint v0.7 runtime and real SimpleAccount execution, the same setup as G2, real v2 token validation/settlement, and the queued tuple `440000 / 420000 / 5000 / 340000`. It checks the tuple, funding mode, execution success/revert, settlement events, and consumed op hashes. It has only diagnostic logs and sanity assertions, not a C_POSTOP sufficiency assertion.

Each ordinary row submits two operations in one bundle for the same user/operator. “Cold/first” means first settlement with fresh timestamp, debt/counter/revenue/settlement state. Validation has already warmed the slots it actually accesses. “Warm/repeat” is the next settlement in that bundle; it still has a new op hash and cold idempotency slots. These labels are **not** a claim that all first-frame slots are cold or all repeat-frame slots warm. The opcode counts below make that distinction explicit. A repeat in a *new transaction* would reset access warmth and is not this row.

Combined submits CREDIT + user-revert for both operators, first each then repeat each, with rate limits enabled, fresh user/operator timestamps, first debt and first counters, zero initial protocol revenue, and real 384-byte contexts. Successful/reverting execution is real target code, not just a PostOpMode argument. No artificial cooling or source instrumentation is used.

Whole-frame gas is the trace's outer SP proxy frame, including delegatecall overhead, excluding EntryPoint's CALL/wrapper and unused-gas penalty. It includes immediate state-gas effects, but is not transaction gas after the end-of-transaction refund cap. Full `-vvvvv --opcodes` traces and the parser are retained. [analyze.py](analyze.py) extracts frame totals, per-frame opcode cost/count histograms and writes.

The controlled runtime comparison uses the **same Prague-compiled artifacts** on nightly `4e8874b` with runtime `--hardfork cancun`, `prague`, and `amsterdam`. Thus the difference is not a compiler-target difference. Stable Forge 1.7.1 controls compile/run with the matching Cancun and Prague targets. All commands use `--offline`; no debugger is used. The tiny standalone `gasleft()` probe below resolves a signed state-gas term that the text tracer clamps to zero.

## Matrix

Final diagnostic results: **5/5 pass on each nightly runtime**, with 12 postOp frames per runtime. Stable 1.7.1 Cancun and Prague controls also pass 5/5 and match every corresponding frame. These are settlement/execution sanity checks, not passing no-subsidy gates.

All numbers below are SP **proxy** frame gas, not implementation-only gas.

| Mode / execution / prior settlement | Cancun | Prague | Amsterdam |
|---|---:|---:|---:|
| BALANCE / success / first | 141,556 | 141,556 | 309,496 |
| BALANCE / success / repeat | 69,914 | 69,914 | 57,314 |
| BALANCE / revert / first | 141,556 | 141,556 | 309,496 |
| BALANCE / revert / repeat | 69,914 | 69,914 | 57,314 |
| CREDIT / success / first | 147,626 | 147,626 | 389,186 |
| CREDIT / success / repeat | 64,026 | 64,026 | 51,426 |
| CREDIT / revert / first | 147,626 | 147,626 | 389,186 |
| CREDIT / revert / repeat | 64,026 | 64,026 | 51,426 |
| Combined: operator A first | 147,626 | 147,626 | 389,186 |
| Combined: operator B first (revenue already initialized) | 125,726 | 125,726 | 279,266 |
| Combined: operator A repeat | 64,026 | 64,026 | 51,426 |
| Combined: operator B repeat | 64,026 | 64,026 | 51,426 |

Success/revert have identical postOp costs for the same state because SP deliberately ignores PostOpMode and always writes the rate-limit timestamp. User execution gas differs, but lies outside these frames. The matrix isolates that fact; the G2 counterexample's revert alone is not the cause.

Token **proxy subcall** costs, included in the above totals:

| Settlement / prior settlement | Cancun | Prague | Amsterdam |
|---|---:|---:|---:|
| settleLocked / first | 41,783 | 41,783 | 46,283 |
| settleLocked / repeat | 33,841 | 33,841 | 23,941 |
| settleCredit / first | 47,841 | 47,841 | 28,041 |
| settleCredit / repeat | 27,841 | 27,841 | 18,041 |

The token clone adds 184 gas over its implementation. SP's proxy adds 400 gas over its implementation. Exact per-row subcalls/opcode histograms are in `matrix-summary.json`. There are **zero** price-feed or registry subcalls inside postOp, settleCredit, or settleLocked: price/fee/gas parameters come from the validation context; credit policy/tier are not rechecked at settlement.

## Exact original failing frame

[Raw frame excerpt](counterexample-frame-amsterdam.log), [opcode histogram](counterexample-attribution.json), [independently derived storage slot labels](storage-slots.json).

Op hash `0xb53300949c74cb28a674e9ee9ab6370dca7a2b48a4000765ae21d419a79eebd8`, user `0x50486B4193eAAdD5af47F0B5617D9A423dB9101C`, operator `0xbf`, CREDIT, user execution reverts. SP proxy **389,218**, implementation **388,818**, token proxy **28,041**, token implementation **27,857**. Settlement succeeds; only the no-subsidy assertion fails.

### Reconciliation (no double counting)

| Item | Gas |
|---|---:|
| SP proxy: warm implementation-slot SLOAD | 100 |
| SP proxy: forwarding, copying, delegatecall and return, excluding implementation | 300 |
| SP implementation: 6 warm + 3 cold SLOAD | 6,900 |
| SP implementation: 4 fresh SSTORE × 108,020 | 432,080 |
| SP implementation: reentrancy enter, nonzero→nonzero | 10,100 |
| SP implementation: balance update + reentrancy exit, 2 × 100 | 200 |
| SP implementation: delete fresh in-flight record, **signed net cost** | **−97,820** |
| SP implementation: transient in-flight marker clear | 100 |
| SP implementation: TransactionSponsored LOG3 | 2,012 |
| SP implementation: remaining arithmetic, ABI/memory, hashing, branches and token CALL overhead | 7,205 |
| Token proxy + settleCredit implementation (expanded next) | 28,041 |
| **Whole SP proxy frame** | **389,218** |

The four fresh SP slots are `userOpState[operator][user].lastTimestamp`, `_settledDebtOps[opHash]`, `operators[operator].totalTxSponsored`, and `protocolRevenue`. They are all zero→nonzero, including **first revenue** and **first operator counter**, not merely a fresh user. The storage mapping hashes in `storage-slots.json` match every displayed write. The validation-warmed timestamp still incurs the expensive allocation charge.

| settleCredit component | Gas |
|---|---:|
| Clone forwarding/return overhead | 184 |
| 4 warm SLOAD + 1 cold SLOAD | 2,500 |
| Delete reservation amount/locker and update creditReservedOf: 3 × 100 | 300 |
| Set usedOpHashes and first debt, state-gas-assisted writes: 2 × 10,100 | 20,200 |
| TLOAD live marker + TSTORE clear | 200 |
| CreditSettled LOG3 | 1,756 |
| Other implementation opcodes | 2,901 |
| **Token proxy subcall** | **28,041** |

### Cold/warm and signed-cost caveat

SP implementation: **9 SLOAD = 6 warm / 3 cold; 8 SSTORE, all warm**. Cold reads are the new SP idempotency marker, first operator counter and first protocol revenue. SP proxy contributes one additional warm SLOAD. Token: **5 SLOAD = 4 warm / 1 cold; 5 SSTORE, all warm**. The token's cold read is its new usedOpHashes marker. Cold SLOAD costs 2,100 and warm SLOAD 100 in all three runtimes. No SSTORE in this frame is charged a cold-access surcharge: each is preceded by an access or warmed during validation. “Warm” therefore does not mean “cheap zero→nonzero.”

The tracer shows SP's in-flight deletion as `[0] SSTORE`, not a signed value. A standalone probe creates then clears one warm slot, logging gasleft immediately around the clear. Amsterdam: before 1,073,616,617; after 1,073,714,426; increase **97,809**. The intervening SWAP2/POP/PUSH0/PUSH0 and second GAS cost **11**. Therefore the clear contributes **−97,820**. Prague: before 1,073,698,537; after 1,073,698,426; decrease **111**, giving the ordinary **100**-gas dirty clear after removing the same 11 gas overhead. This is an immediate state-gas effect, not a 97,820-gas transaction refund applied at transaction end.

The token's two cleared reservation slots and two new slots have observed net allocation balance zero; the new writes cost 10,100 each in this frame. Do not price those two writes at the standalone 108,020 cost as well as counting the clear credit: that double-counts state gas. The report attributes observed costs; the text tracer alone does not expose every intermediate reservoir transition.

### Cancun/Prague versus Amsterdam

The matrix first-CREDIT path has identical opcode counts and nonstorage overhead across these runtimes. Its **241,560-gas increase** reconciles exactly:

```
4 × (108020 − 20000)     four fresh SP writes       +352080
    (10100 − 2900)      reentrancy enter             +7200
2 × (10100 − 20000)     two token allocations       −19800
    (−97820 − 100)      SP in-flight clear          −97920
                                                  -------
                                                   241560
147626 + 241560 = 389186
```

SLOAD costs, log costs, transient opcodes, proxy overhead and the remaining implementation overhead are unchanged. Cancun/Prague first-CREDIT SP writes total 83,200; Amsterdam's signed total is 344,560. The exact G2 frame has the same histogram, with 32 additional gas in the arithmetic/control-flow remainder compared with the matrix's chosen numerical context. It is retained as a larger observed sample, not rounded down to the matrix result.

## Retained counterexample

Exact reproducer from repository root (the original test file is unchanged):

```sh
~/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge test \
  --offline --no-isolate --fuzz-seed 0x5eed \
  --evm-version prague --hardfork amsterdam \
  --disable-external-identification \
  --match-path contracts/test/v2/SuperPaymasterV55Fuzz.t.sol \
  --match-contract '^SuperPaymasterV55FuzzTest$' \
  --match-test '^test_G2_coverage_replay_fixed_seeds' \
  -vvvvv --opcodes SLOAD,SSTORE,TLOAD,TSTORE,LOG1,LOG2,LOG3,LOG4
```

```
[FAIL: DSR no-subsidy: net-of-fee charge (ETH @ validation snapshot) >= op's actualGasCost: 1827511012226570 < 1838299350952020] test_G2_coverage_replay_fixed_seeds() (gas: 7698676)
```

Trace passed cost P = 1,044,007,212,960,250 wei; final EntryPoint cost F = 1,838,299,350,952,020 wei; fee = 1,864,881,370 wei/gas. `(F−P)/fee = 425921` gas. Net charge beyond P covers `420136` gas; the difference is **5,785 gas = 10,788,338,725,450 wei**. Frame excess over C_POSTOP is **49,218 gas**; it is not identical to the final subsidy because the charge also includes C_WRAP and the 10% budget term, while EntryPoint includes its own wrapper and unused-gas penalty.

The original fuzz conservation test is also left unchanged. This work reproduces the fixed-seed failure above; it does not report a newly run full 1,000-case fuzz campaign as passing.

## Peak versus net — caveat on the proposal (added after review)

The tuple below is derived from the **net** frame. The in-flight clear (−97,820) lands near the end of the frame, so
the gas that must be available **during** the frame is about W + 97,820 on Amsterdam, not W. `SETTLE` is checked at
entry and has to cover that peak. Otherwise a call that passes the guard can still run out of gas before the
credit arrives.

`rr5-guard-fail/` (branch `cc127/rr5-guard-fail`) observes exactly this kind of band in a direct-call setup under
the deployment tuple on Amsterdam: OOG past the guard for 440k–632k call gas (CREDIT) and 440k–568k (BALANCE). That
setup's state-gas regime is not yet reconciled with this matrix.

**The proposal below is therefore not adoptable as is.** The final tuple has to come from a peak measurement, and
the gasleft trajectory needs its own attribution.

## Measured bounds and proposals only

`W_matrix` is the maximum of the 12 rows above. `W_observed` additionally retains the exact original counterexample. Neither is a proof of a universal bound over every state, future engine version, context value, token configuration or state-gas reservoir regime.

| Runtime | W_matrix | Larger retained sample | W_observed used for proposal | ceil(1.15 × W_observed) | Proposed C_POSTOP | Proposed MIN_POST | Proposed SETTLE |
|---|---:|---:|---:|---:|---:|---:|---:|
| Cancun | 147,626 | — | 147,626 | 169,770 | 175,000 | 195,000 | 175,000 |
| Prague | 147,626 | — | 147,626 | 169,770 | 175,000 | 195,000 | 175,000 |
| Amsterdam | 389,186 | 389,218 | 389,218 | 447,601 | 450,000 | 470,000 | 450,000 |

Using the matrix alone yields Amsterdam `ceil(1.15 × 389186) = 447564`, the **same rounded proposal**. The frozen rule rounds upward to 5,000 gas and enforces C_POSTOP ≥ 175,000; SETTLE is conservatively set equal to the padded whole-frame bound, and MIN_POST = SETTLE + 20,000. Every proposed tuple satisfies SETTLE ≤ 1,000,000 and C_POSTOP ∈ [175,000, MIN_POST]. C_WRAP remains 5,000. These are measurement-derived candidates, not deployed values or demonstrated repairs of every no-subsidy case; a separate parameter-validation run would be needed before adoption.

## Evidence and limitations

Raw logs, machine-readable frame summaries, [engine versions](engines.txt) and [exact matrix commands](commands.md) are alongside this report. The retained full counterexample is `tmp/nosubsidy/counterexample-final-amsterdam.log`; its compact [result output](counterexample-result.log) is also saved here. The >5 MB counterexample trace is retained in the worktree's **untracked `tmp/nosubsidy/`** because the configured writable roots exclude `~/Dev/aastar/evidence-archive/nosubsidy/`. [SHA256SUMS](SHA256SUMS) records paths and hashes. The excerpt includes the following EntryPoint event for cost correlation; its EP storage/log opcodes are not counted inside the SP frame.

The standalone probe is only a calibration of the signed clear term; the matrix uses unmodified production code. The chosen matrix samples ordinary BALANCE/CREDIT, actual success/revert, fresh and repeated settlement, and the combined fresh-state path. It does not exhaust emergency/rotation/clamped-charge states or prove an upper bound for live bundler estimation. Source code explains why oracle/tier/policy reads are absent from these settlement paths; no internet-derived assumptions are needed for the reported numbers.
