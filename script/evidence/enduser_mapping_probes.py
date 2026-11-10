#!/usr/bin/env python3
"""Deletion probes for the ENDUSER mapping-control ruling (DSR 2026-11-05).

Each probe deletes exactly one site in a scratch copy of script/ and runs its
bound test: baseline OK; mutated failures >= 1, errors == 0; at least one failing
assertion message must contain the deleted gate's name.
Prints per-target match counts and results, plus DISCOVERY_DELETION_PROBES for the
discovery subset and ENDUSER_PROBES PASS only if every probe is red and every baseline is green.
"""
import ast
import re
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'script/upgrade'))
from gate_assertions import assertion_mentions

ISOLATION = 'script/upgrade/old_owner_isolation.py'
TESTS = 'script/upgrade/test_old_owner_isolation.py'
PROBES = [
    ('enduser_mapping_member',
     'MAPPING_CONTROL_ROLES = {u.REG: [ROLE_ANODE, ROLE_KMS, ROLE_ENDUSER]}',
     'MAPPING_CONTROL_ROLES = {u.REG: [ROLE_ANODE, ROLE_KMS]}',
     'OldOwnerIsolationTests.test_mapping_enduser_without_control_holder',
     'a3a_exec.Gate: old_owner_role_control_path'),
    ('role_control_case_gate',
     "        a.need('old_owner_role_control_case',isinstance(case,dict),True)\n",
     '',
     'OldOwnerIsolationTests.test_role_control_case_without_path_gate',
     'TypeError raised at old_owner_isolation.py:role_control'),
    # Codex P2: ENDUSER in roleHistory proves discovery only; skipping its control path must still go red.
    ('enduser_role_control_skipped',
     '                role_control(name,target,role,spec)\n',
     '                if role != ROLE_ENDUSER: role_control(name,target,role,spec)\n',
     'OldOwnerIsolationTests.test_mapping_enduser_without_control_holder',
     'AssertionError: Lists differ: [] != [True]'),
    ('enduser_configured_call_skipped',
     '\n            role_control(name,target,role,spec)\n',
     '\n            if role != ROLE_ENDUSER: role_control(name,target,role,spec)\n',
     'OldOwnerIsolationTests.test_mapping_enduser_configured_only',
     'AssertionError: Lists differ: [] != [True]'),
    # Role-specific shortcuts inside mapping_control (each must be rejected by the per-role negative cases).
    ('enduser_skips_getter_proof',
     "    try:\n        a.need('old_owner_mapping_getter',",
     "    try:\n        if role != ROLE_ENDUSER: a.need('old_owner_mapping_getter',",
     'OldOwnerIsolationTests.test_mapping_function_getter_rejected_per_role',
     "AssertionError: True is not False"),
    ('enduser_ignores_positive_control',
     "    a.need('old_owner_mapping_positive',word(target,'hasRole(bytes32,address)',ROLE_COMMUNITY,u.DEPLOYER),1)\n",
     "    positive = word(target,'hasRole(bytes32,address)',ROLE_COMMUNITY,u.DEPLOYER)\n    if role != ROLE_ENDUSER: a.need('old_owner_mapping_positive',positive,1)\n",
     'OldOwnerIsolationTests.test_mapping_positive_zero',
     'AssertionError: Gate not raised'),
    ('enduser_ignores_negative_control',
     "    a.need('old_owner_mapping_negative',word(target,'hasRole(bytes32,address)',ROLE_COMMUNITY,OLD),0)\n",
     "    negative = word(target,'hasRole(bytes32,address)',ROLE_COMMUNITY,OLD)\n    if role != ROLE_ENDUSER: a.need('old_owner_mapping_negative',negative,0)\n",
     'OldOwnerIsolationTests.test_mapping_negative_one',
     'AssertionError: Gate not raised'),
    # Caller-side shortcuts in role_control (Codex P2): accept ENDUSER on False, or swallow its Gate.
    ('caller_accepts_enduser_on_false',
     '        if mapping_control(spec,target,role,word):\n            return\n',
     '        if mapping_control(spec,target,role,word) or role == ROLE_ENDUSER:\n            return\n',
     'OldOwnerIsolationTests.test_mapping_enduser_faults_stop_audit',
     'AssertionError: Gate not raised'),
    ('caller_swallows_enduser_gate',
     '        if mapping_control(spec,target,role,word):\n            return\n',
     '        try:\n            if mapping_control(spec,target,role,word):\n                return\n'
     '        except a.Gate:\n            if role == ROLE_ENDUSER:\n                return\n            raise\n',
     'OldOwnerIsolationTests.test_mapping_enduser_faults_stop_audit',
     'AssertionError: Gate not raised'),
]


