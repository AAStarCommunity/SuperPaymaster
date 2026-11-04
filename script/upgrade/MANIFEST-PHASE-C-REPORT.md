# Manifest Phase C (funding and sampling configuration) — executor report

Branch `cloud/phase-c-executor`, base `origin/main` `7f0a0f4b`. Scope: MANIFEST-DESIGN.md §3 "Phase C — funding and
sampling configuration (after 6d)" with the related §2 preconditions, §4 nonce/budget/timing, §6 STOP conditions and §7
controls. Nothing was signed or broadcast; no public RPC was contacted. All tests are offline; the only chain used is a
local, non-forked anvil with its default account (comparator check below).

## Design-row mapping

| Design | Executor |
| --- | --- |
| C1 Safe mint `(D, delta_m)`, Safe nonce after 6d | `C1_approve` / `C1_exec` (A approves, E executes, `safeTarget = APNTsCapped`), hash `safe_hash(inner, n, capped)` checked on chain in `pre_send`; read-back: D balance, supply, cap, minter |
| C2 approve + deposit | `C2.approve`, `C2.deposit`; read-back: allowance, `operators(D).aPNTsBalance == AD`, tracked/SP token +delta_A, revenue 0.1, allowance consumed |
| C3 deploy + configure | `C3.deploy` (X = factory's first clone, EIP-1167 runtime, all factory/initializer bindings, metadata), `C3.configure` (exact 9-field `operators(D)` before/after) |
| C5 createAccount | `C5` (omitted iff S already exists and matches owner/EP/implementation/runtime at the pin) |
| C6 / C7 ENDUSER | `C6`, `C7` (omitted iff S already has role + MySBT membership + SP status; mixed status is STOP) |
| C8 mint X | `C8` (zero debt/lock/reservation, policy OFF, no pending ETA) |
| C20 fund O | `C20` before `C9.*` (design execution order) |
| C9 three O→S→X calls | `C9.allowance`, `C9.total`, `C9.mode` (sender O, own nonce sequence) |
| C10–C15 comparators | `C10` T, `C11.S`/`C11.R`, `C12` VPM, `C13.token` Q, `C13.oracle`, `C14` TPM (exact tuple constructor), `C15` |
| C16 stakes | `C16.vpm`, `C16.tpm` (1 ETH, 86400 s) |
| C17 EP deposits | `C17.sp`/`.vpm`/`.tpm` (SP from the post-A13 balance; zero deficit omitted) |
| C18 mint + approve | `C18.mint` (D), `C18.approve` (O→S→Q) |
| C19 fund B | `C19` |
| Funding worksheet | `phase_c_worksheet` → `plan.phaseC` (every quantity; integer `ceilDiv` exactly as written) |
| §2 / §6 chain preconditions | `collect_phase_c` pin reads + `phase_c_pin_gates` (offline) + `phase_c_pre_send` (live) |
| §4 nonces / budget | shared counters + O counter; `budget_deployer_values` at build; calibrated `budget` with exact shortfall; O = pin + C20 vs measured gas + maintenance |
| §4 timing | `C_after_activation` (6d and B4 passed), `C_after_token_eta` (block time ≥ `pendingAPNTsTokenEta`); Phase D handover requires every C step |
| §6 SP-attempt STOPs | `sp_attempt_precheck` (SP_RENEW, renewal mode, caps == frozen L, `L-used ≥ Amax` both counters, price, one recorded block). **Exported helper, run once at the end of Phase C; the sampler is not wired yet** (the A6 collector does not call it; per-attempt wiring is a pilot blocker) |
| §3 "a later discrepancy is STOP" (omitted rows) | `funding_gate`: every funding target re-read at the end of Phase C and before each Phase D handover step |
| §3 post-pilot recompute (M_j/Amax/buffers from consumed attempts, 20-attempt pilot cap, forced new packet) | **not implemented — pilot/formal tooling** |
| §4 sequencing pilot → recompute/read-back → G3 freeze → formal | **not implemented — pilot/formal tooling** |
| §7 controls | 13 reverted-snapshot controls (`PC_CONTROLS`), unit controls for every other gate |
| Stages | `--stage c` (stops after Phase C, `stage-c.json`, never final) |

## Evidence (committed under `docs/release/sp-upgrade-a6e/phase-c-evidence/`)

- `test_manifest_exec.log`, `test_a3a_exec.log`, `test_sp_upgrade_exec.log`, `test_pop_adapter.log`,
  `test_release_evidence.log`, `test_manifest_phase_c.log`: full runs on the final tree.
- `probe_phase_c_gates.log`: gate-removal probe table.
- `rebuild-baselines-real.json`: a real offline `rebuild_baselines` run (Forge 1.7.1, solc 0.8.33) at `7f0a0f4b`:
  F1TestToken has two `MINTER` ranges; both committed sample artifacts match their archived sources, and their
  constructor ABIs equal the design's signatures.
- `local-phase-c-comparators.json`: `local_phase_c_comparators.py` on a plain local anvil with that real bytecode and a
  locally compiled v0.7 EntryPoint: C10–C18.mint sent at their planned nonces. CREATE addresses equal the predictions,
  the offline-derived F1 runtimes match deployed code byte for byte, TPM `cachedPrice == 1e26`, and stake/deposit
  read-backs hold. VPM/TPM runtime hashes are immutable-dependent, so they must be pinned per packet (`runtimeKeccak`).

This is not a fork rehearsal on a real pin: SP/X/Registry rows are exercised only by unit fakes.
