# Sepolia rc.8 manifest window: presence schedule and automation pauses (DRAFT, 2026-11-18)

Sources:
- `script/upgrade/manifest_exec.py` (`bind_timing`, the step list, the senders); the full plan was
  built offline from the `ManifestTests` fixture with its timeline printed.
- Read-only Sepolia reads at blocks 12159283–12159299 (Alchemy; the eta was cross-checked on Tenderly).

The fixture's 718 h wait before activation comes from the fixture's own `pendingAPNTsTokenEta`. On
Sepolia, `SP.pendingAPNTsTokenEta() = 1794226596` is already in the past, so it adds no wait.

## Presence schedule (T0 = first transaction; each "earliest" is the previous wait + 48 h)

| When (earliest) | Keys needed | Steps |
|---|---|---|
| T0 | deployer keystore; Anni; Safe approver (`0xe3d2…008d`) and executor (`0xf7bf…642c`) | A1–A17 (deployer; A17 = `SP.transferOwnership(TL)`), A15.anni, `upgrade_schedule` approve+exec, `upgrade_execute` approve |
| T0 + 48 h | executor and approver | `upgrade_execute_exec`, B2a approve+exec (Safe mints the SP buffer) |
| T0 + 96 h | approver and executor | `activation_schedule` approve+exec, `activation_execute` approve. The 48 h comes from `queueGasParams` in the upgrade batch (gas_eta = upgrade execute + 48 h) |
| T0 + 144 h | executor, approver, deployer keystore, Phase C account owner | `activation_execute_exec`, B4 (deployer; absent if the fraud switch is off), C1 approve+exec (Safe), C2–C20 (deployer), C9.* and C18.approve (account owner), `D.registry.transfer` (deployer), `D.registry_schedule` approve+exec, `D.registry_execute` approve |
| T0 + 192 h | executor, deployer keystore | `D.registry_execute_exec`, then D.protocol / factory / aggregator(.admin) / dvt / committee / old_aggregator transfers (deployer) |

Every Safe step is an approveHash by the approver followed by execTransaction by the executor:
both signers are needed at each row that lists them. The deployer keystore password is typed by
the author at send time.

**Upper bounds and stop conditions.** I found no expiry on the TimelockController operations
(OZ v5.0.2 has none) or on the Safe approvals. Nothing in `manifest_exec.py` sets a deadline by
time. The run can still STOP on state that drifts during the window:
- Every transaction is signed with `maxFeePerGas = 20 gwei` (`a3a_exec.MAX_FEE`). The Sepolia base
  fee was 18 wei at read time. A base fee above 20 gwei stalls inclusion.
- Phase C reads `cachedPrice` at every transaction and requires 0 < price ≤ $3,500
  (`PC_PRICE_CAP`), with 8 decimals. ETH above $3,500 stops Phase C.
- The pinned nonces of deployer, approver, executor, Anni and the account owner, and the pinned
  Safe nonce: any outside transaction from these keys stops the run.
- The frozen-config checks re-read pinned state (operators, roles, pause flags) between steps.

## Automations during the window

| Automation | Key | Conflict | Action |
|---|---|---|---|
| SP price keeper (`updatePrice()`, hourly) | `0xc2dF42897a186e268ee4f1F4aB041DD6557AeB1e` (its own key; not deployer) | None. The plan does not pin `cachedPrice`; it only bounds it at Phase C | **Keep it running.** Stopping it breaks live users after `priceStalenessThreshold` = 4200 s (validUntil = updatedAt + 4200, so UserOps are rejected) and would also stop Phase C |
| Anything signing with the deployer `0xb560…df0E` (old SDK keeper mode, e2e/gasless tests, prepare-test, cloud routines using PRIVATE_KEY) | deployer | Consumes the pinned deployer nonce | Pause for the whole window |
| Anything signing with the Safe owners (approver/executor), Anni or the Phase C account owner | those keys | Pinned nonces; for Safe owners also the Safe nonce | Pause; the Safe sends nothing outside the plan |
| DVT keeper daily task (report + permissionless pause) | DVT node keys | A pause of SP / an operator changes state the frozen checks read, and fights the activation batch's unpause | Pause the pause action (reporting may continue) |
| Guardian / PolicyRegistry pause actions | guardian keys | Same as above | Do not use during the window except in an emergency; an emergency pause means abort and re-pin |

Open: I could not enumerate every cron or routine that uses the deployer key from this repo
alone. The author should confirm the list.

## When the run stops

The live sender is #602 `manifest_send.py`, not merged yet. It signs each step at send time
(`cast mktx`); the fee cap comes from the frozen packet. A resume uses `--first <step>`, and every
earlier step must be proven on both endpoints by its `sent.json` record. Executed timelock steps
stay done: they are on chain.

| Stop | What to do |
|---|---|
| Base fee above the packet's 20 gwei cap | Wait. The nonces have not moved, so resume with `--first` at the same step. No re-pin |
| ETH above $3,500 (Phase C `C_price_bound_exec`) | Wait until the price is back under the cap, then resume at the same step. Raising the cap is a code change plus review, not an on-the-spot action |
| A stray transaction from a pinned key (deployer, approver, executor, Anni, account owner) or from the Safe | Every later planned step of that key fails its nonce gate. The plan is built from a pin of the pre-A state; I have not found support in `build_plan` for re-pinning from a partly executed state. **Open:** decide before deploy day how a re-pin after partial execution works (or that it means a fresh set). Until then the rule is: no transaction from any pinned key during the window |
| `send_live_gas_repin` (estimate > limit/1.1) | Re-pin (sender rule); same open question as above if it happens mid-run |

