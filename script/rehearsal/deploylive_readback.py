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
    value = value.strip().casefold()
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


def expected_chain_id(env):
    """Chain id the operator states they are on; required, never defaulted, never taken from RPC data."""
    if 'DEPLOYLIVE_EXPECTED_CHAIN_ID' not in env:
        raise ValueError('DEPLOYLIVE_EXPECTED_CHAIN_ID required')
    value = env['DEPLOYLIVE_EXPECTED_CHAIN_ID']
    if not isinstance(value, str) or not re.fullmatch(r'[1-9][0-9]*', value):
        raise ValueError('invalid expected chain id')
    return int(value)


def single_provider_allowed(chain, endpoint):
    # Callers must bind RPC chain answers to the operator expectation first.
    return chain == 31337


def independent_providers(primary, secondary, primary_url=None, secondary_url=None):
    approved = json.loads((ROOT/'deployments/readback-providers.json').read_text())
    names = [provider_name(name) for name in (primary, secondary)]
    if names[0] == names[1] or any(name not in approved for name in names):
        raise ValueError('distinct approved provider names required')
    from urllib.parse import urlsplit
    for name, url in zip(names, (primary_url, secondary_url)):
        # Name-only callers validate identity; the checker always supplies both URLs.
        if url is None and primary_url is None and secondary_url is None: continue
        try:
            parsed = urlsplit(url)
            host = (parsed.hostname or '').lower()
            valid = parsed.scheme in ('http', 'https') and not parsed.username and not parsed.password
            valid = valid and not any(c.isspace() for c in url)
            valid = valid and any(host.endswith(suffix) for suffix in approved[name])
        except (ValueError, TypeError):
            valid = False
        if not valid: raise ValueError('provider endpoint binding failed: ' + name)
    if primary_url is not None and urlsplit(primary_url).hostname == urlsplit(secondary_url).hostname:
        raise ValueError('independent provider hostnames required')


def evidence_path(value):
    path = Path(value)
    if not path.is_absolute(): path = ROOT/path
    candidate = path/'readback.json'
    if any(p.is_symlink() for p in (candidate, *candidate.parents)):
        raise ValueError('evidence symlinks refused')
    directory = path.resolve()
    approved = (ROOT/'cache').resolve()
    if directory == approved or not directory.is_relative_to(approved):
        raise ValueError('evidence must be below worktree cache root')
    return directory/'readback.json'


def validate_immutable_policy(pins, policy, config, deps):
    entries = policy['immutableBindings']
    if set(entries) != set(pins): raise ValueError('immutable artifact coverage')
    for artifact, pin in pins.items():
        typed = {}
        for ref in pin['immutableRanges']:
            description = (ref['name'], ref['type'])
            if not all(isinstance(v, str) and v for v in description): raise ValueError('untyped immutable')
            if ref['id'] in typed and typed[ref['id']] != description: raise ValueError('inconsistent immutable type')
            typed[ref['id']] = description
        names = [name for name, kind in typed.values()]
        if len(names) != len(set(names)) or set(entries[artifact]) != set(names):
            raise ValueError('immutable policy coverage: ' + artifact)
        for name, rule in entries[artifact].items():
            if 'unbound' in rule:
                if set(rule) != {'unbound'} or not isinstance(rule['unbound'], str) or not rule['unbound'].strip():
                    raise ValueError('unbound immutable reason/form')
                if name == '_cachedChainId': raise ValueError('chain cache must bind chainId')
                continue
            if 'chainId' in rule:
                if set(rule) != {'chainId', 'why'} or rule['chainId'] is not True or not isinstance(rule['why'], str) or not rule['why'].strip():
                    raise ValueError('chain immutable reason/form')
                continue
            if name == '_cachedChainId': raise ValueError('chain cache must bind chainId')
            if 'expectedUint' in rule:
                if set(rule) != {'expectedUint', 'why'} or not isinstance(rule['why'], str) or not rule['why'].strip() or not isinstance(rule['expectedUint'], str) or not re.fullmatch(r'0|[1-9][0-9]*', rule['expectedUint']) or int(rule['expectedUint']) >= 2**256:
                    raise ValueError('uint immutable policy reason/form')
                continue
            if 'codehashOf' in rule:
                label = rule['codehashOf']
                if set(rule) != {'codehashOf', 'why'} or not isinstance(rule['why'], str) or not rule['why'].strip():
                    raise ValueError('codehash policy reason/form')
                if not isinstance(label, str) or not label.startswith('config:') or not re.fullmatch(r'0x[0-9a-fA-F]{40}', config.get(label[7:], '')) or config[label[7:]].lower() == ZERO:
                    raise ValueError('unknown codehash target')
                continue
            if set(rule) != {'allowed', 'why'}: raise ValueError('address immutable rule form')
            allowed = rule['allowed']
            if not isinstance(rule.get('why'), str) or not rule['why'].strip() or not isinstance(allowed, list) or not allowed or len(set(allowed)) != len(allowed):
                raise ValueError('immutable policy reason/labels')
            for label in allowed:
                if label == 'zero': continue
                prefix, key = label.split(':')
                value = {'config': config, 'external': deps}.get(prefix, {}).get(key)
                if not isinstance(value, str) or not re.fullmatch(r'0x[0-9a-fA-F]{40}', value): raise ValueError('unknown immutable label')
                if value.lower() == ZERO and 'zero' not in allowed: raise ValueError('implicit zero immutable label')


