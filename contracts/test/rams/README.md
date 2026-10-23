# Route A offline rehearsal

This suite implements the CC-125 Route A stop/upgrade/wait/activate/resume sequence.
It never broadcasts. With `SEPOLIA_FORK_RPC` absent or empty, `setUp` returns
before reading other environment variables or creating a fork; each test's
`forkOnly` modifier calls `vm.skip(true)`.
An offline skipped run is **not** Sepolia or Amsterdam acceptance evidence.

## Run

```bash
# Repo-default compiler/profile, no network or compiler download:
FORGE=/path/to/forge
"$FORGE" build --offline
FORGE="$FORGE" env -u SEPOLIA_FORK_RPC ./script/evidence/rams-a-rehearsal.sh

# Orchestrator: pinned Sepolia archive fork, Amsterdam-capable nightly:
export FORGE=/path/to/nightly/forge
export SEPOLIA_FORK_RPC='...'
export FORK_BLOCK='...'
export OPERATORS='0xb5600060e6de5E11D3636731964218E53caadf0E,0xEcAACb915f7D92e9916f449F7ad42BD0408733c9,...'
./script/evidence/rams-a-rehearsal.sh --hardfork amsterdam
```

Replace the example operator list; do not include the literal `...`. Extra runner
arguments are forwarded to Forge. The runner forces `FOUNDRY_ISOLATE=false`,
uses `FOUNDRY_OFFLINE=true` only without RPC, and unsets it for configured forks.
It preserves Forge's exit code through the redacting pipeline and writes unique
UTC/PID logs under `docs/design/aoa-balance-mode/data/rams-a/`. Compiler settings
remain the repository defaults; runtime hardfork defaults to Amsterdam and can
be supplied explicitly. The shared header records Forge version, commit, exact
command, block and inventory; the RPC host is printed only as `<redacted>`.
Local Forge 1.8.6 supports the required `--no-isolate --hardfork amsterdam` flags;
older Forge 1.7.1 does not support `--no-isolate`.

## Inventory prerequisite

The orchestrator MUST scan the SP **proxy** logs from deployment through
`FORK_BLOCK`, using the event in tag `v5.4.2`:
`OperatorConfigured(address indexed operator,address xPNTsToken,address treasury)`.
Deduplicate indexed operator addresses, read back `operators(address).isConfigured`
at that same block, and supply the complete configured list in `OPERATORS`.
The test rejects missing/empty/zero/duplicate entries, missing tokens, unconfigured
addresses, and omission of either known operator. It cannot prove that an unknown
operator was not omitted. Historical logs are not obtained with `vm.getRawLogs`;
`vm.recordLogs` is used only for transactions executed by the test itself.

## Cases

| Test | Required evidence |
| --- | --- |
| `test_A1_oldPausePath_blocksAllOperators` | For **every supplied operator**, a signed old-layout op first validates with a 160-byte context, then the exact same op returns empty context / SIG_FAILURE after owner-only per-operator pause; every pause is read back. |
| `test_A2_newOperatorRisk_window` | Real Registry self-registration of a fresh community/super operator after all listed operators are paused; role-gate rejection before registration, real factory binding, default unpaused sponsorship, then rejection after atomic upgrade/global pause. A migrated V2 positive control with only the global pause lifted isolates the cause. Registry owner and both role-config owners are logged. |
| `test_A3_atomicUpgradeWithGlobalPause` | One upgrade call dispatches `setGlobalPaused(true)` through the new fallback/admin; implementation, runtime, immutables, version, owner, zero gas slot and unsafe defaults are read back. Old, unknown and migrated V2 operators, malformed input, and gas limits from zero through uint128 max are rejected. |
| `test_A3_emptyUpgradeData_admitsUnsafeLimit` | Empty upgrade data leaves global pause false and admits a valid V2 op with a 300k postOp limit; admission, not successful unsafe settlement, is the asserted hazard. |
| `test_A4_legacyContexts` | A real `handleOps` call settles/burns on 5.4.2 before the upgrade; a freshly signed pre-pause op is rejected both directly and by EntryPoint after pause. Advancing the block then upgrading leaves the earlier execution already settled. |
| `test_A4_hypotheticalSmartAccountOwner_midBundle` | Counterfactual transfer to a SimpleAccount; its first UserOp atomically upgrades/pauses after all bundle validation. Victim's 160-byte old context yields exact `PostOpReverted(InvalidContextLength())`, failed UserOperationEvent, rolled-back execution and no user burn/settlement; operator validation debit and protocolRevenue increase both remain stranded and are asserted/logged (306 aPNTs in the pinned fixture). |
| `test_A5_governanceTimeline_EOAowner` | Queue tuple/ETA; exact GasParamsTimelock failures immediately and at ETA−1; activation at ETA; complete gas read-back/pending clear; resume; real V2 `handleOps` settlement at postOp=440k / pmV=1150k; 300k rejected. |
| `test_A5b_settleBindingAnalysis` | Synthetic guard-crossing measurements with cost=100000 and fee=1; not settlement exhaustion or a universal margin. |
| `test_A5c_handleOps_minBoundaries` | Real handleOps at MIN−1 (AA34), MIN, and MIN+1 (execution and settlement). |
| `test_A3b_probeOnly_globalPause` | Probe retained when M14 disables upgrade read-backs and atomic pause. |
| `test_A6b_safeRoute_preUpgradeGap` | New registration and sponsorship during Safe-owned wait; pause cannot mature by earliest upgrade. |
| `test_A6c_registryRegistrationStop` | Owner disables PAYMASTER_SUPER grants with configureRole; existing grants remain valid. |
| `test_A6d_EOAfirst_thenTimelock` | Direct atomic EOA upgrade and queue, then real timelock acceptance/activation batch after 48h or 96h. |
| `test_A6_governanceTimeline_SafeTimelock` | Closed Safe-only proposer/executor roles, old single-step ownership transfer, delayed atomic upgrade+queue batch, exact pre-ETA reverts, exact unexecuted-predecessor rejection on 5.5.0, non-Safe execution rejection after the role audit, and branched 48h overlapping versus 96h sequential waits **after upgrade**. Both include an additional initial 48h before the upgrade: 96h / 144h total downtime from the first pause. |
| `test_A7_readbackGate` | New two-step ownership transfer; exact gas/pending values, owner, guardian, implementation/codehash/version, global/operator pauses, configured inventory and timelock state/timestamp. Each gas component, pending slot, owner, guardian, pause, implementation, each operator's configured/pause bits, and timelock state are independently corrupted with `vm.store`; code is corrupted with `vm.etch`. Missing inputs also fail. Every restored state passes again. |

