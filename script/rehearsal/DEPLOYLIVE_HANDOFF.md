# Deploy-day rehearsal: copy-paste sequence (Sepolia, three guardians)

Prerequisites: reviewed clean HEAD, pinned `FORGE` and matching Anvil binary,
cast 1.7.1 (`CAST_1_7_1`), approved principals, and two distinct real-chain RPCs.
Provision the **loopback forward proxy** on port 18545 separately; its implementation
is a follow-up outside this change. No upstream URL goes on Anvil's command line.
Obtain the approved DVT export after prediction; PoPs bind this request and nonce.
Do not send deployer transactions or change approved inputs between prediction and deploy.

Run deploy day from a FRESH clone at the approved commit, never in a worktree that was used
for a rehearsal: rehearsal and production configs share `deployments/live/config.<ENV>.json`.

Prepare the ignored input file once, fill every required value from the approved
manifest, and leave optional keys present but empty. Endpoint URLs never go into this
file: `DEPLOYLIVE_RPC_FILE`, `DEPLOYLIVE_SOURCE_RPC_FILE` and `DEPLOYLIVE_SECOND_RPC_FILE`
name regular, non-symlink files owned by the operator, mode 0600 or narrower, with exactly one physical URL line, which the loader reads in-process. Any input value that
starts with `http://`, `https://`, `ws://` or `wss://` is refused.
Each endpoint file passes a start-up self-check: the scanner must find a credential-like
segment in the URL (>=16 characters, or >=8 with both letters and digits). An endpoint that truly
carries no credential, such as a keyless public gateway, is allowed only when the operator sets
`<KEY>_NO_CREDENTIAL=1` for it (`DEPLOYLIVE_SOURCE_RPC_NO_CREDENTIAL`, ...). The declaration is part of
the input manifest (changing it after predict is an input change), it is recorded in
`checker.PASS.json` as `noCredentialEndpoints`, and a declaration contradicted by a credential-like
segment stops. Its host and full URL are still matched verbatim by every scan. This is the explicit load step
(run from the worktree root in bash/zsh; the file contains literal assignments only):

```sh
mkdir -p deployments/live
cp -n script/rehearsal/inputs.template.env deployments/live/inputs.sepolia.env
export INPUTS="$PWD/deployments/live/inputs.sepolia.env"
"${EDITOR:-vi}" "$INPUTS"
APPROVED_EXPORTS="$(python3 -c 'import os,shlex,sys; sys.path.insert(0,"script/rehearsal"); from deploylive_controls import load_inputs; print("\n".join("export "+k+"="+shlex.quote(v) for k,v in load_inputs(os.environ["INPUTS"]).items()))')" || exit 1
eval "$APPROVED_EXPORTS"
unset APPROVED_EXPORTS
export PATH="$(dirname "$FORGE"):$PATH"
"$CAST_1_7_1" --version | head -1 | grep -Eq '^cast Version: 1\.7\.1(-|$)' || { echo 'STOP converter requires cast 1.7.1'; exit 1; }
printf '%s\n' 'INPUTS LOADED'
```

Expected: `INPUTS LOADED`. Each driver subcommand independently reloads `--inputs`,
rejects missing/extra/duplicate keys, and derives `SP_COMMIT` from clean HEAD.
Do not put `SP_COMMIT` in the file; an inherited mismatch is refused. Empty optional
keys are omitted from child environments. `GUARDIANS` is generated in step 6.
The template lists the driver and DeployLive inputs; internal execution flags and
the request output path are set by the driver. `DEPLOYLIVE_PRICE_SOURCE=fork` is
rehearsal-only; production requires `chain` and `DEPLOYER_ACCOUNT`.

Evidence **must be inside this worktree**, outside all four build output/cache
directories. The default is `deployments/live/deploy-day-evidence`. Build cleans
its output/cache directories. Only the final archive copy goes outside the worktree.
Set `ARCHIVE_DIR` to a new external archive directory in the final step.

## Rehearsal commands

1. Verify the hardfork and pin A's latest block minus two confirmations. Sepolia
   requires forkId `0x6c1d9423`, activationTime `1791294816`; both endpoints must
   agree on the pinned block hash, `blockAccessListHash` and `slotNumber`.
   B's `eth_config` -32601 is recorded, not a failure. Expectations live in
   `deployments/hardfork-expectations.json`; OP uses the documented unsupported
   `eth_config` / unpopulated-header-field rule and stops on unknown supported configs.
   Expected: `HARDFORK PASS pinned block <number>`. That number is the **rule-check
   block**: the block at which the hardfork rule was verified, and the fork block in a
   rehearsal. It is NOT the PoP pin block (see step 5).

   ```sh
   python3 script/rehearsal/deploylive_fork_deploy.py hardfork-check --inputs "$INPUTS"
   ```

2. Start the pinned fork through the provisioned proxy in a second terminal;
   keep it running. Run the same input load block there first.
   Expected: Anvil's `Listening on 127.0.0.1:8545`.

   ```sh
   PINNED_BLOCK="$(python3 -c 'import json,os; print(json.load(open(os.path.join(os.environ["DEPLOYLIVE_EVIDENCE_DIR"], "hardfork-check.json")))["blockNumber"])')"
   "$(dirname "$FORGE")/anvil" --fork-url http://127.0.0.1:18545 --fork-block-number "$PINNED_BLOCK" --port 8545 --chain-id 11155111 --hardfork amsterdam
   ```

3. Run the snapshot-isolated EIP-7825 control on the fork. It sends a 20,000,000-gas
   CREATE of `0x5b600056`, requires status 0 / gasUsed 16,777,216, and reverts.
   `--production` refuses this command before constructing the fork transport.
   Expected: `CONTROL PASS`.

   ```sh
   python3 script/rehearsal/deploylive_fork_deploy.py cap-control --inputs "$INPUTS"
   ```

4. Build Cancun release and Prague execution artifacts using the same pinned engine.
   Expected final line: `BUILD PASS`.

   ```sh
   python3 script/rehearsal/deploylive_fork_deploy.py build --inputs "$INPUTS"
   ```

5. Predict. The driver writes `cache/deploylive-prediction/pop-request.json` and
   copies it to `$DEPLOYLIVE_EVIDENCE_DIR/pop-request.json`. It also writes sorted
   `inputs.manifest` and `inputs.manifest.sha256`: non-secret inputs, derived SP_COMMIT,
   and request SHA256. The DVT request key set is unchanged.
   Expected final line: `PREDICT PASS` (preceded by the request SHA256).
   The request's `pin.block` is the **PoP pin block**: the PARENT of the block the
   prediction simulated on. On a real chain it follows the live head at prediction time and
   is unrelated to the rule-check block of step 1. DVT verifies the PoP pin block
   (`pin.block`, `pin.blockHash`, the deployer nonce at it), never the rule-check block.

   ```sh
   python3 script/rehearsal/deploylive_fork_deploy.py predict --inputs "$INPUTS"
   ```

6. Have the approved DVT signing workflow place its address-bound export at
   `$DEPLOYLIVE_EVIDENCE_DIR/dvt-export.json`, then convert it. Signing is an
   external prerequisite, not an improvised local helper. The converter writes
   `guardians.hex` and `conversion.json`, binding the manifest digest and SHA256
   of the exact export, request and guardian encoding. Expected: `CONVERT PASS`.

   ```sh
   test -s "$DEPLOYLIVE_EVIDENCE_DIR/dvt-export.json" && PATH="$(dirname "$CAST_1_7_1"):$PATH" python3 script/rehearsal/dvt_pop_to_guardians.py "$DEPLOYLIVE_EVIDENCE_DIR/dvt-export.json" "$DEPLOYLIVE_EVIDENCE_DIR/pop-request.json" --sp-root . --inputs "$INPUTS" && echo 'CONVERT PASS'
   ```

