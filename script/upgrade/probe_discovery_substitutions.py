#!/usr/bin/env python3
"""6j offline single-site substitutions in a temporary tracked-tree copy."""
import ast
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

CASES = (4, 6, 15, 16, 18, 19, 23, 24, 25)
GAPS = (0, 1, 2, 3, 5, 7, 8, 10, 11, 17, 20)


def run(index):
    import test_manifest_exec as t
    from gate_assertions import assertion_mentions
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output).run(unittest.TestSuite([
        t.DiscoverySubstitutionTests('test_call_' + str(index))]))
    return dict(green=result.wasSuccessful(), failures=len(result.failures), errors=len(result.errors),
                named=any(assertion_mentions(message, t.DISCOVERY_CALLS[index][2])
                          for _, message in result.failures), log=output.getvalue())


def main():
    import test_manifest_exec as t
    root = Path(__file__).resolve().parents[2]
    source = Path(t.m.__file__).read_text()
    fixture = t.DiscoverySubstitutionTests()
    fixture.setUp()
    # These fields are constructed solely from literals/constants in setUp, not
    # from current_discovery, discover_targets, or any transitive production call.
    values = {23: fixture.pin, 4: fixture.good, 6: fixture.good,
              15: {**{k: [v] for k, v in fixture.targets.items()}, 'xPNTsToken': fixture.tokens},
              16: fixture.CODE, 18: fixture.WORD_ZERO, 19: fixture.WORD_ZERO,
              24: fixture.array([]), 25: fixture.array(fixture.tokens)}
    sources = {23: 'setUp.pin (literal clean inventory)', 4: 'setUp.good', 6: 'setUp.good', 15: 'setUp.targets+tokens',
               16: 'CODE', 18: 'WORD_ZERO', 19: 'WORD_ZERO',
               24: 'array([])', 25: 'array(setUp.tokens=sorted(ROUND_CLONES))'}
    passed = 0
    with tempfile.TemporaryDirectory(prefix='commit6j-') as directory:
        tree_root = Path(directory) / 'tree'
        tracked = subprocess.run(['git', 'ls-files', '-z'], cwd=root, check=True, capture_output=True).stdout.decode().split('\0')
        for relative in tracked:
            path = root / relative
            if relative and not path.name.startswith('.env') and path.is_file():
                dest = tree_root / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, dest)
        # Include this new, intentionally uncommitted test-only probe.
        shutil.copy2(__file__, tree_root / 'script/upgrade' / Path(__file__).name)
        target = tree_root / 'script/upgrade/manifest_exec.py'
        for index in CASES:
            function, expression, gate = t.DISCOVERY_CALLS[index]
            tree = ast.parse(source)
            fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == function)
            sites = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and ast.get_source_segment(source, n) == expression]
            baseline = run(index)
            if len(sites) != 1:
                print(f'{index}: gate={gate} sites={len(sites)} FAIL')
                continue
            site = sites[0]
            lines = source.splitlines(keepends=True)
            start = sum(map(len, lines[:site.lineno-1])) + site.col_offset
            end = sum(map(len, lines[:site.end_lineno-1])) + site.end_col_offset
            target.write_text(source[:start] + repr(values[index]) + source[end:])
            proc = subprocess.run([sys.executable, '-B', str(tree_root / 'script/upgrade' / Path(__file__).name),
                                   '--worker', str(index)], cwd=tree_root, capture_output=True, text=True)
            result = json.loads(proc.stdout) if proc.returncode == 0 else dict(failures=0, errors=1, named=False, log=proc.stderr)
            good = baseline['green'] and result['failures'] >= 1 and result['errors'] == 0 and result['named']
            passed += good
            print(f'{index}: gate={gate} sites=1 baseline={"green" if baseline["green"] else "RED"} '
                  f'failures={result["failures"]} errors={result["errors"]} named={str(result["named"]).lower()} '
                  f'substitute=DiscoverySubstitutionTests.{sources[index]} {"PASS" if good else "FAIL"}')
            if not good: print(baseline['log'] + result['log'])
    for index in GAPS:
        print(f'{index}: gate={t.DISCOVERY_CALLS[index][2]} GAP source-control=DiscoveryCallTests.test_call_{index}')
    print(f'COMMIT6J_PROBES {"PASS" if passed == len(CASES) else "FAIL"} method_a={passed}/{len(CASES)} gaps={len(GAPS)} total=20')
    return int(passed != len(CASES))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--worker':
        print(json.dumps(run(int(sys.argv[2]))))
    else:
        raise SystemExit(main())
