# Offline release artifact fixtures

Extracted from the rc.8 release build at 82bf3e2e. Retains ABI, creation/runtime bytecode,
immutable/link ranges, and the four artifact-selection settings only; excludes AST, source
maps, build-info and source contents. Full bytecode is required for actual Keccak pin checks.
These fixtures are test inputs, never a production artifact fallback. Tests select them at
call time, so they run before `forge build` and can still mutate artifact selection.

To refresh after a reviewed release, extract these fields from `release_artifact(name)` for
all `creation_pins.release_names()` plus SuperPaymasterAdmin and ERC1967Proxy. Run
`runtime_pins.py deployments/runtime-pins.10.json --check --artifacts contracts/test/fixtures/deploylive/release-artifacts`.
The separate clean-build `runtime_pins.py ... --check` verifies compiler declarations.
