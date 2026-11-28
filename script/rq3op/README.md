# Fresh DeployLive RQ3 three-arm setup

This tool prepares unsigned setup transactions and three immutable sender plans. It
reuses the manifest Phase C builder and its checks, with deployment identities
supplied explicitly. It does not change the accepted `origin/cc127/rq3-sampler-draft`
branch or implement that draft's disabled broadcast path. No deployment or live
acceptance has been performed here.

## Before planning

Supply `DEPLOYLIVE_ENDPOINT_PROVIDER` and an evidence directory below this
worktree's `cache/` via `DEPLOYLIVE_EVIDENCE_DIR` (or `DEPLOYLIVE_LOCAL_EVIDENCE`).
Every chain except 31337 also requires `DEPLOYLIVE_SECOND_RPC_FILE`, containing
the second RPC URL, and `DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER`. Use distinct
approved provider names and endpoints matching `deployments/readback-providers.json`.
The planner's two RPC files and the checker's second RPC file must be available
locally. Release artifacts must be built in `out/`, or in the directory selected
by `DEFAULT_ARTIFACTS_OUT` matching the deployment config.

The planner selects one block hash and supplies it to the checker through
`DEPLOYLIVE_SNAPSHOT_BLOCK_HASH`. The checker resolves that hash and checks its
number, hash and timestamp on both providers before state reads, then repeats
canonical checks after replay. The planner requires the checker's
`SNAPSHOT_BLOCK_HASH` output to equal its own pin. Standalone DeployLive callers
that omit this input retain head selection. `checker_runner.py` only preserves
tool/environment isolation; it never rewrites read arguments. The planner passes
its primary URL through `ETH_RPC_URL`, not process arguments. On non-31337 chains,
the planner validates its own two endpoints with the checker's `independent_providers`
function: approved distinct names, bound hostname suffixes and distinct hostnames.
The names above identify the planner's primary and secondary endpoints too.
For every sender, both providers must report pending nonce equal to the nonce at
the EIP-1898 pin. An in-flight transaction stops planning, including with `--block`.

`eth_feeHistory` is a fee input read by block number, outside the hash pin. Its
results are compared on both providers and the resulting fee is bounded by
`feeCeiling <= MAX_FEE`; this does not establish hash-anchored fee history.

| Known gap | Current control and limit |
|---|---|
| Fee history is outside the hash pin | `eth_feeHistory` is a fee input read by block number, compared on both providers and bounded by `feeCeiling <= MAX_FEE`; fee-history blocks are not hash-proven. |
| Check count binds cardinality only | `guardianN` comes from deployment config; a required check-ID list is not implemented. Equal row counts cannot detect substitution or duplication of assertions. |
| Local integration acceptance | Requires the parent host to run the enabled Anvil test; offline suites cannot establish this acceptance. |


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
4. Calibrate the common task against this deployment locally. Record five arm
   fields (`call`, `verification`, `paymasterVerification`, `postOp`,
   `outer`), including SP `postOp`. Record owner preparation, maintenance and
   each setup transaction's measured/estimated gas. A setup entry may be the maximum
   across the three senders, with that provenance in the calibration evidence.
   `preVerification` is forbidden in calibration (STOP); PVG is computed by rule.
   No default gas estimate exists. Keep calibration evidence under the worktree.
5. DSR supplies `gasFactor`, `feeFactor`, `priorityRule`, `feeCeiling`, `stakeWei`
   and `unstakeDelay`. Ratios use integer numerator/denominator, rounding up.
   The gas factor is common to every calibrated arm and setup gas limit; PVG has factor 1/1. SP postOp uses the maximum of
   the scaled measurement and the on-chain minimum, and records when the floor applies. The TPM's original `refundPostopCost`
   remains a comparator contract configuration value, not a transaction gas limit.

`inputs.example.json` and `calibration.example.json` are **unfilled templates**,
not measured evidence or executable deployment inputs.

The tool runs this checkout's DeployLive checker itself. Pasted checker evidence is
not accepted. Its exit code must be zero and its sole SUMMARY must report zero
failures and exactly the count computed by `deploylive_check_count.expected_check_count` from
committed policy, artifact mapping and release versions plus `guardianN`. `config.commit` must equal HEAD
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

## Deriving inputs and calibrating on a fork (`derive_inputs.py`, `calibrate.py`)

After a new real deployment, refresh the key-only fixture with `python3 -B script/rq3op/fixtures/gen_config_keys.py /path/to/new/config.op-sepolia.json script/rq3op/fixtures/deploylive-config-keys.op-sepolia.json` and review the key diff.

