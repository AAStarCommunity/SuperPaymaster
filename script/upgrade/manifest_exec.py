#!/usr/bin/env python3
"""Phase A/B/D unsigned manifest builder and authenticated fork-only rehearsal."""
import sys
sys.dont_write_bytecode = True
import ast
import argparse
import copy
import hashlib
import json
import re
import os
import tempfile
from functools import lru_cache
from pathlib import Path
import subprocess
import sp_upgrade_exec as u
import old_owner_isolation as isolation

a = u.a
ANNI = '0xecaacb915f7d92e9916f449f7ad42bd0408733c9'
AGG_VERSION = 'BLSAggregator-4.12.0'
FRAUD_SIG = 'queueGuardianSlash(uint256,address[],bytes)'
EVIDENCE_KINDS = ('conformance', 'mutation', 'slither', 'reproducible-build', 'dvt-ci', 'dvt-conformance-4.12')
BUFFER = 10**17
DAY = 86400
PENDING_TOKEN_ETA = 1794226596
PENDING_OWNER_SLOT = '0xdb5a3168abaa6147a9f3a4cb66016161119d4d50b6393344d27120286f742a00'
DVT = '0x568b1486bfe036e603ea11f0d03dc47fa62c9e0e'
COMMITTEE = '0x7ac7e9d471742fa4397beef0b5b11fbd22d196a9'
OLD_AGGREGATOR = '0xeaec2f512ea50708211fa95533e4dbb60e3d2e5d'
# DSR 2026-11-04: sole address-exact exception; never supplied by a plan.
# BLSAggregator-4.11.0 (7c732e70), SDK #413 / 667b1bb2,
# tests/regression/onchain-evidence/dvt-onboard-e2e.ts:145: one-shot key
# generated in memory and discarded. readyAt=1788933060, expiresAt=1789019460.
# Request: 0xe4737f3924f5488e1d037532dbae71b1f0efc91fa6544f92799e112402c82d38
# syncExitNotice: 0xaad53b17a7a3d59ab0d171c7126a7d2341c82d54741c0f1ea04420d130425524
OLD_EXIT_EXEMPTIONS = frozenset({'0xf36c9317765634e4995ce1e7210b5738225425b0'})
# DSR 2026-11-05: duplicate DVT E2E credit-over-limit proposals (2026-07-07/08, blocks 11223327-11228495):
# each validator proposed the same event and one sibling per evidence hash executed.
# DVTValidator has no cancel path, so these stay open; exact ids only, never plan-supplied.
STALE_PROPOSAL_OPERATOR = '0xf7bf79acb7f3702b9dbd397d8140ac9de6ce642c'
STALE_PROPOSAL_NEXT_ID = 10
STALE_PROPOSALS = {
    1: (3, 0x6d1c0d602056be56edf7a5086903bc1a4b9dc082ca8a31df4c4e6ca3d77d5237),
    2: (3, 0x6d1c0d602056be56edf7a5086903bc1a4b9dc082ca8a31df4c4e6ca3d77d5237),
    4: (3, 0x6d1c0d602056be56edf7a5086903bc1a4b9dc082ca8a31df4c4e6ca3d77d5237),
    5: (3, 0x6d1c0d602056be56edf7a5086903bc1a4b9dc082ca8a31df4c4e6ca3d77d5237),
    6: (3, 0x6d1c0d602056be56edf7a5086903bc1a4b9dc082ca8a31df4c4e6ca3d77d5237),
    8: (7, 0x64357531834ff863e1207cea92dcf62db5ecf498d87cd629cb0e27e9d1247d79),
    9: (7, 0x64357531834ff863e1207cea92dcf62db5ecf498d87cd629cb0e27e9d1247d79),
}
VERIFIER_COMMIT = '72aca4fa0ba4aaa8c8a96210b1124534431294d6'
VERIFIER_SHA256 = '4d7e0125094c381a0dca5e2d8dd56efa79b284e43119fd64130dfaa78d33e7d6'
# Offline archive rebuild of 72aca4fa, Forge 1.7.1 / solc 0.8.33.
# Raw runtime fixes immutable owner to zero; drill changes only storage slot zero.
MOCK_TOKEN_STRIPPED_RUNTIME_HASH = '0xb4dcef54c1bf03ed09b0c6dcd6b78699d4801a3e6baf044ddd531c72acb74a86'
MOCK_TOKEN_OVER_SELECTOR = '0xbeaf15d9'
MOCK_TOKEN_RUNTIME_HASH = '0xae01c0c01f84a229b8c6f3591a70f678ea5d48ff956a90661ae669bf1be6d0db'

MUTATIONS = {
    'remove_B2': 'test_pre_send_real_b2_is_required',
    'remove_AGGREGATOR_getter': 'test_a12a_getters_are_enforced',
    'remove_REGISTRY_getter': 'test_a12a_getters_are_enforced',
    'remove_bound_runtime_loop': 'test_pre_send_bound_runtime_is_required',
    'remove_isEqualSet': 'VerifierAcceptsGuardianSubset',
    'subset_comparison': 'VerifierAcceptsGuardianSubset',
    'length_not_equal_to_less_than': 'VerifierAcceptsGuardianSuperset',
}
STAGES = ('a7', 'b4', 'c', 'full')
DVT_SUITES = {'CC115CrossRepoConformance': 7, 'CC115GenuinePragueCrossRepo': 11, 'provenance': 5}

VERIFIER_CREATION = '0x736520628b9e5ed4163f440e4e7b5d064b4e4cb4571c29d926941964e038e3ab'
VERIFIER_EXECUTABLE = '0x697b97795dfc4547e615c048a5583d31f4c7f9a969b53d85d5ecb9e42e218d54'


def reviewed_bytes(path, digest, gate):
    a.need(gate+'_hash', isinstance(digest, str) and len(digest) == 64 and
           all(c in '0123456789abcdef' for c in digest) and int(digest, 16) != 0, True)
    a.need(gate+'_path', isinstance(path, str) and Path(path).is_file(), True)
    raw = Path(path).read_bytes()
    a.need(gate, hashlib.sha256(raw).hexdigest(), digest)
    return raw


def reviewed_file(path, digest, gate):
    return a.plan_json(reviewed_bytes(path, digest, gate))


def verifier_artifact(v):
    a.need('verifier_commit', v['commit'], VERIFIER_COMMIT)
    art = reviewed_file(v.get('artifactPath'), VERIFIER_SHA256, 'verifier_file')
    a.need('verifier_creation', a.keccak(art['bytecode']['object']), VERIFIER_CREATION)
    refs = art['deployedBytecode']['immutableReferences']
    a.need('verifier_ids', set(refs), {'5519', '5522'})
    a.need('verifier_range_counts', [len(refs[k]) for k in ('5519', '5522')], [3, 2])
    names = {str(n.get('id')): n.get('name') for n in a.ast_nodes(art.get('ast', {}))
             if n.get('nodeType') == 'VariableDeclaration' and n.get('mutability') == 'immutable'}
    if not names:
        # Both permutations are checked against the runtime and mandatory getters.
        names = {'5519': 'AGGREGATOR', '5522': 'REGISTRY'}
    a.need('verifier_immutable_names', {names.get(k) for k in refs}, {'AGGREGATOR', 'REGISTRY'})
    ranges = [dict(name=names[k], **r) for k, entries in refs.items() for r in entries]
    a.need('verifier_range_widths', all(r['length'] == 32 for r in ranges), True)
    return dict(bytecode=art['bytecode']['object'], runtimeIdentity=dict(
        artifactRuntime=art['deployedBytecode']['object'], ranges=ranges))

NAMES = ('SuperPaymaster', 'SuperPaymasterAdmin', 'GlobalTierSource', 'AOAProtocolRegistry',
         'xPNTsTokenV2Ext', 'xPNTsTokenV2', 'xPNTsFactoryV2', 'SuperPaymasterLens', 'Registry', 'BLSAggregator')
LAYOUT_PAIRS = (
    ('SuperPaymaster', 'SuperPaymasterAdmin', 'scripts/check-sp-layout.py'),
    ('xPNTsTokenV2', 'xPNTsTokenV2Ext', 'scripts/check-xpnts-v2-layout.py'),
)
IMMUTABLES = dict(SuperPaymaster=u.SP_IMMUTABLES, SuperPaymasterAdmin=u.SP_IMMUTABLES[:-1],
    GlobalTierSource=('REGISTRY',), AOAProtocolRegistry=(),
    xPNTsTokenV2Ext=tuple(a.EIP712_IMMUTABLES)+('PROTOCOL_REGISTRY',),
    xPNTsTokenV2=tuple(a.EIP712_IMMUTABLES)+('PROTOCOL_REGISTRY', 'EXTENSION'),
    xPNTsFactoryV2=('REGISTRY', 'implementation', 'implementationCodehash', 'extensionCodehash'),
    SuperPaymasterLens=(), Registry=('__self',), BLSAggregator=('REGISTRY',))
POP = 'registerBLSPublicKey(address,(bytes32,bytes32,bytes32,bytes32),uint8,(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32))'
CONTROLS = ['early_unpause', 'factory_binding', 'early_bls', 'early_swap', 'funded_swap',
            'old_reputation', 'registry_nonowner', 'early_verifier', 'repeat_verifier', 'verifier_placeholder',
            'verifier_frontrun', 'verifier_wrong', 'unbacked_swap', 'owner_handover']


def required(obj, keys, label):
    a.need(label, isinstance(obj, dict) and set(keys) <= set(obj), True)


def evidence_file(ref, kind, commit=None):
    required(ref, ('path', 'sha256'), 'evidence_reference')
    e = reviewed_file(ref['path'], ref['sha256'], 'evidence_'+kind)
    fields = ['kind', 'subjectCommit', 'tool', 'counts', 'result']
    fields += {'conformance':['controls', 'scope'], 'mutation':['controls'], 'slither':['findings', 'scope', 'storageLayout', 'rawReport'],
               'reproducible-build':['contracts'], 'dvt-ci':['suites', 'ciRun', 'acceptedFailures'],
               'dvt-conformance-4.12':['suites']}[kind]
    if kind.startswith('dvt-'):
        fields += ['spCommit', 'aggregatorVersion']
    a.exact_keys('evidence_fields', e, fields)
    a.need('evidence_kind', e['kind'], kind)
    a.need('evidence_result', e['result'], 'PASS')
    a.need('evidence_commit_format', isinstance(e['subjectCommit'], str) and
           len(e['subjectCommit']) == 40 and all(c in '0123456789abcdef' for c in e['subjectCommit']), True)
    a.exact_keys('evidence_tool', e['tool'], ('name', 'version'))
    a.need('evidence_tool_values', all(isinstance(v, str) and bool(v.strip()) for v in e['tool'].values()), True)
    a.exact_keys('evidence_counts', e['counts'], ('passed', 'failed', 'skipped'))
    a.need('evidence_count_types', all(type(v) is int and v >= 0 for v in e['counts'].values()), True)
    a.need('evidence_passed', e['counts']['passed'] > 0, True)
    a.need('evidence_failed', e['counts']['failed'], 0)
    a.need('evidence_skipped', e['counts']['skipped'], 0)
    if kind == 'dvt-ci':
        validate_ci_run(e)
    validate_evidence_details(e, kind, Path(ref['path']).parent)
    if kind.startswith('dvt-'):
        a.need('evidence_dvt_commit', e['subjectCommit'], VERIFIER_COMMIT)
        a.need('evidence_aggregator_version', e['aggregatorVersion'], AGG_VERSION)
    if commit is not None:
        a.need('evidence_release_commit', e['spCommit'] if kind.startswith('dvt-') else e['subjectCommit'], commit)
    return e


def validate_ci_run(e):
    schema = json.loads(Path(__file__).with_name('release-evidence.schema.json').read_text())
    branch = next(b for b in schema['oneOf'] if b['properties']['kind']['const'] == 'dvt-ci')
    for field in ('ciRun', 'acceptedFailures'):
        _fraud_schema(e[field], branch['properties'][field], 'dvt-ci.'+field)
    for rule in branch.get('allOf', []):
        _fraud_schema(e, rule, 'dvt-ci')
    run = e['ciRun']
    a.need('evidence_ci_head', run['headSha'], e['subjectCommit'])
    accepted = {item['name'] for item in e['acceptedFailures']}
    failing = {name for name, conclusion in run['jobs'].items() if conclusion == 'failure'}
    # CI Success is a derived job, never an independent accepted failure.
    direct = failing - {'CI Success'}
    a.need('evidence_ci_unaccepted', direct <= accepted, True)
    a.need('evidence_ci_overall', not failing if run['overall'] == 'success' else bool(direct & accepted), True)


@lru_cache(maxsize=32)
def evidence_test_names(source):
    return frozenset(n.name for n in ast.walk(ast.parse(source))
                     if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)))


def validate_evidence_details(e, kind, evidence_dir=None):
    if kind == 'conformance':
        schema = json.loads(Path(__file__).with_name('release-evidence.schema.json').read_text())['oneOf'][0]
        _fraud_schema(e, schema, 'conformance')
        root = Path(__file__).resolve().parents[2]
        for control in e['controls'].values():
            refs = [control] + control['positiveControl'] + control['negativeControl']
            for ref in refs:
                path = (root / ref['suite']).resolve()
                a.need('evidence_test_suite', path.is_relative_to(root) and path.suffix == '.py' and path.is_file(), True)
                try:
                    names = evidence_test_names(path.read_text())
                except (OSError, SyntaxError):
                    names = set()
                a.need('evidence_test_name', ref['test'] in names, True)
    elif kind == 'mutation':
        a.exact_keys('evidence_mutations', e['controls'], MUTATIONS)
        for name, test in MUTATIONS.items():
            a.need('evidence_mutation_'+name, e['controls'][name],
                   dict(redTest=test, mutated='FAIL', restored='PASS'))
    elif kind in ('dvt-ci', 'dvt-conformance-4.12'):
        a.exact_keys('evidence_suites', e['suites'], DVT_SUITES)
        for name, count in DVT_SUITES.items():
            expected = dict(passed=count, failed=0, skipped=0, result='PASS')
            if name == 'CC115GenuinePragueCrossRepo':
                expected['env'] = {'FOUNDRY_EVM_VERSION':'prague'}
            a.need('evidence_suite_'+name, e['suites'][name], expected)
        a.need('evidence_suite_totals', e['counts'], dict(passed=sum(DVT_SUITES.values()), failed=0, skipped=0))
    elif kind == 'slither':
        a.need('evidence_slither_tool', e['tool']['name'], 'slither')
        from release_evidence import canonical_path_syntax, canonical_source_path, normalized_detectors, route_slither, source_mappings, Stop
        f = e['findings']
        a.exact_keys('evidence_findings', f, ('threshold', 'aboveThreshold', 'accepted', 'outOfScope', 'inScopeTotal'))
        a.need('evidence_threshold', f['threshold'] in ('Informational', 'Low', 'Medium', 'High'), True)
        a.need('evidence_findings_list', all(isinstance(f[k], list) for k in ('aboveThreshold', 'accepted', 'outOfScope')), True)
        for item in f['accepted']:
            a.need('evidence_accepted_fields', {'id', 'classification', 'reason'} <= set(item)
                   and set(item) <= {'id', 'classification', 'reason', 'row', 'check', 'location'}, True)
            a.need('evidence_classification', item['classification'] in ('false-positive', 'accepted'), True)
            a.need('evidence_acceptance_reason', all(isinstance(item[k],str) and item[k].strip() for k in ('id', 'reason')), True)
        ids = f['aboveThreshold']
        a.need('evidence_unique_findings', len(ids), len(set(ids)))
        a.need('evidence_unaccepted_findings', sorted(ids), sorted(x['id'] for x in f['accepted']))
        a.need('evidence_in_scope_total', f['inScopeTotal'], len(ids))
        scope = e['scope']
        a.exact_keys('evidence_scope', scope, ('contracts', 'files'))
        a.need('evidence_scope_contracts', scope['contracts'], list(NAMES))
        files = scope['files']
        a.need('evidence_scope_files', isinstance(files, list) and bool(files) and files == sorted(set(files))
               and all(canonical_path_syntax(x)
                       and x.endswith('.sol') for x in files), True)
        built = rebuild_commit(e['subjectCommit'])
        a.need('evidence_rebuild_commit', built['commit'], e['subjectCommit'])
        recomputed = built['scope']
        tree = built.get('tree', Path('/__evidence_tree__'))
        for item in f['outOfScope']:
            for filename in item.get('files', []):
                a.need('evidence_finding_path_canonical', canonical_path_syntax(filename) and
                       canonical_source_path(filename, tree) == filename, True)
        a.need('evidence_scope_recomputed', scope, recomputed)
        outside_ids = []
        for item in f['outOfScope']:
            a.exact_keys('evidence_outside', item, ('id', 'impact', 'files', 'classification'))
            a.need('evidence_outside_unclassified', item['classification'], 'unclassified')
            a.need('evidence_outside_files', bool(item['files']) and not set(item['files']).intersection(recomputed['files']), True)
            outside_ids.append(item['id'])
        a.need('evidence_outside_unique', len(outside_ids), len(set(outside_ids)))
        a.need('evidence_outside_not_reviewed', bool(set(outside_ids).intersection(ids)), False)
        a.need('evidence_unique_findings', len(ids + outside_ids), len(set(ids + outside_ids)))
        # Do not rerun Slither: report completeness rests on the generator at the release commit.
        # Re-derive classification under the independently rebuilt scope.
        ref = e.get('rawReport')
        a.exact_keys('evidence_slither_rederived', ref, ('path', 'sha256'))
        a.need('evidence_slither_rederived', canonical_path_syntax(ref['path']), True)
        evidence_root = (evidence_dir or Path.cwd()).resolve()
        try:
            raw_path = (evidence_root / ref['path']).resolve()
            a.need('evidence_slither_rederived',
                   raw_path.is_relative_to(evidence_root) and raw_path.is_file(), True)
        except (OSError, RuntimeError) as error:
            raise a.Gate('evidence_slither_rederived', str(error), 'contained regular raw report') from None
        raw = reviewed_file(str(raw_path), ref['sha256'], 'evidence_slither_rederived')
        try:
            a.need('evidence_slither_rederived', raw.get('success') is True and raw.get('error') is None, True)
            for mapping in source_mappings(raw):
                for field in ('filename_relative', 'filename_absolute', 'filename_short'):
                    filename = mapping.get(field)
                    if filename:
                        a.need('evidence_slither_rederived', canonical_path_syntax(filename), True)
            routed = route_slither(normalized_detectors(raw['results'].get('detectors', []), tree), recomputed, f['threshold'])
        except (Stop, KeyError, TypeError, ValueError) as error:
            raise a.Gate('evidence_slither_rederived', str(error), 'valid raw report') from None
        a.need('evidence_slither_rederived', {k: f[k] for k in routed}, routed)
        a.need('evidence_layout_pair_count', len(e['storageLayout']), len(LAYOUT_PAIRS))
        for pair, (core, extension, reference) in zip(e['storageLayout'], LAYOUT_PAIRS):
            a.exact_keys('evidence_layout_pair', pair, ('core', 'extension', 'reference', 'testReferences', 'coreTable', 'extensionTable'))
            a.need('evidence_layout_identity', (pair['core'], pair['extension'], pair['reference']), (core, extension, reference))
            for table in (pair['coreTable'], pair['extensionTable']):
                a.exact_keys('evidence_layout_table', table, ('storage', 'namespaces'))
                a.need('evidence_layout_nonempty', isinstance(table['storage'], list) and bool(table['storage'])
                       and isinstance(table['namespaces'], list), True)
                for row in table['storage'] + table['namespaces']:
                    a.exact_keys('evidence_layout_row', row, ('label', 'slot', 'offset', 'type'))
            a.need('evidence_layout_parity', pair['coreTable'], pair['extensionTable'])
    elif kind == 'reproducible-build':
        a.exact_keys('evidence_contracts', e['contracts'], (*NAMES, 'OverIssueFraudProofVerifier'))
        for name, hashes in e['contracts'].items():
            a.exact_keys('evidence_creation_hashes', hashes, ('fullCreationKeccak', 'strippedCreationKeccak'))
            for value in hashes.values(): a.typed(value, a.HASH32)
            if name != 'OverIssueFraudProofVerifier':
                a.need('evidence_full_creation_'+name, hashes['strippedCreationKeccak'], hashes['fullCreationKeccak'])


# Release packet pin: verifier 72aca4fa, compiler runtime is the final data object.
# Offsets include the two-byte Solidity CBOR length suffix. No pattern search.
VERIFIER_METADATA_LAYOUT = {'byteLength': 3300, 'segments': [{'offset': 3247, 'length': 53}]}


def verifier_executable(code, layout=None):
    layout = VERIFIER_METADATA_LAYOUT if layout is None else layout
    a.need('verifier_metadata_layout', layout, VERIFIER_METADATA_LAYOUT)
    raw = bytes.fromhex(a.typed(code, a.HEXDATA)[2:])
    a.need('verifier_creation_length', len(raw), layout['byteLength'])
    chunks, cursor = [], 0
    for segment in layout['segments']:
        start, size = segment['offset'], segment['length']
        end = start + size
        a.need('verifier_segment_length', int.from_bytes(raw[end-2:end], 'big') + 2, size)
        metadata = a.cbor_tail('0x' + raw[start:end].hex())
        a.exact_keys('verifier_metadata_keys', metadata, ('ipfs', 'solc'))
        a.need('verifier_metadata_solc', metadata['solc'], bytes.fromhex('000821'))
        a.need('verifier_metadata_ipfs', isinstance(metadata['ipfs'], bytes) and
               len(metadata['ipfs']) == 34 and metadata['ipfs'][:2] == b'\x12\x20', True)
        chunks.append(raw[cursor:start])
        cursor = end
    chunks.append(raw[cursor:])
    return b''.join(chunks)


def creation_hashes(code, name=None):
    full = a.keccak(code)
    stripped = (a.keccak('0x' + verifier_executable(code).hex())
                if name == 'OverIssueFraudProofVerifier' else full)
    return dict(fullCreationKeccak=full, strippedCreationKeccak=stripped)


def compare_build_evidence(e, contracts, reference_contracts=None):
    a.exact_keys('reproducible_contracts', e['contracts'], contracts)
    if reference_contracts is not None:
        a.exact_keys('reproducible_reference_contracts', reference_contracts, contracts)
    differences = []
    for name, art in contracts.items():
        if reference_contracts is not None:
            left, right = reference_contracts[name]['bytecode'], art['bytecode']
            if name == 'OverIssueFraudProofVerifier':
                left, right = verifier_executable(left), verifier_executable(right)
            else:
                left, right = bytes.fromhex(left[2:]), bytes.fromhex(right[2:])
            a.need('reproducible_bytes_'+name, left, right)
        expected = creation_hashes(art['bytecode'], name)
        a.need('rebuild_record_'+name, art['creationHashes'], expected)
        actual = e['contracts'][name]
        a.need('reproducible_executable_'+name, actual['strippedCreationKeccak'], expected['strippedCreationKeccak'])
        if name != 'OverIssueFraudProofVerifier':
            a.need('reproducible_full_'+name, actual['fullCreationKeccak'], expected['fullCreationKeccak'])
        elif actual['fullCreationKeccak'] != expected['fullCreationKeccak']:
            differences.append(name)
    return differences


def commitment_slot(layout, pid):
    entries = [x for x in layout.get('storage', []) if x['label'] == 'proposalSignersCommitment']
    a.need('fraud_layout_entry', len(entries), 1)
    entry = entries[0]
    typ = layout['types'][entry['type']]
    a.need('fraud_layout_mapping', typ['encoding'], 'mapping')
    a.need('fraud_layout_key', layout['types'][typ['key']]['label'], 'uint256')
    a.need('fraud_layout_value', layout['types'][typ['value']]['label'], 'bytes32')
    a.need('fraud_layout_offset', entry['offset'], 0)
    return a.keccak(a.cast('abi-encode', 'c(uint256,uint256)', pid, int(entry['slot'])))


def _fraud_schema(value, schema, path='fixture'):
    """Validate the closed subset of JSON Schema used by our fixture schema."""
    for child in schema.get('allOf', []):
        _fraud_schema(value, child, path)
    if 'if' in schema:
        try:
            _fraud_schema(value, schema['if'], path)
        except a.Gate:
            pass
        else:
            _fraud_schema(value, schema['then'], path)
    if 'const' in schema:
        a.need('fraud_schema_'+path, type(value) is type(schema['const']) and value == schema['const'], True)
    if 'enum' in schema:
        a.need('fraud_schema_enum_'+path, value in schema['enum'], True)
    kind = schema.get('type')
    if kind:
        a.need('fraud_schema_type_'+path, type(value) is {
            'object':dict, 'array':list, 'integer':int, 'string':str}[kind], True)
    if isinstance(value, dict) and (kind == 'object' or 'properties' in schema):
        properties = schema.get('properties', {})
        a.need('fraud_schema_required_'+path, set(schema.get('required', [])) <= set(value), True)
        a.need('fraud_schema_properties_'+path, len(value) >= schema.get('minProperties', 0), True)
        for key, item in value.items():
            if 'propertyNames' in schema:
                _fraud_schema(key, schema['propertyNames'], path+'.name')
            child = properties.get(key, schema.get('additionalProperties', True))
            a.need('fraud_schema_fields_'+path, child is not False, True)
            if isinstance(child, dict):
                _fraud_schema(item, child, path+'.'+key)
    elif kind == 'array':
        a.need('fraud_schema_length_'+path, schema.get('minItems', 0) <= len(value) <= schema.get('maxItems', 2**256-1), True)
        for i, item in enumerate(value):
            child = schema['prefixItems'][i] if 'prefixItems' in schema else schema['items']
            _fraud_schema(item, child, path+'.'+str(i))
    elif kind == 'string' and 'pattern' in schema:
        a.need('fraud_schema_pattern_'+path, re.fullmatch(schema['pattern'], value) is not None, True)
    elif kind == 'integer':
        a.need('fraud_schema_range_'+path, schema.get('minimum', 0) <= value <= schema.get('maximum', 2**256-1), True)


def fraud_format_only(export):
    """Parse DVT's wire format, including historical versions; never build a plan."""
    schema = json.loads(Path(__file__).with_name('fraud-proof-fixture.schema.json').read_text())['properties']['export']
    schema['properties']['version'] = {'type':'string', 'pattern':r'BLSAggregator-[0-9]+\.[0-9]+\.[0-9]+'}
    _fraud_schema(export, schema, 'export')
    return copy.deepcopy(export)


def fraud_message_hash(domain, pid, operator, level, epoch, token):
    evidence = a.keccak(a.cast('abi-encode', 'c(string,address,address,uint256)',
        'DVT_OVERISSUE_EVIDENCE_V1', token, operator, epoch))
    return a.keccak(a.cast('abi-encode', 'c(bytes32,bytes32,uint256,address,uint8,uint256,bytes32)',
        domain, a.keccak('SuperPaymaster.BLS.ExecuteSlash.v1'), pid, operator, level, epoch, evidence))


def fraud_fixture(ref, pin=None, aggregator=None, verifier=None, layout=None):
    required(ref, ('path', 'sha256'), 'fraud_fixture_required')
    wrapper = reviewed_file(ref['path'], ref['sha256'], 'fraud_fixture')
    schema = json.loads(Path(__file__).with_name('fraud-proof-fixture.schema.json').read_text())
    _fraud_schema(wrapper, schema)
    e = wrapper['export']
    v, state = e['valid'], e['forkState']
    pid, fid, mask, epoch = int(v['proposalId']), int(v['fraudProofId']), int(v['signerMask'], 16), int(v['epoch'])
    a.need('fraud_epoch', 0 <= epoch < 2**256, True)
    a.need('fraud_commitment_key', state['commitment']['key'], v['proposalId'])
    # DVT emits checksummed addresses. Normalize only after validating the wire shape.
    guardians = [x.lower() for x in v['guiltyGuardians']]
    token = state['token']
    negatives = e['mustReject']
    for n in negatives:
        if n['id'] != 'N1':
            a.need('fraud_'+n['id']+'_guardians', [x.lower() for x in n['guiltyGuardians']], guardians)
        if n['id'] != 'N3':
            a.need('fraud_'+n['id']+'_proof', n['fraudProof'], v['fraudProof'])
    f = dict(toolCommit=wrapper['toolCommit'], verifierCommit=wrapper['verifierCommit'],
        aggregator=e['aggregator'].lower(), verifier=e['verifier'].lower(), registry=e['registry'].lower(),
        domainSeparator=e['domainSeparator'], block=e['block'], pid=pid, fraudProofId=fid,
        guiltyGuardians=guardians, fraudProof=v['fraudProof'], signerMask=mask,
        messageHash=fraud_message_hash(e['domainSeparator'], pid, v['operator'], v['slashLevel'], epoch, token['address']),
        mockToken=dict(address=token['address'].lower(), runtime=token['runtimeBytecode'],
                       runtimeHash=MOCK_TOKEN_RUNTIME_HASH, over=False),
        commitment=dict(value=state['commitment']['value']),
        invalid=dict(N1=dict(guiltyGuardians=[x.lower() for x in negatives[0]['guiltyGuardians']]),
                     N2=dict(over=True), N3=dict(fraudProof=negatives[2]['fraudProof']),
                     N4=dict(domainDigest=negatives[3]['domainDigest'])))
    a.need('fraud_tool_commit', isinstance(f['toolCommit'], str) and len(f['toolCommit']) == 40 and
           all(c in '0123456789abcdef' for c in f['toolCommit']), True)
    a.need('fraud_verifier_commit', f['verifierCommit'], VERIFIER_COMMIT)
    a.need('fraud_registry', f['registry'], u.REG)
    for key in ('aggregator', 'verifier'): a.typed(f[key], a.ADDRESS_RX)
    for key in ('domainSeparator', 'messageHash'): a.typed(f[key], a.HASH32)
    for key in ('pid', 'fraudProofId', 'signerMask'):
        a.need('fraud_uint_'+key, type(f[key]) is int and 0 < f[key] < 2**256, True)
    a.need('fraud_large_pid', f['pid'] >= 2**128, True)
    guardians = f['guiltyGuardians']
    a.need('fraud_guardians', isinstance(guardians, list) and len(guardians) == 3, True)
    for who in guardians: a.typed(who, a.ADDRESS_RX)
    a.need('fraud_guardians_sorted', guardians, sorted(set(guardians)))
    if pin is not None:
        a.need('fraud_pin_block', f['block'], a.qty(pin['block']) if isinstance(pin['block'], str) else pin['block'])
        a.need('fraud_guardians_pinned', guardians,
               sorted(x['validator'] for x in pin['guardianInventory'] if x['validator'] != a.ZERO))
    if aggregator is not None: a.need('fraud_aggregator', f['aggregator'], aggregator.lower())
    if verifier is not None: a.need('fraud_verifier', f['verifier'], verifier.lower())
    a.typed(f['fraudProof'], a.HEXDATA)
    a.exact_keys('fraud_token_fields', f['mockToken'], ('address', 'runtime', 'runtimeHash', 'over'))
    a.typed(f['mockToken']['address'], a.ADDRESS_RX)
    words = u.uints(f['fraudProof'])
    a.need('fraud_proof_encoding', len(words), 11)
    a.need('fraud_proof_fields', [words[0], words[4], words[5], words[6], words[7], *words[8:]],
           [f['pid'], int(f['mockToken']['address'], 16), f['signerMask'], 224, 3, *[int(x,16) for x in guardians]])
    a.need('fraud_proof_metadata', words[1:4], [int(v['operator'], 16), v['slashLevel'], epoch])
    token = f['mockToken']
    a.exact_keys('fraud_token_fields', token, ('address', 'runtime', 'runtimeHash', 'over'))
    a.typed(token['address'], a.ADDRESS_RX)
    a.need('fraud_token_distinct', token['address'] not in (f['aggregator'], f['verifier'], u.REG, u.SP), True)
    a.typed(token['runtime'], a.HEXDATA)
    a.need('fraud_token_runtime', token['runtime'] != '0x', True)
    a.need('fraud_token_pin_available', MOCK_TOKEN_RUNTIME_HASH is not None, True)
    a.need('fraud_token_pinned_runtime', a.keccak(token['runtime']), MOCK_TOKEN_RUNTIME_HASH)
    a.cbor_tail(token['runtime'])
    raw = bytes.fromhex(token['runtime'][2:])
    size = int.from_bytes(raw[-2:], 'big') + 2
    a.need('fraud_token_stripped_runtime', a.keccak('0x' + raw[:-size].hex()), MOCK_TOKEN_STRIPPED_RUNTIME_HASH)
    raw_runtime = bytes.fromhex(token['runtime'][2:])
    for offset in (130, 210):
        a.need('fraud_token_zero_owner_'+str(offset), raw_runtime[offset:offset+32].hex(), '00'*32)
    a.need('fraud_token_selector', a.calldata('isOverIssued()'), MOCK_TOKEN_OVER_SELECTOR)
    a.need('fraud_token_over', token['over'] is False, True)
    if layout is not None:
        f['commitment']['slot'] = commitment_slot(layout, f['pid'])
    expected = a.keccak(a.cast('abi-encode', 'c(bytes32,bytes32,uint256,bytes32,uint256,address[])',
        f['domainSeparator'], a.keccak('SuperPaymaster.BLS.SignersCommitment.v1'), f['pid'],
        f['messageHash'], f['signerMask'], '['+','.join(guardians)+']'))
    a.need('fraud_commitment_value', f['commitment']['value'], expected)
    a.exact_keys('fraud_invalid_cases', f['invalid'], ('N1', 'N2', 'N3', 'N4'))
    n = f['invalid']
    a.exact_keys('fraud_N1_fields', n['N1'], ('guiltyGuardians',))
    a.need('fraud_N1_subset', n['N1']['guiltyGuardians'] in [guardians[:i]+guardians[i+1:] for i in range(3)], True)
    a.exact_keys('fraud_N2_fields', n['N2'], ('over',))
    a.need('fraud_N2_over', n['N2']['over'] is True, True)
    a.exact_keys('fraud_N3_fields', n['N3'], ('fraudProof',))
    a.typed(n['N3']['fraudProof'], a.HEXDATA)
    changed = u.uints(n['N3']['fraudProof'])
    a.need('fraud_N3_only_mask', changed[:5]+changed[6:], words[:5]+words[6:])
    a.need('fraud_N3_length', len(changed), len(words))
    delta = changed[5] ^ words[5]
    a.need('fraud_N3_one_bit', delta > 0 and delta & (delta-1) == 0, True)
    a.exact_keys('fraud_N4_fields', n['N4'], ('domainDigest',))
    a.typed(n['N4']['domainDigest'], a.HASH32)
    digest = a.keccak(a.cast('abi-encode', 'c(bytes32,bytes32,uint256,address[])', f['domainSeparator'],
        a.keccak('SuperPaymaster.BLS.FraudProof.v1'), f['fraudProofId'], '['+','.join(guardians)+']'))
    a.need('fraud_domain_digest', v['domainDigest'], digest)
    delta = int(digest,16) ^ int(n['N4']['domainDigest'],16)
    a.need('fraud_N4_one_bit', delta > 0 and delta & (delta-1) == 0, True)
    return f