def immutable_bindings(pin, code, entries, labels, *, chain=None, artifact="unknown"):
    raw = bytes.fromhex(code.removeprefix('0x'))
    words, bindings = {}, {}
    expected = {r['name'] for r in pin['immutableRanges']}
    if set(entries) != expected: raise ValueError('immutable policy coverage')
    for ref in pin['immutableRanges']:
        if ref['name'] not in expected: continue
        start, length = int(ref['start']), int(ref['length'])
        word = raw[start:start + length]
        if start < 0 or length != 32 or len(word) != 32 or ('allowed' in entries[ref['name']] and any(word[:12])): raise ValueError('noncanonical address immutable')
        if ref['id'] in words and word != words[ref['id']]: raise ValueError('inconsistent immutable references')
        words[ref['id']] = word
        name = ref['name']
        if 'unbound' in entries[name]:
            if not any(word[:12]) and any(word[12:]):
                raise ValueError('unbound immutable has address shape: ' + artifact + '.' + name)
            bindings[name] = dict(value='0x' + word.hex(), unbound=entries[name]['unbound'], policyMatches=True)
            continue
        if 'chainId' in entries[name]:
            if chain is None or int.from_bytes(word, 'big') != int(chain):
                raise ValueError('immutable binding failed: ' + name)
            bindings[name] = dict(value=str(chain), chainId=True, policyMatches=True)
            continue
        if 'expectedUint' in entries[name]:
            value = str(int.from_bytes(word, 'big'))
            if value != entries[name]['expectedUint']: raise ValueError('immutable binding failed: ' + name)
            bindings[name] = dict(value=value, expectedUint=entries[name]['expectedUint'], policyMatches=True)
            continue
        if 'codehashOf' in entries[name]:
            bindings[name] = dict(value='0x' + word.hex(), codehashOf=entries[name]['codehashOf'], policyMatches=True)
            continue
        value = checksum('0x' + word[12:].hex())
        resolved = labels.get(value.lower(), [])
        rule = entries[name]
        if value == ZERO and ('zero' not in rule['allowed'] or not rule.get('why')): raise ValueError('zero immutable')
        if not policy_matches(value, resolved, rule): raise ValueError('immutable binding failed: ' + name)
        bindings[name] = dict(value=value, resolvesTo=resolved, policyMatches=True)
    return bindings


