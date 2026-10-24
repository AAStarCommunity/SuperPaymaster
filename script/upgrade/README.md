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

The gas tuple is `(440000,420000,5000,340000)`. Both queue and activation are owner-only. The executor waits for the internal 48 hours before scheduling activation, then waits the external 48 hours. Activation depends on the completed upgrade operation. No batches run in parallel. The RAMS 96h and 144h figures are model lower bounds to gas activation; this serial package follows the 144h path plus transaction and verification time.

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


**Engine pin changed 2026-10-24: nightly 926eb1d → 4e8874b.** 926eb1d does not implement the EIP-8037 reservoir split (frame gas uncapped above 2^24, `stateGasReservoir` always 0); it matched real RR txs only on receipt gasUsed (frame-level 0/10). 4e8874b (foundry #17719) matches 10/10 at frame level and 14/14 on the R-AMS R0 probe. Evidence: `docs/design/aoa-balance-mode/data/rams-rr-matrix/frame-calibration/` (PR cc125/rr-matrix). All A3a steps are ≤ 2^24 (R0), so earlier A3a numbers are unaffected, but a fresh plan must be produced under the new pin.
