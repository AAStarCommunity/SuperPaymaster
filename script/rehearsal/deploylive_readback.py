"""Collect ABI-enumerated readback using the checker's block-pinned transport."""
import hashlib
import json
import re
import subprocess
from functools import lru_cache
from pathlib import Path
from deploylive_runtime import release_artifact
from runtime_pins import keccak, masked_code, matches_pin

ROOT = Path(__file__).resolve().parents[2]
ZERO = '0x' + '0' * 40
SLOTS = {'implementation': '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc',
         'admin': '0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103'}
PROXY_ABI = {'registry': 'Registry', 'superPaymaster': 'SuperPaymaster', 'pnts': 'xPNTsTokenV2'}


def provider_name(value):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9 _-]{0,63}', value): raise ValueError('provider NAME required')
    return value


@lru_cache(maxsize=None)
def checksum(address):
    if not re.fullmatch(r'0x[0-9a-fA-F]{40}', address): raise ValueError('invalid address')
    return subprocess.check_output(['cast', 'to-check-sum-address', address], text=True).strip()


def eip1167_target(code):
    match = re.fullmatch(r'0x363d3d373d3d3d363d73([0-9a-f]{40})5af43d82803e903d91602b57fd5bf3', code.lower())
    return checksum('0x' + match[1]) if match else None


def carries_address(field):
    return field['type'].startswith('address') or any(carries_address(c) for c in field.get('components', []))


def carries_array(field):
    return '[' in field['type'] or any(carries_array(c) for c in field.get('components', []))


def abi_type(field):
    return '(' + ','.join(map(abi_type, field['components'])) + ')' + field['type'][5:] if field['type'].startswith('tuple') else field['type']


def project(field, value, resolutions):
    kind = field['type']
    if kind.endswith(']'):
        base = dict(field, type=kind[:kind.rindex('[')])
        pairs = [project(base, v, resolutions) for v in value]
        return [p[0] for p in pairs], [p[1] for p in pairs]
    if kind == 'tuple':
        pairs = {c.get('name') or str(i): project(c, value[i], resolutions)
                 for i, c in enumerate(field['components']) if carries_address(c)}
        return {k: p[0] for k, p in pairs.items()}, {k: p[1] for k, p in pairs.items()}
    return checksum(value), sorted(resolutions.get(value.lower(), ['zero'] if value.lower() == ZERO else []))


def address_getters(abi, read, resolutions, policy=None, unreadable_allowed=None):
    policy = policy or {}
    unreadable_allowed = unreadable_allowed or {}
    getters, unreadable = {}, []
    for f in abi:
        if f.get('type') != 'function' or f['inputs'] or f.get('stateMutability') not in ('view', 'pure') or not any(map(carries_address, f['outputs'])): continue
        name = f['name']
        signature = name + '()(' + ','.join(map(abi_type, f['outputs'])) + ')'
        try:
            values = read(signature)
            if len(f['outputs']) == 1:
                value, resolved = project(f['outputs'][0], values[0], resolutions)
            else:
                value, resolved = project(dict(type='tuple', components=f['outputs']), values, resolutions)
        except (ValueError, RuntimeError, KeyError, IndexError, TypeError):
            value, resolved = None, None
            unreadable.append(name)
        rule = policy.get(name)
        ok = name in unreadable_allowed if name in unreadable else bool(rule) and policy_matches(value, resolved, rule)
        if not ok: raise ValueError('getter policy failed: ' + name)
        getters[name] = dict(value=value, resolvesTo=resolved, policyMatches=True)
    return getters, unreadable


def sha(path):
    return '0x' + hashlib.sha256(Path(path).read_bytes()).hexdigest()