def fraud_rehearsal(rpc, plan):
    a.need('fraud_local_only', getattr(rpc, 'local', False), True)
    agg, verifier = (plan['addresses'][k] for k in ('BLSAggregator', 'OverIssueFraudProofVerifier'))
    f = fraud_fixture(plan['externalInputs']['data']['fraudProofFixture'], plan['pin'], agg, verifier,
                      plan['rebuild']['contracts']['BLSAggregator']['storageLayout'])
    runtime_hashes = {}
    for sid, target in (('A7', agg), ('A12a', verifier)):
        check = next(s for s in plan['steps'] if s['id'] == sid)['readbacks'][0]
        expected = check['expected'] if isinstance(check['expected'], list) else [check['expected']]
        actual = a.keccak(u.code(rpc, target, 'latest'))
        a.need('fraud_runtime_'+sid, actual in [a.keccak(x) for x in expected], True)
        runtime_hashes[sid] = actual
    a.need('fraud_active_verifier', a.address(rpc, agg, 'fraudProofVerifier()'), verifier)
    a.need('fraud_domain', a.call(rpc, agg, 'domainSeparator()'), f['domainSeparator'])
    a.need('fraud_derived_id', a.word(rpc, verifier, 'deriveFraudProofId(uint256)', f['pid']), f['fraudProofId'])
    words = u.uints(f['fraudProof'])
    a.need('fraud_message_hash', a.call(rpc, verifier, 'slashMessageHash(uint256,address,uint8,uint256,address)',
        f['pid'], u.addr_word(words[1]), words[2], words[3], f['mockToken']['address']), f['messageHash'])
    before = a.call(rpc, agg, 'proposalSignersCommitment(uint256)', f['pid'])
    a.need('fraud_unused_pid', before, a.ZERO32)
    a.need('fraud_unused_case', u.uints(a.call(rpc, agg, 'guardianSlashCases(uint256)', f['fraudProofId']))[3], 0)
    token = f['mockToken']['address']
    a.need('fraud_unused_token', u.code(rpc, token, 'latest'), '0x')
    outer = rpc('evm_snapshot', [])
    records, writes = [], []
    def write(target, slot, value, case):
        rpc('anvil_setStorageAt', [target, slot, value])
        writes.append(dict(address=target, slot=slot, value=value, case=case))
    try:
        rpc('anvil_setCode', [token, f['mockToken']['runtime']])
        a.need('fraud_mock_code_readback', u.code(rpc, token, 'latest'), f['mockToken']['runtime'])
        write(token, a.ZERO32, a.ZERO32, 'setup')  # MockOverIssuableToken.over: slot 0 at 72aca4fa.
        write(agg, f['commitment']['slot'], f['commitment']['value'], 'setup')
        a.need('fraud_commitment_readback', a.call(rpc, agg, 'proposalSignersCommitment(uint256)', f['pid']), f['commitment']['value'])
        a.need('fraud_is_over_issued_false', a.word(rpc, token, 'isOverIssued()'), 0)
        a.need('fraud_over_readback', a.word(rpc, token, 'over()'), 0)
        for name in ('valid', 'N1', 'N2', 'N3', 'N4'):
            snap = rpc('evm_snapshot', [])
            try:
                guardians = f['invalid']['N1']['guiltyGuardians'] if name == 'N1' else f['guiltyGuardians']
                payload = f['invalid']['N3']['fraudProof'] if name == 'N3' else f['fraudProof']
                args = (f['fraudProofId'], '['+','.join(guardians)+']', payload)
                if name == 'N2':
                    a.need('fraud_N2_before', a.word(rpc, token, 'isOverIssued()'), 0)
                    write(token, a.ZERO32, '0x'+format(1,'064x'), name)
                    a.need('fraud_N2_is_over_issued', a.word(rpc, token, 'isOverIssued()'), 1)
                    a.need('fraud_N2_readback', a.word(rpc, token, 'over()'), 1)
                if name == 'N4':
                    a.need('fraud_N4_false', a.word(rpc, verifier, 'verify(bytes32,uint256,address[],bytes)',
                           f['invalid']['N4']['domainDigest'], *args), 0)
                    record = dict(result=False)
                else:
                    tx = u.fixture_tx(rpc, u.DEPLOYER, agg, a.calldata(FRAUD_SIG, *args))
                    receipt = u.receipt(rpc, tx, status='0x1' if name == 'valid' else '0x0')
                    record = dict(receipt=receipt)
                    if name == 'valid':
                        case = u.uints(a.call(rpc, agg, 'guardianSlashCases(uint256)', f['fraudProofId']))
                        gh = a.keccak(a.cast('abi-encode', 'c(address[])', args[1]))
                        a.need('fraud_frozen_state', case[:2]+[case[3]], [int(gh,16), int(a.keccak(payload),16), 1])
                        expected = dict(address=agg, topics=[a.keccak('GuardianSlashQueued(uint256,bytes32,uint256,address[])'),
                            '0x'+format(f['fraudProofId'],'064x')],
                            data=a.cast('abi-encode', 'c(bytes32,uint256,address[])', gh, case[2], args[1]))
                        a.need('fraud_queued_event', any(all(log.get(k) == v for k,v in expected.items()) for log in receipt['logs']), True)
                    else:
                        trace = rpc('debug_traceTransaction', [receipt['transactionHash'], {'tracer':'callTracer'}])
                        expected = a.calldata('InvalidFraudProof(uint256)', f['fraudProofId'])
                        a.need('fraud_revert_'+name, trace.get('output', '').lower(), expected)
                        record['revertSelector'] = expected[:10]
                records.append(dict(name=name, snapshotId=snap, **record))
            finally:
                a.need('fraud_variant_restore', rpc('evm_revert', [snap]), True)
    finally:
        a.need('fraud_restore', rpc('evm_revert', [outer]), True)
        restored = a.call(rpc, agg, 'proposalSignersCommitment(uint256)', f['pid'])
        a.need('fraud_main_readback', restored, before)
        a.need('fraud_token_restored', u.code(rpc, token, 'latest'), '0x')
    return dict(fixtureSha256=plan['externalInputs']['data']['fraudProofFixture']['sha256'],
        toolCommit=f['toolCommit'], verifierCommit=f['verifierCommit'], snapshotId=outer,
        runtimeHashes=runtime_hashes, codeWrites=[dict(address=token, runtime=f['mockToken']['runtime'], runtimeHash=f['mockToken']['runtimeHash'])],
        storageWrites=writes, proofs=records, mainReadback=dict(before=before, after=restored), restored=True)


def external(path, stage="full"):
    a.need('external_inputs_required', path is not None and Path(path).is_file(), True)
    raw = Path(path).read_bytes()
    data = a.plan_json(raw)
    validate_external(data, stage)
    return dict(sha256=hashlib.sha256(raw).hexdigest(), data=data)


def validate_external(data, stage="full"):
    a.need("stage", stage in STAGES, True)
    required(data, (() if stage == "a7" else ("pop",)) + (("fraudProofFixture",) if stage == "full" else ())
             + (("phaseC",) if stage in PC_STAGES else ()), "stage_inputs")
    required(data, ('verifier', 'anni', 'dvt', 'committee', 'sampled', 'depositTargetWei',
                    'releaseTag', 'releaseEvidence', 'registryBaselineCommit', 'a3aPlan'), 'external_inputs_complete')
    v = data['verifier']
    a.exact_keys('verifier_provenance', v, ('commit', 'ciSha256', 'ciPath', 'artifactPath', 'buildSha256'))
    verifier_artifact(v)
    a.need('verifier_build_identity', v['buildSha256'], VERIFIER_SHA256)
    evidence_file(dict(path=v['ciPath'], sha256=v['ciSha256']), 'dvt-ci')
    if stage == 'full':
        fraud_fixture(data['fraudProofFixture'])
    if stage in PC_STAGES:
        validate_phase_c_inputs(data['phaseC'])
    a.need('fixed_anni', data['anni'], ANNI)
    required(data['a3aPlan'], ('path', 'sha256', 'receipts'), 'a3a_input')
    reviewed_file(data['a3aPlan']['path'], data['a3aPlan']['sha256'], 'a3a_plan')
    for sid in a.STEP_IDS:
        a.typed(data['a3aPlan']['receipts'].get(sid), a.HASH32)
        a.need('a3a_receipt_nonzero', data['a3aPlan']['receipts'][sid] != a.ZERO32, True)
    a.need('fixed_dvt', data['dvt'], DVT)
    a.need('fixed_committee', data['committee'], COMMITTEE)
    for key in ('ciSha256', 'buildSha256'):
        a.need('verifier_'+key, len(v[key]) == 64 and all(c in '0123456789abcdef' for c in v[key]) and int(v[key], 16) != 0, True)
    a.need('verifier_commit', len(v['commit']) == 40 and all(c in '0123456789abcdef' for c in v['commit']), True)
    for key in ('anni', 'dvt', 'committee'):
        a.typed(data[key], a.ADDRESS_RX)
        a.need('canonical_'+key, data[key], data[key].lower())
        a.need('nonzero_'+key, data[key] != a.ZERO, True)
    if stage != 'a7':
        a.need('pop_three', len(data['pop']), 3)
        for p in data['pop']:
            a.exact_keys('pop_fields', p, ('validator', 'slot', 'calldata', 'aggregator', 'pinBlockHash', 'domainSeparator'))
            a.typed(p['validator'], a.ADDRESS_RX)
            a.typed(p['calldata'], a.HEXDATA)
            a.need('pop_selector', p['calldata'][:10], a.keccak(POP)[:10])
            words = u.uints('0x'+p['calldata'][10:])
            a.need('pop_words', len(words), 14)
            a.need('pop_validator', u.addr_word(words[0]), p['validator'])
            a.need('pop_slot', words[5], p['slot'])
            a.need('pop_slot_range', 1 <= p['slot'] <= 13, True)
        for key in ('validator', 'slot'):
            a.need('pop_unique_'+key, len({p[key] for p in data['pop']}), 3)
    a.need('sampled_deployer_only', data['sampled'], [u.DEPLOYER])
    a.need('sampled_unique', data['sampled'], sorted(set(data['sampled'])))
    a.need('sampled_nonempty', bool(data['sampled']), True)
    for who in data['sampled']:
        a.typed(who, a.ADDRESS_RX)
    a.need('deposit_target', type(data['depositTargetWei']) is int and data['depositTargetWei'] > 0, True)
    for kind in EVIDENCE_KINDS:
        evidence_file(data['releaseEvidence'].get(kind), kind)
    ref = data['releaseEvidence'].get('sourceVerificationPlan')
    required(ref, ('path', 'sha256'), 'source_verification_plan')
    a.need('source_verification_nonempty', bool(reviewed_bytes(ref['path'], ref['sha256'], 'source_verification').strip()), True)


@lru_cache(maxsize=1)
def rebuild():
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=u.ROOT, capture_output=True, text=True, check=True).stdout.strip()
    return {k: v for k, v in rebuild_commit(head).items() if k not in ('tree', 'treeOwner')}


@lru_cache(maxsize=4)
def rebuild_commit(head):
    version = subprocess.run([str(a.REBUILD_FORGE), '--version'], capture_output=True, text=True, check=True).stdout
    a.need('forge_version', version.splitlines()[0], 'forge Version: 1.7.1')
    arts, cfg = a.compile_commit(head, version, NAMES, tuple(IMMUTABLES.items()))
    # Inspect the same committed source/configuration in an isolated build tree.
    directory = tempfile.TemporaryDirectory(prefix='manifest-layout-')
    tree = Path(directory.name)/'tree'
    a.archive_commit(u.ROOT, head, tree)
    env = {k: os.environ[k] for k in ('HOME', 'PATH', 'TMPDIR', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'SVM_HOME') if k in os.environ}
    env['FOUNDRY_PROFILE'] = 'default'
    # Retain the pinned tree with the cached build for canonical finding-path resolution.
    from release_evidence import compiled_scope, Stop
    built = subprocess.run([str(a.REBUILD_FORGE), 'build', '--offline', '--ast', '--build-info'],
                           cwd=tree, env=env, capture_output=True, text=True)
    a.need('evidence_scope_build', built.returncode, 0)
    try:
        scope, _, _ = compiled_scope(tree)
    except Stop as error:
        raise a.Gate('evidence_scope_recomputed', str(error), 'valid compiled release scope') from None
    result = subprocess.run([str(a.REBUILD_FORGE), 'inspect', 'BLSAggregator', 'storage-layout', '--offline', '--json'],
        cwd=tree, env=env, capture_output=True, text=True)
    a.need('fraud_layout_inspect', result.returncode, 0)
    layout = a.plan_json(result.stdout)
    a.need('fraud_layout_build_parity', commitment_slot(layout, 1),
           commitment_slot(arts['BLSAggregator']['storageLayout'], 1))
    arts['BLSAggregator']['storageLayout'] = layout
    functions = [n for n in a.ast_nodes(arts['BLSAggregator']['ast']) if n.get('nodeType') == 'FunctionDefinition' and n.get('name') == 'version']
    a.need('built_aggregator_version', [[n.get('value') for n in a.ast_nodes(f['body']) if n.get('nodeType') == 'Literal'] for f in functions], [[AGG_VERSION]])
    return dict(calldataSignatures=isolation.signature_catalogue(tree), oldOwnerInventory=isolation.inventory_source(tree, mode="release", names=tuple(sorted(set(isolation.NAMES) | {"xPNTsFactoryV2", "xPNTsTokenV2", "xPNTsTokenV2Ext"}))), tree=tree, treeOwner=directory, scope=scope, commit=head, aggregatorVersion=AGG_VERSION, forgeVersion=version.strip(), contracts={name: dict(
        bytecode=art['bytecode']['object'], creationHashes=creation_hashes(art['bytecode']['object']), runtimeIdentity=art['runtimeIdentity'],
        storageLayout=art.get('storageLayout', {}), metadata=a.metadata_identity(art, cfg))
        for name, art in arts.items()})


@lru_cache(maxsize=1)
def rebuild_dvt():
    a.need('dvt_repo_configured', bool(os.environ.get('MANIFEST_DVT_REPO')), True)
    version = subprocess.run([str(a.REBUILD_FORGE), '--version'], capture_output=True, text=True, check=True).stdout
    a.need('dvt_forge_version', version.splitlines()[0], 'forge Version: 1.7.1')
    # Local clone of DVT (YetAnotherAA-Validator) containing VERIFIER_COMMIT; never a hardcoded machine path.
    repo = Path(os.environ['MANIFEST_DVT_REPO'])
    with tempfile.TemporaryDirectory(prefix='manifest-dvt-') as directory:
        tree = Path(directory)/'tree'
        a.archive_commit(repo, VERIFIER_COMMIT, tree)
        env = {k:os.environ[k] for k in ('HOME','PATH','TMPDIR','USER','LOGNAME','LANG','LC_ALL','SVM_HOME') if k in os.environ}
        env['FOUNDRY_PROFILE'] = 'default'
        result = subprocess.run([str(a.REBUILD_FORGE), 'build', '--offline', '--force', '--skip', 'test', '--skip', 'script', '--use', '0.8.33'],
                                cwd=tree/'contracts', env=env, capture_output=True)
        a.need('dvt_offline_rebuild', result.returncode, 0)
        art = a.raw_artifact(tree/'contracts', 'OverIssueFraudProofVerifier')
        a.need('dvt_rebuilt_creation', creation_hashes(art['bytecode']['object'], 'OverIssueFraudProofVerifier')['strippedCreationKeccak'], VERIFIER_EXECUTABLE)
        mock = a.raw_artifact(tree/'contracts', 'MockOverIssuableToken')
        a.need('dvt_mock_rebuilt_runtime', a.keccak(mock['deployedBytecode']['object']), MOCK_TOKEN_RUNTIME_HASH)
        return dict(bytecode=art['bytecode']['object'], creationHashes=creation_hashes(art['bytecode']['object'], 'OverIssueFraudProofVerifier'),
                    mockRuntimeHash=a.keccak(mock['deployedBytecode']['object']))


def release_gate(inputs, build, pin):
    data = inputs['data']
    state = subprocess.run(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=u.ROOT, capture_output=True, text=True, check=True)
    a.need('release_clean_tree', state.stdout, '')
    a.need('built_aggregator_version', build['aggregatorVersion'], AGG_VERSION)
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=u.ROOT, capture_output=True, text=True, check=True).stdout.strip()
    a.need('release_current_head', head, build['commit'])
    for kind in EVIDENCE_KINDS:
        evidence_file(data['releaseEvidence'].get(kind), kind, build['commit'])
    evidence_file(dict(path=data['verifier']['ciPath'], sha256=data['verifier']['ciSha256']), 'dvt-ci', build['commit'])
    verifier = rebuild_dvt()
    a.need('dvt_artifact_rebuild', verifier_executable(verifier['bytecode']),
           verifier_executable(verifier_artifact(data['verifier'])['bytecode']))
    contracts = dict(build['contracts'], OverIssueFraudProofVerifier=verifier)
    evidence = evidence_file(data['releaseEvidence']['reproducible-build'], 'reproducible-build', build['commit'])
    build['metadataOnlyDifferences'] = compare_build_evidence(evidence, contracts)
    build['verifierCreationHashes'] = verifier['creationHashes']
    tag = subprocess.run(['git', 'rev-parse', '--verify', 'refs/tags/'+data['releaseTag']+'^{commit}'],
                         cwd=u.ROOT, capture_output=True, text=True)
    a.need('release_tag', tag.returncode, 0)
    a.need('release_tag_head', tag.stdout.strip(), build['commit'])
    baseline = subprocess.run(['git', 'rev-parse', '--verify', data['registryBaselineCommit']+'^{commit}'],
                              cwd=u.ROOT, capture_output=True, text=True, check=True).stdout.strip()
    a.need('registry_baseline_not_head', baseline != build['commit'], True)
    old, _ = a.compile_commit(baseline, build['forgeVersion'], ('Registry',), (('Registry', ('__self',)),))
    a.need('registry_baseline_runtime', pin['registryImplementationCode'],
           runtime_bytes(old['Registry'], {'__self': int(pin['registryImplementation'], 16)}))
    layout = build['contracts']['Registry']['storageLayout']
    def normalized(value):
        def shape(t):
            info = value['types'][t]
            result = {k: info[k] for k in ('encoding', 'label', 'numberOfBytes')}
            for key in ('key', 'value', 'base'):
                if key in info:
                    result[key] = shape(info[key])
            if 'members' in info:
                result['members'] = [(m['label'], m['slot'], m['offset'], shape(m['type'])) for m in info['members']]
            return result
        return [(x['label'], x['slot'], x['offset'], shape(x['type'])) for x in value['storage']]
    a.need('registry_layout', normalized(layout), normalized(old['Registry']['storageLayout']))
    a.need('registry_storage_count', len(layout['storage']), 32)
    a.need('registry_owner_slot', next(x['slot'] for x in layout['storage'] if x['label'] == '_owner'), '0')


def old_activity(rpc, old, block, pop=None):
    start = u.creation(rpc, old, block)
    events = ('SignatureAggregated(uint256,bytes,uint256)', 'GuardianExitRequested(address,uint256,uint256)')
    logs = u.scan(rpc, old, start, block, [[a.keccak(x) for x in events]])
    exemptions = []
    for log in logs:
        subject = int(log['topics'][1], 16)
        if log['topics'][0] == a.keccak(events[0]):
            a.need('old_proposal_complete', a.word(rpc, old, 'executedProposals(uint256)', subject, block=block), 1)
        else:
            values = u.uints(a.call(rpc, old, 'guardianExitRequests(address)', u.addr_word(subject), block=block))
            a.need('old_exit_shape', len(values), 2)
            if any(values):
                guardian = u.addr_word(subject)
                header = a.block_data(rpc, block)
                maximum = a.word(rpc, old, 'MAX_VALIDATORS()', block=block)
                a.need('old_exit_max_validators', maximum, 13)
                slots = [dict(slot=i, validator=u.addr_word(a.word(
                    rpc, old, 'validatorAtSlot(uint8)', i, block=block))) for i in range(1, 14)]
                slash = a.word(rpc, old, 'pendingGuardianSlashCount(address)', guardian, block=block)
                # Before the A7 PoP exists (stage a7) condition (4) follows from (2): the PoP
                # validator set must equal the old aggregator's nonempty slot inventory.
                pop_source = 'slot-inventory' if pop is None else 'pop'
                in_pop = (guardian in {x['validator'] for x in slots} if pop is None
                          else guardian in {x['validator'].lower() for x in pop})
                # 4.11.0 checks slot holders only in _reconstructPkAgg (signer mask)
                # and _requireCommitteeSurvivesExit (validatorAtSlot). No slot means
                # no signing/quorum effect, including rollback A7–A12b. This slot
                # condition is load-bearing and re-read at EVERY pre_send. An expired
                # request cannot be consumed to exit DVT (GuardianExitRequestExpired).
                a.need('old_exit_exempt_expired', values[1] < a.qty(header['timestamp']), True)
                a.need('old_exit_exempt_slot', all(x['validator'] != guardian for x in slots), True)
                a.need('old_exit_exempt_slash', slash, 0)
                a.need('old_exit_exempt_pop', in_pop, False)
                a.need('old_exit_exempt_listed', guardian in OLD_EXIT_EXEMPTIONS, True)
                exemptions.append(dict(guardian=guardian, readyAt=values[0], expiresAt=values[1],
                    pinTime=a.qty(header['timestamp']), blockHash=header['hash'],
                    slotScan=slots, maxValidators=maximum, slashCount=slash, inPop=in_pop, popSource=pop_source))
            # Backstop only: any nonzero request is decided by the exemption gates above.
            a.need('old_exit_cleared', all(v == 0 for v in values) or bool(exemptions), True)
    return dict(creation=start, logs=logs, exemptions=exemptions)


def record_old_activity(rpc, old, block, pop):
    reads = []
    def recording(method, params):
        result = rpc(method, params)
        reads.append(dict(method=method, params=params, result=copy.deepcopy(result)))
        return result
    return old_activity(recording, old, block, pop), reads


def validate_old_activity(pin, pop):
    evidence = pin.get('oldActivityReads', {})
    a.need('old_exit_endpoints', set(evidence), {'primary', 'secondary'})
    expected = {k:v for k,v in pin['oldActivity'].items() if k != 'dvtProposals'}
    for label in ('primary', 'secondary'):
        reads = iter(evidence[label])
        def replay(method, params):
            row = next(reads, None)
            a.need('old_exit_proof_read', row is not None, True)
            a.need('old_exit_proof_request', (row['method'], row['params']), (method, params))
            return copy.deepcopy(row['result'])
        actual = old_activity(replay, pin['oldAggregator'], pin['stateBlock'], pop)
        a.need('old_exit_proof_unused', next(reads, None), None)
        a.need('old_exit_evidence', actual, expected)
        for item in actual['exemptions']:
            a.need('old_exit_pin_time', item['pinTime'], pin['stateTimestamp'])
            a.need('old_exit_pin_hash', item['blockHash'], pin['stateBlockHash'])


def unchanged_old_activity(rpc, plan, block):
    actual = old_activity(rpc, plan['pin']['oldAggregator'], block,
                          plan['externalInputs']['data'].get('pop'))
    expected = {k:copy.deepcopy(v) for k,v in plan['pin']['oldActivity'].items() if k != 'dvtProposals'}
    # Time/hash advance on the fork; all exemption predicates have just run again.
    for activity in (actual, expected):
        for item in activity.get('exemptions', []):
            item.pop('pinTime', None)
            item.pop('blockHash', None)
    a.need('old_activity_unchanged', actual, expected)


def dvt_activity(rpc, dvt, block):
    # DVT owns proposal creation; aggregation events alone cannot find unsigned proposals.
    # Getters are the inventory; logs must reconcile with them exactly (missing logs are not "none").
    start = u.creation(rpc, dvt, block)
    proposals = u.scan(rpc, dvt, start, block, [a.keccak('ProposalCreated(uint256,address,uint8)')])
    a.need('dvt_stale_next_id', a.word(rpc, dvt, 'nextProposalId()', block=block), STALE_PROPOSAL_NEXT_ID)
    ids = list(range(1, STALE_PROPOSAL_NEXT_ID))
    a.need('dvt_proposal_inventory', sorted(int(log['topics'][1], 16) for log in proposals), ids)
    words = {i: u.uints(a.call(rpc, dvt, 'proposals(uint256)', i, block=block)) for i in ids}
    open_ids = [i for i in ids if words[i][3] != 1]
    for proposal in open_ids:
        a.need('dvt_stale_proposal_listed', proposal in STALE_PROPOSALS, True)
    for proposal in open_ids:
        w = words[proposal]
        sibling, evidence = STALE_PROPOSALS.get(proposal, (None, None))
        a.need('dvt_stale_proposal_shape', (w[0], w[1], w[3], w[4], w[5]), (int(STALE_PROPOSAL_OPERATOR, 16), 1, 0, 1, evidence))
        peer = words.get(sibling, [0]*6)
        a.need('dvt_stale_sibling_executed', (peer[0], peer[1], peer[3], peer[5]), (w[0], w[1], 1, evidence))
    a.need('dvt_stale_open_set', open_ids, sorted(STALE_PROPOSALS))
    return proposals


def old_pointers(rpc, d, old, block):
    bindings = {}
    for target, getter in ((d['dvt'], 'BLS_AGGREGATOR()'), (d['committee'], 'blsAggregator()')):
        a.need('pointer_owner', a.address(rpc, target, 'owner()', block), u.DEPLOYER)
        a.need('old_pointer', a.address(rpc, target, getter, block), old)
        bindings[target] = u.code(rpc, target, block)
    return bindings


def validate_old_timelock(pin):
    a.need('old_timelock_required', 'oldTimelock' in pin, True)
    section = pin['oldTimelock']
    a.need('old_timelock_schema', isinstance(section, dict) and set(section) == {'block', 'reads', 'approvalOwners'}
           and isinstance(section.get('approvalOwners'), dict)
           and isinstance(section.get('reads'), list) and all(isinstance(r, dict) and
           ((set(r) == {'method', 'params', 'block', 'result'} and
             r['method'] == 'eth_getLogs' and isinstance(r['params'], list) and
             isinstance(r['block'], str) and isinstance(r['result'], list)) or
           (set(r) == {'target', 'signature', 'args', 'block', 'result'} and
           isinstance(r['target'], str) and isinstance(r['signature'], str) and
           isinstance(r['args'], list) and isinstance(r['block'], str) and
           isinstance(r['result'], str))) for r in section['reads']), True)
    a.need('old_timelock_block', section['block'] == pin['stateBlock'] and
           all(r['block'] == pin['stateBlock'] for r in section['reads']), True)
    reads = iter(section['reads'])
    def replay(method, params):
        row = next(reads, None)
        a.need('old_timelock_replay', row is not None and
               ((row.get('method') == method == 'eth_getLogs' and params == row['params']) or
                ('target' in row and method == 'eth_call' and
                 params == [dict(to=row['target'], data=a.calldata(row['signature'], *row['args'])), row['block']])), True)
        return copy.deepcopy(row['result'])
    actual = old_timelock_holds_nothing(replay, pin, pin['stateBlock'])
    a.need('old_timelock_replay', actual['approvalOwners'], section['approvalOwners'])
    a.need('old_timelock_unused', next(reads, None), None)


