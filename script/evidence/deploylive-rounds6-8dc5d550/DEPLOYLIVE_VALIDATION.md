# DeployLive round-six implementation and validation

Worktree rc8-dl; baseline HEAD bfb9cc45. No contracts/src changes, network/RPC/fork
access, keystore/environment-file access, formatter or git writes were performed.
All compiler invocations used /Users/jason/.foundry/bin/forge with --offline.
Long commands were prefixed with nice -n 10; the sandbox printed
`nice: setpriority: Operation not permitted`, but executed the commands successfully.
No Anvil process was started. The production path ran in forge's local EVM with
mock chain IDs and mocked infrastructure/BLS verification boundaries.

## Implemented behavior

- Five Safe-owned authority slots, explicit production owner choices and recipient,
  forbidden production GOVERNOR_ADDRESS, exact handover assertions and config fields.
- GToken mint/stake/ticket/remainder ledger, zero deployer balance and allowance,
  exact recipient delta, mint-event checker and rejected post-handover deployer mint.
- Actual encoded fixed handover list: 21 calls; derived TL-to-H distance **22**.
  Observed nonce is captured immediately before CREATE and asserted equal.
- All 25 creation pins checked before broadcast. The isolated clean build succeeded;
  its pins exactly equal those used by the production-path fixture. Pin file:
  `deployments/creation-pins.rehearsal.json`; SHA256
  `dd8694eb6806ec70013ee1bf0b6ede386de8f9cc9b55b0907b2ecfebba15532f`.
  The full contract list is in DEPLOYLIVE_HANDOFF.md and DeployLivePins.sol.
- Artifact comparison, numeric-string validation, required N/A rows, implementation
  owner readbacks, corrected subject-array size, and updated ceremony/disclosures.
- Happy/failure/governance rehearsal paths, verbosity guard, final evidence scan,
  failed-set inventory and ABANDONED records. Fork paths have mocked unit coverage;
  they were not executed against a fork.

## Mechanical local production evidence

`DeployLiveProductionTest.test_ProductionPathN3` executes the real DeployLive.run
production path. It records the broadcast execution through forge state-diff
recording, filters the deployer's CREATE/CALL records, and walks all records before H.
**96 transactions, every value zero; observed TL-to-H distance 22.** This is a local
execution record, not a network broadcast/run-latest.json or a mined receipt.

Two mints to the deployer: **2000 + 199 = 2199 GToken**. Genesis locks 50;
each of three guardians locks 30; COMMUNITY locks zero. Tickets are 30 for bootstrap,
30 for genesis COMMUNITY, 5 for genesis PAYMASTER_SUPER, and 3 for each guardian:
74 total, all paid to the deployer as the then-current treasury. They return to the
payer. Deployer balance before transfer: **2059**; designated recipient delta: **2059**;
deployer final balance and staking allowance: **0**. The test also checks that a
subsequent mint from the deployer reverts with OwnableUnauthorizedAccount.

The same fixture then executes the stopped production path on chain 31337,
corrupts Registry pendingOwner with a storage write, confirms no nonce consumption,
and attempts H CREATE from the deployer at the predicted nonce. CREATE reverts,
H has no code, H retains TL P/E/C and Safe/deployer do not. Genesis and all three
DVT registrations remain. It reads all **27 contract addresses**: every ETH balance
and every balance of the preceding fixture's GToken/APNTsCapped is zero. The failed
set's staking holds **140 of its own GToken**; its other contract GToken balances
and all its contract APNTsCapped balances are zero. These are actual local EVM reads.

Evidence files in evidence/round6: config.success.json, config.abandoned.json,
production-transactions.json, production-pins.json and the full command logs.
The config files are synthetic test records and must never be published as deployments.

## Verbatim green output

`nice -n 10 /Users/jason/.foundry/bin/forge build --offline` (exit 0):

```text
Compiling 1 files with Solc 0.8.33
Solc 0.8.33 finished in 11.71s
Compiler run successful with warnings:
```

`nice -n 10 /Users/jason/.foundry/bin/forge test --offline --match-path 'contracts/test/scripts/DeployLive*.t.sol'` (exit 0):

```text
Suite result: ok. 7 passed; 0 failed; 0 skipped; finished in 7.73ms (8.00ms CPU time)
Suite result: ok. 28 passed; 0 failed; 0 skipped; finished in 26.70ms (83.29ms CPU time)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 27.04ms (73.44ms CPU time)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 614.16ms (614.00ms CPU time)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 2.58s (2.58s CPU time)
Ran 5 test suites in 2.59s (3.26s CPU time): 42 tests passed, 0 failed, 0 skipped (42 total tests)
```

`python3 -m unittest discover -s script/rehearsal -p 'test_deploylive*.py'` (exit 0):

```text
...........................
----------------------------------------------------------------------
Ran 27 tests in 0.779s

OK
SUMMARY 157 passed, 0 failed, 157 total
```

`python3 -m unittest discover -s script/rehearsal -p 'test_creation_pins.py'` (exit 0):

```text
.
----------------------------------------------------------------------
Ran 1 test in 0.005s

OK
```

The 27-test discovery includes the artifact-comparison, verbosity/evidence,
failed-set and mode tests. The checker fixture SUMMARY above is for N=2.
Valid-config formula: **153 + 2N**, hence **157 for N=2**, **159 for N=3**.
Two implementation-isolation assertions count as INFO-PASS. Plain INFO and N/A do not count.
`git diff --check` passed. Full build/lint output is retained in evidence/round6/build.log.

Isolated build (no previous out/cache; exact compiler output):