def collect(config_path, config, chain, block, provider, deps, pins_path, cast):
    pins = json.loads(pins_path.read_text())['artifacts']
    mapping = json.loads((ROOT/'deployments/readback-artifacts.json').read_text())
    policy_path = ROOT/'deployments/readback-policy.json'
    policy = json.loads(policy_path.read_text())
    labels = resolutions(config, deps)
    validate_policy(policy, mapping, config, deps)
    validate_immutable_policy(pins, policy, config, deps)
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
        fields = ('codeLength', 'runtimeKeccak', 'maskedRuntimeKeccak', 'maskedMatchesPin', 'immutables', 'immutableBindings', 'version', 'addressGetters', 'unreadable', 'erc1967', 'eip1167Target', 'eip1167TemplateMatches')
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
        item['immutableBindings'] = immutable_bindings(pin, code, policy['immutableBindings'][name], labels, chain=chain, artifact=name) if pin else {}
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
    def address(v): return isinstance(v, str) and re.fullmatch(r'0x[0-9a-fA-F]{40}', v)
    # DeployLive serializes eight flat arrays and one exact compile-settings object.
    arrays = {'guardians', 'gTokenMintRecipients', 'stakeAccounts', 'ticketTreasuries',
              'gTokenMintAmounts', 'stakeAmounts', 'ticketAmounts', 'stakeRoles'}
    for key, value in config.items():
        if key == 'stakeRoles' and (not isinstance(value, list) or not all(isinstance(v, str) and re.fullmatch(r'0x[0-9a-fA-F]{64}', v) for v in value)):
            raise ValueError('nested config coverage: ' + key)
        if key == 'artifactCompileSettings':
            from creation_pins import release_names
            expected = {n: dict(evmVersion='cancun', viaIR=True,
                               optimizerRuns=200 if n in ('Registry', 'TimelockHandoverBootstrap') else 500)
                        for n in release_names()}
            if value != expected: raise ValueError('nested config coverage: ' + key)
            continue
        if isinstance(value, dict) or isinstance(value, list) and (
                key not in arrays or any(isinstance(v, (dict, list)) for v in value)):
            raise ValueError('nested config coverage: ' + key)
    actual = {k for k, v in config.items() if address(v) or isinstance(v, list) and (not v or any(address(x) for x in v))}
    # Empty amount and role ledgers have a fixed serialization schema too.
    actual -= {k for k in ('gTokenMintAmounts', 'stakeAmounts', 'ticketAmounts', 'stakeRoles') if config.get(k) == []}
    expected = set(mapping) | set(noncontracts)
    if actual != expected: raise ValueError('config address coverage: missing=' + ','.join(sorted(expected-actual)) + ' unknown=' + ','.join(sorted(actual-expected)))
    for key in actual:
        values = config[key] if isinstance(config[key], list) else [config[key]]
        if not all(address(v) for v in values): raise ValueError('invalid config address array')
        if any(v.lower() == ZERO for v in values) and key not in zero_allowed: raise ValueError('unexpected zero config address')


def validate_snapshot_request(block, args, *, requested_hash=None, log_heights=()):
    """Reject unknown reads and selectors before any state transport, even locally."""
    method = args[0]
    if method == 'eth_chainId':
        if len(args) != 1: raise ValueError('invalid chain request')
        return
    if method in ('eth_getBlockByNumber', 'eth_getBlockByHash'):
        if len(args) != 3 or args[2] != 'false': raise ValueError('invalid header request')
        selector = args[1]
        if not isinstance(selector, str): raise ValueError('header selector must be a string')
        if block is None:
            allowed = (method == 'eth_getBlockByHash' and requested_hash is not None and selector.lower() == requested_hash.lower()
                       or method == 'eth_getBlockByNumber' and requested_hash is None and selector == 'latest')
        elif method == 'eth_getBlockByHash':
            allowed = selector.lower() == block['hash'].lower()
        else:
            allowed = bool(re.fullmatch(r'0x(0|[1-9a-f][0-9a-f]*)', selector))
            if allowed:
                height, pin = int(selector, 16), int(block['number'], 16)
                allowed = height == pin or (height <= pin and height in log_heights)
        if not allowed: raise ValueError('unpinned header request')
        return
    methods = {'eth_call': 2, 'eth_getStorageAt': 3, 'eth_getBalance': 2, 'eth_getLogs': 1, 'eth_getCode': 2}
    if method not in methods: raise ValueError('unreplayed snapshot request: ' + method)
    if len(args) != methods[method] + 1: raise ValueError('invalid state request: ' + method)
    if block is None: raise ValueError('state request before snapshot pin')
    if method == 'eth_getLogs':
        query = json.loads(args[1])
        if not 0 <= int(query['fromBlock'], 16) <= int(query['toBlock'], 16) == int(block['number'], 16):
            raise ValueError('unpinned request: ' + method)
    elif json.loads(args[-1]) != dict(blockHash=block['hash'], requireCanonical=True):
        raise ValueError('unpinned request: ' + method)


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