# Getter discovery changes only at these reviewed steps. Deployments also expand coverage.
DISCOVERY_STEPS = {
    'A4.factory': 'factory deployment',
    'A6.upgrade': 'Registry implementation; getters unchanged',
    'upgrade_execute_exec': 'factory pointer',
    'C3.deploy': 'factory token enumeration',
    'C3.configure': 'operator token',
}


def pin_discovery(pin):
    section = pin['oldOwnerIsolation']
    return dict(targets=copy.deepcopy(section['targets']), xpnts=list(section['xpnts']))


def build_expected_discovery(plan):
    state = pin_discovery(plan['pin'])
    expected = {}
    required_ids = set(DISCOVERY_STEPS)
    if plan['stage'] == 'a7':
        required_ids -= {'upgrade_execute_exec', 'C3.deploy', 'C3.configure'}
    elif plan['stage'] == 'b4':
        required_ids -= {'C3.deploy', 'C3.configure'}
    ids = [s['id'] for s in plan['steps']]
    a.need('discovery_step_table', set(ids) & set(DISCOVERY_STEPS) == required_ids and len(ids) == len(set(ids)), True)
    factory = plan['addresses']['xPNTsFactoryV2']
    token = a.create_address(factory, 1)
    sensitive = ('setXPNTsFactory(address)', 'deployxPNTsToken(string,string,string,string,uint256,address)',
                 'configureOperator(address,address)', 'setStaking(address)', 'setMySBT(address)', 'upgradeToAndCall(address,bytes)')
    schedules = {a.keccak(sig)[:10] for sig in plan['rebuild']['calldataSignatures'] if sig.startswith(('schedule(', 'scheduleBatch('))}
    allowed = {sensitive[0]: {'upgrade_execute_exec'}, sensitive[1]: {'C3.deploy'}, sensitive[2]: {'C3.configure'},
               sensitive[5]: {'A6.upgrade', 'upgrade_execute_exec'}}
    for step in plan['steps']:
        sid = step['id']
        # Inspect executed payloads, excluding Safe approvals and timelock scheduling.
        data, effects = step['tx']['data'], []
        if step['tx']['to'] is not None:
            decoded = isolation.assert_manifest_calldata([step], plan['rebuild']['calldataSignatures'])
            outer = decoded[-1] if decoded else {}
            payload = outer.get('arguments', [])[2] if outer.get('signature', '').startswith('execTransaction(') else data
            inactive = data[:10] == a.keccak('approveHash(bytes32)')[:10] or payload[:10] in schedules
            effects = [] if inactive else [r for r in decoded if r['signature'] in sensitive]
            a.need('discovery_unlisted_effect', all(sid in allowed.get(r['signature'], set()) for r in effects), True)
        if sid == 'A4.factory':
            a.need('discovery_factory_prediction', step.get('creates'), factory)
            state['targets']['releaseFactory'] = factory
        elif sid == 'upgrade_execute_exec':
            calls = [r['arguments'][0].lower() for r in effects if r['signature'] == sensitive[0]]
            a.need('discovery_factory_argument', bool(calls) and set(calls) == {factory}, True)
            state['targets']['legacyFactory'] = state['targets']['xPNTsFactory']
            state['targets']['xPNTsFactory'] = factory
        elif sid == 'C3.deploy':
            a.need('discovery_token_prediction', step['tx']['to'] == factory and
                   data == a.calldata('deployxPNTsToken(string,string,string,string,uint256,address)', *PC_TOKEN, PC_RATE, a.ZERO) and
                   any(r.get('kind') == 'code' and r['target'] == token for r in step['readbacks']), True)
            state['xpnts'] = sorted(set(state['xpnts']) | {token})
        elif sid == 'C3.configure':
            a.need('discovery_operator_argument', step['tx']['to'] == u.SP and
                   data == a.calldata('configureOperator(address,address)', token, PC_TREASURY), True)
            state['xpnts'] = sorted(set(state['xpnts']) | {token})
        expected[sid] = copy.deepcopy(state)
    return expected


def expected_discovery(plan, passed):
    state = pin_discovery(plan['pin'])
    for step in plan['steps']:
        if step['id'] in passed:
            state = plan['expectedDiscoveryAfter'][step['id']]
    return copy.deepcopy(state)


def discovery_coverage(plan, passed):
    pin = copy.deepcopy(plan['pin'])
    section = pin['oldOwnerIsolation']
    state = expected_discovery(plan, passed)
    section['targets'].update(state['targets'])
    section['xpnts'] = sorted(set(section['xpnts']) | set(state['xpnts']) | set(isolation.ROUND_CLONES))
    section['tokens'] = sorted(set(section['tokens']) | set(section['xpnts']))
    inventory = section['inventory']
    old_factory = plan['pin']['oldOwnerIsolation']['targets']['xPNTsFactory']
    if 'A4.factory' in passed:
        factory = plan['addresses']['xPNTsFactoryV2']
        section['targets']['legacyFactory'] = old_factory
        section['targets']['releaseFactory'] = factory
        pin['discoveryReleaseFactory'] = factory
        inventory['legacyFactory'] = inventory.get('targetInventories', {}).get(old_factory, inventory['xPNTsFactory'])
        release = plan['rebuild']['oldOwnerInventory']
        inventory['releaseFactory'] = release['xPNTsFactoryV2']
        inventory.setdefault('targetInventories', {})[factory] = release['xPNTsFactoryV2']
        for token in set(section['xpnts']) - set(plan['pin']['oldOwnerIsolation']['xpnts']):
            spec = copy.deepcopy(release['xPNTsTokenV2'])
            for group in ('roles', 'authorities', 'mappings'):
                rows = {r['signature']: r for r in spec[group]}
                rows.update({r['signature']: r for r in release['xPNTsTokenV2Ext'][group]})
                spec[group] = list(rows.values())
            inventory['targetInventories'][token] = spec
    pin['discoveryExpected'] = state
    pin['discoveryOriginalFactory'] = old_factory
    pin['discoveryRetainedTokens'] = plan['pin']['oldOwnerIsolation']['xpnts']
    return pin


def current_discovery(rpc, pin, block):
    found = isolation.discover_targets(rpc, dict(pin, stateBlock=block))
    release_tokens = None
    if 'discoveryReleaseFactory' in pin and u.code(rpc, pin['discoveryReleaseFactory'], block) != '0x':
        found['releaseFactory'] = [pin['discoveryReleaseFactory']]
        release_tokens = u.addr_array(a.call(rpc, pin['discoveryReleaseFactory'], 'getAllTokens()', block=block))
        found['xPNTsToken'] = sorted(set(found['xPNTsToken']) | set(release_tokens))
    if 'discoveryOriginalFactory' in pin and found['xPNTsFactory'][0] != pin['discoveryOriginalFactory']:
        found['legacyFactory'] = [pin['discoveryOriginalFactory']]
        tokens = u.addr_array(a.call(rpc, pin['discoveryOriginalFactory'], 'getAllTokens()', block=block))
        a.need('old_owner_original_factory_enumeration', set(isolation.ROUND_CLONES) | set(pin['discoveryRetainedTokens']) <= set(tokens), True)
        a.need('old_owner_release_factory_enumeration', release_tokens is not None and set(release_tokens) == set(pin['discoveryExpected']['xpnts']) - set(pin['discoveryRetainedTokens']), True)
        found['xPNTsToken'] = sorted(set(found['xPNTsToken']) | set(tokens))
    return dict(targets={name: group[0] for name, group in found.items() if name != 'xPNTsToken'},
                xpnts=sorted(set(found['xPNTsToken'])))


def discovery_old_authority(rpc, pin, block):
    rows = isolation.authority_rows(pin['oldOwnerIsolation'])
    clean = []
    for target, sig, args, kind in rows:
        args = [isolation.OLD if arg == isolation.OLD_TIMELOCK else arg for arg in args]
        raw = a.call(rpc, target, sig, *args, block=block)
        clean.append(u.config(raw)['owner'] != isolation.OLD if kind == 'config' else
                     u.addr_word(u.uints(raw)[0]) != isolation.OLD if kind == 'address' else u.uints(raw) == [0])
    for token in pin['oldOwnerIsolation']['tokens']:
        for holder in isolation.allowance_holders():
            clean.append(u.uints(a.call(rpc, token, 'allowance(address,address)', holder, isolation.OLD, block=block)) == [0])
    a.need('discovery_old_authority', all(clean), True)


def closing_timelock_inventory(rpc, pin, block):
    current = dict(pin, stateBlock=block)
    section = copy.deepcopy(pin['oldOwnerIsolation'])
    found = current_discovery(rpc, pin, block)
    expected = pin.get('discoveryExpected', pin_discovery(pin))
    section['xpnts'] = sorted(set(section['xpnts']) | set(found['xpnts']))
    section['tokens'] = sorted({pin['capped'], isolation.OLD_TOKEN, section['targets']['GToken'], *section['xpnts']})
    inventory = section['inventory']
    deployments = {r['target']: r['creationBlock'] for r in inventory.get('deployedSources', [])}
    section['roleHistory'] = {}
    for name, target in [*section['targets'].items(), *(('xPNTsToken', t) for t in section['xpnts'])]:
        spec = inventory.get('targetInventories', {}).get(target, inventory[name])
        # Scan from genesis for newly discovered contracts, before rejecting inventory drift.
        creation = deployments.get(target, pin.get('isolationDeployments', {}).get(target, 1))
        section['roleHistory'][target] = isolation.role_history(rpc, current, target, spec, creation)
    spec = inventory.get('targetInventories', {}).get(u.REG, inventory['Registry'])
    logs = isolation.bounded_history_logs(rpc, dict(address=u.REG, fromBlock=hex(pin['registryCreation']),
        toBlock=block, topics=[spec['roleEventTopic']]))
    section['configuredRoles'] = sorted({r['value'] for r in spec['roles']} | {log['topics'][1] for log in logs} | set(section['roleHistory'].get(u.REG, [])))
    fields = ('configuredRoles',) if 'discoveryExpected' in pin else ('targets', 'xpnts', 'tokens', 'roleHistory', 'configuredRoles')
    # Coverage never shrinks: every pin target keeps its pinned role history, even after planned discovery changes.
    pinned = pin['oldOwnerIsolation']['roleHistory']
    a.need('old_timelock_inventory_pinned_history', {t: section['roleHistory'].get(t) for t in pinned}, pinned)
    a.need('old_timelock_inventory', (found, {k: section[k] for k in fields}),
           (expected, {k: pin['oldOwnerIsolation'][k] for k in fields}))
    return dict(pin, oldOwnerIsolation=section)


def post_pin_delta(rpc, pin, block):
    section = pin['oldOwnerIsolation']
    start, stop = a.qty(pin['stateBlock'])+1, a.qty(block)
    owners = copy.deepcopy(pin['oldTimelock']['approvalOwners'])
    counts, checked, canonical = {}, {}, {}
    spender = '0x'+isolation.OLD_TIMELOCK[2:].zfill(64)
    approval = a.keccak('Approval(address,address,uint256)')
    inventory = section['inventory']
    registry = inventory.get('targetInventories', {}).get(u.REG, inventory['Registry'])
    configured = registry['roleEventTopic']
    def scan(target, topics):
        logs = isolation.bounded_history_logs(rpc, dict(address=target, fromBlock=hex(start), toBlock=block, topics=topics)) if start <= stop else []
        for log in logs:
            a.need('old_timelock_delta_address', log.get('address'), target)
            a.need('old_timelock_delta_removed', log.get('removed', False), False)
            ts = log.get('topics', [])
            signatures = topics[0] if isinstance(topics[0], list) else [topics[0]]
            length = 2 if ts and ts[0] == configured else 3 if ts and ts[0] in (approval, a.keccak(isolation.REGISTERED), a.keccak(isolation.EXITED)) else 4
            a.need('old_timelock_delta_topics', isinstance(ts, list) and len(ts) == length and ts[0] in signatures and
                   all(isinstance(t, str) and re.fullmatch(r'0x[0-9a-fA-F]{64}', t) for t in ts) and
                   (topics[0] != approval or ts[2] == spender), True)
            number = a.qty(a.typed(log.get('blockNumber'), a.QTY))
            a.need('old_timelock_delta_range', start <= number <= stop, True)
            if number not in canonical:
                canonical[number] = rpc('eth_getBlockByNumber', [hex(number), False])
            a.need('old_timelock_delta_canonical', log.get('blockHash'), canonical[number]['hash'])
            a.need('old_timelock_delta_number', canonical[number]['number'], hex(number))
        counts[target+':'+str(topics[0])] = len(logs)
        return logs
    for token in section['tokens']:
        holders = set(owners.get(token, []))
        for log in scan(token, [approval, None, spender]):
            holders.add(u.addr_word(int(log['topics'][1], 16)))
        owners[token] = sorted(holders)
        for holder in sorted(holders - set(pin['oldTimelock']['approvalOwners'].get(token, []))):
            a.need('old_timelock_delta_allowance', u.uints(a.call(rpc, token, 'allowance(address,address)', holder, isolation.OLD_TIMELOCK, block=block)), [0])
    configured_roles = {log['topics'][1] for log in scan(u.REG, [configured])}
    for name, target in [*sorted(section['targets'].items()), *(('xPNTsToken', t) for t in section['xpnts'])]:
        spec = inventory.get('targetInventories', {}).get(target, inventory[name])
        roles = set(configured_roles) if target == u.REG else set()
        if spec['hasRole']:
            events = [isolation.GRANTED, isolation.REVOKED] + ([isolation.REGISTERED, isolation.EXITED] if target == u.REG else [])
            roles.update(log['topics'][1] for log in scan(target, [[a.keccak(e) for e in events]]))
        checked[target] = sorted(roles)
        for role in sorted(roles):
            if target == u.REG:
                a.need('old_timelock_delta_config_owner', u.config(a.call(rpc, target, 'getRoleConfig(bytes32)', role, block=block))['owner'] != isolation.OLD_TIMELOCK, True)
            if spec['hasRole']:
                a.need('old_timelock_delta_timelock_role', u.uints(a.call(rpc, target, 'hasRole(bytes32,address)', role, isolation.OLD_TIMELOCK, block=block)), [0])
                a.need('old_timelock_delta_old_role', u.uints(a.call(rpc, target, 'hasRole(bytes32,address)', role, isolation.OLD, block=block)), [0])
    found = current_discovery(rpc, pin, block)
    expected = pin.get('discoveryExpected', pin_discovery(pin))
    a.need('old_timelock_delta_targets', found['targets'], expected['targets'])
    a.need('old_timelock_delta_xpnts', found['xpnts'], expected['xpnts'])
    return dict(fromBlock=hex(start), toBlock=block, logCounts=counts, rolesChecked=checked, approvalOwners=owners)


def old_timelock_holds_nothing(rpc, pin, block, owners=None):
    # pre_send supplies pinned owners plus the post-pin delta; closing and the pin scan full history.
    section = pin['oldOwnerIsolation']
    reads = []
    def call(target, sig, *args):
        raw = a.typed(rpc('eth_call', [dict(to=target, data=a.calldata(sig, *args)), block]), a.HEXDATA)
        reads.append(dict(target=target, signature=sig, args=list(args), block=block, result=raw))
        return raw
    roles = [a.ZERO32, *(a.keccak(r+'_ROLE') for r in ('PROPOSER', 'EXECUTOR', 'CANCELLER'))]
    values = [u.uints(call(u.TL, 'hasRole(bytes32,address)', r, isolation.OLD_TIMELOCK)) for r in roles]
    a.need('old_timelock_tl_roles', values, [[0]]*4)
    rows = isolation.authority_rows(section)
    authority = []
    for target, sig, args, kind in rows:
        raw = call(target, sig, *args)
        if kind == 'config':
            clean = u.config(raw)['owner'] != isolation.OLD_TIMELOCK
        elif kind == 'address':
            words = u.uints(raw)
            clean = len(words) == 1 and u.addr_word(words[0]) != isolation.OLD_TIMELOCK
        else:
            clean = u.uints(raw) == [0]
        authority.append(clean)
    a.need('old_timelock_authority', all(authority), True)
    approval_owners = {}
    deployments = {r['target']: r['creationBlock'] for r in section['inventory'].get('deployedSources', [])}
    approval = a.keccak('Approval(address,address,uint256)')
    spender = '0x'+isolation.OLD_TIMELOCK[2:].zfill(64)
    def recorded_logs(method, params):
        result = rpc(method, params)
        reads.append(dict(method=method, params=copy.deepcopy(params), block=block, result=copy.deepcopy(result)))
        return result
    for token in section['tokens']:
        if owners is not None:
            holders = set(owners.get(token, []))
        else:
            creation = deployments.get(token, pin.get('isolationDeployments', {}).get(token, 1))
            a.need('old_timelock_approval_history', type(creation) is int and 0 < creation <= a.qty(block), True)
            logs = isolation.bounded_history_logs(recorded_logs, dict(address=token,
                fromBlock=hex(creation), toBlock=block, topics=[approval, None, spender]))
            holders = set()
            for log in logs:
                topics = log.get('topics', [])
                a.need('old_timelock_approval_history', log.get('address') == token and
                       not log.get('removed', False) and len(topics) == 3 and
                       topics[0] == approval and topics[2] == spender and
                       creation <= a.qty(log.get('blockNumber', '0x0')) <= a.qty(block), True)
                holders.add(u.addr_word(int(a.typed(topics[1], a.HASH32), 16)))
        approval_owners[token] = sorted(holders)
        for holder in sorted(holders | set(isolation.allowance_holders())):
            a.need('old_timelock_allowance', u.uints(call(token, 'allowance(address,address)', holder, isolation.OLD_TIMELOCK)), [0])
    owners = u.addr_array(call(u.SAFE, 'getOwners()'))
    module = u.uints(call(u.SAFE, 'isModuleEnabled(address)', isolation.OLD_TIMELOCK))
    a.need('old_timelock_safe', isolation.OLD_TIMELOCK not in owners and module == [0], True)
    wanted = set(section['targets'].values()) | set(section['xpnts'])
    a.need('old_timelock_holds_nothing', bool(wanted) and {r[0] for r in rows} == wanted, True)
    return dict(block=block, reads=reads, approvalOwners=approval_owners)


def dvt_closing(rpc, plan):
    # After the last step: per-step pre_send reads cannot see anything that lands after it.
    # Every read is bound to one block (DSR #606 L2); all three A8 pointers are re-read (L1).
    d = plan['externalInputs']['data']
    dvt, block = d['dvt'], a.block_data(rpc, 'latest')['number']
    isolation.registry_callsite_targets(lambda target, sig: a.address(rpc, target, sig, block), {})
    coverage = discovery_coverage(plan, {s['id'] for s in plan['steps']})
    never_granted = isolation.never_granted_recheck(rpc, coverage, block)
    expected = plan['pin']['oldAggregator'] if plan['stage'] == 'a7' else plan['addresses']['BLSAggregator']
    pointers = dict(registry=a.address(rpc, u.REG, 'blsAggregator()', block), dvt=a.address(rpc, dvt, 'BLS_AGGREGATOR()', block),
                    committee=a.address(rpc, d['committee'], 'blsAggregator()', block))
    a.need('closing_registry_pointer', pointers['registry'], expected)
    a.need('closing_dvt_pointer', pointers['dvt'], expected)
    a.need('closing_committee_pointer', pointers['committee'], expected)
    latest = dvt_activity(rpc, dvt, block)
    a.need('closing_dvt_activity', latest, plan['pin']['oldActivity']['dvtProposals'])
    for proposal in sorted(STALE_PROPOSALS):
        a.need('closing_stale_unexecuted', (proposal, u.uints(a.call(rpc, dvt, 'proposals(uint256)', proposal, block=block))[3]), (proposal, 0))
    closing = closing_timelock_inventory(rpc, coverage, block)
    discovery_old_authority(rpc, closing, block)
    return dict(neverGranted=never_granted, block=block, pointers=pointers, dvtAggregator=expected, staleUnexecuted=sorted(STALE_PROPOSALS),
                oldTimelock=old_timelock_holds_nothing(rpc, closing, block))


def balances(rpc, operators, block='latest'):
    amounts = {}
    for who in operators:
        words = u.uints(a.call(rpc, u.SP, 'operators(address)', who, block=block))
        a.need('operator_shape', len(words), 9)
        amounts[who] = words[0]
    return dict(totalTrackedBalance=a.word(rpc, u.SP, 'totalTrackedBalance()', block=block),
                protocolRevenue=a.word(rpc, u.SP, 'protocolRevenue()', block=block), operatorBalances=amounts)


def drain_gate(pin):
    required(pin, ('operatorBalances', 'totalTrackedBalance', 'protocolRevenue'), 'drain_pin_required')
    a.need('drain_nonnegative', all(type(v) is int and v >= 0 for v in
           [pin['totalTrackedBalance'], pin['protocolRevenue'], *pin['operatorBalances'].values()]), True)
    a.need('drain_sum_closes', sum(pin['operatorBalances'].values())+pin['protocolRevenue'], pin['totalTrackedBalance'])
    a.need('revenue_buffer', pin['protocolRevenue'] >= BUFFER, True)
    authorized = {pin['senders'][x]['address'] for x in ('deployer', 'anni')}
    a.need('drain_senders', all(v == 0 or k in authorized for k, v in pin['operatorBalances'].items()), True)


# ---------------------------------------------------------------------------
# Phase C: funding and sampling configuration (MANIFEST-DESIGN.md §3, after 6d).
# Every value below is a DSR 2026-11-02 literal; none is chosen at execution time.
# ---------------------------------------------------------------------------
PC_STAGES = ('c', 'full')
PC_ATTEMPTS = 100                 # n per arm (50 formal + 20 pilot + 30 margin); never reduced
PC_FEE = 5*10**9                  # f: formal/pilot max fee per gas
PC_PRIORITY = 10**9
PC_PRICE_CAP = 3500*10**8         # P*: upper bound for positive cached ETH/USD
PC_PRICE_DECIMALS = 8             # d
PC_RATE = 10**18                  # e: X exchange rate
PC_BETA = 5                       # beta_A / extra_EP_j / beta_X / beta_Q = 5x per-attempt maxima
PC_BUNDLER_BETA = 2*10**17        # beta_B
PC_SP_POSTOP = 480000             # initial pp_SP; SP_RENEW is never set
PC_AMAX_CAP = 5000*10**18
PC_XPNTS_TX_LIMIT = 5000*10**18   # xPNTsTokenV2.initialize default maxSingleTxLimit
PC_CAP_L = 50000*10**18           # L: autoAllowance and userTotal cap, no renewal
PC_TASK_UNIT = 1                  # u
PC_TASK_SENDER = 3*PC_ATTEMPTS*PC_TASK_UNIT+PC_TASK_UNIT
DEAD = '0x000000000000000000000000000000000000dead'   # R, TPM wrappedNative/uniswap
PC_STAKE = 10**18
PC_VALIDATION_BUFFER_BPS = 1000   # SuperPaymasterStorage.sol VALIDATION_BUFFER_BPS
PC_TPM_MARKUP = 10**26
PC_TPM_REFUND = 40000
PC_TPM_AGE = 864000
PC_TPM_THRESHOLD = 10**25
PC_TOKEN = ('AOA Research Points', 'xARP', 'AOA Research', '')
PC_TREASURY = u.SAFE
FLAG_SP_RENEW = 1
ACCOUNT_FACTORY = '0x91e60e0613810449d098b0b5ec8b51a0fe8c8985'
ARMS = ('SP', 'VPM', 'TPM')
# ISuperPaymaster.OperatorConfig declaration order = the public getter's return order.
OPERATOR_FIELDS = ('aPNTsBalance', 'isConfigured', 'isPaused', 'xPNTsToken', 'reputation', 'minTxInterval',
                   'treasury', 'totalSpent', 'totalTxSponsored')
OP = {name: i for i, name in enumerate(OPERATOR_FIELDS)}
ARM_FIELDS = ('call', 'verification', 'paymasterVerification', 'postOp', 'preVerification', 'outer')
OWNER_PREPARATION = ('C9.allowance', 'C9.total', 'C9.mode', 'C18.approve')
PC_RUNTIMES = ('accountFactory', 'accountImplementation', 'account', 'VerifyingPaymaster', 'TokenPaymaster')
BASELINE_ARTIFACTS = {'VerifyingPaymaster': 'script/a6-collector/artifacts/VerifyingPaymaster.json',
                      'TokenPaymaster': 'script/a6-collector/artifacts/TokenPaymaster.json'}
F1_SOURCE = 'contracts/test/bundler/F1Fixtures.sol'
VPM_CONSTRUCTOR = 'c(address,address)'
TPM_CONSTRUCTOR = ('c(address,address,address,address,(uint256,uint128,uint48,uint48),'
                   '(uint48,uint48,address,address,bool,bool,bool,uint256),(uint256,uint24,uint8),address)')
F1_SCOPE_NOTE = ('F1Fixtures.sol header says "local nodes only"; DSR 2026-11-02 permits F1TestToken (separate '
                 'T and Q instances) and F1Oracle on Sepolia for this gas experiment without source changes. '
                 'The local Anvil deployment recipe (deploy-baselines.mjs) is not used.')


@lru_cache(maxsize=8)
def role_id(name):
    return a.keccak(name)


def abi_type(item):
    if item['type'].startswith('tuple'):
        return '('+','.join(abi_type(x) for x in item['components'])+')'+item['type'][5:]
    return item['type']


@lru_cache(maxsize=2)
def rebuild_baselines(head):
    """Comparator artifacts: F1 fixtures compiled from the release tree; the two unchanged
    v0.7 sample paymasters from their committed artifacts, source-hash bound to the same tree."""
    version = subprocess.run([str(a.REBUILD_FORGE), '--version'], capture_output=True, text=True, check=True).stdout
    a.need('baseline_forge_version', version.splitlines()[0], 'forge Version: 1.7.1')
    result = {}
    with tempfile.TemporaryDirectory(prefix='manifest-baselines-') as directory:
        tree = Path(directory)/'tree'
        a.archive_commit(u.ROOT, head, tree)
        env = {k: os.environ[k] for k in ('HOME', 'PATH', 'TMPDIR', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'SVM_HOME') if k in os.environ}
        env['FOUNDRY_PROFILE'] = 'default'
        built = subprocess.run([str(a.REBUILD_FORGE), 'build', '--offline', '--ast', '--build-info'],
                               cwd=tree, env=env, capture_output=True)
        a.need('baseline_offline_build', built.returncode, 0)
        for name, immutables in (('F1TestToken', ('MINTER',)), ('F1Oracle', ())):
            art = json.loads((tree/'out/F1Fixtures.sol'/(name+'.json')).read_text())
            refs = art['deployedBytecode'].get('immutableReferences', {})
            identity = (a.immutable_identity(art, tree/'out/build-info', name, frozenset(immutables)) if refs else
                        dict(artifactRuntime=art['deployedBytecode']['object'], ranges=[]))
            a.need('baseline_immutables_'+name, sorted({r['name'] for r in identity['ranges']}), sorted(immutables))
            result[name] = dict(bytecode=art['bytecode']['object'], runtimeIdentity=identity, source=F1_SOURCE, commit=head)
        for name, path in BASELINE_ARTIFACTS.items():
            raw = (tree/path).read_bytes()
            art = a.plan_json(raw)
            source = hashlib.sha256((tree/art['source']).read_bytes()).hexdigest()
            a.need('baseline_source_'+name, art['sourceSha256'], source)
            ctor = [x for x in art['abi'] if x.get('type') == 'constructor']
            a.need('baseline_constructor_count_'+name, len(ctor), 1)
            result[name] = dict(bytecode=art['bytecode'], artifact=path, artifactSha256=hashlib.sha256(raw).hexdigest(),
                                source=art['source'], sourceSha256=source, commit=head,
                                constructor='c('+','.join(abi_type(x) for x in ctor[0]['inputs'])+')')
    return result


def ceil_div(n, d):
    return (n+d-1)//d


def positive(x):
    return max(0, x)


def pre_pilot(x):
    # Amsterdam rehearsal measurement x 1.5, rounded up (§3).
    return ceil_div(3*x, 2)


def single_line(value):
    return isinstance(value, str) and re.fullmatch(r'\S(?:[^\r\n]*\S)?', value) is not None


def pc_address(gate, value):
    a.need(gate, isinstance(value, str) and a.ADDRESS_RX.fullmatch(value) is not None
           and value == value.lower() and value != a.ZERO, True)
    return value


def pc_hash(gate, value):
    a.need(gate, isinstance(value, str) and a.HASH32.fullmatch(value) is not None and value == value.lower()
           and int(value, 16) != 0 and value != a.EMPTY_KECCAK, True)
    return value


def pc_integer(gate, value, minimum=1):
    a.need(gate, type(value) is int and minimum <= value < 2**256, True)
    return value


def validate_phase_c_inputs(c):
    a.exact_keys('phase_c_inputs', c, ('bundler', 'accountOwner', 'verifyingSigner', 'account', 'salt',
                                       'accountImplementation', 'runtimeKeccak', 'accountEvidence', 'rehearsal'))
    for key in ('bundler', 'accountOwner', 'verifyingSigner', 'account', 'accountImplementation'):
        pc_address('phase_c_address_'+key, c[key])
    identities = [c['bundler'], c['accountOwner'], c['verifyingSigner']]
    # B/O/V are fresh dedicated keystores, distinct from D/N/A/E and from each other.
    a.need('phase_c_identity_distinct', len(set(identities+[u.DEPLOYER, ANNI, a.APPROVER, a.EXECUTOR])), 7)
    a.need('phase_c_account_distinct', c['account'] not in set(identities+[u.DEPLOYER, ANNI, a.APPROVER,
           a.EXECUTOR, DEAD, u.SP, u.SAFE, ACCOUNT_FACTORY]), True)
    pc_integer('phase_c_salt', c['salt'], 0)
    a.exact_keys('phase_c_runtime_keys', c['runtimeKeccak'], PC_RUNTIMES)
    for key in PC_RUNTIMES:
        pc_hash('phase_c_runtime_'+key, c['runtimeKeccak'][key])
    required(c['accountEvidence'], ('path', 'sha256'), 'phase_c_account_evidence')
    a.need('phase_c_account_evidence_nonempty', bool(reviewed_bytes(
        c['accountEvidence']['path'], c['accountEvidence']['sha256'], 'phase_c_account_evidence').strip()), True)
    r = c['rehearsal']
    a.exact_keys('phase_c_rehearsal', r, ('evidence', 'arms', 'ownerPreparation', 'ownerMaintenance', 'bundlerMaintenance'))
    required(r['evidence'], ('path', 'sha256'), 'phase_c_rehearsal_evidence')
    a.need('phase_c_rehearsal_evidence_nonempty', bool(reviewed_bytes(
        r['evidence']['path'], r['evidence']['sha256'], 'phase_c_rehearsal_evidence').strip()), True)
    a.exact_keys('phase_c_arms', r['arms'], ARMS)
    for arm in ARMS:
        # pp_SP is the fixed initial 480000; an SP postOp measurement cannot replace it.
        fields = tuple(f for f in ARM_FIELDS if not (arm == 'SP' and f == 'postOp'))
        a.exact_keys('phase_c_arm_fields_'+arm, r['arms'][arm], fields)
        for field in fields:
            pc_integer('phase_c_measurement', r['arms'][arm][field], 0 if field == 'postOp' else 1)
    a.exact_keys('phase_c_owner_preparation', r['ownerPreparation'], OWNER_PREPARATION)
    for value in r['ownerPreparation'].values():
        pc_integer('phase_c_measurement', value)
    for key in ('ownerMaintenance', 'bundlerMaintenance'):
        a.need('phase_c_maintenance_list', isinstance(r[key], list), True)
        for item in r[key]:
            a.exact_keys('phase_c_maintenance_fields', item, ('name', 'gas'))
            a.need('phase_c_maintenance_name', single_line(item['name']), True)
            pc_integer('phase_c_measurement', item['gas'])
        names = [item['name'] for item in r[key]]
        a.need('phase_c_maintenance_unique', len(names), len(set(names)))