7. Deploy and run the integrated checker. The driver reads generated `guardians.hex`;
   it verifies the conversion record before planning, before the final simulation,
   and immediately before broadcast. It never rebuilds. Expected: `SUMMARY 189 passed, 0 failed, 189 total` for N=3,
   then `PASS full deployment; post-deploy checker PASS`. N=2 has 187 rows.
   A config file or successful Forge exit alone is not acceptance.

   ```sh
   python3 script/rehearsal/deploylive_fork_deploy.py deploy --inputs "$INPUTS"
   ```

8. Copy evidence to a new external archive, including verified file copies and
   `SHA256SUMS`. Archive verifies `gated-plan.json` against the canonical digest
   in `checker.PASS.json`. Archive requires this run’s manifest-bound `checker.PASS.json`,
   copies `deployments/live/config.<ENV>.json` and the actual broadcast
   `run-latest.json` itself, and checks their PASS-time digests. Enter the full destination path when prompted; existing destinations
   and symlinks are refused. Expected: `ARCHIVE PASS`.

   ```sh
   printf 'New external archive directory: '; read -r ARCHIVE_DIR
   python3 script/rehearsal/deploylive_fork_deploy.py archive --inputs "$INPUTS" --to "$ARCHIVE_DIR"
   ```

   `archive` re-reads the inputs file and every endpoint file: delete them only AFTER this step.


The gas gate remains single-endpoint on the real chain (`DEPLOYLIVE_SOURCE_RPC`),
independent of fork-price mode. It retains fees, full-sequence simulation and the
5% maximum tolerance. Price threshold remains 4200 seconds. Production uses the
same build/predict/deploy commands with `--production` and approved production inputs;
never run cap-control there. Archive evidence includes hardfork/control JSON, request,
DVT export, build identity, simulation reads, Forge logs and checker output.

These hashes are drift checks against operator mistakes and stale files. The trust
root is the operator's machine.

The build stamps bind clean HEAD and the SHA256 of `foundry.toml`. Deploy verifies
both before planning and before broadcast. The artefacts themselves are checked
byte by byte against the creation pins (hashing all creation bytes) in DeployLive’s
preflight before broadcast; no separate artefact manifest is used.
Deploy re-runs the dual-provider hardfork rule check before generating its plan.
Immediately before broadcast it simulates again and compares count, order, sender,
consecutive nonces, transactionType, destination, calldata, value and
chainId with the gated plan, then checks the
pending deployer nonce against the prediction. The post-broadcast comparison also
requires each gas limit inside [real-chain need, block gas limit], with the lower
bound raised above 2^24 when the total exceeds 90% of 2^24. Accepted differences
are listed in `postbroadcast.gas.json`. Both diff records and `checker.PASS.json`
bind the canonical gated-plan SHA256. Success requires checker PASS and an empty
`diff` list in `postbroadcast.diff.json`.

Remaining window: chain-head movement between the final simulation and broadcast
can change gas estimates. The 1.3× margin plus the post-broadcast comparison cover
it: a changed gas limit makes the run NOT successful even if transactions were sent.
Forge receives RPC URLs through `DEPLOYLIVE_FORGE_RPC_URL` and the `deploylive`
alias; the checker uses `ETH_RPC_URL`. URLs never appear in process arguments.
Before broadcast, sensitive output is refused. After broadcast, affected log streams
are replaced with REDACTED text and `REDACTED_AFTER_BROADCAST` is written; the
post-broadcast diff still runs and its evidence is written.

In stop mode the gates still evaluate the full STOP=0 plan. An additional STOP=1
simulation must equal its prefix, with the omitted tail starting at the H CREATE.
Broadcast is compared with that stop plan and the corresponding gated gas bounds.
`stop-plan.json` and `stop.diff.json` preserve that comparison. PREPARED is not PASS.

### Change an input after predict: offline refusal cell

This cell uses mocked Forge/RPC transports and proves the broadcast/Forge invocation
never ran. Expected: `Ran 1 test` and `OK`.

```sh
PYTHONPATH=script/rehearsal python3 -m unittest test_ddf5.Ddf5Test.test_owner_change_refuses_before_forge
```

On deploy day, any owner, recipient, threshold or other manifest input change requires
new prediction and PoPs. Deploy refuses it with
`STOP deployment: STOP input manifest mismatch; repeat predict and PoP` before Forge.

## Historical design and acceptance notes

The notes below explain earlier rounds. The numbered sequence above supersedes
their invocation examples; use the approved `--inputs` interface for current runs.

# Deploy-day corrections (2026-11-19; required before rc.8)

The checker now has **183 + 2N** rows: **187 for N=2**, **189 for N=3**.
The additional aggregate row checks all principal code reads for EIP-7702;
its failure detail lists every affected address. Earlier counts below are historical.

Production config is `deployments/live/config.<ENV>.json`. `deployments/live`
is ignored, so writing the config does not dirty the source-commit gate.
The driver creates the directory; for direct PoP simulations create it first.
Local non-production chain-31337 behavior remains `deployments/config.<ENV>.json`.
Pass the new production path explicitly to the checker and rehearsal driver:

```sh
ETH_RPC_URL="$DEPLOYLIVE_RPC" python3 script/rehearsal/deploylive_postdeploy_check.py "deployments/live/config.$ENV.json" "$DEPLOYER_ADDRESS" "$GOVERNANCE_OWNER"
```

Success means **checker exit 0 AND its SUMMARY has failed == 0**. Forge can
write a complete config before a later broadcast fails. Config existence, a
successful simulation, and Forge's exit status alone are insufficient. Both
drivers enforce the checker result; stopped-before-H mode is preparation for
the expected-failure rehearsal, never a successful deployment.

## Method (a): pinned nightly engine, identical builds and script

The committed pin is `deployments/forge-deploy-pin.json`: nightly `4e8874b`,
SHA256 `c1364206d29b027f75cde3c1de79e623e49f6b0076786b51f4623263568ff766`.
Use an absolute `FORGE` path to that binary. The driver builds the whole tree
with it twice: Cancun release artifacts, then Prague execution artifacts. It
records `forge --version`, resolved binary path and SHA256 in build stamps next
to both output directories, rechecks both stamps before each script invocation,
and records build/script identity in `forge.build-and-script.json`. Rehearsal and
production both enforce the committed pin. Never build with stable 1.7.1 then execute with
nightly: that mixed build caused stale-cache recompilation and an unsuffixed
TimelockController artifact with constructor decoding displaced by 49 bytes.

Set all production inputs and endpoint variables through the approved input
loading process. Do not put endpoint literals or secrets in commands or logs.
`DEPLOYLIVE_RPC` is the broadcast endpoint; `DEPLOYLIVE_SOURCE_RPC` and
`DEPLOYLIVE_SECOND_RPC` are two distinct real-chain endpoints for chain-price
corroboration. In the inputs file each is given only as a `*_FILE` path; the loader
reads the URL in-process and it never appears in output, STOP messages, config or evidence. Only `DEPLOYLIVE_SOURCE_RPC` is used by the single-endpoint gas gate;
fork-price mode does not require `DEPLOYLIVE_SECOND_RPC`.
`DEPLOYER_ACCOUNT` selects the already prepared keystore account.

```sh
export DEFAULT_ARTIFACTS_OUT=out DEFAULT_CACHE_PATH=cache
export FOUNDRY_OUT=cache/deploylive-rehearsal-out
export FOUNDRY_CACHE_PATH=cache/deploylive-rehearsal-cache
export FOUNDRY_VERBOSITY=2 PRICE_STALENESS_THRESHOLD=4200
export DEPLOYLIVE_GAS_TOLERANCE=0.05
export DEPLOYLIVE_HARDFORK=amsterdam  # Sepolia; select the verified matching OP hardfork for OP
mkdir -p deployments/live "$DEPLOYLIVE_EVIDENCE_DIR"
python3 script/rehearsal/deploylive_fork_deploy.py deploy --production "$DEPLOYER_ADDRESS"
```

