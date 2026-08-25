# CC-48 round-8 — stop claiming more than the code proves

Branch `codex/repcredit-e2e-evidence-20260823`, range `e8a8ac5b..HEAD`. Reviewer verdict
being answered: **REQUEST_CHANGES — 0 BLOCKER / 0 HIGH / 2 MEDIUM / 5 LOW** (comment
`12fc0a84`, the first independent review of `e8a8ac5b`; the round-7 review session was
interrupted by quota exhaustion before producing findings, recorded in `7e8f6ec0`).

This document **supersedes** §2 and §7 of `docs/security/CC48-round7-changes.md`, which
both carried claims that are now retracted in place. Everything the reviewer confirmed
closed in `e8a8ac5b` — the governance gate's owner classification, the Timelock atomicity
proof, the real-4.3.0 unblock, the 7702 verifier rejection, the ABI-generator fail-closed
control, the Safe onboarding runbook — is unchanged and regressed, not rewritten.

| # | Finding | Sev | Status |
|---|---|---|---|
| 1 | MEDIUM-1 — the sentinel was still fingerprintable by calldata length; "indistinguishable" was falsifiable | MEDIUM | fixed + claim downgraded to the truth |
| 2 | MEDIUM-2 — `BLSAggregator.sol` still asserted the owner is a Safe multisig and that the gate enforces it | MEDIUM | fixed + a source-text regression test |
| 3 | LOW-1 — `LOCAL_DEV_GOVERNANCE_ACK` was satisfied unconditionally by the shell entry points, on a false premise | LOW | fixed at both layers |
| 4 | LOW-2 — `GOVERNANCE_OWNER` was neither required nor compared to the live owner | LOW | fixed, fail-closed |
| 5 | LOW-3 — deployment transcripts printed `BLSAggregator 4.9.0` while deploying 4.10.0 | LOW | fixed |
| 6 | LOW-4 — the ABI-drift scope was stated wrongly ("just a newline") | LOW | corrected with a measured breakdown |
| 7 | LOW-5 — the Timelock test claimed to bind the shipped batch and was a copy of it | LOW | fixed by construction |

---

## 1. MEDIUM-1 — the sentinel moved the evasion instead of closing it

**The finding.** Round 6 sent `CATCH_ALL_SENTINEL` as a bare 4-byte selector, which
`if lt(calldatasize(), 36) { revert }` defeated. Round 7 sent it as its full 68-byte
`(bytes32,uint256)` pre-image and wrote that this made it "indistinguishable from a genuine
call to a real method". It did not. **68 bytes was the only 68-byte probe in the entire
library**, so `if gt(calldatasize(), 36) { revert }` — one instruction, the exact mirror of
round 6's — separated it from every real getter while still fabricating clean answers to
all of them. The reviewer ran the whole preflight against such a fixture on Prague and got
three green lights (predecessor binding, taint scan, pending check) for a contract that was
never asked anything.

**The fix — the SET of widths, not a better single width.** This library makes exactly nine
distinct calls to an aggregator, and every one is 4 bytes (`MAX_VALIDATORS`,
`defaultThreshold`, `minThreshold`, `version`, `GUARDIAN_SLASH_CASE_WINDOW`) or 36 bytes
(`validatorAtSlot`, `getBLSPublicKey`, `blsKeyOwner`, `pendingGuardianSlashCount`,
`slashThresholds`, `guardianSlashCases`, `guardianExitRequests`) — every probed argument
list is exactly one static word. `_answersAnySentinelShape` now sends the sentinel at
**4, 36 and 68 bytes** and treats an answer at any of them as a catch-all. A fallback that
answers anything the library will later trust therefore necessarily answers a sentinel of
the *same width*, and **no `calldatasize` predicate — `lt`, `gt`, `eq`, a range or a set —
can admit the one and refuse the other.**