def addr_call(rpc, target, sig, *args, block='latest'):
    return u.addr_word(a.word(rpc, target, sig, *args, block=block))


def account_status(rpc, account, mysbt, block='latest'):
    return [a.word(rpc, u.REG, 'hasRole(bytes32,address)', role_id('ENDUSER'), account, block=block),
            a.word(rpc, mysbt, 'verifyCommunityMembership(address,address)', account, u.DEPLOYER, block=block),
            a.word(rpc, u.SP, 'sbtHolders(address)', account, block=block)]


def collect_phase_c(rpc, block, inputs, pin):
    """Public pin reads for Phase C; the builder re-checks every gate from these values."""
    c = inputs['data']['phaseC']
    out = {}
    for label, key in (('owner', 'accountOwner'), ('bundler', 'bundler'), ('verifyingSigner', 'verifyingSigner')):
        who = c[key]
        n = a.nonce(rpc, who, block)
        a.need('phase_c_pending_nonce_'+label, a.nonce(rpc, who, 'pending'), n)
        out[label] = dict(address=who, nonce=n, balance=a.qty(rpc('eth_getBalance', [who, block])),
                          code=u.code(rpc, who, block))
    capped = pin['capped']
    out['capped'] = dict(cap=a.word(rpc, capped, 'cap()', block=block),
        totalSupply=a.word(rpc, capped, 'totalSupply()', block=block),
        minter=a.address(rpc, capped, 'minter()', block),
        deployerBalance=a.word(rpc, capped, 'balanceOf(address)', u.DEPLOYER, block=block))
    out['sp'] = dict(aPNTsPriceUSD=a.word(rpc, u.SP, 'aPNTsPriceUSD()', block=block),
        protocolFeeBPS=a.word(rpc, u.SP, 'protocolFeeBPS()', block=block),
        cachedPrice=u.uints(a.call(rpc, u.SP, 'cachedPrice()', block=block)),
        deployerOperator=u.uints(a.call(rpc, u.SP, 'operators(address)', u.DEPLOYER, block=block)))
    out['roles'] = {name: a.word(rpc, u.REG, 'hasRole(bytes32,address)', role_id(name), u.DEPLOYER, block=block)
                    for name in ('COMMUNITY', 'PAYMASTER_SUPER')}
    staking = a.address(rpc, u.REG, 'GTOKEN_STAKING()', block)
    gtoken = a.address(rpc, staking, 'GTOKEN()', block)
    mysbt = a.address(rpc, u.REG, 'MYSBT()', block)
    out['endUser'] = dict(roleConfig=a.call(rpc, u.REG, 'getRoleConfig(bytes32)', role_id('ENDUSER'), block=block),
        staking=staking, gtoken=gtoken, mysbt=mysbt,
        deployerGToken=a.word(rpc, gtoken, 'balanceOf(address)', u.DEPLOYER, block=block))
    impl = addr_call(rpc, ACCOUNT_FACTORY, 'accountImplementation()', block=block)
    account = c['account']
    code = u.code(rpc, account, block)
    out['account'] = dict(factoryCodeHash=a.keccak(u.code(rpc, ACCOUNT_FACTORY, block)), implementation=impl,
        implementationCodeHash=a.keccak(u.code(rpc, impl, block)),
        implementationEntryPoint=addr_call(rpc, impl, 'entryPoint()', block=block),
        counterfactual=addr_call(rpc, ACCOUNT_FACTORY, 'getAddress(address,uint256)', c['accountOwner'], c['salt'], block=block),
        codeHash=a.keccak(code), status=account_status(rpc, account, mysbt, block))
    if code != '0x':
        out['account'].update(owner=addr_call(rpc, account, 'owner()', block=block),
            entryPoint=addr_call(rpc, account, 'entryPoint()', block=block),
            implementationSlot=u.addr_word(int(rpc('eth_getStorageAt', [account, u.IMPL_SLOT, block]), 16)))
    return out


def phase_c_pin_gates(pin, c):
    """Chain preconditions for Phase C, evaluated offline from the archived pin reads."""
    p = pin['phaseC']
    a.exact_keys('phase_c_pin', p, ('owner', 'bundler', 'verifyingSigner', 'capped', 'sp', 'roles', 'endUser', 'account'))
    for label, key in (('owner', 'accountOwner'), ('bundler', 'bundler'), ('verifyingSigner', 'verifyingSigner')):
        a.need('phase_c_pin_identity_'+label, p[label]['address'], c[key])
        a.need('phase_c_eoa_'+label, p[label]['code'], '0x')
    a.need('C1_minter', p['capped']['minter'], u.SAFE)
    price = p['sp']['cachedPrice']
    a.need('C_price_shape', len(price), 4)
    # A pin price alone does not bound future reservations: P* bounds funding, and the
    # live cache is re-read before every Phase C transaction.
    a.need('C_price_bound', 0 < price[0] <= PC_PRICE_CAP, True)
    a.need('C_pricing_nonzero', p['sp']['aPNTsPriceUSD'] > 0, True)
    a.need('C_operator_shape', len(p['sp']['deployerOperator']), len(OPERATOR_FIELDS))
    a.need('C2_operator_role', p['roles']['PAYMASTER_SUPER'], 1)
    a.need('C3_community', p['roles']['COMMUNITY'], 1)
    cfg = u.config(p['endUser']['roleConfig'])
    a.need('C7_enduser_active', cfg['isActive'], True)
    acct = p['account']
    a.need('C5_factory_runtime', acct['factoryCodeHash'], c['runtimeKeccak']['accountFactory'])
    a.need('C5_factory_implementation', acct['implementation'], c['accountImplementation'])
    a.need('C5_implementation_runtime', acct['implementationCodeHash'], c['runtimeKeccak']['accountImplementation'])
    a.need('C5_implementation_entrypoint', acct['implementationEntryPoint'], pin['immutables']['entryPoint'])
    a.need('C5_counterfactual', acct['counterfactual'], c['account'])
    exists = acct['codeHash'] != a.EMPTY_KECCAK
    if exists:
        a.need('C5_existing_account', [acct.get('codeHash'), acct.get('owner'), acct.get('entryPoint'), acct.get('implementationSlot')],
               [c['runtimeKeccak']['account'], c['accountOwner'], pin['immutables']['entryPoint'], c['accountImplementation']])
    # Membership is all or nothing; D cannot repair SP status directly (Registry-only).
    a.need('C_account_status', acct['status'] in ([0, 0, 0], [1, 1, 1]), True)
    return dict(accountExists=exists, member=acct['status'] == [1, 1, 1], minStake=cfg['minStake'], ticketPrice=cfg['ticketPrice'])


def phase_c_worksheet(pin, c, sp_deposit_before):
    """§3 funding worksheet with integer rounding exactly as written in the design."""
    p, r = pin['phaseC'], c['rehearsal']
    facts = phase_c_pin_gates(pin, c)
    n = PC_ATTEMPTS
    bounds, maxima, outer = {}, {}, {}
    for arm in ARMS:
        b = {k: pre_pilot(v) for k, v in r['arms'][arm].items()}
        if arm == 'SP':
            b['postOp'] = PC_SP_POSTOP
        bounds[arm] = b
        gas = sum(b[k] for k in ARM_FIELDS if k != 'outer')        # v0.7 sum, no v0.6 multiplier
        maxima[arm] = gas*PC_FEE                                    # M_j
        outer[arm] = b['outer']                                     # H_j
    price_a, fee_b = p['sp']['aPNTsPriceUSD'], p['sp']['protocolFeeBPS']
    a0 = ceil_div(maxima['SP']*PC_PRICE_CAP*10**18, 10**PC_PRICE_DECIMALS*price_a)
    amax = ceil_div(a0*(10000+fee_b+PC_VALIDATION_BUFFER_BPS), 10000)
    # Amax <= 5000e18 also gives Amax <= min(L, default maxSingleTxLimit) and a uint128-safe
    # operator target (105 x 5000e18 < 2^128); the live X limit is re-read before C8.
    a.need('C_amax_cap', amax <= PC_AMAX_CAP, True)
    target_a = n*amax+PC_BETA*amax
    # A15 drains every operator and the 6d swap requires totalTracked == revenue.
    delta_a = positive(target_a-0)
    delta_m = positive(delta_a-p['capped']['deployerBalance'])
    supply = p['capped']['totalSupply']+BUFFER                   # B2a minted the buffer
    a.need('C1_cap_headroom', supply+delta_m <= p['capped']['cap'], True)
    xmax = ceil_div(amax*PC_RATE, 10**18)
    target_x = n*xmax+PC_BETA*xmax
    deposits = {arm: n*maxima[arm]+maxima[arm]+PC_BETA*maxima[arm] for arm in ARMS}
    before = dict(SP=sp_deposit_before, VPM=0, TPM=0)
    qmax = ceil_div((maxima['TPM']+PC_TPM_REFUND*PC_FEE)*PC_TPM_MARKUP, PC_TPM_MARKUP)
    target_q = n*qmax+PC_BETA*qmax
    aux = [dict(name=x['name'], gas=pre_pilot(x['gas'])) for x in r['bundlerMaintenance']]
    target_b = n*PC_FEE*sum(outer.values())+PC_FEE*sum(x['gas'] for x in aux)+PC_BUNDLER_BETA
    prep = {k: pre_pilot(v) for k, v in r['ownerPreparation'].items()}
    maintenance = [dict(name=x['name'], gas=pre_pilot(x['gas'])) for x in r['ownerMaintenance']]
    maintenance_wei = sum(x['gas'] for x in maintenance)*PC_FEE
    target_o = sum(prep.values())*a.MAX_FEE+maintenance_wei
    stake_cost = 0 if facts['member'] else facts['minStake']+facts['ticketPrice']
    a.need('C6_gtoken_balance', p['endUser']['deployerGToken'] >= stake_cost, True)
    return dict(attempts=n, feeCap=PC_FEE, priorityCap=PC_PRIORITY, priceCap=PC_PRICE_CAP, priceDecimals=PC_PRICE_DECIMALS,
        exchangeRate=PC_RATE, betaMultiplier=PC_BETA, bundlerBeta=PC_BUNDLER_BETA, allowanceCap=PC_CAP_L,
        spRenew=False, spPostOp=PC_SP_POSTOP, bounds=bounds, maxPrefund=maxima, outerBound=outer,
        aPNTsPriceUSD=price_a, protocolFeeBPS=fee_b, A0=a0, Amax=amax, operatorTarget=target_a,
        operatorTopUp=delta_a, cappedMint=delta_m, cappedSupplyBefore=supply, Xmax=xmax, userTarget=target_x,
        entryPointTargets=deposits, entryPointBefore=before,
        entryPointTopUps={arm: positive(deposits[arm]-before[arm]) for arm in ARMS},
        Qmax=qmax, feeTokenTarget=target_q, taskSender=PC_TASK_SENDER, taskRecipient=PC_TASK_UNIT,
        bundlerMaintenance=aux, bundlerTarget=target_b, bundlerTopUp=positive(target_b-p['bundler']['balance']),
        ownerPreparation=prep, ownerMaintenance=maintenance, ownerMaintenanceWei=maintenance_wei,
        ownerTarget=target_o, ownerTopUp=positive(target_o-p['owner']['balance']),
        endUserStake=facts['minStake'], endUserTicket=facts['ticketPrice'],
        accountExists=facts['accountExists'], accountMember=facts['member'],
        token=dict(zip(('name', 'symbol', 'communityName', 'communityENS'), PC_TOKEN)), treasury=PC_TREASURY,
        recipient=DEAD, f1Provenance=F1_SCOPE_NOTE)


# keccak256 of the canonical Safe event signatures (checked offline in tests).
SAFE_EVENTS = {
    'ApproveHash(bytes32,address)': '0xf2a0eb156472d1440255b0d7c1e19cc07115d1051fe605b0dce69acfec884d9c',
    'SafeMultiSigTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes,bytes)': '0x66753cd2356569ee081232e3be8909b950e0a76c1f8460c3a5e3c2be32b11bed',
    'RemovedOwner(address)': '0xf8d49fc529812e9a7c5c50e69c20f0dccc0db8fa95c98bc58cc9a4f1c1299eaf',
    'AddedOwner(address)': '0x9465fa0c962cc76958e6373a993326400c1c94f8be2fe3a952adfa7f60b2ea26',
    'ExecutionSuccess(bytes32,uint256)': '0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e',
}
SAFE_SWAP_PACKET = '460e024407694772a511b283f62442f2521b297bddfad2b823ddc2dee80654d1'
SAFE_VOID_PACKET = 'ea2a4f09a3d0ab6826c3df51db7026be150f46a43e3bed3c3fc5f527f23390c3'


def governance_entries(inputs):
    entries = inputs['data'].get('safeGovernanceGaps', [])
    a.need('safe_gap_list', isinstance(entries, list), True)
    rows = []
    for entry in entries:
        a.exact_keys('safe_gap_entry', entry, ('path', 'sha256', 'step', 'hash'))
        packet = reviewed_file(entry['path'], entry['sha256'], 'safe_gap_packet')
        a.need('safe_gap_reviewed_packet', entry['sha256'] in (SAFE_SWAP_PACKET, SAFE_VOID_PACKET), True)
        a.need('safe_gap_step', entry['step'] in ('approveHash', 'execTransaction') and
               (entry['sha256'] != SAFE_VOID_PACKET or entry['step'] == 'approveHash'), True)
        steps = [t for t in packet['transactions'] if t['step'] == entry['step']]
        a.need('safe_gap_packet_step', len(steps), 1)
        tx = steps[0]
        a.typed(entry['hash'], a.HASH32, gate='safe_gap_hash')
        a.need('safe_gap_safe', tx['to'], a.SAFE)
        a.need('safe_gap_packet_chain', packet['chainId'], a.CHAIN)
        a.need('safe_gap_safe_hash', packet['safeTxHash'], safe_hash(packet['swapOwner']['data'], packet['safeNonce'], a.SAFE))
        rows.append(dict(entry=entry, packet=packet, tx=tx, status=int(entry['sha256'] == SAFE_SWAP_PACKET)))
    keys = [(r['tx']['from'], r['tx']['nonce']) for r in rows]
    a.need('safe_gap_unique', len(keys), len(set(keys)))
    return rows


def governance_nonces(inputs):
    return [dict(r['tx'], nonce=hex(r['tx']['nonce'])) for r in governance_entries(inputs)]


def governance_trace(diff, row, miner, receipt, base_fee):
    tx, packet = row['tx'], row['packet']
    a.need('safe_gap_trace_shape', isinstance(diff, dict) and set(diff) == {'pre', 'post'} and
           all(isinstance(x, dict) for x in diff.values()), True)
    pre, post = diff['pre'], diff['post']
    sender = tx['from']
    allowed = {sender, miner} | ({a.SAFE} if row['status'] else set())
    # Pre-only accounts are deletions in diffMode, not harmless reads.
    a.need('safe_gap_trace_accounts', set(pre) | set(post) <= allowed, True)
    for accounts in (pre, post):
        for account in accounts.values():
            a.need('safe_gap_trace_account_shape', isinstance(account, dict) and
                   set(account) <= {'balance', 'nonce', 'code', 'storage'}, True)
            if 'balance' in account:
                a.typed(account['balance'], a.QTY, gate='safe_gap_trace_balance')
            if 'nonce' in account:
                a.need('safe_gap_trace_nonce', type(account['nonce']) is int and account['nonce'] >= 0, True)
            if 'code' in account:
                a.typed(account['code'], a.HEXDATA, gate='safe_gap_trace_code')
            storage = account.get('storage', {})
            a.need('safe_gap_trace_storage', isinstance(storage, dict), True)
            for key, value in storage.items():
                a.typed(key, a.HASH32, gate='safe_gap_trace_storage')
                a.typed(value, a.HASH32, gate='safe_gap_trace_storage')
    a.need('safe_gap_trace_sender', sender in pre and sender in post, True)
    a.need('safe_gap_sender_fields', set(post[sender]), {'nonce', 'balance'})
    a.need('safe_gap_sender_nonce', [pre[sender].get('nonce'), post[sender]['nonce']], [tx['nonce'], tx['nonce']+1])
    a.need('safe_gap_sender_pre_balance', 'balance' in pre[sender], True)
    gas_used = a.qty(a.typed(receipt.get('gasUsed'), a.QTY, gate='safe_gap_gas_used'))
    gas_price = a.qty(a.typed(receipt.get('effectiveGasPrice'), a.QTY, gate='safe_gap_gas_price'))
    a.need('safe_gap_sender_balance', a.qty(pre[sender]['balance']) - a.qty(post[sender]['balance']), gas_used * gas_price + tx['value'])
    a.need('safe_gap_sender_storage', pre[sender].get('storage', {}), {})
    a.need('safe_gap_sender_code', pre[sender].get('code', '0x'), '0x')
    a.need('safe_gap_miner_fields', set(post.get(miner, {})) <= {'balance'} and miner in post, True)
    a.typed(post[miner].get('balance'), a.QTY, gate='safe_gap_miner_balance')
    # The fee recipient gains exactly the priority fee; an absent pre balance was zero.
    miner_pre = a.qty(a.typed(pre.get(miner, {}).get('balance', '0x0'), a.QTY, gate='safe_gap_miner_balance'))
    a.need('safe_gap_miner_balance', a.qty(post[miner]['balance']) - miner_pre, gas_used * (gas_price - base_fee))
    a.need('safe_gap_miner_storage', pre.get(miner, {}).get('storage', {}), {})
    if not row['status']:
        return
    a.need('safe_gap_safe_fields', set(post.get(a.SAFE, {})), {'storage'})
    old = pre.get(a.SAFE, {}).get('storage', {})
    new = post[a.SAFE]['storage']
    def slot(addr): return a.keccak('0x'+addr[2:].zfill(64)+format(2, '064x'))
    if tx['step'] == 'approveHash':
        key = a.keccak(packet['safeTxHash']+a.keccak('0x'+a.APPROVER[2:].zfill(64)+format(8, '064x'))[2:])
        expected = {key: (0, 1)}
    else:
        swap = packet['swapOwner']
        expected = {slot(swap['prev']): (int(swap['old'], 16), int(swap['new'], 16)),
                    slot(swap['new']): (0, 1), slot(swap['old']): (1, 0),
                    '0x'+format(5, '064x'): (packet['safeNonce'], packet['expectedReadback']['nonce'])}
    a.need('safe_gap_storage_slots', set(old) | set(new), set(expected))
    for key, values in expected.items():
        a.need('safe_gap_storage_value', (int(old.get(key, '0x0'), 16), int(new.get(key, '0x0'), 16)), values)


def governance_logs(logs, row, receipt):
    packet, tx = row['packet'], row['tx']
    topics = list(SAFE_EVENTS.values())
    pad = lambda addr: '0x'+addr[2:].zfill(64)
    expected = []
    if row['status']:
        if tx['step'] == 'approveHash':
            expected = [[topics[0], packet['safeTxHash'], pad(a.APPROVER)]]
        else:
            expected = [[topics[1]], [topics[2], pad(packet['swapOwner']['old'])],
                        [topics[3], pad(packet['swapOwner']['new'])], [topics[4], packet['safeTxHash']]]
    a.need('safe_gap_logs', [(x.get('address'), x.get('topics')) for x in logs], [(a.SAFE, x) for x in expected])
    previous = None
    if logs:
        a.typed(receipt.get('transactionIndex'), a.QTY, gate='safe_gap_log_transactionIndex')
    for log in logs:
        for field in ('transactionHash', 'blockHash', 'blockNumber', 'transactionIndex'):
            a.need('safe_gap_log_' + field, log.get(field),
                   row['entry']['hash'] if field == 'transactionHash' else receipt.get(field))
        index = a.qty(a.typed(log.get('logIndex'), a.QTY, gate='safe_gap_log_logIndex'))
        if previous is not None:
            a.need('safe_gap_log_logIndex', index, previous + 1)
        previous = index
        a.need('safe_gap_log_removed', log.get('removed', False), False)
    if expected:
        if tx['step'] == 'approveHash':
            a.need('safe_gap_log_data', logs[0]['data'], '0x')
        else:
            a.need('safe_gap_log_data', [x['data'] for x in logs[1:]], ['0x', '0x', a.ZERO32])
            signatures = '0x'+''.join(who[2:].zfill(64)+'0'*64+'01' for who in sorted((a.APPROVER, a.EXECUTOR)))
            info = a.cast('abi-encode', 'c(uint256,address,uint256)', packet['safeNonce'], a.EXECUTOR, 2)
            data = a.cast('abi-encode', 'c(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes,bytes)',
                          a.SAFE, 0, packet['swapOwner']['data'], 0, 0, 0, 0, a.ZERO, a.ZERO, signatures, info)
            a.need('safe_gap_log_data', logs[0]['data'], data)


def check_governance(rpcs, pin, inputs):
    rows = governance_entries(inputs)
    a.need('safe_gap_endpoints', len(rpcs), 2)
    counts = []
    for row in rows:
        tx, entry = row['tx'], row['entry']
        labels, identities = [], []
        for label, rpc in zip(('a', 'b'), rpcs):
            mined = rpc('eth_getTransactionByHash', [entry['hash']])
            a.need('safe_gap_found', isinstance(mined, dict), True)
            a.need('safe_gap_hash', mined.get('hash'), entry['hash'])
            for field in ('from', 'to', 'nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value', 'chainId'):
                expected = hex(tx[field]) if type(tx[field]) is int else tx[field]
                a.need('safe_gap_'+field, mined.get(field), expected)
            a.need('safe_gap_input', mined.get('input'), tx['data'])
            a.need('safe_gap_type', mined.get('type'), '0x2')
            a.need('safe_gap_authorizations', 'authorizationList' not in mined or mined['authorizationList'] == [], True)
            number = a.typed(mined.get('blockNumber'), a.QTY, gate='safe_gap_mined')
            a.need('safe_gap_before_pin', a.qty(number) <= a.qty(pin['stateBlock']), True)
            a.typed(mined.get('blockHash'), a.HASH32, gate='safe_gap_block_hash')
            block = rpc('eth_getBlockByNumber', [number, False])
            a.need('safe_gap_block', isinstance(block, dict), True)
            a.need('safe_gap_canonical', block.get('hash'), mined.get('blockHash'))
            a.need('safe_gap_block_number', block.get('number'), number)
            index = a.qty(a.typed(mined.get('transactionIndex'), a.QTY, gate='safe_gap_receipt_identity'))
            transactions = block.get('transactions')
            a.need('safe_gap_block_transactions', isinstance(transactions, list), True)
            a.need('safe_gap_block_transaction', index < len(transactions) and transactions[index] == entry['hash'], True)
            miner = a.typed(block.get('miner'), a.ADDRESS_RX, gate='safe_gap_miner')
            owners = set(a.safe_owners(hex(a.OWNER_SWAP_BLOCK - 1))) | set(row['packet']['expectedReadback']['owners'])
            a.need('safe_gap_miner_alias', miner.lower() not in {a.SAFE, tx['from']} | owners, True)
            receipt = rpc('eth_getTransactionReceipt', [entry['hash']])
            a.need('safe_gap_receipt', isinstance(receipt, dict), True)
            a.need('safe_gap_receipt_identity', [receipt.get(k) for k in ('transactionHash', 'blockNumber', 'blockHash', 'transactionIndex')],
                   [entry['hash'], number, block['hash'], a.typed(mined.get('transactionIndex'), a.QTY, gate='safe_gap_receipt_identity')])
            a.need('safe_gap_status', receipt.get('status'), hex(row['status']))
            a.need('safe_gap_logs_shape', isinstance(receipt.get('logs'), list), True)
            governance_logs(receipt['logs'], row, receipt)
            base_fee = a.qty(a.typed(block.get('baseFeePerGas'), a.QTY, gate='safe_gap_base_fee'))
            gas_used = a.qty(a.typed(receipt.get('gasUsed'), a.QTY, gate='safe_gap_gas_used'))
            gas_price = a.qty(a.typed(receipt.get('effectiveGasPrice'), a.QTY, gate='safe_gap_gas_price'))
            a.need('safe_gap_gas_used_positive', gas_used > 0, True)
            a.need('safe_gap_effective_gas_price', gas_price, min(tx['maxFeePerGas'], base_fee + tx['maxPriorityFeePerGas']))
            identities.append([number, block['hash'], block['miner'], mined['transactionIndex'], base_fee,
                               gas_used, gas_price, transactions])
            diff = rpc('debug_traceTransaction', [entry['hash'], {'tracer': 'prestateTracer', 'tracerConfig': {'diffMode': True}}])
            if diff is None or (isinstance(diff, dict) and '__error' in diff):
                continue
            governance_trace(diff, row, block['miner'], receipt, base_fee)
            labels.append(label)
        a.need('safe_gap_dual_identity', identities[0], identities[1])
        row['block'] = a.qty(identities[0][0])
        a.need('safe_gap_trace_available', len(labels) > 0, True)
        counts.append(dict(hash=entry['hash'], traceEndpoints=len(labels), traceEndpointLabels=labels))
    swaps = [r for r in rows if r['tx']['step'] == 'execTransaction']
    a.need('safe_gap_swap_required', len(swaps), 1)
    # The hand-written owner-set boundary must be the block that actually executed the swap.
    a.need('safe_gap_owner_swap_block', swaps[0]['block'], a.OWNER_SWAP_BLOCK)
    expected = swaps[0]['packet']['expectedReadback']
    a.need('safe_gap_pin_owners', pin['safe']['owners'], sorted(a.safe_owners(pin['stateBlock'], expected['owners'])))
    a.need('safe_gap_pin_threshold', pin['safe']['threshold'], expected['threshold'])
    a.need('safe_gap_pin_nonce', pin['safeNonce'], expected['nonce'])
    for rpc in rpcs:
        a.need('safe_gap_pin_owners', sorted(u.addr_array(a.call(rpc, a.SAFE, 'getOwners()', block=pin['stateBlock']))), sorted(expected['owners']))
        a.need('safe_gap_pin_threshold', a.word(rpc, a.SAFE, 'getThreshold()', block=pin['stateBlock']), expected['threshold'])
        a.need('safe_gap_pin_nonce', a.word(rpc, a.SAFE, 'nonce()', block=pin['stateBlock']), expected['nonce'])
        for who in expected['owners']:
            a.need('safe_gap_owner_eoa', rpc('eth_getCode', [who, pin['stateBlock']]), '0x')
            a.need('safe_gap_owner_eoa', pin['safe']['codes'].get(who), '0x')
    return counts


def governance_evidence(pin, inputs, rpcs=None):
    if not inputs['data'].get('safeGovernanceGaps'):
        a.need('safe_gap_evidence_undeclared', 'safeGovernanceGaps' in pin, False)
        return
    if rpcs is not None:
        a.need('safe_gap_endpoints', len(rpcs), 2)
        evidence = dict(partOfA3aPlan=False, reads={'a': [], 'b': []})
        def recording(label, rpc):
            def read(method, params):
                for recorded in evidence['reads'][label]:
                    if (recorded['method'], recorded['params']) == (method, params):
                        return recorded['result']
                try:
                    result = rpc(method, params)
                except a.Gate as error:
                    if method != 'debug_traceTransaction' or error.record['gate'] not in ('rpc_fault', 'rpc_transport'):
                        raise
                    result = {'__error': error.record['gate']}
                evidence['reads'][label].append(dict(method=method, params=params, result=result))
                return result
            return read
        evidence['transactions'] = check_governance([recording(k, r) for k, r in zip(('a', 'b'), rpcs)], pin, inputs)
        pin['safeGovernanceGaps'] = evidence
    required(pin, ('safeGovernanceGaps',), 'safe_gap_evidence')
    evidence = pin['safeGovernanceGaps']
    a.need('safe_gap_not_a3a', evidence['partOfA3aPlan'], False)
    a.exact_keys('safe_gap_evidence_endpoints', evidence['reads'], ('a', 'b'))
    # Offline replay proves internal consistency, not endpoint provenance. Provenance
    # relies on live collection on both endpoints, main() pin_recheck, and plan sha256.
    remaining = {}
    def key(method, params):
        return json.dumps([method, params], sort_keys=True)
    for label, reads in evidence['reads'].items():
        keys = [key(r['method'], r['params']) for r in reads]
        a.need('safe_gap_proof_duplicate', len(keys), len(set(keys)))
        remaining[label] = set(keys)
    def replay(label):
        def read(method, params):
            matches = [r['result'] for r in evidence['reads'][label] if r['method'] == method and r['params'] == params]
            a.need('safe_gap_proof_read', bool(matches), True)
            remaining[label].discard(key(method, params))
            return matches[0]
        return read
    a.need('safe_gap_trace_counts', check_governance([replay('a'), replay('b')], pin, inputs), evidence['transactions'])
    a.need('safe_gap_proof_unused', all(not keys for keys in remaining.values()), True)


def nonce_expectations(pin, inputs):
    spec = inputs['data']['a3aPlan']
    plan = reviewed_file(spec['path'], spec['sha256'], 'a3a_plan')
    last = {}
    for label in ('deployer', 'approver', 'executor'):
        rows = [x for x in plan['steps'] if x['tx']['from'] == pin['senders'][label]['address']]
        a.need('a3a_sender_history', bool(rows), True)
        last[label] = max(rows, key=lambda x: a.qty(x['tx']['nonce']))
        a.need('a3a_last_'+label, last[label]['id'],
               {'deployer':'S7', 'approver':'S6a', 'executor':'S6b'}[label])
        start = a.qty(last[label]['tx']['nonce'])+1
        end = pin['senders'][label]['nonce']
        gaps = spec.get('nonceGaps', []) + governance_nonces(inputs)
        a.need('prepin_gap_sender', all(g['from'] in (a.APPROVER, a.EXECUTOR) for g in gaps), True)
        supplied = [a.qty(g['nonce']) for g in gaps if g['from'] == pin['senders'][label]['address']]
        a.need('prepin_nonce_'+label, sorted(supplied), list(range(start, end)))
        a.need('prepin_nonce_floor_'+label, end >= start, True)
        if label == 'deployer':
            a.need('post_S7_nonce', end, start)
    return last


