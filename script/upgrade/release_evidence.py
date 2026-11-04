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
    """Capture shared helpers too. Global patch: sequential use only, not parallel-safe."""
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
        # Forge 1.7 matches --match-test against the signature `name()`; an anchored bare name finds no tests.
        command += ['--match-test', '^' + re.escape(test) + r'\(\)$']
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


CONFORMANCE_MAP = 'script/evidence/a4-conformance-record.template.json'

# Run one exact unittest method, rejecting absent/ambiguous selectors and skips.
CHECKER_RUNNER = r"""
import importlib.util, json, pathlib, sys, unittest
path, name, output = sys.argv[1:]
path = pathlib.Path(path).resolve()
sys.path.insert(0, str(path.parent))
spec = importlib.util.spec_from_file_location(path.stem, path)
module = importlib.util.module_from_spec(spec)
# unittest looks module fixtures up in sys.modules; unregistered, setUpModule/tearDownModule are silently skipped.
sys.modules[spec.name] = module
spec.loader.exec_module(module)
def flatten(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from flatten(item)
        else:
            yield item
selected = [t for t in flatten(unittest.defaultTestLoader.loadTestsFromModule(module))
            if t.id().split('.')[-1] == name]
if len(selected) != 1:
    raise RuntimeError('named test missing or ambiguous: ' + name)
identity = selected[0].id()
result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(selected))
failed = len(result.failures) + len(result.errors) + len(result.unexpectedSuccesses)
skipped = len(result.skipped) + len(result.expectedFailures)
# Module/class fixture errors and skips are counted without running the test, so testsRun can be 0.
passed = max(0, result.testsRun - failed - skipped)
pathlib.Path(output).write_text(json.dumps(dict(test=identity, run=result.testsRun,
    passed=passed, failed=failed, skipped=skipped)))
sys.exit(0 if result.wasSuccessful() and not skipped and result.testsRun == 1 and passed == 1 else 1)
"""



def install_node_deps(tree):
    """The archive has no node_modules; the A6 collector checks need viem. Install exactly the lockfile, offline."""
    lock = tree / 'pnpm-lock.yaml'
    require(lock.is_file(), 'archived pnpm-lock.yaml required for node checker dependencies')
    pnpm = shutil.which('pnpm')
    require(pnpm is not None, 'pnpm not found; cannot install pinned node dependencies')
    r = subprocess.run([pnpm, 'install', '--frozen-lockfile', '--offline', '--ignore-scripts'],
                       cwd=tree, capture_output=True, text=True)
    require(r.returncode == 0, 'pnpm install --frozen-lockfile --offline failed (store not primed?): '
            + (r.stderr or r.stdout)[-400:])
    require((tree / 'node_modules' / 'viem' / 'package.json').is_file(), 'viem missing after pinned install')

def checker_test(tree, forge, ref):
    path = (tree / ref['suite']).resolve()
    require(path.is_relative_to(tree.resolve()) and path.suffix == '.py' and path.is_file(),
            'suite must name an archived Python file')
    require(isinstance(ref['test'], str) and ref['test'].startswith('test'), 'invalid named test')
    with tempfile.TemporaryDirectory(prefix='sp-checker-') as tmp:
        report = Path(tmp) / 'result.json'
        r = run([sys.executable, '-B', '-c', CHECKER_RUNNER, path, ref['test'], report],
                tree, environment(forge))
        require(report.is_file(), 'named checker test produced no result: ' + ref['test'])
        outcome = json.loads(report.read_text(), object_pairs_hook=unique_object)
    require(r.returncode == 0 and outcome.get('run') == 1 and outcome.get('passed') == 1
            and outcome.get('failed') == 0 and outcome.get('skipped') == 0
            and outcome.get('test', '').split('.')[-1] == ref['test'],
            'named checker test failed or skipped: ' + ref['test'])
    return outcome


