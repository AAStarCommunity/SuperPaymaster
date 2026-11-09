# Timelock reader review — DSR follow-up, 2026-11-05

This supersedes the reader-impact and unresolved classification notes in
`OLD_TIMELOCK_CORRECTION.md`. Review is offline: no RPC role measurement or live
wiring claim is made. Canonical means the A3a S2 timelock `0xccdf…c34b`; legacy
means `config.sepolia.json.timelockControllerLegacy` (`0x86c8…9564`).

## Reader table

Broadcast means a transaction-producing path exists, including local fork paths;
read-only scripts remain “no” even if a caller passes `--broadcast`.
The inventory covers direct key reads, inherited readers and shell callers, plus
writers and synthetic tests that can otherwise be mistaken for readers.

| File | Can broadcast? | Effect of canonical value change / final behavior | Timelock actually needed |
|---|---|---|---|
| `contracts/script/v3/UpgradeViaTimelock.s.sol` (`D5bUpgradeChecks._cfg`, `UpgradeViaTimelock`, `UpgradeRegistryD5b`) | Yes | Former TIMELOCK fallback silently changed to A3a. Now a config containing the legacy key rejects an absent/zero explicit TIMELOCK before any mode runs. Pre-M1 Registry/direct upgrade modes also require explicit selection, although they do not call the timelock. | Explicit selected governance timelock; current production is A3a through Safe. Historical/local runs must select their own address. |
| `contracts/script/v3/UpgradeLive.s.sol` | Yes | Previously would retain A3a and use it as the constructor argument for a missing PolicyRegistry. Now rejects migrated configs before chain reads or broadcast. No implicit target or constructor-wiring change. | Original EOA/bootstrap deployment context; migrated Sepolia requires a separately reviewed Safe/deployment flow. |
| `contracts/script/checks/Check10_V54.s.sol` | No | Code checks and PolicyRegistry binding now assert canonical A3a. A PolicyRegistry still bound to legacy fails visibly; this check does not migrate it or silently accept old wiring. | Current canonical governance target. |
| `contracts/script/checks/CheckDefaultArtifacts.s.sol` | No | Checks A3a runtime, aPNTs owner/delay and PolicyRegistry canonical binding. Recognizes legacy key as historical address inventory only (nonzero and distinct); no current-runtime assertion on historical code. Unknown keys still fail. | Canonical for live governance assertions; legacy only as historical reference. |
| `scripts/a3a-snapshot.mjs` | No | Former hardcoded old target now explicitly reads `timelockControllerLegacy`; header marked LEGACY. | Old timelock for pre-A3a snapshot. |
| `scripts/a3a-v2-snapshot.mjs` | No | Same explicit legacy read and header; canonical change has no effect. | Old timelock for historical precheck. |
| `scripts/a3a-v2-fork-sim.sh` | Yes, local fork | OLD_TL now comes explicitly from legacy key; fresh NEW_TL remains an explicit argument. Header marked LEGACY. | Old for historical isolation; fresh fork deployment for the A3a simulation. |
| `script/evidence/d5b-fork-rehearsal.sh` | Yes, local fork | TL now explicitly reads legacy key; fscript_tl passes TIMELOCK explicitly. Canonical config change cannot redirect historical schedule/execute. Header marked LEGACY. | Historical old timelock (fork role changes); separate FRESH_TL for capped-token rehearsal. |
| `script/evidence/a2-full-rehearsal.sh` | Yes, local fork | OLD_TL inventory reads legacy key explicitly; transaction wrapper already passes its fresh TL explicitly. Header marked LEGACY. | Old inventory reference and newly deployed rehearsal TL. |
| `script/evidence/check-default-artifacts-sepolia-fork.sh` | No | Invokes CheckDefaultArtifacts on canonical Sepolia config; inherits its current wiring checks and resolved legacy-key classification. | Canonical. |
| `scripts/d5b-anvil-rehearsal.sh` | Yes, local Anvil | Writes its own synthetic timelockController config and invokes UpgradeViaTimelock. Does not read Sepolia key; unaffected. | Fresh local timelock. |
| `scripts/check-live-scripts-compile.sh` | No | Compiles scripts only; does not execute config readers. | None. |
| `contracts/test/scripts/CheckDefaultArtifacts.t.sol` | No | Synthetic config uses a locally deployed Safe-only timelock; added legacy-key classification positive and named negative tests. | Local fixture, not Sepolia. |
| `contracts/test/scripts/TimelockConfigSelection.t.sol` | No | New offline tests read Sepolia config to assert implicit selection fails, explicit canonical/legacy selection works, and UpgradeLive rejects before broadcasting. | Both addresses as data only. |
| `contracts/test/v2/D5bTimelockPreflight.t.sol` | No | Calls UpgradeViaTimelock helpers with synthetic Cfg/role fixtures, not Sepolia fallback. Existing Safe-role/attestation negative controls remain applicable. | Local fixtures. |
| `contracts/test/v2/D5bScriptsCompile.t.sol` | No | Imports script types for compilation; no Sepolia key read. | None. |
| `script/upgrade/old_owner_isolation.py` | No | Reads committed config for immutable aliases; does not consume canonical timelock key. OLD_TIMELOCK is an intentionally retained isolation constant. | Old timelock for historical isolation. |
| `script/upgrade/test_old_owner_isolation.py` | No | Committed-config alias fixtures; no canonical-key target selection. | Old isolation fixture. |
| `contracts/script/v3/DeployLive.s.sol` | Yes | Writer only: writes its freshly deployed timelock, never selects one from this key. | Fresh deployment. |
| `contracts/script/v3/DeployAnvil.s.sol` | Yes, local | Writer only; unaffected. | Fresh local deployment. |
| `contracts/script/v3/DeployV54.s.sol` | Yes | Writer only; unaffected by changing input value. | Fresh deployment. |