def history_steps(pin, inputs):
    nonce_expectations(pin, inputs)
    spec = inputs['data']['a3aPlan']
    plan = reviewed_file(spec['path'], spec['sha256'], 'a3a_plan')
    a.validate_plan(plan, frozen=True, historical=True)
    for label in ('deployer', 'approver', 'executor'):
        sender = pin['senders'][label]
        start = plan['pin']['senders'][label]['nonce']
        steps = [a.qty(s['tx']['nonce']) for s in plan['steps'] if s['tx']['from'] == sender['address']]
        gaps = [a.qty(g['nonce']) for source in (plan, spec, {'nonceGaps': governance_nonces(inputs)}) for g in source.get('nonceGaps', []) if g['from'] == sender['address']]
        a.need('a3a_nonce_complete_'+label, sorted(steps+gaps), list(range(start, sender['nonce'])))
    a.need('a3a_all_steps', [s['id'] for s in plan['steps']], list(a.STEP_IDS))
    for gap in plan.get('nonceGaps', []):
        a.need('a3a_gap_sender', gap['from'] in {v['address'] for k,v in pin['senders'].items() if k != 'anni'}, True)
        a.need('a3a_gap_before_pin', a.qty(gap['nonce']) < next(v['nonce'] for v in pin['senders'].values() if v['address'] == gap['from']), True)
    return plan


def history_gaps(rpc, pin, spec, plan):
    for label in ('deployer', 'approver', 'executor'):
        sender = pin['senders'][label]
        tx = {'from': sender['address'], 'nonce': hex(sender['nonce'])}
        a.check_gaps(rpc, plan, tx)
        a.check_gaps(rpc, spec, tx)


def validate_nonce_history(pin, inputs):
    spec = inputs['data']['a3aPlan']
    plan = history_steps(pin, inputs)
    required(pin, ('a3aHistory', 'a3aGapReads'), 'a3a_history_required')
    a.exact_keys('a3a_history', pin['a3aHistory'], a.STEP_IDS)
    for step in plan['steps']:
        proof = pin['a3aHistory'][step['id']]
        receipt, mined = proof['receipt'], proof['transaction']
        txhash = spec['receipts'][step['id']]
        a.need('a3a_mined_'+step['id'], isinstance(receipt, dict), True)
        a.need('a3a_receipt_hash', receipt['transactionHash'], txhash)
        a.need('a3a_transaction_hash', mined['hash'], txhash)
        a.need('a3a_status_'+step['id'], a.qty(receipt['status']), 1)
        a.need('a3a_before_pin', a.qty(receipt['blockNumber']) <= a.qty(pin['stateBlock']), True)
        a.need('a3a_block', mined['blockNumber'], receipt['blockNumber'])
        a.need('a3a_block_hash', mined['blockHash'], receipt['blockHash'])
        a.mined_identity(mined, step['tx'], step['id'])
    def replay(method, params):
        matches = [r['result'] for r in pin['a3aGapReads'] if r['method'] == method and r['params'] == params]
        a.need('gap_proof_read', bool(matches), True)
        result = matches[0]
        if method == 'eth_getTransactionByHash' and result is not None:
            a.need('a3a_gap_mined_before_pin', a.qty(result['blockNumber']) <= a.qty(pin['stateBlock']), True)
        return result
    history_gaps(replay, pin, spec, plan)
    governance_evidence(pin, inputs)


def reconcile_nonces(rpc, pin, inputs, governance_rpcs=None):
    spec = inputs['data']['a3aPlan']
    plan = history_steps(pin, inputs)
    pin['a3aHistory'] = {}
    for step in plan['steps']:
        txhash = spec['receipts'][step['id']]
        receipt = rpc('eth_getTransactionReceipt', [txhash])
        a.need('a3a_mined_'+step['id'], isinstance(receipt, dict), True)
        block = rpc('eth_getBlockByNumber', [receipt['blockNumber'], False])
        a.need('a3a_canonical_receipt', receipt['blockHash'], block['hash'])
        pin['a3aHistory'][step['id']] = dict(receipt=receipt,
            transaction=rpc('eth_getTransactionByHash', [txhash]))
    pin['a3aGapReads'] = []
    def recording(method, params):
        result = rpc(method, params)
        if method == 'eth_getTransactionByHash' and result is not None:
            a.need('a3a_gap_mined_before_pin', a.qty(result['blockNumber']) <= a.qty(pin['stateBlock']), True)
        pin['a3aGapReads'].append(dict(method=method, params=params, result=result))
        return result
    history_gaps(recording, pin, spec, plan)
    governance_evidence(pin, inputs, governance_rpcs)
    validate_nonce_history(pin, inputs)


def collect(rpc, block, inputs, stage="full", governance_rpcs=None):
    validate_external(inputs['data'], stage)
    pin = u.collect(rpc, block)
    d = inputs['data']
    pin['isolationControlCases'] = copy.deepcopy(d.get('isolationControlCases',{}))
    block = pin['stateBlock']
    who = d['anni']
    n = a.nonce(rpc, who, block)
    a.need('anni_pending_nonce', a.nonce(rpc, who, 'pending'), n)
    a.need('anni_eoa', u.code(rpc, who, block), '0x')
    pin['senders']['anni'] = dict(address=who, nonce=n, balance=a.qty(rpc('eth_getBalance', [who, block])))
    a.need('registry_version', a.call(rpc, u.REG, 'version()', block=block), a.cast('abi-encode', 'c(string)', 'Registry-5.8.0'))
    pin['registryImplementation'] = u.addr_word(int(rpc('eth_getStorageAt', [u.REG, u.IMPL_SLOT, block]), 16))
    pin['registryImplementationCode'] = u.code(rpc, pin['registryImplementation'], block)
    reconcile_nonces(rpc, pin, inputs, governance_rpcs)
    pin['oldAggregator'] = a.address(rpc, u.REG, 'blsAggregator()', block)
    a.need('fixed_old_aggregator', pin['oldAggregator'], OLD_AGGREGATOR)
    maximum = a.word(rpc, pin['oldAggregator'], 'MAX_VALIDATORS()', block=block)
    a.need('guardian_maximum', maximum, 13)
    pin['guardianInventory'] = [dict(slot=slot, validator=u.addr_word(a.word(rpc, pin['oldAggregator'], 'validatorAtSlot(uint8)', slot, block=block))) for slot in range(1, maximum+1)]
    pin['oldActivity'], reads = record_old_activity(rpc, pin['oldAggregator'], block, d.get('pop'))
    pin['oldActivityReads'] = dict(primary=reads)
    a.need('old_aggregator_owner', a.address(rpc, pin['oldAggregator'], 'owner()', block), u.DEPLOYER)
    a.need('old_aggregator_slash_policy_admin', a.address(rpc, pin['oldAggregator'], 'slashPolicyAdmin()', block), u.DEPLOYER)
    pin['oldActivity']['dvtProposals'] = dvt_activity(rpc, d['dvt'], block)
    pin['bindings'] = old_pointers(rpc, d, pin['oldAggregator'], block)
    pin.update(balances(rpc, pin['pauseList'], block))
    drain_gate(pin)
    ep = pin['immutables']['entryPoint']
    deposit = u.uints(a.call(rpc, ep, 'getDepositInfo(address)', u.SP, block=block))
    a.need('deposit_info_shape', len(deposit), 5)
    pin['entryPointDeposit'], _, pin['stake'], pin['stakeDelay'], pin['withdrawTime'] = deposit
    a.need('stake_not_unlocking', pin['withdrawTime'], 0)
    # Isolation records discovery calls, bounded role-event history and canonical blocks
    # so build_plan can replay every new inventory gate on both endpoint transcripts.
    pin['oldOwnerIsolation'] = isolation.collect_deployed(rpc, pin, inputs['data'].get('deployedSources'), fork=isolation.local_control_fork(), pending=inputs['data'].get('pendingDsrRuling'))
    pin['oldTimelock'] = old_timelock_holds_nothing(rpc, pin, block)
    if stage in PC_STAGES:
        pin['phaseC'] = collect_phase_c(rpc, block, inputs, pin)
    return pin


def collect_pair(primary, secondary, block, inputs, stage='full'):
    pin = collect(primary, block, inputs, stage, (primary, secondary))
    independent = collect(secondary, block, inputs, stage, (primary, secondary))
    a.need('independent_pin', independent, pin)
    pin['oldActivityReads']['secondary'] = copy.deepcopy(independent['oldActivityReads']['primary'])
    pin['oldOwnerIsolation']['endpointResults'] = dict(
        primary=copy.deepcopy(pin['oldOwnerIsolation']['reads']),
        secondary=copy.deepcopy(independent['oldOwnerIsolation']['reads']))
    if 'sourceSelection' in pin['oldOwnerIsolation']:
        pin['oldOwnerIsolation']['endpointIdentities'] = {label:isolation.endpoint_identity(rpc,label) for label,rpc in (('primary',primary),('secondary',secondary))}
        isolation.assert_endpoint_identities(pin['oldOwnerIsolation']['endpointIdentities'])
    return pin


def predicate(target, sig, args, value, index=None):
    p = dict(kind='call', target=target, signature=sig, args=list(args), expected=value)
    if index is not None:
        p['index'] = index
    return p


def word_pred(target, sig, value, *args, index=None):
    return predicate(target, sig, args, value, index)


def address_pred(target, sig, value, *args):
    return word_pred(target, sig, int(value, 16), *args)


def runtime_bytes(art, values):
    identity = art['runtimeIdentity']
    raw = bytearray.fromhex(identity['artifactRuntime'][2:])
    for entry in identity['ranges']:
        a.need('immutable_supplied_'+entry['name'], entry['name'] in values, True)
        raw[entry['start']:entry['start']+entry['length']] = int(values[entry['name']]).to_bytes(32, 'big')
    return '0x'+raw.hex()


def token_immutables(target, protocol):
    empty, _ = a.short_string('')
    one, _ = a.short_string('1')
    hname, hver = a.keccak('0x'), a.keccak('1')
    domain = a.keccak(a.cast('abi-encode', 'c(bytes32,bytes32,bytes32,uint256,address)',
        a.keccak('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'), hname, hver, a.CHAIN, target))
    return dict(PROTOCOL_REGISTRY=int(protocol, 16), _cachedThis=int(target, 16), _cachedChainId=a.CHAIN,
        _cachedDomainSeparator=int(domain, 16), _hashedName=int(hname, 16), _hashedVersion=int(hver, 16),
        _name=int.from_bytes(empty, 'big'), _version=int.from_bytes(one, 'big'))


def safe_hash(inner, n, target=u.TL):
    domain = a.keccak(a.cast('abi-encode', 'c(bytes32,uint256,address)',
                      a.keccak('EIP712Domain(uint256 chainId,address verifyingContract)'), a.CHAIN, u.SAFE))
    typehash = a.keccak('SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)')
    h = a.keccak(a.cast('abi-encode', 'c(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)',
                        typehash, target, 0, a.keccak(inner), 0, 0, 0, 0, a.ZERO, a.ZERO, n))
    return a.keccak('0x1901'+domain[2:]+h[2:])


def safe_payload(inner, target=u.TL):
    # Approved-hash signatures: each r is an owner, s=0, v=1. Safe requires ascending owners.
    signatures = '0x'+''.join(who[2:].zfill(64)+'0'*64+'01' for who in sorted((a.APPROVER, a.EXECUTOR)))
    return a.calldata('execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)',
                      target, 0, inner, 0, 0, 0, 0, a.ZERO, a.ZERO, signatures)



def domain_separator(aggregator):
    return a.keccak(a.cast('abi-encode', 'c(bytes32,uint256,address,address)',
        a.keccak('SuperPaymaster.BLSConsensus.v1'), a.CHAIN, aggregator, u.REG))


def prefix_payload(plan):
    steps = copy.deepcopy(plan['steps'])
    for step in steps:
        for key in (u.MEASURED_KEYS - {'executionTimestamp'}) | {'skipped', 'gasEvidence', 'variantMeasurements'}:
            step.pop(key, None)
        step['tx'].pop('gas', None)
        for tx in step.get('variants', {}).values():
            tx.pop('gas', None)
    # Phase C pin reads never affect the A/B prefix; a7/b4 sources are collected without them.
    pin = {k: v for k, v in plan['pin'].items() if k != 'phaseC'}
    return dict(pin=pin, addresses=plan['addresses'], steps=steps,
                activationScheduleNotBefore=plan['activationScheduleNotBefore'])


def bind_timing(plan):
    """Derive the same mined-block clock used by wait_until and replay."""
    now = plan['pin']['stateTimestamp']
    etas, gas_eta, verifier_eta = {}, 0, 0
    for step in plan['steps']:
        sid = step['id']
        target = now
        if sid == 'activation_schedule_approve':
            target = max(target, gas_eta, plan['activationScheduleNotBefore'])
        if sid.endswith('execute_exec'):
            target = max(target, etas[step['operation']])
        if sid == 'B4':
            target = max(target, verifier_eta)
        step['warpTarget'] = target
        now = target + 1
        step['executionTimestamp'] = now
        if sid.endswith('schedule_exec'):
            etas[step['operation']] = now + u.DELAY
        if sid == 'upgrade_execute_exec':
            gas_eta = now + u.DELAY
        if sid == 'A12b':
            verifier_eta = now + 4*DAY


def source_plan_bytes(plan):
    return (json.dumps(plan, sort_keys=True, separators=(',', ':'))+'\n').encode()


def stage_source(plan, rpc):
    # Keep measured gas in stage-<name>.json; source plans are independently
    # reproducible offline, while their prefix binds the executed fork timing.
    rebuilt = build_plan(plan['pin'], plan['externalInputs'], plan['stage'], plan['stageSources'])
    verify_prefix(rebuilt, plan, plan['stage'])
    return dict(plan=rebuilt, readback=stage_readback(plan, rpc))