def collect(config_path, config, chain, block, provider, deps, pins_path, cast):
    pins = json.loads(pins_path.read_text())['artifacts']
    mapping = json.loads((ROOT/'deployments/readback-artifacts.json').read_text())
    policy_path = ROOT/'deployments/readback-policy.json'
    policy = json.loads(policy_path.read_text())
    labels = resolutions(config, deps)
    validate_policy(policy, mapping, config, deps)
    def invoke(*args):
        rc, raw = cast(*args)
        if rc: raise ValueError('unreadable readback field')
        return raw
    def read(address, sig):
        raw = invoke('call', address, sig.split(')')[0] + ')')
        return json.loads(invoke('decode-abi', sig, raw, '--json'))
    contracts = []
    for key, name in mapping.items():
        if key not in config: raise ValueError('missing contract config key: ' + key)
        address = checksum(config[key])
        item = dict(configKey=key, address=address, artifact=name)
        fields = ('codeLength', 'runtimeKeccak', 'maskedRuntimeKeccak', 'maskedMatchesPin', 'immutables', 'version', 'addressGetters', 'unreadable', 'erc1967', 'eip1167Target', 'eip1167TemplateMatches')
        if address == ZERO:
            if key not in policy['zeroAllowedConfigKeys']: raise ValueError('zero contract: ' + key)
            item.update(dict.fromkeys(fields)); contracts.append(item); continue
        code = invoke('code', address).lower()
        target = eip1167_target(code)
        item.update(eip1167Target=target, eip1167TemplateMatches=True if target else None)
        pin = pins[name] if name else None
        item.update(codeLength=str(len(bytes.fromhex(code.removeprefix('0x')))), runtimeKeccak=keccak(code),
                    maskedRuntimeKeccak=keccak(masked_code(pin, code)) if pin else None,
                    maskedMatchesPin=matches_pin(pin, code) if pin else None,
                    immutables=[dict(r, value='0x' + bytes.fromhex(code[2:])[int(r['start']):int(r['start']) + int(r['length'])].hex()) for r in pin['immutableRanges']] if pin else None,
                    version=None, addressGetters=None, unreadable=None)
        abi_name = PROXY_ABI.get(key, name)
        if abi_name:
            abi = release_artifact(abi_name)['abi']
            item['addressGetters'], item['unreadable'] = address_getters(abi, lambda sig: read(address, sig), labels, policy['getters'][abi_name], policy['unreadableAllowed'].get(abi_name, {}))
            if any(f.get('type') == 'function' and f.get('name') == 'version' and not f['inputs'] for f in abi):
                item['version'] = read(address, 'version()(string)')[0]
        item['erc1967'] = {label: checksum('0x' + invoke('storage', address, slot)[-40:]) for label, slot in SLOTS.items()}
        contracts.append(item)
    wiring = {}
    for prefix, key, getters in (
        ('SP', 'superPaymaster', 'REGISTRY APNTS_TOKEN BLS_AGGREGATOR ETH_USD_PRICE_FEED entryPoint EXTENSION xpntsFactory treasury guardian owner agentIdentityRegistry agentReputationRegistry pendingOwner pendingAPNTsToken pendingBLSAgg'),
        ('Registry', 'registry', 'SUPER_PAYMASTER GTOKEN_STAKING MYSBT blsAggregator owner pendingOwner')):
        for getter in getters.split(): wiring[prefix + '.' + getter] = next(item for item in contracts if item['configKey'] == key)['addressGetters'][getter]['value']
    wiring['SP.priceStalenessThreshold'] = str(read(config['superPaymaster'], 'priceStalenessThreshold()(uint256)')[0])
    wiring['TL.minDelay'] = str(read(config['timelockController'], 'getMinDelay()(uint256)')[0])
    return dict(schema='deploylive-readback/1', chainId=str(chain),
                block={k: str(int(block[k], 16)) if k != 'hash' else block[k].lower() for k in ('number', 'hash', 'timestamp')},
                endpointProvider=provider_name(provider), commit=config['commit'], configSha256=sha(config_path),
                runtimePinsSha256=sha(pins_path), readbackPolicySha256=sha(policy_path),
                externalDepsSha256=sha(ROOT / (f'contracts/test/fixtures/deploylive/external-deps.31337.agents.json' if chain == 31337 and config.get('enableAgentRegistries') else f'deployments/external-deps.{chain}.json')), contracts=contracts, wiring=wiring)


def write(path, record):
    data = json.dumps(record, indent=2) + '\n'
    if re.search(r'(?i)(?:[a-z][a-z0-9+.-]*://|www\.)', data): raise ValueError('URL in readback')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)


def runtime_rows(config, mapping, pins, code):
    rows = []
    for key, name in mapping.items():
        if name is None and key != 'pnts': continue
        try:
            if config[key].lower() == ZERO:
                ok = key in json.loads((ROOT/'deployments/readback-policy.json').read_text())['zeroAllowedConfigKeys']
            elif key == 'pnts':
                target = eip1167_target(code(config[key]))
                ok = target is not None and target.lower() == config['xPNTsTokenV2Impl'].lower()
            else:
                ok = matches_pin(pins[name], code(config[key]))
        except (ValueError, KeyError, TypeError):
            ok = False
        rows.append((key, ok))
    return rows

