# CC-125 RR matrix — witness DETERMINED, Phase 2 runner

## Engine ruling and witness

Use **4e8874b2bdc840929585ca73e170993c50a4a531**, Amsterdam. The previously pinned
926eb1d is invalid for RR frame measurements: it leaves frame gas uncapped above 2^24
and reports stateGasReservoir = 0. Receipt-only agreement hid that defect.

Committed evidence supplied by the owner at c7b1d02f:

- `frame-calibration/nightly-4e8874b.json`: strict frame-level 10/10 against the chain
  node, including first-frame gas and reservoir; 926eb1d: 0/10 strict, 10/10 receipt-only
  (`frame-calibration/nightly-926eb1d.json`). No replay is needed for Phase 2.
- `r0-probe/probe-nightly-4e8874b-11982241.json`: 14/14 R0 probes. Both engines pass
  these R0 probes; R0 cannot distinguish the reservoir split.
- `witness-results.json`, `witness-traces.jsonl.gz`, `witness-run.log`: real local
  mined controls. `structLogs[].stateGasReservoir` is the consumption witness.
  RR starts with regular frame gas 2^24 minus intrinsic and reservoir gasLimit−2^24.
  Fresh SSTORE costs 110,020, including 97,920 state gas drawn from the reservoir first.
  fresh200 fails under R0 at slot 153 and succeeds under RR, gasUsed 22,020,200.
  fresh500 fails under RR with receipt gasUsed 16,777,216: reverted state gas returns
  to the reservoir. The final pre-opcode step alone does not show that final rollback.

**Witness = DETERMINED.** A high transaction limit alone remains insufficient: retain
per-step evidence of draw. `eth_call` does not apply the regular-gas cap on reth or this
engine; neither it nor eth_estimateGas is evidence of RR execution. View calls may read
ledger/price state; setup may estimate deployment transactions. All measured handleOps
use explicit gas and real mined receipts, never simulations or estimator results.

## Phase 2 execution and definitions

`script/evidence/rr-matrix-run.py` starts its own unforked 31337 anvil with
`--hardfork amsterdam --steps-tracing --order fifo --gas-limit 100000000` on loopback.
It builds offline, etches canonical EP v0.7, and runs unchanged DeployBLayerAnvil,
ams-gasparams and g1-setup. GasParams are activated with queue/48h/execute and read back:
440000/420000/5000/340000. Source and runtime hashes pin the bytes; rc.4's version()
string is `SuperPaymaster-5.5.0`, without an rc suffix.

Definitions are the Cartesian product of balance/credit, legacy160/V2, cold/warm,
first/subsequent sender op, positions 1/1, 1/3, 3/3, six scenarios, and postOp limits
439999/440000/440001. There are 864 definitions, 360 applicable cells, 504 applicability
exclusions, and 1080 measured handleOps transactions in a full run. Subsequent-history
cells also mine one R0 priming operation before the paired snapshot; priming traces are
retained separately. Each applicable cell restores identical state for R0 (2^24), RR30M
(30000000), and RRdelta (2^24+Δ, default Δ=100000). Signed bundles are built once and
reused byte-for-byte; timestamps, gas price and baseline state are identical across regimes.

Applicability and controls:

- Current V2 context means the emitted **384-byte** context. rc.4 decodes only 352 or
  384 bytes. The 5.4.2 160-byte format cannot reach postOp through this unchanged
  deployment. 352 bytes is a historical 5.5.0 upgrade context, also not emitted here.
  Legacy160 definitions are explicitly skipped; no context or SP bytecode is patched.
- Cold/warm describes the SP account and implementation at validation entry. Warm
  uses a transaction access list for both addresses (no storage keys). At target op 3,
  validation is already warm from ops 1/2: cold-3/3 is inapplicable. All postOp calls
  are naturally warm after validation. A previous transaction does not warm storage.
- First/subsequent means first/subsequent sponsored operation of the target sender,
  not account creation. Bundle companions are distinct BALANCE senders; a CREDIT
  target therefore does not inherit prior same-sender operations from its companions.