def prefix_digest(plan):
    return hashlib.sha256(json.dumps(prefix_payload(plan), sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def verify_prefix(plan, prior, stage):
    a.need('prefix_stage', prior['stage'], stage)
    a.need('prefix_digest', prior['prefixDigest'], prefix_digest(prior))
    expected = prefix_payload(plan)
    expected['steps'] = expected['steps'][:len(prior['steps'])]
    expected['addresses'] = {k: expected['addresses'].get(k) for k in prior['addresses']}
    if stage == 'c':
        # Stage c ends with the complete Phase C expansion.
        a.need('prefix_boundary', [s['id'] for s in prior['steps'] if s.get('phase') == 'C'][-1:],
               [s['id'] for s in plan['steps'] if s.get('phase') == 'C'][-1:])
        a.need('prefix_boundary_last', prior['steps'][-1].get('phase'), 'C')
    else:
        a.need('prefix_boundary', prior['steps'][-1]['id'], 'A7' if stage == 'a7' else 'B4')
    a.need('prefix_exact', prefix_payload(prior), expected)


def stage_readback(plan, rpc):
    a.need('stage_local', getattr(rpc, 'local', False), True)
    domain = a.call(rpc, plan['addresses']['BLSAggregator'], 'domainSeparator()')
    a.need('stage_domain', domain, plan['expectedDomainSeparator'])
    return dict(prefixDigest=plan['prefixDigest'], domainSeparator=domain)


def stage_pin(pin, stage):
    """Require Phase C evidence before the builder reads it; strip it for earlier stages."""
    if stage in PC_STAGES:
        a.need('stage_pin_phase_c', 'phaseC' in pin, True)
        return pin
    return {k: v for k, v in pin.items() if k != 'phaseC'}


def build_plan(pin, inputs=None, stage='full', stage_sources=None):
    a.need('manifest_inputs_required', inputs is not None, True)
    required(inputs, ('sha256', 'data'), 'external_binding')
    a.typed('0x'+inputs['sha256'], a.HASH32)
    a.need('external_digest_nonzero', int(inputs['sha256'], 16) != 0, True)
    d = inputs['data']
    validate_external(d, stage)
    # Phase C pin reads belong only to the stages that build Phase C; a7/b4 prefixes are
    # byte-identical whether or not the supplied pin carries them.
    pin = stage_pin(pin, stage)
    sources = copy.deepcopy(stage_sources or {})
    a.need("stage_sources", set(sources), set() if stage == "a7" else ({"a7"} if stage == "b4" else ({"a7", "b4"} if sources else set())))
    salt_digest = sources["b4"]["plan"]["externalInputs"]["sha256"] if "b4" in sources else inputs["sha256"]
    a.exact_keys('bindings', pin['bindings'], (DVT, COMMITTEE))
    for code in pin['bindings'].values():
        a.typed(code, a.HEXDATA)
        a.need('binding_nonempty', code != '0x', True)
    a.need('fixed_old_aggregator', pin['oldAggregator'], OLD_AGGREGATOR)
    validate_nonce_history(pin, inputs)
    validate_old_activity(pin, d.get('pop'))
    required(d, ('verifier', 'anni', 'dvt', 'committee', 'sampled', 'depositTargetWei'), 'manifest_external_complete')
    base_pin = {key: copy.deepcopy(pin[key]) for key in u.PIN_KEYS}
    base_pin['senders'].pop('anni', None)
    u.validate_pin(base_pin)
    a.need('pin_pending_token_eta', pin['pendingAPNTsTokenEta'], PENDING_TOKEN_ETA)
    drain_gate(pin)
    a.need('sampled_inventory', set(d['sampled']) <= set(pin['pauseList']), True)
    a.need('drain_inventory', set(pin['operatorBalances']), set(pin['pauseList']))
    a.need('anni_binding', pin['senders']['anni']['address'], d['anni'])
    a.need('sender_labels', set(pin['senders']), {'deployer', 'anni', 'approver', 'executor'})
    a.need('sender_unique', len({x['address'] for x in pin['senders'].values()}), 4)
    for label, sender in pin['senders'].items():
        a.exact_keys('sender_fields_'+label, sender, ('address', 'nonce', 'balance'))
        a.pin_integer(sender['nonce'], 'nonce_'+label)
        a.pin_integer(sender['balance'], 'balance_'+label)
    for field in ('stake', 'stakeDelay', 'entryPointDeposit', 'withdrawTime'):
        a.pin_integer(pin[field], field)
    a.need('stake_not_unlocking', pin['withdrawTime'], 0)
    for label, who in a.SENDERS.items():
        a.need('sender_'+label, pin['senders'][label]['address'], who)
    arts = copy.deepcopy(rebuild())
    a.need('old_owner_control_cases_binding',pin.get('isolationControlCases',{}),d.get('isolationControlCases',{}))
    isolation.validate_deployed(pin.get('oldOwnerIsolation'), pin, d.get('deployedSources'), pending=d.get('pendingDsrRuling'))
    validate_old_timelock(pin)
    release_gate(inputs, arts, pin)
    counters = {label: x['nonce'] for label, x in pin['senders'].items()}
    sender_of = {label: x['address'] for label, x in pin['senders'].items()}
    if stage in PC_STAGES:
        counters['owner'] = pin['phaseC']['owner']['nonce']
        sender_of['owner'] = pin['phaseC']['owner']['address']
    phase_c = {}
    steps, addresses, runtimes = [], {}, {}
    safe_n = pin['safeNonce']
    operations = {}
    def finish():
        plan = dict(schema='3.1', route='manifest-A-B-D', stage=stage, final=stage == 'full', stageSources=sources,
            pin=copy.deepcopy(pin), externalInputs=copy.deepcopy(inputs), rebuild=arts,
            creationMetadataLayouts={'OverIssueFraudProofVerifier': copy.deepcopy(VERIFIER_METADATA_LAYOUT)},
            addresses=addresses, implementation=impl, extension=extension, operations=operations,
            steps=steps, controls=CONTROLS+(PC_CONTROLS if stage in PC_STAGES else []),
            expectedDomainSeparator=domain_separator(agg),
            b4Disclosure='B4 always consumes its reserved deployer nonce. If already applied, one empty, zero-value self-transfer costs gas only.',
            gasPolicy=copy.deepcopy(u.GAS_POLICY), gasParams=list(u.GAS),
            activationScheduleNotBefore=max(0, pin['pendingAPNTsTokenEta']-u.DELAY))
        isolation.assert_manifest_calldata(steps, arts['calldataSignatures'])
        if stage in PC_STAGES:
            plan['phaseC'] = phase_c
        plan['expectedDiscoveryAfter'] = build_expected_discovery(plan)
        bind_timing(plan)
        plan['prefixDigest'] = prefix_digest(plan)
        prefix_pin = {k: v for k, v in pin.items() if k != 'phaseC'}
        for name, source in sources.items():
            rebuilt = build_plan(prefix_pin, source['plan']['externalInputs'], name,
                                 {'a7': sources['a7']} if name == 'b4' else None)
            a.need('source_plan_bytes', source_plan_bytes(source['plan']) == source_plan_bytes(rebuilt), True)
            verify_prefix(plan, source['plan'], name)
            a.need('source_readback_prefix', source['readback']['prefixDigest'], source['plan']['prefixDigest'])
            a.need('source_domain', source['readback']['domainSeparator'], plan['expectedDomainSeparator'])
        return plan
    def add(sid, target, data, checks, sender='deployer', value=0, **extra):
        a.need('readback_required', bool(checks), True)
        tx = dict(to=target, data=data, value=hex(value), nonce=hex(counters[sender]),
            chainId=hex(a.CHAIN), maxFeePerGas=hex(a.MAX_FEE), maxPriorityFeePerGas=hex(a.PRIORITY),
            **{'from': sender_of[sender]})
        counters[sender] += 1
        steps.append(dict(id=sid, sender=sender, tx=tx, readbacks=checks, safeNonce=safe_n, **extra))
        return steps[-1]
    def deploy(sid, name, signature='c()', args=(), values=None):
        target = a.create_address(u.DEPLOYER, counters['deployer'])
        addresses[name] = target
        art = verifier_artifact(d['verifier']) if name == 'OverIssueFraudProofVerifier' else arts['contracts'][name]
        vals = values(target) if callable(values) else (values or {})
        rt = runtime_bytes(art, vals)
        a.need('nonempty_runtime_'+name, rt != '0x', True)
        runtimes[target] = rt
        add(sid, None, art['bytecode']+a.cast('abi-encode', signature, *args)[2:],
            [dict(kind='code', target=target, expected=rt)], creates=target, constructor=dict(signature=signature,bytecode=art['bytecode']))
        if name == 'OverIssueFraudProofVerifier':
            alternate = runtime_bytes(art, {'AGGREGATOR': vals['REGISTRY'], 'REGISTRY': vals['AGGREGATOR']})
            steps[-1]['readbacks'][0] = dict(kind='verifierCode', target=target, expected=[rt, alternate])
        if name in ('AOAProtocolRegistry', 'xPNTsFactoryV2', 'BLSAggregator'):
            steps[-1]['readbacks'].append(address_pred(target, 'owner()', u.DEPLOYER))
        return target
    def call(sid, target, sig, args, checks, **kw):
        return add(sid, target, a.calldata(sig, *args), checks, **kw)
    imm = {k: int(v, 16) for k, v in pin['immutables'].items()}
    impl = deploy('A1', 'SuperPaymaster', 'c(address,address,address)', tuple(pin['immutables'][k] for k in
        ('entryPoint', 'REGISTRY', 'ETH_USD_PRICE_FEED')), lambda t: {**imm, '__self': int(t, 16), 'EXTENSION': int(a.create_address(t, 1), 16)})
    extension = a.create_address(impl, 1)
    rt = runtime_bytes(arts['contracts']['SuperPaymasterAdmin'], {**imm, '__self': int(extension, 16)})
    steps[-1]['readbacks'].append(dict(kind='code', target=extension, expected=rt))
    tier = deploy('A2', 'GlobalTierSource', 'c(address)', (u.REG,), {'REGISTRY': int(u.REG, 16)})
    protocol = deploy('A3.create', 'AOAProtocolRegistry', 'c(address)', (u.DEPLOYER,))
    for suffix, kind, key in (('sp', 0, '0x'+u.SP[2:].zfill(64)), ('tier', 2, a.keccak(runtimes[tier]))):
        call('A3.'+suffix, protocol, 'bootstrapApprove(uint8,bytes32)', (kind, key),
            [word_pred(protocol, 'approved(uint8,bytes32)', 1, kind, key)])
    call('A3.seal', protocol, 'seal()', (), [word_pred(protocol, 'sealed_()', 1)])
    ext = deploy('A4.ext', 'xPNTsTokenV2Ext', 'c(address)', (protocol,), lambda t: token_immutables(t, protocol))
    token = deploy('A4.token', 'xPNTsTokenV2', 'c(address,address)', (protocol, ext),
        lambda t: {**token_immutables(t, protocol), 'EXTENSION': int(ext, 16)})
    factory = deploy('A4.factory', 'xPNTsFactoryV2', 'c(address,address,address,address)', (u.SP, u.REG, token, tier),
        dict(REGISTRY=int(u.REG, 16), implementation=int(token, 16), implementationCodehash=int(a.keccak(runtimes[token]), 16),
             extensionCodehash=int(a.keccak(runtimes[ext]), 16)))
    steps[-1]['readbacks'] += [address_pred(factory, 'SUPERPAYMASTER()', u.SP),
        address_pred(factory, 'defaultTierSource()', tier)]
    deploy('A5', 'SuperPaymasterLens')
    reg = deploy('A6.create', 'Registry', values=lambda t: {'__self': int(t, 16)})
    call('A6.upgrade', u.REG, 'upgradeToAndCall(address,bytes)', (reg, '0x'),
        [dict(kind='storage', target=u.REG, slot=u.IMPL_SLOT, expected=int(reg, 16)),
         predicate(u.REG, 'version()', (), a.cast('abi-encode', 'c(string)', 'Registry-5.9.0'))])
    agg = deploy('A7', 'BLSAggregator', 'c(address,address,address)', (u.REG, u.SP, d['dvt']), {'REGISTRY': int(u.REG, 16)})
    steps[-1]['readbacks'] += [word_pred(agg, 'minThreshold()', 3), word_pred(agg, 'defaultThreshold()', 7),
        address_pred(agg, 'SUPERPAYMASTER()', u.SP), address_pred(agg, 'DVT_VALIDATOR()', d['dvt']),
        *[word_pred(agg, 'slashThresholds(uint8)', threshold, severity) for severity, threshold in enumerate((2, 3, 3))]]
    steps[-1]['readbacks'].append(predicate(agg, 'version()', (), a.cast('abi-encode', 'c(string)', AGG_VERSION)))
    steps[-1]['readbacks'].append(predicate(agg, 'domainSeparator()', (), domain_separator(agg)))
    if stage == 'a7':
        return finish()
    for suffix, target, setter, getter in (('registry', u.REG, 'setBLSAggregator', 'blsAggregator'),
        ('dvt', d['dvt'], 'setBLSAggregator', 'BLS_AGGREGATOR'), ('committee', d['committee'], 'setBlsAggregator', 'blsAggregator')):
        call('A8.'+suffix, target, setter+'(address)', (agg,), [address_pred(target, getter+'()', agg)])
    for suffix, who, active in (('new', agg, True), ('old', pin['oldAggregator'], False)):
        call('A9.'+suffix, u.REG, 'setReputationSource(address,bool)', (who, str(active).lower()),
            [word_pred(u.REG, 'isReputationSource(address)', int(active), who)])
    inventory = pin['guardianInventory']
    a.need('guardian_slots', [x['slot'] for x in inventory], list(range(1, 14)))
    a.need('guardian_inventory', {(x['validator'], x['slot']) for x in inventory if x['validator'] != a.ZERO}, {(x['validator'], x['slot']) for x in d['pop']})
    a.need('pop_count', len(d['pop']), 3)
    for i, pop in enumerate(d['pop']):
        a.need('pop_domain', pop['domainSeparator'], domain_separator(agg))
        a.need('pop_aggregator', pop['aggregator'], agg)
        a.need('pop_pin', pop['pinBlockHash'], pin['blockHash'])
        words = u.uints('0x'+pop['calldata'][10:])
        add('A10.'+str(i), agg, pop['calldata'],
            [word_pred(agg, 'validatorAtSlot(uint8)', int(pop['validator'], 16), pop['slot']),
             predicate(agg, 'getBLSPublicKey(address)', (pop['validator'],), words[1:5]+[pop['slot'], 1])])
    for suffix, setter, getter in (('min', 'setMinThreshold', 'minThreshold'), ('default', 'setDefaultThreshold', 'defaultThreshold')):
        call('A11.'+suffix, agg, setter+'(uint256)', (2,), [word_pred(agg, getter+'()', 2)])
    verifier = deploy('A12a', 'OverIssueFraudProofVerifier', 'c(address,address)', (agg, u.REG),
        {'AGGREGATOR': int(agg, 16), 'REGISTRY': int(u.REG, 16)})
    steps[-1]['readbacks'] += [address_pred(verifier, 'AGGREGATOR()', agg), address_pred(verifier, 'REGISTRY()', u.REG), address_pred(agg, 'REGISTRY()', u.REG)]
    if stage == 'full':
        fixture = fraud_fixture(d['fraudProofFixture'], pin, agg, verifier, arts['contracts']['BLSAggregator']['storageLayout'])
        a.need('fixture_domain', fixture['domainSeparator'], domain_separator(agg))
    call('A12b', agg, 'proposeFraudProofVerifier(address)', (verifier,),
        [address_pred(agg, 'pendingFraudProofVerifier()', verifier),
         dict(kind='eta', target=agg, signature='pendingFraudProofVerifierReadyAt()', delay=4*DAY)])
    ep = pin['immutables']['entryPoint']
    stake = max(0, 10**18-pin['stake'])
    call('A13.stake', u.SP, 'addStake(uint32)', (max(DAY, pin['stakeDelay']),),
        [word_pred(ep, 'getDepositInfo(address)', pin['stake']+stake, u.SP, index=2),
         word_pred(ep, 'getDepositInfo(address)', max(DAY, pin['stakeDelay']), u.SP, index=3)], value=stake)
    deposit = max(0, d['depositTargetWei']-pin['entryPointDeposit'])
    call('A13.deposit', ep, 'depositTo(address)', (u.SP,),
        [word_pred(ep, 'balanceOf(address)', pin['entryPointDeposit']+deposit, u.SP)], value=deposit)
    for i, who in enumerate(pin['pauseList']):
        call('A14.'+str(i), u.SP, 'setOperatorPaused(address,bool)', (who, 'true'),
            [word_pred(u.SP, 'operators(address)', 1, who, index=2)])
    remaining = pin['totalTrackedBalance']
    for label in ('deployer', 'anni'):
        who = pin['senders'][label]['address']
        amount = pin['operatorBalances'].get(who, 0)
        a.need('drain_operator_present_'+label, who in pin['operatorBalances'], True)
        remaining -= amount
        call('A15.'+label, u.SP, 'withdraw(uint256)', (amount,),
            [word_pred(u.SP, 'operators(address)', 0, who, index=0), word_pred(u.SP, 'totalTrackedBalance()', remaining)], sender=label)
    call('A15.revenue', u.SP, 'withdrawProtocolRevenue(address,uint256)', (u.DEPLOYER, pin['protocolRevenue']-BUFFER),
        [word_pred(u.SP, 'protocolRevenue()', BUFFER), word_pred(u.SP, 'totalTrackedBalance()', BUFFER)])
    add('A16', u.REG, u.freeze_calldata(pin['roleConfig']),
        [predicate(u.REG, 'getRoleConfig(bytes32)', (u.role(),), u.frozen_config(pin['roleConfig']))])
    call('A17', u.SP, 'transferOwnership(address)', (u.TL,), [address_pred(u.SP, 'owner()', u.TL)])
    upgrade_data = [a.calldata('upgradeToAndCall(address,bytes)', impl, a.calldata('setGlobalPaused(bool)', 'true')),
        a.calldata('queueGasParams(uint32,uint32,uint32,uint32)', *u.GAS),
        a.calldata('setXPNTsFactory(address)', factory), a.calldata('queueBLSAggregator(address)', agg)]
    activation_data = [a.calldata(x+'()') for x in ('executeGasParams', 'applyBLSAggregator', 'executeAPNTsTokenChange')]
    activation_data += [a.calldata('setOperatorPaused(address,bool)', who, 'false') for who in d['sampled']]
    activation_data += [a.calldata('setGlobalPaused(bool)', 'false')]
    operations = {}
    predecessor = a.ZERO32
    for name, data in (('upgrade', upgrade_data), ('activation', activation_data)):
        if name == 'activation':
            inner = a.calldata('mint(address,uint256)', u.SP, BUFFER)
            target = pin['capped']
            h = safe_hash(inner, safe_n, target)
            add('B2a_approve', u.SAFE, a.calldata('approveHash(bytes32)', h),
                [word_pred(u.SAFE, 'approvedHashes(address,bytes32)', 1, a.APPROVER, h)],
                sender='approver', safeHash=h, inner=inner, safeTarget=target)
            add('B2a_exec', u.SAFE, safe_payload(inner, target),
                [word_pred(target, 'balanceOf(address)', BUFFER, u.SP)],
                sender='executor', safeHash=h, inner=inner, safeTarget=target)
            safe_n += 1
        op = dict(batch=True, targets=[u.SP]*len(data), data=data, predecessor=predecessor,
                  salt=a.keccak('manifest-v3/'+pin['blockHash']+'/'+salt_digest+'/'+name))
        op['id'] = u.operation_hash(op['targets'], data, predecessor, op['salt'], True)
        operations[name] = op
        predecessor = op['id']
        for verb in ('schedule', 'execute'):
            inner = u.op_call(op, verb)
            h = safe_hash(inner, safe_n)
            sid = name+'_'+verb
            add(sid+'_approve', u.SAFE, a.calldata('approveHash(bytes32)', h),
                [word_pred(u.SAFE, 'approvedHashes(address,bytes32)', 1, a.APPROVER, h)],
                sender='approver', safeHash=h, inner=inner, operation=name)
            checks = [word_pred(u.TL, 'getOperationState(bytes32)', 1 if verb == 'schedule' else 3, op['id'])]
            if verb == 'schedule':
                checks += [dict(kind='eta', target=u.TL, signature='getTimestamp(bytes32)', args=[op['id']], delay=u.DELAY)]
            else:
                checks += [dict(kind=name)]
            add(sid+'_exec', u.SAFE, safe_payload(inner), checks, sender='executor', safeHash=h, inner=inner, operation=name)
            safe_n += 1
    b4 = call('B4', agg, 'applyFraudProofVerifier()', (), [
        address_pred(agg, 'fraudProofVerifier()', verifier),
        address_pred(agg, 'pendingFraudProofVerifier()', a.ZERO),
        word_pred(agg, 'pendingFraudProofVerifierReadyAt()', 0)])
    b4['variants'] = dict(apply=copy.deepcopy(b4['tx']),
        placeholder=dict(b4['tx'], to=u.DEPLOYER, value='0x0', data='0x'))
    if stage == 'b4':
        return finish()
    # Phase C (§3): after 6d and B4, before Phase D, on the same sender/Safe counters.
    c, p = d['phaseC'], pin['phaseC']
    # DSR 2026-11-02: D is the only sampled operator; N stays paused and unfunded. Enforced for every stage by
    # validate_external's sampled_deployer_only (DSR 2026-11-05, F-01).
    ws = phase_c_worksheet(pin, c, pin['entryPointDeposit']+deposit)
    phase_c.update(ws)
    base = rebuild_baselines(arts['commit'])
    a.need('C12_constructor_abi', base['VerifyingPaymaster']['constructor'], VPM_CONSTRUCTOR)
    a.need('C14_constructor_abi', base['TokenPaymaster']['constructor'], TPM_CONSTRUCTOR)
    for name in ('F1TestToken', 'F1Oracle', 'VerifyingPaymaster', 'TokenPaymaster'):
        a.need('C_baseline_commit_'+name, base[name]['commit'], arts['commit'])
    phase_c['artifacts'] = {name: {k: v for k, v in base[name].items() if k not in ('bytecode', 'runtimeIdentity')}
                            | dict(creationKeccak=a.keccak(base[name]['bytecode'])) for name in sorted(base)}
    D, S, O, capped = u.DEPLOYER, c['account'], c['accountOwner'], pin['capped']
    X = a.create_address(factory, 1)   # first Clones.clone CREATE of the A4 factory
    staking, gtoken, mysbt = (p['endUser'][k] for k in ('staking', 'gtoken', 'mysbt'))
    words = list(p['sp']['deployerOperator'])
    def c_add(sid, target, data, checks, **kw):
        return add(sid, target, data, checks, phase='C', **kw)
    def c_call(sid, target, sig, args, checks, **kw):
        return c_add(sid, target, a.calldata(sig, *args), checks, **kw)
    def c_deploy(sid, key, art, signature, args, checks):
        target = a.create_address(D, counters['deployer'])
        code = (dict(kind='code', target=target, expected=runtime_bytes(art, {'MINTER': int(D, 16)}))
                if 'runtimeIdentity' in art else dict(kind='codeHash', target=target, expected=c['runtimeKeccak'][key]))
        c_add(sid, None, art['bytecode']+a.cast('abi-encode', signature, *args)[2:], [code]+checks(target), creates=target,
              constructor=dict(signature=signature, bytecode=art['bytecode']))
        return target
    def account_exec(target, inner):
        return a.calldata('execute(address,uint256,bytes)', target, 0, inner)
    phase_c['addresses'] = dict(X=X, S=S, R=DEAD)
    delta_m, delta_a = ws['cappedMint'], ws['operatorTopUp']
    held = p['capped']['deployerBalance']+delta_m
    if delta_m:
        inner = a.calldata('mint(address,uint256)', D, delta_m)
        h = safe_hash(inner, safe_n, capped)
        c_add('C1_approve', u.SAFE, a.calldata('approveHash(bytes32)', h),
            [word_pred(u.SAFE, 'approvedHashes(address,bytes32)', 1, a.APPROVER, h)],
            sender='approver', safeHash=h, inner=inner, safeTarget=capped)
        c_add('C1_exec', u.SAFE, safe_payload(inner, capped),
            [word_pred(capped, 'balanceOf(address)', held, D),
             word_pred(capped, 'totalSupply()', ws['cappedSupplyBefore']+delta_m),
             word_pred(capped, 'cap()', p['capped']['cap']), address_pred(capped, 'minter()', u.SAFE)],
            sender='executor', safeHash=h, inner=inner, safeTarget=capped)
        safe_n += 1
    if delta_a:
        c_call('C2.approve', capped, 'approve(address,uint256)', (u.SP, delta_a),
            [word_pred(capped, 'allowance(address,address)', delta_a, D, u.SP)])
        c_call('C2.deposit', u.SP, 'deposit(uint256)', (delta_a,),
            [word_pred(u.SP, 'operators(address)', ws['operatorTarget'], D, index=OP['aPNTsBalance']),
             word_pred(u.SP, 'totalTrackedBalance()', BUFFER+delta_a), word_pred(u.SP, 'protocolRevenue()', BUFFER),
             word_pred(capped, 'balanceOf(address)', BUFFER+delta_a, u.SP),
             word_pred(capped, 'balanceOf(address)', held-delta_a, D),
             word_pred(capped, 'allowance(address,address)', 0, D, u.SP)])
    before = words[:]
    before[OP['aPNTsBalance']], before[OP['isPaused']] = ws['operatorTarget'], 0
    phase_c['operatorBefore'] = before
    string = lambda value: a.cast('abi-encode', 'c(string)', value)
    c_call('C3.deploy', factory, 'deployxPNTsToken(string,string,string,string,uint256,address)', (*PC_TOKEN, PC_RATE, a.ZERO),
        [address_pred(factory, 'getTokenAddress(address)', X, D), word_pred(factory, 'isXPNTs(address)', 1, X),
         word_pred(factory, 'getDeployedCount()', 1),
         dict(kind='code', target=X, expected='0x363d3d373d3d3d363d73'+addresses['xPNTsTokenV2'][2:]+'5af43d82803e903d91602b57fd5bf3'),
         address_pred(X, 'FACTORY()', factory), address_pred(X, 'communityOwner()', D), address_pred(X, 'community()', D),
         word_pred(X, 'exchangeRate()', PC_RATE), address_pred(X, 'SUPERPAYMASTER_ADDRESS()', u.SP),
         address_pred(X, 'creditTierSource()', tier), word_pred(X, 'creditPolicy()', 0), word_pred(X, 'pendingPolicyEta()', 0),
         word_pred(X, 'maxSingleTxLimit()', PC_XPNTS_TX_LIMIT), word_pred(X, 'BALANCE_MODE_VERSION()', 1),
         predicate(X, 'name()', (), string(PC_TOKEN[0])), predicate(X, 'symbol()', (), string(PC_TOKEN[1])),
         predicate(X, 'communityName()', (), string(PC_TOKEN[2])), predicate(X, 'communityENS()', (), string(PC_TOKEN[3])),
         predicate(u.SP, 'operators(address)', (D,), before)])
    after = before[:]
    after[OP['isConfigured']], after[OP['xPNTsToken']], after[OP['treasury']] = 1, int(X, 16), int(PC_TREASURY, 16)
    phase_c['operatorAfter'] = after
    c_call('C3.configure', u.SP, 'configureOperator(address,address)', (X, PC_TREASURY),
        [predicate(u.SP, 'operators(address)', (D,), after), word_pred(X, 'creditPolicy()', 0),
         word_pred(X, 'pendingPolicyEta()', 0), word_pred(X, 'maxSingleTxLimit()', PC_XPNTS_TX_LIMIT)])
    if not ws['accountExists']:
        c_call('C5', ACCOUNT_FACTORY, 'createAccount(address,uint256)', (O, c['salt']),
            [dict(kind='codeHash', target=S, expected=c['runtimeKeccak']['account']),
             dict(kind='storage', target=S, slot=u.IMPL_SLOT, expected=int(c['accountImplementation'], 16)),
             address_pred(S, 'owner()', O), address_pred(S, 'entryPoint()', ep)])
    ticket = ws['endUserStake']+ws['endUserTicket']
    if not ws['accountMember']:
        c_call('C6', gtoken, 'approve(address,uint256)', (staking, ticket),
            [word_pred(gtoken, 'allowance(address,address)', ticket, D, staking)])
        c_call('C7', u.REG, 'safeMintForRole(bytes32,address,bytes)',
            (role_id('ENDUSER'), S, a.cast('abi-encode', 'c(address,uint256)', D, ws['endUserStake'])),
            [word_pred(u.REG, 'hasRole(bytes32,address)', 1, role_id('ENDUSER'), S),
             word_pred(mysbt, 'verifyCommunityMembership(address,address)', 1, S, D),
             word_pred(u.SP, 'sbtHolders(address)', 1, S), word_pred(u.SP, 'isEligibleForSponsorship(address)', 1, S),
             word_pred(u.REG, 'getRoleStake(bytes32,address)', ws['endUserStake'], role_id('ENDUSER'), S),
             word_pred(gtoken, 'allowance(address,address)', 0, D, staking),
             word_pred(gtoken, 'balanceOf(address)', p['endUser']['deployerGToken']-ticket, D)])
    c_call('C8', X, 'mint(address,uint256)', (S, ws['userTarget']),
        [word_pred(X, 'balanceOf(address)', ws['userTarget'], S), word_pred(X, 'totalSupply()', ws['userTarget']),
         word_pred(X, 'debts(address)', 0, S), word_pred(X, 'creditPolicy()', 0), word_pred(X, 'pendingPolicyEta()', 0)])
    if ws['ownerTopUp']:
        c_add('C20', O, '0x', [dict(kind='balance', target=O, expected=p['owner']['balance']+ws['ownerTopUp'])],
              value=ws['ownerTopUp'])
    owner_steps = [('C9.allowance', 'setAutoAllowance(address,uint256)', (u.SP, PC_CAP_L)),
                   ('C9.total', 'setUserTotalCap(uint256)', (PC_CAP_L,)), ('C9.mode', 'setRenewalMode(uint8)', (0,))]
    checks = []
    for sid, sig, args in owner_steps:
        checks = checks + {'C9.allowance': [predicate(X, 'autoAllowance(address,address)', (S, u.SP), [PC_CAP_L, 0])],
                           'C9.total': [predicate(X, 'userTotal(address)', (S,), [PC_CAP_L, 0])],
                           'C9.mode': [word_pred(X, 'renewalMode(address)', 0, S), word_pred(X, 'autoRenewUsed(address)', 0, S),
                                       word_pred(X, 'creditPolicy()', 0)]}[sid]
        c_add(sid, S, account_exec(X, a.calldata(sig, *args)), list(checks), sender='owner',
              gasBound=ws['ownerPreparation'][sid])
    f1 = lambda target: [address_pred(target, 'MINTER()', D), word_pred(target, 'decimals()', 18), word_pred(target, 'totalSupply()', 0)]
    task = c_deploy('C10', 'T', base['F1TestToken'], 'c()', (), f1)
    transfer = a.calldata('transfer(address,uint256)', DEAD, PC_TASK_UNIT)
    phase_c['taskCallData'] = account_exec(task, transfer)
    phase_c['callDataHash'] = a.keccak(phase_c['taskCallData'])
    for sid, who, amount in (('C11.S', S, PC_TASK_SENDER), ('C11.R', DEAD, PC_TASK_UNIT)):
        c_call(sid, task, 'mint(address,uint256)', (who, amount), [word_pred(task, 'balanceOf(address)', amount, who)])
    vpm = c_deploy('C12', 'VerifyingPaymaster', base['VerifyingPaymaster'], VPM_CONSTRUCTOR, (ep, c['verifyingSigner']),
        lambda t: [address_pred(t, 'owner()', D), address_pred(t, 'entryPoint()', ep),
                   address_pred(t, 'verifyingSigner()', c['verifyingSigner'])])
    fee = c_deploy('C13.token', 'Q', base['F1TestToken'], 'c()', (), f1)
    oracle = c_deploy('C13.oracle', 'oracle', base['F1Oracle'], 'c()', (),
        lambda t: [word_pred(t, 'decimals()', 8), word_pred(t, 'latestRoundData()', 10**8, index=1)])
    config = (PC_TPM_MARKUP, 0, PC_TPM_REFUND, PC_TPM_AGE)
    tpm = c_deploy('C14', 'TokenPaymaster', base['TokenPaymaster'], TPM_CONSTRUCTOR,
        (fee, ep, DEAD, DEAD, '(%d,%d,%d,%d)' % config,
         '(%d,%d,%s,%s,true,false,false,%d)' % (PC_TPM_AGE, PC_TPM_AGE, oracle, a.ZERO, PC_TPM_THRESHOLD),
         '(1,3000,5)', D),
        lambda t: [address_pred(t, 'owner()', D), address_pred(t, 'entryPoint()', ep), address_pred(t, 'token()', fee),
                   address_pred(t, 'wrappedNative()', DEAD), address_pred(t, 'uniswap()', DEAD),
                   predicate(t, 'tokenPaymasterConfig()', (), list(config))])
    c_call('C15', tpm, 'updateCachedPrice(bool)', ('true',),
        [word_pred(tpm, 'cachedPrice()', PC_TPM_MARKUP), dict(kind='eta', target=tpm, signature='cachedPriceTimestamp()', delay=0)])
    targets = dict(SP=u.SP, VPM=vpm, TPM=tpm)
    for arm in ('VPM', 'TPM'):
        c_call('C16.'+arm.lower(), targets[arm], 'addStake(uint32)', (DAY,),
            [predicate(ep, 'getDepositInfo(address)', (targets[arm],), [0, 1, PC_STAKE, DAY, 0])], value=PC_STAKE)
    stakes = dict(SP=pin['stake']+stake, VPM=PC_STAKE, TPM=PC_STAKE)
    for arm in ARMS:
        top = ws['entryPointTopUps'][arm]
        if top:
            c_call('C17.'+arm.lower(), ep, 'depositTo(address)', (targets[arm],),
                [word_pred(ep, 'balanceOf(address)', ws['entryPointBefore'][arm]+top, targets[arm]),
                 word_pred(ep, 'getDepositInfo(address)', stakes[arm], targets[arm], index=2)], value=top)
    c_call('C18.mint', fee, 'mint(address,uint256)', (S, ws['feeTokenTarget']),
        [word_pred(fee, 'balanceOf(address)', ws['feeTokenTarget'], S)])
    c_add('C18.approve', S, account_exec(fee, a.calldata('approve(address,uint256)', tpm, ws['feeTokenTarget'])),
        [word_pred(fee, 'allowance(address,address)', ws['feeTokenTarget'], S, tpm)], sender='owner',
        gasBound=ws['ownerPreparation']['C18.approve'])
    if ws['bundlerTopUp']:
        c_add('C19', c['bundler'], '0x', [dict(kind='balance', target=c['bundler'],
              expected=p['bundler']['balance']+ws['bundlerTopUp'])], value=ws['bundlerTopUp'])
    phase_c['addresses'].update(T=task, Q=fee, oracle=oracle, VPM=vpm, TPM=tpm)
    phase_c['steps'] = [s['id'] for s in steps if s.get('phase') == 'C']
    values = sum(a.qty(s['tx']['value']) for s in steps if s['sender'] == 'deployer')
    # Values alone (stakes, deposits, B/O funding) must fit D before gas is even measured.
    report = dict(balanceWei=pin['senders']['deployer']['balance'], requiredWei=values,
                  shortfallWei=positive(values-pin['senders']['deployer']['balance']))
    a.need('budget_deployer_values', report, dict(report, shortfallWei=0))
    phase_c['deployerValueWei'] = values
    if stage == 'c':
        return finish()
    call('D.registry.transfer', u.REG, 'transferOwnership(address)', (u.TL,),
         registry_ownership(u.DEPLOYER, u.TL))
    op = dict(batch=False, targets=[u.REG], data=[a.calldata('acceptOwnership()')],
              predecessor=operations['activation']['id'],
              salt=a.keccak('manifest-v3.1/'+pin['blockHash']+'/'+inputs['sha256']+'/registry_accept'))
    op['id'] = u.operation_hash(op['targets'], op['data'], op['predecessor'], op['salt'], False)
    operations['registry_accept'] = op
    for verb in ('schedule', 'execute'):
        inner = u.op_call(op, verb)
        h = safe_hash(inner, safe_n)
        sid = 'D.registry_'+verb
        add(sid+'_approve', u.SAFE, a.calldata('approveHash(bytes32)', h),
            [word_pred(u.SAFE, 'approvedHashes(address,bytes32)', 1, a.APPROVER, h)],
            sender='approver', safeHash=h, inner=inner, operation='registry_accept')
        checks = [word_pred(u.TL, 'getOperationState(bytes32)', 1 if verb == 'schedule' else 3, op['id'])]
        if verb == 'schedule':
            checks.append(dict(kind='eta', target=u.TL, signature='getTimestamp(bytes32)', args=[op['id']], delay=u.DELAY))
        else:
            checks += registry_ownership(u.TL, a.ZERO)
        add(sid+'_exec', u.SAFE, safe_payload(inner), checks, sender='executor',
            safeHash=h, inner=inner, operation='registry_accept')
        safe_n += 1
    for name, target, owner in handover_contracts(addresses)[1:]:
        if name in ('aggregator', 'old_aggregator'):
            call('D.'+name+'.admin', target, 'setSlashPolicyAdmin(address)', (u.SAFE,),
                 [address_pred(target, 'slashPolicyAdmin()', u.SAFE)])
        call('D.'+name+'.transfer', target, 'transferOwnership(address)', (owner,),
             [address_pred(target, 'owner()', owner)])
    return finish()


def registry_ownership(owner, pending):
    return [address_pred(u.REG, 'owner()', owner), address_pred(u.REG, 'pendingOwner()', pending),
            dict(kind='storage', target=u.REG, slot=PENDING_OWNER_SLOT, expected=int(pending, 16))]


def handover_contracts(addresses):
    return [('registry', u.REG, u.TL), ('protocol', addresses['AOAProtocolRegistry'], u.TL),
            ('factory', addresses['xPNTsFactoryV2'], u.TL),
            ('aggregator', addresses['BLSAggregator'], u.SAFE), ('dvt', DVT, u.SAFE),
            ('committee', COMMITTEE, u.SAFE), ('old_aggregator', OLD_AGGREGATOR, u.SAFE)]


def handover_gate(rpc, plan, step, context):
    sid = step['id']
    if not sid.startswith('D.'):
        return
    passed = context.get('passed', set())
    required_steps = {'activation_execute_exec', 'B4'}
    if sid.startswith(('D.aggregator.', 'D.old_aggregator.')):
        required_steps.update(('A10.0', 'A10.1', 'A10.2', 'A11.min', 'A11.default'))
    if 'phaseC' in plan:
        # Phase C funding precedes Phase D (§3 ordering, §4 critical path), and every
        # funding target, including omitted rows, still holds before each handover step.
        required_steps.update(plan['phaseC']['steps'])
        if required_steps <= passed:
            context.setdefault('handoverFunding', []).append(funding_gate(rpc, plan))
    if sid.startswith('D.registry_'):
        required_steps.add('D.registry.transfer')
        for pred in registry_ownership(u.DEPLOYER, u.TL):
            check_predicate(rpc, pred)
    if sid == 'D.committee.transfer':
        required_steps.add('A8.committee')
        # Require the transferOwnership dispatch bytes and no acceptOwnership or
        # pendingOwner selector bytes in the pinned runtime. The post-transfer
        # owner()==SAFE read-back remains the authoritative ownership check.
        runtime = plan['pin']['bindings'][COMMITTEE].lower()
        a.need('committee_transfer_selector', '63f2fde38b' in runtime, True)
        a.need('committee_no_accept_ownership', '79ba5097' in runtime, False)
        a.need('committee_no_pending_owner', 'e30c3978' in runtime, False)
    if sid in ('D.aggregator.transfer', 'D.old_aggregator.transfer'):
        required_steps.add(sid.replace('.transfer', '.admin'))
        check_predicate(rpc, address_pred(step['tx']['to'], 'slashPolicyAdmin()', u.SAFE))
    a.need('handover_dependencies', required_steps <= passed, True)


def handover_trace(rpc, plan, step, receipt):
    # The existing SP trace helper is intentionally SP-specific.
    trace = rpc('debug_traceTransaction', [receipt['transactionHash'], {'tracer':'callTracer'}])
    a.need('handover_trace_object', isinstance(trace, dict), True)
    for key, expected in (('from', step['tx']['from']), ('to', u.SAFE), ('input', step['tx']['data'])):
        a.need('handover_trace_'+key, trace.get(key, '').lower(), expected.lower())
    a.need('handover_trace_success', bool(trace.get('error')), False)
    nodes = list(a.trace_nodes(trace))
    if step['id'].endswith('_exec'):
        expected = [(u.SAFE, u.TL, step['inner'])]
        if 'execute' in step['id']:
            expected.append((u.TL, u.REG, a.calldata('acceptOwnership()')))
        for sender, target, data in expected:
            matches = [n for n in nodes if n.get('to', '').lower() == target and n.get('input') == data]
            a.need('handover_trace_call_count', len(matches), 1)
            a.need('handover_trace_caller', matches[0].get('from', '').lower(), sender)
            a.need('handover_trace_call_success', bool(matches[0].get('error')), False)


def handover_controls(rpc, plan):
    """Exercise actual owner checks; all fixture writes/nonces are snapshot-isolated."""
    a.need('handover_controls_local', getattr(rpc, 'local', False), True)
    results = []
    for name, target, owner in handover_contracts(plan['addresses']):
        snap = rpc('evm_snapshot', [])
        try:
            check_predicate(rpc, address_pred(target, 'owner()', owner))
            data = a.calldata('transferOwnership(address)', owner)
            for sender in ((u.DEPLOYER, u.SAFE) if owner == u.TL else (u.DEPLOYER,)):
                tx = u.fixture_tx(rpc, sender, target, data)
                results.append(a.negative(rpc, tx, a.calldata('OwnableUnauthorizedAccount(address)', sender),
                                          'handover_'+name+'_'+sender))
            receipt = u.receipt(rpc, u.fixture_tx(rpc, owner, target, data))
            a.need('handover_positive_status', a.qty(receipt['status']), 1)
            check_predicate(rpc, address_pred(target, 'owner()', owner))
            if name == 'registry':
                for pred in registry_ownership(owner, owner):
                    check_predicate(rpc, pred)
            if name in ('aggregator', 'old_aggregator'):
                data = a.calldata('setSlashPolicyAdmin(address)', u.SAFE)
                results.append(a.negative(rpc, u.fixture_tx(rpc, u.DEPLOYER, target, data),
                    a.calldata('OwnableUnauthorizedAccount(address)', u.DEPLOYER), 'handover_'+name+'_admin'))
                receipt = u.receipt(rpc, u.fixture_tx(rpc, u.SAFE, target, data))
                a.need('handover_admin_status', a.qty(receipt['status']), 1)
                check_predicate(rpc, address_pred(target, 'slashPolicyAdmin()', u.SAFE))
            results.append(dict(contract=name, positiveReceipt=receipt, snapshot=snap))
        finally:
            a.need('handover_control_restore', rpc('evm_revert', [snap]), True)
    # Probe setters without retaining policy, balance or nonce changes.
    probes = [('sp', u.SP, u.TL, 'setProtocolFee(uint256)', 'protocolFeeBPS()', (),
               (u.DEPLOYER, u.SAFE), 'OwnableUnauthorizedAccount(address)')]
    for name, target in (('aggregator', plan['addresses']['BLSAggregator']),
                         ('old_aggregator', OLD_AGGREGATOR)):
        probes += [(name, target, u.SAFE, setter, getter, args, (u.DEPLOYER,),
                    'NotSlashPolicyAdmin(address)') for setter, getter, args in (
                        ('setSlashThreshold(uint8,uint8)', 'slashThresholds(uint8)', (0,)),
                        ('setGuardianSlashBps(uint16)', 'guardianSlashBps()', ()))]
    for name, target, admin, setter, getter, args, denied, error in probes:
        snap = rpc('evm_snapshot', [])
        try:
            authority = 'owner()' if name == 'sp' else 'slashPolicyAdmin()'
            check_predicate(rpc, address_pred(target, authority, admin))
            current = a.word(rpc, target, getter, *args)
            data = a.calldata(setter, *args, current)
            label = 'handover_'+name+'_'+setter.split('(')[0]
            for sender in denied:
                results.append(a.negative(rpc, u.fixture_tx(rpc, sender, target, data),
                    a.calldata(error, sender), label+'_'+sender))
            receipt = u.receipt(rpc, u.fixture_tx(rpc, admin, target, data))
            a.need(label+'_status', a.qty(receipt['status']), 1)
            check_predicate(rpc, word_pred(target, getter, current, *args))
            results.append(dict(contract=name, setter=setter, currentValue=current,
                                positiveReceipt=receipt, snapshot=snap))
        finally:
            a.need('handover_setter_restore', rpc('evm_revert', [snap]), True)
        check_predicate(rpc, word_pred(target, getter, current, *args))
    check_predicate(rpc, address_pred(u.SP, 'owner()', u.TL))
    for name, target, owner in handover_contracts(plan['addresses']):
        check_predicate(rpc, address_pred(target, 'owner()', owner))
        if name in ('aggregator', 'old_aggregator'):
            check_predicate(rpc, address_pred(target, 'slashPolicyAdmin()', u.SAFE))
    for pred in registry_ownership(u.TL, a.ZERO):
        check_predicate(rpc, pred)
    return dict(control='owner_handover', assertions=results, restored=True)


def activation_eta_gate(plan, schedule_timestamp, execute_timestamp):
    a.need('6c_schedule_floor', schedule_timestamp >= plan['activationScheduleNotBefore'], True)
    a.need('6d_timelock_eta', execute_timestamp >= schedule_timestamp+u.DELAY, True)
    a.need('6d_token_eta', execute_timestamp >= plan['pin']['pendingAPNTsTokenEta'], True)


def b2_gate(rpc, plan, upgrade_block):
    a.need('B2_capped_buffer', a.word(rpc, plan['pin']['capped'], 'balanceOf(address)', u.SP), BUFFER)
    observed = balances(rpc, plan['pin']['pauseList'])
    a.need('B2_balances', observed['totalTrackedBalance'], observed['protocolRevenue'])
    a.need('B2_revenue', observed['protocolRevenue'] <= BUFFER, True)
    a.need('B2_operator_balances', sum(observed['operatorBalances'].values()), 0)
    for who in plan['pin']['pauseList']:
        a.need('B2_pending_slash_'+who, a.word(rpc, u.SP, 'isSlashPending(address)', who), 0)
    # 5.4.2 has no reservation map. B1 creates 5.5's first possible reservation
    # epoch, atomically paused. Require a continuous pause and no intervening
    # implementation change; a current pause bit alone cannot prove this.
    a.need('B2_global_pause', a.word(rpc, u.SP, 'paused()'), 1)
    end = a.block_data(rpc, 'latest')['number']
    pauses = u.scan(rpc, u.SP, int(upgrade_block, 16), end, [a.keccak('GlobalPauseSet(address,bool)')])
    a.need('B2_pause_history_present', bool(pauses), True)
    a.need('B2_no_unpause_since_upgrade', all(u.uints(x['data']) == [1] for x in pauses), True)
    upgrades = u.scan(rpc, u.SP, int(upgrade_block, 16), end, [a.keccak('Upgraded(address)')])
    a.need('B2_single_upgrade', len(upgrades), 1)
    a.need('B2_upgrade_identity', u.addr_word(int(upgrades[0]['topics'][1], 16)), plan['implementation'])
    observed['inflightProof'] = dict(upgradeBlock=upgrade_block, continuousGlobalPause=True, upgrades=upgrades, pauses=pauses)
    return observed


def b4_needed(rpc, plan):
    return a.address(rpc, plan['addresses']['BLSAggregator'], 'fraudProofVerifier()') != plan['addresses']['OverIssueFraudProofVerifier']


def b4_post_state(rpc, plan, variant, receipt):
    a.need('B4_variant', variant in ('apply', 'placeholder'), True)
    status = a.qty(receipt['status'])
    a.need('B4_status', status == 1 or (variant == 'apply' and status == 0), True)
    step = next(s for s in plan['steps'] if s['id'] == 'B4')
    return [check_predicate(rpc, pred) for pred in step['readbacks']]


def select_b4(rpc, plan, step):
    name = 'apply' if b4_needed(rpc, plan) else 'placeholder'
    return name, copy.deepcopy(step['variants'][name])


def execute_b4(remote, rpc, plan, step, context, overrides, calibrate, out=None):
    timestamp = a.qty(a.block_data(rpc, 'latest')['timestamp'])+1
    if calibrate:
        u.measure_step(remote, rpc, plan, step, overrides, timestamp, True)
        # Calibration requires the unapplied fixture to measure both approved payloads.
        # Snapshot probes never consume the reserved nonce.
        step['variants']['apply'] = copy.deepcopy(step['tx'])
    placeholder = dict(id=step['id'], tx=step['variants']['placeholder'])
    if not calibrate:
        placeholder.update(step['variantMeasurements']['placeholder'])
        u.replay_remote_measurement(remote, plan, step, overrides, timestamp)
        u.replay_remote_measurement(remote, plan, placeholder, overrides, timestamp)
    if calibrate:
        u.measure_step(remote, rpc, plan, placeholder, overrides, timestamp, True)
        step['variantMeasurements'] = {'placeholder': {k: copy.deepcopy(v) for k, v in placeholder.items() if k not in ('id', 'tx')}}
    # Re-estimate the selected payload. A race after this gate is checked by b4_post_state.
    name, tx = select_b4(rpc, plan, step)
    selected = dict(step, tx=tx)
    if name == 'placeholder':
        selected.update(step['variantMeasurements']['placeholder'])
    if not calibrate:
        u.measure_step(remote, rpc, plan, selected, overrides, timestamp, False)
    pre_send(rpc, plan, selected, context, measured=True)
    fresh = u.fresh_gas(remote, selected, overrides, timestamp, pin_block=plan['pin']['block'])
    a.need('B4_block_gas', a.qty(tx['gas']) <= a.qty(a.block_data(rpc, 'latest')['gasLimit']), True)
    rpc('evm_setNextBlockTimestamp', [timestamp])
    r = u.receipt(rpc, tx, status=None)
    a.mined_identity(rpc('eth_getTransactionByHash', [r['transactionHash']]), tx, 'B4')
    # Codex audit605 round 4: like manifest_timestamp, B4 must be mined at the timestamp it was measured for.
    a.need('B4_timestamp', a.qty(a.block_data(rpc, r['blockNumber'])['timestamp']), timestamp)
    a.need('B4_nonce_consumed', a.nonce(rpc, tx['from']), a.qty(tx['nonce'])+1)
    a.need('B4_safe_nonce', a.word(rpc, u.SAFE, 'nonce()'), step['safeNonce'])
    a.need('B4_receipt_gas', a.qty(r['gasUsed']) <= a.qty(tx['gas']), True)
    # Record even a reverted apply before checking whether its post-state permits continuation.
    record = dict(step='B4', variant=name, transaction=tx, receipt=r, freshGas=fresh)
    context['B4Receipt'] = record
    if out is not None:
        u.log(out, record)
    observed = b4_post_state(rpc, plan, name, r)
    step['skipped'] = False
    return dict(record, readbacks=observed)


def b4_controls(rpc, plan, step):
    results = []
    agg = plan['addresses']['BLSAggregator']
    for control in ('verifier_placeholder', 'verifier_frontrun', 'verifier_wrong'):
        snap = rpc('evm_snapshot', [])
        try:
            if not b4_needed(rpc, plan):
                u.receipt(rpc, u.fixture_tx(rpc, u.DEPLOYER, agg,
                    a.calldata('emergencyDisarmFraudProofVerifier()')))
                u.receipt(rpc, u.fixture_tx(rpc, u.DEPLOYER, agg,
                    a.calldata('proposeFraudProofVerifier(address)', plan['addresses']['OverIssueFraudProofVerifier'])))
                u.wait_until(rpc, a.word(rpc, agg, 'pendingFraudProofVerifierReadyAt()'))
            name, tx = select_b4(rpc, plan, step)
            a.need('B4_control_initial', name, 'apply')
            if control == 'verifier_wrong':
                u.receipt(rpc, u.fixture_tx(rpc, u.DEPLOYER, agg,
                    a.calldata('proposeFraudProofVerifier(address)', plan['pin']['oldAggregator'])))
                u.wait_until(rpc, a.word(rpc, agg, 'pendingFraudProofVerifierReadyAt()'))
            # Permissionless apply from another account preserves D's reserved nonce.
            u.receipt(rpc, u.fixture_tx(rpc, a.EXECUTOR, agg, a.calldata('applyFraudProofVerifier()')))
            if control == 'verifier_placeholder':
                name, tx = select_b4(rpc, plan, step)
                a.need('B4_control_placeholder', name, 'placeholder')
            tx = dict(tx, gas=tx.get('gas', hex(a.GAS_CAP)))
            # Owner setup writes are confined to this reverted fixture.
            tx['nonce'] = hex(a.nonce(rpc, u.DEPLOYER))
            receipt = u.receipt(rpc, tx, status=None)
            try:
                b4_post_state(rpc, plan, name, receipt)
            except a.Gate as error:
                if control != 'verifier_wrong':
                    raise
                a.need('B4_wrong_gate', error.record['gate'], 'readback_fraudProofVerifier()')
                a.need('B4_wrong_status', receipt['status'], '0x0')
                results.append(dict(control=control, stopped=True, receipt=receipt))
            else:
                a.need('B4_wrong_must_stop', control != 'verifier_wrong', True)
                a.need('B4_control_status', a.qty(receipt['status']),
                       1 if control == 'verifier_placeholder' else 0)
                next_nonce = a.nonce(rpc, u.DEPLOYER)
                a.need('B4_next_nonce', next_nonce, a.qty(tx['nonce'])+1)
                # A later D transaction uses exactly the next nonce in either branch.
                later = dict(tx, to=u.DEPLOYER, data='0x', value='0x0', nonce=hex(next_nonce))
                u.receipt(rpc, later)
                a.need('B4_later_nonce', a.nonce(rpc, u.DEPLOYER), next_nonce+1)
                results.append(dict(control=control, variant=name, receipt=receipt, nextDeployerNonce=next_nonce))
        finally:
            a.need('B4_control_restore', rpc('evm_revert', [snap]), True)
    return results


def check_predicate(rpc, p, timestamp=None):
    kind = p['kind']
    if kind == 'verifierCode':
        value = u.code(rpc, p['target'], 'latest')
        a.need('verifier_bound_runtime', value in p['expected'], True)
        return value
    if kind == 'code':
        value = u.code(rpc, p['target'], 'latest')
    elif kind == 'codeHash':
        value = a.keccak(u.code(rpc, p['target'], 'latest'))
    elif kind == 'balance':
        value = a.qty(rpc('eth_getBalance', [p['target'], 'latest']))
    elif kind == 'storage':
        value = int(rpc('eth_getStorageAt', [p['target'], p['slot'], 'latest']), 16)
    else:
        raw = a.call(rpc, p['target'], p['signature'], *p.get('args', []))
        if kind == 'eta':
            a.need('readback_eta', int(raw, 16), timestamp+p['delay'])
            return int(raw, 16)
        expected = p['expected']
        words = u.uints(raw)
        value = words[p['index']] if 'index' in p else (words if isinstance(expected, list) else
            (int(raw, 16) if isinstance(expected, int) else raw))
    a.need('readback_'+p.get('signature', kind), value, p['expected'])
    return value


def batch_readback(rpc, plan, activated, timestamp):
    addr = plan['addresses']
    checks = [dict(kind='storage', target=u.SP, slot=u.IMPL_SLOT, expected=int(plan['implementation'], 16)),
        address_pred(plan['implementation'], 'EXTENSION()', plan['extension']),
        address_pred(u.SP, 'owner()', u.TL), address_pred(u.SP, 'xpntsFactory()', addr['xPNTsFactoryV2']),
        word_pred(u.SP, 'paused()', int(not activated))]
    gas = u.uints(a.call(rpc, u.SP, 'gasParams()'))
    a.need('batch_gas', gas[:4] if activated else gas[4:8], u.GAS)
    if activated:
        a.need('batch_gas_queue_empty', gas[4:], [0]*5)
        checks += [address_pred(u.SP, 'BLS_AGGREGATOR()', addr['BLSAggregator']),
            address_pred(u.SP, 'APNTS_TOKEN()', plan['pin']['capped']),
            address_pred(u.SP, 'pendingAPNTsToken()', a.ZERO), word_pred(u.SP, 'pendingAPNTsTokenEta()', 0),
            address_pred(u.SP, 'pendingBLSAgg()', a.ZERO), word_pred(u.SP, 'pendingBLSAggEta()', 0)]
    else:
        a.need('gas_eta', gas[8], timestamp+u.DELAY)
        checks += [address_pred(u.SP, 'pendingBLSAgg()', addr['BLSAggregator']),
            word_pred(u.SP, 'pendingBLSAggEta()', timestamp+DAY)]
    for who in plan['pin']['pauseList']:
        checks += [word_pred(u.SP, 'operators(address)', int(not activated or who not in plan['externalInputs']['data']['sampled']), who, index=2)]
    for p in checks:
        check_predicate(rpc, p)
    return dict(gasParams=gas, activated=activated)


def budget(plan):
    result = {}
    senders = dict(plan['pin']['senders'])
    pc = plan.get('phaseC')
    if pc is not None:
        senders['owner'] = plan['pin']['phaseC']['owner']
    for label, sender in senders.items():
        cost = sum(max(a.qty(t['gas']) for t in s.get('variants', {'apply': s['tx']}).values())*a.qty(s['tx']['maxFeePerGas'])+a.qty(s['tx']['value'])
                   for s in plan['steps'] if s['sender'] == label and not s.get('skipped', False))
        available, required_wei = sender['balance'], cost
        if label == 'owner':
            # D funds O (C20) for its packet calls plus the listed in-window maintenance.
            available += pc['ownerTopUp']
            required_wei += pc['ownerMaintenanceWei']
        # Report the exact shortfall; n is never reduced to fit a balance (§4).
        report = dict(balanceWei=available, requiredWei=required_wei, shortfallWei=positive(required_wei-available))
        a.need('budget_'+label, report, dict(report, shortfallWei=0))
        result[label] = cost
    plan['budgetsWei'] = result


def validate_plan(plan, inputs, frozen=False):
    a.need('external_inputs_match', plan['externalInputs'], inputs)
    expected = build_plan(plan['pin'], inputs, plan.get('stage', 'full'), plan.get('stageSources'))
    a.exact_keys('manifest_keys', plan, set(expected) | ({'budgetsWei'} if frozen else set()))
    for key in set(expected)-{'steps'}:
        a.need('manifest_'+key, plan[key], expected[key])
    a.need('manifest_length', len(plan['steps']), len(expected['steps']))
    for actual, derived in zip(plan['steps'], expected['steps']):
        extra = u.MEASURED_KEYS | {'skipped', 'gasEvidence'} if frozen else set()
        if frozen and 'variants' in derived:
            extra |= {'variantMeasurements'}
        if frozen:
            u.validate_gas_evidence(plan, actual)
            owner_gas_gate(dict(actual, gasBound=derived['gasBound'])) if 'gasBound' in derived else None
        if frozen:
            a.need('no_skipped_nonce', actual.get('skipped'), False)
        a.exact_keys('manifest_step', actual, set(derived) | extra)
        for key in set(derived)-{'tx', 'variants'}:
            a.need('manifest_step_'+key, actual[key], derived[key])
        a.exact_keys('manifest_tx', actual['tx'], set(derived['tx']) | ({'gas'} if frozen and not actual.get('skipped') else set()))
        for key, value in derived['tx'].items():
            a.need('manifest_tx_'+key, actual['tx'][key], value)
        if 'variants' in derived:
            a.exact_keys('B4_variants', actual['variants'], ('apply', 'placeholder'))
            for name, tx in derived['variants'].items():
                variant = actual['variants'][name]
                a.exact_keys('B4_variant_fields', variant, set(tx) | ({'gas'} if frozen else set()))
                for key, value in tx.items():
                    a.need('B4_variant_'+key, variant[key], value)
            a.need('B4_apply_binding', actual['variants']['apply'], actual['tx'])
            if frozen:
                a.need('B4_placeholder_intrinsic', a.qty(actual['variants']['placeholder']['gas']) >= 21000, True)
                a.tx_quantities(actual['variants']['placeholder'])
                with u.gas_step(actual):
                    a.exact_keys('B4_variant_measurements', actual['variantMeasurements'], ('placeholder',))
                placeholder = dict(id=actual['id'], **actual['variantMeasurements']['placeholder'])
                placeholder['tx'] = actual['variants']['placeholder']
                u.validate_gas_evidence(plan, placeholder)
                with u.gas_step(actual):
                    a.exact_keys('B4_placeholder_measurements', actual['variantMeasurements']['placeholder'],
                                 u.MEASURED_KEYS | {'gasEvidence'})
    if frozen:
        checked = copy.deepcopy(plan)
        budget(checked)
        a.need('manifest_budget', checked['budgetsWei'], plan['budgetsWei'])


def owner_gas_gate(step):
    # O's funding (OD) was computed from this reviewed bound; a larger limit is STOP.
    if 'gasBound' in step:
        a.need('C_owner_gas_bound', a.qty(step['tx']['gas']) <= step['gasBound'], True)


def price_gate(rpc, block='latest'):
    price = u.uints(a.call(rpc, u.SP, 'cachedPrice()', block=block))
    a.need('C_price_decimals', price[3], PC_PRICE_DECIMALS)
    a.need('C_price_bound', 0 < price[0] <= PC_PRICE_CAP, True)
    return price


def phase_c_state(rpc, plan, context):
    """§3 C1 preconditions held for every Phase C transaction (B3/B4 complete)."""
    a.need('C_after_activation', {'activation_execute_exec', 'B4'} <= context.get('passed', set())
           and bool(context.get('activated')), True)
    a.need('C_after_token_eta', a.qty(a.block_data(rpc, 'latest')['timestamp']) >= plan['pin']['pendingAPNTsTokenEta'], True)
    a.need('C_token_swapped', a.address(rpc, u.SP, 'APNTS_TOKEN()'), plan['pin']['capped'])
    gas = u.uints(a.call(rpc, u.SP, 'gasParams()'))
    a.need('C_gas_tuple', [gas[:4], gas[4:]], [u.GAS, [0]*(len(gas)-4)])
    a.need('C_global_unpaused', a.word(rpc, u.SP, 'paused()'), 0)
    sampled = set(plan['externalInputs']['data']['sampled'])
    for who in plan['pin']['pauseList']:
        a.need('C_sampled_unpaused' if who in sampled else 'C_unsampled_paused',
               u.uints(a.call(rpc, u.SP, 'operators(address)', who))[OP['isPaused']], int(who not in sampled))
    price_gate(rpc)
    pc = plan['phaseC']
    a.need('C_pricing_unchanged', [a.word(rpc, u.SP, 'aPNTsPriceUSD()'), a.word(rpc, u.SP, 'protocolFeeBPS()')],
           [pc['aPNTsPriceUSD'], pc['protocolFeeBPS']])


def phase_c_pre_send(rpc, plan, step, context):
    phase_c_state(rpc, plan, context)
    pc, pin, sid = plan['phaseC'], plan['pin'], step['id']
    p, c = pin['phaseC'], plan['externalInputs']['data']['phaseC']
    capped, D, S, O = pin['capped'], u.DEPLOYER, c['account'], c['accountOwner']
    addr = pc['addresses']
    X, factory = addr['X'], plan['addresses']['xPNTsFactoryV2']
    if sid.startswith('C1_'):
        a.need('C1_minter', a.address(rpc, capped, 'minter()'), u.SAFE)
        a.need('C1_cap_headroom', a.word(rpc, capped, 'totalSupply()')+pc['cappedMint'] <= a.word(rpc, capped, 'cap()'), True)
        a.need('C1_pinned_balance', a.word(rpc, capped, 'balanceOf(address)', D), p['capped']['deployerBalance'])
    if sid == 'C2.approve':
        a.need('C2_operator_role', a.word(rpc, u.REG, 'hasRole(bytes32,address)', role_id('PAYMASTER_SUPER'), D), 1)
        a.need('C2_token_balance', a.word(rpc, capped, 'balanceOf(address)', D) >= pc['operatorTopUp'], True)
        expected = list(pc['operatorBefore'])
        expected[OP['aPNTsBalance']] = pc['operatorTarget']-pc['operatorTopUp']
        a.need('C_operator_before', u.uints(a.call(rpc, u.SP, 'operators(address)', D)), expected)
    if sid == 'C3.deploy':
        a.need('C3_factory_active', a.address(rpc, u.SP, 'xpntsFactory()'), factory)
        a.need('C3_community', a.word(rpc, u.REG, 'hasRole(bytes32,address)', role_id('COMMUNITY'), D), 1)
        # X is the factory's first CREATE; any earlier clone changes the planned address.
        a.need('C3_factory_fresh', [addr_call(rpc, factory, 'getTokenAddress(address)', D),
               a.word(rpc, factory, 'getDeployedCount()'), u.code(rpc, X, 'latest')], [a.ZERO, 0, '0x'])
    if sid == 'C3.configure':
        a.need('C_operator_before', u.uints(a.call(rpc, u.SP, 'operators(address)', D)), pc['operatorBefore'])
    if sid == 'C5':
        a.need('C5_counterfactual', addr_call(rpc, ACCOUNT_FACTORY, 'getAddress(address,uint256)', O, c['salt']), S)
        a.need('C5_absent', u.code(rpc, S, 'latest'), '0x')
    if sid in ('C6', 'C7', 'C8'):
        cfg = u.config(a.call(rpc, u.REG, 'getRoleConfig(bytes32)', role_id('ENDUSER')))
        a.need('C7_enduser_active', cfg['isActive'], True)
        a.need('C7_enduser_config', [cfg['minStake'], cfg['ticketPrice']], [pc['endUserStake'], pc['endUserTicket']])
        member = pc['accountMember'] or sid == 'C8'
        a.need('C_account_status', account_status(rpc, S, p['endUser']['mysbt']), [int(member)]*3)
    if sid == 'C6':
        a.need('C6_gtoken_balance', a.word(rpc, p['endUser']['gtoken'], 'balanceOf(address)', D),
               p['endUser']['deployerGToken'])
    if sid == 'C8':
        a.need('C8_community_owner', addr_call(rpc, X, 'communityOwner()'), D)
        a.need('C8_policy_off', [a.word(rpc, X, 'creditPolicy()'), a.word(rpc, X, 'pendingPolicyEta()')], [0, 0])
        a.need('C8_user_clean', [a.word(rpc, X, sig, S) for sig in ('debts(address)', 'lockedOf(address)',
               'creditReservedOf(address)', 'balanceOf(address)')], [0, 0, 0, 0])
        a.need('C8_amax_limit', pc['Amax'] <= min(PC_CAP_L, a.word(rpc, X, 'maxSingleTxLimit()')), True)
    if step['sender'] == 'owner':
        a.need('C9_account_owner', addr_call(rpc, S, 'owner()'), O)
        # O must still cover every remaining O transaction plus the listed maintenance.
        index = next(i for i, s in enumerate(plan['steps']) if s['id'] == sid)
        remaining = sum(a.qty(s['tx'].get('gas', hex(s['gasBound'])))*a.qty(s['tx']['maxFeePerGas'])
                        for s in plan['steps'][index:] if s['sender'] == 'owner')
        a.need('C_owner_budget', a.qty(rpc('eth_getBalance', [O, 'latest'])) >= remaining+pc['ownerMaintenanceWei'], True)
    if sid.startswith('C9.'):
        a.need('C9_counters', [*u.uints(a.call(rpc, X, 'autoAllowance(address,address)', S, u.SP))[1:],
               *u.uints(a.call(rpc, X, 'userTotal(address)', S))[1:], a.word(rpc, X, 'lockedOf(address)', S),
               a.word(rpc, X, 'creditReservedOf(address)', S)], [0, 0, 0, 0])
    if step['tx']['to'] is None:
        a.need('C_create_unused', u.code(rpc, step['creates'], 'latest'), '0x')
    if sid.startswith('C17.'):
        arm = sid.split('.')[1].upper()
        target = dict(SP=u.SP, VPM=addr['VPM'], TPM=addr['TPM'])[arm]
        a.need('C17_deposit_before', a.word(rpc, plan['pin']['immutables']['entryPoint'], 'balanceOf(address)', target),
               pc['entryPointBefore'][arm])
    if sid == 'C18.mint':
        a.need('C18_fee_balance', a.word(rpc, addr['Q'], 'balanceOf(address)', S), 0)
    if sid in ('C19', 'C20'):
        who = c['bundler'] if sid == 'C19' else O
        label = 'bundler' if sid == 'C19' else 'owner'
        a.need(sid+'_recipient_balance', a.qty(rpc('eth_getBalance', [who, 'latest'])), p[label]['balance'])
        a.need(sid+'_recipient_eoa', u.code(rpc, who, 'latest'), '0x')


def sp_attempt_precheck(rpc, plan, flags=0):
    """SP-attempt precheck: no renewal, frozen L with L-used >= Amax, price within P*.

    Exported helper. The executor runs it once at the end of Phase C; the A6 sampler does not
    call it yet, so per-attempt enforcement belongs to the pilot tooling (not this module).
    """
    a.need('SP_RENEW_never', flags & FLAG_SP_RENEW, 0)
    pc = plan['phaseC']
    X, S = pc['addresses']['X'], pc['addresses']['S']
    # Every read is bound to one block; the record names it.
    head = a.block_data(rpc, 'latest')
    block = head['number']
    price = price_gate(rpc, block)
    a.need('precheck_renewal_mode', [a.word(rpc, X, 'renewalMode(address)', S, block=block),
           a.word(rpc, X, 'autoRenewUsed(address)', S, block=block)], [0, 0])
    allow = u.uints(a.call(rpc, X, 'autoAllowance(address,address)', S, u.SP, block=block))
    total = u.uints(a.call(rpc, X, 'userTotal(address)', S, block=block))
    # L is frozen in the packet (§3): any cap change, up or down, is STOP before the used test.
    a.need('precheck_allowance_cap', allow[0], PC_CAP_L)
    a.need('precheck_total_cap', total[0], PC_CAP_L)
    a.need('precheck_allowance', allow[1] <= PC_CAP_L and PC_CAP_L-allow[1] >= pc['Amax'], True)
    a.need('precheck_total', total[1] <= PC_CAP_L and PC_CAP_L-total[1] >= pc['Amax'], True)
    return dict(block=block, blockHash=head['hash'], flags=flags, cachedPrice=price,
                autoAllowance=allow, userTotal=total, Amax=pc['Amax'], L=PC_CAP_L)


def funding_gate(rpc, plan):
    """Re-read every Phase C funding target, executed or omitted at build time (§3: a later
    discrepancy is STOP). O only needs its remaining in-window maintenance after its calls."""
    pc, pin = plan['phaseC'], plan['pin']
    addr, ep = pc['addresses'], pin['immutables']['entryPoint']
    S = addr['S']
    head = a.block_data(rpc, 'latest')
    block = head['number']
    observed = {}
    for arm, target in (('SP', u.SP), ('VPM', addr['VPM']), ('TPM', addr['TPM'])):
        observed['entryPoint'+arm] = a.word(rpc, ep, 'balanceOf(address)', target, block=block)
        a.need('C_funding_entrypoint_'+arm, observed['entryPoint'+arm] >= pc['entryPointTargets'][arm], True)
    for label, who, target in (('bundler', plan['externalInputs']['data']['phaseC']['bundler'], pc['bundlerTarget']),
                               ('owner', plan['externalInputs']['data']['phaseC']['accountOwner'], pc['ownerMaintenanceWei'])):
        observed[label] = a.qty(rpc('eth_getBalance', [who, block]))
        a.need('C_funding_'+label, observed[label] >= target, True)
    # D's operator deposit (AD), the largest single target, sits in SP's own accounting.
    observed['operator'] = u.uints(a.call(rpc, u.SP, 'operators(address)', u.DEPLOYER, block=block))[OP['aPNTsBalance']]
    a.need('C_funding_operator', observed['operator'] >= pc['operatorTarget'], True)
    for label, token, holder, target in (('user', addr['X'], S, pc['userTarget']), ('feeToken', addr['Q'], S, pc['feeTokenTarget']),
                                         ('taskSender', addr['T'], S, pc['taskSender']), ('taskRecipient', addr['T'], DEAD, pc['taskRecipient'])):
        observed[label] = a.word(rpc, token, 'balanceOf(address)', holder, block=block)
        a.need('C_funding_'+label, observed[label] >= target, True)
    observed['feeAllowance'] = a.word(rpc, addr['Q'], 'allowance(address,address)', S, addr['TPM'], block=block)
    a.need('C_funding_feeAllowance', observed['feeAllowance'], pc['feeTokenTarget'])
    return dict(block=block, blockHash=head['hash'], **observed)


PC_CONTROLS = ['C_price_above_cap', 'C_cap_exhausted', 'C_factory_used', 'C_enduser_inactive', 'C_status_mismatch',
               'C_policy_pending', 'C_owner_underfunded', 'C_deposit_front_run', 'C_allowance_exhausted',
               'C_total_exhausted', 'C_sp_renew', 'C_renewal_mode', 'C_bundler_drained']


def layout_slot(plan, contract, label):
    entries = [x for x in plan['rebuild']['contracts'][contract]['storageLayout'].get('storage', []) if x['label'] == label]
    a.need('C_control_layout_'+label, [(len(entries), entries[0]['offset'] if entries else None)], [(1, 0)])
    return int(entries[0]['slot'])


def mapping_slot(key, slot):
    return int(a.keccak(a.cast('abi-encode', 'c(address,uint256)', key, slot)), 16)


def stop_control(rpc, name, gate, mutate, check):
    """Mutate a reverted snapshot, require the named STOP, then require the clean state to pass."""
    snap = rpc('evm_snapshot', [])
    try:
        detail = mutate()
        tripped = None
        try:
            check()
        except a.Gate as error:
            tripped = error.record['gate']
        # Acceptance (None) and a different gate both fail: the named STOP must fire.
        a.need(name+'_gate', tripped, gate)
    finally:
        a.need(name+'_restore', rpc('evm_revert', [snap]), True)
    check()
    return dict(control=name, gate=gate, snapshot=snap, mutation=detail, restored=True)


def write_word(rpc, target, slot, value, getter):
    """Snapshot-only storage write; the getter read-back catches a wrong slot."""
    rpc('anvil_setStorageAt', [target, '0x'+format(slot, '064x'), '0x'+format(value, '064x')])
    observed = getter()
    return dict(target=target, slot=hex(slot), value=hex(value), readback=observed)


def phase_c_controls(rpc, plan, sid, controls, context):
    pc = plan.get('phaseC')
    if pc is None or sid not in pc['steps']+['after_phase_c']:
        return
    step = next((s for s in plan['steps'] if s['id'] == sid), None)
    c = plan['externalInputs']['data']['phaseC']
    X, S, O = pc['addresses']['X'], pc['addresses']['S'], c['accountOwner']
    pre = lambda: phase_c_pre_send(rpc, plan, step, context)
    def fixture(sender, target, data, value=0):
        return u.receipt(rpc, dict(u.fixture_tx(rpc, sender, target, data), value=hex(value)))
    def add(name, gate, mutate, check=pre):
        controls.append(stop_control(rpc, name, gate, mutate, check))
    def not_applicable(name, reason):
        controls.append(dict(control=name, notApplicable=reason))
    if sid == pc['steps'][0]:
        slot = layout_slot(plan, 'SuperPaymaster', 'cachedPrice')
        def high_price():
            value = PC_PRICE_CAP+1
            detail = write_word(rpc, u.SP, slot, value, lambda: u.uints(a.call(rpc, u.SP, 'cachedPrice()'))[0])
            a.need('C_control_slot', detail['readback'], value)
            return detail
        add('C_price_above_cap', 'C_price_bound', high_price)
        if 'C1_approve' not in pc['steps']:
            not_applicable('C_cap_exhausted', 'C1 omitted: zero mint deficit')
    if sid == 'C1_approve':
        capped = plan['pin']['capped']
        def exhaust():
            room = a.word(rpc, capped, 'cap()')-a.word(rpc, capped, 'totalSupply()')-pc['cappedMint']+1
            return fixture(u.SAFE, capped, a.calldata('mint(address,uint256)', DEAD, room))
        add('C_cap_exhausted', 'C1_cap_headroom', exhaust)
    if sid == 'C3.deploy':
        add('C_factory_used', 'C3_factory_fresh', lambda: fixture(u.DEPLOYER, plan['addresses']['xPNTsFactoryV2'],
            step['tx']['data']))
    if sid == 'C8':
        raw = a.call(rpc, u.REG, 'getRoleConfig(bytes32)', role_id('ENDUSER'))
        data = (a.keccak('configureRole(bytes32,'+u.CONFIG_TYPE+')')[:10]+role_id('ENDUSER')[2:]
                +format(64, '064x')+u.frozen_config(raw)[66:])
        add('C_enduser_inactive', 'C7_enduser_active', lambda: fixture(u.DEPLOYER, u.REG, data))
        add('C_status_mismatch', 'C_account_status', lambda: fixture(u.REG, u.SP,
            a.calldata('updateSBTStatus(address,bool)', S, 'false')))
        add('C_policy_pending', 'C8_policy_off', lambda: fixture(u.DEPLOYER, X, a.calldata('queueCreditPolicy(uint8)', 1)))
    if sid == 'C9.allowance':
        add('C_owner_underfunded', 'C_owner_budget', lambda: rpc('anvil_setBalance', [O, hex(pc['ownerMaintenanceWei'])]))
    first_deposit = next((x for x in pc['steps'] if x.startswith('C17.')), None)
    if sid == pc['steps'][0] and first_deposit is None:
        not_applicable('C_deposit_front_run', 'C17 omitted: all EntryPoint deposits already at target')
    if sid == first_deposit:
        arm = sid.split('.')[1].upper()
        target = dict(SP=u.SP, VPM=pc['addresses']['VPM'], TPM=pc['addresses']['TPM'])[arm]
        add('C_deposit_front_run', 'C17_deposit_before', lambda: fixture(a.EXECUTOR,
            plan['pin']['immutables']['entryPoint'], a.calldata('depositTo(address)', target), 1))
    if sid == 'after_phase_c':
        check = lambda: sp_attempt_precheck(rpc, plan)
        for name, gate, label, args in (('C_allowance_exhausted', 'precheck_allowance', '_auto', (u.SP,)),
                                        ('C_total_exhausted', 'precheck_total', '_budget', ())):
            def exhaust(label=label, args=args):
                base = layout_slot(plan, 'xPNTsTokenV2', label)
                slot = mapping_slot(S, mapping_slot(args[0], base)) if args else mapping_slot(S, base)
                old = int(rpc('eth_getStorageAt', [X, hex(slot), 'latest']), 16)
                used = PC_CAP_L-pc['Amax']+1
                getter = (lambda: u.uints(a.call(rpc, X, 'autoAllowance(address,address)', S, u.SP))[1]) if args else \
                         (lambda: u.uints(a.call(rpc, X, 'userTotal(address)', S))[1])
                detail = write_word(rpc, X, slot, (old >> 128 << 128) | used, getter)
                a.need('C_control_slot', detail['readback'], used)
                return detail
            add(name, gate, exhaust, check)
        state = dict(flags=0)
        def renew():
            state['flags'] = FLAG_SP_RENEW
            return dict(flags=FLAG_SP_RENEW)
        def check_flags():
            # One proposed attempt per call; the clean re-check uses no renewal flag.
            flags, state['flags'] = state['flags'], 0
            return sp_attempt_precheck(rpc, plan, flags)
        add('C_sp_renew', 'SP_RENEW_never', renew, check_flags)
        add('C_bundler_drained', 'C_funding_bundler', lambda: rpc('anvil_setBalance', [c['bundler'], hex(pc['bundlerTarget']-1)]),
            lambda: funding_gate(rpc, plan))
        add('C_renewal_mode', 'precheck_renewal_mode', lambda: fixture(O, S, a.calldata('execute(address,uint256,bytes)',
            X, 0, a.calldata('setRenewalMode(uint8)', 1))), check)


def assert_manifest_frozen(rpc, pin, registry_handed_over=False):
    # Keep the shared role/config checks, but follow the completed owner transition.
    u.assert_frozen(rpc, dict(pin, registryOwner=u.TL if registry_handed_over else pin['registryOwner']))


def pre_send(rpc, plan, step, context, measured=False):
    a.need('manifest_local_only', getattr(rpc, 'local', False), True)
    block = a.block_data(rpc,'latest')['number']
    isolation.registry_callsite_targets(lambda target, sig: a.address(rpc, target, sig, block), {})
    # Before every send, not only at closing: a post-pin allowance, role or authority of the orphaned timelock.
    coverage = discovery_coverage(plan, context.get('passed', set()))
    isolation.never_granted_recheck(rpc, coverage, block)
    delta = post_pin_delta(rpc, coverage, block)
    context['oldTimelockDelta'] = delta
    discovery_old_authority(rpc, coverage, block)
    old_timelock_holds_nothing(rpc, coverage, block, delta['approvalOwners'])
    handover_gate(rpc, plan, step, context)
    if step.get('phase') == 'C':
        phase_c_pre_send(rpc, plan, step, context)
    tx = step['tx']
    a.need('chain', a.qty(rpc('eth_chainId', [])), a.CHAIN)
    a.need('sender_nonce', a.nonce(rpc, tx['from']), a.qty(tx['nonce']))
    a.need('pending_nonce', a.nonce(rpc, tx['from'], 'pending'), a.qty(tx['nonce']))
    a.need('safe_nonce', a.word(rpc, u.SAFE, 'nonce()'), step['safeNonce'])
    a.need('safe_state', u.safe_state(rpc, 'latest'), plan['pin']['safe'])
    u.governance(rpc, 'latest', plan['pin']['timelockCreation'])
    for target, expected in plan['pin']['bindings'].items():
        a.need('bound_runtime', u.code(rpc, target, 'latest'), expected)
    unchanged_old_activity(rpc, plan, a.block_data(rpc, 'latest')['number'])
    a.need('dvt_activity_unchanged', dvt_activity(rpc, plan['externalInputs']['data']['dvt'],
        a.block_data(rpc, 'latest')['number']), plan['pin']['oldActivity']['dvtProposals'])
    a.need('registry_owner', a.address(rpc, u.REG, 'owner()'),
           u.TL if 'D.registry_execute_exec' in context.get('passed', set()) else u.DEPLOYER)
    a.need('SP_owner', a.address(rpc, u.SP, 'owner()'), u.TL if context.get('transferred') else u.DEPLOYER)
    if context.get('frozen'):
        assert_manifest_frozen(rpc, plan['pin'], 'D.registry_execute_exec' in context.get('passed', set()))
    else:
        a.need('role_config_unchanged', a.call(rpc, u.REG, 'getRoleConfig(bytes32)', u.role()), plan['pin']['roleConfig'])
    if not context.get('activated'):
        a.need('pending_token', a.address(rpc, u.SP, 'pendingAPNTsToken()'), plan['pin']['capped'])
        a.need('pending_token_eta', a.word(rpc, u.SP, 'pendingAPNTsTokenEta()'), plan['pin']['pendingAPNTsTokenEta'])
    if step['id'] == 'A17':
        u.check_inventory(rpc, plan['pin'])
        u.require_pauses(rpc, plan['pin'])
        drain = balances(rpc, plan['pin']['pauseList'])
        a.need('transfer_drained', drain['totalTrackedBalance'], BUFFER)
        a.need('transfer_revenue', drain['protocolRevenue'], BUFFER)
    if step['id'] == 'activation_execute_exec':
        context['B2'] = b2_gate(rpc, plan, context['upgradeBlock'])
        eta = a.word(rpc, u.TL, 'getTimestamp(bytes32)', plan['operations']['activation']['id'])
        activation_eta_gate(plan, context['activationScheduledAt'], eta)
    if 'safeHash' in step:
        h = a.call(rpc, u.SAFE, 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)',
            step.get('safeTarget', u.TL), 0, step['inner'], 0, 0, 0, 0, a.ZERO, a.ZERO, step['safeNonce'])
        a.need('onchain_safe_hash', h, step['safeHash'])
        if 'operation' in step:
            u.check_op_hash(rpc, plan['operations'][step['operation']])
    if measured:
        u.validate_gas(step)
        owner_gas_gate(step)
        probe = {k: v for k, v in a.tx_rpc(tx, gas_cap=u.MAX_CREATE_GAS if tx['to'] is None else a.GAS_CAP).items() if k != 'gas'}
        a.need('fresh_estimate', a.qty(rpc('eth_estimateGas', [probe, 'latest'])) <= a.qty(tx['gas']), True)
        a.need('block_gas_limit', a.qty(tx['gas']) <= a.qty(a.block_data(rpc, 'latest')['gasLimit']), True)
    return tx


def mint_trace(rpc, step, receipt):
    trace = rpc('debug_traceTransaction', [receipt['transactionHash'], {'tracer': 'callTracer'}])
    a.need('mint_trace_top', (trace.get('from', '').lower(), trace.get('to', '').lower(), trace.get('input')),
           (step['tx']['from'], u.SAFE, step['tx']['data']))
    a.need('mint_trace_success', bool(trace.get('error')), False)
    if step['id'].endswith('_exec'):
        calls = [n for n in a.trace_nodes(trace) if n.get('to', '').lower() == step['safeTarget']]
        a.need('mint_trace_count', len(calls), 1)
        a.need('mint_trace_call', (calls[0].get('from', '').lower(), calls[0].get('input'), bool(calls[0].get('error'))),
               (u.SAFE, step['inner'], False))


def unbacked_swap_control(rpc, plan):
    """Execute the real 6d operation without B2a on a reverted local snapshot."""
    snap = rpc('evm_snapshot', [])
    try:
        a.need('unbacked_initial', a.word(rpc, plan['pin']['capped'], 'balanceOf(address)', u.SP), 0)
        op = plan['operations']['activation']
        u.wait_until(rpc, max(plan['activationScheduleNotBefore'],
                             u.uints(a.call(rpc, u.SP, 'gasParams()'))[8]))
        u.receipt(rpc, u.fixture_tx(rpc, u.SAFE, u.TL, u.op_call(op, 'schedule')))
        u.wait_until(rpc, a.word(rpc, u.TL, 'getTimestamp(bytes32)', op['id']))
        # Deliberately bypass pre_send only for the negative control.
        u.receipt(rpc, u.fixture_tx(rpc, u.SAFE, u.TL, u.op_call(op, 'execute')))
        tracked = a.word(rpc, u.SP, 'totalTrackedBalance()')
        backing = a.word(rpc, plan['pin']['capped'], 'balanceOf(address)', u.SP)
        a.need('unbacked_shortfall', tracked-backing, BUFFER)
        try:
            b2_gate(rpc, plan, '0x0')
        except a.Gate as error:
            a.need('unbacked_refusal_gate', error.record['gate'], 'B2_capped_buffer')
        else:
            raise a.Gate('unbacked_build_refusal', 'accepted', 'B2 rejection')
        candidate = build_plan(plan['pin'], plan['externalInputs'])
        candidate['steps'] = [s for s in candidate['steps'] if not s['id'].startswith('B2a_')]
        try:
            validate_plan(candidate, plan['externalInputs'])
        except a.Gate as error:
            a.need('unbacked_plan_refusal_gate', error.record['gate'], 'manifest_length')
        else:
            raise a.Gate('unbacked_plan_refusal', 'accepted', 'missing mint rejection')
        return dict(control='unbacked_swap', tracked=tracked, backing=backing,
                    shortfall=tracked-backing, buildRefused=True, gate='B2_capped_buffer',
                    planGate='manifest_length')
    finally:
        a.need('unbacked_restore', rpc('evm_revert', [snap]), True)


def early_swap_control(rpc, plan):
    """Isolate the replacement ETA guard after B1, retaining A15 accounting."""
    snap = rpc('evm_snapshot', [])
    try:
        implementation = u.addr_word(int(rpc('eth_getStorageAt', [u.SP, u.IMPL_SLOT, 'latest']), 16))
        a.need('early_swap_implementation', implementation, plan['implementation'])
        tracked = a.word(rpc, u.SP, 'totalTrackedBalance()')
        revenue = a.word(rpc, u.SP, 'protocolRevenue()')
        a.need('early_swap_accounting', tracked == revenue <= BUFFER, True)
        token = plan['pin']['capped']
        a.need('early_swap_token', token != a.ZERO, True)
        a.need('early_swap_owner', a.address(rpc, u.SP, 'owner()'), u.TL)
        u.receipt(rpc, u.fixture_tx(rpc, u.TL, u.SP, a.calldata('setAPNTsToken(address)', token)))
        a.need('early_swap_pending', a.address(rpc, u.SP, 'pendingAPNTsToken()'), token)
        eta = a.word(rpc, u.SP, 'pendingAPNTsTokenEta()')
        a.need('early_swap_future_eta', a.qty(a.block_data(rpc, 'latest')['timestamp'])+1 < eta, True)
        tx = u.fixture_tx(rpc, u.TL, u.SP, a.calldata('executeAPNTsTokenChange()'))
        result = a.negative(rpc, tx, a.calldata('InvalidConfiguration()'), 'early_swap')
        # The contract shares this error with its accounting guard. Success with
        # identical state after only advancing time establishes the ETA cause.
        u.wait_until(rpc, eta)
        receipt = u.receipt(rpc, tx)
        a.need('early_swap_mature_token', a.address(rpc, u.SP, 'APNTS_TOKEN()'), token)
        a.need('early_swap_mature_pending', a.address(rpc, u.SP, 'pendingAPNTsToken()'), a.ZERO)
        a.need('early_swap_mature_eta', a.word(rpc, u.SP, 'pendingAPNTsTokenEta()'), 0)
        return dict(result, eta=eta, tracked=tracked, revenue=revenue, matureReceipt=receipt)
    finally:
        a.need('early_swap_restore', rpc('evm_revert', [snap]), True)


def controls_at(rpc, plan, sid, controls):
    agg = plan['addresses']['BLSAggregator']
    def negative(name, sender, target, sig, args, error, error_args=()):
        snap = rpc('evm_snapshot', [])
        try:
            tx = u.fixture_tx(rpc, sender, target, a.calldata(sig, *args))
            controls.append(a.negative(rpc, tx, a.calldata(error, *error_args), name))
        finally:
            a.need('control_fixture_restore', rpc('evm_revert', [snap]), True)
    if sid == 'A6.upgrade':
        negative('registry_nonowner', a.EXECUTOR, u.REG, 'upgradeToAndCall(address,bytes)',
            (plan['addresses']['Registry'], '0x'), 'OwnableUnauthorizedAccount(address)', (a.EXECUTOR,))
    if sid == 'A10.0':
        negative('old_reputation', plan['pin']['oldAggregator'], u.REG,
            'batchUpdateGlobalReputation(uint256,address[],uint256[],uint256,bytes)', (1, '[]', '[]', 1, '0x'), 'UnauthorizedSource()')
    if sid == 'A13.stake':
        eta = a.word(rpc, agg, 'pendingFraudProofVerifierReadyAt()')
        negative('early_verifier', u.DEPLOYER, agg, 'applyFraudProofVerifier()', (), 'VerifierRotationNotReady(uint256)', (eta,))
    if sid == 'after_upgrade_execute_exec':
        controls.append(early_swap_control(rpc, plan))
    if sid == 'upgrade_schedule_approve':
        # Exercise the new implementation before factory wiring, then restore the
        # old implementation and every fixture nonce. No mock storage writes.
        snap = rpc('evm_snapshot', [])
        try:
            tx = u.fixture_tx(rpc, u.TL, u.SP, a.calldata('upgradeToAndCall(address,bytes)', plan['implementation'], '0x'))
            u.receipt(rpc, tx)
            factory_error = 'InvalidConfiguration()' if a.address(rpc, u.SP, 'xpntsFactory()') == a.ZERO else 'InvalidXPNTsToken()'
            negative('factory_binding', u.DEPLOYER, u.SP, 'configureOperator(address,address)',
                (plan['addresses']['xPNTsTokenV2'], u.DEPLOYER), factory_error)
        finally:
            a.need('factory_control_restore', rpc('evm_revert', [snap]), True)
    if sid == 'B2a_approve':
        controls.append(unbacked_swap_control(rpc, plan))
    if sid == 'activation_schedule_approve':
        negative('early_unpause', u.DEPLOYER, u.SP, 'setGlobalPaused(bool)', ('false',), 'Unauthorized()')
        negative('early_bls', u.TL, u.SP, 'applyBLSAggregator()', (), 'InvalidConfiguration()')
        snap = rpc('evm_snapshot', [])
        try:
            # Deposits are legal while paused. A restored operator balance must
            # stop both the executor gate and the token swap itself.
            old = a.address(rpc, u.SP, 'APNTS_TOKEN()')
            for target, sig, args in ((old, 'approve(address,uint256)', (u.SP, 1)), (u.SP, 'deposit(uint256)', (1,))):
                u.receipt(rpc, u.fixture_tx(rpc, u.DEPLOYER, target, a.calldata(sig, *args)))
            u.wait_until(rpc, plan['pin']['pendingAPNTsTokenEta'])
            negative('funded_swap', u.TL, u.SP, 'executeAPNTsTokenChange()', (), 'InvalidConfiguration()')
        finally:
            a.need('funded_swap_restore', rpc('evm_revert', [snap]), True)
    if sid == 'after_B4':
        negative('repeat_verifier', u.DEPLOYER, agg, 'applyFraudProofVerifier()', (), 'NoPendingVerifierRotation()')


def run_manifest(remote, rpc, plan, out, calibrate=True):
    a.need('manifest_local_only', getattr(rpc, 'local', False), True)
    validate_plan(plan, plan['externalInputs'], frozen=not calibrate)
    for sender in plan['pin']['senders'].values():
        rpc('anvil_impersonateAccount', [sender['address']])
    pc = plan.get('phaseC')
    if pc is not None:
        rpc('anvil_impersonateAccount', [plan['pin']['phaseC']['owner']['address']])
    context, records, controls = {'passed': set()}, [], []
    overrides = copy.deepcopy(getattr(rpc, 'archive_overrides', {}))
    for step in plan['steps']:
        a.process_alive(rpc.engine_process)
        sid = step['id']
        controls_at(rpc, plan, sid, controls)
        phase_c_controls(rpc, plan, sid, controls, context)
        if not calibrate:
            a.need('frozen_step_not_skipped', step['skipped'], False)
        if sid == 'activation_schedule_approve':
            gas_eta = u.uints(a.call(rpc, u.SP, 'gasParams()'))[8]
            u.wait_until(rpc, max(gas_eta, plan['activationScheduleNotBefore']))
        if sid.endswith('execute_exec'):
            u.wait_until(rpc, a.word(rpc, u.TL, 'getTimestamp(bytes32)', plan['operations'][step['operation']]['id']))
        if sid == 'B4':
            u.wait_until(rpc, a.word(rpc, plan['addresses']['BLSAggregator'], 'pendingFraudProofVerifierReadyAt()'))
            controls.extend(b4_controls(rpc, plan, step))
            record = execute_b4(remote, rpc, plan, step, context, overrides, calibrate, out)
            records.append(record)
            u.log(out, record)
            a.trace_overrides(rpc, record['receipt'], overrides)
            context['passed'].add(sid)
            controls_at(rpc, plan, 'after_B4', controls)
            continue
        pre_send(rpc, plan, step, context)
        timestamp = a.qty(a.block_data(rpc, 'latest')['timestamp'])+1
        evidence = u.measure_step(remote, rpc, plan, step, overrides, timestamp, calibrate)
        pre_send(rpc, plan, step, context, measured=True)
        evidence['freshGas'] = u.fresh_gas(remote, step, overrides, timestamp, pin_block=plan['pin']['block'])
        rpc('evm_setNextBlockTimestamp', [timestamp])
        r = u.receipt(rpc, step['tx'])
        a.need('manifest_receipt_gas', a.qty(r['gasUsed']), step['forkGasUsed'])
        a.need('manifest_timestamp', a.qty(a.block_data(rpc, r['blockNumber'])['timestamp']), timestamp)
        if step['rrRequired']:
            a.need('manifest_rr_witness', u.reservoir_witness(rpc, step['tx'], r), step['rrWitness'])
        a.mined_identity(rpc('eth_getTransactionByHash', [r['transactionHash']]), step['tx'], sid)
        a.need('post_nonce', a.nonce(rpc, step['tx']['from']), a.qty(step['tx']['nonce'])+1)
        a.need('post_safe_nonce', a.word(rpc, u.SAFE, 'nonce()'), step['safeNonce']+int(sid.endswith('_exec')))
        observed = []
        for pred in step['readbacks']:
            if pred['kind'] in ('upgrade', 'activation'):
                observed.append(batch_readback(rpc, plan, pred['kind'] == 'activation', timestamp))
            else:
                observed.append(check_predicate(rpc, pred, timestamp))
        if sid == 'A17':
            context['transferred'] = True
        if sid == 'activation_execute_exec':
            context['activated'] = True
            context['after6d'] = balances(rpc, plan['pin']['pauseList'])
            context['after6d']['cappedBalance'] = a.word(rpc, plan['pin']['capped'], 'balanceOf(address)', u.SP)
            observed6d = context['after6d']
            a.need('after_6d_accounting', [observed6d['totalTrackedBalance'], observed6d['protocolRevenue'],
                   observed6d['cappedBalance'], sum(observed6d['operatorBalances'].values())], [BUFFER, BUFFER, BUFFER, 0])
        if sid == 'A16':
            context['frozen'] = True
            u.check_inventory(rpc, plan['pin'])
        if sid == 'upgrade_execute_exec':
            context['upgradeBlock'] = r['blockNumber']
        if sid == 'activation_schedule_exec':
            context['activationScheduledAt'] = timestamp
            activation_eta_gate(plan, timestamp, a.word(rpc, u.TL, 'getTimestamp(bytes32)', plan['operations']['activation']['id']))
        if 'safeHash' in step:
            if 'safeTarget' in step:
                mint_trace(rpc, step, r)
            elif step.get('operation') == 'registry_accept':
                handover_trace(rpc, plan, step, r)
            else:
                u.safe_trace(rpc, plan, step, r)
            if sid.endswith('_exec'):
                u.safe_exec_events(r['logs'], step['safeHash'])
        context['passed'].add(sid)
        step['skipped'] = False
        record = dict(step=sid, receipt=r, readbacks=observed, **evidence)
        records.append(record)
        u.log(out, record)
        a.trace_overrides(rpc, r, overrides)
        if sid == 'upgrade_execute_exec':
            controls_at(rpc, plan, 'after_upgrade_execute_exec', controls)
        if pc is not None and sid == pc['steps'][-1]:
            context['afterC'] = phase_c_accounting(rpc, plan)
            context['funding'] = funding_gate(rpc, plan)
            context['precheck'] = sp_attempt_precheck(rpc, plan)
            phase_c_controls(rpc, plan, 'after_phase_c', controls, context)
    if pc is not None:
        a.need('phase_c_controls_complete', sorted(x['control'] for x in controls if x['control'] in PC_CONTROLS),
               sorted(PC_CONTROLS))
    if plan['stage'] != 'full':
        a.need('stage_steps_complete', [x['step'] for x in records], [x['id'] for x in plan['steps']])
        closing = dvt_closing(rpc, plan)
        readback = dict(stage_readback(plan, rpc), dvtClosing=closing)
        a.write_json(out/'stage-readback.json', readback)
        budget(plan)
        validate_plan(plan, plan['externalInputs'], frozen=True)
        result = dict(status='PASS', stage=plan['stage'], steps=records, readback=readback)
        if pc is not None:
            result.update(phaseCAccounting=context['afterC'], phaseCFunding=context['funding'], spAttemptPrecheck=context['precheck'],
                          negativeControls=[x for x in controls if x['control'] in PC_CONTROLS])
        return result
    controls.append(handover_controls(rpc, plan))
    a.need('controls_complete', sorted(x['control'] for x in controls), sorted(plan['controls']))
    a.need('steps_complete', [x['step'] for x in records], [x['id'] for x in plan['steps']])
    closing = dvt_closing(rpc, plan)
    assert_manifest_frozen(rpc, plan['pin'], True)
    accounting = balances(rpc, plan['pin']['pauseList'])
    accounting['cappedBalance'] = a.word(rpc, plan['pin']['capped'], 'balanceOf(address)', u.SP)
    funded = BUFFER+plan['phaseC']['operatorTopUp']
    a.need('post_swap_tracked', accounting['totalTrackedBalance'], funded)
    a.need('post_swap_revenue', accounting['protocolRevenue'], BUFFER)
    a.need('post_swap_capped_balance', accounting['cappedBalance'], funded)
    # Phase C's deposit is the only accounting change after 6d; Phase D changes none.
    a.need('accounting_unchanged_since_phase_c', accounting, context['afterC'])
    fraud = fraud_rehearsal(rpc, plan)
    a.write_json(out/'manifest-fraud-proof.json', fraud)
    solvency = solvency_probe(rpc, plan, context['after6d'])
    a.write_json(out/'manifest-solvency.json', solvency)
    a.need('post_swap_solvency', solvency['allSolvent'], True)
    budget(plan)
    validate_plan(plan, plan['externalInputs'], frozen=True)
    result = dict(status='PASS', scope='Phases A/B/C/D', steps=records, negativeControls=controls,
                  B2=context['B2'], postSwapAccounting=accounting, phaseCAccounting=context['afterC'],
                  phaseCFunding=context['funding'], handoverFunding=context.get('handoverFunding', []),
                  spAttemptPrecheck=context['precheck'], fraudProof=fraud, dvtClosing=closing)
    a.write_json(out/'manifest-simulate.json', result)
    return result


def phase_c_accounting(rpc, plan):
    pc = plan['phaseC']
    state = balances(rpc, plan['pin']['pauseList'])
    state['cappedBalance'] = a.word(rpc, plan['pin']['capped'], 'balanceOf(address)', u.SP)
    funded = BUFFER+pc['operatorTopUp']
    expected = {who: (pc['operatorTarget'] if who == u.DEPLOYER else 0) for who in plan['pin']['pauseList']}
    a.need('C_accounting', [state['totalTrackedBalance'], state['protocolRevenue'], state['cappedBalance'], state['operatorBalances']],
           [funded, BUFFER, funded, expected])
    return state


def solvency_probe(rpc, plan, initial):
    """Observe B2a backing through deposit, real slash accrual and excess withdrawal."""
    a.need('solvency_probe_local', getattr(rpc, 'local', False), True)
    snap = rpc('evm_snapshot', [])
    observations = [dict(stage='after_swap', **initial)]
    token = plan['pin']['capped']
    def observe(stage):
        state = balances(rpc, plan['pin']['pauseList'])
        state['cappedBalance'] = a.word(rpc, token, 'balanceOf(address)', u.SP)
        observations.append(dict(stage=stage, **state))
    try:
        minter = a.address(rpc, token, 'minter()')
        a.need('capped_minter', minter, u.SAFE)
        for sender, target, sig, args in (
            (minter, token, 'mint(address,uint256)', (u.DEPLOYER, 10**18)),
            (u.DEPLOYER, token, 'approve(address,uint256)', (u.SP, 10**18)),
            (u.DEPLOYER, u.SP, 'deposit(uint256)', (10**18,))):
            u.receipt(rpc, u.fixture_tx(rpc, sender, target, a.calldata(sig, *args)))
        observe('after_first_deposit')
        # Slashing transfers deposited accounting to revenue without changing backing.
        u.receipt(rpc, u.fixture_tx(rpc, u.TL, u.SP, a.calldata('queueSlash(address)', u.DEPLOYER)))
        u.wait_until(rpc, a.qty(a.block_data(rpc, 'latest')['timestamp'])+DAY)
        u.receipt(rpc, u.fixture_tx(rpc, u.TL, u.SP,
            a.calldata('slashOperator(address,uint8,uint256,string)', u.DEPLOYER, 0, BUFFER, 'solvency fixture')))
        a.need('fixture_revenue_accrued', a.word(rpc, u.SP, 'protocolRevenue()'), 2*BUFFER)
        u.receipt(rpc, u.fixture_tx(rpc, u.TL, u.SP,
            a.calldata('withdrawProtocolRevenue(address,uint256)', u.DEPLOYER, BUFFER)))
        observe('after_revenue_withdrawal')
    finally:
        a.need('solvency_fixture_restore', rpc('evm_revert', [snap]), True)
    for state in observations:
        state['difference'] = state['cappedBalance']-state['totalTrackedBalance']
        state['explanation'] = ('equal' if state['difference'] == 0 else
                                'missing B2a backing' if state['difference'] == -BUFFER else 'unexpected balance difference')
        a.need('solvency_difference_explained', state['difference'] in (0, -BUFFER), True)
        state['solvent'] = state['cappedBalance'] >= state['totalTrackedBalance']
        state['shortfall'] = max(0, state['totalTrackedBalance']-state['cappedBalance'])
        a.need('solvency_accounting_sum', state['totalTrackedBalance'],
               state['protocolRevenue']+sum(state['operatorBalances'].values()))
    return dict(observations=observations, allSolvent=all(x['solvent'] for x in observations),
                invariant='APNTsCapped.balanceOf(SP) >= totalTrackedBalance', restored=True)


def require_final(plan):
    # a3a's check predates stage c; a renamed or relabelled stage artifact is never final.
    a.require_final_artifact(plan)
    a.need('final_stage', plan.get('stage', 'full'), 'full')


def save_artifact(out, plan):
    if plan['stage'] in STAGES[:-1]:
        a.need('stage_not_final', plan['final'], False)
        path = out/('stage-'+plan['stage']+'.json')
        a.write_json(path, plan)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        path.with_name(path.name+'.sha256').write_text(digest+'  '+path.name+'\n')
    else:
        require_final(plan)
        u.save_plan(out, plan)


def load_artifact(path):
    # Integrity is independent of release eligibility and of the filename.
    plan = a.load_plan(path)
    if plan.get('stage') in STAGES[:-1]:
        a.need('stage_not_final', plan.get('final'), False)
    else:
        require_final(plan)
    return plan


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('plan', 'simulate'):
        p = sub.add_parser(name)
        p.add_argument('--stage', choices=STAGES, default='full')
        p.add_argument('--a7-source', type=Path, help='JSON containing plan and readback from A7 fork')
        p.add_argument('--b4-source', type=Path, help='JSON containing plan and readback from B4 fork')
        p.add_argument('--dump-state', type=Path)
        p.add_argument('--hold-fork', action='store_true', help='Keep stage fork alive until Enter')
        p.add_argument('--inputs', type=Path, required=True)
        p.add_argument('--out', type=Path, required=True)
        if name == 'plan':
            p.add_argument('--pin', type=Path, required=True, help='Pinned JSON from collect; offline build only')
        else:
            p.add_argument('--rpc-file', type=Path, required=True)
            p.add_argument('--rpc-file-secondary', type=Path, required=True)
            p.add_argument('--block', type=lambda x: hex(int(x, 0)), required=True)
            p.add_argument('--plan', type=Path)
    for name in ('sign', 'send'):
        sub.add_parser(name).add_argument('--plan', type=Path)
    args = parser.parse_args(argv)
    out = getattr(args, 'out', None)
    try:
        if args.command in ('sign', 'send'):
            if args.plan:
                try:
                    require_final(a.plan_json(args.plan.read_bytes()))
                except a.Gate as error:
                    print('STOP: '+error.record['gate'], file=sys.stderr)
                    return 1
            print('STOP: manifest signing and sending are not implemented', file=sys.stderr)
            return 3
        a.need('output_empty', not out.exists() or (out.is_dir() and not any(out.iterdir())), True)
        out.mkdir(parents=True, exist_ok=True)
        inputs = external(args.inputs, args.stage)
        sources = {name: a.plan_json(path.read_bytes()) for name, path in
                   (('a7', args.a7_source), ('b4', args.b4_source)) if path}
        if args.command == 'plan':
            pin = a.plan_json(args.pin.read_bytes())
            plan = build_plan(pin, inputs, args.stage, sources)
            # A skeleton is explicitly not a calibrated/reviewable release packet.
            if args.stage == 'full':
                a.write_json(out/'manifest-draft.json', plan)
            else:
                save_artifact(out, plan)
        else:
            remote = a.RPC(args.rpc_file.read_text().strip())
            secondary = a.RPC(args.rpc_file_secondary.read_text().strip())
            pin = collect_pair(remote, secondary, args.block, inputs, args.stage)
            plan = load_artifact(args.plan) if args.plan else build_plan(pin, inputs, args.stage, sources)
            replay_frozen = bool(args.plan) and (plan['stage'] == 'full' or 'budgetsWei' in plan)
            a.need('simulation_pin', plan['pin'], pin)
            validate_plan(plan, inputs, frozen=replay_frozen)
            a.need('simulation_stage', plan['stage'], args.stage)
            frozen = copy.deepcopy(plan)
            with a.fork(remote, pin, out) as local:
                run_manifest(remote, local, plan, out, calibrate=not replay_frozen)
                if args.stage != 'full':
                    a.write_json(out/'stage-source.json', stage_source(plan, local))
                    if args.dump_state:
                        a.write_json(args.dump_state, local('anvil_dumpState', []))
                    print(json.dumps(dict(stage=args.stage, A7=plan['addresses']['BLSAggregator'], forkRPC=local.url)), flush=True)
                    if args.hold_fork:
                        input('Stage stopped. Press Enter to terminate the fork: ')
            a.relay_evidence(out)
            a.need('engine_stderr', (out/'engine.stderr').stat().st_size, 0)
            a.need('pin_recheck', collect_pair(remote, secondary, args.block, inputs, args.stage), pin)
            if replay_frozen:
                a.need('frozen_plan_unchanged', plan, frozen)
            save_artifact(out, plan)
        return 0
    except a.Gate as error:
        if error.record['gate'] != 'output_empty':
            a.failure_record(out, error.record)
        print('STOP: '+error.record['gate'], file=sys.stderr)
        return 1
    except Exception as error:
        a.failure_record(out, dict(status='FAILURE', gate='manifest_error', observed=type(error).__name__))
        print('STOP: manifest_error ('+type(error).__name__+')', file=sys.stderr)
        return 1
    except BaseException as error:
        a.failure_record(out, dict(status='FAILURE', gate='interrupted', observed=type(error).__name__))
        return 1


if __name__ == '__main__':
    sys.exit(main())