**And one level below that: argument values.** Probing each width once would have reopened
the same hole a third time — `if iszero(calldataload(4)) { revert }` admits
`pendingGuardianSlashCount(address(1))` while refusing a zero-argument sentinel. The
36-byte shape is therefore sent **twice, with 0 and with 1**, which are the only two
argument values the real one-word probes carry (`guardianSlashCases(0)`,
`validatorAtSlot(0)` versus `pendingGuardianSlashCount(address(1))`,
`guardianExitRequests(address(1))`). `ArgValueDiscriminatingCatchAllStub` /
`test_AnArgValueDiscriminatingCatchAllCannotEvadeTheSentinelEither` asserts the single-value
sentinel being evaded *first*, then the fix. A predicate ranging over the argument's whole
unbounded domain remains out of reach — a fixed probe set cannot cover an unbounded one —
and folds into the stated limitation below.

**The claim, downgraded to what is provable.** `guardianSlashCapability`'s NatSpec now
carries `STATED LIMITATION 1`: step 0 proves that a **shape**-based catch-all is refused,
and proves *nothing* about a **selector**-whitelist liar. A contract that declares exactly
the probed selectors, returns a fabricated value of the right width for each, and has no
fallback is indistinguishable from a genuine getter set at the probe layer, at any width,
by construction — that is what "implements this function" means over a `staticcall`
interface. Rounds 6 and 7 both said otherwise; both statements are retracted.

Two new fixtures and two new tests in `contracts/test/security/CC48MigrationPreflight.t.sol`:

- `SizeDiscriminatingCatchAllStub` / `test_ASizeDiscriminatingCatchAllCannotEvadeTheSentinelEither`
  asserts the **defect first** (it fabricates a clean 32-byte `pendingGuardianSlashCount`
  *and* a clean `MAX_VALIDATORS() == 0`, and it *does* evade the round-7 68-byte probe,
  reproduced inline so a regression re-fails this test) and only then the fix (the 4-byte
  and 36-byte sentinels both land → `Ambiguous`, and `requireNoPendingCases` reverts).
- `SelectorWhitelistLiarStub` / `test_ASelectorWhitelistLiarIsNotDetectableAtTheProbeLayer`
  is the **executable statement of the limit**. Every sentinel width reverts against it; it
  classifies `Present`, so the pending scan is *not skipped* — it runs, reads a fabricated
  `MAX_VALIDATORS() == 0`, iterates zero times and reports clean. The test ends by showing
  what actually keeps it out: `requireDeclaredPredecessor` reverts with
  `PredecessorMismatch` because the scan target is pinned to `Registry.blsAggregator()`.

**Residual, stated plainly.** Reaching this fail-open requires governance to have already
wired a hostile aggregator into the live Registry. That is the same residual the reviewer
weighed when scoring round 6's version of this finding MEDIUM, so the severity is unchanged
and the mitigation is the predecessor binding, not the probe.

## 2. MEDIUM-2 — the file downstream actually reads still asserted canonicity

`GovernanceOwnerGate.sol`'s own NatSpec sets the rule: *"every message, log line and
document in this repo must say 'Safe-compatible M-of-N', never 'is a Safe'."* Six lines in
`BLSAggregator.sol` — the file `repo:dvt` and `repo:sdk` consume, together with its ABI —
broke it: `owner MUST be a Safe multisig`, `GovernanceOwnerGate.sol enforces the multisig`,
`the owner being a Safe multisig, and nothing else`, `for the DISARM path the multisig is
the ONLY governance defence`, and the disarm paragraph's closing sentence. One more sat in
`UpgradeRegistryTo570.s.sol`. Round 7's delivery comment said "code, log and docs all say
Safe-compatible M-of-N"; that was true of the log and of `GovernanceOwnerGate.sol` and
false of `BLSAggregator.sol`.

All of them now state the interface-and-threshold property and, where the disarm threat
model is spelled out, state explicitly what the gate does **not** prove. The old wording is
recorded as retracted rather than silently swapped.