The build stage performs the two builds. Deploy verifies their stamps, runs a
fresh dry run and all gates below, then this
exact method-(a) broadcast command (shown for audit; run it through the driver
so the gates and build stamps cannot be omitted):

```sh
ETH_RPC_URL="$DEPLOYLIVE_RPC" "$FORGE" script --offline contracts/script/v3/DeployLive.s.sol:DeployLive \
  --sender "$DEPLOYER_ADDRESS" --slow \
  --evm-version prague --hardfork "$DEPLOYLIVE_HARDFORK" \
  --gas-estimate-multiplier 130 -vv --account "$DEPLOYER_ACCOUNT" --broadcast
```

Compilation target Prague and runtime hardfork Amsterdam are separate settings.
The gas multiplier is forge's default 130 (`DEPLOYLIVE_GAS_MULTIPLIER`, passed to both
forge and the gate). With 100 the broadcast limits would equal the raw estimates. Under
EIP-8037 a limit <= 2^24 leaves no state-gas reservoir, so the TOTAL gas counts against the
2^24 regular cap: the Paymaster CREATE totals 16,771,708, which is 5,508 below the cap. The gate
recovers forge's estimate as ceil(limit x 100 / multiplier) before comparing it with the real-chain
eth_simulateV1 gas. For every transaction it also requires limit <= the block gas limit, and, for a
limit <= 2^24, a total gas <= 90% of 2^24. Measured on the Sepolia fork (2026-11-19): the largest
regular-gas portion is 807,489 (SP implementation), against 60,155,369 total. Keep the full
dry-run JSON and the real simulation result in evidence.

## Fixed pre-broadcast and fork rehearsal gates

- **Fix ALL inputs before generating the PoP request.** Write the request inside
  the worktree, e.g. `cache/deploylive-prediction/pop-request.json` (Forge `fs_permissions`), then
  copy it to evidence. Fixing an input or changing the deployer nonce afterwards
  requires a fresh request and fresh PoPs.
- Verify the active hardfork at the pinned head. In the rehearsal, `eth_config`
  was supported only by Alchemy; corroborate the second endpoint using the
  block-header fields `blockAccessListHash` and `slotNumber`, at the same block.
- Anvil fork URLs must come from a file or environment, never the command
  line. Provision the loopback forward proxy described above; even
  `anvil --fork-url "$RPC"` expands the URL into process arguments and is forbidden. Do not weaken gas limits to make a run pass.
- The EIP-7825 positive control is a **fixed rehearsal step**: a 20M-gas loop
  CREATE capped at **16,777,216** must fail. Archive the command, bytecode,
  capped gas, receipt/error and hardfork/header evidence. A control that succeeds
  invalidates the rehearsal's cap enforcement.
- The driver derives the zero-based `price_init_index` from the fresh dry-run
  `SuperPaymaster.updatePrice()` transaction by the computed calldata selector and
  SP proxy destination, never by Forge function/name labels or an assumed 45.
  The proxy is linked to its implementation by the planned proxy constructor. It reads the
  feed `latestRoundData().updatedAt`, head and 100-block-old header from two
  endpoints at the same fixed blocks in chain mode, or the single fork endpoint
  in fork mode. Require
  `(price_init_index × measured_block_time) × 3 + (head.timestamp − updatedAt) ≤ 4200`.
  Every term and remaining margin go to `prebroadcast.log`. A negative margin
  stops with **wait for the next feed update**. Equality passes.
  Sepolia rehearsal: heartbeat ~1 h, limit 4,200 s, #46 of 97 (index 45),
  ~12 s/block → 540 s (~9 min), ×3 = 1,620 s; maximum acceptable feed age 2,580 s.
  OP example: ~2 s/block and index 45 → 90 s, ×3 = 270 s; maximum age 3,930 s.
  The repository's parameter guide lists an OP ETH/USD heartbeat of 1,200 s.
  These are planning examples: the gate measures block time and actual feed age
  and derives the index again for each chain and planned sequence.
- Before broadcasting, submit **the full sequence**, in order, to real-chain
  `eth_simulateV1`, one transaction per simulated block. Compare the seven large
  CREATEs (Registry, xPNTsFactory, MySBT, SuperPaymaster, xPNTsTokenV2Ext,
  xPNTsTokenV2, BLSAggregator) and TimelockHandoverBootstrap H against Forge.
  H must see all predecessor state; never use isolated `eth_estimateGas` for H.
  Unsupported simulation, incomplete/reverting results, real gas above Forge,
  or Forge more than 5% above real gas **STOP** the run. The tolerance is an
  explicit input, recorded per comparison; operators may tighten it below 5%.
  A mismatch is evidence to investigate, not permission to widen the limit.
- The checker rejects EIP-7702 delegation code (`0xef0100`) for every configured
  or live-read principal: guardians, GUARDIAN_ADDRESS, SP_GUARDIAN, genesis,
  GToken recipient, Safe signers, authority inputs and accounting beneficiaries.
  Ordinary contract code, including a Safe, passes this delegation check.
  The existing deployer-empty-code and Safe-specific checks remain in force.

For the final Sepolia-fork run, use the same build/output variables above,
set `REHEARSAL_SOURCE_RPC` to the source endpoint and supply the rehearsal's
`REHEARSAL_BLS_SCALARS` for the evidence scrubber. Run:

```sh
python3 script/rehearsal/deploylive_rehearse.py happy "$FORK_RPC" \
  "deployments/live/config.$ENV.json" "$DEPLOYER_ADDRESS" "$GOVERNANCE_OWNER"
```

Main session: on a fresh Sepolia fork, rerun the positive control and full PoP
flow using the final committed head and pinned binary; archive request/export
hashes, both build stamps, dry-run sequence, price reads (dual-endpoint on chain, single-endpoint on fork),
`eth_simulateV1` requests/results, per-transaction gas/receipt table, Forge logs,
and final checker output. Exercise a failing checker with the config still
present and confirm the driver exits nonzero. Keep real endpoints in environment
or files. The sandbox change author runs no Anvil, RPC or keystore commands.

# Round 9 acceptance corrections

The checker has **182 + 2N** rows: **186 for N=2**, **188 for N=3**.
The four additions are `deployer has no code`, `artifact directory`,
`artifact compile settings`, and `release creation pins` (all 25).
The earlier round counts below are historical.

Production rejects a deployer with any code using `DeployerHasCode(address)`
before any broadcast, immediately before CREATE TL, and immediately before CREATE H.
Config records `deployerCodeLength`; the checker requires both recorded and live
code length to be zero.

All release readers use `DEFAULT_ARTIFACTS_OUT`, default `out`. The committed
inputs use `out`, matching both the default and acceptance rehearsal; there is
no need for `out-cancun`. Config's `artifactCompileSettings` is a contract-name
map read from selected artifact metadata, with `evmVersion`, `viaIR`, and
`optimizerRuns` per contract. All 25 must be Cancun/viaIR; Registry and
TimelockHandoverBootstrap use 200 runs, the other 23 use 500. Registry's
compilation restriction also places the importing H in the 200-run profile.
The checker compares those recorded settings with its independently selected
artifacts and verifies all 25 creation hashes against committed chain pins.

Verify the exact directory before deployment:

```sh
python3 script/rehearsal/creation_pins.py --check deployments/creation-pins.10.json --artifacts "${DEFAULT_ARTIFACTS_OUT:-out}"
```

Without `--artifacts`, pin generation/checking retains the isolated clean-build
mode. The fork wrapper keeps Prague simulation output in
`cache/deploylive-rehearsal-out` and its cache in
`cache/deploylive-rehearsal-cache`, separate from Cancun release artifacts.