def header_fields(block):
    """All header fields consumed by assertions/evidence; DATA preserves length."""
    if not re.fullmatch(r'0x[0-9a-fA-F]{64}', block['hash']): raise ValueError('invalid header hash')
    def quantity(value):
        return str(int(str(value), 16 if str(value).startswith('0x') else 10))
    return dict(number=quantity(block['number']), hash=block['hash'].lower(), timestamp=quantity(block['timestamp']))


def recheck_block(block, transport):
    rc, raw = transport('rpc', 'eth_getBlockByNumber', block['number'], 'false')
    try:
        if rc or header_fields(json.loads(raw)) != header_fields(block): raise ValueError()
    except (ValueError, KeyError, TypeError):
        raise ValueError('block header changed') from None


def codehash_binding_matches(record, item, name, rule):
    target = next((c for c in record['contracts'] if 'config:' + c['configKey'] == rule['codehashOf']), None)
    result = item['immutableBindings'].get(name, {})
    return bool(target and target['address'].lower() != ZERO and target['runtimeKeccak']
                and result.get('codehashOf') == rule['codehashOf'] and result.get('policyMatches') is True
                and result.get('value', '').lower() == target['runtimeKeccak'].lower())


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
        expected_bindings = policy['immutableBindings'].get(item['artifact'], {})
        if set(item['immutableBindings']) != set(expected_bindings): raise ValueError('record immutable coverage')
        for name, result in item['immutableBindings'].items():
            rule = expected_bindings[name]
            if 'unbound' in rule:
                word = bytes.fromhex(result['value'].removeprefix('0x'))
                if len(word) != 32 or (not any(word[:12]) and any(word[12:])) or result != dict(value=result['value'], unbound=rule['unbound'], policyMatches=True):
                    raise ValueError('record unbound immutable mismatch: ' + name)
                continue
            if 'chainId' in rule:
                if result != dict(value=record['chainId'], chainId=True, policyMatches=True):
                    raise ValueError('record chain immutable mismatch: ' + name)
                continue
            if 'expectedUint' in rule:
                if result != dict(value=rule['expectedUint'], expectedUint=rule['expectedUint'], policyMatches=True):
                    raise ValueError('record uint immutable mismatch: ' + name)
                continue
            if 'codehashOf' in rule:
                if not codehash_binding_matches(record, item, name, rule):
                    raise ValueError('record immutable codehash mismatch: ' + name)
                continue
            if result.get('policyMatches') is not True or not policy_matches(result['value'], result['resolvesTo'], rule):
                raise ValueError('record immutable policy mismatch')
            if result['value'] == ZERO and 'zero' not in rule['allowed']: raise ValueError('record zero immutable')
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


