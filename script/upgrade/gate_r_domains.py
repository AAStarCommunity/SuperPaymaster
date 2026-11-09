"""Finite domains reclassified from R; enumerations are tied to reviewed source ASTs."""
import copy
import json
from pathlib import Path
import manifest_exec as m

SCHEMA = json.loads(Path(m.__file__).with_name('fraud-proof-fixture.schema.json').read_text())


def schema_nodes():
    def walk(node, path):
        yield path, node
        for key, child in node.get('properties', {}).items():
            yield from walk(child, path + '.' + key)
        if node.get('type') == 'array':
            children = node.get('prefixItems', [node.get('items')] * node['maxItems'])
            for index, child in enumerate(children):
                yield from walk(child, path + '.' + str(index))
    yield from walk(SCHEMA, 'fixture')
    export = copy.deepcopy(SCHEMA['properties']['export'])
    export['properties']['version'] = {'type': 'string', 'pattern': r'BLSAggregator-[0-9]+\.[0-9]+\.[0-9]+'}
    yield from walk(export, 'export')


SCHEMA_RULES = {
    379: lambda n: 'const' in n,
    381: lambda n: 'enum' in n,
    384: lambda n: 'type' in n,
    388: lambda n: n.get('type') == 'object',
    389: lambda n: n.get('type') == 'object',
    394: lambda n: n.get('type') == 'object',
    398: lambda n: n.get('type') == 'array',
    403: lambda n: n.get('type') == 'string' and 'pattern' in n,
    405: lambda n: n.get('type') == 'integer',
}


def labels(line):
    if line in SCHEMA_RULES:
        return sorted({path for path, node in schema_nodes() if SCHEMA_RULES[line](node)})
    if line in (343, 345, 347, 349):
        return list(m.NAMES) + ([] if line == 349 else ['OverIssueFraudProofVerifier'])
    if line == 1993:
        return sorted(set().union(*m.IMMUTABLES.values()) | {'MINTER', 'AGGREGATOR'})
    if line == 2886:
        return ['deployer', 'anni', 'approver', 'executor', 'owner']
    # build_plan.finish/add, bind_timing and the B4 variant constructor.
    if line == 2897:
        return sorted('activationScheduleNotBefore addresses b4Disclosure controls creationMetadataLayouts expectedDiscoveryAfter expectedDomainSeparator extension externalInputs final gasParams gasPolicy implementation operations phaseC pin prefixDigest rebuild route schema stage stageSources timelockRuntimeIdentity'.split())
    if line == 2910:
        return sorted('constructor creates executionTimestamp gasBound id inner operation phase readbacks safeHash safeNonce safeTarget sender warpTarget'.split())
    if line in (2913, 2920):
        return sorted('chainId data from maxFeePerGas maxPriorityFeePerGas nonce to value'.split())
    if line == 2841:
        return READBACK_LABELS
    raise KeyError(line)

# Direct predicate constructor signature constants, plus the finite getter
# columns in build_plan and handover_controls; special batch dispatch kinds
# never reach check_predicate's readback gate.
def readback_labels():
    import ast
    tree = ast.parse(Path(m.__file__).read_text())
    direct = {n.args[1].value for n in ast.walk(tree) if isinstance(n, ast.Call)
              and isinstance(n.func, ast.Name) and n.func.id in ('word_pred', 'address_pred', 'predicate')
              and len(n.args) > 1 and isinstance(n.args[1], ast.Constant) and isinstance(n.args[1].value, str)}
    getters = {'protocolFeeBPS()', 'guardianSlashBps()', 'minThreshold()', 'defaultThreshold()',
               'BLS_AGGREGATOR()', 'blsAggregator()'}
    return sorted(direct | getters | {'code', 'codeHash', 'balance', 'storage'})

READBACK_LABELS = readback_labels()


def isolation_labels(line):
    import old_owner_isolation as o
    names = set(o.NAMES) | set(m.NAMES)
    if line in (525, 530):
        names.add('GTokenAuthorization')
    elif line != 704:
        raise KeyError(line)
    return sorted(names)
