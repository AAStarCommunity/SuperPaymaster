# Commands (run from repository root)

Original counterexample: exact command in REPORT.md. Expected exit status: 1.
No `G2_*` environment overrides are used. The diagnostic test asserts the original queued tuple.

## Matrix (same Prague-compiled bytecode, three nightly runtimes)

```sh
forge_nightly="$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge"
for runtime in cancun prague amsterdam; do
  "$forge_nightly" test --offline --no-isolate --fuzz-seed 0x5eed \
    --evm-version prague --hardfork "$runtime" --disable-external-identification \
    --match-path contracts/test/v2/SuperPaymasterPostOpGasMatrix.t.sol \
    --match-test '^test_matrix_' -vvvvv \
    --opcodes SLOAD,SSTORE,TLOAD,TSTORE,LOG1,LOG2,LOG3,LOG4 \
    > "docs/design/aoa-balance-mode/data/nosubsidy-attribution/matrix-$runtime.log" 2>&1
done
```

The per-test inline `default.isolate = true` is intentional and applies despite the nightly
command's `--no-isolate` default. It makes each top-level fixture call and each handleOps a
separate transaction, while all operations *inside one handleOps* share access warmth.

## Stable controls (matching compiler/runtime targets)

```sh
for runtime in prague cancun; do
  "$HOME/.foundry/bin/forge" test --offline --fuzz-seed 0x5eed \
    --evm-version "$runtime" \
    --match-path contracts/test/v2/SuperPaymasterPostOpGasMatrix.t.sol \
    --match-test '^test_matrix_' -vvvv \
    > "docs/design/aoa-balance-mode/data/nosubsidy-attribution/matrix-stable-$runtime.log" 2>&1
done
```

Stable 1.7.1 has no `--no-isolate`, `--opcodes`, or `--disable-external-identification`; none is passed to it.

## Signed state-clear calibration (no debugger)

```sh
mkdir -p tmp/nosubsidy/probe/test
cp docs/design/aoa-balance-mode/data/nosubsidy-attribution/StateGasProbe.sol \
  tmp/nosubsidy/probe/test/StateGas.t.sol
for runtime in amsterdam prague; do
  "$forge_nightly" test --root tmp/nosubsidy/probe --offline --use 0.8.33 \
    --no-isolate --evm-version prague --hardfork "$runtime" \
    --disable-external-identification -vvvvv \
    --opcodes SSTORE,GAS,PUSH0,PUSH1,SWAP1,SWAP2,DUP1,DUP2,POP \
    > "docs/design/aoa-balance-mode/data/nosubsidy-attribution/state-gas-probe-$runtime.log" 2>&1
done
```

This creates no root configuration and does not modify the root foundry.toml. The calibration
has no imports and deliberately exposes the instructions between its two gasleft checkpoints.
Its unoptimized compiler setting does not affect SSTORE's measured protocol charge.

## Parse/review

```sh
python3 docs/design/aoa-balance-mode/data/nosubsidy-attribution/analyze.py \
  docs/design/aoa-balance-mode/data/nosubsidy-attribution/matrix-{cancun,prague,amsterdam}.log \
  > docs/design/aoa-balance-mode/data/nosubsidy-attribution/matrix-summary.json
```

`SHA256SUMS` paths are relative to repository root; check with `shasum -a 256 -c`.
The report's frame arithmetic includes the signed clear correction measured by the probe;
the parser intentionally preserves the tracer's displayed `[0]` cost instead of inventing a
negative opcode field.
