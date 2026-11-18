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

Results kept as evidence, not landed:
- `COMMIT6_RESULTS.md` f11bf111…f383
- `fixtures/gate-producer-compile.json` 19786182…d841

**B1** (CI read the local `/private/tmp/l1-builds` archive) is already solved on `main` by `8e0fc8d4`
(#614 review B1): the fixture is committed, and CI materializes it before the suites run. The split
therefore has no separate PR for COMMIT 6m.
