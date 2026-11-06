#!/usr/bin/env python3
"""Phase C gate-removal probes: suppress one named gate, require its control to turn red.

Production files are never modified: the baseline identifies the failing source
statement, then the probe deletes exactly that AST statement in memory. A red
probe has failures >= 1, zero errors, and a failing assertion naming the gate.
The script also scans manifest_exec.py against a base revision and fails if a newly added
gate literal has no probe case.
"""
import sys
sys.dont_write_bytecode = True
import io
import inspect
import ast
import re
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch
from gate_assertions import assertion_mentions
import test_manifest_exec as base_tests
import test_manifest_phase_c as tests

a = tests.a
P, L, S = tests.PhaseCTests, tests.LiveGateTests, tests.SnapshotControlTests
CASES = [(P, 'test_build_'+g, g) for g in tests.BUILD_CASES]
CASES += [(P, 'test_rebuild_'+g, g) for g in tests.REBUILD_CASES]
CASES += [(tests.BaselineGateTests, 'test_build_'+g, g) for g in
          ('C12_constructor_abi', 'C14_constructor_abi', 'C_baseline_commit_F1TestToken')]
CASES += [(L, 'test_live_'+g, g) for g in tests.LIVE_CASES]
CASES += [(L, 'test_precheck_'+g, g.split('__')[0]) for g in tests.PRECHECK_CASES]
CASES += [(L, 'test_funding_'+g, g.split('__')[0]) for g in tests.FUNDING_CASES]
CASES += [
    (P, 'test_pin_price_zero', 'C_price_bound'),
    (P, 'test_stage_c_boundary_and_prefix', 'prefix_boundary'),
    (P, 'test_stage_c_prefix_must_end_in_phase_c', 'prefix_boundary_last'),
    (P, 'test_stage_c_artifact_never_final', 'final_stage'),
    (P, 'test_collect_phase_c_pending_nonce', 'phase_c_pending_nonce_owner'),
    (L, 'test_accounting', 'C_accounting'),
    (L, 'test_owner_gas_bound', 'C_owner_gas_bound'),
    (L, 'test_budget_owner_shortfall', 'budget_owner'),
    (L, 'test_handover_requires_phase_c', 'handover_dependencies'),
    (S, 'test_control_must_fire_named_gate', 'X_gate'),
    (S, 'test_control_must_fire_named_gate', 'X_restore'),
    (S, 'test_control_slot_readback', 'C_control_slot'),
    (S, 'test_control_slot_readback', 'C_control_layout_cachedPrice'),
    (base_tests.ManifestTests, 'test_rehearsal_phase_c_controls_complete', 'phase_c_controls_complete'),
    (base_tests.ManifestTests, 'test_rehearsal_after_6d_accounting', 'after_6d_accounting'),
    (base_tests.ManifestTests, 'test_rehearsal_accounting_unchanged_since_phase_c', 'accounting_unchanged_since_phase_c'),
    (base_tests.ManifestTests, 'test_rehearsal_funding_rechecked_after_phase_c', 'C_funding_bundler'),
    # #605 audit fixes and #606 L1 (DSR 2026-11-05): gates added outside Phase C, bound to their named controls.
    (base_tests.ManifestTests, 'test_pin_pending_token_eta', 'pin_pending_token_eta'),
    (base_tests.ManifestTests, 'test_collect_direct_fake_chain', 'old_aggregator_slash_policy_admin'),
    (base_tests.ManifestTests, 'test_dvt_closing_binds_pointer_and_stale_proposals', 'closing_registry_pointer'),
    (base_tests.ManifestTests, 'test_dvt_closing_binds_pointer_and_stale_proposals', 'closing_committee_pointer'),
    (base_tests.F05ExecuteB4Gates, 'test_B4_timestamp', 'B4_timestamp'),
]
CASES += [(base_tests.ManifestTests, 'test_'+gate, gate) for gate in
          ('old_timelock_holds_nothing', 'old_timelock_tl_roles', 'old_timelock_authority', 'old_timelock_safe')]
CASES += [(base_tests.ManifestTests, 'test_'+gate, gate) for gate in
          ('old_timelock_required', 'old_timelock_schema', 'old_timelock_block', 'old_timelock_replay',
           'old_timelock_unused', 'old_timelock_allowance')]
