# CC-125 / R2-F3 direction (i) — incomplete, environment blocked

The requested engine is present: anvil 1.8.7-nightly,
926eb1d087523f1de437e3c0c49ea6d26407e827. The repository is on cc125/rr-matrix,
HEAD 2536c1e1fb1131499fec43ceecaa0ac2f1d50505.

The local, unforked Amsterdam control run failed during node startup:
`Error: Operation not permitted (os error 1)`. A separate Python standard-library
`socket.bind(('127.0.0.1', 18951))` check returned
`PermissionError: [Errno 1] Operation not permitted`. This session's sandbox does
not permit the local listener needed for these measurements. No permission escalation
is available in this session. No archive RPC is required by the Phase 1 script.

**Reservoir consumption observability is UNDETERMINED.** There is no mined receipt,
trace, positive-control result, or negative-control result. The higher-gas-limit
assumption is not substituted for a witness. Phase 2 has not started.

## DSR request coverage

| Requested item | Cell / artifact | Result |
|---|---|---|
| Witness design before matrix | DESIGN.md | Written; validation pending |
| Explicit receipt/struct logger/callTracer reservoir fields | Planned control capture | Not observable in this session because node cannot start; engine support unknown |
| Positive control | fresh1000-RR: 1000 distinct fresh SSTOREs, limit 30000000 | Script prepared; not mined |
| Negative control, same initial state and payload | fresh1000-R0: limit 16777216 | Script prepared; not mined |
| No-state control | stop-R0 / stop-RR | Script prepared; not mined |
| Real handleOps pairs, balance / credit | All matrix cells | Gated; not run |
| Legacy 160 B / V2 context | All matrix cells | Reachability not established |
| Cold/warm; first/subsequent sender; bundle positions 1/1, 1/3, 3/3 | All matrix cells | Not run |
| Success / execution revert / postOp exhaustion / refund / reservoir refill | All matrix cells | Not run; EIP-8037 refill point not established |
| Queue/execute GasParams 440k/420k/5k/340k; postOp MIN−1/MIN/MIN+1 | All matrix cells | Not run |
| Receipt gasUsed, per-op actualGasCost/actualGasUsed, charge, bare cost | All matrix cells | No values; not measured |
| I9, sponsorship reserved but never settled | All matrix cells | Not evaluated |
| I10 | 03-final-spec.md §4, I10; corrections R10-M1/R10-M1b | Defined; not evaluated |
| Charge − bareCost / charge − feeTarget and price/fee snapshot | All matrix cells | Not evaluated; no G2/fee-target computation claimed |
| Run provenance and failure | witness-run.log, anvil.log, witness-failure.json | Captured |
| Compressed trace evidence | witness-traces.jsonl.gz | Absent intentionally: no transaction mined |
| Evidence integrity | SHA256SUMS | Generated, excludes itself |

I10 requires checking state after stale release, not merely seeing a failed operation:
execution side effects and token deduction zero, operator a0 returned, protocolRevenue
unchanged, EP gas borne by SP ETH deposit. Validation nonce/state and totalSpent may remain.

## Required next step / open questions

Run the prepared witness capture where loopback TCP listeners are permitted. Inspect the
result before deciding whether the engine offers a consumption witness. If no witness
can be established from that capture or a justified differential, stop for the owner's
decision as requested. If one is established, build the SP matrix with per-cell witnesses.
The script currently captures candidate evidence; it does not automate a witness verdict
or implement the conditional SP matrix.

No commits, staging, public network calls, real-chain transactions, or edits to
contracts/src, contracts/script, or foundry.toml were performed. Prior 10/10 Sepolia replay
evidence was neither rerun nor treated as reservoir-consumption evidence for these cells.
