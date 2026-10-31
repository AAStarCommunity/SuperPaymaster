# M3 reproduction kit — SP rerun

`../reproduction/` is a byte-for-byte copy of DSR-Research-Flow commit `0b030b54`,
`output/AOA_M3_Reproduction_Rehearsal_2026-10-30.zip`
(sha256 `e6ebc232796dfdf31dddc8d809e3d44715590f5b42c15558c8c0eb67f9c7dca5`). Its scripts are identical to the
source-only zip (sha256 `b8d25decfc8b7398ab4dc89f08143f22175aec853314a232fc0bcf7d82c04a4d`).
`MANIFEST.json` covers all 461 shipped files.

**Rehearsal data only.** The archive is the local anvil n50 run (chainId 31337, `runType: rehearsal`). It is not
chain evidence and not M3 acceptance.

## Reproduce

```sh
script/evidence/m3-reproduction-run.sh <out-dir> /usr/bin/python3 python3
```

The script requires a clean tree and extracts the kit with `git archive HEAD`. For each interpreter, it runs these
steps:

1. The manifest check.
2. 17 unit tests.
3. The self-test.
4. `scripts/gate/stats_from_csv.py --m3-package data/receive.json`, which generates the results.
5. A same-engine self-compare.
6. A compare against DSR's published `dsr-0b030b54-stat_results.json`
   (sha256 `6e0e44ca42fcd82d0b7207b97aa85fe3d3d1d711ee4fc330bce6a048ae816988`).

It finishes with a control: the reference is tampered by one digit. The compare must reject it and list the
numeric mismatch alongside the version mismatch.

## Result (`run/`, generated at the commit in `run/head.txt`)

| Interpreter | Self-compare | vs DSR reference |
|---|---|---|
| Python 3.9.6 | 10,706 fields, exact | exact, 10,706 fields |
| Python 3.11.9 | 10,706 fields, exact | differs only in `statisticalConfig.pythonVersion` |

The tampered reference was rejected with exit 1, and both mismatches were listed.
`run/SHA256SUMS` gives the hash of every output file.

**Note for DSR:** the kit README says Python ≥ 3.10, but the reference was generated on 3.9.6. Every statistic
agrees across 3.9.6 and 3.11.9. This is a same-engine reproduction, not an independent implementation.
