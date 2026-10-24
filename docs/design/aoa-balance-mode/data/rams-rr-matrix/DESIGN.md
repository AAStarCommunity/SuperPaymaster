# CC-125 RR matrix — witness gate

Engine: Foundry nightly 926eb1d, Amsterdam, no fork. Phase 1 precedes all SP measurements.
A transaction gasLimit > 2^24 establishes an initial reservoir only; it is not a consumption witness.

## Phase 1

Use a tiny runtime that writes 1 into N distinct initially zero slots. Install this control
runtime with anvil_setCode (fixture setup only); execute it with real eth_sendTransaction
transactions. Revert to the same snapshot before each control. No eth_call or debug_traceCall
result counts as measurement. Record raw receipts, default struct logs, and callTracer outputs
from debug_traceTransaction as compressed JSONL.

First inspect the receipt and trace schemas for explicit state-gas/reservoir/refund counters.
If exposed, test their response to fresh SSTORE versus a STOP control and to R0 versus RR.
Otherwise evaluate a differential witness: the same state demand must exceed the regular
budget in both transactions, fail in R0, and succeed in RR. A mere success at a higher gas
limit is insufficient unless the trace establishes the regular-budget cap independently.
Inspect opcode gas transitions, especially SSTORE and GAS, to distinguish gas accounting
from a higher ordinary allowance. Trace costs/refund values alone are not presumed to be
reservoir usage. If no consumption witness can be validated, stop before Phase 2.

## Planned Phase 2 (conditional on witness gate)

Real EntryPoint v0.7 handleOps, rc.4 SP bytes from the existing B-layer harness. Paired R0/RR
runs start from identical snapshots and use the same signed operations and fee/price state.
Activate GasParams 440000/420000/5000/340000 with queue/execute. Cover balance/credit,
reachable context formats, cold/warm SP, first/subsequent sender operation, positions 1/1,
1/3 and 3/3, success/execution revert/postOp exhaustion/refund/refill, and postOp limits
439999/440000/440001. Unreachable combinations must be reported rather than synthesized
with altered SP code. Warm means within a transaction; previous transactions do not warm SP.
Each row needs a validated reservoir witness, raw receipt, EP events, token and reservation
state deltas, G2 bare cost and fee target using the validation snapshot. Context and reservoir
refill reachability must be established from local code/engine evidence, not assumed.

I9: reservation without settlement must not retain sponsored execution effects.
I10 is defined in 03-final-spec.md §4 (row I10), with R10-M1/R10-M1b corrections:
after postOp rollback and releaseStaleSponsorship, execution effects and token charge are
zero, operator a0 is returned, protocolRevenue is unchanged; SP ETH deposit pays EP gas.
Validation nonce/state and totalSpent can remain. Report reservation before/after release.

## Provenance

Every run log begins with engine version, repository commit, dirty path count and exact
invocation. Trace records are .jsonl.gz. SHA256SUMS covers evidence files except itself.
No archive access, public RPC, commits, source-contract edits, or real-chain signing.