RULE = 'resolved ∩ allowed ≠ ∅; resolved = [] fails; array outputs: each element independently'


def resolutions(config, deps):
    labels = {ZERO: {'zero'}}
    for prefix, source in (('config', config), ('external', deps)):
        for key, value in source.items():
            if isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]{40}', value):
                labels.setdefault(value.lower(), set()).add(prefix + ':' + key)
    return {address: sorted(names) for address, names in labels.items()}


def policy_matches(value, resolved, rule):
    if isinstance(value, str):
        return isinstance(resolved, list) and bool(set(resolved) & set(rule['allowed']))
    if isinstance(value, list):
        return isinstance(resolved, list) and len(value) == len(resolved) and (
            all(policy_matches(v, r, rule) for v, r in zip(value, resolved)) if value else rule.get('emptyAllowed') is True)
    if isinstance(value, dict):
        return bool(value) and isinstance(resolved, dict) and value.keys() == resolved.keys() and all(policy_matches(v, resolved[k], rule) for k, v in value.items())
    return False


def address_leaves(field):
    if field['type'].startswith('tuple'): return sum(map(address_leaves, field['components']))
    return 1 if field['type'].startswith('address') else 0


def getter_functions(abi):
    return {f['name']: f for f in abi if f.get('type') == 'function' and not f['inputs']
            and f.get('stateMutability') in ('view', 'pure') and any(map(carries_address, f['outputs']))}


def validate_policy(policy, mapping, config, deps):
    if policy['schema'] != 'readback-policy/1' or policy['rule'] != RULE: raise ValueError('policy schema/rule')
    if any(key not in config or not isinstance(reason, str) or not reason.strip() for key, reason in policy['zeroAllowedConfigKeys'].items()): raise ValueError('zero config policy reason/coverage')
    names = set(mapping.values()) - {None}
    names.update(PROXY_ABI[k] for k in mapping if k in PROXY_ABI)
    if set(policy['getters']) != names or set(policy['unreadableAllowed']) - names: raise ValueError('policy artifact coverage')
    for name in names:
        functions = getter_functions(release_artifact(name)['abi'])
        entries = policy['getters'][name]
        if set(entries) != set(functions) or set(policy['unreadableAllowed'].get(name, {})) - set(functions): raise ValueError('policy getter coverage: ' + name)
        for getter, rule in entries.items():
            allowed = rule['allowed']
            if not rule.get('why') or not isinstance(allowed, list) or (not allowed and rule.get('emptyAllowed') is not True) or len(set(allowed)) != len(allowed): raise ValueError('policy reason/labels')
            if len([a for a in allowed if a != 'zero']) > 2: raise ValueError('policy too broad')
            for label in allowed:
                if label == 'zero':
                    if not rule.get('zeroAllowed') and not any(a.startswith('config:') and a[7:] in policy['zeroAllowedConfigKeys'] for a in allowed): raise ValueError('zero policy inconsistent')
                else:
                    prefix, key = label.split(':')
                    source = {'config': config, 'external': deps}.get(prefix, {})
                    if not isinstance(source.get(key), str) or not re.fullmatch(r'0x[0-9a-fA-F]{40}', source[key]): raise ValueError('unknown policy label: ' + label)
                    if source[key].lower() == ZERO and key not in policy['zeroAllowedConfigKeys'] and not rule.get('zeroAllowed'): raise ValueError('zero label inconsistent')
            if rule.get('zeroAllowed') and ('zero' not in allowed or not isinstance(rule['zeroAllowed'], str)): raise ValueError('zero permission needs reason and label')
            outputs = functions[getter]['outputs']
            # One policy entry applies one `allowed` set and one `emptyAllowed` flag to the whole output, so it is
            # only sound for exactly one address leaf: a tuple, or several address leaves, would let one field
            # pass on another field's label. Such a getter is refused until per-field policy exists (schema /2).
            if any(o['type'].startswith('tuple') for o in outputs) or sum(map(address_leaves, outputs)) != 1:
                raise ValueError('policy unsupported for multi-field address getter: ' + name + '.' + getter)
            if 'emptyAllowed' in rule and (type(rule['emptyAllowed']) is not bool or not any(map(carries_array, outputs))): raise ValueError('empty permission requires array')
        if any(not reason for reason in policy['unreadableAllowed'].get(name, {}).values()): raise ValueError('unreadable reason')


