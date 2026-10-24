# CC-125 reservoir measurements

**Witness = DETERMINED on nightly 4e8874b.** The owner ran and committed the controls and
calibration at c7b1d02f. 926eb1d has no functioning reservoir split; its receipt-only
10/10 agreement is insufficient. See DESIGN.md and REPORT.md for evidence paths.

Phase 2 is implemented but has not been executed in this sandbox. Run from the repo root
where local TCP listeners are permitted. Requires Node, Python 3.11, locally installed
`viem`, initialized submodules, cached solc 0.8.33, and the calibrated nightly's anvil/forge.
The launcher builds with `--offline`; it does not install or download dependencies.
If the checkout lacks Node dependencies, populate them from your existing offline cache
(for example `pnpm install --offline --frozen-lockfile`) before running.

Offline checks (no node, artifacts, or npm packages needed for the self-test):

```sh
node --check script/b-layer/rr-matrix-lib.mjs
node --check script/b-layer/rr-matrix.mjs
PYTHONPYCACHEPREFIX=/tmp/rr-matrix-pycache python3.11 -m py_compile script/evidence/rr-matrix-run.py script/evidence/rr-matrix-witness.py
python3.11 script/evidence/rr-matrix-run.py --self-test
```

Start with one cell (three real transactions):

```sh
python3.11 script/evidence/rr-matrix-run.py --out docs/design/aoa-balance-mode/data/rams-rr-matrix/phase2-smoke --filter balance-V2-cold-first-1of1-success-440000
```

Full matrix, **1080 measured handleOps transactions plus 180 history priming transactions**:

```sh
python3.11 script/evidence/rr-matrix-run.py --out docs/design/aoa-balance-mode/data/rams-rr-matrix/phase2
```

The default engine is `/Users/jason/Dev/aastar/tools/foundry-rams/nightly-4e8874b/anvil`;
forge defaults to its sibling. Override with `RR_ANVIL`/`RR_FORGE` or `--anvil`/`--forge`.
Both binary commits are checked. Options: `--port` (default 18952), `--delta` (default
100000), `--filter` (cell-ID substring). Output must be a new directory inside this repo.
The launcher owns and stops its unforked anvil. Deployment signs only with anvil's public
dev key, against loopback 31337. Measurement submission uses unlocked local transactions.
`eth_call` is used only for reading state; it and eth_estimateGas never determine RR outcomes.

Outputs include headers and logs, source/runtime hashes, activated GasParams and setup,
all definitions with applicability reasons, per-cell JSONL, raw `.jsonl.gz` traces,
comparisons (including guard pass/fail changes), summary, generated REPORT.md and SHA256SUMS.
Full traces can consume substantial disk/time. Results are flushed per transaction;
a failed run retains its partial evidence and writes failure.json. Exit 2 indicates an
execution/check failure; even exit 0 requires reviewing coverage and comparisons. Skipped
legacy contexts, MIN−1 rejection, and injected exhaustion must not be presented as natural
settlement measurements of those unreachable paths. The root report has the coverage map.

Root `.gitignore` ignores `*.log`; `data/.gitignore` currently exempts evidence logs and
`.gz` files. Logs must be force-added later as requested when archiving the evidence.
This task does not stage or commit files. Do not rerun the witness into this committed
directory unless replacing its existing control evidence is intended.
