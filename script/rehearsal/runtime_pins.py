#!/usr/bin/env python3
"""Generate/check chain-independent runtime pins from an isolated offline release build."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from creation_pins import ROOT, CAST, release_names, clean_build_pins
from deploylive_runtime import release_artifact, masked_runtime


def keccak(code):
    return subprocess.check_output([CAST, 'keccak', code], text=True).strip().lower()


def runtime_pin(runtime, runs):
    refs = runtime.get('immutableReferences', {})
    ranges = sorted((dict(id=str(k), start=str(r['start']), length=str(r['length']))
                     for k, values in refs.items() for r in values), key=lambda r: int(r['start']))
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


def artifact_pins(directory, creation_file):
    creation = json.loads(creation_file.read_bytes())
    artifacts = {}
    for name in release_names():
        obj = release_artifact(name, directory)
        if keccak(obj['bytecode']['object']) != creation[name]: raise ValueError('creation pin mismatch: ' + name)
        artifacts[name] = runtime_pin(obj['deployedBytecode'], 200 if name in ('Registry', 'TimelockHandoverBootstrap') else 500)
    return dict(schema='runtime-pins/1', compiler=dict(solc='0.8.33', viaIR=True, evmVersion='cancun'),
                creationPinsSha256='0x' + hashlib.sha256(creation_file.read_bytes()).hexdigest(), artifacts=artifacts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pin_file', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    if args.artifacts and not args.check: parser.error('--artifacts requires --check')
    path = args.pin_file.resolve()
    if not path.is_relative_to(ROOT): raise ValueError('pin file must be in worktree')
    creation = path.with_name(path.name.replace('runtime-pins.', 'creation-pins.'))
    collect = lambda directory: artifact_pins(directory, creation)
    actual = collect(args.artifacts) if args.artifacts else clean_build_pins(collect)
    if args.check:
        if json.loads(path.read_text()) != actual: raise ValueError('runtime pin mismatch')
        print('PASS runtime pins')
    else:
        path.write_text(json.dumps(actual, sort_keys=True, separators=(',', ':')) + '\n')


if __name__ == '__main__': main()