Historical tools are retained for reproducibility, not deleted. Their LEGACY
headers identify their scope; none is relabelled as a current production runner.
Other readers of the Sepolia JSON use other fields or copy the JSON as data; they
do not select a transaction target from this field.

## Broadcaster and Safe assumptions

Supplied A3a S2 arguments: PROPOSER = CANCELLER = EXECUTOR =
`[0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114]`, DEFAULT_ADMIN = `[timelock itself]`,
minDelay = 172800. These are supplied provenance, not a fresh offline chain claim.

UpgradeViaTimelock's six schedule/execute modes already run operator preflight:
manifest consistency, 48-hour delay, Safe P/C/E, self-admin, no open executor,
known-account exclusions and role-history attestation. For proposer/executor not
equal to Safe they print Safe calldata and return; when equal they call
`vm.startBroadcast(proposer/executor)` and schedule/execute. A contract Safe cannot
sign an EOA transaction: `--sender Safe` is suitable for local impersonation, not
production authorization. Production submission must use the Safe transaction
flow. Explicit TIMELOCK is address-selection opt-in only; it bypasses none of
these role or attestation checks. Old EOA-role timelocks do not become valid under
this Safe-only preflight merely because they are selected explicitly.

The new selection failure says:
`TIMELOCK required after migration: A3a is Safe-only; EOA cannot schedule/execute`.
UpgradeLive fails with:
`UpgradeLive: migrated timelock config; use reviewed Safe upgrade/deployment flow`.

## Address gate and classification decision

`script/upgrade/test_no_legacy_timelock.py` scans working-copy contents of every
git-tracked file (gitlinks are not blobs), case-insensitively, including binary
content. Only exact legacy-field/OLD_TIMELOCK assignments, historical docs/design
paths and individually reasoned allowlist paths are exempt. Release records are
listed individually in `script/upgrade/legacy_timelock_allowlist.json`; there is
no blanket docs/release exemption. Symlinks are scanned as link text. The gate
refuses tracked `.env` files without opening them; tracked example templates are
ordinary source inputs. No actual `.env` was read or sourced.

CI now runs on every PR and main push, because a forbidden address can be added
outside the old workflow path filters. The gate includes named controls:

- `test_negative_injected_occurrence_in_temp_copy` (lowercase, uppercase, mixed case).
- `test_negative_canonical_field_not_exempt` (legacy field cannot hide a canonical occurrence on the same line).
- `test_negative_release_source_not_blanket_exempt`.

CheckDefaultArtifacts uses the least invasive schema change: classify the one
documented historical key with nonzero/distinct-address checks. No broad unknown
key exemption and no forced current-artifact match for a historical deployment.
Named Solidity negatives cover identical canonical/legacy addresses, unknown
keys, missing explicit TIMELOCK, and UpgradeLive's pre-broadcast rejection.

## Offline validation

Results are recorded below after running the focused checks. No commit, push,
RPC query, live script execution or broadcasting is part of this review.

| Command / control | Result |
|---|---|
| `python3 -B script/upgrade/test_no_legacy_timelock.py` | 4 passed, including all three named negatives; full tracked-file scan passed. |
| `/Users/jason/.foundry/bin/forge test --offline --match-path contracts/test/scripts/CheckDefaultArtifacts.t.sol` | 18 passed, 0 failed, 0 skipped. |
| `/Users/jason/.foundry/bin/forge test --offline --match-path contracts/test/scripts/TimelockConfigSelection.t.sol` | 5 passed, 0 failed, 0 skipped. |
| `/Users/jason/.foundry/bin/forge test --offline --match-path contracts/test/v2/D5bTimelockPreflight.t.sol` | 35 passed, 0 failed, 0 skipped. |
| `node --check` on both edited snapshot scripts; `bash -n` on all three edited rehearsal scripts | Passed. No script was executed against RPC. |
| Address scan of the four new, not-yet-tracked deliverables using the same scanner | Passed. They will join the tracked scan when staged by the owner. |
| `git diff --check` | Passed. |

Forge was absent from PATH, so its installed absolute path was used. Initially
missing Chainlink/Solady dependencies caused compilation failure; despite
`--offline`, Foundry attempted submodule installation, which failed at local git
metadata permissions before cloning. No dependency was downloaded. Tests then
compiled successfully using source copied locally from the owner's existing
SuperPaymaster checkout: Solady `90db92ce173856605d24a554969f2c67cadbc7e9` and
Chainlink `6e324d8ad9fbb5519186ad9f1eaf99704de4c915`, both exactly matching this
worktree's gitlinks. Only dependency source trees were copied, excluding `.git`
and environment files. Foundry still emitted the failed auto-install warning,
but all three final suites compiled and passed using local Solc 0.8.33. Logs:
`/tmp/oldtl-artifacts-test.log`, `/tmp/oldtl-selection-test.log`,
`/tmp/oldtl-preflight-test.log`, `/tmp/oldtl-scan-test.log`.

These are local unit/negative controls, not proof of current Sepolia contract
state. Read-only wiring checks intentionally still fail if a live PolicyRegistry
or token is bound to a different timelock than the canonical config.