- MIN−1 is expected to fail validation (AA34), before reservation/postOp. A failed
  transaction's missing per-op events/costs are null, not measured zero costs.
- Success writes one marker slot; execution-revert writes then REVERTs. Refund clears
  eight preseeded nonzero slots; trace refund increases are checked inside that fixture.
  Refill writes eight fresh slots then REVERTs; the trace records the reservoir increase
  on failed-frame unwind. This is EIP-8037 rollback of state-gas expenditure, distinct
  from the EVM gas refund counter. A refill observation is required for admitted RR30M
  refill rows; R0 has no reservoir, and RRdelta may exhaust its reservoir in validation.
- `state-demand` is an extra pressure scenario: 24 fresh SSTOREs against a 1.5M call
  budget. R0 can exhaust execution gas while RR30M can pay state gas from its reservoir.
  Its actual outcome is recorded, and differences are flagged rather than assumed.
- `postOp-exhaustion` uses a **labelled adversarial token fixture**: the existing token
  clone runtime is copied to a shadow account; a wrapper at the token clone forwards
  via delegatecall, preserving storage/sender, except settleLocked/settleCredit for
  the target sender, which loop until OOG. SP and EP bytes remain unchanged. This is
  settlement-subcall exhaustion within postOp, not evidence that the unaltered token
  naturally exhausts at MIN. The fixture and original runtime are retained per cell.

## Trace, charging and invariant rules

Default struct logger retains stacks, regular gas, stateGasReservoir and refund;
callTracer supplies frame inputs/results. Frame mapping uses depth transitions plus
call type, destination and exact entry gas, skipping calls with no opcode frames.
Mapping failure stops capture; it never guesses a frame. Every trace is a .jsonl.gz
record with provenance, mined transaction, raw receipt and both trace formats.

Record handleOps entry, each SP validation and postOp entry (proxy and implementation),
all reservoir transitions, and the terminal observation. Successful RETURN/STOP has
an exact end reservoir; failed top-level exits expose only a pre-opcode terminal
observation, and `end` is explicitly null. No final reservoir is invented from that value.
PostOp entry regular gas is the requested entry gasleft proxy; the first GAS opcode
inside the implementation additionally records the actual guard gasleft return value.
The source's first GAS on this path is the `gasleft() < snapSettle` guard (after modifiers
and context checks). Record its PC and context snapshot; threshold is verified as 420k.
Comparisons flag guard changes, guard pass/fail changes, and any EP/transaction outcome
change independently. An execution change is not evidence of a guard change.

Bare cost follows rams-2a/REPORT.md §4.3 and G2: ceil(actualGasCost × price × 1e18 /
(10^decimals × aPNTsPriceUSD)). Fee target is ceil(bare × (10000+feeBps)/10000).
Charge is TransactionSponsored's fourth field (`debtAPNTs` in the ABI, charge in rc.4),
checked against LockSettled/CreditSettled and actual burn/debt deltas. All comparison
amounts are aPNTs base units; tokenUnits separately records xPNTs burn or credit debt.
Store the price/fee/rate snapshot and verify emitted context prices, mode and gas tuple.
Also record G2's conservative net-of-fee ETH conversion and no-subsidy result. A deficit
is reported, not hidden by replacing the charge or redefining the target.

I9 follows 03-final-spec.md and the G2 per-op assertions: no retained execution or
sponsorship record without settlement, SP charge equals token-side charge, at most
one settlement, and no reservation remains after explicit stale release. Report a
reserved-but-unsettled postOp failure before release separately; do not claim it settled.
I10 is defined in 03-final-spec.md §4, corrected by R10-M1/R10-M1b: after postOp failure
and stale release, execution effects and token charge are zero, operator a0 is restored,
protocolRevenue unchanged for the failed op, and SP's ETH deposit pays EP actualGasCost.
Validate aggregate operator/revenue/deposit accounting net of successful companions.
Validation nonce/state and totalSpent may remain.

Every run log starts with engine commit/version, repository commit, dirty path count and
exact subcommand. Fresh output directories prevent accidental evidence replacement.
SHA256SUMS covers each evidence directory except itself. No commits or external RPC.
