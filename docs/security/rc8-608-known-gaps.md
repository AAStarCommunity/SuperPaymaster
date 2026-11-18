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
| **6e rename proof and per-gate deletion probes** (`gate_rename_ast_diff.py`, `gate_name_flow.py`, `gate_templates.json`, `gate_finite_domains.json`, `gate_typed_probe_results.json`, `test_gate_*_controls.py`, `probe_*`) | A machine proof that the tree is AST-identical except at the declared gate-name positions. Plus, for each renamed gate, that deleting it turns a named test red. | `script/upgrade/test_gate_name_hygiene.py` (PR-2) covers three things:<br>(a) no new repeated gate name; the 41 repeats that predate 6e are frozen;<br>(b) the 46 replaced names survive nowhere as literals in executor code, tests or workflows, and every gate name a consumer compares against is still raised;<br>(c) every `rpc_result_*` site passes a unique literal, the 89 sites are pinned, and `typed()` reports the name it is given.<br>The four renamed dynamic prefixes have named-STOP tests in `test_manifest_exec.py`. The existing offline suites are green on the renamed tree. | `gate_templates.json` 002794eb…8e65<br>`gate_rename_ast_diff.py` 49fc7534…14a4<br>`gate_name_flow.py` 44480d37…6b57<br>`gate_finite_domains.json` 55df5829…c5ad<br>`gate_typed_probe_results.json` 0dd70645…ce51<br>`test_gate_template_controls.py` 2a10e3c1…68f7 |
| **`old_owner_fork_case_` — checked by hand, not by the hygiene test** | An automatic check that this consumer and its producer agree. The prefix reaches `need` through the `gate` parameter of `absent()`, so the AST scan classifies it as a forwarded variable and cannot match it. | Manual review (PR-2): the producer `absent(normalized,'old_owner_fork_case_'+case['gate'])` (`script/upgrade/old_owner_isolation.py:1510`) and the consumer `a.need('old_owner_fork_stop_gate',error.record['gate'],'old_owner_fork_case_'+case['gate'])` (`:1512`) use the same expression. Re-check by hand if either line changes. | — |
| **`a3a_sender_history_rows_present`** (6e added accessor gate, not a rename) | A strict deletion probe. On `bb9ac9af` it lives in `probe_sender_accessor.py`, which is part of the proof machinery that is not landed. | The gate stays in `manifest_exec.py`. `probe_phase_c_gates.py` lists it under `KNOWN_GAPS`, so CI prints it instead of failing on it. It is one of the 44 gates that the post-PR-3 test PR classifies (甲 / 乙). | — |
| **rpc_result composition** (replaces per-site injection) | That a malformed value at each of the 89 `rpc_result_*` sites stops with *that site's* name. | Composition: `typed()` raises with the name it receives, and each site passes its own unique literal.<br>Not covered: a site that an earlier check stops first. It still STOPs, but under the earlier gate's name. | — |
| **6j D/M7 behavioural substitution controls** (`probe_discovery_substitutions.py`, the 6j additions to `test_manifest_exec.py`) | A behavioural proof that discovery calls cannot be substituted by a different, equally shaped call. | The discovery gates themselves stay on `main` and are exercised by the manifest suites. | `probe_discovery_substitutions.py` 124f8d05…860c |
| **6k/6l rpc_result 88-site inventory proof** (`script/evidence/rpc_result_merge.py` and its test, `run_all_6j.sh`) | An evidence-level inventory proving the rpc_result probe drivers covered every site with an owned gate set. | The PR-2 hygiene test pins the site count and the uniqueness of the names from the source AST. | `rpc_result_merge.py` e2bd0f2a…267f<br>`test_rpc_result_merge.py` 8536c096…685a<br>`run_all_6j.sh` 24d55b69…b63b |

Results kept as evidence, not landed:
- `COMMIT6_RESULTS.md` f11bf111…f383
- `fixtures/gate-producer-compile.json` 19786182…d841

**B1** (CI read the local `/private/tmp/l1-builds` archive) is already solved on `main` by `8e0fc8d4`
(#614 review B1): the fixture is committed, and CI materializes it before the suites run. The split
therefore has no separate PR for COMMIT 6m.