The calibration chain is the required integer `--chain` argument; DeployLive configs
do not need a `chainId` key. Derivation checks both providers against this chain,
the fork checks its RPC chain ID, and the checker binds the config to this chain.
Supported fork rules are centralized in `calibrate.py`: Sepolia `11155111` uses
`--chain-id 11155111 --hardfork amsterdam`; OP Sepolia `11155420` uses
`--chain-id 11155420 --hardfork op:karst --optimism`. Unknown chains STOP.
OP `op:karst` is accepted by nightly `4e8874b` anvil. Never replace the real chain
ID with `31337`. OP Sepolia has a 2-second block time and a base fee around 250 wei;
actual fee inputs come from the pin. Anvil's Optimism execution accounts for L1
data fees; these tools do not hand-model them.

`--upstream-file` must contain a **KEYLESS upstream** URL: Anvil receives its
contents as a command-line argument, visible in the process table. This also
applies to the probe's case `upstream` files. Diagnostic redaction does not hide
process arguments.

Run the planner/checker with the **archived planner environment file**, containing
only the checker's variables. Keep `DEPLOYLIVE_EVIDENCE_DIR` unset and set
`DEPLOYLIVE_LOCAL_EVIDENCE` to the archived evidence under the worktree's `cache/`.
Never use the deploy-day loader for this: the checker requires
"evidence must be below worktree cache root".
Run `calibrate.py` (and the planner) with the **current directory set to the planner root**
(`cd <deploy worktree>` before invoking the tool from its own checkout): the planner resolves the
calibration's relative `evidenceFile` against the current directory, and anything outside the planner
root stops with `rq3_path`.

Fork ports are selected by the tool. Before writes, the child must still be alive,
the endpoint must report Anvil, and its fork configuration must match the requested
block pin. The probe requires an explicit case `block`.

OP Sepolia measurement invocation (all paths and pin values are placeholders;
prepare the checker, provisional calibration and derived inputs using the sequence below):

```sh
python3 -B script/rq3op/calibrate.py run --mode measure --chain 11155420 \
  --planner-root /path/to/deploy-worktree \
  --config /path/to/deploy-worktree/deployments/live/config.op-sepolia.json \
  --upstream-file /path/to/keyless-op-sepolia-upstream-file \
  --inputs /path/to/inputs.json --calibration /path/to/provisional-calibration.json \
  --checker-record /path/to/checker.json \
  --pin <block-number> --pin-hash <block-hash> --out-dir /path/to/measurements
```

Use that same config and `--chain 11155420` for `checker`, `provisional`, `assemble`, `derive_inputs.py`
and `run --mode verify`. Labels identify the chain and config SHA-256 and retain
**REHEARSAL / fork measurement; not for reuse** semantics. Assembly rejects
measurements from a different chain or config. The standalone `tpm_gas_probe.py`
reads the chain and config digest from plan 0; omitted case hardfork/flags use the
same mapping, and conflicting identity flags STOP. The deployment planner remains
bound to commit `99a38d8d` and is not modified by calibration.

Two tools produce the "reviewed" values of steps 3-4. Neither sends to a real chain.