## Fixture boundaries and limitations

- All tests require the stated live 5.4.2 EOA ownership, Sepolia immutables,
  2-of-3 Safe, and zero future gas/guardian/pause slots. Mismatches fail, not skip.
- Synthetic SimpleAccounts receive ETH/xPNTs, operator aPNTs deposits, SBT status
  via a Registry impersonation, and account-scoped credit-limit mocks. The oracle
  returns a controlled fresh $2000 price, including after time warps. Positive
  controls explicitly unpause their operator and set its rate interval to zero.
  These arrangements do not establish production funding, oracle freshness or
  real-user eligibility. Registry membership/registration gates are never mocked.
- A2/A3/A5 deploy a real local V2 protocol registry/tier source/token/factory stack
  and reconfigure the scenario's operator to it. The live legacy tokens are not silently treated as
  V2-compatible. A1 covers all supplied live tokens; A5 establishes V2 settlement
  for the fixture migration, not a production migration of every operator.
- A2 uses actual self-registration with staked/ticket-funded GToken. Disabled
  roles or incompatible live Registry/factory behavior fail explicitly for review.
  Registry `registerRole` is self-service; `safeMintForRole` lets an existing
  community sponsor eligible registrations. The Registry owner and role-config
  owner control configuration, rather than being the sole role-acquisition path.
- Solidity calls model successive transaction boundaries in A4: `handleOps`
  returns only after settlement, then the test advances a block and upgrades.
  A Forge test does not mine two external transactions. No EntryPoint execution
  context can remain suspended across top-level transactions.
- A4 changes ownership **only in its counterfactual test**. The fork's actual
  undelegated EOA has no account code. Safe-only executor roles reject a direct
  call from a SimpleAccount, but **do not prove universal same-bundle
  unreachability**: an account can potentially relay a threshold-authorized
  `Safe.execTransaction` which invokes the timelock. Safe AA modules, delegated
  EOAs and pre-authorized Safe payloads require operational exclusion. This suite
  does not fabricate live Safe signatures or claim that every Safe is incapable
  of ERC-4337 execution. Global pause cannot repair already-created legacy contexts.
- The read-back gate accepts an explicitly expected zero guardian. Runtime identity
  comes from the exact test-deployed `SuperPaymaster` with live immutables; it is
  not compared to `type(SuperPaymaster).runtimeCode`. Layout slots are derived by
  the compiler from the shared storage base, not copied numeric constants.
- Fork behavior and Amsterdam settlement must be executed by the orchestrator.
  Compilation and offline skips alone cannot validate these assertions.

The pre-upgrade sponsorship gap remains: newly registered operators can be sponsored
on 5.4.2 after the listed operators have paused (A2/A6b). Once the timelock owns
5.4.2, pausing additions also takes 48h. Re-enumeration alone cannot close that gap.
The stop guarantee starts at the atomic upgrade.

Mutation definitions and rerun instructions are in
`docs/design/aoa-balance-mode/data/rams-a/MUTATIONS.md`. The current M1–M16 patches
are regenerated with `bash script/evidence/rams-a-mutations-generate.sh OUTPUT_DIRECTORY`.
`targets.tsv` includes the expected first-failure substring; a different failure
is WRONG-ASSERTION. Historical fork logs do not validate this revised fixture.

Review 2 evidence scope, unresolved assumptions, scan reproduction, and both governance orderings are recorded in `docs/design/aoa-balance-mode/data/rams-a/README.md` and `REVIEW-2.md`. Current definitions await fork rerun.
