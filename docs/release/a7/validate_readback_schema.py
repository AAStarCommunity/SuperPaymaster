#!/usr/bin/env python3
"""Self-checks for aoa-a7-readback/1: both examples validate, known-bad instances are rejected,
and no oneOf node lets one value match two branches (the defect that made every live file fail)."""
import copy
import re
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


URL_LIKE = re.compile(r'(?i)([a-z][a-z0-9+.-]*://|\b(?:https?|wss?|ftp|file):)')


def url_like_strings(node, path='$'):
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            found += url_like_strings(value, f'{path}.{key}')
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found += url_like_strings(value, f'{path}[{index}]')
    elif isinstance(node, str) and URL_LIKE.search(node):
        found.append(path)
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
    no_community = copy.deepcopy(base)
    del no_community['contracts']['evaluationCommunityToken']
    no_registry = copy.deepcopy(base)
    del no_registry['contracts']['registry']
    roles_obj = copy.deepcopy(base)
    roles_obj['contracts']['blsAggregator']['roles'] = {}
    no_pending = copy.deepcopy(base)
    del no_pending['contracts']['blsAggregator']['pendingFraudProofVerifierReadyAt']
    no_writer = copy.deepcopy(base)
    del no_writer['contracts']['disclosureRegistry']['WRITER']
    no_slot = copy.deepcopy(base)
    del no_slot['contracts']['blsAggregator']['guardianSet'][0]['slot']
    no_timelock = copy.deepcopy(base)
    del no_timelock['contracts']['timelockController']
    registry_na_roles = copy.deepcopy(base)
    registry_na_roles['contracts']['registry']['roles'] = 'n/a:not deployed'
    top_level = {}
    for key in ('schema', 'header', 'contracts', 'checks', 'amsterdamProbe'):
        top_level[f'missing top-level {key}'] = copy.deepcopy(base)
        del top_level[f'missing top-level {key}'][key]
    return {**top_level, 'missing timelockController': no_timelock, 'registry roles n/a': registry_na_roles,
            'guardianSet entry without slot': no_slot,
            'roles object on a contract without a role system': roles_obj,
            'missing blsAggregator.pendingFraudProofVerifierReadyAt': no_pending,
            'missing disclosureRegistry.WRITER': no_writer,
            'missing registry (release-set key)': no_registry, 'missing evaluationCommunityToken': no_community, 'missing estimateSimulate': no_simulate, 'omitted required field': omitted, 'bare "unreadable"': bare,
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
        urls = url_like_strings(instance)
        if urls:
            failures.append(f'{name}: URL-like strings at {urls}')
        thresholds = c['blsAggregator'].get('thresholds')
        if isinstance(thresholds, dict) and set(thresholds) != {'WARNING', 'MINOR', 'MAJOR'}:
            failures.append(f'{name}: blsAggregator.thresholds must list WARNING, MINOR and MAJOR')
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