## In-repo entry points that read the deployer key

- **CI:** none. No workflow has a deployer or private-key secret. The only scheduled workflow is
  `vendored-drift.yml`, which uses GITHUB_TOKEN only.
- **Batch / test runners that sign with PRIVATE_KEY:**
  - `script/gasless-tests/*.js` (run-all-tests.sh, setup-gasless.js, mint-tokens.js,
    transfer-tokens.js, test-case-*.js, test-group-*.js, test-x402-*.js,
    test-micropayment-channel.js, test-bls-permissionless-switch.js);
  - `scripts/gasless-test/*.js`;
  - `script/v3/test-e2e.js` and `test-local.sh`;
  - `scripts/v3.1_e2e_verification.js`.
- **Deploy / prepare:** `deploy-core`, `scripts/deploy-core.sh`, `prepare-test`,
  `run_full_regression.sh`, `deploy-sepolia.sh`, `scripts/deploy/*.sh|*.js`,
  `scripts/final_wiring_sepolia.sh`, `scripts/verify-all.sh`.
- **Evidence and rehearsal:** `script/a6-collector/rehearsal-window.sh`,
  `script/evidence/a2-full-rehearsal.sh`, `d5b-fork-rehearsal.sh`, `d7-*.sh` and
  `a3a-live-step.UNREVIEWED.py`. Most of these target forks; confirm before running.
- **Every forge script** under `contracts/script/**` that calls `vm.envUint("PRIVATE_KEY")` (about
  60, all manual).
- `deprecated/scripts/*` (about 80, manual, obsolete).

Outside this repo (the author to complete): the SDK keeper modes that use the deployer, cloud
routines, Mini or nicolas-mini cron jobs, DVT-side scripts.

## CORRECTION (2026-11-18): live service impact during the window

- From T0+48h (upgrade executes) to T0+144h (activation executes), the live SP is globally
  paused by design: the upgrade batch is `upgradeToAndCall(impl, setGlobalPaused(true))`
  (manifest_exec.py:2309), and the activation batch ends with `setGlobalPaused(false)`. There is
  no testnet sponsorship for about 4 days.
- A14 pauses the operators in pauseList at T0.
- The keeper must still run (Phase C, and immediate service after activation).

## Abort by boundary (T0 segment)

| Abort point | On-chain state | Cleanup |
|---|---|---|
| After A1–A5, before A6 | Only new contracts deployed; the live system is untouched | Abandon them; re-pin |
| A6–A13 | Registry upgraded in place; BLS aggregator pointers and reputation sources may be switched; extra ETH may be staked or deposited; SP still 5.4.2 | The deployer still owns everything and can revert the pointers or continue. **Unverified:** that the new Registry with the old SP 5.4.2 serves live traffic. Needs a fork control (stop after A13, run a live operator UserOp) |
| A14–A16 | Additionally: pauseList operators are paused, operator balances withdrawn | The deployer (still SP owner) can unpause and re-deposit |
| After A17 | The SP owner is the TL | Any SP fix goes Safe → TL with 48 h; paused operators stay paused for at least 48 h. A17 is a point of no return |
| After upgrade_execute (T0+48h) | New SP implementation, globally paused | Forward only: activation, or a separate Safe→TL unpause (48 h each) |

## Design principle for the (i) series (DSR 2026-11-18)

- Every deployer CREATE is in the T0 segment. New CREATEs are appended after A12a. A7.dvt stays
  before A7; notify DVT of the address shift.
- The five Phase C CREATEs (C10, C12, C13.token, C13.oracle, C14) can move to the end of the T0
  segment: their constructors do not depend on upgrade or activation state. Moving them needs:
  - a phase tag outside 'C' (the C_after_activation gate);
  - `phase_c['addresses']` derived from the T0 nonces;
  - the budget and calibration moved with them.
- With those changes, the deployer's no-touch zone is the T0 segment only.

## Operators during the window (Sepolia, inventory block 12158965)

- Configured operators:
  - Anni `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9`
  - deployer `0xb5600060e6de5E11D3636731964218E53caadf0E`
- Other PAYMASTER_SUPER holders, never configured and unattributed:
  - `0xF92DC383c74eA30d7791b929d5872daD18679516`
  - `0x2e72A258FD9e1C69B2B2bB6ED8bC7E94773f7b00`
  - `0x368f8Cb8cCA42174B03156cEa761BaE31cEE5C94`
- pauseList = all five. A14 pauses every one of them at T0. In 5.4.2, `configureOperator` does not
  clear `isPaused` and validation rejects paused operators, so none of them can sponsor in the
  window.
- Activation unpauses only `sampled` (deployer in DRYRUN4–6). **Anni stays paused after rc.8**
  until a separate Safe→TL unpause (≥48 h), and its balance must be re-deposited. The author must
  confirm this is intended.
- Residual path: a brand-new address registers PAYMASTER_SUPER + COMMUNITY permissionlessly and
  configures itself (not paused) → it can sponsor with its own aPNTs on the intermediate state; the
  frozen checks then stop the plan. To verify on the Sepolia fork control.