# COMMIT 1: remove complete AST gate statements, never partial multiline expressions.
_c1_source = (ROOT/ISOLATION).read_text()
_c1_tree = ast.parse(_c1_source)
for _suffix in ('role_write_key', 'role_assembly', 'role_lowlevel_call', 'registry_source_commit', 'role_write_sites', 'role_initializer_only', 'role_init_ids', 'role_init_standard', 'role_configure_emit', 'role_config_control', 'xpnts_deployment_count', 'xpnts_deployment_log', 'xpnts_owner_pin'):
    _gate = 'old_owner_'+_suffix
    _nodes = [n for n in ast.walk(_c1_tree) if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
              and isinstance(n.value.func, ast.Attribute) and n.value.func.attr == 'need'
              and n.value.args and isinstance(n.value.args[0], ast.Constant) and n.value.args[0].value == _gate]
    assert len(_nodes) == 1, (_gate, len(_nodes))
    PROBES.append((_gate, ast.get_source_segment(_c1_source, _nodes[0]), 'pass',
                   'OldOwnerIsolationTests.test_'+_suffix, 'AssertionError:' if _suffix.startswith('xpnts_') else 'AssertionError: Gate not raised'))
PROBES.append(('role_write_extraction_call', '                initialized_roles = registry_role_writes(entries, source_inputs, declarations)\n', "                initialized_roles = {n['name'] for _, n in entries if n.get('constant') and n.get('typeDescriptions', {}).get('typeString') == 'bytes32' and (n.get('name', '').startswith('ROLE_') or n.get('name', '').endswith('ROLE'))}\n",
               'OldOwnerIsolationTests.test_role_write_extraction_call', 'AssertionError: Gate not raised'))

PROBES.append(('role_opaque_extraction_call', '                callsite_matches = registry_opaque_writes(opaque_entries, source_inputs, declarations)\n', '                callsite_matches = []\n',
               'OldOwnerIsolationTests.test_role_opaque_extraction_call', 'old_owner_role_assembly'))

PROBES.append(('registry_event_only_restored',
               '            roles |= standard | set(histories.get(target, []))',
               "            a.need('old_owner_role_extraction_empty', bool(roles) and standard <= roles, True)",
               'OldOwnerIsolationTests.test_role_configured_independent_coverage_and_gate_removals',
               'AssertionError: old_owner_role_extraction_empty'))


PROBES.append(('xpnts_deployment_call', '        community = token_deployment_community(recorded, pin, token_factory, token)\n', '',
               'OldOwnerIsolationTests.test_xpnts_deployment_call', 'AssertionError:'))

DELTA_GATES = ('address', 'removed', 'topics', 'range', 'canonical', 'number', 'allowance',
               'config_owner', 'timelock_role', 'old_role', 'targets', 'xpnts')


