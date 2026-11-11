#!/usr/bin/env python3
"""Self-checks for aoa-a7-readback/1: both examples validate, known-bad instances are rejected,
and no oneOf node lets one value match two branches (the defect that made every live file fail)."""
import copy
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator

HERE = Path(__file__).resolve().parent
SCHEMA = json.loads((HERE / 'aoa-a7-readback-1.schema.json').read_text())
EXAMPLES = ('aoa-a7-readback-1.example.json', 'aoa-a7-readback-1.live.example.json')
PROBES = [None, 'n/a:x', 'unreadable:x', 'plain', '0x' + '1' * 40, '0x' + 'a' * 64,
          '4e8874b2bdc840929585ca73e170993c50a4a531', 'c' * 64, True, 0, 7, [], {}, '0x6c1d9423']


def oneof_overlaps(schema):
    found = []

    def walk(node, path):
        if isinstance(node, dict):
            if 'oneOf' in node:
                for value in PROBES:
                    matches = sum(Draft202012Validator(dict(branch, **{'$defs': schema['$defs']})).is_valid(value)
                                  for branch in node['oneOf'])
                    if matches > 1:
                        found.append(f'{path}: {value!r} matches {matches} branches')
            for key, child in node.items():
                walk(child, f'{path}/{key}')
        elif isinstance(node, list):
            for index, child in enumerate(node):
                walk(child, f'{path}[{index}]')

    walk(schema, '#')
    return found


def negatives(base):
    omitted = copy.deepcopy(base)
    del omitted['contracts']['superPaymaster']['guardian']
    bare = copy.deepcopy(base)
    bare['contracts']['superPaymaster']['owner'] = 'unreadable'
    extra = copy.deepcopy(base)
    extra['unexpected'] = 1
    null_version = copy.deepcopy(base)
    null_version['contracts']['disclosureRegistry']['version'] = None
    answering_extension = copy.deepcopy(base)
    answering_extension['contracts']['spAdminExtension']['version'] = 'SuperPaymasterAdmin-0.0.0'
    no_simulate = copy.deepcopy(base)
    del no_simulate['amsterdamProbe']['estimateSimulate']
    return {'missing estimateSimulate': no_simulate, 'omitted required field': omitted, 'bare "unreadable"': bare,
            'top-level extra key': extra, 'null version on a versioned contract': null_version,
            'version on a no-version contract': answering_extension}


def main():
    Draft202012Validator.check_schema(SCHEMA)
    validator = Draft202012Validator(SCHEMA)
    failures = []
    for name in EXAMPLES:
        errors = sorted(validator.iter_errors(json.loads((HERE / name).read_text())), key=str)
        print(f'{name}: {"VALID" if not errors else "INVALID"}')
        failures += [f'{name}: {e.message}' for e in errors]
    for name in EXAMPLES:
        instance = json.loads((HERE / name).read_text())
        c = instance['contracts']
        if 'spAdminExtension' in c and c['superPaymaster']['extensionCodehash'] != c['spAdminExtension']['codehash']:
            failures.append(f'{name}: superPaymaster.extensionCodehash != spAdminExtension.codehash')
        probe = instance['amsterdamProbe']
        judged = [v for v in probe['estimateSimulate'].values() if isinstance(v, int)]
        if not judged or any(v != probe['gasUsedFork'] or v != probe['expected']['gasUsed'] for v in judged) \
                or not all(probe['callAtGasUsed'].values()):
            failures.append(f'{name}: amsterdamProbe predicate does not hold')
    base = json.loads((HERE / EXAMPLES[0]).read_text())
    for label, instance in negatives(base).items():
        rejected = not validator.is_valid(instance)
        print(f'negative {label}: {"REJECTED" if rejected else "ACCEPTED"}')
        if not rejected:
            failures.append(f'negative accepted: {label}')
    overlaps = oneof_overlaps(SCHEMA)
    print('oneOf overlaps:', overlaps or 'none')
    failures += overlaps
    if failures:
        print('SCHEMA SELF-CHECK FAIL', *failures, sep='\n')
        return 1
    print('SCHEMA SELF-CHECK PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