def conformance(tree, forge, details):
    mapping = tree / CONFORMANCE_MAP
    require(mapping.is_file(), 'archived conformance mapping required')
    template = json.loads(mapping.read_text(), object_pairs_hook=unique_object)
    controls = template['controls']
    require(template.get('scope') == 'checker-logic-offline', 'invalid conformance scope')
    require(isinstance(controls, dict) and set(controls) == {f'C{i}' for i in range(1, 10)},
            'mapping must contain exactly C1–C9')
    details['controls'] = {}
    total = 0
    emitted = {}
    for label, spec in sorted(controls.items()):
        require(isinstance(spec, dict) and set(spec) ==
                {'suite', 'test', 'positiveControl', 'negativeControl', 'result'}, 'invalid item: ' + label)
        for field in ('positiveControl', 'negativeControl'):
            require(isinstance(spec[field], list) and spec[field], label + ' missing ' + field)
            require(all(isinstance(ref, dict) and set(ref) == {'suite', 'test'} for ref in spec[field]),
                    label + ' invalid ' + field)
        outcomes = []
        details['controls'][label] = outcomes
        refs = [dict(suite=spec['suite'], test=spec['test'])] + spec['positiveControl'] + spec['negativeControl']
        for ref in refs:
            outcome = checker_test(tree, forge, ref)
            outcomes.append(dict(ref, outcome=outcome))
            total += outcome['passed']
        emitted[label] = dict(spec, result='PASS')
    return dict(scope='checker-logic-offline', controls=emitted), total


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


def compiled_scope(tree):
    """Resolve import closures and inheritance within each build-info unit."""
    roots, root_nodes, signatures = {}, {}, {}
    files = set()
    units = sorted((tree / 'out/build-info').glob('*.json'))
    require(units, 'missing compiled scope build-info')
    for unit in units:
        data = json.loads(unit.read_text(), object_pairs_hook=unique_object)
        sources = data.get('output', {}).get('sources', {})
        require(sources, 'missing compiled scope build-info sources')
        nodes = {}
        for source, output in sources.items():
            ast = output.get('ast', {})
            require(ast.get('absolutePath') == source, 'missing or invalid compiled source AST')
            for node in ast.get('nodes', []):
                if node.get('nodeType') == 'ContractDefinition':
                    require(node['id'] not in nodes, 'conflicting compiler AST IDs within unit')
                    nodes[node['id']] = (source, node)
        # AdminCalls is the explicitly required Solidity facade, not an inherited base.
        for name in (*m.NAMES, 'SuperPaymasterAdminCalls'):
            matches = [n for n in nodes.values()
                       if n[1]['name'] == name and n[0].startswith('contracts/src/')]
            require(len(matches) <= 1, 'ambiguous compiled scope root: ' + name)
            if not matches:
                continue
            source, node = matches[0]
            chain = []
            unit_files = set()
            pending = [source]
            while pending:
                path = pending.pop()
                if path in unit_files:
                    continue
                require(path in sources, 'missing compiled import AST in unit: ' + path)
                unit_files.add(path)
                for imported in sources[path]['ast'].get('nodes', []):
                    if imported.get('nodeType') == 'ImportDirective':
                        target = imported.get('absolutePath')
                        require(isinstance(target, str) and target in sources,
                                'missing compiled import AST in unit: ' + str(target))
                        pending.append(target)
            for base in node['linearizedBaseContracts']:
                require(base in nodes, 'missing compiled base AST in unit: ' + unit.name)
                path, definition = nodes[base]
                content = data.get('input', {}).get('sources', {}).get(path, {}).get('content')
                require(isinstance(content, str), 'missing compiled source content: ' + path)
                chain.append((path, definition['name'], definition['contractKind'], content))
            # IDs and source indices differ between units. Compare source identity,
            # exact contents and ordered inheritance instead of numeric AST IDs.
            signature = (source, chain)
            require(name not in signatures or signatures[name] == signature,
                    'non-identical duplicate compiled scope root: ' + name)
            signatures[name] = signature
            roots[name] = (source, node)
            root_nodes[name] = nodes
            files.update(unit_files)
    for name in (*m.NAMES, 'SuperPaymasterAdminCalls'):
        require(name in roots, 'missing compiled scope root: ' + name)
    files = {canonical_source_path(f, tree, scope=True) for f in files}
    return dict(contracts=list(m.NAMES), files=sorted(files)), roots, root_nodes


def layout_table(data):
    types = data['types']
    def expand(key, seen=()):
        require(key in types, 'missing storage type')
        t = types[key]
        if key in seen:
            return dict(label=t['label'])
        result = {k: t[k] for k in ('label', 'encoding', 'numberOfBytes')}
        for field in ('key', 'value', 'base'):
            if field in t:
                result[field] = expand(t[field], (*seen, key))
        if 'members' in t:
            result['members'] = [entry(x, (*seen, key)) for x in t['members']]
        return result
    def entry(x, seen=()):
        return dict(label=x['label'], slot=x['slot'], offset=x['offset'], type=expand(x['type'], seen))
    require(isinstance(data['storage'], list) and data['storage'], 'empty storage layout')
    return [entry(x) for x in data['storage']]


