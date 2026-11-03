#!/usr/bin/env python3
"""Offline SP release evidence. No checkout, fetch, commit, tag, or live RPC actions."""
import sys
sys.dont_write_bytecode = True
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

import manifest_exec as m

a = m.a
KINDS = m.EVIDENCE_KINDS[:4]
VENDOR = 'contracts/test/crossrepo/vendor/OverIssueFraudProofVerifier.sol'
MANIFEST = 'script/upgrade/manifest_exec.py'


class Stop(RuntimeError):
    pass


def require(ok, message):
    if not ok:
        raise Stop(message)


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'duplicate JSON key: ' + key)
        value[key] = item
    return value


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def clean_commit(ref, repo):
    """Read-only git operations; accept a local tag or a commit with an exact tag."""
    def git(*args):
        r = subprocess.run(['git', *args], cwd=repo, capture_output=True, text=True)
        require(r.returncode == 0, 'local git lookup failed: ' + ' '.join(args))
        return r.stdout.strip()
    require(not git('status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none'),
            'dirty tree (tracked, untracked, or submodule changes); refusing evidence')
    require(ref and not ref.startswith('-'), 'invalid commit/tag')
    commit = git('rev-parse', '--verify', ref + '^{commit}')
    require(re.fullmatch('[0-9a-f]{40}', commit), 'expected a full commit hash')
    tags = git('tag', '--points-at', commit).splitlines()
    require(tags, 'commit must resolve from an existing local release tag')
    require(any(git('rev-parse', '--verify', 'refs/tags/' + tag + '^{commit}') == commit for tag in tags),
            'no tag resolves to the selected commit')
    return commit


def environment(forge, evm='cancun'):
    env = {k: os.environ[k] for k in ('HOME', 'PATH', 'TMPDIR', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'SVM_HOME') if k in os.environ}
    env.update(FOUNDRY_PROFILE='default', FOUNDRY_OFFLINE='true', FOUNDRY_EVM_VERSION=evm,
               PYTHONDONTWRITEBYTECODE='1', A3A_ENGINE_DIR=str(forge.parent))
    env['PATH'] = str(forge.parent) + os.pathsep + env.get('PATH', '')
    return env


@contextmanager
def capture_commands(records):
    """Also capture commands inside the shared archive/rebuild helpers."""
    original = subprocess.run
    def run(command, **kwargs):
        started = time.monotonic()
        record = dict(command=[str(x) for x in command], cwd=str(kwargs.get('cwd', Path.cwd())))
        env = kwargs.get('env', {})
        record['env'] = {k: env[k] for k in ('FOUNDRY_PROFILE', 'FOUNDRY_EVM_VERSION', 'FOUNDRY_OFFLINE') if k in env}
        records.append(record)
        try:
            result = original(command, **kwargs)
            record['exitCode'] = result.returncode
            for key in ('stdout', 'stderr'):
                value = getattr(result, key)
                if value is not None:
                    record[key] = value.decode(errors='replace') if isinstance(value, bytes) else value
            output = str(record.get('stdout', '')) + str(record.get('stderr', ''))
            if len(command) > 1 and str(command[1]) == 'test' and '--json' in command:
                record['counts'] = forge_counts(record.get('stdout', ''), record.get('stderr', ''))
            return result
        except subprocess.CalledProcessError as error:
            record.update(exitCode=error.returncode, stdout=str(error.stdout), stderr=str(error.stderr))
            raise
        except OSError as error:
            record.update(exitCode=None, error=str(error))
            raise Stop('tool unavailable: ' + str(command[0])) from error
        finally:
            record['seconds'] = time.monotonic() - started
    subprocess.run = run
    try:
        yield
    finally:
        subprocess.run = original


def run(command, tree, env):
    return subprocess.run([str(x) for x in command], cwd=tree, env=env, capture_output=True, text=True)


def tool_version(binary, tree, env):
    r = run([binary, '--version'], tree, env)
    require(r.returncode == 0 and r.stdout.strip(), f'{binary} --version failed: {r.stderr}')
    return r.stdout.strip()


