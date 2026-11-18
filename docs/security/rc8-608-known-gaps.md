# #608 split — known gaps (proof machinery not landed in rc.8)

#608 (`cc125/old-timelock-never-granted`, last on `cc125/rc8-l10-endpoint` @ `bb9ac9af`) lands in rc.8
only as the code that the Sepolia manifest executes, plus that code's tests:

- **PR-2:** the COMMIT 6e gate renames.
- **PR-3:** COMMIT 6f–6i, executor integrity before signing.

Two other kinds of material stay out of `main`:

- **Generated or result material** (`COMMIT6_RESULTS.md`, `fixtures/gate-producer-compile.json`,
  `run_all_6j.sh`, probe outputs) stays on `cc125/rc8-l10-endpoint` @ `bb9ac9af`, referenced by
  sha256.
- **Machinery that exists only to prove other gates** is not landed. The table below records it.
  Each row states:
  - which guarantee is missing;
  - what covers the gates instead;
  - why rc.8 can ship without it.

Common reason: none of this machinery runs on deploy day. The gates it proves are on `main` and run
on deploy day. The offline suites, the dry run and the Sepolia fork rehearsal execute them.

| Item | Missing guarantee | What covers instead | Evidence on `bb9ac9af` (sha256) |
|---|---|---|---|
| **6e rename proof and per-gate deletion probes** (`gate_rename_ast_diff.py`, `gate_name_flow.py`, `gate_templates.json`, `gate_finite_domains.json`, `gate_typed_probe_results.json`, `test_gate_*_controls.py`, `probe_*`) | A machine proof that the tree is AST-identical except at the declared gate-name positions. Plus, for each renamed gate, that deleting it turns a named test red. | `script/upgrade/test_gate_name_hygiene.py` (PR-2, run in CI by `a3a-executor.yml`) on top of the static scanner `script/upgrade/gate_name_scan.py`, over all 12 executor modules (`gate_name_scan.runtime_files()`):<br>(a) the per-name count of the 43 names raised more than once is frozen (all predate 6e); a new repeat or a grown count fails;<br>(b) the 59 names (48 literals, 11 prefixes) replaced between `4029a23e` and the PR-2 head (`gate_names_replaced_pr2.json`, produced by `gate_name_scan.py --write-replaced`; a test asserts the generator's output equals the committed file) survive nowhere as literals in executor code, tests or workflows; every name a consumer compares a caught gate against is exactly producible, and the three consumers matched only through a producer prefix are frozen; every use of a caught gate name must be a form the scanner understands (a comparison, `need`, or a frozen pass-through form), anything else fails;<br>(c) every `rpc_result_*` site passes a unique literal, the 89 sites are pinned, and `typed()` reports the name it is given.<br>The three frozen records (`gate_name_frozen.json`, `gate_names_replaced_pr2.json`, `gate_renames_pr2.json`) are pinned by sha256 in the test.<br>`probe_phase_c_gates.py` excludes only the 77 frozen renames in `gate_renames_pr2.json` (name, file, defining function, base name); `gate_rename_map.json` no longer widens the exclusion.<br>`probe_gate_name_hygiene_mutants.py` (also in CI) re-applies the review's seven mutations to copies; it requires a green baseline, counts only the named test's assertion failure (an ERROR never counts) and exits non-zero otherwise.<br>The four renamed dynamic prefixes have named-STOP tests in `test_manifest_exec.py`. The existing offline suites are green on the renamed tree. | `gate_templates.json` 002794eb…8e65<br>`gate_rename_ast_diff.py` 49fc7534…14a4<br>`gate_name_flow.py` 44480d37…6b57<br>`gate_finite_domains.json` 55df5829…c5ad<br>`gate_typed_probe_results.json` 0dd70645…ce51<br>`test_gate_template_controls.py` 2a10e3c1…68f7 |
| **Names the scanner cannot resolve** | A check of names that are runtime data. 46 producer sites pass a name the scanner cannot resolve to a literal or prefix (33 in `a3a_exec.py`, mostly `label + ...` built from a caller value; 8 in `manifest_exec.py`); their names take no part in the repeat count. 181 prefix producers end in runtime data, so a consumer matched through a prefix is checked only to that prefix (the three such consumers are frozen). One consumer, `a.need('old_owner_release_negative_control', stopped, control['gate'])` (`old_owner_isolation.py`), compares two caught names and is frozen as opaque. | The repeat freeze, the frozen prefix-only and opaque consumers, and the offline suites, which execute these sites. Re-check by hand if one of the frozen consumers changes. | — |
| **Consumer forms the scanner does not match** | A check of a caught gate name used as a dict key (`d[gate]`, `d.get(gate)`), with `startswith`/`endswith`, in a `match` statement, or passed into a comparing helper. | None exists in the tree today (39 uses: 20 comparisons or `need`, 17 pass-through, 2 re-raises). The scanner reports any such use as unsupported and the hygiene test fails, so a new one cannot land silently; it must then be matched by hand or the scanner extended. Pass-through forms (string concatenation into a message, a dict value, a `Gate`/`dict`/`trusted_gate` argument, an assignment) carry the name without matching it and are not checked for producibility. | — |
| **`typed()` lost its default name** (API change, not a rename) | — | 6e removed the default `gate` argument of `a3a_exec.typed()`, so every caller must name its gate; a call without one is a `TypeError`. All 89 in-tree callers pass a literal (hygiene test (c)); out-of-tree callers must be updated. The two 6e-added redundant checks (`a3a_sender_history_rows_present`, `old_owner_getter_signature_present`) were removed again, so PR-2 adds no gate. | — |
| **rpc_result composition** (replaces per-site injection) | That a malformed value at each of the 89 `rpc_result_*` sites stops with *that site's* name. | Composition: `typed()` raises with the name it receives, and each site passes its own unique literal.<br>Not covered: a site that an earlier check stops first. It still STOPs, but under the earlier gate's name. | — |
| **6j D/M7 behavioural substitution controls** (`probe_discovery_substitutions.py`, the 6j additions to `test_manifest_exec.py`) | A behavioural proof that discovery calls cannot be substituted by a different, equally shaped call. | The discovery gates themselves stay on `main` and are exercised by the manifest suites. | `probe_discovery_substitutions.py` 124f8d05…860c |
| **6k/6l rpc_result 88-site inventory proof** (`script/evidence/rpc_result_merge.py` and its test, `run_all_6j.sh`) | An evidence-level inventory proving the rpc_result probe drivers covered every site with an owned gate set. | The PR-2 hygiene test pins the site count and the uniqueness of the names from the source AST. | `rpc_result_merge.py` e2bd0f2a…267f<br>`test_rpc_result_merge.py` 8536c096…685a<br>`run_all_6j.sh` 24d55b69…b63b |

## PR-3 (COMMIT 6f–6i, executor integrity)

These checks defend against an honest operator running on a tree that is not the reviewed one: a
dirty worktree, the wrong branch, or a forgotten pull. They do NOT defend against an attacker who
can write files on the operator's machine as the same user; such an attacker can replace the Python
interpreter or take the keystore, and no self-check can stop that. That threat is carried by the
deploy-day procedure (fresh clone + `shasum -c`, below).

**Deploy day, step 1 (paste into the Sepolia and OP runbooks):** Make a fresh clone of the reviewed
commit. Obtain the execution-set manifest from the signed freeze packet and confirm its SHA-256
against `execution.manifestSha256` in the author-confirmed freeze record. From the clone root, run
`shasum -a 256 -c <execution-set manifest>` with the system shasum. Only after every file passes may
you run any Python from the repository. Verify the data files as well as Python: the manifest
includes schemas, registry AST allowlists/node types, the SuperPaymaster ABI, PR-2 frozen gate
JSONs, the legacy timelock allowlist, and the reviewed variable-path supplements. Keep the manifest/output packet outside the checkout, or
in an ignored evidence directory, so the clean-tree check remains meaningful.

PR-3 is **a second line of defence against accidental deviation**. It checks the checkout, helper
source and loaded module files before transaction preparation and again after operator confirmation.
The sender now signs only after that second check; confirmation therefore identifies the planned
step and reviewed plan digest, before a signed transaction hash exists.

`execution_set.py` computes the entry scripts' transitive repository imports from the AST, including
imports inside functions, the integrity helper, and itself. Ambiguous module names are included
conservatively. Literal repository data paths are resolved from the AST; `SUPPLEMENTARY` records
variable-path inputs. `execution_data_reads.json` inventories AST read sites and root joins so a
new unregistered read fails the offline test. Generated build outputs and caller-supplied files
remain subject to their existing provenance checks. The manifest uses system `shasum -a 256 -c` syntax. `a3a_exec.plan_command`,
`sp_upgrade_exec.save_plan`, and `manifest_exec.save_artifact` now write `execution-set.sha256` and
record its digest in `execution.manifestSha256`. An existing digest is never silently refreshed.
The final signer pin is added explicitly when preparing the author-reviewed freeze packet:

```sh
python3 -B script/upgrade/execution_set.py --manifest <execution-set manifest> \
  --plan <calibrated plan.json> --packet <frozen plan.json> --cast <reviewed cast executable>
```

This freeze command records `execution.cast.path` (absolute), `execution.cast.sha256`, and
`execution.cast.version`. Review these and
the manifest digest, then sign the freeze record and deliver the frozen **plan's** SHA-256 out of
band as usual. The signing of the author freeze record is an external release procedure, not code
on this branch. Legacy calibrated plans remain loadable for rehearsal but cannot be sent live
without both execution pins. Live sending recomputes the manifest digest, resolves and compares the absolute
cast executable, compares its bytes before invoking `--version`, and compares that version before
reading account names or inspecting password-file metadata. `execution.json` records the manifest
digest and the absolute Git/cast paths, versions and cast digest.

Every integrity Git query disables replacement objects in both argv and environment; replacement
refs and an existing `info/grafts` file are refused. A replaced Git binary on PATH is part of the
same-user trust-root limitation, not a security property of these checks.

Import-order limits and remaining gaps:

- CLI paths with `--plan` in `a3a_send.py`, `a3a_exec.py`, `sp_upgrade_exec.py`, and
  `manifest_exec.py` call the stdlib-only preflight before importing other repository modules.
  Building a new plan has no reviewed plan/commit argument yet; deploy-day shasum is its prior check.
- Library imports have no plan argument. `a3a_send` imports `a3a_exec` (and its `rpc_strict` dependency)
  to expose the existing Gate/API. `manifest_exec` imports `sp_upgrade_exec`, `old_owner_isolation`,
  and `execution_reads` (transitively `a3a_exec`/`rpc_strict`) to define its builder/rehearsal API.
  Those imports necessarily precede a later library caller supplying the plan. The library caller
  must perform deploy-day verification first. `run_manifest` now checks integrity before validation
  or loading the read allowlist, not after them.
- The helper first byte-checks the stdlib-only AST generator, then verifies every execution-set
  file against the reviewed commit before loading `a3a_exec`, `rpc_strict`, or `sp_upgrade_exec`.
  The Gate bootstrap retains exception compatibility; later checks also validate loaded origins.
  This remains a second line of defence against accidental deviation, not a same-user boundary.
- Verification/loading and verification/signing TOCTOU (including symlink swaps) is covered by the
  stated trust root and fresh-clone procedure. The code does not pin in-memory bytecode.
- The read barrier can be bypassed via `sh -c`, nested interpreters/external programs, dynamic
  imports and case-alias paths. It is an accidental-read barrier, not an OS sandbox. AST discovery
  cannot infer arbitrary runtime-generated imports; those require review and an updated generator.

`test_execution_calls.py` uses committed temporary copies and real integrity functions, asserting
that the cast mktx wrapper is never called on refusal. `probe_execution_integrity.py` removes both
sender calls, each loader's `module.check`, the manifest call, and the head/clean-tree gates. It
requires a green baseline, an actual text change, a named assertion FAIL and no ERROR for each
mutation. Existing named gate-deletion probes remain in place.

What PR-3 does not carry:

| Item | Missing guarantee | What covers instead | Evidence on `bb9ac9af` |
|---|---|---|---|
| `DeclarationTests.test_6f_declarations_reject_changed_bytes_and_gate_locations` (uses `gate_rename_ast_diff.declared_6f` and `gate_6f_additions.json`) | A machine proof that the 6f declarations exactly match the source: the eight added gates sit at the declared lines, with the declared fingerprints. | `probe_execution_integrity.py`: deleting each integrity gate turns its named test red. `test_gate_name_hygiene.py`: every gate name is a unique literal. The named-STOP tests in `test_execution_integrity.py`. | `gate_6f_additions.json` and `gate_rename_ast_diff.py` (see the 6e row) |
| `test_new_names_unique_across_executor_sources`, previously on `test_gate_names.inventory` (name-flow aware) | Uniqueness counted through forwarding, aliases and defaults. | The same test, now on `test_gate_name_hygiene.gate_sites` (literal call sites only). `execution_reads.py` and `execution_integrity.py` were added to the hygiene scan. | `test_gate_names.py` |

Results kept as evidence, not landed:
- `COMMIT6_RESULTS.md` f11bf111…f383
- `fixtures/gate-producer-compile.json` 19786182…d841

**B1** (CI read the local `/private/tmp/l1-builds` archive) is already solved on `main` by `8e0fc8d4`
(#614 review B1): the fixture is committed, and CI materializes it before the suites run. The split
therefore has no separate PR for COMMIT 6m.