CASES += [(base_tests.ManifestTests, 'test_old_timelock_inventory_new_role', 'old_timelock_inventory'),
          (base_tests.ManifestTests, 'test_old_timelock_inventory_new_token', 'old_timelock_inventory')]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_legacy_timelock_source_targets', 'old_owner_source_targets')]
CASES += [(base_tests.ManifestTests, 'test_old_timelock_approval_history', 'old_timelock_approval_history'),
          (base_tests.ManifestTests, 'test_old_timelock_external_approval', 'old_timelock_allowance'),
          (base_tests.ManifestTests, 'test_old_timelock_approval_incomplete', 'old_owner_log_partition')]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_never_granted_range_grant', 'old_owner_never_granted_set')]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_never_granted_control_holder', 'old_owner_never_granted_holder')]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_mapping_function_falls_back', 'old_owner_mapping_getter')]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_role_control_case_without_path_gate', 'old_owner_role_control_case')]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_mapping_positive_zero', 'old_owner_mapping_positive')]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_mapping_negative_one', 'old_owner_mapping_negative')]
CASES += [(base_tests.ManifestTests, 'test_never_granted_closing_change', 'old_owner_never_granted_recheck')]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, name, gate) for name, gate in (
    ('test_never_granted_extra_zero','old_owner_history_positive'),
    ('test_never_granted_missing_role','old_owner_never_granted_set'),
    ('test_never_granted_old_holder','old_owner_never_granted_holder'),
    ('test_history_all_roles_zero','old_owner_history_positive'))]
CASES += [(base_tests.ManifestTests,'test_never_granted_pre_send_change','old_owner_never_granted_recheck')]
CASES += [(base_tests.ManifestTests, name, 'old_owner_role_recheck') for name in ('test_old_role_closing_change', 'test_old_role_pre_send_change')]
CASES += [(base_tests.DeltaTests, 'test_old_timelock_delta_'+g, 'old_timelock_delta_'+g) for g in base_tests.DELTA_CASES]
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_history_standard_revoke_only', 'old_owner_history_positive')]
C1_GATES = ('role_write_key', 'role_assembly', 'role_lowlevel_call', 'registry_source_commit', 'role_write_sites', 'role_initializer_only', 'role_init_ids', 'role_init_standard', 'role_configure_emit', 'role_config_control')
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_'+g, 'old_owner_'+g) for g in C1_GATES]
C2_GATES = ('xpnts_deployment_count', 'xpnts_deployment_log', 'xpnts_owner_pin')
CASES += [(base_tests.isolation_tests.OldOwnerIsolationTests, 'test_'+g, 'old_owner_'+g) for g in C2_GATES]
CASES += [(base_tests.ManifestTests, 'test_xpnts_owner_'+stage, 'old_owner_xpnts_owner_recheck') for stage in ('pre_send','closing')]
CASES += [(base_tests.DiscoveryTests, 'test_'+gate, gate) for gate in base_tests.DISCOVERY_GATES]
# These new/changed isolation gates must fail by assertion, with zero test errors.
ASSERTION_ONLY_GATES = {'old_owner_never_granted_set', 'old_owner_never_granted_holder',
                        'old_owner_never_granted_recheck', 'old_owner_role_recheck', 'old_owner_mapping_getter',
                        'old_owner_mapping_positive', 'old_owner_mapping_negative',
                        'old_owner_history_positive'}
ASSERTION_ONLY_GATES.update('old_owner_'+g for g in (*C1_GATES,*C2_GATES,'xpnts_owner_recheck'))
ASSERTION_ONLY_GATES.update(base_tests.DISCOVERY_GATES)
ASSERTION_ONLY_GATES.update('old_timelock_delta_'+g for g in base_tests.DELTA_CASES)
GATE = re.compile(r"""a\.(?:need|exact_keys)\(\s*['"]([A-Za-z0-9_]+)['"]""")
# Gate literals whose control is a whole family (name+'_gate', name+'_restore').
FAMILIES = {'_gate': 'X_gate', '_restore': 'X_restore'}


SITES = {}