def manifest_probes():
    path = 'script/upgrade/manifest_exec.py'
    source = (ROOT/path).read_text()
    tree = ast.parse(source)
    probes = []
    for suffix in DELTA_GATES:
        gate = 'old_timelock_delta_'+suffix
        nodes = [n for n in ast.walk(tree) if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
                 and isinstance(n.value.func, ast.Attribute) and n.value.func.attr == 'need'
                 and n.value.args and isinstance(n.value.args[0], ast.Constant) and n.value.args[0].value == gate]
        assert len(nodes) == 1, (gate, len(nodes))
        probes.append((gate, ast.get_source_segment(source, nodes[0]), 'pass', 'DeltaTests.test_'+gate))
    test_tree = ast.parse((ROOT/'script/upgrade/test_manifest_exec.py').read_text())
    constants = {n.targets[0].id: ast.literal_eval(n.value) for n in test_tree.body
                 if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name)
                 and n.targets[0].id in ('DISCOVERY_GATES', 'DISCOVERY_CALLS')}
    for gate in constants['DISCOVERY_GATES']:
        nodes = [n for n in ast.walk(tree) if isinstance(n, ast.Expr) and isinstance(n.value, ast.Call)
                 and isinstance(n.value.func, ast.Attribute) and n.value.func.attr == 'need'
                 and n.value.args and isinstance(n.value.args[0], ast.Constant) and n.value.args[0].value == gate]
        assert len(nodes) == 1, (gate, len(nodes))
        probes.append((gate, ast.get_source_segment(source,nodes[0]), 'pass', 'DiscoveryTests.test_'+gate))
    for i, (function, expression, gate) in enumerate(constants['DISCOVERY_CALLS']):
        fn = next(n for n in ast.walk(tree) if isinstance(n,ast.FunctionDef) and n.name == function)
        body = ast.get_source_segment(source,fn)
        assert body.count(expression) == 1, (function, expression)
        probes.append(('discovery_call_'+str(i), body, body.replace(expression,'None'), 'DiscoveryCallTests.test_call_'+str(i)))
    probes.append(('post_pin_delta_call', "    delta = post_pin_delta(rpc, coverage, block)\n", '', 'DeltaTests.test_pre_send_delta_call'))
    probes.append(('configured_roles_closing_standard',
                   "{r['value'] for r in spec['roles']} | {log['topics'][1] for log in logs}",
                   "{log['topics'][1] for log in logs}", 'ManifestTests.test_configured_roles_closing_without_events'))
    isolation_source = (ROOT/ISOLATION).read_text()
    for stage in ('pre_send', 'closing'):
        site = "    isolation.never_granted_recheck(rpc, coverage, block)\n" if stage == 'pre_send' else "    never_granted = isolation.never_granted_recheck(rpc, coverage, block)\n"
        replacement = '' if stage == 'pre_send' else '    never_granted = {}\n'
        probes.append(('xpnts_owner_'+stage+'_call',site,replacement,'ManifestTests.test_xpnts_owner_'+stage))
    # The shared owner gate is in isolation, exercised through both callers.
    owner_gate = next(line for line in isolation_source.splitlines(True) if "a.need('old_owner_xpnts_owner_recheck'" in line)
    probes.append(('xpnts_owner_recheck',owner_gate,'', 'ManifestTests.test_xpnts_owner_pre_send'))
    probes += [
        ('discovery_preswitch_gate', "    a.need('old_owner_factory_enumeration',switched or bool(enumerated) and set(ROUND_CLONES) <= enumerated,True)\n", '', 'DiscoveryTests.test_preswitch_enumeration'),
        ('discovery_switch_path', "switched = 'discoveryOriginalFactory' in pin and targets['xPNTsFactory'][0] != pin['discoveryOriginalFactory']", 'switched = False', 'DiscoveryTests.test_postswitch_enumeration'),
    ]
    discovery_names = set(constants['DISCOVERY_GATES']) | {'discovery_call_'+str(i) for i in range(len(constants['DISCOVERY_CALLS']))} | {
        'discovery_preswitch_gate', 'discovery_switch_path'}
    discovery_results = []
    ok = True
    with tempfile.TemporaryDirectory() as directory:
        tree = pathlib.Path(directory)
        shutil.copytree(ROOT/'script', tree/'script')
        for extra in ('contracts', 'foundry.toml', 'out', 'lib', 'singleton-paymaster'):
            if (ROOT/extra).exists():
                (tree/extra).symlink_to(ROOT/extra)
        for name, old, new, test in probes:
            (tree/path).write_text(source)
            (tree/ISOLATION).write_text(isolation_source)
            target_path = ISOLATION if name in ('xpnts_owner_recheck', 'discovery_preswitch_gate', 'discovery_switch_path', 'discovery_retained_tokens') else path
            target_source = isolation_source if target_path == ISOLATION else source
            count = target_source.count(old)
            base_rc, base_tail, _ = run(tree, test, 'script/upgrade/test_manifest_exec.py')
            (tree/target_path).write_text(target_source.replace(old, new))
            mut_rc, mut_tail, mut_err = run(tree, test, 'script/upgrade/test_manifest_exec.py')
            gate = manifest_gate(name, test, constants)
            red = count == 1 and base_rc == 0 and mut_rc != 0 and assertion_red(mut_tail, mut_err, gate)
            ok &= red
            if name in discovery_names:
                discovery_results.append(red)
            print(f'{name}: matches={count} baseline=rc{base_rc} [{base_tail}] removed=rc{mut_rc} [{mut_tail}] {"red" if red else "NOT RED"}')
    discovery_ok = len(discovery_results) == len(discovery_names) and all(discovery_results)
    print(f'DISCOVERY_DELETION_PROBES {"PASS" if discovery_ok else "FAIL"} '
          f'{sum(discovery_results)}/{len(discovery_names)}; each matches=1 and red')
    ok &= discovery_ok
    print('DELTA_DELETION_PROBES', 'PASS' if ok else 'FAIL')
    return ok


