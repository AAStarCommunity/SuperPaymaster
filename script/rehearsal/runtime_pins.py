#!/usr/bin/env python3
"""Generate/check chain-independent runtime pins from an isolated offline release build."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from creation_pins import ROOT, CAST, release_names, clean_build_pins
from deploylive_runtime import release_artifact, masked_runtime, refuse_fixture_directory


def keccak(code):
    return subprocess.check_output([CAST, 'keccak', code], text=True).strip().lower()


def runtime_pin(runtime, runs, declarations=None):
    refs = runtime.get('immutableReferences', {})
    ranges = sorted((dict(id=str(k), start=str(r['start']), length=str(r['length']))
                     for k, values in refs.items() for r in values), key=lambda r: int(r['start']))
    if declarations is not None:
        for ref in ranges:
            ref.update(declarations[ref['id']])
    code = runtime['object']
    return dict(optimizerRuns=str(runs), runtimeLength=str(len(bytes.fromhex(code.removeprefix('0x')))),
                immutableRanges=ranges, hasImmutables=bool(ranges),
                maskedRuntimeKeccak=keccak(masked_runtime(code, refs)), rawRuntimeKeccak=keccak(code))


def masked_code(pin, code):
    refs = {}
    for r in pin['immutableRanges']:
        refs.setdefault(r['id'], []).append(dict(start=int(r['start']), length=int(r['length'])))
    return masked_runtime(code, refs)


def matches_pin(pin, code):
    try:
        return len(bytes.fromhex(code.removeprefix('0x'))) == int(pin['runtimeLength']) and keccak(masked_code(pin, code)) == pin['maskedRuntimeKeccak']
    except (ValueError, TypeError, KeyError):
        return False


def build_declarations(directory, name, artifact, builds=None):
    """Use the full matching compilation, including imported source ASTs."""
    if builds is None:
        builds = [json.loads(p.read_text()) for p in (Path(directory)/'build-info').glob('*.json')]
    found = []
    for build in (builds() if callable(builds) else builds):
        output = build.get('output', {})
        contracts = output.get('contracts', {})
        matches = [c for file in contracts.values() for n, c in file.items()
                   if n == name and c.get('evm', {}).get('deployedBytecode', {}).get('object', '').removeprefix('0x')
                   == artifact['deployedBytecode']['object'].removeprefix('0x')]
        if not matches: continue
        declarations = {}
        def walk(node):
            if isinstance(node, dict):
                if node.get('nodeType') == 'VariableDeclaration' and node.get('mutability') == 'immutable':
                    declarations[str(node['id'])] = dict(name=node['name'], type=node['typeDescriptions']['typeString'])
                for value in node.values(): walk(value)
            elif isinstance(node, list):
                for value in node: walk(value)
        walk(output.get('sources', {}))
        refs = artifact['deployedBytecode'].get('immutableReferences', {})
        if not set(refs) <= declarations.keys(): continue
        found.append({key: declarations[key] for key in refs})
    if not found or any(d != found[0] for d in found):
        raise ValueError('missing/ambiguous full build-info AST: ' + name)
    return found[0]


def artifact_pins(directory, creation_file, *, derive_types=True):
    creation = json.loads(creation_file.read_bytes())
    artifacts = {}
    from functools import lru_cache
    @lru_cache(maxsize=1)
    def builds():
        return [json.loads(p.read_text()) for p in (Path(directory)/'build-info').glob('*.json')]
    for name in release_names():
        obj = release_artifact(name, directory)
        if keccak(obj['bytecode']['object']) != creation[name]: raise ValueError('creation pin mismatch: ' + name)
        artifacts[name] = runtime_pin(obj['deployedBytecode'], 200 if name in ('Registry', 'TimelockHandoverBootstrap') else 500, build_declarations(directory, name, obj, builds) if derive_types else None)
    admin = release_artifact('SuperPaymasterAdmin', directory)
    artifacts['SuperPaymasterAdmin'] = dict(runtime_pin(admin['deployedBytecode'], 500, build_declarations(directory, 'SuperPaymasterAdmin', admin, builds) if derive_types else None),
                                           creationPin='embedded in SuperPaymaster')
    return dict(schema='runtime-pins/1', compiler=dict(solc='0.8.33', viaIR=True, evmVersion='cancun'),
                creationPinsSha256='0x' + hashlib.sha256(creation_file.read_bytes()).hexdigest(), artifacts=artifacts)


def check_runtime_pins(expected, actual, *, compare_types=True):
    if not compare_types:
        expected = json.loads(json.dumps(expected))
        for pin in expected['artifacts'].values():
            typed = {}
            for ref in pin['immutableRanges']:
                description = (ref.pop('name', None), ref.pop('type', None))
                if not all(isinstance(v, str) and v for v in description):
                    raise ValueError('untyped committed immutable')
                if ref['id'] in typed and typed[ref['id']] != description:
                    raise ValueError('inconsistent committed immutable type')
                typed[ref['id']] = description
    # AST ids identify declarations only inside one compiler output, not across builds.
    def comparable(pins):
        pins = json.loads(json.dumps(pins))
        for pin in pins['artifacts'].values():
            for ref in pin['immutableRanges']:
                ref.pop('id', None)
        return pins
    if comparable(expected) != comparable(actual): raise ValueError('runtime pin mismatch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pin_file', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    if args.artifacts and not args.check: parser.error('--artifacts requires --check')
    if args.artifacts is not None: args.artifacts = refuse_fixture_directory(args.artifacts)
    path = args.pin_file.resolve()
    if not path.is_relative_to(ROOT): raise ValueError('pin file must be in worktree')
    creation = path.with_name(path.name.replace('runtime-pins.', 'creation-pins.'))
    collect = lambda directory: artifact_pins(directory, creation, derive_types=not args.artifacts)
    actual = collect(args.artifacts) if args.artifacts else clean_build_pins(collect, build_info=True)
    if args.check:
        check_runtime_pins(json.loads(path.read_text()), actual, compare_types=not args.artifacts)
        print('INFO names/types: committed presence/consistency only; not re-derived from --artifacts' if args.artifacts else 'INFO names/types: re-derived and compared from isolated build-info')
        print('PASS runtime pins')
    else:
        path.write_text(json.dumps(actual, sort_keys=True, separators=(',', ':')) + '\n')


if __name__ == '__main__': main()
