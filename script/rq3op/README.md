# Fresh DeployLive RQ3 three-arm setup

This tool prepares unsigned setup transactions and three immutable sender plans. It
reuses the manifest Phase C builder and its checks, with deployment identities
supplied explicitly. It does not change the accepted `origin/cc127/rq3-sampler-draft`
branch or implement that draft's disabled broadcast path. No deployment or live
acceptance has been performed here.

## Before planning

1. Deploy with the frozen DeployLive script and complete the handoff checker.
   **No funding or registration before checker PASS.** Preserve its full stdout,
   exit status, config and deployment provenance.
2. DeployLive records the deployment source commit as `config.commit` (40
   lowercase hex digits). The planner requires that exact commit at HEAD in a
   clean worktree and independently runs the checker against the config.
   Never substitute the current checkout HEAD for an unknown deployment commit.
   The planner rejects missing provenance. It hashes the complete config and binds
   the checker evidence, comparator artifacts and all three plans to that commit.
   No change to DeployLive is needed.
3. Supply the experiment address, genesis operator, bundler, verifying signer,
   and three distinct SimpleAccount S / owner O / salt triples. The experiment,
   genesis, O, bundler and verifying signer must differ from the deployer and Safe.
   Signing names and passwords never belong in plans. Obtain account runtime hashes
   from the reviewed factory/implementation and comparator runtime hashes from the
   pinned constructor build/rehearsal. The planner checks the account predictions.
4. Calibrate the common task against this deployment locally. Record all six arm
   fields (`call`, `verification`, `paymasterVerification`, `postOp`,
   `preVerification`, `outer`), including SP `postOp`. Record owner preparation, maintenance and
   each setup transaction's measured/estimated gas. A setup entry may be the maximum
   across the three senders, with that provenance in the calibration evidence.
   No default gas estimate exists. Keep calibration evidence under the worktree.
5. DSR supplies `gasFactor`, `feeFactor`, `priorityRule`, `feeCeiling`, `stakeWei`
   and `unstakeDelay`. Ratios use integer numerator/denominator, rounding up.
   The gas factor is common to every arm and setup gas limit. SP postOp uses the maximum of
   the scaled measurement and the on-chain minimum, and records when the floor applies. The TPM's original `refundPostopCost`
   remains a comparator contract configuration value, not a transaction gas limit.

`inputs.example.json` and `calibration.example.json` are **unfilled templates**,
not measured evidence or executable deployment inputs.

The tool runs this checkout's DeployLive checker itself. Pasted checker evidence is
not accepted. Its exit code must be zero and its sole SUMMARY must report zero
failures and exactly `182 + 2 * guardianN` checks. `config.commit` must equal HEAD
in a clean worktree. Plans contain only structured checker results and the raw
stdout SHA256, plus a normalized address table. Output is scanned for URLs and
credentials before writing.

Calibration `source.evidenceFile` names a worktree-local JSON file; `evidenceSha256`
hashes its exact bytes. It must contain `chainId`, `superPaymaster`, `commit`,
`blockNumber`, `blockHash`, and exact copies of `arms`, `setup`, `ownerPreparation`,
`ownerMaintenance`, `bundlerMaintenance`, and `safeTransactions`. The block hash is
checked on both endpoints. Every gas limit must be positive, including VPM postOp.
`safeTransactions` supplies gas measurements for C1, GToken.transfer,
SP.stake.schedule and SP.stake.execute. Common gas/fee factors apply to these too.

## Plan and review

In the parent session with network access, from the repository root:

```sh
mkdir -p cache/3arm
python3 -B script/rq3op/plan_three_arm.py \
  cache/3arm/config.json cache/3arm/inputs.json cache/3arm/rq3-three-arm.10.json \
  --rpc-a-file cache/3arm/rpc-a.url --rpc-b-file cache/3arm/rpc-b.url
shasum -a 256 cache/3arm/rq3-three-arm.10.json
```

The planner only permits read RPCs. Its two injected clients must agree, state
reads use EIP-1898 block hashes, and it rechecks the anchor before writing output.
Paths must resolve inside this worktree. Keep operational config, inputs and outputs
under ignored `cache/3arm/` so producing evidence does not dirty the source tree.
No environment file or keystore is read.
The injected `build(config, inputs, rpc, checker, calibration, baselines)` interface
is the pure assembly layer used by offline tests. `generate()` authenticates the
checker, calibration, source commit, code and versions before assembly.

The output includes:

- `plans[S]`: three separately frozen plans, each with `phaseC`, `pin.phaseC`,
  `externalInputs`, `steps`, config/commit binding, fixed limits and provenance.