def run(cls, name, gate=None):
    original = a.need
    observed = {}

    def recording(actual, *args, **kwargs):
        try:
            return original(actual, *args, **kwargs)
        except a.Gate:
            frame = inspect.currentframe().f_back
            while frame and Path(frame.f_code.co_filename).name not in ('manifest_exec.py', 'old_owner_isolation.py', 'sp_upgrade_exec.py'):
                frame = frame.f_back
            if frame:
                observed.setdefault(actual, set()).add((frame.f_code.co_filename, frame.f_lineno))
            raise

    stream = io.StringIO()
    saved, module, matches = None, None, 0
    aliases = []
    if gate is not None:
        sites = SITES.get((cls, name, gate), set())
        if len(sites) != 1:
            return True, False, f'{gate}: expected one failing source location, got {sites}'
        filename, line = next(iter(sites))
        source = Path(filename).read_text()
        tree = ast.parse(source, filename)
        candidates = [n for n in ast.walk(tree) if isinstance(n, ast.Expr) and n.lineno <= line <= n.end_lineno
                      and isinstance(n.value, ast.Call)]
        matches = len(candidates)
        if matches != 1:
            return True, False, f'{gate}: matches={matches}'
        target = candidates[0]
        class Delete(ast.NodeTransformer):
            def visit_Expr(self, node):
                return ast.copy_location(ast.Pass(), node) if node is target else self.generic_visit(node)
        tree = ast.fix_missing_locations(Delete().visit(tree))
        module = next(m for m in (base_tests.m, base_tests.isolation_tests.o, base_tests.u) if Path(m.__file__).resolve() == Path(filename).resolve())
        saved = module.__dict__.copy()
        exec(compile(tree, filename, 'exec'), module.__dict__)
        replacements = {id(value): module.__dict__[key] for key, value in saved.items()
                        if callable(value) and key in module.__dict__ and module.__dict__[key] is not value}
        for test_module in (tests, base_tests, base_tests.isolation_tests):
            for key, value in list(test_module.__dict__.items()):
                if id(value) in replacements:
                    aliases.append((test_module, key, value))
                    setattr(test_module, key, replacements[id(value)])
    try:
        with patch.object(a, 'need', side_effect=recording):
            result = unittest.TextTestRunner(stream=stream).run(unittest.TestSuite([cls(name)]))
    finally:
        for test_module, key, value in aliases:
            setattr(test_module, key, value)
        if saved is not None:
            module.__dict__.clear()
            module.__dict__.update(saved)
    if gate is None:
        for actual, sites in observed.items():
            SITES[(cls, name, actual)] = sites
        return result.wasSuccessful(), False, stream.getvalue()
    red = (matches == 1 and len(result.failures) >= 1 and not result.errors
           and any(assertion_mentions(log, gate) for _, log in result.failures))
    return not red, matches == 1, stream.getvalue()


def new_gates(base):
    path = 'script/upgrade/manifest_exec.py'
    root = Path(__file__).resolve().parents[2]
    old = subprocess.run(['git', 'show', base+':'+path], cwd=root, capture_output=True, text=True, check=True).stdout
    current = (root/path).read_text()
    return sorted(set(GATE.findall(current))-set(GATE.findall(old)))


def covered(gate, names):
    if gate in names:
        return True
    if gate.endswith('_'):
        return any(n.startswith(gate) for n in names)
    return False


def main(argv):
    base = argv[1] if len(argv) > 1 else 'origin/main'
    names = {g for _, _, g in CASES} | {'_gate', '_restore'}
    missing = [g for g in new_gates(base) if not covered(g, names)]
    rows = []
    for cls, name, gate in CASES:
        ok, _, log = run(cls, name)
        if not ok:
            # A control that fails without suppression proves nothing about its gate.
            print(f'BASELINE FAILED {name}\n{log}', file=sys.stderr)
            return 1
        ok, reached, log = run(cls, name, gate)
        if ok:
            print(f'NOT STRICT RED {cls.__name__}.{name} gate={gate} sites={SITES.get((cls,name,gate))}\n{log}', file=sys.stderr)
        rows.append((cls.__name__+'.'+name, gate, 'PASS', 'red' if not ok and reached else
                     'NO SINGLE DELETION SITE' if not reached else 'NOT STRICT RED (see mutation result)'))
    print('| Control | Suppressed gate | Baseline | Gate removed |')
    print('|---|---|---|---|')
    for row in rows:
        print('| %s | `%s` | %s | %s |' % row)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'evidence'))
    from enduser_mapping_probes import manifest_probes
    deletions = manifest_probes()
    bad = [r for r in rows if r[3] != 'red']
    print(f'PHASE_C_GATE_PROBES {"PASS" if not bad and not missing and deletions else "FAIL"} '
          f'{len(rows)-len(bad)}/{len(rows)} red; uncovered new gates: {missing}')
    return 1 if bad or missing or not deletions else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
