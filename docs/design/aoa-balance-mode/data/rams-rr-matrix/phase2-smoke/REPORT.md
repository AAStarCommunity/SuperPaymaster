# CC-125 Phase 2 capture

Engine: 4e8874b2bdc840929585ca73e170993c50a4a531; repository: 6d648cddd2221e00bc545f56dc1a8c49e56bbd06.
Selected definitions: 1; measured transactions: 3. Errors: 0.

| DSR dimension | Captured cell values |
|---|---|
| mode | balance |
| context | V2 |
| warmth | cold |
| history | first |
| position | 1of1 |
| scenario | success |
| postGas | 440000 |

Each ID in definitions.json maps to cells.jsonl and traces/<ID>-<regime>.jsonl.gz. Legacy160 and cold 3of3 are inapplicable (definitions include reasons).

I9, I10, charge and bare/fee targets are per-op fields in cells.jsonl. I10 includes stale-release checks. PostOp exhaustion uses the labelled adversarial token fixture.

Refund observations: 3; refill observations: 0; exhaustion observations: 0.

Guard or outcome changes: 0; all comparisons are in comparisons.json.

| Cell | RR regime | Guard changed | Guard pass/fail changed | Outcome changed |
|---|---|---|---|---|