- `steps`: one ordered setup queue, IDs prefixed `0/`, `1/`, `2/`. Do not concatenate
  the per-sender plans in lexicographic address order; that can reorder nonces.
- `safeTransactions`: four inner transactions, each reporting the on-chain Safe
  threshold as `requiredSignatures`.
- `timelockOperation`: exact targets, values, calldata, predecessor, salt, operation
  ID and delay. The ID includes the **nonzero value** of SP addStake.

One X, T, Q, oracle, VPM and TPM are shared. There is one operator deposit and one
EntryPoint top-up per paymaster, covering the sum of the three worksheets. Each O
has its own preparation budget and exact Q approval. The task callData is common.
`PC_ATTEMPTS=100` is preserved: division over three S gives **34/33/33**, with the
indivisible remainder assigned to the first input S. This is recorded explicitly;
no attempt is discarded or silently added. Each plan retains the original safety
margins. Operator funding is `(100+5)*Amax`, shared by all three plans.

Gas limits are frozen for the entire plan, including the outer transaction and
setup limits. `phaseC.gasSources` records source measurements, factor, anchor and
result; `steps[].gasEvidence` records setup equivalents. The collector must copy
these records, the plan digest, and `phaseC.feeRule` into each data row. Do not
re-estimate an attempt: EntryPoint v0.7's unused-gas penalty would bias costs.

Fees are frozen at plan time with the price keeper's rule. The priority fee is the median, over
the last `priorityRule.blocks` blocks, of each block's `priorityRule.percentile`-th reward from
`eth_feeHistory`. Nonhistorical node estimates are excluded from frozen artifacts
so setup can reconstruct the same bytes later.
`maxFeePerGas = min(ceil(baseFee*feeFactor) + priority, feeCeiling)`. The same rule applies to
all three arms. `phaseC.feeRule` records the block range, rewards, priority and fee cap. The ceiling
cannot exceed the historical 20 gwei sanity bound. Planning stops if the capped fee cannot cover
base fee plus priority, or if the priority is zero.
Before sending, a higher base fee stops execution; it does not revise the plan.

## Safe and the only 48-hour wait

| Safe transaction | Signatures | Delay / value |
|---|---|---|
| C1: capped aPNTs mint to genesis | observed threshold | direct, no timelock |
| GToken transfer to genesis for ENDUSER stakes/tickets | observed threshold | direct, no timelock |
| schedule SP `addStake(unstakeDelay)` batch | observed threshold | starts 172800-second delay |
| execute the same batch | observed threshold | after 48 h; attach `stakeWei` ETH |

These are four separate Safe transactions (four times the threshold in signature
slots, not four distinct people). Even zero-deficit mint/transfer calls are output
explicitly. The Safe nonce is not reserved: review/order these inner calls in the
Safe workflow. SP's owner must be TL48. The planner never schedules or sends them.
The normal setup sender stops until the SP stake is active with sufficient amount
and delay. SP EntryPoint `depositTo` is permissionless and remains a normal setup
step from the experiment address. VPM/TPM stakes use the experiment address.
There is no gas-parameter update, additional 48-hour internal wait, or cap raise.
Insufficient cap headroom stops planning.

## Send setup with the existing formal transport

Install the repository's existing `viem` dependency in the authorized parent
session if absent. A signing-map file maps each sending address to
`{"address":"0x...","name":"local-keystore-name"}`. Include the experiment,
genesis and three O addresses; exclude the DeployLive deployer.

For each zero-based queue index in order:

```sh
node script/rq3op/setup.mjs cache/3arm/rq3-three-arm.10.json <reviewed-raw-file-sha256> \
  <queue-index> cache/3arm/signers.json cache/3arm/rpc-a.url cache/3arm/rpc-b.url \
  cache/3arm/setup.ndjson cache/3arm/config.json cache/3arm/inputs.json
```

`formal.mjs` supplies endpoint resolution, secret-redacted raw archives and
`cast wallet sign --account` signing. The only opt-in change to that module allows
archived pending nonce reads for setup; normal formal mode keeps its existing
fixed-block restriction. The setup adapter signs the exact frozen gas, fee, nonce,
value and calldata. Both endpoints must agree on chain, pending nonce, reads and
successful receipt. The Python gate worker executes the shared manifest's
per-step checks and receipt-block readbacks through this archived transport.
Readback failure stops; inspect the receipt before retrying. A replay cannot reuse
the consumed nonce. No local impersonation sender is used.

Sender routing is: genesis for C2/C3/C6/C7/C8; each O for C9.* and C18.approve;
experiment for comparator deployment/mint/configuration, C5, stakes/deposits and
ETH top-ups. The DeployLive deployer sends nothing.