def replay_snapshot(block, reads, primary, secondary, name):
    """Replay all recorded state requests; bracket historical logs with canonical checks."""
    methods = {'eth_call', 'eth_getStorageAt', 'eth_getBalance', 'eth_getLogs', 'eth_getCode'}
    pin = dict(blockHash=block['hash'], requireCanonical=True)
    height = hex(int(str(block['number']), 0) if str(block['number']).startswith('0x') else int(block['number']))

    def normalize(value, method, field=None):
        if isinstance(value, dict): return {k: normalize(v, method, k) for k, v in value.items()}
        if isinstance(value, list): return [normalize(v, method, field) for v in value]
        quantity = (method == 'eth_getBalance' or
                    method == 'eth_getLogs' and field in ('blockNumber', 'logIndex', 'transactionIndex'))
        if isinstance(value, str) and value.startswith('0x'):
            return hex(int(value, 16)) if quantity else value.lower()
        return value

    def header(rpc, number):
        rc, raw = rpc('eth_getBlockByNumber', number, 'false')
        try:
            value = json.loads(raw)
            if rc: raise ValueError()
            fields = header_fields(value)
            if fields['number'] != str(int(number, 16)): raise ValueError()
            return fields
        except (ValueError, KeyError, TypeError):
            raise ValueError('canonical header failed: block ' + number) from None

    def paired_header(number):
        first, second = header(primary, number), header(secondary, number)
        if first != second: raise ValueError('canonical header mismatch: block ' + number)
        return first

    def end_check():
        if paired_header(height) != header_fields(block):
            raise ValueError('canonical header mismatch: block ' + height)

    def result(response, label):
        rc, raw = response
        if rc: return (False, raw)
        try: return (True, normalize(json.loads(raw), method))
        except (ValueError, TypeError): raise ValueError('invalid replay result: ' + label) from None

    def logs_canonical(logs, cache):
        for log in logs:
            try:
                number = hex(int(log['blockNumber'], 16))
                if number not in cache: cache[number] = paired_header(number)['hash']
                if log['blockHash'].lower() != cache[number]:
                    raise ValueError('log canonical hash mismatch: block ' + number)
            except (KeyError, TypeError):
                raise ValueError('invalid canonical log') from None

    end_check()
    canonical_logs = {}
    count = 0
    for args, recorded in reads.items():
        method = args[0]
        if method not in methods:
            if method == 'eth_getBlockByNumber':
                try:
                    if recorded[0]: raise ValueError()
                    used = header_fields(json.loads(recorded[1]))
                    if args[1].startswith('0x') and int(args[1], 16) != int(used['number']): raise ValueError()
                    if paired_header(hex(int(used['number']))) != used: raise ValueError()
                except (ValueError, KeyError, TypeError):
                    raise ValueError('recorded header mismatch') from None
                continue
            if method in ('eth_chainId', 'eth_blockNumber'): continue
            raise ValueError('unreplayed snapshot request: ' + method)
        if method == 'eth_call':
            query = json.loads(args[1]); label = method + ' ' + query['to'] + ' ' + query['data'][:10]
        elif method == 'eth_getLogs':
            query = json.loads(args[1])
            import hashlib
            topics = normalize(query.get('topics', []), method, 'topics')
            digest = hashlib.sha256(json.dumps(topics, separators=(',', ':')).encode()).hexdigest()
            label = (method + ' ' + str(query.get('address', 'all addresses')) +
                     ' fromBlock=' + hex(int(query['fromBlock'], 16)) +
                     ' toBlock=' + hex(int(query['toBlock'], 16)) + ' topics=' + digest)
        else:
            label = method + ' ' + args[1] + (' ' + args[2] if method == 'eth_getStorageAt' else '')
        if method != 'eth_getLogs':
            if json.loads(args[-1]) != pin: raise ValueError('unpinned request: ' + label)
            responses = [recorded, secondary(*args)]
        else:
            if int(query['toBlock'], 16) != int(height, 16): raise ValueError('unpinned request: ' + label)
            responses = [primary(*args), secondary(*args)]
            if result(recorded, label) != result(responses[0], label): raise ValueError('snapshot replay mismatch: ' + label)
            for response in responses:
                if response[0]: raise ValueError('log replay failed: ' + label)
                logs_canonical(json.loads(response[1]), canonical_logs)
        if result(responses[0], label) != result(responses[1], label):
            raise ValueError('provider replay mismatch: ' + label)
        count += 1
    end_check()
    return dict(name=provider_name(name), requests=count, allEqual=True, blockHashMatches=True)
