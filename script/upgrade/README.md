# Unsigned Safe A6e SuperPaymaster upgrade

This executor prepares CC-125's Safe A6e route from Sepolia SP 5.4.2 to candidate `v5.5.0-rc.4` (`fbd74fb1e2e9d948996e6d6c02c48dc1c1778107`). Read the [design](../../docs/release/sp-upgrade-a6e/DESIGN.md) for the authority model, ordered calls, waits, recovery rules, and evidence sources.

`sign` and `send` always refuse with rc=3. Remote RPC objects allow read methods only. Simulation transactions use impersonation exclusively on A3a's authenticated loopback Anvil. This package contains no signing or public broadcasting implementation.

## Prerequisites

Use Python 3.11.9 and local Foundry 1.7.1 for offline archive rebuilds. The simulation engine must be nightly commit `4e8874b2bdc840929585ca73e170993c50a4a531`. Set `A3A_ENGINE_DIR` to that installation. The executor authenticates its version, `anvil_nodeInfo`, fork identity, process, and listening port through A3a's helpers. It uses `--hardfork amsterdam --order fifo` with a read-only loopback relay. Archive URLs never enter engine arguments or logs.

Keep candidate git objects, recursively initialized submodules, and solc 0.8.33 installed locally. The new executor imports A3a's git-archive builder and runs `forge build --offline --ast --build-info` in a temporary archive of the candidate. ASTs bind immutable names to their compiler ranges. No ignored working-tree `out/` artifact supplies upgrade bytes.

A3a's frozen plan still has its existing artifact prerequisites and independent rebuild checks. Prepare it with `script/a3a/a3a_exec.py` and retain its adjacent `.sha256` file. Its selected timelock must be `0xCCdF8e0D29Fb2c3061910D79484a2b653757C34B`.

A3a's clean-tree policy applies to this executor. The owner must finish reviewing and recording these edits before running plan or simulation. The executor excludes only the requested output directory from its check. It does not commit files or relax that gate. Use a new, empty output directory for every run.

## Rehearse both phases before A3a executes live

A3a has not executed live. A live `plan` must therefore fail its deployment prerequisite today. Use the bootstrap simulation to exercise the full sequence without fabricating a live deployment:

```sh
A3A_ENGINE_DIR=$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b \
  python3 -B \
  script/upgrade/sp_upgrade_exec.py simulate \
  --rpc-file /private/tmp/sepolia-archive-url \
  --a3a-plan /path/to/frozen-a3a/plan.json \
  --out /private/tmp/a6e-bootstrap
```

The executor first imports and calls `a3a_exec.rehearse` on the frozen A3a plan. Its opt-in continuation keeps the same engine and relay alive after all A3a steps and controls pass. It then observes that fork's resulting state, builds the transaction skeleton, calibrates every gas limit, and executes the upgrade phase. The continuation carries A3a's cumulative state overrides into archive estimation. A3a S7 must finish while the EOA owns SP, before this package transfers SP ownership.

Independently verify the generated upgrade plan with a second engine run:

```sh
A3A_ENGINE_DIR=$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b \
  python3 -B \
  script/upgrade/sp_upgrade_exec.py simulate \
  --rpc-file /private/tmp/sepolia-archive-url \
  --a3a-plan /path/to/frozen-a3a/plan.json \
  --plan /private/tmp/a6e-bootstrap/plan.json \
  --out /private/tmp/a6e-independent
```

Both `.sha256` sidecars are checked. The second run replays A3a from its original pin, collects the post-A3a state again, rebuilds the candidate from git archive, and re-derives the entire upgrade plan. A changed field, unknown key, altered calldata, missing pause, salt, predecessor, nonce, runtime, or budget fails before upgrade execution.

The bootstrap plan records both the original fork pin and the post-A3a state block. It binds the frozen A3a plan's SHA-256. It is a rehearsal plan, not a live transaction packet. Do not transplant its nonces to a later live state.

## Create a live read-only plan after A3a executes

Choose the pin explicitly. Use two independent archive RPC files:

```sh
A3A_ENGINE_DIR=$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b \
  python3 -B \
  script/upgrade/sp_upgrade_exec.py plan \
  --rpc-file /private/tmp/sepolia-archive-a \
  --rpc-file-secondary /private/tmp/sepolia-archive-b \
  --block 11974561 \
  --out /private/tmp/a6e-live-plan
```

Replace the example block with the chosen post-A3a block. Historical RAMS block 11974561 predates execution and must fail the A3a prerequisite.

`plan` sends no transactions to either archive endpoint. Both archive views must agree on the complete pinned observation. It then starts an authenticated local fork to calibrate every upgrade step and run the controls before freezing the unsigned plan. Each sender's current pending nonce must equal its pinned nonce. The plan assigns separate deployer, approver, executor, and Safe nonce sequences and reserves the maximum fee budget for every proposed transaction.

The A3a gate requires:

- The shared timelock's fresh runtime, constructor input, exact role history and live memberships, self-admin policy, and 172800-second minimum delay.
- A3a APNTsCapped owner equals the timelock and SP pendingAPNTsToken equals APNTsCapped.
- SP still has the EOA owner, so S7 necessarily precedes ownership transfer.
- Current Safe owners and threshold, no modules, zero guard, and code checks for the Safe, every owner, and the deployer. EOAs must have empty code.
- No outstanding timelock operations, after reconciling complete scheduled, executed, and cancelled log history.

A live plan has no bootstrap hash. The combined `simulate --a3a-plan --plan` interface requires a bootstrap plan because it must replay A3a first on that same fork. A later live plan has a different pin, balances, and nonce timeline and is intentionally rejected by that interface. Keep the successful independent bootstrap evidence with the separately generated live plan; neither authorizes a signature. This distinction prevents treating an A3a deployment that has not happened as live state.

## Sequence and read-backs

The implementation constructor deploys its own SuperPaymasterAdmin extension. There is one top-level implementation CREATE and no separate extension deployment. Both runtimes and their immutable values are verified from the fresh archive build.