Happy mode accepts an OP-mainnet Anvil fork with chain ID 10 (also 31337).
The wrapper explicitly runs `anvil_setCode(deployer, "0x")` before the run:
this is the selected rehearsal approach for undelegating default-mnemonic OP
accounts. It is an Anvil-only preparation step, never a production transaction.

**What the three "deployer has no code" checks do and do not guarantee.** Production
DeployLive calls `_requireUndelegatedDeployer` in the preflight, right before CREATE TL and
right before CREATE H. `forge script` simulates the whole run first and broadcasts afterwards,
so all three checks execute during the simulation. They are not re-evaluated on chain when the
corresponding transaction is broadcast. A delegation added to the deployer DURING the broadcast
can only come from a 7702 authorization signed by the deployer key itself, which the
trusted-deployer premise covers. After the run, the checker detects it: it reads back
`deployerCodeLength` and asserts the predicted TL/H addresses. The checks are not three live
on-chain gates.
`DEPLOYLIVE_EVIDENCE_DIR` must be inside the worktree; use `archive --to` for the external copy.
Forge stdout/stderr are written as `forge.stdout.log` and `forge.stderr.log`,
including failed Forge runs; the outer driver scans those files before returning.

Failure mode is **31337-only**, enforced by both driver and deployment helper,
because the stop switch exists only on that rehearsal chain. Its three deviations
from chain 10 are:

1. `deployments/creation-pins.31337.json` is identical to `.10.json`.
2. `deployments/external-deps.31337.json` points at local infrastructure fixtures;
   install those fixtures on the fork before running.
3. `inputs/external-tokens.json` now includes a committed `31337` group containing
   the OP fork's inherited token addresses. Pass that file with `--external-tokens`;
   nobody needs to re-parent the OP group by hand. This group assumes an OP fork,
   not an empty local chain; empty-chain tests must supply their deployed mock tokens.

In a failed set, the deployer still directly owns Registry, SuperPaymaster and
APNTsCapped: the two-step transfers were nominated but never accepted, and
pendingOwner is TL. The artificial failure rehearsal deliberately clears Registry's
pendingOwner to trigger the revert; that injected fault is the exception to the
normal failed-set nomination state. Operating rule: in an abandoned set, the
deployer sends **NO further transaction** (no accept, no transfer). Redeploy with
a new nonce range and regenerate all address-bound PoPs.

## Deployer EOA after a successful deployment; SDK experiment account ordering (DSR 2026-11-18)

After a successful broadcast and a checker PASS, the deployer EOA holds no protocol
authority. It sends **no further transaction to protocol contracts**. It remains
the owner of the paper's SDK experiment account, the SimpleAccount v0.7
`0xE8Eaad6A4802300F33E53c40e65863CCcDA6898b` (factory `0x91E6…8985`,
`getAddress(owner 0x51Ac694981b6CEa06aA6c51751C227aac5F6b8A3, salt 0)`), and only
signs UserOps for it.

Ordering constraint: between the PoP request pin and the DeployLive broadcast, the
deployer sends nothing, because the PoPs bind its nonce. The following therefore
run only AFTER the broadcast has completed and the checker has passed:
- deploying that SimpleAccount on a chain where it does not exist yet (on Sepolia
  it is not deployed; the owner EOA sends that transaction);
- any preparation paid by the deployer EOA.

Minting task tokens to that address does not need the account to exist and may
happen in the three-arm setup.

# Round 8 delta handoff (2026-11-18, base 12278ac0)

The current checker count is **182 + 2N**: **186 for N=2**, **188 for N=3**.
The five new rows are the governance Safe proxy codehash, the config pin-file
SHA256, and three artifact creation-code pins. Authority rows also apply the
proxy and singleton checks to all five owner inputs and the GToken recipient.
The agent switch and dependency-key schema fail fast and do not add summary rows.
Historical round 7 counts below describe that version only.

Proxy codehash: `0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c`.
Provenance: committed `docs/release/a3a-newpin-11995523/boot/plan.json:99`,
recorded runtime for `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`.
The complete bytes, including compiler metadata, were hashed with local
`cast keccak`; no network read was performed. The same bytes occur in
`docs/release/sp-upgrade-a6e/evidence-11983550/boot/plan.json:99`.
Main session must compare the live codehash. The reusable fixture copies these
bytes and uses a stub singleton at the official v1.4.1 address; it tests real
proxy delegation, not the full Safe singleton implementation.

Script preflight now requires an allowlisted proxy codehash, slot-0 singleton,
and fallback handler, in addition to the existing threshold/owner/module/guard
checks. Checker runtime comparisons first hash each local artifact's creation
code against `deployments/creation-pins.<chainId>.json`, and require the config's
`creationPinsSha256` to match that committed file. Runtime matching is skipped
and marked FAIL when either binding fails.

31337 defaults to zero for all three agent registry addresses. Only a=1 selects
`contracts/test/fixtures/deploylive/external-deps.31337.agents.json`; the production
chain groups remain authoritative elsewhere. With a=0 the checker expects zeros,
and the script records zero validation registry too (including OP; its address
remains informational in the reviewed dependency file). Missing dependency keys
produce a named FAIL. The legacy row is now named `config legacy pnts == zero`;
it makes no claim of on-chain absence.

The main session reported a green local Anvil run on 2026-11-18 at 12278ac0:
`SUMMARY 178 passed, 0 failed, 178 total`. That was **a=1**, before these changes.
Round 8 a=0 and a=1 acceptance remain for the main session; neither was run in
this sandbox. Run `DEPLOYLIVE_LOCAL_TEST=1 python3 -m unittest discover -s
script/rehearsal -p 'test_deploylive_local.py'`. Evidence is separated into
`cache/deploylive-tests/round8/a0/` and `a1/`, including untouched forge configs.
The Foundry workflow now runs all Python rehearsal tests with that opt-in flag,
and its full-diff trigger includes all rehearsal, deployment and fixture paths.

## Round 8 known gaps

- Low 4: SafeL2 v1.3.0 is not allowlisted; DSR awaits the author's mainnet Safe
  address. No v1.3.0 proxy hash was added. The existing v1.3.0 singleton entry
  does not establish support without an approved proxy codehash.
- Low 6: tokens sent to predicted addresses before deployment remain an accepted
  inventory gap. Listed-token balance checks do not make discovery exhaustive.
- Local Anvil a=0/a=1 and live proxy-codehash comparison require main-session
  evidence. The historical a=1 result does not validate this round's changes.

---

# DeployLive round-seven governance ceremony

The deployer is trusted during deployment. Acceptance is the verified final state,
not a successful simulation or a partially written config. `contracts/src` is unchanged.
Only chain 31337 without `DEPLOYLIVE_REHEARSAL=1` uses the legacy local behavior.

## Inputs and authority

Production requires `GOVERNANCE_OWNER`, `GUARDIAN_ADDRESS`, `SP_GUARDIAN`,
`GENESIS_AASTAR_OPERATOR`, `APNTS_CAP`, `GUARDIAN_N`, `GUARDIAN_MIN_THRESHOLD`,
`GUARDIAN_DEFAULT_THRESHOLD`, `GUARDIAN_SLASH_THRESHOLD_0/1/2`, and public
`GUARDIANS` (ABI-encoded account, public key, PoP tuples).
Safe, policy guardian, SP guardian, genesis operator, deployer and each DVT guardian
must differ. Thresholds satisfy 2 <= min <= default <= N <= 64; slash thresholds
are in [2,N]. EntryPoint v0.7, the fresh 8-decimal oracle and the account factory
are checked before broadcast.

The following five inputs have **no production defaults**. Each accepts the exact
literal `timelock`, the exact literal `safe`, or a contract passing the Safe checks below. The declared choice is resolved, applied, asserted and recorded.

