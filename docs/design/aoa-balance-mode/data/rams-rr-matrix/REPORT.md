# CC-125 / R2-F3 direction (i)

**Witness = DETERMINED. Phase 2 scripts are ready for operator execution; no Phase 2
measurement result is claimed here.** The earlier sandbox TCP-bind failure is superseded
by the owner's committed runs at c7b1d02f; it is not an unresolved witness question.

## Engine correction and positive control

| Evidence | Finding |
|---|---|
| frame-calibration/nightly-926eb1d.json | 10/10 receipt-only matches, **0/10 strict frame matches**; regular gas uncapped above 2^24, stateGasReservoir always zero |
| frame-calibration/nightly-4e8874b.json | **10/10 strict frame matches** against chain debug_traceTransaction; correct regular/reservoir split (foundry #17719) |
| r0-probe/probe-nightly-4e8874b-11982241.json | **14/14 R0**; both engines pass R0, which cannot discriminate the split |
| witness-results.json / witness-traces.jsonl.gz | 4e8874b mined controls expose per-step stateGasReservoir; fresh200 R0 fails at slot 153, RR succeeds with gasUsed **22,020,200** |
| Same witness, fresh500-RR | OOG with gasUsed **16,777,216**; state gas is returned to the reservoir on failure |

Under RR, regular gas starts at 2^24−intrinsic and reservoir at gasLimit−2^24.
Fresh SSTORE costs 110,020, including 97,920 state gas drawn from the reservoir first.
The per-step field, not a high limit or receipt-only agreement, is the witness.
`eth_call` does not apply the regular cap on reth or this engine; never infer RR behavior
from eth_call or eth_estimateGas. New Phase 2 runs require nightly
4e8874b2bdc840929585ca73e170993c50a4a531, unforked Amsterdam, steps tracing and FIFO order.

## DSR-to-cell map

Definitions: `script/b-layer/rr-matrix-lib.mjs::cells()`. Each applicable ID maps to three
records in `<run>/cells.jsonl` and `<run>/traces/<ID>-<regime>.jsonl.gz`. IDs have the form
`<mode>-<context>-<warmth>-<history>-<position>-<scenario>-<postGas>`.
There are 864 definitions, 360 applicable cells, 504 exclusions, 1080 measured transactions;
180 subsequent-history cells also retain a separately traced priming transaction.

| DSR item | Cell mapping / fields | Status |
|---|---|---|
| balance / credit | balance-* / credit-*; target b1 / b7; distinct BALANCE companions | Scripted; unrun |
| legacy / V2 context | legacy160-* excluded with reason; V2-* uses emitted 384 B | 160 B not reachable: rc.4 accepts only 352/384 B; 352 B not emitted here |
| cold / warm SP | *-cold-* / *-warm-*; warm access list covers proxy+implementation | cold target validation at 3/3 impossible, excluded; every postOp naturally warm |
| first / subsequent sender op | *-first-* / *-subsequent-*; priming tx before paired snapshot | Scripted; unrun |
| 1/1, 1/3, 3/3 | *-1of1-* / *-1of3-* / *-3of3-* | Scripted; unrun |
| success / execution revert | *-success-* / *-execution-revert-* | Scripted; unrun |
| postOp exhaustion | *-postOp-exhaustion-* | Labelled token settlement-subcall OOG fixture, SP bytes unchanged; not natural-token exhaustion evidence |
| refund | *-refund-* | Eight preseeded slots cleared; checks refund counter increases inside execution fixture |
| refill | *-refill-* | Fresh writes then REVERT; records reservoir restoration on failed-frame unwind under EIP-8037, distinct from gas refund |
| reservoir pressure differential | *-state-demand-* | Extra 24-slot workload; outcome changes recorded, not predeclared |
| MIN−1 / MIN / MIN+1 | ID suffix 439999 / 440000 / 440001 | Queue/execute tuple 440k/420k/5k/340k; MIN−1 expected AA34 before reservation/postOp |
| real R0 / RR | R0=2^24; RR30M=30M; RRdelta=2^24+Δ (default 100000) | Identical signed bundles and baseline snapshots; mined receipts only |
| reservoir trajectory / postOp gasleft | trace.handleOpsEntry, frames, transitions, terminal/end; perOp validationEntry/postOpEntry/postOpImplementationEntry/gasleftAtFirstGuardGAS | Raw struct logs + callTracer preserved; exact final reservoir null for failed top-level exits whose rollback is not exposed after the terminal opcode |
| guard question | comparisons.json: guardChanged, guardPassFailChanged, outcomeChanged | Separate guard pass/fail from execution/transaction outcome changes; context threshold verified 420k |
| per-op costs and token charge | perOp actualGasCost/actualGasUsed/spCharge/tokenCharge/tokenUnits/balanceBurn/debtAdded | Missing events on rejected transactions yield null costs |
| G2 / bare / fee target | priceSnapshot; perOp contextSnapshot, bareCost, feeTarget, chargeMinusBareCost, chargeMinusFeeTarget, netOfFeeChargeWei/g2NoSubsidy | Validation-time prices/fee verified against context; ceil conversions follow G2 / rams-2a §4.3 |
| I9 | perOp.I9, row.I9; reservationAfter / reservationAfterRelease | No retained execution/sponsorship without settlement; charge matches token burn/debt; stale reservations released and counted separately |
| I10 | row.I10 plus before/after/released/accounting/cleanup hashes | Defined in 03-final-spec.md §4, R10-M1/R10-M1b; check after stale release |
| provenance/integrity | header.json, runtime.json, stage logs, SHA256SUMS | Generated per fresh run; source hashes, engine/repo commits, dirty path count and exact command |

I10: after a postOp failure and stale release, execution effects and token charge must be
zero, the operator's a0 must be restored, protocolRevenue unchanged for that op, and SP's
ETH deposit bears actualGasCost. Accounting is net of successful companions. Validation
nonce/state and totalSpent may remain. A transient reserved-but-unsettled operation before
stale release is reported explicitly; it is not called a successful settlement.

## Validation and remaining work

Offline node syntax checks, Python compilation and dry self-test are recorded in
`offline-checks.log`. The self-test covers definition counts/applicability, gas regimes,
MIN−1 classification, rounding, trace frame mapping and adversarial-token dispatch.
It requires neither npm dependencies nor artifacts nor anvil. It does not establish
that deployment or the matrix executes successfully; those checks require the owner's run.

Run the README smoke command first, then the full command. Inspect generated REPORT.md,
summary.json, comparisons.json and any failure.json. Review actual reservoir draw/refill,
unknown guard outcomes, signed per-op deltas and any fee-target/G2 deficit before making
RR claims. The deliberate legacy and cold-3/3 applicability limits remain part of the
result, as does the distinction between natural-token paths and injected settlement OOG.

No public RPC, archive replay, source-contract/config edits, staging or commits were used
for this script-writing task. The existing witness/calibration evidence was read, not rerun.
