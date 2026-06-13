# SuperPaymaster ABI Documentation

Authoritative, drift-free ABI reference for the SuperPaymaster contract suite, generated straight from the Foundry compiled artifacts in `out/`.

## What's here

| File | Source | Contents |
|---|---|---|
| [`reference.md`](./reference.md) | **generated** | Per-contract reference: every external/public function with signature, 4-byte selector, params/returns (+ NatSpec), state mutability, best-effort access control; plus events (topic0) and errors (selector). |
| [`selectors.md`](./selectors.md) | **generated** | Global index of every function selector, custom-error selector, and event topic across `contracts/src/` — for decoding raw calldata / revert data / logs. |
| [`capabilities.md`](./capabilities.md) | hand-written | Capability-grouped map: product capability → the functions that implement it → the E2E test script that exercises it (the scripts are the best call examples). |
| [`sdk-integration.md`](./sdk-integration.md) | hand-written | Integration flows for the main capabilities (gasless sponsorship, x402 settlement, micropayment channel). |

> `reference.md` and `selectors.md` carry a `GENERATED FILE — DO NOT EDIT` marker. Hand edits are overwritten on the next regen.

## How the generated docs are produced

No third-party doc framework — a single Node ESM script ([`scripts/gen-abi-docs.mjs`](../../scripts/gen-abi-docs.mjs)) consumes the Foundry build output:

- `out/<C>.sol/<C>.json` → `abi` (fragments), `methodIdentifiers` (solc's authoritative signature → 4-byte selector map), and `metadata.output.userdoc/devdoc` (NatSpec `@notice`/`@dev`/`@param`/`@return`).
- Only contracts whose `compilationTarget` is under `contracts/src/` are documented (libraries, forge-std, OZ, account-abstraction are filtered out). Test (`.t.sol`) and script (`.s.sol`) artifacts are skipped.
- Function selectors come from solc's `methodIdentifiers`, cross-checked against a local `keccak256` (viem); event topics and error selectors are computed from canonical signatures.
- Access-control modifiers (`onlyOwner`, `onlyEntryPoint`, `onlyRegistry`, `onlyDAO`, …) are **not** in the ABI, so they're scraped best-effort from the Solidity source headers and labelled as such (`—` = none recognised on the declaration; may still be guarded in the body).

The output is a pure function of `out/` + `contracts/src/` (no timestamps) → re-running on an unchanged build produces byte-identical files.

## Regenerate

```bash
forge build            # produce out/
pnpm gen:abi-docs      # write docs/abi/reference.md + selectors.md
```

## CI / drift check

```bash
pnpm gen:abi-docs:check   # exit 1 if the committed docs are stale
```

Wired into CI (`.github/workflows/`) right after `forge build`/`forge test`, reusing the same `out/`. If the ABI changes and the docs aren't regenerated, CI goes red.

## A note on quality

The reference is only as good as the NatSpec coverage in the contracts — the generator can only render the `@notice`/`@dev`/`@param`/`@return` that exist in source. Keep NatSpec complete on new external functions.
