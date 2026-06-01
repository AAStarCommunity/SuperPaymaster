# SuperPaymaster — Security Validation Pipeline (production process)

> Branch `security/pre-mainnet-hardening` · 2026-05-31
>
> A staged, industry-standard verification pipeline mapped onto the dev lifecycle.
> Each stage has a cost/latency budget so fast checks gate every commit and the
> expensive ones gate releases. Goal: make "a green pipeline" actually mean
> "no known class of bug slipped through".

## Pipeline at a glance

| Stage | When | Tools | Budget | Gate |
|---|---|---|---|---|
| 1 · Authoring | every save / pre-commit | `solhint`, `forge fmt`, `forge build` | seconds | style + compile + EIP-170 size |
| 2 · Daily / PR | every push | `forge test`, `forge test --fuzz`, `forge coverage` | 1–5 min | tests pass + fuzz pass + coverage ≥ target |
| 3 · CI fast scan | every push/PR (server) | `slither`, secret-scan, tests | < 2 min | no new High/Medium static finding |
| 4 · Pre-release deep | release branch / major change | `mythril`, `forge invariant` (10k+), `echidna`, adversarial review | minutes–hours | invariants hold, no symbolic-exec violation |
| 5 · Release gate | tag / mainnet | external audit, coverage thresholds, P0 closed | days | sign-off |

---

## Stage 1 — Authoring (seconds, local/pre-commit)

```bash
solhint 'contracts/src/**/*.sol'        # lint: style + a set of security rules
forge fmt --check                       # formatting
forge build                             # compile (0.8.33, via-IR, Cancun)
forge build --sizes | grep -i paymaster # EIP-170: SuperPaymaster must stay < 24576
```
- **solhint** ✅ installed. Add a `.solhint.json` (see "Config" below) to enable the security ruleset (reentrancy, low-level-calls, tx-origin, etc.).

## Stage 2 — Daily / PR testing (1–5 min, local)

```bash
forge test                              # unit (currently 961/961)
forge test --fuzz-runs 10000            # property/fuzz tests, 10k runs
forge coverage --ir-minimum --report summary   # track coverage; gate critical contracts ≥ 90%
```
- Today's coverage: 65.75% lines overall; critical-path branch coverage is the gap (SuperPaymaster 71.65%, MicroPaymentChannel 60.71%, `utils/BLS.sol` 2.86%).
- **Action**: raise `[fuzz] runs` (see Config) and add property tests for the credit/debt, x402, and BLS paths.

## Stage 3 — CI fast static scan (< 2 min, server)

```bash
solc-select use 0.8.33
slither . --config-file slither.config.json   # fast static vuln scan
```
- **slither** ❌ not installed. Gate the CI on High/Medium severity (allow-list known/accepted).
- Keep the existing `check-secrets.yml` (private-key/secret scanning) in this stage.

## Stage 4 — Pre-release deep verification (minutes–hours, release branch)

```bash
# Symbolic execution on the critical contracts (deep, slow)
myth analyze contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol \
  --solv 0.8.33 --execution-timeout 3600

# Foundry invariant tests — 10k+ runs (solvency INV-03, debt monotonicity, voucher monotonicity)
forge test --match-contract Invariant --fuzz-runs 50000

# Echidna property fuzzing (configs already in repo)
echidna . --config echidna-long-run.yaml
echidna . --config echidna-all-contracts.yaml

# Optional second static engine
aderyn .
```
- **mythril, echidna, aderyn** ❌ not installed.
- **Invariant tests don't exist yet** — write them (this is a P0 from the audit): the INV-03 solvency invariant `protocolRevenue + Σ aPNTsBalance + pending == totalTrackedBalance` is exactly the property C-04 breaks.

## Stage 5 — Release gate (mainnet)

- [ ] Full third-party audit signed off.
- [ ] All P0 findings from `2026-05-31-pk-audit-findings.md` closed, each with a regression test.
- [ ] Critical-contract branch coverage ≥ 90%; `BLS.sol` verification path covered.
- [ ] Invariant + echidna campaigns clean on a long run.
- [ ] Ownership → multisig (Safe); deploy/upgrade rehearsed on a fork.

---

## Missing tools — install commands

```bash
# 1) solc-select — lets slither/mythril use the exact compiler (0.8.33)
pip3 install solc-select
solc-select install 0.8.33 && solc-select use 0.8.33

# 2) Slither — fast static analysis (Stage 3)
pip3 install slither-analyzer

# 3) Mythril — symbolic execution (Stage 4). Heavy; may need build deps.
pip3 install mythril
#   if it fails on macOS, prefer Docker:  docker pull mythril/myth

# 4) Echidna — property fuzzing (Stage 4)
brew install echidna
#   alternative:  docker pull trailofbits/echidna

# 5) Aderyn — Rust static analyzer (optional second engine, Stage 4)
cargo install aderyn
```
Already present: `forge`, `cast`, `solhint`, `python3/pip3`, `cargo`, `brew`, `pnpm`.

---

## Config to add (this branch)

**`foundry.toml`** — make fuzz/invariant first-class:
```toml
[fuzz]
runs = 10000              # daily; bump to 50000 pre-release

[invariant]
runs = 1000
depth = 50
fail_on_revert = false
```

**`.solhint.json`** (Stage 1 ruleset):
```json
{
  "extends": "solhint:recommended",
  "rules": {
    "reentrancy": "error",
    "avoid-low-level-calls": "warn",
    "avoid-tx-origin": "error",
    "not-rely-on-time": "off",
    "compiler-version": ["error", "0.8.33"],
    "func-visibility": ["error", { "ignoreConstructors": true }]
  }
}
```

**`slither.config.json`** — scope + noise control:
```json
{
  "filter_paths": "lib|contracts/lib|singleton-paymaster|node_modules|contracts/test|contracts/src/mocks",
  "exclude_informational": true,
  "exclude_low": false
}
```

**CI** (`.github/workflows/`): extend the existing secrets workflow with a `security.yml` running Stage 1–3 on every PR, and a manually-triggered `deep-scan.yml` for Stage 4.

---

## How this maps to the current findings

The PK audit (`2026-05-31-pk-audit-findings.md`) found 4 Critical + 2 High in the
**least-tested** paths. This pipeline is how we stop that recurring:
- **Stage 2 fuzz + Stage 4 invariant** would have caught C-04 (solvency break) and C-01 (unbounded debt).
- **Stage 3 slither / Stage 4 mythril** flag the missing-authorization patterns in C-02/C-03.
- **Stage 4 echidna + BLS.sol tests** target H-02 (BLS rogue-key).