The EOA then freezes the complete PAYMASTER_SUPER role configuration, changing only `isActive`. The executor scans holders again after that freeze, reconciles `getRoleUserCount`, and pauses the union with every historical `OperatorConfigured` address. It reads back each pause before transferring SP ownership to the shared timelock.

Each governance action uses one owner's `approveHash` followed by the other owner's `execTransaction`. Approved-hash signatures are sorted by address. On-chain `getTransactionHash`, operation hashes, Safe approvals, nonce changes, receipts, successful execution events, and top-level call traces are checked. The upgrade and gas queue form one timelock batch. The upgrade embeds `setGlobalPaused(true)` atomically.

The gas tuple is `(480000,450000,5000,450000)`. Both queue and activation are owner-only. The executor waits for the internal 48 hours before scheduling activation, then waits the external 48 hours. Activation depends on the completed upgrade operation. No batches run in parallel. The RAMS 96h and 144h figures are model lower bounds to gas activation; this serial package follows the 144h path plus transaction and verification time.

Before every transaction after the freeze, `pre_send` re-reads the Registry owner, the role configuration owner, and the full frozen role configuration. Registration reopening fails the package. It also re-reads Safe state, delegation status, nonces, timelock roles, pending operations, SP ownership, the A3a token pointer, and gas affordability. Operator pauses and the inventory are checked before ownership transfer and governance actions.

The final gate requires correct active gas parameters, an empty gas queue, timelock ownership, unchanged guardian, implementation slot and both runtimes, global pause, every operator pause, frozen registration, both operations Done, and no outstanding operation. It leaves service paused. Restoration belongs to a separate later package.

## Fork controls and failure evidence

The simulation executes these controls without preserving their state changes:

- A pre-freeze `safeMintForRole` success by an existing COMMUNITY sponsor for a qualified recipient, followed by the identical call's exact `RoleNotConfigured(SUPER,false)` revert after the freeze.
- A failed pause read-back that blocks ownership transfer.
- Premature upgrade execution, a non-Safe executor, and premature gas activation, with exact revert checks.
- Safe cancellation of the scheduled upgrade, denied execution of the cancelled operation, and Safe rescheduling with a distinct salt.

Mint controls use a fresh synthetic recipient and real Registry registration. Their explicitly logged fork fixtures fund GToken through its real owner's mint and approve the real staking contract. Roles, pause bits, upgrade calls, and Safe execution are not mocked in the fork simulation. Snapshots restore fixtures, nonces, token balances, supply, stake, and membership. If the current deployment cannot satisfy those controls, the run fails.

Successful governance traces must begin with the planned EOA transaction to the Safe, call the timelock from the Safe, and call SP from the timelock. Upgrade traces must show both pause delegatecalls. EntryPoint calls fail. A4's hypothetical in-bundle upgrade stranded 306 aPNTs in its historical fixture. Empty modules and a zero guard cannot exclude future Safe-authorized AA relaying or concurrent governance changes. Keep every live governance call outside ERC-4337 bundles and exclude concurrent authority changes.

Outputs include `plan.json` and its hash when generated, A3a `simulate.json`, phase-labelled `simulate.log`, `upgrade-simulate.json`, and `combined-simulate.json`. Require both phases PASS and a pre-restore PASS. `FAILURE.json` and rc=1 identify any failed gate. A partial plan or a phase's PASS is insufficient when the combined run fails. Do not blindly retry: inspect actual ownership, nonces, pause bits, and operation state, then regenerate the remaining unsigned plan. Recovery by the timelock retains all governance waits.

## Gas calibration and RR deployment

Regenerate old schema-1 upgrade plans. Schema 2 contains no fixed gas limits. For every step it records `estimateGas`, `localEstimateGas`, and `forkGasUsed`, then uses `ceil(max(those values, minedGasMinimum if present) * 13 / 10)`. Archive estimates include the cumulative fork state overrides and the exact execution timestamp. Sender budgets are calculated after calibration.

CREATE additionally gets a binary search of the minimum gas limit that succeeds as a **mined** transaction. Each trial snapshots state, sends the exact transaction, verifies its receipt and transaction identity, and reverts. The search and pilots never advance package nonces or preserve deployed code. Trial limits, hashes, statuses, and gas used appear in each step's `minedGasSearch` evidence in `simulate.log`.

Only CREATE may exceed 2^24. Its mined minimum must exceed `floor(2^24 * 10 / 13)`, and its first-step trace must prove a nonzero state-gas reservoir. That step records `rrRequired: true` and a bound `rrWitness`. The margin-adjusted limit must remain at most 100,000,000 and at most the block gas limit. Every other step retains the 2^24 cap. An estimate cannot authorize the exception.

The minimum search first requires success at the 100M ceiling. An admission error, failed high trial, unavailable trace, zero reservoir, insufficient funds, or margin above the ceiling stops the package. These failures are not converted into a larger guess. Snapshot pilots require stable gas-used accounting before the limit is frozen. `pre_send` requires the planned gas to cover the recorded minimum; frozen simulation searches again and checks that minimum independently, even when estimates remain low.