def namespace_table(tree, root, nodes):
    """Solc omits ERC-7201 storage. Check the shared declaration and slot binding explicitly.

    The release uses OZ Initializable and the repo's pending-owner namespace.
    Unknown annotated namespaces STOP
    rather than silently producing a partial parity claim.
    """
    tables = []
    for base in root[1]['linearizedBaseContracts']:
        path, node = nodes[base]
        if node.get('name') == 'Ownable2StepNamespaced':
            source = (tree / path).read_text()
            slots = re.findall(r'bytes32 internal constant OWNERSHIP_2STEP_SLOT\s*=\s*(0x[0-9a-fA-F]{64});', source)
            require(len(slots) == 1 and
                    re.search(r'function pendingOwner\(\) public view virtual returns \(address p\)', source) and
                    re.search(r'function _setPendingOwner\(address p\) private', source) and
                    source.count('bytes32 slot = OWNERSHIP_2STEP_SLOT;') == 2 and
                    'p := sload(slot)' in source and 'sstore(slot, p)' in source,
                    'pending-owner namespace binding changed')
            tables.append(dict(label='aastar.storage.Ownership2Step._pendingOwner',
                               slot=str(int(slots[0], 16)), offset=0, type='address'))
        for member in node.get('nodes', []):
            doc = member.get('documentation') or {}
            text = doc.get('text', '') if isinstance(doc, dict) else doc
            if '@custom:storage-location' not in text:
                continue
            require(member['name'] == 'InitializableStorage' and
                    'erc7201:openzeppelin.storage.Initializable' in text, 'unsupported storage namespace')
            fields = [(x['name'], x['typeDescriptions']['typeString']) for x in member['members']]
            require(fields == [('_initialized', 'uint64'), ('_initializing', 'bool')], 'namespace layout changed')
            source = (tree / path).read_text()
            slots = re.findall(r'bytes32 private constant INITIALIZABLE_STORAGE = (0x[0-9a-fA-F]{64});', source)
            require(len(slots) == 1 and '$.slot := INITIALIZABLE_STORAGE' in source, 'namespace slot binding changed')
            for (label, typ), offset in zip(fields, (0, 8)):
                tables.append(dict(label='openzeppelin.storage.Initializable.' + label,
                                   slot=str(int(slots[0], 16)), offset=offset, type=typ))
    return tables


def storage_consistency(tree, forge, roots, nodes, details):
    pairs = []
    details['storageLayout'] = pairs
    for core, extension, reference in m.LAYOUT_PAIRS:
        tables = []
        for name in (core, extension):
            target = roots[name][0] + ':' + name
            r = run([forge, 'inspect', target, 'storageLayout', '--json', '--offline'], tree, environment(forge))
            require(r.returncode == 0, 'storage layout inspect failed: ' + name)
            table = layout_table(json.loads(r.stdout, object_pairs_hook=unique_object))
            tables.append(dict(storage=table, namespaces=namespace_table(tree, roots[name], nodes[name])))
        refs = []
        test_path = 'contracts/test/v2/SuperPaymasterD5bGov2.t.sol'
        test_name = 'test_gov2_sp_pendingOwner_erc7201_slot'
        if core == 'SuperPaymaster' and (tree / test_path).is_file() and test_name in (tree / test_path).read_text():
            refs.append(test_path + ':' + test_name)
        pair = dict(core=core, extension=extension, reference=reference, testReferences=refs,
                    coreTable=tables[0], extensionTable=tables[1])
        pairs.append(pair)
        require(tables[0] == tables[1], 'storage layout mismatch: ' + core + ' vs ' + extension)
    return pairs


def canonical_source_path(filename, tree, *, scope=False):
    path = (tree / filename).resolve()
    root = tree.resolve()
    if scope:
        require(path.is_relative_to(root) and path.is_file(), 'invalid compiled scope path')
    return path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path)


def finding_files(item, tree):
    files = set()
    for element in item.get('elements', []):
        mapping = element.get('source_mapping', {})
        filename = mapping.get('filename_relative') or mapping.get('filename_absolute')
        if filename:
            files.add(canonical_source_path(filename, tree))
    require(files, 'Slither finding has no source location: ' + item['id'])
    return sorted(files)


