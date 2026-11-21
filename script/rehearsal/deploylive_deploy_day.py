"""Deploy-day gates shared by the production and fork drivers; transport is injectable."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tomllib
from deploylive_runtime import clean_source_commit

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / 'deployments/forge-deploy-pin.json'
LARGE_CREATES = ('Registry', 'xPNTsFactory', 'MySBT', 'SuperPaymaster',
                 'xPNTsTokenV2Ext', 'xPNTsTokenV2', 'BLSAggregator', 'TimelockHandoverBootstrap')


def redact_error(error):
    text = re.sub(r'(?i)bearer\s+[^\s,}]+', 'Bearer <redacted>', str(error))
    text = re.sub(r"https?://[^\s\"'<>]+", '<redacted-url>', text, flags=re.I)
    # Exempt exactly the checker separator and equality comparisons.
    text = re.sub(r"(?i)((?:api[_-]?key|token|password|secret|authorization|private[_-]?key)[\"']?(?! :: )(?!\s*==)\s*[:=]\s*[\"']?)([^\s,}\"']+)",
                  r'\1<redacted>', text)
    return text


def require(ok, message):
    if not ok:
        raise RuntimeError('STOP ' + message)


def integer(value):
    return int(value, 16 if value.startswith('0x') else 10) if isinstance(value, str) else int(value)


def checker_pass(result):
    summaries = re.findall(r'^SUMMARY (\d+) passed, (\d+) failed, (\d+) total$', result.stdout, re.M)
    require(result.returncode == 0 and len(summaries) == 1
            and int(summaries[0][0]) > 0 and int(summaries[0][1]) == 0
            and summaries[0][0] == summaries[0][2], 'post-deploy checker did not PASS')


def config_path(env):
    name = env.get('ENV', '')
    require(bool(re.fullmatch(r'[A-Za-z0-9_-]+', name)), 'set ENV')
    return ROOT / 'deployments/live' / f'config.{name}.json'


def forge_identity(env):
    binary = shutil.which(env.get('FORGE', 'forge'), path=env.get('PATH', os.defpath))
    require(binary is not None, 'forge not found')
    path = Path(binary).resolve()
    version = subprocess.run([str(path), '--version'], capture_output=True, text=True, check=True).stdout.strip()
    return dict(path=str(path), version=version, sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def check_pin(identity, production):
    pin = json.loads(PIN.read_text())
    require(pin['commit'] in identity['version'] and identity['sha256'] == pin['sha256'], 'deploy engine pin mismatch')


def build_paths(env):
    out = (ROOT / env.get('FOUNDRY_OUT', 'out')).resolve()
    cache = (ROOT / env.get('FOUNDRY_CACHE_PATH', 'cache')).resolve()
    release = (ROOT / env.get('DEFAULT_ARTIFACTS_OUT', 'out')).resolve()
    default_cache = (ROOT / env.get('DEFAULT_CACHE_PATH', 'cache')).resolve()
    # The execution cache may be inside cache/, but must not reuse its root.
    require(out != release and not out.is_relative_to(release) and not release.is_relative_to(out)
            and cache != default_cache and not default_cache.is_relative_to(cache)
            and out != cache and not out.is_relative_to(cache) and not cache.is_relative_to(out),
            'separate Prague out/cache and Cancun out/cache required')
    require(out.is_relative_to(ROOT) and cache.is_relative_to(ROOT), 'build directories must be inside worktree')
    return out, cache


def stamp_path(env):
    out, _ = build_paths(env)
    return out.with_name(out.name + '.build-stamp.json')


def print_command(command):
    hidden = False
    safe = []
    for word in command:
        safe.append('<redacted>' if hidden else str(word))
        hidden = word in ('--rpc-url', '--account', '--private-key', '--password')
    print('COMMAND ' + shlex.join(safe), flush=True)


def clean_build_directories(env):
    targets = []
    for key, default in (('FOUNDRY_OUT', 'out'), ('FOUNDRY_CACHE_PATH', 'cache'),
                         ('DEFAULT_ARTIFACTS_OUT', 'out'), ('DEFAULT_CACHE_PATH', 'cache')):
        raw = Path(env.get(key, default))
        target = (ROOT / raw).resolve()
        require('..' not in raw.parts and target != ROOT and target.is_relative_to(ROOT)
                and not (ROOT / raw).is_symlink(), 'unsafe build directory: ' + key)
        require(not target.exists() or target.is_dir(), 'build target is not a directory: ' + key)
        targets.append(target)
    build_paths(env)
    for target in targets:
        if target.exists():
            shutil.rmtree(target)


def build(env, production):
    out, cache = build_paths(env)
    identity = forge_identity(env)
    check_pin(identity, production)
    clean_build_directories(env)
    stamp = stamp_path(env)
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.unlink(missing_ok=True)
    release_out = (ROOT / env.get('DEFAULT_ARTIFACTS_OUT', 'out')).resolve()
    release_cache = (ROOT / env.get('DEFAULT_CACHE_PATH', 'cache')).resolve()
    release_env = dict(env, FOUNDRY_OUT=str(release_out), FOUNDRY_CACHE_PATH=str(release_cache))
    release_stamp = release_out.with_name(release_out.name + '.build-stamp.json')
    release_stamp.unlink(missing_ok=True)
    print_command([identity['path'], 'build', '--offline', '--evm-version', 'cancun'])
    release_result = subprocess.run([identity['path'], 'build', '--offline', '--evm-version', 'cancun'], cwd=ROOT, env=release_env)
    require(release_result.returncode == 0, 'Cancun build failed')
    release_record = dict(forge=identity, out=str(release_out), cache=str(release_cache), evmVersion='cancun', **source_stamp())
    release_stamp.write_text(json.dumps(release_record, indent=2) + '\n')
    print_command([identity['path'], 'build', '--offline', '--evm-version', 'prague'])
    result = subprocess.run([identity['path'], 'build', '--offline', '--evm-version', 'prague'], cwd=ROOT, env=env)
    require(result.returncode == 0, 'Prague build failed')
    require(forge_identity(env) == identity, 'build forge changed during build')
    record = dict(forge=identity, out=str(out), cache=str(cache), evmVersion='prague', **source_stamp())
    stamp.write_text(json.dumps(record, indent=2) + '\n')
    print('BUILD ' + json.dumps(release_record))
    print('BUILD ' + json.dumps(record))


def verify_build(env, production):
    identity = forge_identity(env)
    check_pin(identity, production)
    out, cache = build_paths(env)
    try:
        record = json.loads(stamp_path(env).read_text())
    except (OSError, ValueError):
        raise RuntimeError('STOP missing build stamp; build with this driver') from None
    require(record == dict(forge=identity, out=str(out), cache=str(cache), evmVersion='prague', **source_stamp()),
            'build forge/settings differs from script forge/settings')
    release_out = (ROOT / env.get('DEFAULT_ARTIFACTS_OUT', 'out')).resolve()
    release_cache = (ROOT / env.get('DEFAULT_CACHE_PATH', 'cache')).resolve()
    try:
        release_record = json.loads(release_out.with_name(release_out.name + '.build-stamp.json').read_text())
    except (OSError, ValueError):
        raise RuntimeError('STOP missing Cancun build stamp') from None
    require(release_record == dict(forge=identity, out=str(release_out), cache=str(release_cache), evmVersion='cancun', **source_stamp()),
            'Cancun build forge/settings differs from script forge/settings')
    print('SCRIPT ' + json.dumps(identity))
    return identity['path']


def contract_name(name):
    profiles = tomllib.loads((ROOT / 'foundry.toml').read_text())['profile']
    names = set(profiles)
    for profile in profiles.values():
        names.update(p['name'] for p in profile.get('additional_compiler_profiles', []))
    base, dot, suffix = (name or '').rpartition('.')
    return base if dot and suffix in names else name


def large_creates(plan):
    targets = [(i, tx) for i, tx in enumerate(plan['transactions'])
               if tx.get('transactionType') == 'CREATE' and contract_name(tx.get('contractName')) in LARGE_CREATES]
    require(sorted(contract_name(tx['contractName']) for _, tx in targets) == sorted(LARGE_CREATES),
            'large CREATE inventory incomplete or duplicated')
    return targets


def superpaymaster_proxy(plan):
    implementations = [tx['contractAddress'].lower() for tx in plan['transactions']
                       if tx.get('transactionType') == 'CREATE' and contract_name(tx.get('contractName')) == 'SuperPaymaster']
    require(len(implementations) == 1, 'planned SP implementation must occur exactly once')
    proxies = [tx['contractAddress'] for tx in plan['transactions']
               if tx.get('transactionType') == 'CREATE' and contract_name(tx.get('contractName')) == 'ERC1967Proxy'
               and tx.get('arguments') and tx['arguments'][0].lower() == implementations[0]]
    require(len(proxies) == 1, 'planned SP proxy must occur exactly once')
    return proxies[0]


def price_window(plan, rpc, corroborating_rpc, feed, threshold, emit=print, sp_proxy=None):
    if corroborating_rpc is rpc:
        corroborating_rpc = None
    proxy = sp_proxy or superpaymaster_proxy(plan)
    selector = subprocess.check_output(['cast', 'sig', 'updatePrice()'], text=True).strip().lower()
    require(bool(re.fullmatch(r'0x[0-9a-f]{8}', selector)), 'invalid updatePrice selector')
    indices = [i for i, tx in enumerate(plan['transactions'])
               if tx.get('transactionType') == 'CALL'
               and (tx['transaction'].get('to') or '').lower() == proxy.lower()
               and (tx['transaction'].get('input') or tx['transaction'].get('data') or '')[:10].lower() == selector]
    require(len(indices) == 1, 'planned SP.updatePrice must occur exactly once')
    head = rpc('eth_getBlockByNumber', 'latest', False)
    block = head['number']
    old_number = integer(block) - 100
    require(old_number >= 0, '100-block history required')
    old = rpc('eth_getBlockByNumber', hex(old_number), False)
    data = {'to': feed, 'data': '0xfeaf968c'}  # latestRoundData()
    raw = rpc('eth_call', data, block)
    if corroborating_rpc is not None:
        other_head = corroborating_rpc('eth_getBlockByNumber', block, False)
        other_old = corroborating_rpc('eth_getBlockByNumber', hex(old_number), False)
        other_raw = corroborating_rpc('eth_call', data, block)
        require(all(head[k] == other_head[k] and old[k] == other_old[k] for k in ('number', 'hash', 'timestamp'))
                and raw == other_raw, 'price endpoints disagree at fixed block')
    require(isinstance(raw, str) and re.fullmatch(r'0x[0-9a-fA-F]{320}', raw), 'invalid feed round')
    values = [int(raw[i:i+64], 16) for i in range(2, len(raw), 64)]
    updated = values[3]
    require(values[1] > 0 and values[1] < 2**255 and values[4] >= values[0] and updated > 0, 'invalid feed round')
    head_time = integer(head['timestamp'])
    elapsed = head_time - integer(old['timestamp'])
    block_time = elapsed / 100
    age = head_time - updated
    require(block_time > 0 and age >= 0 and threshold > 0, 'invalid price timing')
    margin_hundredths = threshold * 100 - (indices[0] * elapsed * 3 + age * 100)
    margin = margin_hundredths / 100
    emit(f'PRICE price_init_index={indices[0]} block_time={block_time:g} factor=3 head.timestamp={head_time} updatedAt={updated} age={age} threshold={threshold} margin={margin:g}')
    if corroborating_rpc is None:
        emit('PRICE corroboration not applicable on a fork; single fork endpoint')
    require(margin_hundredths >= 0, 'wait for the next feed update')
    return block, block_time


TX_GAS_CAP = 2**24  # EIP-7825 regular-gas cap
CAP_FRACTION = 0.9  # a limit <= the cap leaves no state-gas reservoir: total gas must fit with headroom


def gas_semantics(chain):
    # an OP-chain fork rehearsal must use the real chain id (anvil fork keeps it);
    # 31337 means a local chain with Amsterdam semantics only.
    # The sole chain-to-semantics mapping, shared by gas gates and cap/hardfork controls.
    semantics = {10: 'karst', 11155420: 'karst', 11155111: 'amsterdam', 31337: 'amsterdam'}
    require(chain in semantics, 'unsupported gas semantics chain')
    return semantics[chain]


def gas_crosscheck(plan, rpc, block, tolerance, emit=print, multiplier=100, *, chain):
    require(math.isfinite(tolerance) and 0 <= tolerance <= .05, 'gas tolerance must be between 0 and 0.05')
    require(type(multiplier) is int and 100 <= multiplier <= 200, 'gas multiplier must be an integer percentage 100..200')
    emit(f'GAS single-endpoint real-chain tolerance={tolerance:g} multiplier={multiplier}')
    txs = plan['transactions']
    karst = gas_semantics(chain) == 'karst'
    if karst:
        for i, tx in enumerate(txs):
            name = tx.get('contractName') or tx.get('function') or str(i)
            require(integer(tx['transaction']['gas']) <= int(CAP_FRACTION * TX_GAS_CAP),
                    f'Karst transaction gas limit above headroom {int(CAP_FRACTION * TX_GAS_CAP)}: {name} index={i}')
    targets = large_creates(plan)
    try:
        head = rpc('eth_getBlockByNumber', block, False)
    except Exception as error:
        raise RuntimeError('STOP eth_simulateV1 full-sequence support required; head read: ' + redact_error(error)) from None
    # One sequential block per transaction mirrors --slow and stays below a single block's gas budget.
    blocks = []
    for i, tx in enumerate(txs):
        call = {k:v for k,v in tx['transaction'].items() if k in ('from', 'to', 'value', 'input', 'data', 'gas', 'nonce', 'maxFeePerGas', 'maxPriorityFeePerGas') and v is not None}
        if 'input' in call: call['data'] = call.pop('input')
        # Default tip is 1 gwei; preserve each planned fee independently when supplied.
        call.setdefault('maxPriorityFeePerGas', hex(1_000_000_000))
        if 'maxFeePerGas' not in call:
            require('baseFeePerGas' in head, 'head missing baseFeePerGas for simulation fees')
            call['maxFeePerGas'] = hex(2 * integer(head['baseFeePerGas']) + integer(call['maxPriorityFeePerGas']))
        emit(f"GAS fees index={i} maxFeePerGas={call['maxFeePerGas']} maxPriorityFeePerGas={call['maxPriorityFeePerGas']}")
        blocks.append({'calls':[call]})
    try:
        result = rpc('eth_simulateV1', {'blockStateCalls':blocks, 'validation':True, 'traceTransfers':False}, block)
    except Exception as error:
        raise RuntimeError('STOP eth_simulateV1 full-sequence support required; ' + redact_error(error)) from None
    require(isinstance(result, list) and len(result) == len(blocks), 'eth_simulateV1 incomplete sequence')
    calls = [r['calls'][0] for r in result if len(r.get('calls', [])) == 1]
    require(len(calls) == len(txs), 'eth_simulateV1 sequence incomplete')
    for i, call in enumerate(calls):
        require(integer(call.get('status', 0)) == 1 and not call.get('error'),
                f'eth_simulateV1 sequence reverted index={i}: ' + redact_error(json.dumps(call.get('error', call))))
    block_gas_limit = integer(head['gasLimit'])
    for i, tx in enumerate(txs):
        limit, real = integer(tx['transaction']['gas']), integer(calls[i]['gasUsed'])
        name = tx.get('contractName') or str(i)
        require(limit <= block_gas_limit, f'gas limit above block gas limit: {name} {limit} > {block_gas_limit}')
        # Under EIP-8037 a limit <= 2^24 has no state-gas reservoir, so the TOTAL gas counts against the
        # regular cap (e.g. the Paymaster CREATE totals 16,771,708). Such a tx must fit with headroom.
        require(karst or limit > TX_GAS_CAP or real <= TX_GAS_CAP * CAP_FRACTION,
                f'tx gas limit <= 2^24 but total gas {real} leaves under 10% headroom: {name}')
    for i, tx in targets:
        limit = integer(tx['transaction']['gas'])
        simulated = -(-limit * 100 // multiplier)  # forge's estimate before its multiplier (ceil)
        real = integer(calls[i]['gasUsed'])
        emit(f"GAS index={i} contract={tx['contractName']} limit={limit} simulated={simulated} real={real} tolerance={tolerance:g}")
        require(real > 0 and real <= simulated <= real * (1 + tolerance), 'gas mismatch: ' + tx['contractName'])
    return [integer(c['gasUsed']) for c in calls], block_gas_limit


def price_sources(env, production, chain, second, fork):
    mode = env.get('DEPLOYLIVE_PRICE_SOURCE', 'chain')
    require(mode in ('chain', 'fork'), 'invalid price source')
    require(not production or mode == 'chain', 'production refuses fork price source')
    return (fork, fork) if mode == 'fork' else (chain, second)


def broadcast_gates(env, plan, rpc, second_rpc, emit=print, price_rpcs=None, *, chain):
    # This input must equal DeployLive's fixed initializer; do not silently invent a threshold.
    threshold = integer(env['PRICE_STALENESS_THRESHOLD'])
    require(threshold == 4200, 'PRICE_STALENESS_THRESHOLD differs from DeployLive initializer')
    primary, secondary = price_rpcs or (rpc, second_rpc)
    block, _ = price_window(plan, primary, secondary, env['ETH_USD_FEED'], threshold, emit)
    if price_rpcs is not None:
        block = rpc('eth_getBlockByNumber', 'latest', False)['number']
    reals, block_gas_limit = gas_crosscheck(plan, rpc, block, float(env.get('DEPLOYLIVE_GAS_TOLERANCE', '0.05')), emit,
                   multiplier=integer(env.get('DEPLOYLIVE_GAS_MULTIPLIER', '130')), chain=chain)
    price_window(plan, primary, secondary, env['ETH_USD_FEED'], threshold, emit)
    return gas_bounds(reals, block_gas_limit, chain=chain)


def gas_bounds(reals, block_gas_limit, *, chain):
    # DSR 2026-11-19: a broadcast gas limit is accepted inside the gated range, not only when equal.
    # Amsterdam preserves the EIP-8037 reservoir lower bound and block upper bound.
    # Karst uses the real need as the lower bound and caps the upper bound at 2^24.
    karst = gas_semantics(chain) == 'karst'
    if karst:
        block_gas_limit = min(block_gas_limit, TX_GAS_CAP)
    bounds = []
    for real in reals:
        low = real if karst or real <= TX_GAS_CAP * CAP_FRACTION else max(real, TX_GAS_CAP + 1)
        require(low <= block_gas_limit, 'gated gas need above block gas limit')
        bounds.append([low, block_gas_limit])
    return bounds


def source_stamp():
    return dict(commit=clean_source_commit(), foundrySha256=hashlib.sha256((ROOT/'foundry.toml').read_bytes()).hexdigest())
