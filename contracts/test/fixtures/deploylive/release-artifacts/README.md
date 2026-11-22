# Offline release artifact fixtures

Extracted from the 5.5.4 branch build. The rc.8 copy is at tag `v5.5.0-rc.8`.
Retains ABI, creation/runtime bytecode,
immutable/link ranges, and the four artifact-selection settings only; excludes AST, source
maps, build-info and source contents. Full bytecode is required for actual Keccak pin checks.
These fixtures are test inputs, never a production artifact fallback. Tests select them at
call time, so they run before `forge build` and can still mutate artifact selection.

To refresh after a reviewed release, extract these fields from `release_artifact(name)` for
all `creation_pins.release_names()` plus SuperPaymasterAdmin and ERC1967Proxy.
`RuntimePinsTest.test_release_check_and_tampered_hash` verifies the fixture contents via `artifact_pins`.
The separate clean-build `runtime_pins.py ... --check` verifies compiler declarations.