def slither(tree, forge, threshold, accepted, details):
    binary = shutil.which('slither')
    require(binary, 'Slither is not installed; install it locally before generating evidence (no fallback)')
    env = environment(forge)
    version = tool_version(binary, tree, env)
    with tempfile.TemporaryDirectory(prefix='sp-slither-') as tmp:
        report = Path(tmp) / 'release-slither.json'
        build = run([forge, 'build', '--offline', '--force', '--ast', '--build-info', '--skip', 'test', '--skip', 'script'], tree, env)
        require(build.returncode == 0, 'Slither input build failed')
        scope, roots, nodes = compiled_scope(tree)
        details['scope'] = scope
        layouts = storage_consistency(tree, forge, roots, nodes, details)
        # Use a dedicated config: repository exclusions must not narrow the claimed threshold.
        selection = dict(detectors_to_run='all', detectors_to_exclude=None,
                         detectors_to_include=None, filter_paths=[], exclude_dependencies=False,
                         **{'exclude_' + level: False for level in
                            ('high', 'medium', 'low', 'informational', 'optimization')})
        config = Path(tmp) / 'release-slither.config.json'
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
        ids, outside, all_ids = [], [], []
        for item in detectors:
            require(item['impact'] in levels and isinstance(item['id'], str) and item['id'], 'invalid Slither detector')
            all_ids.append(item['id'])
            files = finding_files(item, tree)
            if not set(files).intersection(scope['files']):
                outside.append(dict(id=item['id'], impact=item['impact'], files=files, classification='unclassified'))
            elif levels.index(item['impact']) >= levels.index(threshold):
                ids.append(item['id'])
        require(len(all_ids) == len(set(all_ids)), 'duplicate Slither finding IDs')
        require(isinstance(accepted, list), 'invalid accepted findings')
        for item in accepted:
            require(isinstance(item, dict) and {'id', 'classification', 'reason'} <= set(item)
                    and set(item) <= {'id', 'classification', 'reason', 'row', 'check', 'location'}
                    and item['classification'] in ('false-positive', 'accepted')
                    and all(isinstance(item[k], str) and item[k].strip() for k in ('id', 'reason')),
                    'invalid accepted findings')
        classified = [x['id'] for x in accepted]
        require(len(classified) == len(set(classified)), 'duplicate classifications')
        require(len(ids) == len(classified) and set(ids) == set(classified),
                'unreviewed or stale accepted Slither findings; in-scope total must equal classification count')
        return dict(findings=dict(threshold=threshold, aboveThreshold=ids, accepted=accepted,
                                 outOfScope=outside, inScopeTotal=len(ids)),
                    scope=scope, storageLayout=layouts), 1, version



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
    differences = m.compare_build_evidence({'contracts': hashes}, second, first)
    details['rebuild'] = dict(metadataOnlyDifferences=differences,
        creationMetadataLayouts={'OverIssueFraudProofVerifier': m.VERIFIER_METADATA_LAYOUT},
        verifierCreationHashes=hashes['OverIssueFraudProofVerifier'],
        secondCreationHashes={name: art['creationHashes'] for name, art in second.items()})
    return dict(contracts=hashes), len(hashes)


def generate(kind, commit, tree, out, forge, threshold='Medium', accepted=None):
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
                payload, passed = conformance(tree, forge, details)
                tool = dict(name='unittest', version=sys.version)
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
        p.add_argument('--threshold', choices=['Informational', 'Low', 'Medium', 'High'], default='Medium')
        p.add_argument('--accepted-findings', type=Path, help='JSON array of {id, classification, reason, row?}; DSR check/location fields accepted')
    args = parser.parse_args(argv)
    out = args.out.resolve()
    previous_engine = a.ENGINE
    try:
        require(not out.is_relative_to(m.u.ROOT.resolve()), '--out must be outside the source tree')
        require(not out.exists() or not any(out.iterdir()), '--out must be new or empty; stale evidence is refused')
        commit = clean_commit(args.commit, m.u.ROOT)
        accepted = json.loads(args.accepted_findings.read_text(), object_pairs_hook=unique_object) if args.accepted_findings else []
        forge = a.REBUILD_FORGE.resolve()
        a.ENGINE = forge.parent
        out.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='sp-release-evidence-') as tmp:
            tree = Path(tmp) / 'tree'
            records = []
            try:
                with capture_commands(records):
                    a.archive_commit(m.u.ROOT, commit, tree)
                    install_node_deps(tree)
            finally:
                write_json(out / 'archive.audit.json', dict(subjectCommit=commit, commands=records))
            for kind in KINDS if args.kind == 'all' else (args.kind,):
                print('Running ' + kind + ' (offline; may take several minutes)', flush=True)
                generate(kind, commit, tree, out, forge, args.threshold, accepted)
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
