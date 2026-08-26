# Changelog

All notable changes to SuperPaymaster are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [Semantic Versioning](https://semver.org/).

---

## [v5.5.0] — 2026-08-26 (RepCredit V16 — bounded credit issuance & guarded guardian governance)

Closes the two security gaps the DSR/RepCredit V16 paper identified. Delivered through
CC-48 as nine rounds of adversarial review (each round: independent read-only reviewer →
REQUEST_CHANGES → narrow fix), with final independent approval from Claude Opus, Codex and
the PR review daemon. Merged via PR #375.

Contract versions: `Registry-5.4.2` → **`Registry-5.8.0`**, `BLSAggregator-4.3.0` →
**`BLSAggregator-4.10.0`**. `SuperPaymaster` unchanged.

### Gap 1 — Credit issuance had no protocol-level bound (`Registry.sol`)

The pre-existing cap applied per proposal only, so splitting one large uplift across many
small proposals bypassed it entirely. Three layers now stand between reputation and credit:

- **Per-proposal aggregate cap** (`maxAggregateCreditUpliftPerProposal`): sums the actual,
  post-clamp positive credit-limit uplift within one proposal; atomic revert on breach
  (`AggregateCreditUpliftExceeded`).
- **Protocol-wide outstanding exposure** (`totalCreditExposure` / `maxTotalCreditExposure`):
  a running stock of outstanding credit that every proposal is measured against regardless of
  how the work is sliced. Negative changes release budget. Closes the splitting bypass
  (`TotalCreditExposureExceeded`).
- **Credit population re-seeding** (`seedCreditPopulation`, `creditPopulationEpoch`,
  `CreditPopulationNotSeeded` / `CreditPopulationCountMismatch`): the contract has no
  enumerable user set, so `totalCreditExposure` is necessarily a cached value. `setCreditTier`
  and `setLevelThresholds` change every user's `getCreditLimit` at once and would silently
  decouple that cache from reality — measured at 16.6x in one owner call. Both setters now
  unconditionally invalidate the population snapshot; issuance is blocked until it is re-seeded.
  The "who recalculates" question is enforced by the type/flow rather than left to memory.
- `CreditTiersNotMonotonic`: credit tiers must be monotonic; a non-monotonic price written to a
  currently-unreachable level reverts the moment `setLevelThresholds` grows to reach it.
- `setCreditPolicy(perProposalCap, totalCap)` + `CreditPolicyUpdated` /
  `CreditExposureResynced` / `ReputationProposalUplift` events.
- `blsDomainSeparator()` and versioned reputation message hashing, mirroring the aggregator
  byte-for-byte.
- `consumeGuardianExit(address)`: atomic Registry-side gate consumed by the aggregator's exit path.

### Gap 2 — Guardians could exit ahead of a slash (`BLSAggregator.sol`)

- **Two-phase exit**: `request` → 2-day delay → 1-day execution window
  (`GUARDIAN_EXIT_DELAY`, `GUARDIAN_EXIT_WINDOW`). Signing authority stops the moment the
  request is filed. Cancelling costs a 1-day cooldown (`GUARDIAN_EXIT_COOLDOWN`), which closes
  the request/cancel flip-flop. An exit that would drop the remaining active committee below
  threshold reverts (`GuardianExitWouldBreakQuorum`).
- **Pending-case freeze**: `pendingGuardianSlashCount` blocks exit while a case is open
  (`GuardianExitBlockedBySlash`).
- **The verdict is frozen, not the verifier**: `GuardianSlashCase` snapshots
  `fraudProofHash` at queue time. Snapshotting the verifier *address* was insufficient — for an
  upgradeable proxy, address, `code.length` and `extcodehash` are all invariant across an
  implementation swap, so an attacker could queue a case and then retroactively void it by
  pointing the verifier at code returning `false`. Execution now re-checks
  `guardiansHash` + `fraudProofHash` and never calls the verifier again. Verifier rotation,
  proxy upgrade and selfdestruct can no longer kill an already-queued case
  (`FraudProofMismatch`, `GuardianSlashJudgmentFrozen`).
- **Case state machine**: `queueGuardianSlash` → 4-day window (`GUARDIAN_SLASH_CASE_WINDOW`) →
  `executeGuardianSlash` (per-guardian, resumable, partial-progress via `guardianCaseResolved`)
  or `expireGuardianSlashCase`.
- **Versioned domain separation across every BLS path**:
  `domainSeparator() = keccak256(abi.encode(DOMAIN_NAME, block.chainid, address(this), address(REGISTRY)))`
  plus seven versioned tags (`TAG_QUEUE_SLASH`, `TAG_EXECUTE_SLASH`, `TAG_REPUTATION`,
  `TAG_PROPOSAL`, `TAG_POP`, `TAG_SIGNERS_COMMITMENT`, `TAG_FRAUD_PROOF`). A signature produced
  against an experiment aggregator is no longer byte-reusable against a production one.
- **PoP bound to the validator address** + duplicate-key rejection (`blsKeyOwner`,
  `DuplicatePublicKey`): a proof-of-possession in public calldata could previously be replayed
  by a different `ROLE_DVT` address to register one public key into several slots, presenting a
  single signer as N. `popDigest(validator, publicKey)` binds the registrant;
  `releaseKeyBinding` is the owner-only escape hatch for a mis-registration.
- **Verifier rotation hardening**: `proposeFraudProofVerifier` + 4-day
  `VERIFIER_ROTATION_DELAY`, an immediate power-reducing-only emergency disarm
  (`FraudProofVerifierEmergencyDisarmed`), and rejection of EOAs and EIP-7702 delegated
  accounts posing as contracts (`VerifierNotContract`, `VerifierIsDelegatedEoa`).
- `CombinedProposalNotSupported` / `EmptyProposalNotSupported`: the combined proof path is
  removed rather than left partially domain-separated.

### Governance & migration

- **Safe-compatible M-of-N owner gate** (`contracts/script/checks/GovernanceOwnerGate.sol`):
  production gates no longer accept "any address with code" as a Safe. Rejects the EIP-7702
  `0xef0100` delegation prefix, requires an explicit `GOVERNANCE_OWNER`, calls
  `getThreshold()` / `getOwners()` with exact-ABI decoding and fails closed, and requires
  `threshold >= 2`. This enforces a Safe-compatible M-of-N interface — it does not claim to
  prove a canonical Safe.
- **`UpgradeRegistryTo570.s.sol`**: atomic upgrade batch — the new exposure slot cannot sit at
  0 in an executable intermediate window. Migration preflight is runnable against the real
  4.3.0 predecessor, and tainted-key scanning cannot be silently skipped
  (`BLSKeyScanLib.sol`, `ScanDuplicateBLSKeys.s.sol`).
- Isolated successor deployment for RepCredit evidence (`DeployRepCreditSepolia.s.sol`). The
  prior experiment stack is retained as an immutable compromised audit archive and must not be
  reused.

### CI / build

- **Prague real-precompile gate** (`security.yml`): `forge test --evm-version prague` now runs
  in CI. Previously every BLS suite ran only under Cancun, where the EIP-2537 precompiles do
  not exist and `vm.etch`ed stubs decide whether a signature is valid — i.e. the BLS
  verification path had never been exercised against real pairings in CI.
  `contracts/test/helpers/MockedPrecompiles.sol` makes the two EVM targets complementary:
  injection-dependent suites skip themselves on Prague, and `contracts/test/paper7/` covers the
  same domain / exit / cap / key-scan / slash paths with real keys and real pairings.
- **Fail-closed contract-change detector** (`.github/scripts/detect-contract-changes.sh`,
  self-tested by `test-detect-contract-changes.sh` as the `gate-self-test` check). Replaces four
  inlined copies that shared three fail-open defects: `set -e` not applying to a command in an
  `if` condition, `printf | grep -q` inverting its answer on a >64 KiB diff under `pipefail`, and
  git's default `core.quotePath` C-quoting hiding non-ASCII contract paths. Every exit routes
  through `apply` (fail-closed) or `skip`.
- **Required checks made decidable**: `ci-required-shim.yml` removed as strict de-duplication —
  three check names each had two sources, which makes a required check undecidable. Job count
  11 → 8, distinct check names 8 → 8, duplicates 3 → 0. No check name was lost.
- **`abis/*.json` had drifted from source and is now correct.** The fail-open generator above
  meant the committed ABI silently stopped tracking the contracts. `abis/BLSAggregator.json`
  went 63 -> 159 entries: it was missing `executeGuardianSlash` (merged into `main` by PR #370)
  entirely, and still declared the pre-`evidenceHash` shape of `verifyAndExecute`
  (`...,uint256,bytes`, selector `0x2399c309`) while `BLSAggregator.sol`, `IBLSAggregator.sol`
  and `DVTValidator.sol:294` had all carried the 8-argument form (`...,uint256,bytes32,bytes`,
  selector `0xd38f1586`) for some time. **Downstream consumers that generated calls from the
  committed ABI were encoding a selector that does not exist on-chain — those calls reverted
  before this release, and are fixed by it.** `repo:sdk` (aastar-sdk v0.39.0 synced this file)
  and `repo:dvt` must re-sync from the post-merge ABI. Note this is a correction of a stale
  artifact, not a breaking interface change: no Solidity interface was modified.

- **ABI doc generator no longer invents contracts**: multi-segment artifact stems
  (`<Contract>.registry-size.json`, produced by the `registry-size` compiler profile) were being
  read as separate contracts — 93 contracts / 1624 functions before, 55 / 934 after.

### Compiler settings

- `foundry.toml`: `profile.v3-only` and `profile.tokens` aligned with `profile.default`
  (`optimizer_runs = 500`, `via_ir = true`). Two pre-existing bugs are fixed by this:
  `via_ir = false` put `GTokenStaking.sol` over "Stack too deep" so the whole `v3-only` profile
  failed to compile — the build command documented in CLAUDE.md had not produced an artifact in
  a long time — and `optimizer_runs = 10000` built SuperPaymaster at 27,597 B and BLSAggregator
  at 25,860 B, both over the 24,576 B EIP-170 limit and undeployable.
- `Registry.sol` restricted to `max_optimizer_runs = 200` in all three profiles
  (`compilation_restrictions`), buying EIP-170 headroom. This is a stopgap: the credit /
  reputation subsystem still needs to be split out of Registry.
- CLAUDE.md corrected: `forge build --profile v3-only` is not valid on forge 1.7; the profile is
  selected via the `FOUNDRY_PROFILE` environment variable.

### What the test numbers do and do not prove

Measured, not asserted — a mutation run (`BLS.sol` pairing result forced to a constant) shows
where the cryptographic coverage actually lives:

- **Cancun (`forge test`) is blind to BLS correctness.** Its suites `vm.mockCall` the pairing
  precompile at `0x0F`, so a broken pairing is caught by only **3 of 1344** tests. Cancun proves
  bookkeeping — slot assignment, duplicate keys, exit state machines, slash accounting — not
  cryptography.
- **Prague (`forge test --evm-version prague`) is the load-bearing gate.** The same mutation
  fails 14 tests, 14 of them inside `contracts/test/paper7/`. This is the only command that
  verifies signatures against real EIP-2537 pairings.
- **Read Prague's "20 skipped" carefully.** Ten suites skip in `setUp()`, which collapses each
  to a single reported skip and drops its remaining tests from the total: 1382 Cancun tests vs
  1277 Prague tests means **125 tests do not execute on Prague**, not 20. The two skip sets are
  disjoint and their union covers every test — verified by set comparison, so there is no test
  that never runs anywhere — but neither command's number is a coverage claim on its own.

Both commands run in CI (`security.yml`), so the gate as a whole is complete. Quote them
together or not at all.

### Known operational prerequisites (not blockers for merge)

- Existing Sepolia governance owners are EOAs; Safe/Timelock migration remains a manual
  production prerequisite.
- Registry EIP-170 headroom is tight — measure, never cite a remembered figure.
- Fraud-watcher timeliness remains an operational assumption.
- **`executeGuardianSlash` depends on an `IFraudProofVerifier` implementation this repository
  does not contain.** Every guardian-slash test here drives a `MockVerifier` returning `true`;
  `contracts/test/helpers/FraudProofVerifierConformance.sol` is a fixture exported for the DVT
  repo to run against its own implementation (mutation-tested here: neutering the fixture fails
  6 of 13 conformance tests, and it rejects all four non-conforming prototypes). The hardening
  in this release is therefore conditional on a conforming verifier being delivered and wired —
  tracked as CC-89 stage 0/2.
- `abis/DVTValidator.json` must be regenerated and provenance-checked before downstream use.

---

## [v5.4.1-rc.1] — 2026-06-27 (Sepolia Release Candidate)

### Security Fixes

- **S1 — Two-step slash guard** (HIGH, fixes #249): Operators could call `withdraw()` immediately
  after slash initiation to escape penalties. Added mandatory two-step flow:
  - `queueSlash(operator)` — governance sets `_pendingSlash[operator]`; emits `SlashQueued`
  - `withdraw()` reverts with `SlashPending()` if flag is set
  - Both `slashOperator()` and `executeSlashWithBLS()` now require `_pendingSlash` to be set first
  - `cancelSlash(operator)` — governance escape hatch; emits `SlashCancelled`

- **S2 — srcHash authority** (HIGH, Codex H-3): Deploy scripts previously wrote `srcHash` to config
  before audit ran, creating a window where unverified code could appear audited.
  - All forge scripts now write `srcHash=""` unconditionally
  - `deploy-core` is the sole authority: writes real hash atomically only after `audit-core` exits 0
  - `foundry.toml`, `remappings.txt`, `deploy-core` itself added to hash inputs

- **S3 — BLS_AGGREGATOR wiring** (HIGH, Codex H-2): Fresh deployments left `BLS_AGGREGATOR`
  as `address(0)`, silently disabling BLS-based slash execution.
  - `initBLSAggregator(address)` — one-time setter callable only when `BLS_AGGREGATOR == address(0)`;
    no timelock (fresh deploy path); `onlyOwner`
  - Called automatically in `DeployLive._executeWiring()` and asserted in `_assertWiring()`
  - Anvil deploy uses `queue + warp + applyBLSAggregator()` sequence

- **MEDIUM — `_assertWiring()` completeness**: Added assertions for `SP.BLS_AGGREGATOR` and
  price-feed address so wiring failures surface immediately at deploy time.

### Changed

- `SuperPaymaster.version()`: `"SuperPaymaster-5.4.0"` → `"SuperPaymaster-5.4.1"`
- `__gap`: `uint256[31]` → `uint256[30]` (`_pendingSlash` consumes one slot; no collision)
- `DeployLive.s.sol`: ASCII `-` replaces Unicode em-dash `—` in string literals (compiler rejects non-ASCII)

### Added (ABI)

| Function | Selector | Description |
|---|---|---|
| `queueSlash(address)` | `0x...` | Start two-step slash; sets `_pendingSlash` |
| `cancelSlash(address)` | `0x...` | Cancel queued slash; clears `_pendingSlash` |
| `initBLSAggregator(address)` | `0x...` | One-time BLS_AGGREGATOR wiring for fresh deploy |

Events: `SlashQueued(address indexed operator)`, `SlashCancelled(address indexed operator)`
Error: `SlashPending()`

### Verified (Sepolia, chainId 11155111)

| Contract | Address |
|---|---|
| SuperPaymaster proxy | `0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9` |
| SuperPaymaster impl v5.4.1 | `0x0274811E93B4AaE027c1A7dbF592e2B2D37E0250` |
| Registry proxy | `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71` |
| BLSAggregator | `0x893b8fb7B3d203C288b481400fE05Ade5edD6d11` |

Upgrade TX: `0xa57d6007cd98522b641286815a9501f193eb2fedddc773b38e502b78ab446771`

---

## [v5.4.0-beta.1] — 2026-06-11 (Sepolia)

### Added

- **x402 god-split**: `X402Facilitator` extracted from `SuperPaymaster` (~2,875 bytes recovered;
  EIP-170 compliance restored). Standalone facilitator handles x402 settlement + policy enforcement.
- **DVT hardening**: `PolicyRegistry` contract, golden test vectors, domain-separation tag `_POP_`
  for BLS proof-of-possession.
- **V54Bootstrap**: shared library wiring `DeployLive` / `UpgradeLive` / `DeployAnvil` for v5.4
  complete deployments via `./deploy-core`.
- **H-1 credit ceiling**, **M-1**, **#211 L-C**, sentinel-ordering fix, per-spender cap — security
  audit findings addressed.

---

## [v5.3.0] — 2026-03-23

### Added

- ERC-8004 Agent Identity + dual-channel sponsorship (`SBT OR Agent NFT`)
- `settleX402Payment()` / `settleX402PaymentDirect()` replacing Permit2
- Agent sponsorship policies: `setAgentPolicies()`, tiered BPS rates + daily USD cap
- EIP-1153 transient cache (`_getCachedBalance` / `_setCachedBalance`) for same-operator batch
- `IAgentIdentityRegistry`, `IAgentReputationRegistry`, `IERC3009` interfaces

---

## [v5.0.0] — 2026-03-22

### Added

- UUPS upgradeable proxies for Registry and SuperPaymaster (ERC1967Proxy)
- `BasePaymasterUpgradeable` base class
- `GTokenStaking.REGISTRY` and `MySBT.REGISTRY` made `immutable`
- `__gap[50]` storage gaps; `_authorizeUpgrade` restricted to `onlyOwner`
- Deployment order Scheme B (Registry proxy first, then Staking/MySBT with immutable REGISTRY)