def assertion_red(tail, log, gate):
    failures = re.search(r'failures=(\d+)', tail)
    return bool(failures and int(failures[1]) >= 1 and 'errors=' not in tail
                and assertion_mentions(log, gate))


def isolation_gate(name):
    if name.startswith('old_owner_'):
        return name
    return {
        'enduser_mapping_member': 'old_owner_role_control_path',
        'role_control_case_gate': 'old_owner_role_control_case',
        'enduser_role_control_skipped': 'old_owner_role_control_path',
        'enduser_configured_call_skipped': 'old_owner_role_control_path',
        'enduser_skips_getter_proof': 'old_owner_mapping_getter',
        'enduser_ignores_positive_control': 'old_owner_mapping_positive',
        'enduser_ignores_negative_control': 'old_owner_mapping_negative',
        'caller_accepts_enduser_on_false': 'old_owner_role_control_path',
        'caller_swallows_enduser_gate': 'old_owner_mapping_positive',
        'role_write_extraction_call': 'old_owner_role_configure_emit',
        'role_opaque_extraction_call': 'old_owner_role_assembly',
        'registry_event_only_restored': 'old_owner_role_extraction_empty',
        'xpnts_deployment_call': 'old_owner_xpnts_deployment_count',
    }[name]


def manifest_gate(name, test, constants):
    if name.startswith('discovery_call_'):
        return constants['DISCOVERY_CALLS'][int(name.rsplit('_',1)[1])][2]
    return {
        'discovery_preswitch_gate': 'old_owner_factory_enumeration',
        'discovery_switch_path': 'old_owner_factory_enumeration',
        'post_pin_delta_call': 'old_timelock_delta_allowance',
        'configured_roles_closing_standard': 'old_timelock_inventory',
        'xpnts_owner_pre_send_call': 'old_owner_xpnts_owner_recheck',
        'xpnts_owner_closing_call': 'old_owner_xpnts_owner_recheck',
        'xpnts_owner_recheck': 'old_owner_xpnts_owner_recheck',
    }.get(name, name)


def run(tree, test, tests=TESTS):
    proc = subprocess.run([sys.executable, '-B', tests, test], cwd=tree, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)
    tail = [line for line in proc.stderr.splitlines() if line.startswith(('Ran ', 'OK', 'FAILED'))]
    return proc.returncode, ' '.join(tail), proc.stderr


def main():
    ok = manifest_probes()
    for name, old, new, test, cause in PROBES:
        with tempfile.TemporaryDirectory() as directory:
            tree = pathlib.Path(directory)
            shutil.copytree(ROOT/'script', tree/'script')
            for extra in ('contracts', 'foundry.toml', 'out', 'lib', 'singleton-paymaster'):
                if (ROOT/extra).exists():
                    (tree/extra).symlink_to(ROOT/extra)
            source = (tree/ISOLATION).read_text()
            count = source.count(old)
            base_rc, base_tail, _ = run(tree, test)
            (tree/ISOLATION).write_text(source.replace(old, new))
            mut_rc, mut_tail, mut_err = run(tree, test)
        gate = isolation_gate(name)
        named = assertion_red(mut_tail, mut_err, gate)
        red = count == 1 and base_rc == 0 and mut_rc != 0 and named
        ok &= red
        print(f'{name}: matches={count} baseline=rc{base_rc} [{base_tail}] removed=rc{mut_rc} [{mut_tail}] cause={named} '
              f'{"red" if red else "NOT RED"}')
    print('ENDUSER_PROBES', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