`test_NoSourceFileClaimsTheGateProvesACanonicalSafe` turns the grep two consecutive
reviewers had to run into a test: it `vm.readFile`s `BLSAggregator.sol`,
`GovernanceOwnerGate.sol` and `UpgradeRegistryTo570.s.sol`, refuses four canonicity-asserting
phrases, and **also** requires each file to still state the `Safe-compatible M-of-N`
property — so the rule cannot be satisfied by deleting the threat model instead of fixing
it. Scope is those three files: unrelated operational notes elsewhere ("hand it to the
multisig post-deploy") are not claims about what an on-chain check established.

No logic, ABI, storage or bytecode change — comments only in `BLSAggregator.sol`.

## 3. LOW-1 — the ack was typed by a script, not by a human

Round 7 required `LOCAL_DEV_GOVERNANCE_ACK` to be typed, then had `deploy-core anvil` and
`scripts/deploy-core.sh anvil` export it on every run, justified as "a genuinely local node,
started by this repo's own tooling". **That justification was false.** `deploy-core` does not
start anvil; `run_full_regression.sh` only tells the operator to start one, and
`deprecated/scripts/test-anvil.sh` starts `anvil --fork-url "$SEPOLIA_RPC_URL"`. So on the
fork-rehearsal path — the one the round-7 section exists to close — the ack was set
automatically and nobody acknowledged anything.

Both halves are now real:

- **Shell:** the ack is **probed for**, not assumed. Each entry point asks the node for its
  chain id and head block (`cast chain-id`, `cast block-number`) and pre-sets the ack only
  when the answer is chain id `31337` **and** a head block below `1000000`. A fork, an
  unreachable node or a missing `cast` all leave it unset and print what the operator must
  type. An ack already present in the environment is never overwritten.
- **Gate:** `_gate` refuses a 31337 chain whose `block.number >= LOCAL_FRESH_BLOCK_CEILING`
  (1,000,000) **regardless of who set the ack**, and the skip log now prints the head block
  it judged.

Stated limitation, in the constant's own NatSpec and here: this is a **heuristic, not a
proof**. Forking a chain whose head is below the ceiling would still pass, and nothing
on-chain can prove a node is not a fork. What it buys is that the realistic mistake —
rehearsing against a fork of a *live* chain (Ethereum ~23M, Sepolia ~9M, OP ~1.4e8, versus a
fresh anvil's few hundred blocks after a full deploy) — can no longer skip the gate.

Asserted in `test_GateBehaviourAcrossChainsAndOwnerShapes`: with the ack set and
`vm.roll(LOCAL_FRESH_BLOCK_CEILING)`, both the normal and strict gates refuse and the
message names `round-8 LOW-1` and `FORK`; at `CEILING - 1` the skip still works, so ordinary
local development is unaffected.

## 4. LOW-2 — `GOVERNANCE_OWNER` was decorative

Round 7 read `GOVERNANCE_OWNER` only inside `_declarationHint`, to choose between two
failure *messages*. It did not participate in any decision: unset passed, and set-to-the-
wrong-address passed whenever the live owner happened to satisfy the gate on its own. The
round-6 receiving requirement (`607377bc`) had asked for an explicit `GOVERNANCE_OWNER`.

It is now binding, in two directions:

- **Declared ≠ live owner → refused**, on every path including the acknowledged testnet
  ones. This is the shape "the operator named a Safe and the transfer silently did not land"
  takes, and under round 7 `TESTNET_EOA_OWNER_ACK` waved the resulting EOA-owned aggregator
  straight through while the transcript named a Safe.
- **Accepted as M-of-N while nothing was declared → refused.** Deployment evidence has to be
  reconcilable against an intent somebody stated; "whatever address ended up owning it
  answered `getThreshold()`" is not a governance decision anyone made.

Ordering matters and is deliberate: the binding check runs at the **end** of each path, so a
wrong declaration never masks the more specific diagnosis (`EIP-7702 DELEGATED EOA`,
`threshold < 2`) that the operator has to fix first. Experiment stacks that declare no
governance owner — the honest statement of what they are — are unaffected.

Because the 5.7.0 migration gates **two** subjects with independent owners, one global env
var could only bind one of them. `requireGovernanceOwnerStrictDeclaredAs` takes the variable
name, and `UpgradeRegistryTo570` now binds `Registry` to `REGISTRY_GOVERNANCE_OWNER` (on the
branch where `TIMELOCK` is unset; the `TIMELOCK` branch was already an explicit declaration
checked against the live owner) and the new aggregator to `GOVERNANCE_OWNER`. The variable
name appears verbatim in every failure message, and the accepted-owner transcript now prints
`declared via : <VAR> (checked == owner)`.

## 5. LOW-3 — the transcript named a build that was never deployed

`DeployBLSAggregatorSepolia.s.sol` printed `BLSAggregator 4.9.0 … deployed at:` while
deploying 4.10.0, and its NatSpec said the same; `DeployRepCreditSepolia.s.sol` asserted
`== "BLSAggregator-4.10.0"` with the revert message `"BLSAggregator is not 4.9.0"`. In a
round whose whole subject is evidence saying what it actually proves, the deployment
evidence named the wrong contract.

The `console.log` now reads `agg.version()` off the deployed contract instead of restating a
literal that has to be remembered, so this class of drift cannot recur on that line. The
revert message and the two NatSpec references are corrected. Historical statements ("before
4.9.0 no owner entry point could…", "from 4.9.0 the owner CAN…") are left alone — they are
about when a property arrived and are accurate.

## 6. LOW-4 — the ABI-drift scope was stated wrongly

Round 7's delivery note said the committed artifacts differ from a clean regeneration only
in the trailing newline, plus GToken's legacy bare-array format. Reproduced independently
this round over the 17 contracts the script regenerates:

| Class | Count | Files |
|---|---|---|
| byte-identical | 4 | `BLSAggregator`, `LivenessRegistry`, `ReputationSystem`, `SuperPaymaster` |
| trailing newline only | 1 | `Registry` — and only `Registry` |
| legacy **bare array** (real shape change) | 9 | `GToken`, `GTokenStaking`, `MicroPaymentChannel`, `MySBT`, `PolicyRegistry`, `TimelockController`, `X402Facilitator`, `xPNTsFactory`, `xPNTsToken` |
| same shape, **stale content** | 3 | `DVTValidator`, `Paymaster`, `PaymasterFactory` |

The last row is the one that matters downstream and was not in any previous list:
`abis/DVTValidator.json` is ~22.1 kB committed against ~25.4 kB regenerated — genuinely
older than the current build, not a formatting difference. **`repo:dvt` consumes exactly
that file**, so it must regenerate before pinning.

`abi.config.json` remains self-consistent with what is committed (the drift is against the
current build, not within `abis/`), and `abis/BLSAggregator.json` is byte-identical to a
clean regeneration — this round changes no ABI at all. Nothing is silently broken today; the
normalisation of all 13 drifting files is a breaking change for the 9 bare arrays and still
needs its own commit and its own notice to `repo:sdk`. The corrected breakdown, and the
command to reproduce it, are recorded in `scripts/extract_v3_abis.sh` where the wrong
version lived.

## 7. LOW-5 — "binds to the shipped parameters" was a copy, not a binding

`CC48RegistryTimelockGovernance`'s NatSpec claimed the salt and predecessor were "exactly
the ones the script emits … so this test binds to the shipped parameters rather than to a
convenient reimplementation of them", and its constants carried the comment "changing either
in the script without changing it here makes this test fail". Both were false: the constants
were local, `_batch()` was a hand-written copy, and changing the salt in
`UpgradeRegistryTo570` left the test green.

`contracts/script/checks/RegistryUpgradeBatchLib.sol` is now the single definition of
`BATCH_SALT`, `NO_PREDECESSOR`, `buildBatch(...)` and `upgradeOnlySubBatch(...)`. The script
and the test both call it, so an edit to the shipped batch **is** an edit to what the test
asserts — by construction, not by discipline.

The reviewer also flagged `assertEq(registry.version(), "Registry-5.7.0", "upgraded")` as a
vacuous assertion: `UUPSDeployHelper` deploys 5.7.0, so it held before the batch too. The
test now captures the ERC-1967 implementation slot before scheduling and asserts it
**moved** after execution — the non-vacuous statement that step (1) actually ran — and
additionally asserts the batch shape it is exercising (three calls, every target the proxy,
every value zero). The four substantive post-conditions (`blsAggregator`,
`maxTotalCreditExposure`, `totalCreditExposure`, per-proposal cap) and the counterfactual
are unchanged.

## 8. Observation carried forward, not fixed (reviewer's own filing)

`proposeFraudProofVerifier` / `applyFraudProofVerifier` still perform no `code.length` or
7702 check; the rejection happens in `queueGuardianSlash`. Governance can therefore install
a 7702-delegated address that *looks* armed while every `queueGuardianSlash` reverts, for at
least one `VERIFIER_ROTATION_DELAY`. The reviewer filed this as an observation rather than a
finding, on the grounds that round 3 made the same siting decision for `VerifierNotContract`.
It is **not** changed this round, so that it is reviewed as its own decision rather than
smuggled into a narrow-fix round.

## 9. Residual risks — unchanged from round 7, restated so they are not lost

- **`Registry` bytecode headroom:** 23,771 B of 24,576 — 805 B free. Release residual; the
  next core extension splits a module first.
- **Watcher liveness:** guardian-collusion detection still depends on someone noticing and
  queueing a case in time. It is not on-chain automatic detection; a paper/operational
  assumption, not a solved problem.
- **Real Sepolia migration:** `Registry` and the live 4.3.0 aggregator are both EOA-owned
  today, so `UpgradeRegistryTo570` stops at the strict gate. The prerequisites (Registry →
  Safe, new aggregator → Safe, Prague RPC, `OLD == Registry.blsAggregator()`) remain manual
  ops steps with no script in this repo, and round 8 adds two more declarations
  (`GOVERNANCE_OWNER`, `REGISTRY_GOVERNANCE_OWNER`). Nothing here claims the real migration
  is end-to-end unblocked.
- **Canonicity:** the gate proves a Safe-**compatible** M-of-N interface and threshold. It
  does not prove a canonical Gnosis Safe, and no message, log line or NatSpec in the CC-48
  governance files may say otherwise — now enforced by a test.

## 10. ABI / version impact

**None.** This round changes a script library, a check library, two shell entry points,
comments in `BLSAggregator.sol`, and tests.

| Item | Round 7 | Round 8 |
|---|---|---|
| `BLSAggregator.version()` | `BLSAggregator-4.10.0` | **unchanged** |
| `BLSAggregator` ABI | 56 errors incl. `VerifierIsDelegatedEoa(address)` | **unchanged** |
| `Registry.version()` | `Registry-5.7.0` | **unchanged** |
| domain separator | `keccak256(DOMAIN_NAME, chainid, aggregator, registry)` | **unchanged** |
| storage layouts | SuperPaymaster 37 slots, Registry 28 slots | **unchanged** |

New operator-visible requirements (not ABI, but they will break a migration run that does
not set them): `GOVERNANCE_OWNER` must be set and equal to the aggregator's live owner
wherever an M-of-N owner is accepted, and `REGISTRY_GOVERNANCE_OWNER` likewise for
`Registry` on the non-`TIMELOCK` branch of `UpgradeRegistryTo570`.

`repo:dvt` — the verifier seam (`verify` selector `0x61077735`, `assertSetBound`,
`assertDomainBound`) is untouched this round, but see §6: regenerate `abis/DVTValidator.json`
before pinning it.

## 11. Verification

Recorded in full in the CC-48 round-8 delivery comment: `forge build` under both profiles,
full Cancun and Prague test runs, the focused CC-48 and paper7 suites, the storage-layout
check, EIP-170 runtime sizes measured from `out/`, an independent ABI regeneration, and
`git diff --check` over the commit range.