The reservoir legitimately pays state gas for a plain EOA-funded deployment. Its `handleOps` bundler-reimbursement concern does not apply to a plain CREATE. See the [design's gas policy](../../docs/release/sp-upgrade-a6e/DESIGN.md#measured-gas-and-create-reservoir-policy) for the RR-matrix provenance and the exact gates. The 4e8874b engine pin and A3a teardown marker are preserved.

## Offline verification

These tests mock RPC and execution; only ABI encoding and keccak use local `cast`. They open no archive connection or listener. Python 3.11.9 with `-B` was used.

| A3A_ENGINE_DIR | Upgrade suite | A3a regression suite |
|---|---:|---:|
| `$HOME/.foundry/bin` | 135 passed | 70 passed |
| `$HOME/Dev/aastar/tools/foundry-rams/nightly-4e8874b` | 135 passed | 70 passed |

Run the suites with:

```sh
A3A_ENGINE_DIR="$HOME/.foundry/bin" \
  python3 -B script/upgrade/test_sp_upgrade_exec.py
A3A_ENGINE_DIR="$HOME/.foundry/bin" \
  python3 -B script/a3a/test_a3a_exec.py
```

Repeat with the nightly directory. `.github/workflows/a3a-executor.yml` includes the upgrade suite under the existing Python 3.11 and Foundry 1.7.1 pins and triggers on upgrade executor changes. No archive-backed plan, simulation, or fresh Solidity build was run during this edit-only delivery.


**Engine pin changed 2026-10-24: nightly 926eb1d → 4e8874b.** 926eb1d does not implement the EIP-8037 reservoir split (frame gas uncapped above 2^24, `stateGasReservoir` always 0); it matched real RR txs only on receipt gasUsed (first-step frame gas + reservoir: 0/10). 4e8874b (foundry #17719) matches 10/10 on status, gasUsed and the first step's frame gas and stateGasReservoir, and 14/14 on the R-AMS R0 probe. Later frames were not compared one by one (DSR acceptance 2026-10-25: first-step calibration, not full-frame). Evidence: `docs/design/aoa-balance-mode/data/rams-rr-matrix/frame-calibration/` (PR cc125/rr-matrix). All A3a steps are ≤ 2^24 (R0), so earlier A3a numbers are unaffected, but a fresh plan must be produced under the new pin.

## Pre-sampling manifest, slice 1 (schema 3)

`manifest_exec.py` builds Phase A and Phase B from `MANIFEST-DESIGN.md`. It imports the existing executor's Safe hashes, ABI helpers, receipt checks, measured gas policy (including CREATE reservoir witnesses), and A3a's authenticated Amsterdam fork/read-only relay. It does not change the schema-2 IG-08 route. `sign` and `send` return 3. No wallet, keystore, environment credential, signing, or public transaction submission code is added.

Every multi-call design row is expanded into individual transactions. Ten top-level CREATEs use the deployer's consecutive nonce counter; the SP extension address uses implementation nonce 1. All four sender counters start at the pin. B4 is last in this Phase A/B slice and always consumes its reserved deployer nonce. Its packet includes exactly two complete transaction variants: the apply call and a zero-value, empty-data deployer self-transfer with identical nonce and fees. Calibration measures the self-transfer's intrinsic gas on the Amsterdam fork and freezes that exact limit; replay verifies it again. Both payloads and limits are covered by the packet hash, and budgeting uses the more expensive variant. The packet discloses the possible gas-only placeholder (§9).

Immediately before B4, the executor reads the active verifier and chooses apply unless it is already A12a. Every branch requires A12a active, pending verifier zero, and readyAt zero afterwards. Only the apply variant may pass with mined status 0, and only with that complete post-state; its receipt is logged before the post-state check. The placeholder still requires status 1. Reverted-snapshot controls exercise preapplication, a front-run after selection, and a wrong verifier, including a follow-on deployer transaction to check nonce continuity. Phase D now follows B4 as described below. Foreign nonce changes stop rehearsal; this slice has no nonce-gap amendment command.

`plan` is an offline **draft** builder. It accepts a previously collected pin JSON and the mandatory external-input file. It writes `manifest-draft.json`, without invented gas limits or a release-packet hash:

```sh
python3 -B script/upgrade/manifest_exec.py plan \
  --pin /path/to/post-s7-pin.json --inputs /path/to/manifest-inputs.json \
  --out /private/tmp/manifest-draft
```

`simulate` collects and cross-checks the actual post-S7 pin using two read-only archive endpoints, derives the plan, and calibrates/rehearses every transaction on the authenticated local fork. Pass `--plan` to independently replay an already calibrated plan and its SHA-256 sidecar. A3a must already be deployed at this pin; combined pre-S7 bootstrap is not exposed by this module.

```sh
A3A_ENGINE_DIR=/path/to/nightly-4e8874b \
python3 -B script/upgrade/manifest_exec.py simulate \
  --rpc-file /path/to/archive-a-url --rpc-file-secondary /path/to/archive-b-url \
  --block 0xPOST_S7_BLOCK --inputs /path/to/manifest-inputs.json \
  --out /private/tmp/manifest-rehearsal
```

The existing clean-tree fork gate is preserved. This delivery remains uncommitted at the user's instruction, so that gate currently prevents a real fork run. No permission bypass or implicit commit is provided.

### Mandatory external-input JSON

The entire file's SHA-256 and parsed content enter the plan. This is a public-data file, never an `.env` or key file. Unknown/missing PoPs and verifier artifacts cannot produce a partial plan. The unit tests' `input_data()` supplies deliberately synthetic fixtures, unsuitable for a fork.

Required fields:

- `anni`, `dvt`, `committee`: full lowercase addresses. DVT must be `0x568b1486bfe036e603ea11f0d03dc47fa62c9e0e`, committee `0x7ac7e9d471742fa4397beef0b5b11fbd22d196a9`, and the chain's old aggregator `0xeaec2f512ea50708211fa95533e4dbb60e3d2e5d`. Ownership, pointers and runtimes are pinned; `bindings` must contain exactly the DVT and committee keys with nonempty code. Anni must be exactly `0xecaacb915f7d92e9916f449f7ad42bd0408733c9` and an undelegated EOA.
- `sampled`: nonempty sorted unique list of configured/inventoried operator addresses. Only these are unpaused by B3.
- `depositTargetWei`: positive integer target EntryPoint deposit. Stake targets at least 1 ETH and at least 86400 seconds; stake and deposit values enter sender budgets.
- `releaseTag`: existing local tag resolving to HEAD. `registryBaselineCommit`: locally available 5.8.0 baseline used for recursive storage-layout comparison (32 variables, owner at slot zero). It must differ from HEAD. Collection reads the Registry proxy's ERC-1967 implementation and code at the pin; the baseline rebuild must reproduce that runtime, substituting its implementation address into `__self`. The builder also runs this check.
- `releaseEvidence`: `{path, sha256}` file references named `conformance`, `mutation`, `slither`, `reproducible-build`, `dvt-ci`, `dvt-conformance-4.12`, plus the nonempty `sourceVerificationPlan`. Evidence JSON must match [the per-kind schema](release-evidence.schema.json): `kind`, `subjectCommit`, `tool: {name, version}`, `counts: {passed, failed, skipped}`, and `result`. Passed must be positive, failed zero, skipped zero, result `PASS`. SP evidence subject commits must equal the frozen tagged build commit. Both DVT kinds additionally require `spCommit` equal to that commit and `aggregatorVersion: "BLSAggregator-4.12.0"`; their subject commit is the pinned DVT verifier commit. The compiled version literal and A7 version read-back must match. A dirty tracked or untracked tree is refused. Every file must match its nonzero SHA-256. Bare digest attestations are refused. These bind supplied release-evidence attestations; this executor does not rerun the release-analysis tools.
- For `dvt-ci`, `result: PASS` and the counts cover only the 23 required suite results. Required `ciRun` records `runId` (positive integer), `headSha` (40 lowercase hex characters), `overall` (`failure` or `success`), and a nonempty name-keyed `jobs` object, for example `{"Security Audit":"failure","CI Success":"failure","Build":"success"}`. Names are exact and case-sensitive; duplicate JSON keys STOP at parsing, before schema validation can lose them. The old array format is rejected. Conclusions are only `success`, `skipped`, or `failure`; every other value STOPs, including on exempt names. Only `Security Audit` and derived `CI Success` may have conclusion `failure`. Required `acceptedFailures` is a closed list of at most one `{name: "Security Audit", reference: "<DSR acceptance reference>"}` entry, under DSR's 2026-11-02 ruling 1 (npm). References and job names use the same schema/executor single-line pattern `^\S(?:[^\r\n]*\S)?$(?![\s\S])`: nonblank, no surrounding whitespace, no CR/LF, including a trailing newline. Overall `success` forbids failures; overall `failure` requires a failed Security Audit with an acceptance. These structural and conditional rules are encoded in the schema and read by the executor.
- Executor cross-field checks additionally bind `ciRun.headSha == subjectCommit` and enforce the derived `CI Success` rule: its failure requires at least one other failing job, with every other failing job accepted. Acceptance membership and overall/failure consistency are also checked explicitly in the executor, in addition to schema conditions. Duplicate raw JSON keys are a parser-only check because JSON Schema sees already-parsed objects. Run 41262513958 can report overall `failure` with `Security Audit` and derived `CI Success` failing while the required suites report `PASS`. This validates supplied metadata offline; it does not establish job inventory completeness or authenticate job names against the CI service. Mutation evidence is recorded in [DVT-CI-MUTANTS.json](DVT-CI-MUTANTS.json).
- `verifier`: exactly `commit`, `artifactPath`, `buildSha256`, `ciPath`, `ciSha256`. The public artifact file, not caller-supplied initcode or ranges, is mandatory. Its SHA-256 and `buildSha256` must be `4d7e0125094c381a0dca5e2d8dd56efa79b284e43119fd64130dfaa78d33e7d6`; commit must be `72aca4fa0ba4aaa8c8a96210b1124534431294d6`; creation keccak without arguments must be `0x736520628b9e5ed4163f440e4e7b5d064b4e4cb4571c29d926941964e038e3ab`. `ciPath` is a public JSON record whose bytes match `ciSha256`, with the `dvt-ci` evidence schema above, including DVT and SP commit bindings. This binds a supplied CI attestation; it does not rerun DVT CI. Zero hashes are refused. The pinned artifact must have immutable IDs 5519 (three ranges) and 5522 (two), all 32 bytes wide. AST names resolve the mapping when present; otherwise runtime matching plus both mandatory getters disambiguates the two permutations. No other runtime bytes may differ. Read-back requires `AGGREGATOR()==A7` and `REGISTRY()==A7.REGISTRY()==Registry`.
- `a3aPlan`: `path` and reviewed `sha256` of the amended A3a plan, `receipts` mapping every step `S1`, `S2`, `S3`, `S4`, `S5a`, `S5b`, `S6a`, `S6b`, `S7` to transaction hashes, and optional `nonceGaps` in A3a format. Collection verifies successful mined receipts, canonical blocks at/before the pin, and exact planned transaction identity. D's pinned nonce must equal S7+1. A/E must equal their last planned nonce+1, or every intermediate nonce must pass `a3a_exec.check_gaps` (plain transfer, receipt, codeless recipient and prestate trace). Every embedded amended-plan `nonceGaps` entry is also re-proven with `a3a_exec.check_gaps`. Collected `a3aHistory` includes every receipt and transaction; `a3aGapReads` contains replayable gap RPC evidence; the offline builder revalidates it. No gap is allowed after D's S7.
- `pop`: exactly three objects containing `validator`, `slot`, `calldata`, `aggregator`, `pinBlockHash`, `domainSeparator`. Calldata must be the complete owner-path `registerBLSPublicKey(address,(bytes32,bytes32,bytes32,bytes32),uint8,(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32))` call. Validators and slots must be distinct and equal exactly the nonempty inventory collected from the OLD aggregator’s `validatorAtSlot(1..MAX_VALIDATORS)` at the pin (all 13 slots are retained). The 2026-11-01 reference inventory is slot 1 `0x5d870e132cc010e882e90f4afaacdc4f19c7eca3`, slot 2 `0x40f0b12128f256b62fa22b36d37012ee004bbd1f`, slot 3 `0xd904a706e355d6b48baedbec472ce94bc6981601`; slots 4–13 empty. The authenticated pin, rather than this dated reference, determines equality. The builder validates selector, fixed-width encoding, validator, slot, derived A7 address, and pin hash. The real fork validates the cryptographic PoPs and reads back public keys/slots.

- `fraudProofFixture`: required `{path, sha256}` reference to a reviewed JSON wrapper matching [the fixture schema](fraud-proof-fixture.schema.json): `{ "toolCommit": "<40 lowercase hex>", "verifierCommit": "72aca4fa0ba4aaa8c8a96210b1124534431294d6", "export": <unchanged DVT output> }`. The SHA-256 covers the entire wrapper, including both required commits. `toolCommit` records the export tool revision independently of the pinned verifier source revision.
- `export` uses DVT's fields: `purpose`, `chainId`, `aggregator`, `version`, `owner`, `verifier`, `registry`, `domainSeparator`, `block`, `forkState`, `valid`, and `mustReject`. Checksummed addresses are validated then normalized. Decimal-string IDs and epoch and the hex-string signer mask are decoded with uint256 bounds. The production path requires chain 11155111, `BLSAggregator-4.12.0`, Registry, A7/A12a derived from planned nonces, the pinned block number, and exactly the pinned guardians in ascending address order. The authenticated pin retains its block hash; DVT supplies only a block number. Domain and verifier-derived IDs/message hashes are checked on the fork. `owner` is descriptive export metadata, not execution authority.
- `forkState.token` contains `address`, `runtimeBytecode`, and `overIssuedStorageSlot: 0`. Runtime full keccak must be `0xae01c0c01f84a229b8c6f3591a70f678ea5d48ff956a90661ae669bf1be6d0db`; CBOR-stripped keccak must be `0xb4dcef54c1bf03ed09b0c6dcd6b78699d4801a3e6baf044ddd531c72acb74a86`. Both immutable owner words at byte offsets 130 and 210 must be zero. `isOverIssued()` is pinned to selector `0xbeaf15d9`.
- `forkState.commitment` contains `mapping: "proposalSignersCommitment"`, decimal `key` equal to `valid.proposalId`, `value`, and DVT's exact `check` instruction. Caller-supplied slots are refused. The executor independently runs `forge inspect BLSAggregator storage-layout --offline --json` against the committed build in a temporary tree, checks compiled-layout parity, and derives `keccak256(abi.encode(proposalId, mappingSlot))`. It reconstructs the slash message hash from the proof metadata and DVT evidence convention to check the commitment value, and reads the written value back through `proposalSignersCommitment(proposalId)`.
- `valid` preserves DVT's call/expect strings, proposal/fraud IDs, guardians, proof, domain digest, signer mask, operator, slash level, and epoch. `mustReject` is the four-element N1–N4 array, preserving each `id`, `change`, `expect`, and case-specific fields. N1 removes one guardian with unchanged proof; N2 sets token slot 0 to 1 with unchanged proof and guardians; N3 flips exactly one signer-mask bit in the proof; N4 flips one canonical digest bit and calls the verifier directly. All other case data must match the valid case.

`fraud_format_only(export)` parses the raw historical wire format without requiring a production version or provenance wrapper. It is a test helper and is never called by the build/rehearsal path. The checked-in 4.11 sample passes this helper and is refused by production validation. Synthetic 4.12 fixtures derived from it exercise the schema and bindings; they do not establish live-fork validity.

After B4, the drill checks A7 and A12a runtime hashes against the packet, active verifier, domain, `deriveFraudProofId(pid)`, and `slashMessageHash(...)`. It takes its own snapshot before installing T's runtime and writing T.over at slot 0 and A7's computed commitment slot. It reads the commitment back through `proposalSignersCommitment(pid)`. Each case takes another snapshot and restores it, so every case starts from identical setup state. Valid must succeed, freeze the expected case and emit the full `GuardianSlashQueued` event. N1–N3 must return exactly `InvalidFraudProof(uint256)` with the expected id. **N3 has no distinct commitment error:** the pinned verifier's `_commitmentMatches` failure returns false; A7 raises `InvalidFraudProof`. N4 calls `verifier.verify` directly and asserts false.

The outer snapshot is reverted in `finally`. The executor then re-reads the main-path commitment (zero) and T's code (empty) to prove restoration. `manifest-fraud-proof.json` records the outer and per-case snapshot ids, code/runtime hashes, every written slot/value, receipts, selectors, both commits and before/after read-backs. Main-path accounting is collected before the drill. Rerun the drill if either contract changes with the release tag.

The fixture's SHA-256 authenticates the reviewed input bytes; its declared tool revision and mock runtime provenance still require DVT review. The real 4.11 export establishes format compatibility; cryptographic acceptance for A7/A12a still requires a fresh 4.12 export and authenticated fork run. Synthetic tests verify the schema and orchestration, not cryptography. The drill bypasses `_checkSignatures` and does not prove `verifyAndExecute` writes the same commitment; that remains covered by DVT/SP source-level parity and precompile tests per spec §7.

The public pin can be collected with `manifest_exec.collect(read_only_rpc, block, external_inputs)` after S7. It includes the original executor's full pin plus Anni nonce/balance, exact operator balances, revenue, tracked total, EntryPoint stake/deposit, old-aggregator activity, and DVT/committee runtime bindings. The draft builder checks the balance sum and rejects nonzero balances belonging to unhandled senders.

### Timing, controls, and buffer backing

B1 contains upgrade-with-atomic-pause, gas queue, factory binding, and aggregator queue. B3 contains gas activation, aggregator application, token swap, sampled operator unpauses, and finally global unpause. Its predecessor is B1. Scheduling waits until both the internal gas ETA and `pendingAPNTsTokenEta - 172800`; the scheduled ETA is independently checked against the swap ETA.

B2a follows the successful 5b read-back: A approves and E executes `APNTsCapped.mint(SP, 0.1e18)` through the Safe. Safe nonces and hashes are fixed in order 5a, 5b, B2a, 6c, 6d. A failed mint or wrong balance stops before 6c.

B2 requires `APNTsCapped.balanceOf(SP) == 0.1e18` exactly (excess is also refused), independently of old-token accounting. It re-reads accounting, every inventoried operator, pending slash flags, and continuous global pause since the first 5.5 upgrade. There is no enumerable in-flight getter. Its no-reservation proof relies on 5.4.2 having no reservation map, B1's atomic pause, no subsequent unpause event, and no intervening implementation change. This is a release-version-specific proof, not a generic “current pause means no in-flight work” assumption.

Controls cover premature/unprivileged unpause, factory binding, premature BLS/swap/verifier application, a paused-state deposit blocking the swap, retired reputation submission, non-owner Registry upgrade, repeated verifier application, and B4's calibration no-send path. A snapshot control executes the actual activation timelock operation without B2a: it records the 0.1-token shortfall and the `B2_capped_buffer` refusal, then restores state. Omitting B2a also fails deterministic plan validation.

The solvency probe records the immediate post-6d balance, checks it is unchanged by B4, then deposits one token on a snapshot. It queues a slash, waits a day and slashes 0.1 token from that deposit into revenue. Only then does it withdraw the 0.1 excess above the retained buffer. It records equality or the missing-backing difference at all three stages in `manifest-solvency.json`, restores the snapshot, and refuses insolvency. `contracts/test/upgrade/ManifestSolvency.t.sol` tests real proxy/token/slash/withdrawal code, including the original `InsufficientRevenue` revert and the no-B2a deficit.

The old-token 0.1 remains stranded in SP with no rescue path. After B2a but before 6d, the new token is held but untracked; if the route is abandoned it remains untracked. These are explicit §6/§9 recovery and decision-card facts.

Not implemented: Phase C, live sending/signing, a manifest nonce-gap amendment command, or combined A3a bootstrap. The reverted solvency fixtures are controls, not Phase C transactions. The full release still requires an authenticated fork and release evidence; local unit tests do not authorize broadcasting.

Offline tests:

```sh
A3A_ENGINE_DIR="$HOME/.foundry/bin" python3 -B script/upgrade/test_manifest_exec.py
```

See the [round-4 report](MANIFEST-ROUND4-REPORT.md) for current results and limits, and the [historical slice-1 report](MANIFEST-SLICE1-REPORT.md) for interface assumptions.


### Round 6 release checks

A3a history first checks the reviewed SHA-256, then calls its frozen plan validator in historical mode. That mode rebuilds from the plan's own recorded commit, using isolated archived sources, and compares the entire rebuild record as well as all derived fields. No rebuild-record exception is enabled: unavailable historical sources, dependencies or compiler stop collection. Every nonce from each A3a sender's original pin up to (excluding) its manifest nonce must occur exactly once as a prescribed mined step or a gap proven by `check_gaps`. Gap transactions must be mined by the manifest pin. Collection also checks canonical receipt blocks.

Evidence now requires C1–C9 individually PASS; both DVT records require the 7-test cross-repo suite, the 11-test genuine Prague suite with `FOUNDRY_EVM_VERSION=prague` and zero skips, and 5-test provenance. Mutation controls name their red test, mutated FAIL and restored PASS: the four manifest controls (`remove_B2`, both verifier getters, bound runtimes) and the three guardian-set mutations specified in §2. Slither records its version, severity threshold, findings above that threshold, and an explicit reason for every accepted finding. Missing suites or controls fail even with positive aggregate counts. The JSON schema lists exact field names.

Every SP deployed contract (including the constructor-created admin extension) records `creationHashes.fullCreationKeccak` and `strippedCreationKeccak` from the executor's archive rebuild. The verifier is separately rebuilt offline from DVT `72aca4fa` in an isolated archive using Forge 1.7.1 / solc 0.8.33; its bytes must match the pinned artifact. `reproducible-build.contracts` must contain both hashes for all eleven contracts. Executable differences fail; metadata-only differences are explicitly recorded in `rebuild.metadataOnlyDifferences`. `rebuild.verifierCreationHashes` records the verifier pair. Hashes exclude constructor arguments.

The mock runtime pin is `0xae01c0c01f84a229b8c6f3591a70f678ea5d48ff956a90661ae669bf1be6d0db`, independently derived from that same DVT archive and compiler configuration. It is the raw runtime with immutable `owner` set to zero; fixture exporters must supply those exact bytes. The drill uses snapshot-scoped storage writes, not its owner setter. It requires `isOverIssued()==false` before N2 and `true` after changing slot zero, before submitting N2. A reverting implementation fails this read-back. No placeholder remains.

B2 is an off-chain observation. Extra tokens sent to SP before 6d only increase backing, which is harmless; under the packet's paused state and enforced controls, nothing can decrease it. This observation is therefore acceptable; the packet still enforces B2's backing check.


### Phase D ownership controls and validation limits

Post-Phase-D controls include SP: `setProtocolFee` with the current value must reject D and a directly impersonated Safe with the exact `OwnableUnauthorizedAccount(address)` payload, and succeed from the impersonated timelock. Both A7 and the old `0xEaeC…` aggregator are checked with current-value `setSlashThreshold` and `setGuardianSlashBps` calls: D must revert with the exact `NotSlashPolicyAdmin(D)` payload and the impersonated Safe must succeed. Each setter probe has its own snapshot, success read-back, and restoration.

Phase D unit tests cover sequence construction and dependency gates only. They do not establish compatibility of the pinned bytecode. Compatibility—including single-step committee ownership transfer and exact error selectors/payloads—is established only by the fork rehearsal on the real pin. No such fork rehearsal was run in this fix round.

### Staged manifest format revision

No packet has been released. This revision deliberately changes the default
complete-input format: PoPs require `domainSeparator`, and plans add stage/source,
final-status, domain, prefix, and per-step timing fields. Old input and plan bytes
are not compatible and must be regenerated. The stricter schema retains the DVT
PoP export domain for independent fork read-back binding; it is not optional.
DVT's `deploy/reregister-guardians.mjs --export-pop` supplies top-level
`domainSeparator` and per-registration G1/G2 word arrays and `calldata`.
`pop_adapter.py` consumes this format; an export without calldata is rejected.

Set `MANIFEST_DVT_REPO` to a local clone of DVT (YetAnotherAA-Validator) that contains the pinned verifier commit; the verifier rebuild refuses to run without it.

### Staged manifest forks for DVT exports

Use one pin, release build, constructor inputs and sender nonce inventory throughout.
`manifest_exec.py plan` and `simulate` accept `--stage a7|b4|full` (default:
`full`). Full still requires three PoPs and the reviewed fraud fixture. Each PoP
entry now also carries the export's `domainSeparator`; it must match the computed
A7 domain and the supplied stage read-back. Offline builders compare supplied
read-backs to computed expectations; the actual fork read and check happen in
stage `simulate`. All stages retain the release gates.

1. Pin the state. Build with `plan --stage a7 --pin PIN --inputs INPUTS --out A7-DRAFT`.
   PoPs and `fraudProofFixture` may be absent. Simulate with `--stage a7`, the same
   inputs, `--block PIN_BLOCK`, both `--rpc-file` and `--rpc-file-secondary`, and
   `--out A7-RUN --hold-fork`. Execution stops immediately after A7, prints its
   address and the local RPC, and writes `stage-source.json`. Leave it waiting
   while DVT reads domainSeparator/popDigest and dry-runs owner registration.
2. Convert DVT's PoP export using the same pin and A7 source:

   ```bash
   PYTHONPATH=script/upgrade:script/a3a A3A_ENGINE_DIR=$HOME/.foundry/bin \
     python3 script/upgrade/pop_adapter.py --export DVT-POP.json --pin PIN \
       --a7-source A7-RUN/stage-source.json --tool-commit DVT_EXPORTER_COMMIT \
       --out POP-INPUT.json
   ```

   `DVT_EXPORTER_COMMIT` is the exporter tool's 40-character lowercase commit.
   Copy only `POP-INPUT.json`'s `pop` array into the manifest inputs' `pop` field;
   archive the wrapper with `exportSha256` (original export file bytes),
   `exportBlock`, and `toolCommit` alongside the export. These fields are outside the
   executor's exact six-field PoP objects. The callable API is
   `pop_adapter.adapt(export_path, pin=pin, stage_source=source, tool_commit=commit)`.
   The adapter requires Sepolia, version 4.12.0, the source plan's A7 address,
   deployer D as owner, and the supplied A7 domain read-back. It re-encodes each
   registration from the export's own fields with the executor's cast ABI encoder
   and requires exact calldata bytes, including selector `0xaded17c5` and 14 words. Slots 1–3 must match both the
   release guardian constants and the pin's complete 13-slot inventory. Every
   output `pinBlockHash` comes from `PIN`; the export's block is not a pin hash.
   The nonnegative integer export block is
   recorded as `exportBlock` and must be at least `plan.pin.block` when present
   in the A7 source (an integer or hexadecimal RPC quantity).
   Validation is offline format/binding validation, not PoP pairing verification
   or authentication of supplied fork evidence. The adapter checks the declared
   chain, owner and domain; it does not prove that a signature was made for them.
   `popDigest` is checked for format only. Relabeling an export cannot substitute
   for successful registration during stage simulation. Cast re-encoding proves only
   consistency of calldata with the export's own fields,
   not authenticity of the key or signature. That validation belongs to stage
   simulate and A10 read-back. Duplicate JSON keys at any depth and excessive
   nesting exit with `STOP`. Output uses a temporary file in the same directory
   and atomic replacement; failures preserve the previous output and remove
   the temporary file (an interrupt in the instant after `mkstemp` returns can
   leave a dot-prefixed temporary behind; the previous output is still intact).
   The output is created by `mkstemp`, so it has mode 0600, and a symlinked
   `--out` is replaced by a regular file rather than written through. JSON
   inputs deeper than 64 levels are refused before decoding (the interpreter's
   own recursion limit differs between Python 3.11 and 3.12).
   Inputs must be strict UTF-8 without a BOM; a BOM, UTF-16 or UTF-32 input
   is refused (STOP), unlike plain `json.loads(bytes)`, which would accept it.

   Preserve guardian addresses and slots exactly.
   Build/simulate `--stage b4 --a7-source A7-RUN/stage-source.json` from the same
   pin. The fixture may still be absent. Use `--dump-state B4-STATE.json
   --hold-fork` on simulate. This executes through B4, including time warps,
   verifies the applied verifier and cleared pending rotation, and stops before
   handover or the fraud drill. The dump file contains the JSON string returned
   by `anvil_dumpState`; pass that decoded string to `anvil_loadState`.
3. Load that state into a **separate** local Anvil instance for DVT's destructive
   drill-run (`setCode`/`setStorageAt`). Keep the pre-drill B4 instance pristine.
   Export the drill read-only from the pre-drill instance. Wrap and hash the
   export with toolCommit `9f4bc99890c4595ddc046961e0c535ca693b1c42` and verifierCommit
   `72aca4fa0ba4aaa8c8a96210b1124534431294d6`.
4. Add the fixture reference and build/simulate `--stage full` from the original
   pin, supplying **both** `--a7-source A7-RUN/stage-source.json` and
   `--b4-source B4-RUN/stage-source.json`. The full builder compares exact prefixes
   (pin, addresses, transaction nonces, calldata, execution timestamps, warp targets,
   activation threshold, ETA delays and read-backs), verifies prefix
   digests, compares supplied domain read-backs to computed expectations, and
   rejects drift. It does not independently verify that those supplied read-backs
   came from a fork; the real fork domain check occurs in stage `simulate`. It retains the B4 input
   hash for B-phase operation salts so adding the fixture cannot change them.
   Standalone full builds with complete inputs retain their existing salt behavior.

Stage sources embed the deterministic source plan and fork domain read-back; archive them with the
inputs and simulation evidence. Each source is independently rebuilt from the same pin and its stage inputs;
canonical source plan bytes must match before read-back evidence is accepted.
Source plans contain derived timing and no gas calibration fields, so the entire
source plan must match byte for byte in canonical JSON. Gas measurements remain
in the separate stage simulation artifact. Prefix digests bind the activation
threshold and every step, including ETA delays and warp targets.
Stage simulations write `stage-a7.json` or `stage-b4.json`, with `stage` set to
`a7` or `b4` and `final: false`; they never emit `plan.json` or its hash sidecar.
Each stage artifact has its own integrity sidecar (`stage-a7.json.sha256` or
`stage-b4.json.sha256`). Replay it with `simulate --stage a7` (or `b4`) and
`--plan <stage artifact>` plus the same inputs and RPC arguments. The loader
verifies the sidecar without granting release eligibility. Saved stage drafts
are calibrated on replay; calibrated stage artifacts are replayed frozen.
Signing/sending and final packet writers reject stage content even after renaming. `--hold-fork` waits for Enter after
printing the RPC; Enter terminates that fork. Without it the fork closes after
writing evidence (and any requested dump). Stages are rehearsal artifacts, not
release authorization. Full rehearsal still runs the isolated fraud controls.

### Generate SP release evidence locally

`release_evidence.py` produces only `conformance`, `mutation`, `slither`, and
`reproducible-build`. It never creates DVT attestations. It performs read-only Git
queries and uses `a3a_exec.archive_commit` (including locally available pinned
submodules); it never checks out, commits, tags, fetches, or downloads tools.
The source worktree must be clean, including untracked files and submodules, and
`--commit` must resolve to a commit with an existing local tag. Output must be a
new or empty directory **outside** the repository. Missing local dependencies,
compilers, tools, failed tests, and skipped tests stop that kind without its PASS
JSON. Full runs are opt-in and may be long.

```sh
# Replace RELEASE_TAG with the existing local release tag.
python3 -B script/upgrade/release_evidence.py all \
  --commit RELEASE_TAG --out /tmp/sp-release-evidence-RELEASE_TAG

# Run one kind independently, using a fresh output directory each time.
python3 -B script/upgrade/release_evidence.py mutation \
  --commit RELEASE_TAG --out /tmp/sp-mutations-RELEASE_TAG
python3 -B script/upgrade/release_evidence.py slither \
  --commit RELEASE_TAG --out /tmp/sp-slither-RELEASE_TAG \
  --threshold Medium --accepted-findings /absolute/path/to/reviewed-findings.json
python3 -B script/upgrade/release_evidence.py reproducible-build \
  --commit RELEASE_TAG --out /tmp/sp-build-RELEASE_TAG
```

Conformance reads the reviewed C1–C9 mapping from
`script/evidence/a4-conformance-record.template.json` in the clean archive of
`--commit`. It runs each item's exact named Python test and every positive and
negative control, requiring one successful test per invocation and zero skips.
Negative controls are tests that successfully reject bad inputs; failing tests
never produce PASS evidence. Missing or ambiguous tests and import errors stop
generation. Template counts and result labels are ignored. Counts reflect actual
test invocations (shared controls may run more than once). Output uses scope
`checker-logic-offline` and per-item suite/test/control references and derived
results. This is checker-logic evidence, not live release-state or DVT evidence.
No external `--suite-map` is needed.

Mutation evidence runs each named manifest Python test and each vendored verifier
set-binding control baseline → mutated → restored. The guardian controls run in
both Cancun and Prague. `redTest` uses the schema's `VerifierAcceptsGuardianSubset`
and `VerifierAcceptsGuardianSuperset` error names; the audit commands identify the
actual `test_*PassesAssertSetBound` functions. Compiler errors, import errors,
missing tests, and unexpected failure reasons do not count as killed mutants.

Slither uses a fresh offline Forge build, records the full detector report, and
requires explicit acceptance of every finding **at or above** the selected
threshold (default `Medium`). A dedicated config enables all detector severities
and removes detector/path exclusions; `slither.audit.json` records this effective
selection and the completed detector count. Scratch config/report files live in a
temporary directory outside the release tree and are removed after analysis. A successful JSON report and a
matching completed-analysis summary are required, including for Slither 0.11.5
clean reports whose `results` object is empty. `--accepted-findings` is a JSON array of
`{"id": "<Slither detector id>", "reason": "<review rationale>"}`; the default is
`[]`. Unexpected and stale acceptances both stop generation. The `passed` count
for Slither is one completed, reviewed analysis, not an invented test count.
Review detector IDs in `slither.audit.json` after a refusal, then rerun with a new
output directory. Tool environments omit inherited wallet/RPC credentials and
build overrides, including `VIRTUAL_ENV`.

Reproducible build calls the executor's `compile_commit`, `rebuild_dvt`,
`creation_hashes`, and `compare_build_evidence` paths. It independently rebuilds
the ten SP contracts plus the pinned DVT verifier twice, with Forge 1.7.1 and
locally installed compilers/dependencies. The pinned verifier and mock runtime
hash checks remain enforced. Executable differences stop generation; metadata-only
differences and `verifierCreationHashes` go in the audit's `rebuild` object because
the evidence schema forbids those extra fields. The PASS count is eleven compared
contracts, and constructor arguments are excluded from creation hashes.

Each successful kind writes `<kind>.json`, accepted by `manifest_exec.evidence_file`.
`<kind>.audit.json` contains tool versions, command lines, sanitized EVM/profile
overrides, exit codes, elapsed seconds, stdout/stderr, and parsed Forge counts.
Failed kinds retain STOP audits but no evidence JSON. `archive.audit.json` records
archive commands; `SHA256SUMS` is written only after every requested kind passes
and covers every generated JSON, including audits. Command capture temporarily
patches `subprocess.run` globally and supports sequential execution only.
Completed kinds in an interrupted `all` run remain individually valid; no overall
PASS is emitted. Supply each evidence file's path and SHA-256 to `releaseEvidence`.

Generator tests require `pip install jsonschema==4.23.0` and run
no Forge suites or Git commands:

```sh
python3 -B script/upgrade/test_release_evidence.py
```