## Sampler integration and acceptance boundary

Export the `plans` map as the draft's three sender plans and freeze whole-plan
hashes with its existing manifest functions. Do not change S inside a frozen plan.
Use `manifest_exec.sp_attempt_precheck` as the draft's injected helper; it now reads
SP from `phaseC.addresses.SP`, as does `price_gate`. Legacy plans without that key
retain their Sepolia behavior. This branch and the actual draft both name the
price policy gate `C_price_bound_exec` (main's post-rename execution gate).

The sending integration must run `plan_three_arm.pre_send` on two agreeing,
anchored clients immediately before **every arm's send**, then the existing
SP allowance precheck for SP. `C_gas_tuple` compares the entire effective/pending
tuple with the plan-time read; any change requires regeneration. It also checks
stake readiness, chain, fees, pause status, pricing and price freshness.
The draft's restricted precheck wrapper cannot carry the additional chain/stake
checks: run the fresh-deployment gate outside that wrapper. Do not change its
policy-refusal allowlist to swallow plan invalidation.

`manifest_exec.funding_gate` accepts these plan SP/operator identities for the
post-setup check. Run it for all three plans before sampling. The old local
`phase_c_state`, controls and accounting routines retain their upgrade semantics;
do not run the manifest's local executor on these plans. Fresh planning instead
pins zero tracked/revenue/backing balances and checks the exact deposit readback.

**The accepted draft still disables broadcasting.** This delivery is the setup
planner/sender, not an enabled sampler. The unchanged a6 `formalConfig` also retains
its historical 5/1-gwei rule; do not bypass the new frozen fees by handing it these
plans as legacy configs. Parent-session sampling must use an adapter that consumes
the new frozen fields, checks them before sending and archives their provenance.

## Separate fixture pins and known dependency gap

`fixture-pins.json` pins only F1TestToken and F1Oracle, with source SHA256,
artifact SHA256, creation keccak and constructor immutable patch locations. The
small compiled artifacts are included under `artifacts/`. They were built offline
with solc 0.8.33, Cancun, viaIR, optimizer 500; release pin files were untouched.
Their source comment permits these comparator fixtures on 10 and 11155111; other
F1 fixtures remain local only. Chain 31337 is accepted for local acceptance.

VPM and TPM retain the committed artifact SHA256, source SHA256, constructor ABI
and deployment runtime-hash checks. The artifacts must equal the files at the
config's commit. **The missing `@uniswap` directory remains a known gap:** TPM's
original build cannot be reproduced from this checkout alone. No dependency was
fetched and no comparator artifact was rebuilt or substituted.

## Upgrade-only steps removed

| Removed assumption/step | Replacement |
|---|---|
| Phase D handover | DeployLive checker PASS establishes completed handover |
| A13 SP owner stake / deposit | Safe/TL48 addStake operation; normal experiment depositTo |
| A14 pause inventory | fresh checker evidence, unpaused SP and genesis checks |
| A15 drain all operators | fresh zero tracked/revenue/backing gate, one shared deposit |
| BUFFER / B2a minted buffer | actual fresh backing pin and exact C2 deposit readbacks |
| activation/B4 / pending token swap | checker evidence and target deployment addresses; no upgrade wait |
| Sepolia SP/Safe/deployer/factory constants | config addresses, dedicated experiment key and genesis |
| fixed SP 480000 postOp | own postOp measurement × common gasFactor; effective gasParams minimum is a sanity bound |
| implicit 1 ETH/day SP stake | explicit bundler-required amount/delay, value-bearing Safe operation |
| fixed fees and other gas literals | common input factors, calibration sources, frozen fee ceiling |

## Parent-session local acceptance still required

Do not start Anvil in this sandbox. In the parent session:

1. Run `DEPLOYLIVE_LOCAL_TEST=1 python3 -m unittest discover -s script/rehearsal -p
   'test_deploylive_local.py'` and retain the actual DeployLive config and complete
   checker PASS. Follow HANDOFF for the production-path local deployment, pins and
   guardians. Record the deployment commit before checker evidence is frozen.
2. On that fresh local deployment, prepare the dedicated experiment/genesis/O
   fixture keys, calibrate all listed gas fields, choose DSR-approved factors,
   generate three plans with two read endpoints and inspect all Safe transactions.
3. Execute the two direct Safe calls. Schedule the exact SP stake operation, prove
   execution fails before 172800 seconds, advance local time, execute it with value,
   and read back stake amount/delay. Only SP addStake waits 48 h.
4. Execute the queue in order using local-only fixture signing in the parent
   harness. Assert nonce/address predictions, all readbacks, shared deposits,
   no deployer transaction, and all three `funding_gate` checks.
5. Integrate the draft with the frozen-plan send adapter described above. Run one
   task transfer through **each arm**, preserving the plan gas/fees. Archive
   UserOperationEvent, token balances, receipt and gas provenance; check SP renewal
   remains off, exact TPM approval and plan-derived SP precheck. This is smoke-test
   evidence, not a formal RQ3 window or factor calibration claim.
6. Change the effective SP gas tuple in the local harness and prove the next send
   stops without signing; repeat missing PASS, insufficient stake and fee-ceiling
   negatives. Reconcile remaining deposits and token balances.

Offline validation and the exact evidence paths are recorded in `REPORT.md`.

## Round 2 branch and ABI contract

Every plan declares `phaseC.spBranch = balance` and `creditPolicy = 0` (OFF).
C8 mints the full gas-token budget; this experiment needs no credit, no policy
queue/execute, and no `requestCredit`. Only SP addStake needs the 48-hour wait.
The balance branch calibration must be measured separately from a credit run.

The task calls SimpleAccount.execute(T, 0, T.transfer(R, 1)). T is a separate
F1TestToken, while X is the gas-paying xPNTs token. The builder rejects T == X
and records both addresses in `phaseC.balanceLock`.

The collector records `spBranch.planned`, `.observed`, and `.event` per row.
Balance settlement is `LockSettled(address,bytes32,uint256,uint256)`;
credit settlement is `CreditSettled(address,bytes32,uint256)`. Match the exact
X emitter, indexed S and UserOp hash, and reject missing, duplicate or wrong
settlements. The draft adapter must call `settlementBranch` from `branch.mjs`
with `planned: plan.phaseC.spBranch` after each SP receipt and archive the result
(or error.branch before stopping). The existing A6 collector enforces balance,
its planned branch. This does not enable the draft's disabled broadcasting.

Current checked-out ISuperPaymaster.OperatorConfig has aPNTsBalance at index 0,
xPNTsToken at 3, reputation at 4. The SDK's reported index-4 layout is not the
layout in this worktree. ENDUSER roleData is (community, stakeAmount). C7 uses
community-signed safeMintForRole, not a third-party registerRole call; the latter
requires msg.sender == user. Source-order and emitted-calldata tests guard this.


### SDK output and additional task-token balances

Write the output as `rq3-three-arm.<chainId>.json`. On real runs, retain it under
`deployments/rq3/` on an evidence branch. The SDK checks the file's sha256 before
reading `shared.*`: `T`, `R`, `SP`, `chainId`, `commit`, `configSha256`,
`taskCallData`, and `taskRecipients`. All three plans use the same T deployed by
plan 0's C10 and the exact `execute(T,0,transfer(R,1))` calldata.

`taskRecipients` is required; use `[]` when no extra balances are needed. Each
entry has `address` and an integer `amount` of at least 301. Addresses must be
unique (case insensitive), nonzero, and different from R and all three S accounts.
Plan 0 mints these balances using the experiment key after C11.S and C11.R,
with an exact balanceOf readback. Supply calibration `setup` measurements for
`C11.extra.0`, `C11.extra.1`, etc.; their scaled gas limits count toward the
experiment key's setup budget. The example includes one 10000-unit recipient.

These additions and the uniform measurement × gasFactor rule apply only to the
fresh deployment planner. The legacy Sepolia manifest retains its fixed 480000
SP postOp limit and original output bytes. Fresh SP postOp rejects a scaled
measurement below minPostOpGas; `sp_postop_limit` isolates this rule from the
possible alternative `max(scaled, minPostOpGas)`. The gas tuple is re-read before
send and must still match the pinned tuple.

Setup independently regenerates the complete bundle at its original block using
config, inputs, calibration and the same planner. Both the exact bytes and the
DSR-approved SHA256 must match before loading a signer. Archive-capable endpoints
are required for subsequent steps. The gate worker receives the verified bundle
in memory and requires a unique plan/step association. All transaction fields are
compared again after precheck, then pending nonce and chain are read on both
endpoints immediately before signing.

An exclusive `cache/3arm/locks/<experiment-address>.lock` is held for the whole
setup invocation. Existing locks, including stale ones, stop execution; investigate
and remove a stale lock manually only after confirming no signer is active.

`funding.senders` shows value, maximum gas cost, total required, current balance,
planned incoming funding and shortfall for experiment, genesis, every O and Safe.
Safe gas is a calibrated allowance for the emitted Safe transactions; the eventual
executor must also hold signing gas. `funding.eth` and `funding.tokens` aggregate
ETH obligations and token preparation amounts by token address.