| Input | DSR ceremony choice | Authority |
|---|---|---|
| SLASH_POLICY_ADMIN | timelock | BLSAggregator slashPolicyAdmin |
| X402_OWNER | safe | X402Facilitator owner |
| REPUTATION_OWNER | timelock | ReputationSystem owner |
| MPC_OWNER | timelock | MicroPaymentChannel owner |
| PAYMASTER_FACTORY_OWNER | timelock | PaymasterFactory and Paymaster implementation owners |

`GOVERNOR_ADDRESS` must be absent on production, including an empty declaration.
The rejection points to `X402_OWNER`. Legacy local behavior still resolves governor.
`DEPLOYER_GTOKEN_RECIPIENT` is required and accepts `safe`, `timelock`, or a
contract passing the same Safe checks. Empty input has a named error. Explicit rehearsal choices are in
[inputs/deploylive-rehearsal.inputs](inputs/deploylive-rehearsal.inputs); this file
is never loaded implicitly by the production script.

BLSAggregator, DVTValidator, xPNTsFactory v1, xPNTsFactoryV2 and
AOAProtocolRegistry owners are always the Safe. Every slot is checked using
GovernanceOwnerGate.readMofN, exact address equality, contract code and rejection
of the EIP-7702 prefix. This proves a Safe-compatible threshold >= 2 with enough
unique nonzero owners, excluding the deployer. The script additionally requires
no enabled modules (including the pagination sentinel) and a zero guard. Explicit
owner/recipient contracts pass these same checks. The independent checker also
requires slot 0 to match the singleton allowlist and the fallback-handler slot to
match the handler allowlist in `deployments/safe-official.json`. That JSON cites
each address's repository source; no package download or network lookup was used.
This checks the requested storage and interfaces; it is not proxy bytecode attestation.
The general gate's local-chain bypass is not used for the production rehearsal.
GToken owner, MySBT DAO, both treasuries, APNTsCapped minter and capGuardian are Safe.
Registry, SuperPaymaster and APNTsCapped ownership goes to TL through H.
AOA Paymaster and legacy uncapped aPNTs are not deployed; the checker requires zero config addresses and no deployer paymaster in the factory.

## Bytecode and execution environment

Production `CREATION_PINS` must be exactly `deployments/creation-pins.<chainId>.json`;
missing files and rehearsal paths fail before broadcast. Chain 31337 production rehearsal also requires its committed
`deployments/creation-pins.31337.json`; the legacy rehearsal file is rejected. Config records the exact file's SHA-256. The OP file is
`deployments/creation-pins.10.json`; CI independently rebuilds and compares it.
Regeneration belongs to reviewed release preparation, never automatic deployment.
Generate or check it with `python3 script/rehearsal/creation_pins.py <pin-file> [--check]`.
The tool copies source/dependencies/config to a fresh worktree-local temporary
directory, excludes existing outputs, caches and environment files, creates an
empty `out-clean`, sets `DEFAULT_ARTIFACTS_OUT=out-clean`, and builds offline.
Clean-build mode never selects a pre-existing artifact; --artifacts checks the supplied directory. Registry and the importing deployment
script use runs=200; other release artifacts use runs=500. Pins cover the exact
artifact creation bytes selected by DefaultArtifacts plus compiled H creationCode.
SuperPaymaster's pin also binds its embedded SuperPaymasterAdmin creation code.

The 25 pins are Registry, SuperPaymaster, APNTsCapped, TimelockController, H,
ERC1967Proxy, xPNTsFactory, GTokenAuthorization, GTokenStaking, MySBT,
ReputationSystem, DVTValidator, BLSAggregator, MicroPaymentChannel,
PaymasterFactory, Paymaster, X402Facilitator, PolicyRegistry, GlobalTierSource,
AOAProtocolRegistry, xPNTsTokenV2Ext, xPNTsTokenV2, xPNTsFactoryV2,
SuperPaymasterLens and xPNTsToken.

For a Prague fork, retain **Cancun release artifacts in `out`** and set
`DEFAULT_ARTIFACTS_OUT=out`, while the forge runner uses `--evm-version prague`
and a separate `FOUNDRY_OUT` and `FOUNDRY_CACHE_PATH`. The independent checker
reads the reviewed release artifacts from DEFAULT_ARTIFACTS_OUT (default out) and requires equality with the config directory.
Cancun bytes are the deployed release; Prague supplies EIP-2537 for BLS verification.
Do not let the simulation overwrite or silently replace the release artifact set.
`compare_artifacts.py <dirA> <dirB>` lists creation/runtime differences and missing
artifacts and exits nonzero for any non-test difference. Config records the artifact
directory and `DEPLOYLIVE_EVM_VERSION`; the provided fork wrapper sets the latter
and the actual forge flag together. For direct CLI use, the operator must keep them
consistent: Solidity cannot read forge's selected hardfork name.

## Fixed handover and accounting

A remaining GToken balance leaves the deployer a path back into a protocol role.
It could re-approve staking and pay the 30 GToken ticket through the permissionless
`registerRole` to register itself as COMMUNITY again. The handover therefore
transfers the entire remainder to DEPLOYER_GTOKEN_RECIPIENT.

Before TL CREATE: v5.4 CREATE/transfer/CREATE, three privilege transfers and one
unconditional GToken remainder transfer. The TL prediction is therefore +7 from
the start of v5.4. Staking allowance is already zero. Recipient pre-balance and
transferred amount are recorded, and the final exact balance delta is asserted.

The actual encoded handover list has seven role configs, one slash-admin change,
ten single-step owner transfers and three nominations: 21 calls. H's nonce is
`TL nonce + 1 + call-list.length`, currently **+22**. The observed nonce is recorded
immediately before CREATE and must match. No conditional transaction belongs here.

TL initially has delay zero, self-admin and P/E/C only for predicted H. Safe has
no TL authority. H's constructor atomically accepts three ownerships, grants Safe
P/E/C, revokes H P/E/C and sets delay 172800. Its runtime has no callable surface.
No additional funding or operational registration is permitted until checker PASS.
Genesis remains registered but not configured as a SuperPaymaster operator.

The mint ledger records count, recipients and amounts; supply must equal their sum.
The registration ledger records stakes, tickets and the treasury at payment time.
For the N=3 local production-path fixture (base units are 1e18):

| Item | GToken |
|---|---:|
| Mint 1 to deployer | 2000 |
| Mint 2 to deployer | 199 |
| Genesis PAYMASTER_SUPER stake | 50 |
| Each of three guardian DVT stakes | 30 |
| Bootstrap COMMUNITY ticket | 30 |
| Genesis COMMUNITY / PAYMASTER_SUPER tickets | 30 / 5 |
| Each guardian ticket | 3 |
| ticketsToTreasury (measured Safe receipts) | 74 |
| Deployer balance before remainder transfer | 1985 |
| deployerRemainderToRecipient | 1985 |
| Deployer final balance / staking allowance | 0 / 0 |

On production, staking treasury is set immediately after staking deployment, before
any registration; SP treasury is set immediately after its proxy deployment. Neither
is set again in handover. Tickets do not reduce supply. Conservation is
2199 = 140 locked + 74 ticketsToTreasury + 1985 deployerRemainderToRecipient
= GToken.totalSupply(). A distinct recipient receives only 1985; when recipient is
Safe its final balance is 2059, of which 74 arrived during registrations. GToken owner is Safe; deployer mint is rejected.
Checker also reconstructs every mint from zero-source Transfer logs.

## Failed set: abandon and redeploy

Genesis COMMUNITY/PAYMASTER_SUPER and guardian DVT registrations, validator
admission, public keys/PoPs and threshold configuration stay before H because they
need the pre-handover owner. A reverted H CREATE leaves no H code and no external
party able to propose or execute via TL: predicted H alone retains P/E/C.
There is no recovery procedure. The failed set is **ABANDONED**, never published.