def validate_config(config, mapping, noncontracts, zero_allowed):
    actual = {k for k, v in config.items() if isinstance(v, str) and re.fullmatch(r'0x[0-9a-fA-F]{40}', v)}
    expected = set(mapping) | set(noncontracts)
    if actual != expected: raise ValueError('config address coverage: missing=' + ','.join(sorted(expected-actual)) + ' unknown=' + ','.join(sorted(actual-expected)))
    if any(config[k].lower() == ZERO and k not in zero_allowed for k in actual): raise ValueError('unexpected zero config address')


class Snapshot:
    """One read per request. Freeze before evaluating the assertion pass."""
    def __init__(self, transport):
        self.transport, self.reads, self.frozen = transport, {}, False

    def __call__(self, *args):
        key = tuple(str(a).lower() if re.fullmatch(r'0x[0-9a-fA-F]{40}', str(a)) else str(a) for a in args)
        if key not in self.reads:
            if self.frozen: raise ValueError('read outside frozen snapshot')
            self.reads[key] = self.transport(*args)
        return self.reads[key]

    def freeze(self):
        from types import MappingProxyType
        self.reads = MappingProxyType(self.reads)
        self.frozen = True


def recheck_block(block, transport):
    rc, raw = transport('rpc', 'eth_getBlockByNumber', block['number'], 'false')
    if rc or json.loads(raw)['hash'].lower() != block['hash'].lower(): raise ValueError('block hash changed')


def validate_record(record, config, policy):
    for item in record['contracts']:
        key = item['configKey']
        if item['address'].lower() == ZERO:
            if key not in policy['zeroAllowedConfigKeys']: raise ValueError('zero contract: ' + key)
            continue
        if item['artifact'] and item['maskedMatchesPin'] is not True: raise ValueError('runtime mismatch: ' + key)
        if key == 'pnts' and (item['eip1167TemplateMatches'] is not True or item['eip1167Target'].lower() != config['xPNTsTokenV2Impl'].lower()): raise ValueError('clone mismatch')
        if key in ('registry', 'superPaymaster'):
            expected = config[{'registry': 'registryImpl', 'superPaymaster': 'spImpl'}[key]]
            if item['erc1967']['implementation'].lower() != expected.lower(): raise ValueError('implementation slot mismatch: ' + key)
        name = PROXY_ABI.get(key, item['artifact'])
        for getter, result in item['addressGetters'].items():
            if getter in item['unreadable']:
                if getter not in policy['unreadableAllowed'].get(name, {}): raise ValueError('unreadable getter')
            elif not policy_matches(result['value'], result['resolvesTo'], policy['getters'][name][getter]): raise ValueError('getter policy mismatch: ' + key + '.' + getter)
            # The same artifact ABI describes an initialized proxy and its inert
            # template. Template zero permissions cannot erase proxy wiring.
            if key in ('registry', 'superPaymaster') and result['value'] == ZERO:
                required = [label[7:] for label in policy['getters'][name][getter]['allowed'] if label.startswith('config:')]
                if any(config[k].lower() != ZERO for k in required): raise ValueError('unwired proxy getter: ' + getter)
            if result.get('policyMatches') is not True: raise ValueError('policy not asserted')


def corroborate(record, transport, name):
    rc, header = transport('rpc', 'eth_getBlockByNumber', hex(int(record['block']['number'])), 'false')
    header_ok = rc == 0 and json.loads(header)['hash'].lower() == record['block']['hash']
    runtime_ok, slots_ok = True, True
    for item in record['contracts']:
        if item['address'].lower() == ZERO: continue
        rc, code = transport('code', item['address'])
        runtime_ok &= rc == 0 and keccak(code) == item['runtimeKeccak']
        if item['configKey'] in ('registry', 'superPaymaster'):
            rc, value = transport('storage', item['address'], SLOTS['implementation'])
            slots_ok &= rc == 0 and ('0x' + value[-40:]).lower() == item['erc1967']['implementation'].lower()
    return dict(name=provider_name(name), blockHashMatches=header_ok, runtimeKeccakMatches=runtime_ok, implSlotsMatch=slots_ok)