`derive_inputs.py` reads both providers at one EIP-1898 pinned block hash
(`requireCanonical`) and requires byte-identical results. It writes
`inputs.<variant>.json` and `derived-values.json` ("value / how derived / pinned
block (hash, both providers equal)"):

| Value | Derivation | Planner check that consumes it |
|---|---|---|
| `accountImplementation` | `factory.accountImplementation()` | `C5_factory_implementation` |
| `runtimeKeccak.accountFactory` | `keccak(eth_getCode(factory))` | `C5_factory_runtime` |
| `runtimeKeccak.accountImplementation` | `keccak(eth_getCode(implementation))` | `C5_implementation_runtime` |
| `runtimeKeccak.account` | `keccak(eth_getCode(sample))` of an existing proxy with the same ERC1967 implementation, found by `eth_getLogs` on `SimpleAccountInitialized` (EntryPoint topic) | C5 `codeHash` readback |
| `account` | `factory.getAddress(owner, salt)` | `C5_counterfactual_pin` |
| `runtimeKeccak.VerifyingPaymaster` / `.TokenPaymaster` | read-only creation `eth_call {from: experiment, data: artifact.bytecode ++ args}`. The arguments come from plan 0's exact C12/C14 transaction. The artifact SHA-256 must equal `baselineSha256`. TPM's constructor calls Q and the oracle, so their runtimes are supplied as state overrides. These are taken from plan 0's own C13 `code` readbacks. | C12/C14 `codeHash` readbacks |
| SDK `xAmount` | `plan_three_arm.cost_bounds` at the pinned SP pricing, `N = sdkRuns*(4+sdkMaxOps)`, chosen `(N+PC_BETA)*Xmax` | `rq3_sdk_amount` |

All addresses are written lowercase (`pc_address`). The comparator constructor
arguments contain plan-derived addresses. That creates a cycle between the inputs and
the plan. Stage 1 therefore writes clearly-labelled PROVISIONAL comparator keccaks,
and stage 2 (`--plan`) replaces them. Comparator addresses depend only on sender
nonces, not on these keccaks, so the final plan's C12/C14 bytes are unchanged.

`calibrate.py` breaks the plan<->calibration cycle in this order:

1. `checker`: runs the commit-bound checker against the configured chain at the pin hash.
2. `provisional`: a deliberately generous calibration of kind `estimate`. It stays
   within the 2^24 per-transaction cap after gasFactor.
3. `run --mode measure`: the tool starts anvil itself on 127.0.0.1, forking Tenderly
   at the pin. It applies fork-only changes, all recorded:
   - funding of experiment, genesis, the Safe and the Safe owners;
   - a permissionless `SP.updatePrice()`;
   - for every S, the owner storage slot is replaced by a public fork key;
   - VerifyingPaymaster's `verifyingSigner` immutable bytes are replaced by a fork key.

   It then calls the planner's pure `build()` on the fork. It executes the four Safe
   transactions through `execTransaction` with pre-validated signatures. The
   48-hour execute is measured in a snapshot, and the stake is then reproduced by the
   impersonated timelock. Every queued step goes through `precheck_state`, `pre_send`,
   `phase_c_pre_send` and `check_predicate`. Last come the post-setup `funding_gate`
   and `sp_attempt_precheck`. `calibrate_ops.mjs` builds each UserOperation from
   `frozen-plan.mjs`'s frozen gas, fees and callData with the collector's packing and
   signing, and finalises PVG with `pvg.mjs`. For each field it finds the smallest
   limit that EntryPoint accepts and that still yields a successful op. Each
   candidate is re-signed and sent inside `evm_snapshot`/`evm_revert`. Callee frame
   gas understates EntryPoint's accounting: AA26 also counts the nonce update.
   With search on, the round -1 SP warm-up row is additionally searched for the
   `verification` field only, at EntryPoint key-0 nonce 0 before the warm-up op is
   sent, and recorded on the row as `warmupMinima.verification` (the collector
   `--first-use` sends each sender's first op, SP arm at nonce 0, at the frozen
   plan limits).
4. `assemble`: builds the calibration (kind `measured`, blockHash = the pin's real
   hash) and its evidence. Every number lists the fork transaction(s) that measured it.
   `SP.verification = max(nonce0, nonceAtLeast1)`: `nonce0` is the warm-up nonce-0
   minimum above, `nonceAtLeast1` the usual nonce >= 1 measurement maximum; both are
   recorded as the new top-level `spVerificationMinima` key of `calibration.json` and
   the evidence (top-level, not inside `arms`; the planner's `verify_calibration`
   compares only `arms`/`setup`/... and requires every `arms` value to be a positive
   int, so the extra key is ignored there).
5. `run --mode verify`: re-plans with the measured calibration on a fresh fork. It
   repeats the whole sequence with the frozen limits, without the search. Verify mode
   STOPs unless every op row is `USEROP_SUCCESS` with tx status `0x1`, `uoe.success`,
   and per-sender key-0 nonces consecutive in send order (each successful op consumed
   exactly one nonce).

Outputs belong under `cache/`. Rehearsal outputs must never be reused for a real run.

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

v0.7: unused execution gas (callGasLimit + paymasterPostOpGasLimit) is
charged at 10%, no threshold; preVerificationGas is charged in full;
verification limits are not charged when unused. See vendored
[`EntryPoint.sol`](../../singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol)
lines 46 (10%), 672 (PVG), 718–727 (unused execution gas). The decomposition
`A = P + E + floor(max(L-E,0)/10)` and PVG rule are v0.7-only; v0.8 adds a 40k
penalty threshold. The planner compares one pinned EntryPoint runtime read with
[`entrypoint-v07.json`](entrypoint-v07.json) and stops on mismatch. This uses the
committed canonical runtime and its recorded chain provenance, not the stale
v0.6 deployment artifacts in the vendored v7 directory or a local recompile.

Required `minTxInterval` is an integer uint48 in seconds (RQ2 S1r: **60**).
`C3.limits` follows `C3.configure`, is signed by GENESIS, uses its own calibration
measurement, and reads back `operators(genesis).minTxInterval`. Every setup send
checks the appropriate before/after interval; every sampling send checks the final
interval. This is self-service, not a timelock operation: `SuperPaymasterAdmin.sol:181`.
DeployLive registers genesis roles without configuring its operator limits
(`DeployLive.s.sol:761–765`, `:943–944`); Solidity's default interval is zero.
The timestamp is keyed by (operator, user), including reverted operations
(`SuperPaymaster.sol:309–320`, `:455–456`). The external schedule must space each
account's operations by at least this interval. No `schedule.py` exists in this
worktree; verification against the actual scheduler remains a cross-repo prerequisite.

Optional `extraEndUsers: [{address, xAmount}]` creates sponsored ENDUSER memberships
and mints X for **RQ2 live E2E**. These addresses are not S senders. GENESIS pays the
stake and ticket, approves staking, calls `safeMintForRole` with community=GENESIS,
then mints X. Calibrate `C8.extra.<index>.approve`, `.role`, and `.mint`. The plan
includes role, SBT balance/membership and X balance readbacks; funding includes all
extra stakes/tickets and X. Zero addresses, duplicate extras and S/O/R collisions
are refused. Both lists exclude every address recursively found in config and
inputs other than `extraEndUsers` and `taskRecipients`, including all principals
(experiment, genesis, bundler, verifyingSigner, owners, deployer, Safe and timelock).
Each list is independently unique, case insensitive; an address may appear in both
lists to receive ENDUSER membership, X and task-token T. A code-less recipient prints an INFO line to stderr (JSON stays clean).
`Registry.sol:458–475` performs no code check and passes `msg.sender` as sponsor;
`:494` passes that sponsor to staking. `GTokenStaking.sol:165` transfers from the
payer. `MySBT.sol:294–319` uses `_mint`, so no ERC721 receiver code is required.

Calibrated gas limits are frozen for the entire plan, including the outer transaction and
setup limits. PVG freezes the rule in `pvg-rule.json`, with mode `sign-time` and a null
plan bound/value. Nonce and both signatures are unknown at planning. The shared SP/VPM/TPM
function computes the EVM calldata cost (zero byte 4, non-zero 16) of the packed UserOp
as encoded inside handleOps, plus 21000/ops and the op-independent handleOps calldata
cost/ops. This collector permits exactly one op per transaction. The latter includes
the selector, argument offsets, beneficiary, array length and tuple offset.

PVG always has factor 1/1, independent of gasFactor. Changing encoded limits can still
change byte costs; numeric invariance is for identical op bytes. A 65-byte all-0xff
owner signature placeholder is available before signing. At sign time the collector
uses the actual nonce, beneficiary, owner signature and VPM signature, regenerates
both signatures for each candidate PVG, and requires an exact fixed point including
the PVG word itself. A deterministic signature changes with the PVG word, and its zero-byte
count can alternate, so the rule value can cycle (for example 27196 <-> 27208 on the attempt1
fork; see `a6-collector/pvg-cycle.test.mjs`). A cycle is resolved at its maximum m. The op is
re-signed at m, its own bytes must cost r <= m, and the result declares `ruleValue` r,
`surplus` m - r (a multiple of 12 gas) and `resolution: cycle-max`. Non-convergence without a
cycle, r > m or m above the reserve still STOP before sending. No nonce prediction
or empirical gas constant is used. The planner records `pvgLengths` for initCode,
callData, paymasterAndData and signature per arm. `pvgReserve` applies the same rule
to maximal non-zero op values and beneficiary (ABI padding remains canonical).
Signing rejects changed lengths (`PVG_LENGTHS`) or PVG above reserve (`PVG_RESERVE`).
Prefund includes this reserve and excludes outer gas; outer funds only the bundler.

Each SENT row records `pvgConsistency` = rule PVG - (21000 + standard calldata
cost of actual tx input) / opsPerTx. Any value other than the declared surplus (0 for an exact
fixed point) STOPs with `PVG_CONSISTENCY`.
Standard intrinsic calldata prices are zero 4 / non-zero 16. This rule ASSUMES the
EIP-7623 calldata floor does not apply. Collection records `calldataFloorGas` =
21000 + 10 * (zero + 4*nonZero), `outerGasUsed`, and `calldataFloorBinding` on equality.
`bundlerNetGas` is this op's event actualGasUsed minus receipt gasUsed.
`unusedGasPenalty` uses the existing trace-bound decomposition; ambiguity or unavailable
evidence yields null with a reason, and mismatches are flagged. `bundlerNetGasExPenalty`
subtracts that penalty (null if unknown). This is the self-bundling PVG over/under-charge
column. `opGasPrice` and `outerEffectiveGasPrice` remain separate: gas differences are
not wei differences when prices differ. `l1DataFee` remains separate. All measured
columns are null on NOT_SENT rows. The rule JSON cites the vendored EntryPoint lines
for PVG, penalty, cost and event semantics. Sepolia and OP use the
same definition. `phaseC.gasSources` records source measurements, factor, anchor and
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

These are separate Safe transactions, each requiring the observed threshold.
Zero-deficit mint/transfer calls are omitted because they have no planned state change. The Safe nonce is not reserved: review/order these inner calls in the
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
  cache/3arm/setup.ndjson cache/3arm/config.json cache/3arm/inputs.json --expect-head <previous-chain-head>
```

`formal.mjs` supplies endpoint resolution, secret-redacted raw archives and
`cast wallet sign --account` signing. Setup enables archived pending nonce reads; normal formal mode keeps its
fixed-block restriction. Safe emission and completion recording use read-only mode. The setup adapter signs the exact frozen gas, fee, nonce,
value and calldata. Both endpoints must agree on chain, pending nonce, reads and
successful receipt. The Python gate worker executes the shared manifest's
per-step checks and receipt-block readbacks through this archived transport.
Readback failure stops; inspect the receipt before retrying. A replay cannot reuse
the consumed nonce. No local impersonation sender is used.

Keychain password source (opt-in): add `"keystorePasswordSource":"keychain"` to a
signing-map entry to have `formal.mjs` type that keystore's password from the macOS
Keychain (service `aastar-rq3-keystore`, account = keystore name)
through a pseudo-terminal instead of prompting on `/dev/tty`. A missing entry or any
helper failure stops with `keystore signing failed (redacted)`; there is no fallback.
See [Keychain password source (opt-in)](../a6-collector/README.md#keychain-password-source-opt-in)
for the same-user silent-read exposure and the required delete-when-idle step (with its
read-only check), plus the optional dedicated auto-locking keychain. The default tty flow
never stores the password.

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

**The accepted draft still disables broadcasting.** Sampling consumes frozen-plan
fees and checks `baseFee + priority <= cap <= ceiling` and `priority <= cap`.
`formalConfig` uses the same fee predicate; there is no fixed 5/1-gwei requirement.
The adapter checks the frozen fields before sending and archives their provenance.

## Separate fixture pins and known dependency gap

`fixture-pins.json` pins only F1TestToken and F1Oracle, with source SHA256,
artifact SHA256, creation keccak and constructor immutable patch locations. The
small compiled artifacts are included under `artifacts/`. They were built offline
with solc 0.8.33, Cancun, viaIR, optimizer 500; release pin files were untouched.
Its `commit` field records where these two fixtures were built (their build provenance). The planner requires that commit to be an ancestor of the deployment commit, and checks exact matches for each artifact SHA256, creation keccak, the fixture source SHA256 (`sourceSha256`), and `runtimeIdentity` (artifact runtime bytecode and MINTER immutable ranges).
The planner enforces permission for these comparator fixtures on 10, 11155111,
11155420 and 31337 (local acceptance). Other F1 fixtures remain local only.
This scope supersedes the older source comment without changing pinned fixture sources.

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
| fixed SP 480000 postOp | max(own postOp measurement × common gasFactor, on-chain minPostOpGas) |
| implicit 1 ETH/day SP stake | explicit bundler-required amount/delay, value-bearing Safe operation |
| fixed fees and other gas literals | common input factors, calibration sources, frozen fee ceiling |

## Parent-session local acceptance still required

Use a host that permits binding Anvil to `127.0.0.1`. The existing local test
command now includes `test_planner_final_checker_acceptance`: it deploys the full
local system, advances head, and runs the real planner/checker against the earlier
hash. With `DEPLOYLIVE_LOCAL_TEST=1`, socket, Anvil launch and startup failures fail
the test. Skipping is allowed only when that variable is unset. CI reruns this
test verbosely and requires its explicit `... ok` result. This test also runs in `deploylive-python`, which builds the required `out/` artifacts.
The a3a job runs offline rq3op tests without that build and cannot run this gate.

In the parent session:

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
unique (case insensitive), nonzero, and different from R, all three S accounts,
and every principal/config address, as for `extraEndUsers`. Cross-list overlap is
allowed. In plan 0, `C11.extra.<i>` mints T before the appended
`C8.extra.<j>.approve`, `.role`, `.mint` group; the experiment sends the T mint,
GENESIS sends the membership/X group, and per-sender nonces remain consecutive.
Plan 0 mints these balances using the experiment key after C11.S and C11.R,
with an exact balanceOf readback. Supply calibration `setup` measurements for
`C11.extra.0`, `C11.extra.1`, etc.; their scaled gas limits count toward the
experiment key's setup budget. The example includes one 10000-unit recipient.

These additions and the uniform measurement × gasFactor rule apply only to the
fresh deployment planner. The legacy Sepolia manifest retains its fixed 480000
SP postOp limit and original output bytes. Fresh SP postOp rejects a limit below
minPostOpGas (C-04), so a calibrated minimum at or below the floor is the floor
itself: `sp_postop_limit` then freezes the limit at minPostOpGas (DSR K9,
2026-11-27); only a measurement above the floor is scaled, as
`max(measured × gasFactor, minPostOpGas)`. The gas tuple is re-read before
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

Round-2 execution trust: git and cast are resolved to absolute paths once at
startup. Their paths, version output and SHA256 are recorded in `checker.tools`.
All planner/checker subprocesses receive only a fixed tool-directory PATH plus
/usr/bin:/bin and LC_ALL=C. Checker and runner bytes must match their git blobs
at config.commit. Malicious replacement of executables on the operator machine
is part of the trust root; these controls prevent accidental tool/config misuse.
Expected on-chain versions come only from `deployments/release-versions.rc8.json`;
CI compares that reviewed table with source literals.

Frozen collector runs hold `cache/3arm/collector-locks/<chainId>/<bundler>.lock`
until process exit. Active and stale locks are refused, never stolen. Both RPCs
must agree on the initial pending nonce and on the expected next pending nonce
immediately before each send. Legacy formal mode retains its fixed-block nonce.

### Round 3 SDK funding and formal gates

All plans require integer `sdkRuns` in `1..10000`, `sdkMaxOps` in `1..32`, and
integer `sdkMaxCostPerOp` in `1..10^18` wei; stricter downstream bounds are below. There is no warm-up; each operation has signBudget 1.
`shared.sdkLive` records the pinned pricing and the exact rounded conversion used by
phase C. With `N = sdkRuns * (4 + sdkMaxOps)`, every extra user's `xAmount` must be
between `(N+1)*Xmax` and `(N+PC_BETA)*Xmax`, inclusive. `extraEndUsersXTotal` is the
sum of those amounts. The shared cross-repository vector is `sdk-cost-vector.json`;
large integers are decimal strings so JavaScript consumers must use BigInt.
Live SDK cells remain provisional until the SDK pre-sign cost cap merges.

Non-rehearsal formal collection requires both `--frozen-plan` and `--bundle-sha256`
before config or keystore access. Planner and collector read the repository maximum
fee from `script/fee-limits.json`. Acceptance recomputes the exact frozen fee from
its planning base and factor; the current base plus priority must also fit that cap.
Pinned postOp minima must meet `docs/release/rq3-runtime-expectations.json`, checked
against the release contract constant by an offline test. EntryPoint pin schema,
version and chain list are exact; 31337 is reserved for offline/rehearsal fixtures.

### Round 5 completion protocol and Safe handoff

Every step uses a dual-endpoint pinned-head gate. A completion entry plus its
freshly re-read successful receipt and matching current target state yields
`already-satisfied`. Without an entry, only the exact initial state permits
execution. All other combinations stop, including an unlogged target state,
a missing/failed receipt, or drift after a recorded completion. No-effect calls are omitted during planning and consume no nonce. An unlogged
step at its target stops even when its initial and target predicates are identical.

The append-only, fsynced log is `<bundle-path>.completions.jsonl`, beside the
bundle. Completion entries bind the raw bundle SHA-256 and step id to transaction
hash, block number/hash, receipt status, block timestamp and exact readback values.
The runner rechecks transaction identity and the canonical receipt block on both
endpoints. C15 and SP scheduling use the verified receipt timestamp plus the
planned delay for their target predicate. Keep the log and `.head` with the bundle.

Before owners sign each Safe transaction, run (index into `safeTransactions`):

```sh
node script/rq3op/setup.mjs safe <bundle> <digest> <index> - \
  <rpc-a-file> <rpc-b-file> <audit-log> <config> <inputs> --expect-head <previous-chain-head>
```

This chain-read-only command verifies the reviewed bundle and gate, records an
authorization, then emits the inner CALL plus full signing fields, safeTxHash and
bound digests. A completed step prints `already-satisfied` and emits no transaction;
a STOP emits none. It constructs no signer. The operator sequence is exactly: `safe` (get transaction + safeTxHash) -> verify
hash in Safe UI and collect signatures -> `safe-clear` -> execute immediately ->
`safe-record`. After collecting signatures, run:

```sh
node script/rq3op/setup.mjs safe-clear <bundle> <digest> <index> - \
  <rpc-a-file> <rpc-b-file> <audit-log> <config> <inputs> --expect-head <previous-chain-head>
```

Only after this succeeds, execute the emitted CALL through `execTransaction`.
Then record the receipt and readback:

```sh
node script/rq3op/setup.mjs safe-record <bundle> <digest> <index> - \
  <rpc-a-file> <rpc-b-file> <audit-log> <config> <inputs> <execution-tx-hash> --expect-head <previous-chain-head>
```

The recorder verifies the Safe address, exact inner call and `ExecutionSuccess`
event against the unexpired authorization, then checks receipt-block state. A successful
outer receipt with a failed Safe inner call is refused. For an interrupted EOA
send whose completion was not recorded, use the same command with `record` in
place of `safe-record` and the index into `steps`. It checks every frozen transaction
field and receipt-block readback before recording. Investigate the transaction
before using this recovery command; rerunning the send will stop without a record.

SDK-only `C8.extra.*` approve/role/mint steps require literal `sdkLive.status:
"cleared"` and a lowercase 40-hex `sdkCostCapCommit`. Three-arm steps remain
available for provisional plans. The input is `priceHeadroomBPS`; the old
`sdkPriceHeadroomBPS` alias is refused, even when the new field is present.

Operational bounds are `sdkRuns` in 1..10,000, `sdkMaxOps` in 1..32 and
`sdkMaxCostPerOp` in 1..10^18 wei. These limit the declared experiment to 360,000
operations per user and at most 1 ETH per operation before stricter token budgets.
Every SDK converted result, per-user cap/floor, aggregate token funding, stake/ticket
funding and ETH/gas funding total must fit uint256. Xmax must fit uint128 for token
locks. `(N+PC_BETA)*Amax` must fit the extra users' existing 5,000 aPNTs allowance
and total-cap defaults; the planner does not raise these caps. Existing Safe GToken,
aPNTs supply-cap and sender ETH affordability checks still apply.

Fee ceilings and factor components must be JSON integers. Both fee implementations
run every case in `script/fee-rule-vectors.json`; formal signing rechecks the full
frozen rule on its final refreshed head. Setup uses the collector's lossless parser;
large integers cross the Python line protocol as tagged decimal strings.

### Safe authorization and completion integrity (round 6)

Taking a transaction directly from the plan file is unsupported. Run `safe` first;
only a successful pinned-head gate appends an `AUTHORIZATION` to the bundle's
`.completions.jsonl`, fsyncs it and its tail checkpoint, and emits the signing
information. **Compare `safeTxHash` character by character with the Safe UI**,
along with the emitted `safe` and `chainId`. `signingTransaction` freezes the
nonce read from `nonce()` at that pinned block and all ten SafeTx fields.
`safeTxGas`, `baseGas`, `gasPrice`, `gasToken`, and `refundReceiver` default to
zero (the zero address for address fields), unless explicitly set in the reviewed
plan. Do not let the UI substitute different gas/refund parameters.

The only supported `VERSION()` value is 1.4.1 (`SUPPORTED_SAFE_VERSIONS` in completion.mjs). The signing hash
uses the EIP-712 `EIP712Domain(uint256 chainId,address verifyingContract)` and
`SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)`
type hashes, dynamic-data keccak256, and the `0x1901` prefix. Every other version stops,
including 1.3.0 and 1.4.0: no real receipt in this checkout proves their event layout.
1.4.1 reads txHash from topics[1], pinned by a receipt produced on a Sepolia fork by the real Safe 1.4.1 code:
`docs/release/a3a-testsafe-12025632/live/S5b/receipt.json`. **Adding a version requires a
real receipt of that version as a test fixture**; a synthetic layout test is not enough. A Safe ExecutionFailure always refuses recording.
The SHA-256 transaction digest also binds Safe, chain and all signing fields.

An authorization records `blockNumber`, `blockHash`, `blockTimestamp`, and
`expiresAtTimestamp = blockTimestamp + AUTH_WINDOW_SECONDS`. The single named
constant `AUTH_WINDOW_SECONDS = 86400` provides one day for human multi-owner
signing, independent of chain block speed. The pin timestamp comes from the
pinned header cross-checked through both providers; disagreement stops. This is a SIGNING authorization, not permission to execute after collecting signatures.
`safe-clear` uses a NEW pinned head corroborated by both providers, rechecks the
step's initial predicates, re-reads nonce and VERSION, and recomputes safeTxHash.
A changed predicate, nonce, hash or anchor prints `DO NOT EXECUTE` and appends
nothing. On success it appends an `EXECUTION_CLEARANCE` bound to the signing
authorization's recordDigest. `CLEARANCE_WINDOW_SECONDS = 600` is the single
named ten-minute limit; expiry is the smaller of pin timestamp + 600 and the
signing authorization expiry. There may be only one unconsumed, unexpired
clearance per authorization. An expired clearance may be replaced after a fresh
successful gate. The signing authorization still expires after 24 hours.

`safe-record` requires exactly one unused authorization for the step, Safe and
chain. Both execution and the current agreeing recording head must be strictly
after the pin block, with block timestamp <= `expiresAtTimestamp` (inclusive).
An outstanding authorization prevents re-authorization while the new gate's pin
timestamp is <= the previous expiry, regardless of the number of elapsed blocks.
The authorization block must remain canonical. The decoded execution
parameters plus the authorized nonce must reproduce its Safe signing hash and the
`ExecutionSuccess` event's txHash. That event cryptographically identifies the
nonce consumed by this execution, even with multiple Safe transactions in one
block. Execution must be strictly after the clearance pin block and have timestamp
<= clearance expiry. Missing, expired, consumed or ambiguous clearances refuse
with `execution not cleared`. Recording rechecks both canonical pin hashes and
consumes exactly one clearance and its authorization by record digest. A
clearance cannot extend the signing authorization lifetime. Expired,
ambiguous, consumed or missing authorizations stop with
`transaction not authorized by the gate`; an expired execution cannot be recovered
by authorizing it retrospectively. Re-gating is possible only while the step is
still in its initial state and the previous authorization has expired.

Every authorization and completion is chained using SHA-256 over canonical full
record content excluding only `recordDigest`, including `previousDigest`.
Canonical encoding is compact UTF-8 JSON: object keys sorted lexicographically
at every level, array order preserved, JSON string escaping, BigInts represented
as exact decimal JSON number tokens (distinct from strings). Genesis is 64 ASCII zeroes. Every read verifies the entire
chain and bundle digest before selecting a record. The separate `.head` file
stores the count and final digest, detecting complete-record suffix truncation
or removal of the log. Appends fsync the log, atomically replace a fsynced head,
and fsync its directory. An interrupted append/checkpoint mismatch stops for
operator review; never delete/reset these files to bypass it. Preserve both files
together. Every command prints `CHAIN_HEAD <digest>` as its final stdout line;
save that value separately from the log and its `.head`. Every later invocation
must pass `--expect-head <digest>` with that saved value. A mismatch refuses
before state checks or signing. This detects rolling back or deleting both files
relative to the operator's retained digest. If the bundle cannot be identified or
the chain is corrupt, output is `CHAIN_HEAD unavailable`, which is not an anchor.
Existing unchained logs are refused. On rerun, receipt-block target observations
are obtained again and compared in full to the recorded readback before its
completion evidence is used for the current-state gate.

### Recovery and first invocation (round 7)

Do not infer initialization from missing files. For the first invocation only,
use `--first-run` instead of `--expect-head`. It is accepted only with an empty
history AND every Safe and EOA step in its initial state at one dual-provider
pinned head. Any target or partial state refuses and directs the operator to
`--expect-head`; checking only the selected step is insufficient. Sequential
plans can contain future-step initial predicates that are not yet true, so this
check is deliberately conservative and may refuse such a plan. Do not use a
fresh genesis digest to evade a lost history check.

After a refusal, preserve the evidence. Restore the reviewed log and `.head`
from a trusted backup and compare their head to the separately retained digest.
Never adopt the current on-disk digest merely to silence a mismatch, and never
reset to `--first-run` after losing history. If the prior digest or history is
unavailable, stop and reconcile the receipts and state before resuming. The
operator-supplied anchor is the trust root; supplying an old digest alongside an
old backup defeats rollback detection.

### Known residual

Safe signatures themselves do not expire. The 24-hour authorization bounds when a
clearance may be issued; this tool also requires execution within that authorization
window, but recording a timely execution may happen later.

Clearance issuance requires at least 60 seconds remaining before the smaller of
the authorization expiry and pin timestamp + 600. This leaves a practical margin
for submission and a subsequent block, without guaranteeing inclusion. A refusal
reports the expiry timestamp.

Within the 600-second clearance window the state can still change.
The post-execution target check detects a step that did not reach its planned target state; it does not detect
unrelated state changes, or a change that was reverted before the check.

After the first Safe transaction of the Sepolia rehearsal executes, its on-chain receipt is added as a fixture.
The DeployLive readback checker requires `DEPLOYLIVE_ENDPOINT_PROVIDER` (a short provider
name, never an endpoint URL) and an explicit `DEPLOYLIVE_EVIDENCE_DIR` for its evidence.
Set both before invoking rq3; `PinnedTools` forwards them to the checker. There is no
fallback to the config file's directory. Provider validation runs during input loading
and checker startup, before chain reads.

The frozen-plan collector uses one public-seed schedule of 60 slots in three
separate runs, in order. Windows 1, 2 and 3 cover slots 0–19, 20–39 and 40–59,
respectively, with their own start and end passports. Refresh the price externally
before each window. The price may change only between windows. Every slot in the
slice is attempted without optional stopping, and a run that finishes the slice
and passes end checks reports `EXHAUSTED`. Under rotation, `phaseC.attempts`
remains each sender's budget per arm (34/33/33), and the full schedule uses
20 allocations per sender per arm. [Frozen collector run instructions](../a6-collector/frozen-plan.md)

The later evidence aggregate is `COMPLETE` at 50 or more complete triplets across
all three valid windows, `INCOMPLETE` below 50, and `INVALID-INTERRUPTED` if a
slice is missing or void. A void or interrupted slice must never be rerun under
the same registration. The collector refuses an existing window directory. A
new directory for the same slice produces a second result for that range, which
the aggregate must refuse as a duplicate. Slice validation and aggregation are
pending in the evidence PR.

Every planned transaction gas limit is bounded by the pinned block header gasLimit.
Stricter caps live in tx-gas-caps.json: OP mainnet (10) and OP Sepolia (11155420)
are capped at 16,777,216 by Karst. The entries record provenance and explicitly
note that no over-cap transaction was sent to validate rejection.
The shape is {"<decimal chain id>": {"gasLimit": <positive integer>, "source": "<nonempty provenance>"}}.
Unregistered chains use only the block bound; registered caps cannot relax it.