Retain the normal checker FAIL and the separate inventory tool's registration rows. Also run
`deploylive_failed_set_check.py <local-fork-rpc> <failed-config>`. The external list
is [inputs/external-tokens.json](inputs/external-tokens.json), selected by
`eth_chainId`; the rehearsal inputs explicitly set `EXTERNAL_TOKENS_FILE`. Labels
and decimals are explicit metadata, never inferred from `symbol()`. The OP group
contains native USDC, USDC.e, bridged USDT, USDT0, DAI, WETH and OP; Sepolia
contains Circle USDC and both specified WETH deployments. Unknown chains and
empty groups FAIL. Pass `--external-tokens <worktree-file>` to failure mode. It writes the supplied
groups into the abandoned config as `externalTokens`. The committed 31337 group uses inherited OP tokens; empty-chain tests supply deployed mock tokens instead.
Every listed address must have code before any balance call; missing code FAILs
and its balance is never read. Every listed token is read directly against every
contract in the failed set and must return an ABI uint256 equal to zero. Empty,
malformed or reverted reads FAIL. The Transfer scan remains a fallback for
unlisted tokens. It reads each
recorded contract's ETH balance, discovers incoming Transfer-emitting tokens from
the recorded `deploymentStartBlock`, reads balances for every discovered token/holder,
and permits positive balances only for this set's GToken/APNTsCapped. It prints
historical and current registrations and the abandoned addresses. Any incomplete
RPC read fails the inventory; an inventory PASS never accepts the deployment.
Nonstandard tokens that change balances without Transfer events are outside this
log-discovery method; an independently complete external-token inventory remains
necessary to make an unrestricted "every token" claim.

The deployment coordinator records every address as ABANDONED and notifies the DVT
node operators and Safe signers. A replacement set has a **new aggregator address**.
Send DVT operators the new release pin file/hash, chain/domain, predicted aggregator
and DVT addresses, and each guardian account/slot. Each node regenerates its PoP in
predicted-address mode, verifies the new popContext, and returns only public key and
PoP to SP's coordinator. The coordinator invalidates all old PoPs and redistributes
the replacement public input bundle to the Safe signers. Old PoPs are void for the
new aggregator. Failed-set public keys and registrations remain on chain: public
keys are public and harmless; abandoned registrations have authority only in that set.

## Rehearsal driver and evidence

Modes: `happy`, `failure`, `governance`, plus existing `prepare`, `hook`, `guard`.
Invocation: `deploylive_rehearse.py MODE LOCAL_RPC CONFIG DEPLOYER SAFE [OPERATOR] [--external-tokens FILE]`.
The mutating driver requires an Anvil fork. These modes were unit-tested only here;
no fork was available or accessed. The Solidity production fixture runs locally
with mock infrastructure/BLS boundaries, not a fork or genuine PoP validation.

Failure mode deploys with STOP_BEFORE_BOOTSTRAP=1, overwrites pendingOwner with
anvil_setStorageAt (no nonce), submits H creation at the recorded nonce, requires a
reverted receipt and absent code, inventories the failed set, and requires checker
exit 1. Governance mode impersonates Safe, schedules TL.updateDelay(172801), requires
the exact not-ready revert before 172800 seconds, advances time, executes and reads
back 172801. Run this only after the initial checker: it deliberately changes history.

No BLS secret/PoP step may run at forge verbosity >=3. The repository default is 3;
set FOUNDRY_VERBOSITY=2 explicitly. Both entry points refuse unsafe verbosity before
RPC/deployment. A key-generating rehearsal script must begin with
`REHEARSAL ONLY - never use for deploy day`. This driver does not generate keys.
On deploy day, DVT nodes generate PoPs in predicted-address mode; SP receives only
PoPs and public keys, never scalars.

Provide DEPLOYLIVE_EVIDENCE_DIR, REHEARSAL_SOURCE_RPC and REHEARSAL_BLS_SCALARS
(JSON array, explicitly [] when no secrets were used). The fixed final step runs
even on failure: recursively scan every evidence file for source RPC URL, host,
path/query fragments and scalar decimal/hex forms. Any hit fails without echoing it.
Include all forge/broadcast outputs in that evidence directory before invoking the
driver; files outside it cannot be certified by the scan.

## Reviewed external dependencies

`deployments/external-deps.10.json` records the owner-provided OP verification at
block 159689777. `external-deps.31337.json` is explicitly a fixture group. Other
chain IDs fail until their reviewed file exists. Production defaults identity and reputation to ZERO; explicit opt-in must match
the reviewed file. The validation address is recorded only, never wired to SP.
The checker obtains chainId itself and checks SP feed, EntryPoint, identity and
reputation getters, account-factory config and recorded validation address against
that file. It does not take expected dependency addresses from deployer inputs.

## Transaction counts and checker count

Transactions before H: **86 + 3N + c + a**, where c=1 if minimum threshold <3,
and a=1 when agent registries are wired. OP defaults to a=0. For N=3, c=1 this is **96**, plus H itself makes 97 broadcasts.
The explicit a=1 fixture has **97** before H, 98 including H. The agent
registry call is in Step 5, before Step 8/v5.4 and before CREATE TL. Thus the
v5.4-relative **+7** and TL-to-H **22** remain valid; default-off and explicit-on N=3 fixtures
independently count the transactions and both nonce distances. The opt-in local
forge regression uses the enabled 31337 fixture expectations.

The valid-config checker count is **172 + 2N**: **176 for N=2**, **178 for N=3**.
Relative to round 6c, there are 17 additional rows: two formerly N/A rows, pending
SBT burn, four Safe checks, six external-dependency rows, three runtime comparisons,
and the recipient authority row. N guardian rows and N+3 stake rows vary with N.
Implementation-isolation INFO-PASS rows count; ordinary INFO and fail-fast input
errors do not. Failed-set inventory has a separate result.

## Final handover assertions mapped to checker rows

This maps every assertion in `_assertHandover`, its Safe gate and
`TimelockHandover.assertFinal`. Rows are named rather than numbered so N does not
change the mapping. Existing negative probes are retained; mapping coverage does
not claim every require has an isolated mutation test.

| In-script assertion | Independent checker row(s) |
|---|---|
| SBT balance zero | deployer SBT balance == recorded (recorded must also be zero) |
| No pending SBT burn | deployer pending SBT burn == false |
| PolicyRegistry timelock / guardian | PolicyRegistry.timelock / PolicyRegistry.guardian == expected |
| TL delay 172800 | TL.minDelay == expected |
| Three two-step owners / pendingOwner zero | owner(registry/superPaymaster/aPNTs) == expected; pendingOwner(...) == 0 |
| TL self-admin; Safe P/E/C; no forbidden subject roles | TL role exact members, safe/H/deployer memberships, TL self-admin |
| Safe code, non-7702, threshold, owners excluding deployer | Safe code excludes delegation; Safe threshold/owners; Safe owners exclude deployer |
| Safe modules empty / guard zero | Safe modules empty; Safe guard zero |
| Deployer staking allowance zero | deployer GToken allowance == recorded |
| H constructor-only runtime | H runtime non-callable (prefix/length check); creation pins bind exact H |
| Facilitator and ten single-step owners | owner(each contract) == expected |
| Five gated owners equal Safe and pass threshold/code gate | owner(each contract) == expected; Safe code/threshold/owners rows |
| Minted supply | GToken mint ledger; GToken mint events == ledger; GToken totalSupply == mints |
| Each locked stake / ticket treasury | GToken stake[i]; GToken ticket ledger |
| Locked + tickets + remainder conservation | GToken conservation |
| Treasury ticket delta | GToken treasury tickets |
| Deployer GToken zero / recipient delta | deployer GToken balance == recorded; GToken recipient exact delta |
| Seven Registry role owners / deployer holds none | roleConfigs[role].owner == timelock; deployer.hasRole(role) == false |
| Empty deployer Registry role list | deployer Registry role list empty |
| No deployer DVT / reputation-source privilege | DVT.isValidator(deployer) == false; isReputationSource(deployer) == false |
| GToken owner / MySBT DAO | owner(gToken) == expected; MySBT.daoMultisig == expected |
| Both treasuries | SP.treasury / staking.treasury == expected |
| SP guardian / slash admin | SP.guardian / aggregator.slashPolicyAdmin == expected |
| Minimum/default/slash thresholds | agg.minThreshold / agg.defaultThreshold == expected; agg.slashThresholds[i] == input |
| Guardian slots | guardian[i] registered |
| Cap / minter / capGuardian | APNTsCapped.cap / minter / capGuardian == expected |
| Oracle staleness threshold | SP.priceStalenessThreshold == expected |
| Genesis registered, not configured | genesis operator has COMMUNITY/PAYMASTER_SUPER; genesis isConfigured == false |

