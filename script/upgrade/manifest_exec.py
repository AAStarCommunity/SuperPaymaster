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

a = u.a
ANNI = '0xecaacb915f7d92e9916f449f7ad42bd0408733c9'
AGG_VERSION = 'BLSAggregator-4.12.0'
FRAUD_SIG = 'queueGuardianSlash(uint256,address[],bytes)'
EVIDENCE_KINDS = ('conformance', 'mutation', 'slither', 'reproducible-build', 'dvt-ci', 'dvt-conformance-4.12')
BUFFER = 10**17
DAY = 86400
PENDING_OWNER_SLOT = '0xdb5a3168abaa6147a9f3a4cb66016161119d4d50b6393344d27120286f742a00'
DVT = '0x568b1486bfe036e603ea11f0d03dc47fa62c9e0e'
COMMITTEE = '0x7ac7e9d471742fa4397beef0b5b11fbd22d196a9'
OLD_AGGREGATOR = '0xeaec2f512ea50708211fa95533e4dbb60e3d2e5d'
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
    fields += {'conformance':['controls', 'scope'], 'mutation':['controls'], 'slither':['findings', 'scope', 'storageLayout'],
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
    validate_evidence_details(e, kind)
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


def validate_evidence_details(e, kind):
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
                    names = {n.name for n in ast.walk(ast.parse(path.read_text())) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
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
               and all(isinstance(x, str) and not x.startswith('/') and all(part not in ('', '.', '..') for part in x.split('/'))
                       and x.endswith('.sol') for x in files), True)
        recomputed = rebuild()['scope']
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
    a.need("stage", stage in ("a7", "b4", "full"), True)
    required(data, (() if stage == "a7" else ("pop",)) + (("fraudProofFixture",) if stage == "full" else ()), "stage_inputs")
    required(data, ('verifier', 'anni', 'dvt', 'committee', 'sampled', 'depositTargetWei',
                    'releaseTag', 'releaseEvidence', 'registryBaselineCommit', 'a3aPlan'), 'external_inputs_complete')
    v = data['verifier']
    a.exact_keys('verifier_provenance', v, ('commit', 'ciSha256', 'ciPath', 'artifactPath', 'buildSha256'))
    verifier_artifact(v)
    a.need('verifier_build_identity', v['buildSha256'], VERIFIER_SHA256)
    evidence_file(dict(path=v['ciPath'], sha256=v['ciSha256']), 'dvt-ci')
    if stage == 'full':
        fraud_fixture(data['fraudProofFixture'])
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
    version = subprocess.run([str(a.REBUILD_FORGE), '--version'], capture_output=True, text=True, check=True).stdout
    a.need('forge_version', version.splitlines()[0], 'forge Version: 1.7.1')
    arts, cfg = a.compile_commit(head, version, NAMES, tuple(IMMUTABLES.items()))
    # Inspect the same committed source/configuration in an isolated build tree.
    with tempfile.TemporaryDirectory(prefix='manifest-layout-') as directory:
        tree = Path(directory)/'tree'
        a.archive_commit(u.ROOT, head, tree)
        env = {k: os.environ[k] for k in ('HOME', 'PATH', 'TMPDIR', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'SVM_HOME') if k in os.environ}
        env['FOUNDRY_PROFILE'] = 'default'
        # Compute and cache the closure before the pinned archive is removed.
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
    return dict(scope=scope, commit=head, aggregatorVersion=AGG_VERSION, forgeVersion=version.strip(), contracts={name: dict(
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


def old_activity(rpc, old, block):
    start = u.creation(rpc, old, block)
    events = ('SignatureAggregated(uint256,bytes,uint256)', 'GuardianExitRequested(address,uint256,uint256)')
    logs = u.scan(rpc, old, start, block, [[a.keccak(x) for x in events]])
    for log in logs:
        subject = int(log['topics'][1], 16)
        if log['topics'][0] == a.keccak(events[0]):
            a.need('old_proposal_complete', a.word(rpc, old, 'executedProposals(uint256)', subject, block=block), 1)
        else:
            values = u.uints(a.call(rpc, old, 'guardianExitRequests(address)', u.addr_word(subject), block=block))
            a.need('old_exit_cleared', all(v == 0 for v in values), True)
    return dict(creation=start, logs=logs)


def dvt_activity(rpc, dvt, block):
    # DVT owns proposal creation; aggregation events alone cannot find unsigned proposals.
    start = u.creation(rpc, dvt, block)
    proposals = u.scan(rpc, dvt, start, block, [a.keccak('ProposalCreated(uint256,address,uint8)')])
    for log in proposals:
        proposal = int(log['topics'][1], 16)
        words = u.uints(a.call(rpc, dvt, 'proposals(uint256)', proposal, block=block))
        a.need('dvt_proposal_executed', words[3], 1)
    return proposals


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
        gaps = spec.get('nonceGaps', [])
        supplied = [a.qty(g['nonce']) for g in gaps if g['from'] == pin['senders'][label]['address']]
        a.need('prepin_nonce_'+label, supplied, list(range(start, end)))
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
        gaps = [a.qty(g['nonce']) for source in (plan, spec) for g in source.get('nonceGaps', []) if g['from'] == sender['address']]
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


def reconcile_nonces(rpc, pin, inputs):
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
    validate_nonce_history(pin, inputs)


def collect(rpc, block, inputs, stage="full"):
    validate_external(inputs['data'], stage)
    pin = u.collect(rpc, block)
    d = inputs['data']
    block = pin['stateBlock']
    who = d['anni']
    n = a.nonce(rpc, who, block)
    a.need('anni_pending_nonce', a.nonce(rpc, who, 'pending'), n)
    a.need('anni_eoa', u.code(rpc, who, block), '0x')
    pin['senders']['anni'] = dict(address=who, nonce=n, balance=a.qty(rpc('eth_getBalance', [who, block])))
    a.need('registry_version', a.call(rpc, u.REG, 'version()', block=block), a.cast('abi-encode', 'c(string)', 'Registry-5.8.0'))
    pin['registryImplementation'] = u.addr_word(int(rpc('eth_getStorageAt', [u.REG, u.IMPL_SLOT, block]), 16))
    pin['registryImplementationCode'] = u.code(rpc, pin['registryImplementation'], block)
    reconcile_nonces(rpc, pin, inputs)
    pin['oldAggregator'] = a.address(rpc, u.REG, 'blsAggregator()', block)
    a.need('fixed_old_aggregator', pin['oldAggregator'], OLD_AGGREGATOR)
    maximum = a.word(rpc, pin['oldAggregator'], 'MAX_VALIDATORS()', block=block)
    a.need('guardian_maximum', maximum, 13)
    pin['guardianInventory'] = [dict(slot=slot, validator=u.addr_word(a.word(rpc, pin['oldAggregator'], 'validatorAtSlot(uint8)', slot, block=block))) for slot in range(1, maximum+1)]
    pin['oldActivity'] = old_activity(rpc, pin['oldAggregator'], block)
    a.need('old_aggregator_owner', a.address(rpc, pin['oldAggregator'], 'owner()', block), u.DEPLOYER)
    pin['oldActivity']['dvtProposals'] = dvt_activity(rpc, d['dvt'], block)
    pin['bindings'] = {}
    for target, getter in ((d['dvt'], 'BLS_AGGREGATOR()'), (d['committee'], 'blsAggregator()')):
        a.need('pointer_owner', a.address(rpc, target, 'owner()', block), u.DEPLOYER)
        a.need('old_pointer', a.address(rpc, target, getter, block), pin['oldAggregator'])
        pin['bindings'][target] = u.code(rpc, target, block)
    pin.update(balances(rpc, pin['pauseList'], block))
    drain_gate(pin)
    ep = pin['immutables']['entryPoint']
    deposit = u.uints(a.call(rpc, ep, 'getDepositInfo(address)', u.SP, block=block))
    a.need('deposit_info_shape', len(deposit), 5)
    pin['entryPointDeposit'], _, pin['stake'], pin['stakeDelay'], pin['withdrawTime'] = deposit
    a.need('stake_not_unlocking', pin['withdrawTime'], 0)
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
        for key in (u.MEASURED_KEYS - {'executionTimestamp'}) | {'skipped'}:
            step.pop(key, None)
        step['tx'].pop('gas', None)
        for tx in step.get('variants', {}).values():
            tx.pop('gas', None)
    return dict(pin=plan['pin'], addresses=plan['addresses'], steps=steps,
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
    a.need('prefix_boundary', prior['steps'][-1]['id'], 'A7' if stage == 'a7' else 'B4')
    a.need('prefix_exact', prefix_payload(prior), expected)


def stage_readback(plan, rpc):
    a.need('stage_local', getattr(rpc, 'local', False), True)
    domain = a.call(rpc, plan['addresses']['BLSAggregator'], 'domainSeparator()')
    a.need('stage_domain', domain, plan['expectedDomainSeparator'])
    return dict(prefixDigest=plan['prefixDigest'], domainSeparator=domain)


def build_plan(pin, inputs=None, stage='full', stage_sources=None):
    a.need('manifest_inputs_required', inputs is not None, True)
    required(inputs, ('sha256', 'data'), 'external_binding')
    a.typed('0x'+inputs['sha256'], a.HASH32)
    a.need('external_digest_nonzero', int(inputs['sha256'], 16) != 0, True)
    d = inputs['data']
    validate_external(d, stage)
    sources = copy.deepcopy(stage_sources or {})
    a.need("stage_sources", set(sources), set() if stage == "a7" else ({"a7"} if stage == "b4" else ({"a7", "b4"} if sources else set())))
    salt_digest = sources["b4"]["plan"]["externalInputs"]["sha256"] if "b4" in sources else inputs["sha256"]
    a.exact_keys('bindings', pin['bindings'], (DVT, COMMITTEE))
    for code in pin['bindings'].values():
        a.typed(code, a.HEXDATA)
        a.need('binding_nonempty', code != '0x', True)
    a.need('fixed_old_aggregator', pin['oldAggregator'], OLD_AGGREGATOR)
    validate_nonce_history(pin, inputs)
    required(d, ('verifier', 'anni', 'dvt', 'committee', 'sampled', 'depositTargetWei'), 'manifest_external_complete')
    base_pin = {key: copy.deepcopy(pin[key]) for key in u.PIN_KEYS}
    base_pin['senders'].pop('anni', None)
    u.validate_pin(base_pin)
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
    release_gate(inputs, arts, pin)
    counters = {label: x['nonce'] for label, x in pin['senders'].items()}
    steps, addresses, runtimes = [], {}, {}
    safe_n = pin['safeNonce']
    operations = {}
    def finish():
        plan = dict(schema='3.1', route='manifest-A-B-D', stage=stage, final=stage == 'full', stageSources=sources,
            pin=copy.deepcopy(pin), externalInputs=copy.deepcopy(inputs), rebuild=arts,
            creationMetadataLayouts={'OverIssueFraudProofVerifier': copy.deepcopy(VERIFIER_METADATA_LAYOUT)},
            addresses=addresses, implementation=impl, extension=extension, operations=operations,
            steps=steps, controls=CONTROLS,
            expectedDomainSeparator=domain_separator(agg),
            b4Disclosure='B4 always consumes its reserved deployer nonce. If already applied, one empty, zero-value self-transfer costs gas only.',
            gasPolicy=copy.deepcopy(u.GAS_POLICY), gasParams=list(u.GAS),
            activationScheduleNotBefore=max(0, pin['pendingAPNTsTokenEta']-u.DELAY))
        bind_timing(plan)
        plan['prefixDigest'] = prefix_digest(plan)
        for name, source in sources.items():
            rebuilt = build_plan(pin, source['plan']['externalInputs'], name,
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
            **{'from': pin['senders'][sender]['address']})
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
            [dict(kind='code', target=target, expected=rt)], creates=target)
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
    # PHASE C INSERTION POINT: funding/sampling is NOT implemented in this slice.
    # Future Phase C steps must precede D and consume these same nonce counters.
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
        # Calibration requires the unapplied fixture to measure both approved payloads.
        # Snapshot probes never consume the reserved nonce.
        u.measure_step(remote, rpc, plan, step, overrides, timestamp, True)
        step['variants']['apply'] = copy.deepcopy(step['tx'])
    tx = step['variants']['placeholder']
    probe = {k: v for k, v in a.tx_rpc(tx).items() if k != 'gas'}
    gas = a.qty(rpc('eth_estimateGas', [probe, 'latest']))
    trial, _ = u.probe(rpc, tx, gas, timestamp)
    a.need('B4_placeholder_probe', trial['status'], '0x1')
    gas = a.qty(trial['gasUsed'])
    a.need('B4_intrinsic_floor', gas >= 21000, True)
    trial, _ = u.probe(rpc, tx, gas, timestamp)
    a.need('B4_placeholder_exact', (trial['status'], a.qty(trial['gasUsed'])), ('0x1', gas))
    if calibrate:
        tx['gas'] = hex(gas)
    else:
        a.need('B4_frozen_intrinsic', tx['gas'], hex(gas))
    # Do not estimate apply after this read: a concurrent apply can legitimately revert.
    name, tx = select_b4(rpc, plan, step)
    selected = dict(step, tx=tx)
    pre_send(rpc, plan, selected, context)
    a.need('B4_block_gas', a.qty(tx['gas']) <= a.qty(a.block_data(rpc, 'latest')['gasLimit']), True)
    rpc('evm_setNextBlockTimestamp', [timestamp])
    r = u.receipt(rpc, tx, status=None)
    a.mined_identity(rpc('eth_getTransactionByHash', [r['transactionHash']]), tx, 'B4')
    a.need('B4_nonce_consumed', a.nonce(rpc, tx['from']), a.qty(tx['nonce'])+1)
    a.need('B4_safe_nonce', a.word(rpc, u.SAFE, 'nonce()'), step['safeNonce'])
    a.need('B4_receipt_gas', a.qty(r['gasUsed']) <= a.qty(tx['gas']), True)
    # Record even a reverted apply before checking whether its post-state permits continuation.
    record = dict(step='B4', variant=name, transaction=tx, receipt=r)
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
    for label in plan['pin']['senders']:
        cost = sum(max(a.qty(t['gas']) for t in s.get('variants', {'apply': s['tx']}).values())*a.qty(s['tx']['maxFeePerGas'])+a.qty(s['tx']['value'])
                   for s in plan['steps'] if s['sender'] == label and not s.get('skipped', False))
        a.need('budget_'+label, plan['pin']['senders'][label]['balance'] >= cost, True)
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
        extra = u.MEASURED_KEYS | {'skipped'} if frozen else set()
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
        if frozen:
            u.validate_gas(actual)
    if frozen:
        checked = copy.deepcopy(plan)
        budget(checked)
        a.need('manifest_budget', checked['budgetsWei'], plan['budgetsWei'])


def assert_manifest_frozen(rpc, pin, registry_handed_over=False):
    # Keep the shared role/config checks, but follow the completed owner transition.
    u.assert_frozen(rpc, dict(pin, registryOwner=u.TL if registry_handed_over else pin['registryOwner']))


def pre_send(rpc, plan, step, context, measured=False):
    a.need('manifest_local_only', getattr(rpc, 'local', False), True)
    handover_gate(rpc, plan, step, context)
    tx = step['tx']
    a.need('chain', a.qty(rpc('eth_chainId', [])), a.CHAIN)
    a.need('sender_nonce', a.nonce(rpc, tx['from']), a.qty(tx['nonce']))
    a.need('pending_nonce', a.nonce(rpc, tx['from'], 'pending'), a.qty(tx['nonce']))
    a.need('safe_nonce', a.word(rpc, u.SAFE, 'nonce()'), step['safeNonce'])
    a.need('safe_state', u.safe_state(rpc, 'latest'), plan['pin']['safe'])
    u.governance(rpc, 'latest', plan['pin']['timelockCreation'])
    for target, expected in plan['pin']['bindings'].items():
        a.need('bound_runtime', u.code(rpc, target, 'latest'), expected)
    a.need('old_activity_unchanged', old_activity(rpc, plan['pin']['oldAggregator'],
        a.block_data(rpc, 'latest')['number']), {k:v for k,v in plan['pin']['oldActivity'].items() if k != 'dvtProposals'})
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
    context, records, controls = {'passed': set()}, [], []
    overrides = copy.deepcopy(getattr(rpc, 'archive_overrides', {}))
    for step in plan['steps']:
        a.process_alive(rpc.engine_process)
        sid = step['id']
        controls_at(rpc, plan, sid, controls)
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
    if plan['stage'] != 'full':
        a.need('stage_steps_complete', [x['step'] for x in records], [x['id'] for x in plan['steps']])
        readback = stage_readback(plan, rpc)
        a.write_json(out/'stage-readback.json', readback)
        budget(plan)
        validate_plan(plan, plan['externalInputs'], frozen=True)
        return dict(status='PASS', stage=plan['stage'], steps=records, readback=readback)
    controls.append(handover_controls(rpc, plan))
    a.need('controls_complete', sorted(x['control'] for x in controls), sorted(CONTROLS))
    a.need('steps_complete', [x['step'] for x in records], [x['id'] for x in plan['steps']])
    assert_manifest_frozen(rpc, plan['pin'], True)
    accounting = balances(rpc, plan['pin']['pauseList'])
    accounting['cappedBalance'] = a.word(rpc, plan['pin']['capped'], 'balanceOf(address)', u.SP)
    a.need('post_swap_tracked', accounting['totalTrackedBalance'], BUFFER)
    a.need('post_swap_revenue', accounting['protocolRevenue'], BUFFER)
    a.need('post_swap_capped_balance', accounting['cappedBalance'], BUFFER)
    a.need('accounting_unchanged_since_6d', accounting, context['after6d'])
    fraud = fraud_rehearsal(rpc, plan)
    a.write_json(out/'manifest-fraud-proof.json', fraud)
    solvency = solvency_probe(rpc, plan, context['after6d'])
    a.write_json(out/'manifest-solvency.json', solvency)
    a.need('post_swap_solvency', solvency['allSolvent'], True)
    budget(plan)
    validate_plan(plan, plan['externalInputs'], frozen=True)
    result = dict(status='PASS', scope='Phases A/B/D; Phase C not implemented', steps=records, negativeControls=controls,
                  B2=context['B2'], postSwapAccounting=accounting, fraudProof=fraud)
    a.write_json(out/'manifest-simulate.json', result)
    return result


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


def save_artifact(out, plan):
    if plan['stage'] in ('a7', 'b4'):
        a.need('stage_not_final', plan['final'], False)
        path = out/('stage-'+plan['stage']+'.json')
        a.write_json(path, plan)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        path.with_name(path.name+'.sha256').write_text(digest+'  '+path.name+'\n')
    else:
        a.require_final_artifact(plan)
        u.save_plan(out, plan)


def load_artifact(path):
    # Integrity is independent of release eligibility and of the filename.
    plan = a.load_plan(path)
    if plan.get('stage') in ('a7', 'b4'):
        a.need('stage_not_final', plan.get('final'), False)
    else:
        a.require_final_artifact(plan)
    return plan


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('plan', 'simulate'):
        p = sub.add_parser(name)
        p.add_argument('--stage', choices=('a7', 'b4', 'full'), default='full')
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
                    a.require_final_artifact(a.plan_json(args.plan.read_bytes()))
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
            pin = collect(remote, args.block, inputs, args.stage)
            a.need('independent_pin', collect(secondary, args.block, inputs, args.stage), pin)
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
            a.need('pin_recheck', collect(remote, args.block, inputs, args.stage), pin)
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
