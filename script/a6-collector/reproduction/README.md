# AOA M3 publication statistics reproduction kit

This kit is self-contained Python source for offline AOA M3 arithmetic,
statistical reproduction, and archive consistency checking. It does not attest
chain truth, authorize transactions or sampling, or turn rehearsal data into
formal evidence. No RPC, signing key, network access, third-party Python package,
or installation step is required. Use Python 3.10 or later; exact comparisons
include the recorded Python version and source hashes.

## Run the checks

From the extracted kit directory:

```sh
python3 -m unittest -v scripts/test_aoa_m3_stats.py scripts/test_gate_stats_from_csv.py
python3 scripts/aoa_m3_selftest.py
```

The tests generate their own synthetic two-triplet archive in a temporary
directory. The intentionally tampered-result test prints a FAIL payload;
the unittest process must finish with `OK` and exit 0. Synthetic tests do not
replace 50 matched triplets in formal candidate data.

## Reproduce an archived M3 dataset

Supply the existing `aoa-m3-receive-v1` `receive.json` and **every** file in its
SHA256 inventory, preserving their relative paths. Keep raw input files intact.
The authorized publication entrypoint is `scripts/gate/stats_from_csv.py`:

```sh
python3 scripts/gate/stats_from_csv.py --m3-package data/receive.json \
  --json-out output/stat_results.json --latex-out output/tables.tex
python3 scripts/gate/stats_from_csv.py --m3-package data/receive.json \
  --compare-stat-results output/stat_results.json \
  --json-out output/reproduced.json
```

The defaults are 50 triplets, 10,000 percentile bootstrap resamples, seed
20261030, and Type-7 quantiles. CSV mode retains its historical seed 42;
pass `--seed 20261030` for a deliberate common seed. Copy generated tables
and retain the exact command alongside them, as required by A3.2. M3 outputs
include the publication entrypoint, source hashes, input hashes, per-attempt
records, and run type. `rehearsal` remains rehearsal. Generated LaTeX requires
the paper's normal `booktabs`, `graphicx`, and `amsmath` packages.

For ordinary CSV inputs, the existing invocation remains valid:

```sh
python3 scripts/gate/stats_from_csv.py --col txGasUsed SP=sp.csv VPM=vpm.csv \
  --cliff SP,VPM --seed 20261030 --out output/csv-stats.md \
  --json-out output/csv-stats.json
```

CSV cells are parsed as decimal numbers, preserving large integer observations.
Missing observations are skipped as before; empty samples, missing columns and
nonfinite values fail. Confidence intervals are `[low, high]`, not mean plus or
minus half-width. `boot_ci` now returns two Decimal endpoints. Cliff's delta
uses **P(first > second) - P(first < second)**, positive when the first sample
is larger; this intentionally corrects the old CSV entrypoint's opposite sign.
Skewness is adjusted Fisher-Pearson and undefined constant samples produce
`null`/`N/A`. Exact intermediate Fraction arithmetic produces decimal strings
rounded to at most 12 fractional places; convenience float fields remain
approximate and are not substitutes for those strings.

## Input and accounting boundaries

- All N-2 gas inputs come from the hashed passport. Row copies must agree.
- The current package adapter rejects row-supplied `executionGasUsed`, including
  producer flags claiming verification. N-2 results are identified intervals;
  paired differences propagate `[L_A-U_B, U_A-L_B]`. They are not execution-only
  gas, and the interval is not a sampling confidence interval.
- A future SP trace adapter must bind archived transaction/operation identity,
  method/version/hash, and the pinned EntryPoint measurement boundary. A producer
  report of trace reconstruction, including two-solution bounds, does not by
  itself enable exact-mode acceptance here.
- B-9 checks the positive-reservation, positive-charge BALANCE sampling path,
  event identities, proportional ceiling burn, budget balances and explicit
  zero post-state `lockedOf`/`debts`. Zero-reservation or zero-charge cases fail;
  they are not silently treated as tested general contract branches.
- Released reservation is not actual overcharge. Receipt and state consistency
  do not prove archive completeness, independent RPCs, a valid deployment pin,
  or unrestricted absence of residual state beyond the fields checked.

## Comparison protocol

`--compare-stat-results` is **same-engine reproduction**, not independent
implementation validation. Every semantic report field is compared, including
source hashes, Python version, per-attempt records, input/package hashes,
configuration, and metadata. Only root `statResultsComparison` is excluded
because it describes the comparison itself. Default tolerances are zero.
Integers compare exactly; p-values never use absolute tolerance. A different
implementation or changed source hash should fail this identity check.

An independent implementation requires a separate acceptance protocol before
formal sampling: use the same archived input inventory, operation identities,
exclusions, pairing, formulas, Type-7 convention, sign-test tie handling, and
Holm families; independently compare integer/interval accounting exactly and
compare rational p-values and endpoint decimal strings. For bootstrap equality,
freeze the resampling index stream (or match Python `random.Random.randrange`
with the same version, seed and per-metric reseeding); otherwise document a
separate numerical agreement criterion and do not call different random draws
bit-identical. No cross-implementation acceptance is asserted by this kit.

## Bundle integrity and upstream handoff

`MANIFEST.json` lists SHA256 digests for all shipped files (except the manifest
itself). Verify the extracted files against it before running. Source-only kits
ship no experimental dataset; tests remain executable from the kit. A builder
may explicitly add a rehearsal archive under `data/`, with all files copied
from its verified inventory. Never substitute synthetic or rehearsal data for
public-chain samples.

SP can vendor this directory through its existing delivery task, rerun the
commands, and return the public commit, raw input inventory, output files,
commands, and test results. Local packaging is not evidence of upstream
publication or formal M3 completion.