## Remaining acceptance evidence and known gaps

The local Anvil regression is `DEPLOYLIVE_LOCAL_TEST=1 python3 -m unittest discover
-s script/rehearsal -p 'test_deploylive_local.py'`. It uses deterministic public test
BLS material, fixture infrastructure and a fixture Safe, then invokes the actual
DeployLive production/rehearsal path. The checker receives the untouched file
written by forge. **It could not run in this sandbox: loopback bind was denied.**
The main session subsequently supplied the a=1 SUMMARY quoted above; round 8 and live failure-mode inventory remain pending. Execute
these acceptance steps in the authorized parent session; the current offline
results do not authorize deployment acceptance.

The checker runtime comparison intentionally covers only Registry implementation,
SuperPaymaster implementation and TimelockController, masking compiler immutable
references. The bytecode of every other contract must be evidenced by block-explorer
source verification in the deployment runbook, with compiler settings, constructor
arguments, address and verification result recorded. H's exact creation pin remains
part of preflight; its checker runtime row is a non-callability check.

Registry/SP implementation owners remain recorded and isolated as before; this
round does not transfer them. Existing artifact, wiring and v5.5 stack checks remain
in the deployment script; the table above is the final handover assertion mapping,
not a claim of checker parity for every historical deployment helper.

Listed external-token balances cover prefunding even though Transfer discovery
starts at deployment. Unlisted tokens received before that block, or tokens without
Transfer events, remain an inventory limitation. Never call the inventory exhaustive.

Fail-first evidence is specific to named regressions and the three run-level
mutations. The suite does not establish an exhaustive mutation proof of all
historical assertions. See DEPLOYLIVE_VALIDATION.md for exact results and logs.

## Round 7b — agent registries default OFF (DSR, 2026-11-18)

OP launch uses a=0: identity and reputation inputs default to ZERO and
DeployLive does not call setAgentRegistries. The three recorded OP registries are
130 B EIP-1967 proxies owned by the unattributed EOA
`0x547289319C3e6aedB179C0b8e8aF0B5ACd062603` (nonce 3).
One implementation upgrade by that key could make isRegisteredAgent return true
for anyone. SuperPaymaster calls it in validatePaymasterUserOp for eligibility
(SuperPaymaster.sol:525/533), giving any account operator-funded sponsorship.
setAgentRegistries is onlyOwner, so removing or changing SP's pointer takes the
48 h timelock. The addresses remain recorded, non-binding information in
external-deps.10.json; expected identity and reputation are ZERO.

Production opt-in requires ENABLE_AGENT_REGISTRIES=1 and both
AGENT_IDENTITY_REGISTRY and AGENT_REPUTATION_REGISTRY to be nonzero and equal the
reviewed external-deps.<chainId>.json expectations. Nonzero addresses without
the switch, a switch with either zero address, invalid switch values, and
mismatched enabled addresses revert during preflight. OP's reviewed zero
expectations therefore prevent opt-in without a reviewed dependency-file change.
The switch and both values are logged; config records enableAgentRegistries and
the actual agentIdentityRegistry / agentReputationRegistry pointers. The checker
compares both on-chain getters against the expected file, including ZERO on OP.

**Known testnet exposure:** Sepolia live SP
`0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9` has
agentIdentityRegistry = `0x8004A818BFB912233c491871b3d84c89A494BD9e` and
agentReputationRegistry = `0x8004B663056A597Dffe9eCcC1965A193B7388713`.
Both are 130 B proxies owned by the same EOA. The rc.8 Sepolia manifest does
not call setAgentRegistries; the in-place upgrade keeps storage, so both pointers
stay set after rc.8 on the testnet. These are owner-provided findings; this round
performed no network verification.

## Original 53 checks → current names

All original checks remain; exact-target companion checks strengthen negative ownership checks.

| Original # | Original check | Current name |
|---|---|---|
| 1 | `owner(superPaymaster) != deployer` | `owner(superPaymaster) != deployer` |
| 2 | `owner(registry) != deployer` | `owner(registry) != deployer` |
| 3 | `owner(staking) != deployer` | `owner(staking) != deployer` |
| 4 | `owner(gToken) != deployer` | `owner(gToken) != deployer` |
| 5 | `owner(xPNTsFactoryV2) != deployer` | `owner(xPNTsFactoryV2) != deployer` |
| 6 | `owner(aoaProtocolRegistry) != deployer` | `owner(aoaProtocolRegistry) != deployer` |
| 7 | `owner(reputationSystem) != deployer` | `owner(reputationSystem) != deployer` |
| 8 | `owner(blsAggregator) != deployer` | `owner(blsAggregator) != deployer` |
| 9 | `owner(dvtValidator) != deployer` | `owner(dvtValidator) != deployer` |
| 10 | `roleConfigs[COMMUNITY].owner != deployer` | `roleConfigs[COMMUNITY].owner != deployer` |
| 11 | `roleConfigs[ENDUSER].owner != deployer` | `roleConfigs[ENDUSER].owner != deployer` |
| 12 | `roleConfigs[PAYMASTER_AOA].owner != deployer` | `roleConfigs[PAYMASTER_AOA].owner != deployer` |
| 13 | `roleConfigs[PAYMASTER_SUPER].owner != deployer` | `roleConfigs[PAYMASTER_SUPER].owner != deployer` |
| 14 | `roleConfigs[DVT].owner != deployer` | `roleConfigs[DVT].owner != deployer` |
| 15 | `roleConfigs[ANODE].owner != deployer` | `roleConfigs[ANODE].owner != deployer` |
| 16 | `roleConfigs[KMS].owner != deployer` | `roleConfigs[KMS].owner != deployer` |
| 17 | `isReputationSource(repSystem)` | `isReputationSource(repSystem)` |
| 18 | `isReputationSource(aggregator)` | `isReputationSource(aggregator)` |
| 19 | `isReputationSource(deployer) == false` | `isReputationSource(deployer) == false` |
| 20 | `SP.treasury != deployer` | `SP.treasury != deployer` |
| 21 | `staking.treasury != deployer` | `staking.treasury != deployer` |
| 22 | `MySBT.daoMultisig != deployer` | `MySBT.daoMultisig != deployer` |
| 23 | `aggregator.slashPolicyAdmin != deployer` | `aggregator.slashPolicyAdmin != deployer` |
| 24 | `SP.guardian != deployer` | `SP.guardian != deployer` |
| 25 | `PolicyRegistry.guardian != deployer` | `PolicyRegistry.guardian != deployer` |
| 26 | `DVT.isValidator(deployer) == false` | `DVT.isValidator(deployer) == false` |
| 27 | `TL.PROPOSER_ROLE(deployer) == false` | `TL.PROPOSER_ROLE(deployer) == false` |
| 28 | `TL.EXECUTOR_ROLE(deployer) == false` | `TL.EXECUTOR_ROLE(deployer) == false` |
| 29 | `TL.CANCELLER_ROLE(deployer) == false` | `TL.CANCELLER_ROLE(deployer) == false` |
| 30 | `TL.DEFAULT_ADMIN_ROLE(deployer) == false` | `TL.DEFAULT_ADMIN_ROLE(deployer) == false` |
| 31 | `authorizedSlashers(aggregator) == false` | `authorizedSlashers(aggregator) == false` |
| 32 | `fraudProofVerifier == 0` | `fraudProofVerifier == 0` |
| 33 | `owner(superPaymaster) != aggregator` | `owner(superPaymaster) != aggregator` |
| 34 | `owner(registry) != aggregator` | `owner(registry) != aggregator` |
| 35 | `owner(staking) != aggregator` | `owner(staking) != aggregator` |
| 36 | `owner(gToken) != aggregator` | `owner(gToken) != aggregator` |
| 37 | `owner(xPNTsFactoryV2) != aggregator` | `owner(xPNTsFactoryV2) != aggregator` |
| 38 | `owner(aoaProtocolRegistry) != aggregator` | `owner(aoaProtocolRegistry) != aggregator` |
| 39 | `owner(reputationSystem) != aggregator` | `owner(reputationSystem) != aggregator` |
| 40 | `owner(blsAggregator) != aggregator` | `owner(blsAggregator) != aggregator` |
| 41 | `owner(dvtValidator) != aggregator` | `owner(dvtValidator) != aggregator` |
| 42 | `owner(xPNTsFactory) != aggregator` | `owner(xPNTsFactory) != aggregator` |
| 43 | `owner(paymasterFactory) != aggregator` | `owner(paymasterFactory) != aggregator` |
| 44 | `owner(paymasterV4Impl) != aggregator` | `owner(paymasterV4Impl) != aggregator` |
| 45 | `owner(microPaymentChannel) != aggregator` | `owner(microPaymentChannel) != aggregator` |
| 46 | `owner(x402Facilitator) != aggregator` | `owner(x402Facilitator) != aggregator` |
| 47 | `aggregator ETH balance == 0` | `aggregator ETH balance == 0` |
| 48 | `aggregator gToken balance == 0` | `aggregator gToken balance == 0` |
| 49 | `aggregator aPNTs balance == 0` | `aggregator aPNTs balance == 0` |
| 50 | `aggregator pnts balance == 0` | `config legacy pnts == zero` |
| 51 | `generic executeProposal(batchUpdateGlobalReputation) rejected with ForbiddenGenericSelector` | `generic executeProposal(batchUpdateGlobalReputation) rejected with ForbiddenGenericSelector` |
| 52 | `generic executeProposal(slash) rejected with ForbiddenGenericSelector` | `generic executeProposal(slash) rejected with ForbiddenGenericSelector` |
| 53 | `generic executeProposal(slashByDVT) rejected with ForbiddenGenericSelector` | `generic executeProposal(slashByDVT) rejected with ForbiddenGenericSelector` |