```text
Compiling 259 files with Solc 0.8.33
Compiling 289 files with Solc 0.8.33
Solc 0.8.33 finished in 314.93s
Solc 0.8.33 finished in 616.30s
Compiler run successful with warnings:
```

## Red evidence and its limits

The following original-code failures were captured before their corresponding fixes:

```text
[FAIL: next call did not revert as expected] test_Round6GovernorRejected() (gas: 2518775)
[FAIL: next call did not revert as expected] test_Round6MissingOwnerInputRejected() (gas: 2518773)
```

Initial checker additions (malformed `1_000` and missing N/A rows):

```text
Ran 13 tests in 0.937s
FAILED (failures=2)
SUMMARY 141 passed, 0 failed, 141 total
```

The production fixture against original DeployLive handover behavior:

```text
[FAIL: round6: Safe owners] test_ProductionPathN3() (gas: 211246039)
```

Subsequent fail-first cases include recipient/mint/ticket checker mutations (three
failures), mint-event mismatch (one), malformed observed nonce (one), incomplete
failed-set inventory (one), and transport failure incorrectly accepted as an early
TL execution rejection (one). New tool tests initially failed on missing modules or
functions. Their exact outputs remain in evidence/round6/red-*.log.

A deliberately wrong derived nonce (+2 instead of +1) failed the actual production
fixture; the mutation was restored and the required build/test commands rerun:

```text
[FAIL: handover: bootstrap nonce] test_ProductionPathN3() (gas: 199926996)
```

**Fail-first requirement not fully met:** not every individual new Solidity assertion
received its own test run against unchanged code before implementation. Several
assertions were added as a group and then exercised by the complete production
fixture and mutation tests. The red evidence above is real, but is not a complete
per-assertion fail-first proof. No retroactive claim is made.

## Runtime sizes and operational limits

H runtime is **16 bytes**, in both runs=200 and runs=500 artifacts and in the
successful constructor test. No contracts/src source changed, so there is no changed
release runtime to remeasure. Changed script tooling artifacts: DeployLive runtime
**109576 bytes**; abstract DeployLiveInputs and DeployLivePins have no runtime (0).
DeployLive is forge tooling, not a contract deployed to the release chain; its size
is not an EIP-170 production-contract claim. Test harness sizes are likewise tooling.

- No genuine-PoP or fork run was performed: explicitly prohibited/unavailable here.
  Local BLS verification is mocked; arithmetic, ownership, nonce and failed-state
  reads execute against real deployed contracts in the forge EVM.
- The failed-set token scanner enumerates Transfer-emitting incoming tokens since
  genesis. It cannot prove absence of nonstandard tokens that change balances without
  Transfer events. An unrestricted every-token proof remains outstanding; a complete
  independently supplied token universe would be needed.
- The supplied wrapper binds the recorded EVM version to its actual forge flag.
  A direct forge CLI caller can supply an inconsistent DEPLOYLIVE_EVM_VERSION;
  Solidity has no cheatcode here to read forge's exact hardfork name.
- Evidence scanning covers every file under the explicitly supplied evidence directory
  and every explicitly supplied rehearsal scalar. It cannot certify undisclosed
  secrets or forge/broadcast files left outside that directory.

## Per-file changes versus bfb9cc45

Tracked changes and new non-ignored files are counted below. Ignored generated
compiler outputs and verbose .log files are excluded; their paths are recorded above.

| File | Added | Deleted |
|---|---:|---:|
| `contracts/script/v3/DeployLive.s.sol` | 130 | 32 |
| `contracts/script/v3/DeployLiveInputs.sol` | 32 | 1 |
| `contracts/script/v3/DeployLivePins.sol` | 28 | 0 |
| `contracts/test/scripts/DeployLiveHandover.t.sol` | 43 | 1 |
| `contracts/test/scripts/DeployLivePins.t.sol` | 41 | 0 |
| `contracts/test/scripts/DeployLiveProduction.t.sol` | 159 | 0 |
| `deployments/creation-pins.rehearsal.json` | 27 | 0 |
| `docs/security/rc8-daybreak-fixes.md` | 55 | 35 |
| `script/rehearsal/DEPLOYLIVE_HANDOFF.md` | 171 | 318 |
| `script/rehearsal/DEPLOYLIVE_VALIDATION.md` | 183 | 74 |
| `script/rehearsal/compare_artifacts.py` | 43 | 0 |
| `script/rehearsal/creation_pins.py` | 70 | 0 |
| `script/rehearsal/deploylive_failed_set_check.py` | 59 | 0 |
| `script/rehearsal/deploylive_fork_deploy.py` | 4 | 3 |
| `script/rehearsal/deploylive_postdeploy_check.py` | 61 | 8 |
| `script/rehearsal/deploylive_rehearse.py` | 134 | 10 |
| `script/rehearsal/evidence/round6/config.abandoned.json` | 1 | 0 |
| `script/rehearsal/evidence/round6/config.success.json` | 1 | 0 |
| `script/rehearsal/evidence/round6/production-pins.json` | 1 | 0 |
| `script/rehearsal/evidence/round6/production-transactions.json` | 1 | 0 |
| `script/rehearsal/evidence/round6/test-pins.json` | 1 | 0 |
| `script/rehearsal/inputs/deploylive-rehearsal.inputs` | 13 | 0 |
| `script/rehearsal/test_creation_pins.py` | 20 | 0 |
| `script/rehearsal/test_deploylive_failed_set.py` | 31 | 0 |
| `script/rehearsal/test_deploylive_modes.py` | 54 | 0 |
| `script/rehearsal/test_deploylive_postdeploy_check.py` | 38 | 4 |
| `script/rehearsal/test_deploylive_round6_tools.py` | 43 | 0 |