def forge_results(output):
    try:
        data = json.loads(output, object_pairs_hook=unique_object)
    except ValueError as error:
        raise Stop('Forge did not return valid JSON test results') from error
    require(isinstance(data, dict) and data, 'Forge returned no suites')
    tests = []
    for suite in data.values():
        require(isinstance(suite, dict) and isinstance(suite.get('test_results'), dict)
                and suite['test_results'], 'Forge suite has no structured tests')
        for test in suite['test_results'].values():
            require(isinstance(test, dict) and test.get('status') in ('Success', 'Failure', 'Skipped'),
                    'invalid Forge test status')
            tests.append(test)
    return tests


def forge_counts(output, diagnostics=''):
    tests = forge_results(output)
    counts = {key: sum(test['status'] == status for test in tests)
              for key, status in zip(('passed', 'failed', 'skipped'), ('Success', 'Failure', 'Skipped'))}
    # JSON mode normally has no text summary. If one is present, it must agree.
    for line in diagnostics.splitlines():
        if 'Suite result:' in line or re.search(r'\bRan .*test suite', line):
            match = re.fullmatch(r'Ran \d+ test suites?[^:]*: (\d+) tests? passed; (\d+) failed; (\d+) skipped(?:;.*| \(.*\))?', line.strip())
            require(match is not None, 'unparseable Forge summary')
            require(tuple(map(int, match.groups())) == tuple(counts.values()),
                    'Forge summary disagrees with structured tests')
    return counts


def forge_test(forge, tree, path, contract=None, test=None, evm='cancun', red=None):
    command = [forge, 'test', '--json', '--offline', '--match-path', path]
    if contract:
        command += ['--match-contract', '^' + re.escape(contract) + '$']
    if test:
        command += ['--match-test', '^' + re.escape(test) + '$']
    r = run(command, tree, environment(forge, evm))
    counts = forge_counts(r.stdout, r.stderr)
    require(counts['skipped'] == 0, 'skipped Forge tests cannot produce release evidence')
    if red:
        failures = [item for item in forge_results(r.stdout) if item['status'] == 'Failure']
        require(r.returncode != 0 and counts['failed'] == 1 and counts['passed'] == 0 and
                isinstance(failures[0].get('reason'), str) and red in failures[0]['reason'],
                'mutation did not fail with the expected guardian-set error: ' + red)
    else:
        require(not any(marker in stream for stream in (r.stdout, r.stderr)
                        for marker in ('[FAIL', '[SKIP', 'Failing tests', 'Encountered')),
                'Forge output contains failure or skip markers')
        require(r.returncode == 0 and counts['passed'] > 0 and counts['failed'] == 0
                and counts['passed'] == len(forge_results(r.stdout)),
                'Forge suite failed: ' + path)
    return counts


def conformance(tree, forge, suite_map, details):
    require(suite_map is not None, 'C1–C9 mapping required: --suite-map FILE (see README); no inferred PASS labels')
    require(isinstance(suite_map, dict) and set(suite_map) == {f'C{i}' for i in range(1, 10)}, 'suite map must contain exactly C1–C9')
    total = 0
    details['suites'] = {}
    for label, spec in sorted(suite_map.items()):
        require(isinstance(spec, dict) and set(spec) == {'path', 'contract', 'evm'}, label + ' requires path, contract, evm')
        path = spec['path']
        require(isinstance(path, str) and path.endswith('.t.sol') and
                (tree / path).resolve().is_relative_to(tree.resolve()) and (tree / path).is_file(),
                'suite must name an archived .t.sol file')
        require(isinstance(spec['contract'], str) and spec['contract'], 'missing contract selector')
        require(spec['evm'] in ('cancun', 'prague'), 'unsupported suite EVM')
        require('Prague' not in spec['contract'] or spec['evm'] == 'prague', 'Prague suites require Prague EVM')
        counts = forge_test(forge, tree, path, spec['contract'], evm=spec['evm'])
        details['suites'][label] = dict(spec, counts=counts)
        total += counts['passed']
    # Independently enforce the SP-owned cross-repository Prague/provenance gates.
    for name, expected, evm in (('CC115CrossRepoConformance', 7, 'cancun'),
                                ('CC115GenuinePragueCrossRepo', 11, 'prague'),
                                ('VendoredProvenanceSelfCheck', 5, 'cancun')):
        counts = forge_test(forge, tree, f'contracts/test/crossrepo/{name}.t.sol', name, evm=evm)
        require(counts['passed'] == expected, name + ': unexpected test count')
        details['suites'][name] = dict(counts=counts, env={'FOUNDRY_EVM_VERSION': evm})
        total += counts['passed']
    return dict(controls={f'C{i}': 'PASS' for i in range(1, 10)}), total