## Source commit gate (DSR 2026-11-18)

Before every production simulation, PoP request, rehearsal or broadcast, run from
this repository root:

```sh
[ -z "$(git status --porcelain)" ] || { echo 'STOP dirty worktree'; exit 1; }
export SP_COMMIT="$(git rev-parse HEAD)"
```

Keep `SP_COMMIT` set through the final broadcast. Production requires exactly
40 lowercase hexadecimal characters and writes them to `config.commit`.
The checker adds one `source commit` PASS/FAIL row: non-31337 chains require a
valid commit equal to HEAD and a clean worktree. On 31337, a non-empty commit
has the same requirements; an empty commit is exempt. Ignored evidence files
do not make the worktree dirty. Both deployment drivers refuse dirty trees
before RPC access and derive `SP_COMMIT` from HEAD themselves.

## DeployLive PoP request and DVT export conversion

1. Fix ALL inputs before generating the PoP request; freeze the final SP head and deployment inputs. At the selected pin block,
   simulate DeployLive with `SP_COMMIT="$(git rev-parse HEAD)"` and
   `DEPLOYLIVE_POP_REQUEST_OUT=cache/deploylive-prediction/pop-request.json`. Keep the same deployer and nonce
   for the subsequent deployment. `GUARDIANS` may be absent in this mode; all
   other production preflight inputs remain required. The script actually
   deploys through DVTValidator and BLSAggregator in simulation, writes their
   observed addresses and Registry, then stops before wiring/registration.
2. Send that request to DVT. It is schema `deploylive-pop-request/1`.
   `pin.block` and `pin.blockHash` name the same block: the PARENT of the simulated block, because EVM BLOCKHASH cannot read the current block. `pin.senders.deployer.nonce` is the deployer nonce at entry to `run()`. If the deployer sent a transaction in the latest block, a nonce read at `pin.block` differs and DVT refuses (fail-closed), so the operator re-runs the simulation. DVT can check `getBlock(pin.block).hash == pin.blockHash` directly.

   ```sh
   python3 script/rehearsal/dvt_pop_to_guardians.py "$DEPLOYLIVE_EVIDENCE_DIR/dvt-export.json" "$DEPLOYLIVE_EVIDENCE_DIR/pop-request.json" --sp-root . --inputs "$INPUTS"
   ```

   The converter prints both input SHA256 values to stderr and emits only
   `abi.encode(GuardianInput[])` to stdout, and writes `guardians.hex` plus the
   manifest-bound `conversion.json` in the evidence directory. Any named `STOP` exits 3. It checks
   the pinned source blob using read-only `git show`, the local source version,
   the domain, exact export keys, metadata, canonical calldata, slots and
   distinct accounts. `popDigests` is count-checked; curve membership and PoP
   validity are verified by the aggregator on chain, not by this converter.
5. Repeat the source commit gate above, unset `DEPLOYLIVE_POP_REQUEST_OUT`, and run
   `python3 script/rehearsal/deploylive_fork_deploy.py deploy --inputs "$INPUTS" --production`
   with the same deployment inputs and artifacts,
   and **no intervening deployer transaction**. If the nonce or inputs move,
   discard the request and PoPs and repeat from step 1.
6. Record `sha256sum "$DEPLOYLIVE_EVIDENCE_DIR/pop-request.json" "$DEPLOYLIVE_EVIDENCE_DIR/dvt-export.json" "$DEPLOYLIVE_EVIDENCE_DIR/guardians.hex"` (or
   `shasum -a 256 ...`) with the final head, deployment inputs and evidence.

Prediction rejects Foundry `vm.isContext(ScriptBroadcast)` and
`vm.isContext(ScriptResume)` before `startBroadcast()`. It does not infer a
live send from `startBroadcast()` itself: Forge dry runs also use that call.
An empty request path disables prediction. The prediction artifact is not a
completed deployment config or acceptance evidence.

The synthetic comparison files are in `fixtures/dvt-pop/`. They use only
GenuineBLS public scalars 1/2/3, never production keys. Regenerate and compare:

```sh
forge test --offline --evm-version prague --match-contract DeployLivePopSyntheticTest
python3 script/rehearsal/test_dvt_pop_to_guardians.py --write-synthetic-fixtures
python3 -m unittest discover -s script/rehearsal -p test_dvt_pop_to_guardians.py
forge test --offline --match-path 'contracts/test/scripts/DeployLive*.t.sol'
```

Use separate Forge output/cache directories for Prague fixture generation if
preserving already-reviewed Cancun artifacts. The prediction test snapshots
and restores EVM state, then runs the normal production harness from the same
nonce and compares all three addresses. Its cryptography is mocked by the
existing orchestration fixture. The separate synthetic test executes the real
BLS precompiles under Prague and calls DeployLiveLocalBundle for the byte-exact
GUARDIANS control. No Anvil or RPC is required for these unit tests.
