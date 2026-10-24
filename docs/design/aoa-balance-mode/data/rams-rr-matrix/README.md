# CC-125 reservoir measurement evidence

Status: **blocked before witness measurement**. The managed execution environment refuses
local TCP bind (`PermissionError: [Errno 1] Operation not permitted`). The specified anvil
also exits with that error. No transaction was submitted, no witness was established,
and no SP matrix claim is made. This does not establish that the engine lacks a witness.

Run from the repository root in an environment permitting loopback listeners:

```sh
python3.11 script/evidence/rr-matrix-witness.py
```

The runner uses only Python 3.11's standard library and the pinned absolute anvil binary.
It starts its own unforked Amsterdam instance on 127.0.0.1:18951 and terminates that process
on exit. It submits unlocked local transactions and snapshots/reverts control state.
It exits 2 on failure, 0 when capture completes. Capture completion alone does not approve
the witness gate: inspect the raw receipt and trace evidence under DESIGN.md's criteria.
Do not start the SP matrix until that gate is satisfied. No Node dependencies are needed
for Phase 1. The fixture is raw EVM bytecode; no project Solidity source is changed.

Outputs: provenance headers in witness-run.log and anvil.log; failure JSON on failed run;
on successful capture, witness-results.json and witness-traces.jsonl.gz. Each compressed
JSONL record contains one real mined receipt, default struct logger, and callTracer result.
The current failed attempt has no trace file because there were no mined transactions.
Re-running replaces the runner's generated capture outputs; archive an earlier run first
if it needs to be retained. SHA256SUMS covers all files in this directory except itself.

The root .gitignore ignores `*.log`; data/.gitignore currently makes an exception
with `!*.log` for this evidence subtree. Logs must still be force-added later as requested
by the owner/reviewer when archiving this evidence. This task makes no commits and does not stage files.

See DESIGN.md for the witness gate and REPORT.md for the DSR coverage map.