def mutation_edit(name):
    if name == 'remove_B2':
        return MANIFEST, "        context['B2'] = b2_gate(rpc, plan, context['upgradeBlock'])", "        context['B2'] = {}"
    if name in ('remove_AGGREGATOR_getter', 'remove_REGISTRY_getter'):
        getter = name.split('_')[1]
        expr = "address_pred(verifier, '" + getter + "()', " + ('agg' if getter == 'AGGREGATOR' else 'u.REG') + '), '
        return MANIFEST, expr, ''
    if name == 'remove_bound_runtime_loop':
        return MANIFEST, "    for target, expected in plan['pin']['bindings'].items():\n        a.need('bound_runtime', u.code(rpc, target, 'latest'), expected)", '    pass'
    if name == 'remove_isEqualSet':
        return VENDOR, '        if (!_isEqualSet(guiltyGuardians, claimedSigners)) return false;', '        // Mutation: omit exact-set validation.'
    if name == 'subset_comparison':
        return VENDOR, '        uint256 n = b.length;\n        if (a.length != n) return false;', '        uint256 n = a.length;\n        if (a.length > b.length) return false;'
    if name == 'length_not_equal_to_less_than':
        return VENDOR, '        if (a.length != n) return false;', '        if (a.length < n) return false;'
    raise Stop('unknown mutation: ' + name)


def python_red_test(tree, forge, test, red=False):
    r = run([sys.executable, '-B', '-m', 'unittest', '-v', 'test_manifest_exec.ManifestTests.' + test],
            tree / 'script/upgrade', environment(forge))
    output = r.stdout + r.stderr
    require(re.search(r'Ran 1 test\b', output) and test in output, 'named mutation test did not execute')
    if red:
        require(r.returncode != 0 and 'FAILED (failures=1)' in output and 'AssertionError' in output,
                'mutation must cause an assertion failure, not a tool/import error')
    else:
        require(r.returncode == 0 and re.search(r'^OK$', output, re.M), 'restored/baseline mutation test failed')


def mutation(tree, forge, details):
    controls = {}
    passed = 0
    for name, red_test in m.MUTATIONS.items():
        relative, old, new = mutation_edit(name)
        path = tree / relative
        source = path.read_text()
        require(source.count(old) == 1, 'mutation anchor missing or ambiguous: ' + name)
        modes = ('cancun', 'prague') if relative == VENDOR else ('python',)
        for mode in modes:
            def check(red=False):
                if mode == 'python':
                    python_red_test(tree, forge, red_test, red)
                else:
                    suite = 'CC115CrossRepoConformance' if mode == 'cancun' else 'CC115GenuinePragueCrossRepo'
                    test = 'test_RealDvtVerifierPassesAssertSetBound' if mode == 'cancun' else 'test_GenuinePrague_RealDvtVerifierPassesAssertSetBound'
                    forge_test(forge, tree, f'contracts/test/crossrepo/{suite}.t.sol', suite, test, mode,
                               red_test if red else None)
            check()
            try:
                path.write_text(source.replace(old, new))
                check(red=True)
            finally:
                path.write_text(source)
            check()
            passed += 1
        controls[name] = dict(redTest=red_test, mutated='FAIL', restored='PASS')
    details['mutationModes'] = ['python', 'cancun', 'prague']
    return dict(controls=controls), passed


