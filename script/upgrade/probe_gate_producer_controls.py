#!/usr/bin/env python3
"""One producer probe; source mutation is confined to an owned temporary tree."""
import ast
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from gate_assertions import assertion_mentions
from test_gate_producer_controls import GATE, prove_schedule_flow

ROOT = Path(__file__).resolve().parents[2]


def main():
    prove_schedule_flow()
    out = Path('/tmp/commit6e-producer-controls')
    out.mkdir(exist_ok=True)
    command = [sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'script/upgrade',
               '-p', 'test_gate_producer_controls.py']
    with tempfile.TemporaryDirectory(prefix='commit6e-producer-probe-') as directory:
        tree = Path(directory)
        shutil.copytree(ROOT/'script', tree/'script', ignore=shutil.ignore_patterns('__pycache__'))
        # Packet fixture paths are relative to the copied repository root.
        shutil.copytree(ROOT/'docs/release', tree/'docs/release')
        # The rebuild consumer performs read-only rev-parse/show checks against
        # the original commit. Its producer is the sole replaced function.
        assert (ROOT/'.git').is_file()
        shutil.copy2(ROOT/'.git', tree/'.git')
        baseline = subprocess.run(command, cwd=tree, capture_output=True, text=True, timeout=120)
        baseline_log = baseline.stdout + baseline.stderr
        def focused(method, at=tree):
            result = subprocess.run([sys.executable, '-B', '-m', 'unittest',
                'test_gate_producer_controls.ProducerTests.' + method],
                cwd=at, env=dict(__import__('os').environ, PYTHONPATH=str(at/'script/upgrade')),
                capture_output=True, text=True, timeout=120)
            return dict(code=result.returncode, log=result.stdout + result.stderr)
        shadow_e = focused('probe_shadow_e', ROOT)
        path = tree/'script/a3a/a3a_exec.py'
        source = path.read_text()
        nodes = [n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.Call)
                 and any(k.arg == 'gate' and isinstance(k.value, ast.Constant) and k.value.value == GATE for k in n.keywords)]
        assert len(nodes) == 1
        node = nodes[0]
        assert node.lineno == node.end_lineno
        lines = source.splitlines(keepends=True)
        line = lines[node.lineno-1]
        lines[node.lineno-1] = line[:node.col_offset] + ast.unparse(node.args[0]) + line[node.end_col_offset:]
        assert tree.resolve() != ROOT.resolve()
        path.write_text(''.join(lines))
        # The dataflow test belongs to the baseline; deletion intentionally removes its target.
        mutated = subprocess.run([sys.executable, '-B', '-m', 'unittest',
            'test_gate_producer_controls.ProducerTests.test_malformed_return'],
            cwd=tree, env=dict(__import__('os').environ, PYTHONPATH=str(tree/'script/upgrade')),
            capture_output=True, text=True, timeout=120)
        log = mutated.stdout + mutated.stderr
        # E contains T as an argument: remove only E, preserving argument evaluation.
        path.write_text(source)
        outer = [n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.Call)
                 and ast.unparse(n.func) == 'need' and n.args
                 and isinstance(n.args[0], ast.Constant) and n.args[0].value == 'schedule_log_data']
        assert len(outer) == 1
        e = outer[0]
        lines = source.splitlines(keepends=True)
        line = lines[e.lineno-1]
        lines[e.lineno-1] = line[:e.col_offset] + ast.unparse(e.args[1]) + line[e.end_col_offset:]
        path.write_text(''.join(lines))
        e_only = focused('test_malformed_return')
        e_shadow = focused('probe_shadow_e')
        paired_source = path.read_text()
        t = next(n for n in ast.walk(ast.parse(paired_source)) if isinstance(n, ast.Call)
                 and any(k.arg == 'gate' and isinstance(k.value, ast.Constant) and k.value.value == GATE for k in n.keywords))
        lines = paired_source.splitlines(keepends=True)
        line = lines[t.lineno-1]
        lines[t.lineno-1] = line[:t.col_offset] + ast.unparse(t.args[0]) + line[t.end_col_offset:]
        path.write_text(''.join(lines))
        both = focused('test_malformed_return')
        path.write_text(source)
        compile_gate = 'rpc_result_rebuild_artifacts_object_2'
        compile_nodes = [n for n in ast.walk(ast.parse(source)) if isinstance(n, ast.Call)
                         and any(k.arg == 'gate' and isinstance(k.value, ast.Constant)
                                 and k.value.value == compile_gate for k in n.keywords)]
        assert len(compile_nodes) == 1
        t = compile_nodes[0]
        lines = source.splitlines(keepends=True)
        line = lines[t.lineno-1]
        lines[t.lineno-1] = line[:t.col_offset] + ast.unparse(t.args[0]) + line[t.end_col_offset:]
        path.write_text(''.join(lines))
        compiled = subprocess.run([sys.executable, '-B', '-m', 'unittest',
            'test_gate_producer_controls.CompileProducerTests.test_malformed_return'],
            cwd=tree, env=dict(__import__('os').environ, PYTHONPATH=str(tree/'script/upgrade')),
            capture_output=True, text=True, timeout=120)
        compile_log = compiled.stdout + compiled.stderr
    passed = (baseline.returncode == 0 and mutated.returncode != 0 and log.count('FAIL:') >= 1
              and log.count('ERROR:') == 0 and assertion_mentions(log, GATE))
    final = (f'PRODUCER_PROBE scope=script/a3a/a3a_exec.py:1525 gate={GATE} '
             f'{"PASS" if passed else "BLOCKED"} source_sites={len(nodes)} '
             f'baseline={"green" if baseline.returncode == 0 else "RED"} '
             f'failures={log.count("FAIL:")} errors={log.count("ERROR:")} named={assertion_mentions(log, GATE)}')
    paired = (f'PRODUCER_PAIR scope=script/a3a/a3a_exec.py:1525 BLOCKED '
              f'E=schedule_log_data T={GATE} E_sites={len(outer)} '
              f'real_shadow_E={"green" if shadow_e["code"] == 0 else "RED"} '
              f'delete_E_exact_T={e_only["code"] == 0} '
              f'delete_E_failures={e_shadow["log"].count("FAIL:")} '
              f'delete_E_errors={e_shadow["log"].count("ERROR:")} '
              f'delete_E_named={assertion_mentions(e_shadow["log"], GATE)} '
              f'delete_ET_failures={both["log"].count("FAIL:")} '
              f'delete_ET_errors={both["log"].count("ERROR:")} '
              f'delete_ET_named={assertion_mentions(both["log"], GATE)} reason=T_evaluates_before_E')
    compile_passed = (baseline.returncode == 0 and compiled.returncode != 0
                      and compile_log.count('FAIL:') >= 1 and compile_log.count('ERROR:') == 0
                      and assertion_mentions(compile_log, compile_gate))
    compile_final = (f'PRODUCER_PROBE scope=script/a3a/a3a_exec.py:669 gate={compile_gate} '
                     f'{"PASS" if compile_passed else "BLOCKED"} source_sites={len(compile_nodes)} '
                     f'baseline={"green" if baseline.returncode == 0 else "RED"} '
                     f'failures={compile_log.count("FAIL:")} errors={compile_log.count("ERROR:")} '
                     f'named={assertion_mentions(compile_log, compile_gate)}')
    (out/'result.json').write_text(json.dumps(dict(final=final, paired=paired, baseline=baseline_log,
        mutation=log, shadow_e=shadow_e, e_only=e_only, e_shadow=e_shadow, both=both,
        compile_final=compile_final, compile_mutation=compile_log), indent=2)+'\n')
    print(final)
    print(paired)
    print(compile_final)
    if not (passed and compile_passed):
        print(baseline_log, log, compile_log)
    return int(not (passed and compile_passed))


if __name__ == '__main__':
    raise SystemExit(main())
