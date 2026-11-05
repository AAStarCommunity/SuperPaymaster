#!/usr/bin/env python3
"""Deletion probes for the ENDUSER mapping-control ruling (DSR 2026-11-05).

Each probe deletes exactly one site (the pattern must match once) in a scratch copy of script/, then runs its
bound test there: the baseline must pass and the mutated copy must fail that test with the named cause
(the gate that now STOPs, or the TypeError the deleted gate used to pre-empt).
Prints ENDUSER_PROBES PASS only if every probe is red and every baseline is green.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
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
     "TypeError: 'NoneType' object is not subscriptable"),
    # Codex P2: ENDUSER in roleHistory proves discovery only; skipping its control path must still go red.
    ('enduser_role_control_skipped',
     '                role_control(name,target,role,spec)\n',
     '                if role != ROLE_ENDUSER: role_control(name,target,role,spec)\n',
     'OldOwnerIsolationTests.test_mapping_enduser_without_control_holder',
     'AssertionError: Lists differ: [] != [True]'),
]


def run(tree, test):
    proc = subprocess.run([sys.executable, '-B', TESTS, test], cwd=tree, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)
    tail = [line for line in proc.stderr.splitlines() if line.startswith(('Ran ', 'OK', 'FAILED'))]
    return proc.returncode, ' '.join(tail), proc.stderr


def main():
    ok = True
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
        named = cause in mut_err
        red = count == 1 and base_rc == 0 and mut_rc != 0 and 'FAILED' in mut_tail and named
        ok &= red
        print(f'{name}: matches={count} baseline=rc{base_rc} [{base_tail}] removed=rc{mut_rc} [{mut_tail}] cause={named} '
              f'{"red" if red else "NOT RED"}')
    print('ENDUSER_PROBES', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