def slither(tree, forge, threshold, accepted, details):
    binary = shutil.which('slither')
    require(binary, 'Slither is not installed; install it locally before generating evidence (no fallback)')
    env = environment(forge)
    version = tool_version(binary, tree, env)
    report = tree / 'release-slither.json'
    build = run([forge, 'build', '--offline', '--force', '--build-info', '--skip', 'test', '--skip', 'script'], tree, env)
    require(build.returncode == 0, 'Slither input build failed')
    # Use a dedicated config: repository exclusions must not narrow the claimed threshold.
    selection = dict(detectors_to_run='all', detectors_to_exclude=None,
                     detectors_to_include=None, filter_paths=[], exclude_dependencies=False,
                     **{'exclude_' + level: False for level in
                        ('high', 'medium', 'low', 'informational', 'optimization')})
    config = tree / 'release-slither.config.json'
    write_json(config, selection)
    details['slitherSelection'] = dict(config=selection, threshold=threshold)
    report.unlink(missing_ok=True)
    r = run([binary, '.', '--config-file', config, '--compile-force-framework', 'foundry', '--ignore-compile',
             '--fail-none', '--json', report], tree, env)
    require(json.loads(config.read_text(), object_pairs_hook=unique_object) == selection, 'Slither detector selection changed')
    require(selection['detectors_to_run'] == 'all' and not selection['detectors_to_exclude'] and
            not any(selection['exclude_' + level] for level in ('high', 'medium', 'low', 'informational')),
            'Slither detector coverage does not support threshold')
    require(r.returncode == 0 and report.is_file(), 'Slither failed; no PASS evidence')
    data = json.loads(report.read_text(), object_pairs_hook=unique_object)
    require(data.get('success') is True and data.get('error') is None, 'Slither analysis was unsuccessful')
    details['slither'] = data
    results = data.get('results')
    require(isinstance(results, dict), 'invalid Slither results')
    detectors = results.get('detectors', [])
    require(isinstance(detectors, list), 'invalid Slither detectors')
    markers = re.findall(r'analyzed \((\d+) contracts with (\d+) detectors\), (\d+) result\(s\) found', r.stdout + r.stderr)
    require(len(markers) == 1 and int(markers[0][0]) > 0 and int(markers[0][1]) > 0,
            'Slither analysis completion marker missing')
    require(int(markers[0][2]) == len(detectors), 'Slither summary disagrees with findings')
    details['slitherSelection']['detectorsRun'] = int(markers[0][1])
    levels = ['Optimization', 'Informational', 'Low', 'Medium', 'High']
    ids = []
    for item in detectors:
        require(item['impact'] in levels and isinstance(item['id'], str) and item['id'], 'invalid Slither detector')
        if levels.index(item['impact']) >= levels.index(threshold):
            ids.append(item['id'])
    require(len(ids) == len(set(ids)), 'duplicate Slither finding IDs')
    require(isinstance(accepted, list) and all(isinstance(x, dict) and set(x) == {'id', 'reason'} and
            all(isinstance(v, str) and v.strip() for v in x.values()) for x in accepted), 'invalid accepted findings')
    require(sorted(ids) == sorted(x['id'] for x in accepted), 'unreviewed or stale accepted Slither findings')
    details['slither'] = data
    return dict(findings=dict(threshold=threshold, aboveThreshold=ids, accepted=accepted)), 1, version


def reproducible(commit, version, details):
    require(version.splitlines()[0] == 'forge Version: 1.7.1', 'executor requires Forge 1.7.1')
    def build():
        a.compile_commit.cache_clear()
        arts, _ = a.compile_commit(commit, version, m.NAMES, tuple(m.IMMUTABLES.items()))
        contracts = {name: dict(bytecode=art['bytecode']['object'],
                     creationHashes=m.creation_hashes(art['bytecode']['object'])) for name, art in arts.items()}
        m.rebuild_dvt.cache_clear()
        contracts['OverIssueFraudProofVerifier'] = m.rebuild_dvt()
        return contracts
    first, second = build(), build()
    hashes = {name: art['creationHashes'] for name, art in first.items()}
    differences = m.compare_build_evidence({'contracts': hashes}, second)
    details['rebuild'] = dict(metadataOnlyDifferences=differences,
        verifierCreationHashes=hashes['OverIssueFraudProofVerifier'],
        secondCreationHashes={name: art['creationHashes'] for name, art in second.items()})
    return dict(contracts=hashes), len(hashes)


