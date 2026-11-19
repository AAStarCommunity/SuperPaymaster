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
    return checksum(value), 'zero' if value.lower() == ZERO else resolutions.get(value.lower())


def address_getters(abi, read, resolutions):
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
        getters[name] = dict(value=value, resolvesTo=resolved)
    return getters, unreadable


def sha(path):
    return '0x' + hashlib.sha256(Path(path).read_bytes()).hexdigest()


def collect(config_path, config, chain, block, provider, deps, pins_path, cast):
    pins = json.loads(pins_path.read_text())['artifacts']
    mapping = json.loads((ROOT/'deployments/readback-artifacts.json').read_text())
    resolutions = {}
    for prefix, source in (('external', deps), ('config', config)):
        for key, value in reversed(list(source.items())):
            if isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]{40}', value): resolutions[value.lower()] = prefix + ':' + key
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
            item['addressGetters'], item['unreadable'] = address_getters(abi, lambda sig: read(address, sig), resolutions)
            if any(f.get('type') == 'function' and f.get('name') == 'version' and not f['inputs'] for f in abi):
                item['version'] = read(address, 'version()(string)')[0]
        item['erc1967'] = {label: checksum('0x' + invoke('storage', address, slot)[-40:]) for label, slot in SLOTS.items()}
        contracts.append(item)
    wiring = {}
    for prefix, key, getters in (
        ('SP', 'superPaymaster', 'REGISTRY APNTS_TOKEN BLS_AGGREGATOR ETH_USD_PRICE_FEED entryPoint EXTENSION xpntsFactory treasury guardian owner agentIdentityRegistry agentReputationRegistry pendingOwner pendingAPNTsToken pendingBLSAgg'),
        ('Registry', 'registry', 'SUPER_PAYMASTER GTOKEN_STAKING MYSBT blsAggregator owner pendingOwner')):
        for getter in getters.split(): wiring[prefix + '.' + getter] = checksum(read(config[key], getter + '()(address)')[0])
    wiring['SP.priceStalenessThreshold'] = str(read(config['superPaymaster'], 'priceStalenessThreshold()(uint256)')[0])
    wiring['TL.minDelay'] = str(read(config['timelockController'], 'getMinDelay()(uint256)')[0])
    return dict(schema='deploylive-readback/1', chainId=str(chain),
                block={k: str(int(block[k], 16)) if k != 'hash' else block[k].lower() for k in ('number', 'hash', 'timestamp')},
                endpointProvider=provider_name(provider), commit=config['commit'], configSha256=sha(config_path),
                runtimePinsSha256=sha(pins_path), contracts=contracts, wiring=wiring)


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
                ok = True
            elif key == 'pnts':
                target = eip1167_target(code(config[key]))
                ok = target is not None and target.lower() == config['xPNTsTokenV2Impl'].lower()
            else:
                ok = matches_pin(pins[name], code(config[key]))
        except (ValueError, KeyError, TypeError):
            ok = False
        rows.append((key, ok))
    return rows
