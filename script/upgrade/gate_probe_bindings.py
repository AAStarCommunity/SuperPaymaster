"""Exact offline probe registration and execution binding checks."""
import importlib
from pathlib import Path
from collections import Counter
from gate_rename_ast_diff import ROOT


def validate_binding(probe):
    def module(file):
        path = (ROOT / file).resolve()
        assert path.parent == Path(__file__).resolve().parent, 'gate_templates: binding outside offline tooling'
        loaded = importlib.import_module(path.stem)
        assert Path(loaded.__file__).resolve() == path, 'gate_templates: binding module path mismatch'
        return loaded
    runner = module(probe['file'])
    assert callable(getattr(runner, probe['function'], None)), 'gate_templates: probe binding callable missing'
    tests = module(probe['test_file'])
    cls = getattr(tests, probe['test_class'], None)
    assert cls is not None and callable(getattr(cls, probe['test_method'], None)), 'gate_templates: test binding missing'
    return cls


def registered_cases(registry):
    result = []
    for row in registry:
        probes = [row['probe']] if row.get('domain') == 'R' else row.get('probes', {}).values()
        for probe in probes:
            if probe['file'] != 'script/upgrade/probe_gate_r.py':
                continue
            validate_site_binding(row, probe)
            cls = validate_binding(probe)
            assert probe['function'] == 'run_probes', 'gate_templates: runner binding mismatch'
            result.append((row['file'], row['line'], probe['gate'], cls, probe['test_method']))
    return result


def reconcile(registry, executed):
    expected = Counter(registered_cases(registry))
    actual = Counter(executed)
    assert expected == actual, ('gate_templates: executed binding mismatch missing=' + repr(expected - actual)
                                + ' extra=' + repr(actual - expected))


def validate_site_binding(row, probe):
    cls = validate_binding(probe)
    if probe['file'] == 'script/upgrade/probe_gate_dsr2.py':
        from test_gate_dsr2 import CASES
        matches = [r for r in CASES if r['gate'] == probe['gate'] and r['line'] == row['line']
                   and 'script/upgrade/' + r['file'] == row['file']]
        assert len(matches) == 1, 'gate_templates: DSR2 source binding mismatch'
        case = matches[0]
        assert (probe['function'] == 'main' and probe['test_file'] == 'script/upgrade/test_gate_dsr2.py'
                and probe['test_class'] == case['class'] and probe['earlier'] == case['earlier']
                and probe['test_method'] == 'test_shadow_' + case['gate']
                and probe['target_method'] == 'test_target_' + case['gate']
                and callable(getattr(cls, probe['target_method'], None))), 'gate_templates: DSR2 pair binding mismatch'
    if probe['file'] == 'script/upgrade/probe_gate_r.py':
        assert probe['function'] == 'run_probes', 'gate_templates: runner binding mismatch'
        tests = importlib.import_module(Path(probe['test_file']).stem)
        expected = (cls, probe['test_method'], probe['gate'], row['line'])
        assert tests.CASES.count(expected) == 1, 'gate_templates: source site binding missing or duplicated'
        expected_file = 'script/upgrade/old_owner_isolation.py' if probe['gate'].startswith('old_owner_') else 'script/upgrade/manifest_exec.py'
        assert row['file'] == expected_file, 'gate_templates: production file binding mismatch'