def generate(kind, commit, tree, out, forge, suite_map=None, threshold='Medium', accepted=None):
    details = dict(kind=kind, subjectCommit=commit, commands=[])
    path = out / (kind + '.json')
    require(not path.exists(), 'refusing to overwrite existing evidence: ' + str(path))
    try:
        with capture_commands(details['commands']):
            env = environment(forge)
            version = tool_version(forge, tree, env)
            details['tools'] = dict(forge=version, python=sys.version)
            if kind in ('mutation', 'reproducible-build'):
                details['tools']['cast'] = tool_version(forge.parent / 'cast', tree, env)
            tool = dict(name='forge', version=version)
            if kind == 'conformance':
                payload, passed = conformance(tree, forge, suite_map, details)
            elif kind == 'mutation':
                payload, passed = mutation(tree, forge, details)
                tool = dict(name='forge + unittest', version=version + '; Python ' + sys.version)
            elif kind == 'slither':
                payload, passed, slither_version = slither(tree, forge, threshold, accepted or [], details)
                tool = dict(name='slither', version=slither_version)
                details['tools']['slither'] = slither_version
            elif kind == 'reproducible-build':
                payload, passed = reproducible(commit, version, details)
            else:
                raise Stop('unsupported kind: ' + kind)
            evidence = dict(kind=kind, subjectCommit=commit, tool=tool,
                            counts=dict(passed=passed, failed=0, skipped=0), result='PASS', **payload)
            # Validate before publishing; the schema intentionally allows no audit fields.
            with tempfile.TemporaryDirectory() as tmp:
                candidate = Path(tmp) / 'evidence.json'
                write_json(candidate, evidence)
                m.evidence_file(dict(path=str(candidate), sha256=hashlib.sha256(candidate.read_bytes()).hexdigest()), kind, commit)
            write_json(path, evidence)
            details['result'] = 'PASS'
    except Exception as error:
        details.update(result='STOP', error=str(error))
        raise
    finally:
        write_json(out / (kind + '.audit.json'), details)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='kind', required=True)
    for kind in (*KINDS, 'all'):
        p = sub.add_parser(kind)
        p.add_argument('--commit', required=True, help='existing local tag or exactly tagged commit')
        p.add_argument('--out', required=True, type=Path, help='new/empty directory outside the repository')
        p.add_argument('--suite-map', type=Path, help='reviewed C1–C9 path/contract/evm mapping')
        p.add_argument('--threshold', choices=['Informational', 'Low', 'Medium', 'High'], default='Medium')
        p.add_argument('--accepted-findings', type=Path, help='JSON array of {id, reason}; defaults to none')
    args = parser.parse_args(argv)
    out = args.out.resolve()
    previous_engine = a.ENGINE
    try:
        require(not out.is_relative_to(m.u.ROOT.resolve()), '--out must be outside the source tree')
        require(not out.exists() or not any(out.iterdir()), '--out must be new or empty; stale evidence is refused')
        commit = clean_commit(args.commit, m.u.ROOT)
        suite_map = json.loads(args.suite_map.read_text()) if args.suite_map else None
        accepted = json.loads(args.accepted_findings.read_text()) if args.accepted_findings else []
        forge = a.REBUILD_FORGE.resolve()
        a.ENGINE = forge.parent
        out.mkdir(parents=True, exist_ok=True)
        try:
            with tempfile.TemporaryDirectory(prefix='sp-release-evidence-') as tmp:
                tree = Path(tmp) / 'tree'
                records = []
                try:
                    with capture_commands(records):
                        a.archive_commit(m.u.ROOT, commit, tree)
                finally:
                    write_json(out / 'archive.audit.json', dict(subjectCommit=commit, commands=records))
                for kind in KINDS if args.kind == 'all' else (args.kind,):
                    print('Running ' + kind + ' (offline; may take several minutes)', flush=True)
                    generate(kind, commit, tree, out, forge, suite_map, args.threshold, accepted)
        finally:
            lines = [hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name for p in sorted(out.glob('*.json'))]
            (out / 'SHA256SUMS').write_text('\n'.join(lines) + '\n')
        return 0
    except (Stop, a.Gate, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print('STOP: ' + str(error), file=sys.stderr)
        return 1
    finally:
        a.ENGINE = previous_engine


if __name__ == '__main__':
    sys.exit(main())
