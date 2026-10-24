#!/usr/bin/env python3
"""Unsigned CC-125 Safe A6e plan and same-fork A3a/upgrade rehearsal."""
import sys
sys.dont_write_bytecode = True
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
from functools import lru_cache

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'script/a3a'))
import a3a_exec as a

TL = '0xccdf8e0d29fb2c3061910d79484a2b653757c34b'
REG = '0xf5bf37ca83afdaab73691ba7eccdfa69b8708e71'
SAFE, SP, DEPLOYER = a.SAFE, a.SP, a.DEPLOYER
DELAY = 172800
CANDIDATE = 'fbd74fb1e2e9d948996e6d6c02c48dc1c1778107'
IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
GUARD_SLOT = '0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8'
SENTINEL = '0x'+'0'*39+'1'
GAS = [440000, 420000, 5000, 340000]
CONFIG_TYPE = '(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address,uint256)'
ROLES = {'DEFAULT_ADMIN': [TL], 'PROPOSER': [SAFE], 'EXECUTOR': [SAFE], 'CANCELLER': [SAFE]}
SP_IMMUTABLES = ('entryPoint', 'REGISTRY', 'ETH_USD_PRICE_FEED', '__self', 'EXTENSION')
ART_NAMES = ('SuperPaymaster', 'SuperPaymasterAdmin', 'TimelockController', 'APNTsCapped')
MAX_CREATE_GAS = 60_000_000
# Headroom implied by the same 13/10 margin, rather than an arbitrary gas allowance.
RR_THRESHOLD = a.GAS_CAP*a.MARGIN_DEN//a.MARGIN_NUM
MEASURED_KEYS = {'executionTimestamp', 'estimateGas', 'localEstimateGas', 'forkGasUsed',
                 'minedGasMinimum', 'rrRequired', 'rrWitness'}
GAS_POLICY = dict(margin=[a.MARGIN_NUM, a.MARGIN_DEN], regularGasCap=a.GAS_CAP,
                  rrThreshold=RR_THRESHOLD, maxCreateGas=MAX_CREATE_GAS)
RECIPIENT = '0x0000000000000000000000000000000000a6e125'
CONTROL_IDS = ['safeMint_positive', 'safeMint_negative', 'failed_pause_readback',
               'early_upgrade', 'non_safe_execute', 'cancel_reschedule', 'early_activation']
PIN_KEYS = ('block', 'blockHash', 'timestamp', 'stateBlock', 'stateBlockHash', 'stateTimestamp',
            'senders', 'safeNonce', 'safe', 'registryOwner', 'roleConfig', 'immutables',
            'implementation', 'implementationCode', 'holders', 'historicalOperators', 'pauseList',
            'registryCreation', 'spCreation', 'timelockCreation', 'pendingOperations',
            'capped', 'pendingAPNTsTokenEta', 'guardianBefore')


def role():
    return a.keccak('PAYMASTER_SUPER')


def uints(raw):
    a.typed(raw, a.HEXDATA)
    a.need('abi_word_alignment', len(raw[2:]) % 64, 0)
    return [int(raw[i:i+64], 16) for i in range(2, len(raw), 64)]


def addr_word(value):
    a.need('abi_address_padding', value < 2**160, True)
    return '0x'+format(value, '040x')


def addr_array(raw):
    w = uints(raw)
    a.need('address_array_offset', w[0], 32)
    a.need('address_array_size', len(w), 2+w[1])
    result = [addr_word(v) for v in w[2:]]
    a.need('address_array_unique', len(set(result)), len(result))
    return result


def config(raw):
    w = uints(raw)
    a.need('config_offset', w[0], 32)
    a.need('config_min_words', len(w) >= 14, True)
    a.need('config_description_offset', w[10], 384)
    size = w[13]
    a.need('config_string_length', len(w), 14+(size+31)//32)
    body = bytes.fromhex(raw[2:])[32:]
    a.need('config_string_padding', body[416+size:], bytes(len(body)-416-size))
    body[416:416+size].decode('utf-8')
    for i, bits in ((2, 32), (3, 32), (4, 32), (5, 32), (6, 16), (7, 1)):
        a.need('config_range_'+str(i), w[i+1] < 2**bits, True)
    return dict(raw=raw, owner=addr_word(w[11]), isActive=bool(w[8]), minStake=w[1], ticketPrice=w[2])


def frozen_config(raw):
    config(raw)
    data = bytearray.fromhex(raw[2:])
    data[32+7*32:32+8*32] = bytes(32)
    return '0x'+data.hex()


def freeze_calldata(raw):
    body = frozen_config(raw)[66:]
    # getRoleConfig returns an outer tuple offset; configureRole has a role and tuple offset.
    return a.keccak('configureRole(bytes32,'+CONFIG_TYPE+')')[:10]+role()[2:]+format(64, '064x')+body


def code(rpc, target, block):
    return a.typed(rpc('eth_getCode', [target, block]), a.HEXDATA).lower()


def creation(rpc, target, block):
    hi = a.qty(block)
    a.need('deployed_'+target, code(rpc, target, block) != '0x', True)
    lo = 0
    while lo < hi:
        mid = (lo+hi)//2
        if code(rpc, target, hex(mid)) == '0x':
            lo = mid+1
        else:
            hi = mid
    a.need('creation_nonzero', lo > 0, True)
    a.need('creation_negative_'+target, code(rpc, target, hex(lo-1)), '0x')
    a.need('creation_positive_'+target, code(rpc, target, hex(lo)) != '0x', True)
    return lo


def scan(rpc, target, start, end, topics):
    result, seen = [], set()
    for lo in range(start, a.qty(end)+1, 2000):
        hi = min(lo+1999, a.qty(end))
        logs = rpc('eth_getLogs', [dict(address=target, fromBlock=hex(lo), toBlock=hex(hi), topics=topics)])
        a.need('logs_array', isinstance(logs, list), True)
        for log in logs:
            a.need('log_emitter', log['address'].lower(), target)
            a.need('log_removed', log.get('removed', False), False)
            a.need('log_range', lo <= a.qty(log['blockNumber']) <= hi, True)
            identity = (a.typed(log['blockHash'], a.HASH32), a.typed(log['transactionHash'], a.HASH32),
                        a.qty(log['logIndex']))
            a.need('log_duplicate', identity in seen, False)
            seen.add(identity)
            result.append(log)
    return sorted(result, key=lambda x: (a.qty(x['blockNumber']), a.qty(x['transactionIndex']), a.qty(x['logIndex'])))


def inventory(rpc, block, reg_start, sp_start):
    grant = a.keccak('RoleRegistered(bytes32,address,uint256,uint256)')
    logs = scan(rpc, REG, reg_start, block, [grant, role()])
    candidates = set()
    for log in logs:
        a.need('grant_topics', len(log['topics']), 3)
        a.need('grant_topic', log['topics'][:2], [grant, role()])
        candidates.add(addr_word(int(a.typed(log['topics'][2], a.HASH32), 16)))
    holders = []
    for who in sorted(candidates):
        held = a.word(rpc, REG, 'hasRole(bytes32,address)', role(), who, block=block)
        a.need('membership_boolean', held in (0, 1), True)
        if held:
            holders.append(who)
    a.need('holder_count', len(holders), a.word(rpc, REG, 'getRoleUserCount(bytes32)', role(), block=block))
    topic = a.keccak('OperatorConfigured(address,address,address)')
    logs = scan(rpc, SP, sp_start, block, [topic])
    operators = set()
    for log in logs:
        a.need('operator_topics', len(log['topics']), 2)
        a.need('operator_topic', log['topics'][0], topic)
        operators.add(addr_word(int(a.typed(log['topics'][1], a.HASH32), 16)))
    a.need('nonempty_holders', len(holders) > 0, True)
    a.need('nonempty_operators', len(operators) > 0, True)
    return dict(holders=holders, historicalOperators=sorted(operators), pauseList=sorted(set(holders) | operators))


def safe_state(rpc, block):
    owners = sorted(addr_array(a.call(rpc, SAFE, 'getOwners()', block=block)))
    a.need('safe_owner_count', len(owners), 3)
    a.need('safe_signers', {a.APPROVER, a.EXECUTOR} <= set(owners), True)
    threshold = a.word(rpc, SAFE, 'getThreshold()', block=block)
    a.need('safe_threshold', threshold, 2)
    modules, seen, cursor = [], set(), SENTINEL
    while True:
        a.need('module_cursor_cycle', cursor in seen, False)
        seen.add(cursor)
        w = uints(a.call(rpc, SAFE, 'getModulesPaginated(address,uint256)', cursor, 32, block=block))
        a.need('module_offset', w[0], 64)
        a.need('module_size', len(w), 3+w[2])
        modules.extend(addr_word(x) for x in w[3:])
        cursor = addr_word(w[1])
        if cursor == SENTINEL:
            break
        a.need('module_page_progress', w[2] > 0, True)
    a.need('safe_modules', modules, [])
    guard = a.typed(rpc('eth_getStorageAt', [SAFE, GUARD_SLOT, block]), a.HASH32)
    a.need('safe_guard', guard, a.ZERO32)
    codes = {who: code(rpc, who, block) for who in sorted({SAFE, DEPLOYER, *owners})}
    a.need('safe_runtime', codes[SAFE] != '0x' and not codes[SAFE].startswith('0xef0100'), True)
    for who in set(owners) | {DEPLOYER}:
        a.need('undelegated_'+who, codes[who], '0x')
    return dict(owners=owners, threshold=threshold, modules=modules, guard=guard, codes=codes)


def pending_operations(rpc, start, block):
    scheduled = a.keccak('CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)')
    executed = a.keccak('CallExecuted(bytes32,uint256,address,uint256,bytes)')
    cancelled = a.keccak('Cancelled(bytes32)')
    logs = scan(rpc, TL, start, block, [[scheduled, executed, cancelled]])
    outstanding = {}
    for log in logs:
        topics = log['topics']
        a.need('operation_topics', len(topics), 2 if topics[0] == cancelled else 3)
        op = a.typed(topics[1], a.HASH32)
        if topics[0] == scheduled:
            outstanding.setdefault(op, []).append(log)
        else:
            a.need('operation_event_kind', topics[0] in (executed, cancelled), True)
            outstanding.pop(op, None)
    result = []
    for op in sorted(outstanding):
        state = a.word(rpc, TL, 'getOperationState(bytes32)', op, block=block)
        eta = a.word(rpc, TL, 'getTimestamp(bytes32)', op, block=block)
        a.need('pending_operation_state', state in (1, 2), True)
        a.need('pending_operation_eta', eta > 1, True)
        result.append(dict(id=op, state=state, eta=eta, scheduledLogs=outstanding[op]))
    return result


@lru_cache(maxsize=1)
def build():
    version = subprocess.run([str(a.REBUILD_FORGE), '--version'], capture_output=True, text=True)
    a.need('rebuild_version_status', version.returncode, 0)
    a.need('rebuild_version', version.stdout.splitlines()[0], 'forge Version: 1.7.1')
    names = (('SuperPaymaster', SP_IMMUTABLES),
             ('SuperPaymasterAdmin', SP_IMMUTABLES[:-1]),
             ('TimelockController', ('_minDelay',)),
             ('APNTsCapped', tuple(sorted(a.EIP712_IMMUTABLES))))
    arts, cfg = a.compile_commit(CANDIDATE, version.stdout, ART_NAMES, names)
    identities = {}
    for name in ART_NAMES:
        art = arts[name]
        identities[name] = dict(runtime=art['runtimeIdentity'],
            bytecode=art['bytecode']['object'], metadata=a.metadata_identity(art, cfg),
            storageLayout=art.get('storageLayout', {}),
            sourceHashes=a.artifact_sources(json.loads(art['metadata']) if isinstance(art['metadata'], str) else art['metadata']))
    return dict(commit=CANDIDATE, forgeVersion=version.stdout.strip(), contracts=identities)


def runtime(rpc, name, target, block, immutable_values=None):
    identity = build()['contracts'][name]['runtime']
    if name == 'TimelockController':
        return a.verify_runtime(rpc, {'timelockRuntimeIdentity': identity}, code(rpc, target, block), name)
    a.need('runtime_values_present', immutable_values is not None, True)
    return a.verify_runtime(rpc, {}, code(rpc, target, block), name, identity=identity,
                            values={k: int(v, 16).to_bytes(32, 'big') for k, v in immutable_values.items()})


def governance(rpc, block, start):
    runtime(rpc, 'TimelockController', TL, block)
    a.need('timelock_delay', a.word(rpc, TL, 'getMinDelay()', block=block), DELAY)
    # Reuse the reviewed event-history role reconciliation with a pinned read-only view.
    def pinned(method, params):
        params = copy.deepcopy(params)
        if method == 'eth_getLogs':
            end = a.block_data(rpc, block)['number'] if block == 'latest' else block
            return scan(rpc, TL, start, end, params[0]['topics'])
        elif params and params[-1] == 'latest':
            params[-1] = block
        return rpc(method, params)
    a.roles_readback(pinned, {'pin': {'timelock': TL}, 'roles': ROLES}, hex(start))
    for label, members in ROLES.items():
        rid = a.ZERO32 if label == 'DEFAULT_ADMIN' else a.keccak(label+'_ROLE')
        for who in {SAFE, TL, a.ZERO, *a.SENDERS.values()}:
            a.need('live_role_'+label+'_'+who,
                   a.word(rpc, TL, 'hasRole(bytes32,address)', rid, who, block=block), int(who in members))


def timelock_creation(rpc, start):
    # Runtime equality alone cannot exclude silent constructor role writes.
    b = rpc('eth_getBlockByNumber', [hex(start), True])
    matches = [tx for tx in b['transactions'] if tx['from'].lower() == DEPLOYER
               and a.qty(tx['nonce']) == 12132 and tx['to'] is None]
    a.need('a3a_timelock_creation_transaction', len(matches), 1)
    tx = matches[0]
    init = build()['contracts']['TimelockController']['bytecode'] + a.cast(
        'abi-encode', 'c(uint256,address[],address[],address)', DELAY, '['+SAFE+']', '['+SAFE+']', a.ZERO)[2:]
    a.need('a3a_timelock_creation_input', tx['input'], init)
    receipt = rpc('eth_getTransactionReceipt', [tx['hash']])
    a.need('a3a_timelock_creation_status', receipt['status'], '0x1')
    a.need('a3a_timelock_creation_address', receipt['contractAddress'].lower(), TL)
    a.need('a3a_timelock_creation_block', receipt['blockNumber'], hex(start))


def a3a_gate(rpc, block):
    a.need('a3a_timelock_code', code(rpc, TL, block) != '0x', True)
    start = creation(rpc, TL, block)
    timelock_creation(rpc, start)
    governance(rpc, block, start)
    capped = a.address(rpc, SP, 'pendingAPNTsToken()', block)
    a.need('a3a_s7_pending_token', capped != a.ZERO, True)
    # A3a's token deployment at the frozen nonce is part of the author-selected packet.
    expected = a.create_address(DEPLOYER, 12133)
    a.need('a3a_capped_address', capped, expected)
    a.need('a3a_s6_owner', a.address(rpc, capped, 'owner()', block), TL)
    a.need('a3a_capped_code', code(rpc, capped, block) != '0x', True)
    a.need('a3a_s7_before_ownership_transfer', a.address(rpc, SP, 'owner()', block), DEPLOYER)
    return capped, start


def initial_guardian(rpc, block):
    layout = build()['contracts']['SuperPaymaster']['storageLayout']['storage']
    matches = [entry for entry in layout if entry['label'] == 'guardian']
    a.need('guardian_layout', len(matches), 1)
    entry = matches[0]
    value = int(a.typed(rpc('eth_getStorageAt', [SP, hex(int(entry['slot'])), block]), a.HASH32), 16)
    # 5.4.2 has no guardian getter. Its future guardian/pause slot must be unused and zero.
    a.need('initial_guardian_pause_slot', value, 0)
    return addr_word((value >> (8*entry['offset'])) & (2**160-1))


def collect(rpc, block, source=None):
    a.need('chain', a.qty(rpc('eth_chainId', [])), a.CHAIN)
    a.check_keccak(rpc)
    b = a.block_data(rpc, block)
    block = b['number']
    capped, tl_start = a3a_gate(rpc, block)
    a.need('sp_542', a.call(rpc, SP, 'version()', block=block),
           a.cast('abi-encode', 'c(string)', 'SuperPaymaster-5.4.2'))
    registry = a.address(rpc, SP, 'REGISTRY()', block)
    a.need('sp_registry', registry, REG)
    cfg = config(a.call(rpc, REG, 'getRoleConfig(bytes32)', role(), block=block))
    a.need('registration_initially_active', cfg['isActive'], True)
    owner = a.address(rpc, REG, 'owner()', block)
    a.need('registry_owner_precondition', owner, DEPLOYER)
    a.need('config_owner_precondition', cfg['owner'], DEPLOYER)
    reg_start, sp_start = creation(rpc, REG, block), creation(rpc, SP, block)
    inv = inventory(rpc, block, reg_start, sp_start)
    senders = {}
    for label, who in a.SENDERS.items():
        n = a.nonce(rpc, who, block)
        a.need('pending_nonce_'+label, a.nonce(rpc, who, 'pending'), n)
        senders[label] = dict(address=who, nonce=n, balance=a.qty(rpc('eth_getBalance', [who, block])))
    pending = pending_operations(rpc, tl_start, block)
    a.need('initial_pending_operations', pending, [])
    impl = addr_word(int(rpc('eth_getStorageAt', [SP, IMPL_SLOT, block]), 16))
    origin = source or b
    return dict(block=origin['number'], blockHash=origin['hash'], timestamp=a.qty(origin['timestamp']),
                stateBlock=block, stateBlockHash=b['hash'], stateTimestamp=a.qty(b['timestamp']),
                senders=senders, safeNonce=a.word(rpc, SAFE, 'nonce()', block=block), safe=safe_state(rpc, block),
                registryOwner=owner, roleConfig=cfg['raw'], immutables={key: a.address(rpc, SP, key+'()', block)
                    for key in ('entryPoint', 'REGISTRY', 'ETH_USD_PRICE_FEED')},
                implementation=impl, implementationCode=code(rpc, impl, block), **inv,
                registryCreation=reg_start, spCreation=sp_start, timelockCreation=tl_start,
                pendingOperations=pending, capped=capped,
                pendingAPNTsTokenEta=a.word(rpc, SP, 'pendingAPNTsTokenEta()', block=block), guardianBefore=initial_guardian(rpc, block))


def operation_hash(targets, data, predecessor, salt, batch):
    if batch:
        encoded = a.cast('abi-encode', 'c(address[],uint256[],bytes[],bytes32,bytes32)',
                         '['+','.join(targets)+']', '['+','.join('0' for _ in targets)+']',
                         '['+','.join(data)+']', predecessor, salt)
    else:
        encoded = a.cast('abi-encode', 'c(address,uint256,bytes,bytes32,bytes32)', targets[0], 0, data[0], predecessor, salt)
    return a.keccak(encoded)


def op_call(op, verb):
    if op['batch']:
        args = ('['+','.join(op['targets'])+']', '['+','.join('0' for _ in op['targets'])+']',
                '['+','.join(op['data'])+']', op['predecessor'], op['salt'])
        sig = verb+'Batch(address[],uint256[],bytes[],bytes32,bytes32'+(',uint256)' if verb == 'schedule' else ')')
    else:
        args = (op['targets'][0], 0, op['data'][0], op['predecessor'], op['salt'])
        sig = verb+'(address,uint256,bytes,bytes32,bytes32'+(',uint256)' if verb == 'schedule' else ')')
    return a.calldata(sig, *args, *((DELAY,) if verb == 'schedule' else ()))


def safe_hash(inner, n):
    domain = a.keccak(a.cast('abi-encode', 'c(bytes32,uint256,address)',
                      a.keccak('EIP712Domain(uint256 chainId,address verifyingContract)'), a.CHAIN, SAFE))
    typehash = a.keccak('SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)')
    h = a.keccak(a.cast('abi-encode', 'c(bytes32,address,uint256,bytes32,uint8,uint256,uint256,uint256,address,address,uint256)',
                        typehash, TL, 0, a.keccak(inner), 0, 0, 0, 0, a.ZERO, a.ZERO, n))
    return a.keccak('0x1901'+domain[2:]+h[2:])


def safe_payload(inner):
    # Approved-hash signatures: each r is an owner, s=0, v=1. Safe requires ascending owners.
    signatures = '0x'+''.join(who[2:].zfill(64)+'0'*64+'01' for who in sorted((a.APPROVER, a.EXECUTOR)))
    return a.calldata('execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)',
                      TL, 0, inner, 0, 0, 0, 0, a.ZERO, a.ZERO, signatures)


def build_plan(pin, a3a_digest=None):
    a.exact_keys('pin_keys', pin, PIN_KEYS)
    n = pin['senders']['deployer']['nonce']
    new_impl = a.create_address(DEPLOYER, n)
    extension = a.create_address(new_impl, 1)
    artifacts = copy.deepcopy(build())
    init = artifacts['contracts']['SuperPaymaster']['bytecode']+a.cast('abi-encode', 'c(address,address,address)',
                *(pin['immutables'][x] for x in ('entryPoint', 'REGISTRY', 'ETH_USD_PRICE_FEED')))[2:]
    upgrade = a.calldata('upgradeToAndCall(address,bytes)', new_impl, a.calldata('setGlobalPaused(bool)', 'true'))
    queue = a.calldata('queueGasParams(uint32,uint32,uint32,uint32)', *GAS)
    salt = a.keccak('CC-125/A6e/'+pin['blockHash']+'/'+new_impl+'/upgrade-queue')
    first = dict(batch=True, targets=[SP, SP], data=[upgrade, queue], predecessor=a.ZERO32, salt=salt)
    first['id'] = operation_hash(first['targets'], first['data'], first['predecessor'], salt, True)
    second = dict(batch=False, targets=[SP], data=[a.calldata('executeGasParams()')], predecessor=first['id'],
                  salt=a.keccak('CC-125/A6e/'+pin['blockHash']+'/'+new_impl+'/activate'))
    second['id'] = operation_hash(second['targets'], second['data'], second['predecessor'], second['salt'], False)
    counters = {v['address']: v['nonce'] for v in pin['senders'].values()}
    steps = []
    safe_n = pin['safeNonce']
    def add(sid, who, to, data, **extra):
        tx = dict(to=to, data=data, value='0x0', nonce=hex(counters[who]), **{'from': who},
                  chainId=hex(a.CHAIN), maxFeePerGas=hex(a.MAX_FEE), maxPriorityFeePerGas=hex(a.PRIORITY))
        steps.append(dict(id=sid, tx=tx, safeNonce=safe_n, **extra))
        counters[who] += 1
    add('deploy', DEPLOYER, None, init)
    add('freeze', DEPLOYER, REG, freeze_calldata(pin['roleConfig']))
    for i, who in enumerate(pin['pauseList']):
        add('pause_'+str(i), DEPLOYER, SP, a.calldata('setOperatorPaused(address,bool)', who, 'true'), operator=who)
    add('transfer', DEPLOYER, SP, a.calldata('transferOwnership(address)', TL))
    for opname, op in (('upgrade', first), ('activation', second)):
        for verb in ('schedule', 'execute'):
            inner = op_call(op, verb)
            h = safe_hash(inner, safe_n)
            sid = opname+'_'+verb
            add(sid+'_approve', a.APPROVER, SAFE, a.calldata('approveHash(bytes32)', h),
                safeHash=h, inner=inner, operation=opname)
            add(sid+'_exec', a.EXECUTOR, SAFE, safe_payload(inner),
                safeHash=h, inner=inner, operation=opname)
            safe_n += 1
    return dict(schema=2, route='Safe-A6e', a3aPlanSha256=a3a_digest, pin=pin, rebuild=artifacts,
                implementation=new_impl, extension=extension, operations={'upgrade': first, 'activation': second},
                steps=steps, gasPolicy=copy.deepcopy(GAS_POLICY), gasParams=list(GAS), controls=list(CONTROL_IDS))


def budget(plan):
    budgets = {label: sum(a.qty(s['tx']['gas'])*a.qty(s['tx']['maxFeePerGas'])
                         for s in plan['steps'] if s['tx']['from'] == who)
               for label, who in a.SENDERS.items()}
    for label, required in budgets.items():
        a.need('budget_'+label, plan['pin']['senders'][label]['balance'] >= required, True)
    plan['budgetsWei'] = budgets


def margin_limit(*values):
    return (max(values)*a.MARGIN_NUM+a.MARGIN_DEN-1)//a.MARGIN_DEN


def validate_gas(step):
    tx = step['tx']
    # Check the mined requirement before consulting estimates. The latter ignore the RR cap.
    minimum = step['minedGasMinimum']
    if tx['to'] is None:
        a.need('create_mined_minimum', type(minimum) is int and minimum > 0, True)
        a.need('pre_send_mined_minimum', a.qty(tx['gas']) >= minimum, True)
    else:
        a.need('non_create_mined_minimum', minimum, None)
    for key in ('estimateGas', 'localEstimateGas', 'forkGasUsed', 'executionTimestamp'):
        a.need('measurement_'+key, type(step[key]) is int and step[key] > 0, True)
    limit = a.qty(tx['gas'])
    a.need('create_gas_ceiling', limit <= MAX_CREATE_GAS, True)
    rr = limit > a.GAS_CAP
    a.need('rr_required_flag', step['rrRequired'], rr)
    if rr:
        a.need('rr_create_only', tx['to'], None)
        a.need('rr_mined_need', minimum > RR_THRESHOLD, True)
        witness = step['rrWitness']
        a.exact_keys('rr_witness_keys', witness, ('engineCommit', 'transactionHash', 'gasLimit',
                                               'stepIndex', 'pc', 'depth', 'gas', 'stateGasReservoir'))
        a.need('rr_witness_engine', witness['engineCommit'], a.COMMIT)
        a.typed(witness['transactionHash'], a.HASH32)
        a.need('rr_witness_gas_limit', witness['gasLimit'], limit)
        a.need('rr_first_step', witness['stepIndex'], 0)
        a.need('rr_first_depth', witness['depth'], 1)
        a.need('rr_first_pc', witness['pc'], 0)
        for key in ('gas', 'stateGasReservoir'):
            a.need('rr_witness_'+key, type(witness[key]) is int and witness[key] > 0, True)
        a.need('rr_regular_cap', witness['gas'] <= a.GAS_CAP, True)
        a.need('rr_reservoir_bound', witness['stateGasReservoir'] <= limit-a.GAS_CAP, True)
    else:
        a.need('non_rr_witness', step['rrWitness'], None)
    a.tx_quantities(tx, gas_cap=MAX_CREATE_GAS if rr else a.GAS_CAP)
    a.need('measured_gas_limit', limit, margin_limit(step['estimateGas'], step['localEstimateGas'],
                                                   step['forkGasUsed'], minimum or 0))


def validate_plan(plan, frozen=True):
    expected = build_plan(plan['pin'], plan['a3aPlanSha256'])
    a.exact_keys('plan_keys', plan, set(expected) | ({'budgetsWei'} if frozen else set()))
    validate_pin(plan['pin'])
    for key in set(expected)-{'steps'}:
        a.need('plan_derived_'+key, plan[key], expected[key])
    a.need('plan_step_count', len(plan['steps']), len(expected['steps']))
    for step, derived in zip(plan['steps'], expected['steps']):
        a.exact_keys('step_keys', step, set(derived) | (MEASURED_KEYS if frozen else set()))
        a.exact_keys('tx_keys', step['tx'], set(derived['tx']) | ({'gas'} if frozen else set()))
        for key in set(derived)-{'tx'}:
            a.need('plan_step_'+key, step[key], derived[key])
        for key, value in derived['tx'].items():
            a.need('plan_tx_'+key, step['tx'][key], value)
        if frozen:
            validate_gas(step)
    if frozen:
        checked = copy.deepcopy(plan)
        budget(checked)
        a.need('plan_budgets', plan['budgetsWei'], checked['budgetsWei'])
    return plan


def receipt(rpc, tx, status='0x1'):
    # The optional cap in the shared helper never changes A3a's default. All raw high-gas
    # probes here are fork-only CREATEs; final transactions pass validate_gas first.
    cap = MAX_CREATE_GAS if tx['to'] is None else a.GAS_CAP
    a.need('upgrade_receipt_local', getattr(rpc, 'local', False), True)
    return a.receipt(rpc, tx, status=status, gas_cap=cap)


def probe(rpc, tx, gas, timestamp, witness=False):
    a.need('probe_local', getattr(rpc, 'local', False), True)
    trial = dict(tx, gas=hex(gas))
    a.tx_quantities(trial, gas_cap=MAX_CREATE_GAS if tx['to'] is None else a.GAS_CAP)
    snap = rpc('evm_snapshot', [])
    before = (a.nonce(rpc, tx['from']), a.word(rpc, SAFE, 'nonce()'))
    try:
        rpc('evm_setNextBlockTimestamp', [timestamp])
        r = receipt(rpc, trial, status=None)
        a.mined_identity(rpc('eth_getTransactionByHash', [r['transactionHash']]), trial, 'gas_probe')
        rr = reservoir_witness(rpc, trial, r) if witness and r['status'] == '0x1' else None
    finally:
        a.need('gas_probe_restore', rpc('evm_revert', [snap]), True)
    a.need('gas_probe_nonce_restore', (a.nonce(rpc, tx['from']), a.word(rpc, SAFE, 'nonce()')), before)
    return r, rr


def admission_gas(tx):
    # Type-2, no access/authorization list. Stay above intrinsic AND EIP-7623 calldata
    # floor so the search probes mined failures rather than invalid RPC submissions.
    data = bytes.fromhex(a.typed(tx['data'], a.HEXDATA)[2:])
    tokens = sum(1 if b == 0 else 4 for b in data)
    intrinsic = 21000+4*tokens
    if tx['to'] is None:
        intrinsic += 32000+2*((len(data)+31)//32)
    return max(intrinsic, 21000+10*tokens)


def mined_minimum(rpc, tx, timestamp):
    a.need('mined_search_create_only', tx['to'], None)
    low, high = admission_gas(tx)-1, MAX_CREATE_GAS
    trials = []
    def succeeds(gas):
        r, _ = probe(rpc, tx, gas, timestamp)
        trials.append(dict(gasLimit=gas, status=r['status'], gasUsed=a.qty(r['gasUsed']), transactionHash=r['transactionHash']))
        return r['status'] == '0x1'
    a.need('mined_search_high_success', succeeds(high), True)
    while high-low > 1:
        middle = (low+high)//2
        if succeeds(middle):
            high = middle
        else:
            low = middle
    return high, trials


def trace_number(value, name):
    if isinstance(value, str):
        return a.qty(value)
    a.need('trace_integer_'+name, type(value) is int and value >= 0, True)
    return value


def reservoir_witness(rpc, tx, r):
    a.need('rr_trace_create_only', tx['to'], None)
    a.need('rr_trace_receipt', r['status'], '0x1')
    trace = rpc('debug_traceTransaction', [r['transactionHash'],
                dict(disableMemory=True, disableStack=True, disableStorage=True, limit=1)])
    a.need('rr_struct_logs', isinstance(trace, dict) and isinstance(trace.get('structLogs'), list)
           and len(trace['structLogs']) > 0, True)
    first = trace['structLogs'][0]
    witness = dict(engineCommit=a.COMMIT, transactionHash=r['transactionHash'], gasLimit=a.qty(tx['gas']), stepIndex=0)
    for key in ('pc', 'depth', 'gas', 'stateGasReservoir'):
        witness[key] = trace_number(first.get(key), key)
    a.need('rr_nonzero_reservoir', witness['stateGasReservoir'] > 0, True)
    return witness


def measure_step(remote, rpc, plan, step, overrides, timestamp, calibrate):
    tx = step['tx']
    estimate_tx = {k: v for k, v in a.tx_rpc(tx, gas_cap=MAX_CREATE_GAS if tx['to'] is None else a.GAS_CAP).items() if k != 'gas'}
    context = dict(block=plan['pin']['block'], stateOverrides=copy.deepcopy(overrides), blockOverrides={'time': hex(timestamp)})
    est = a.qty(remote('eth_estimateGas', [estimate_tx, context['block'], overrides, context['blockOverrides']]))
    local_est = a.qty(rpc('eth_estimateGas', [estimate_tx, 'latest']))
    minimum, trials = mined_minimum(rpc, tx, timestamp) if tx['to'] is None else (None, [])
    observed = dict(executionTimestamp=timestamp, estimateGas=est, localEstimateGas=local_est, minedGasMinimum=minimum)
    if not calibrate:
        for key, value in observed.items():
            a.need('replay_'+key, value, step[key])
        validate_gas(step)
        return dict(estimateContext=context, minedGasSearch=trials)
    limit = margin_limit(est, local_est, minimum or 0)
    # Gas-used accounting can depend on the submitted limit. Require a stable measured
    # limit, and fail on a cycle/non-convergence instead of freezing inconsistent evidence.
    for _ in range(4):
        if limit > MAX_CREATE_GAS:
            raise a.Gate('measured_gas_ceiling', dict(step=step.get('id'), limit=limit, estimateGas=est, localEstimateGas=local_est,
                                                      minedGasMinimum=minimum), '<= %d' % MAX_CREATE_GAS)
        if limit > a.GAS_CAP:
            a.need('rr_create_only', tx['to'], None)
            a.need('rr_mined_need', minimum > RR_THRESHOLD, True)
        trial, witness = probe(rpc, tx, limit, timestamp, witness=limit > a.GAS_CAP)
        a.need('pilot_success', trial['status'], '0x1')
        used = a.qty(trial['gasUsed'])
        final_limit = margin_limit(est, local_est, used, minimum or 0)
        if final_limit == limit:
            break
        limit = final_limit
    else:
        raise a.Gate('gas_measurement_convergence', limit, 'stable margin from estimates, gasUsed, and mined minimum')
    step.update(observed, forkGasUsed=used, rrRequired=limit > a.GAS_CAP, rrWitness=witness)
    step['tx']['gas'] = hex(limit)
    validate_gas(step)
    return dict(estimateContext=context, minedGasSearch=trials)


def validate_pin(pin):
    a.exact_keys('pin_keys', pin, PIN_KEYS)
    for field in ('timestamp', 'stateTimestamp', 'safeNonce', 'registryCreation', 'spCreation', 'timelockCreation', 'pendingAPNTsTokenEta'):
        a.pin_integer(pin[field], field)
    for field in ('block', 'stateBlock'):
        a.qty(pin[field])
    for field in ('blockHash', 'stateBlockHash'):
        a.typed(pin[field], a.HASH32)
    a.exact_keys('senders', pin['senders'], a.SENDERS)
    for label, who in a.SENDERS.items():
        sender = pin['senders'][label]
        a.exact_keys('sender', sender, ('address', 'nonce', 'balance'))
        a.need('sender_identity', sender['address'], who)
        a.pin_integer(sender['nonce'], 'nonce')
        a.pin_integer(sender['balance'], 'balance')
    a.exact_keys('safe', pin['safe'], ('owners', 'threshold', 'modules', 'guard', 'codes'))
    a.need('pin_threshold', pin['safe']['threshold'], 2)
    owners = pin['safe']['owners']
    a.need('pin_safe_owners_sorted', owners, sorted(set(owners)))
    a.need('pin_safe_owner_count', len(owners), 3)
    a.need('pin_safe_signers', {a.APPROVER, a.EXECUTOR} <= set(owners), True)
    for who in owners:
        a.typed(who, a.ADDRESS_RX)
    a.need('pin_modules', pin['safe']['modules'], [])
    a.need('pin_guard', pin['safe']['guard'], a.ZERO32)
    a.exact_keys('safe_codes', pin['safe']['codes'], {SAFE, DEPLOYER, *owners})
    for who in {DEPLOYER, *owners}:
        a.need('pin_eoa_code', pin['safe']['codes'][who], '0x')
    for key in ('holders', 'historicalOperators', 'pauseList'):
        values = pin[key]
        a.need('pin_sorted_'+key, values, sorted(set(values)))
        for who in values:
            a.typed(who, a.ADDRESS_RX)
            a.need('pin_address_lower', who, who.lower())
            a.need('pin_nonzero_address', who != a.ZERO, True)
    a.need('pin_union', pin['pauseList'], sorted(set(pin['holders']) | set(pin['historicalOperators'])))
    a.need('pin_pending', pin['pendingOperations'], [])
    a.need('pin_registry_owner', pin['registryOwner'], DEPLOYER)
    cfg = config(pin['roleConfig'])
    a.need('pin_config_owner', cfg['owner'], DEPLOYER)
    a.need('pin_active', cfg['isActive'], True)
    a.exact_keys('pin_immutables', pin['immutables'], ('entryPoint', 'REGISTRY', 'ETH_USD_PRICE_FEED'))
    for who in pin['immutables'].values():
        a.typed(who, a.ADDRESS_RX)
    a.need('pin_registry', pin['immutables']['REGISTRY'], REG)
    a.need('pin_guardian', pin['guardianBefore'], a.ZERO)
    a.need('pin_capped', pin['capped'], a.create_address(DEPLOYER, 12133))


def assert_frozen(rpc, pin):
    a.need('registry_authority', a.address(rpc, REG, 'owner()'), pin['registryOwner'])
    current = a.call(rpc, REG, 'getRoleConfig(bytes32)', role())
    c = config(current)
    a.need('config_authority', c['owner'], config(pin['roleConfig'])['owner'])
    a.need('registration_still_frozen', c['isActive'], False)
    a.need('frozen_full_config', current, frozen_config(pin['roleConfig']))


def paused(rpc, who):
    w = uints(a.call(rpc, SP, 'operators(address)', who))
    a.need('operator_abi', len(w), 9)
    a.need('operator_pause_boolean', w[2] in (0, 1), True)
    return bool(w[2])


def require_pauses(rpc, pin):
    for who in pin['pauseList']:
        a.need('operator_paused_'+who, paused(rpc, who), True)


def check_inventory(rpc, pin):
    b = a.block_data(rpc, 'latest')['number']
    observed = inventory(rpc, b, pin['registryCreation'], pin['spCreation'])
    for key in ('holders', 'historicalOperators', 'pauseList'):
        a.need('post_freeze_'+key, observed[key], pin[key])
    return observed


def operation_state(rpc, op, state):
    a.need('operation_state_'+op['id'], a.word(rpc, TL, 'getOperationState(bytes32)', op['id']), state)
    eta = a.word(rpc, TL, 'getTimestamp(bytes32)', op['id'])
    a.need('operation_timestamp_'+op['id'], eta == 1 if state == 3 else eta > 1, True)
    return eta


def check_op_hash(rpc, op):
    if op['batch']:
        raw = a.call(rpc, TL, 'hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)',
                '['+','.join(op['targets'])+']', '['+','.join('0' for _ in op['targets'])+']',
                '['+','.join(op['data'])+']', op['predecessor'], op['salt'])
    else:
        raw = a.call(rpc, TL, 'hashOperation(address,uint256,bytes,bytes32,bytes32)',
                     op['targets'][0], 0, op['data'][0], op['predecessor'], op['salt'])
    a.need('onchain_operation_hash', raw, op['id'])


def upgrade_readback(rpc, plan, activated=False):
    pin = plan['pin']
    impl = addr_word(int(rpc('eth_getStorageAt', [SP, IMPL_SLOT, 'latest']), 16))
    a.need('implementation_slot', impl, plan['implementation'])
    values = {**pin['immutables'], '__self': impl, 'EXTENSION': plan['extension']}
    runtime(rpc, 'SuperPaymaster', impl, 'latest', values)
    runtime(rpc, 'SuperPaymasterAdmin', plan['extension'], 'latest',
            {**pin['immutables'], '__self': plan['extension']})
    a.need('extension_getter', a.address(rpc, impl, 'EXTENSION()'), plan['extension'])
    for key, expected in pin['immutables'].items():
        a.need('immutable_readback_'+key, a.address(rpc, SP, key+'()'), expected)
    a.need('version_550', a.call(rpc, SP, 'version()'), a.cast('abi-encode', 'c(string)', 'SuperPaymaster-5.5.0'))
    a.need('sp_owner', a.address(rpc, SP, 'owner()'), TL)
    a.need('guardian', a.address(rpc, SP, 'guardian()'), pin['guardianBefore'])
    a.need('global_pause', a.word(rpc, SP, 'paused()'), 1)
    require_pauses(rpc, pin)
    w = uints(a.call(rpc, SP, 'gasParams()'))
    a.need('gas_parameters_abi', len(w), 9)
    if activated:
        a.need('active_gas', w[:4], GAS)
        a.need('pending_gas_cleared', w[4:], [0]*5)
    else:
        a.need('queued_gas', w[4:8], GAS)
        a.need('queued_eta', w[8] > 0, True)
    return w


def pre_send(step, rpc, plan, check_gas=True):
    pin, sid, tx = plan['pin'], step['id'], copy.deepcopy(step['tx'])
    a.need('pre_send_chain', a.qty(rpc('eth_chainId', [])), a.CHAIN)
    a.need('pre_send_safe_state', safe_state(rpc, 'latest'), pin['safe'])
    governance(rpc, 'latest', pin['timelockCreation'])
    a.need('pre_send_sender_nonce', a.nonce(rpc, tx['from']), a.qty(tx['nonce']))
    a.need('pre_send_pending_nonce', a.nonce(rpc, tx['from'], 'pending'), a.qty(tx['nonce']))
    a.need('pre_send_safe_nonce', a.word(rpc, SAFE, 'nonce()'), step['safeNonce'])
    if sid not in ('deploy', 'freeze'):
        assert_frozen(rpc, pin)
    else:
        a.need('initial_config', a.call(rpc, REG, 'getRoleConfig(bytes32)', role()), pin['roleConfig'])
        a.need('initial_registry_owner', a.address(rpc, REG, 'owner()'), pin['registryOwner'])
    a.need('pre_send_s7_preserved', a.address(rpc, SP, 'pendingAPNTsToken()'), pin['capped'])
    a.need('pre_send_capped_owner', a.address(rpc, pin['capped'], 'owner()'), TL)
    if sid in ('deploy', 'freeze') or sid.startswith('pause_') or sid == 'transfer':
        a.need('pre_send_sp_eoa_owner', a.address(rpc, SP, 'owner()'), DEPLOYER)
        a.need('pre_send_legacy_impl', addr_word(int(rpc('eth_getStorageAt', [SP, IMPL_SLOT, 'latest']), 16)), pin['implementation'])
        a.need('pre_send_legacy_runtime', code(rpc, pin['implementation'], 'latest'), pin['implementationCode'])
    else:
        a.need('pre_send_sp_timelock_owner', a.address(rpc, SP, 'owner()'), TL)
    if sid == 'transfer' or sid.startswith(('upgrade_', 'activation_')):
        require_pauses(rpc, pin)
        check_inventory(rpc, pin)
    if sid == 'transfer':
        a.need('s7_before_transfer', a.word(rpc, SP, 'pendingAPNTsTokenEta()'), pin['pendingAPNTsTokenEta'])
    current_pending = pending_operations(rpc, pin['timelockCreation'], a.block_data(rpc, 'latest')['number'])
    allowed = {op['id'] for op in plan['operations'].values()}
    a.need('pending_operation_exclusion', all(x['id'] in allowed for x in current_pending), True)
    if 'safeHash' in step:
        raw = a.call(rpc, SAFE, 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)',
                     TL, 0, step['inner'], 0, 0, 0, 0, a.ZERO, a.ZERO, step['safeNonce'])
        a.need('onchain_safe_hash', raw, step['safeHash'])
        check_op_hash(rpc, plan['operations'][step['operation']])
        if sid.endswith('_exec'):
            a.need('safe_hash_approved', a.word(rpc, SAFE, 'approvedHashes(address,bytes32)', a.APPROVER, step['safeHash']), 1)
    if sid.startswith('activation_'):
        operation_state(rpc, plan['operations']['upgrade'], 3)
        gas = upgrade_readback(rpc, plan)
        # No parallel scheduling of the activation operation during the internal wait.
        a.need('internal_gas_wait', a.qty(a.block_data(rpc, 'latest')['timestamp']) >= gas[8], True)
    if sid.endswith('execute_exec'):
        op = plan['operations'][step['operation']]
        operation_state(rpc, op, 2)
    if check_gas:
        validate_gas(step)
        estimate_tx = {k: v for k, v in a.tx_rpc(tx, gas_cap=MAX_CREATE_GAS if step['rrRequired'] else a.GAS_CAP).items() if k != 'gas'}
        a.need('pre_send_gas', a.qty(rpc('eth_estimateGas', [estimate_tx, 'latest'])) <= a.qty(tx['gas']), True)
        a.need('pre_send_balance', a.qty(rpc('eth_getBalance', [tx['from'], 'latest'])) >= a.qty(tx['gas'])*a.qty(tx['maxFeePerGas']), True)
    return tx


def final_gate(rpc, plan):
    assert_frozen(rpc, plan['pin'])
    upgrade_readback(rpc, plan, activated=True)
    check_inventory(rpc, plan['pin'])
    a.need('final_safe', safe_state(rpc, 'latest'), plan['pin']['safe'])
    governance(rpc, 'latest', plan['pin']['timelockCreation'])
    for op in plan['operations'].values():
        operation_state(rpc, op, 3)
    a.need('final_pending_operations', pending_operations(rpc, plan['pin']['timelockCreation'],
           a.block_data(rpc, 'latest')['number']), [])
    return dict(status='PASS', service='PAUSED', gasParams=GAS, owner=TL,
                guardian=plan['pin']['guardianBefore'], implementation=plan['implementation'],
                operators=plan['pin']['pauseList'], operations={key: value['id'] for key, value in plan['operations'].items()})


def safe_trace(rpc, plan, step, receipt):
    trace = rpc('debug_traceTransaction', [receipt['transactionHash'], {'tracer': 'callTracer'}])
    a.need('safe_trace_object', isinstance(trace, dict), True)
    a.need('safe_trace_top_from', trace.get('from', '').lower(), step['tx']['from'])
    a.need('safe_trace_top_to', trace.get('to', '').lower(), SAFE)
    a.need('safe_trace_top_input', trace.get('input'), step['tx']['data'])
    a.need('safe_trace_top_success', bool(trace.get('error')), False)
    nodes = list(a.trace_nodes(trace))
    ep = plan['pin']['immutables']['entryPoint']
    a.need('no_entrypoint_in_governance', any(n.get('to', '').lower() == ep for n in nodes), False)
    if step['id'].endswith('_exec'):
        calls = [n for n in nodes if n.get('to', '').lower() == TL and n.get('input') == step['inner']]
        a.need('safe_timelock_call_count', len(calls), 1)
        a.need('safe_timelock_caller', calls[0].get('from', '').lower(), SAFE)
        a.need('safe_timelock_success', bool(calls[0].get('error')), False)
        expected = plan['operations'][step['operation']]['data'] if 'execute' in step['id'] else []
        writes = [n for n in nodes if n.get('to', '').lower() == SP and n.get('type') == 'CALL']
        a.need('timelock_sp_call_inputs', [n.get('input') for n in writes], expected)
        for node in writes:
            a.need('timelock_sp_caller', node.get('from', '').lower(), TL)
            a.need('timelock_sp_success', bool(node.get('error')), False)
        if step['id'] == 'upgrade_execute_exec':
            pause = a.calldata('setGlobalPaused(bool)', 'true')
            for target in (plan['implementation'], plan['extension']):
                matches = [n for n in nodes if n.get('to', '').lower() == target
                           and n.get('type') == 'DELEGATECALL' and n.get('input') == pause]
                a.need('atomic_pause_delegatecall_'+target, len(matches), 1)
                a.need('atomic_pause_delegatecall_success', bool(matches[0].get('error')), False)
    return dict(topLevelSafe=True, entryPointExcluded=True)


def log(out, record):
    with (out/'simulate.log').open('a') as stream:
        stream.write(json.dumps(record, sort_keys=True)+'\n')


def fixture_tx(rpc, sender, target, data):
    a.need('fixture_local_only', getattr(rpc, 'local', False), True)
    rpc('anvil_impersonateAccount', [sender])
    rpc('anvil_setBalance', [sender, hex(100*10**18)])
    return dict(to=target, data=data, value='0x0', nonce=hex(a.nonce(rpc, sender)), **{'from': sender},
                chainId=hex(a.CHAIN), maxFeePerGas=hex(a.MAX_FEE), maxPriorityFeePerGas=hex(a.PRIORITY), gas=hex(8000000))


def mint_fixture(rpc, pin, fixtures):
    # All fixture transactions are reverted before the plan starts and after its negative probe.
    sponsor = DEPLOYER
    community = a.keccak('COMMUNITY')
    a.need('sponsor_existing_community', a.word(rpc, REG, 'hasRole(bytes32,address)', community, sponsor), 1)
    a.need('recipient_no_community', a.word(rpc, REG, 'hasRole(bytes32,address)', community, RECIPIENT), 0)
    a.need('recipient_no_super', a.word(rpc, REG, 'hasRole(bytes32,address)', role(), RECIPIENT), 0)
    cc = config(a.call(rpc, REG, 'getRoleConfig(bytes32)', community))
    sc = config(pin['roleConfig'])
    staking = a.address(rpc, REG, 'GTOKEN_STAKING()')
    gtoken = a.address(rpc, staking, 'GTOKEN()')
    owner = a.address(rpc, gtoken, 'owner()')
    # Explicit fork-only GToken funding via the real token's mint, not role or pause storage mocks.
    funding = cc['minStake']+cc['ticketPrice']+sc['minStake']+sc['ticketPrice']
    def fixture(sender, target, payload, purpose):
        tx = fixture_tx(rpc, sender, target, payload)
        result = a.receipt(rpc, tx)
        fixtures.append(dict(purpose=purpose, tx=tx, receipt=result))
    for recipient, amount in ((RECIPIENT, cc['minStake']+cc['ticketPrice']), (sponsor, funding)):
        fixture(owner, gtoken, a.calldata('mint(address,uint256)', recipient, amount), 'fork_gtoken_funding')
        fixture(recipient, gtoken, a.calldata('approve(address,uint256)', staking, 2**256-1), 'fork_staking_approval')
    data = a.cast('abi-encode', 'c((string,string,uint256))', '("A6e-mint-control","",%d)' % cc['minStake'])
    fixture(RECIPIENT, REG, a.calldata('registerRole(bytes32,address,bytes)', community, RECIPIENT, data), 'fork_recipient_community')
    a.need('recipient_qualified', a.word(rpc, REG, 'hasRole(bytes32,address)', community, RECIPIENT), 1)
    return fixture_tx(rpc, sponsor, REG, a.calldata('safeMintForRole(bytes32,address,bytes)', role(), RECIPIENT,
                      a.cast('abi-encode', 'c(uint256)', sc['minStake'])))


def mint_control(rpc, plan, positive):
    snap = rpc('evm_snapshot', [])
    before = [a.nonce(rpc, DEPLOYER), a.word(rpc, SAFE, 'nonce()')]
    before_state = mint_state(rpc)
    fixtures = []
    try:
        tx = mint_fixture(rpc, plan['pin'], fixtures)
        if positive:
            result = a.receipt(rpc, tx)
            a.need('safe_mint_positive_membership', a.word(rpc, REG, 'hasRole(bytes32,address)', role(), RECIPIENT), 1)
            record = dict(control='safeMint_positive', receipt=result, sponsor=DEPLOYER, user=RECIPIENT, calldata=tx['data'])
        else:
            record = a.negative(rpc, tx, a.calldata('RoleNotConfigured(bytes32,bool)', role(), 'false'), 'safeMint_negative')
            record.update(sponsor=DEPLOYER, user=RECIPIENT, calldata=tx['data'])
            a.need('safe_mint_negative_membership', a.word(rpc, REG, 'hasRole(bytes32,address)', role(), RECIPIENT), 0)
    finally:
        a.need('mint_snapshot_restore', rpc('evm_revert', [snap]), True)
    a.need('mint_nonce_restore', [a.nonce(rpc, DEPLOYER), a.word(rpc, SAFE, 'nonce()')], before)
    a.need('mint_state_restore', mint_state(rpc), before_state)
    record.update(fixtures=fixtures, restoredState=before_state)
    return record


def mint_state(rpc):
    staking = a.address(rpc, REG, 'GTOKEN_STAKING()')
    token = a.address(rpc, staking, 'GTOKEN()')
    owner = a.address(rpc, token, 'owner()')
    return dict(totalStaked=a.word(rpc, staking, 'totalStaked()'),
                totalSupply=a.word(rpc, token, 'totalSupply()'),
                balances={who: a.word(rpc, token, 'balanceOf(address)', who) for who in (DEPLOYER, RECIPIENT, staking)},
                nonces={who: a.nonce(rpc, who) for who in {DEPLOYER, RECIPIENT, owner}},
                membership={rid: a.word(rpc, REG, 'hasRole(bytes32,address)', rid, RECIPIENT)
                            for rid in (role(), a.keccak('COMMUNITY'))},
                locked={rid: a.word(rpc, staking, 'getLockedStake(address,bytes32)', RECIPIENT, rid)
                        for rid in (role(), a.keccak('COMMUNITY'))})


def wait_until(rpc, timestamp):
    current = a.qty(a.block_data(rpc, 'latest')['timestamp'])
    if current < timestamp:
        rpc('evm_setNextBlockTimestamp', [timestamp])
        rpc('evm_mine', [])


def cancel_control(rpc, plan):
    snap = rpc('evm_snapshot', [])
    nonces = {who: a.nonce(rpc, who) for who in a.SENDERS.values()}
    safe_n = a.word(rpc, SAFE, 'nonce()')
    op = plan['operations']['upgrade']
    def safe_action(inner):
        n = a.word(rpc, SAFE, 'nonce()')
        h = safe_hash(inner, n)
        a.need('recovery_safe_hash', a.call(rpc, SAFE, 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)',
            TL, 0, inner, 0, 0, 0, 0, a.ZERO, a.ZERO, n), h)
        a.receipt(rpc, fixture_tx(rpc, a.APPROVER, SAFE, a.calldata('approveHash(bytes32)', h)))
        r = a.receipt(rpc, fixture_tx(rpc, a.EXECUTOR, SAFE, safe_payload(inner)))
        a.need('recovery_safe_nonce', a.word(rpc, SAFE, 'nonce()'), n+1)
        return r
    try:
        safe_action(a.calldata('cancel(bytes32)', op['id']))
        a.need('cancel_state', a.word(rpc, TL, 'getOperationState(bytes32)', op['id']), 0)
        data = op_call(op, 'execute')
        tx = fixture_tx(rpc, SAFE, TL, data)
        # Direct Safe impersonation is confined to this denied execution probe. Recovery writes use real Safe calls.
        result = a.negative(rpc, tx, a.calldata('TimelockUnexpectedOperationState(bytes32,bytes32)', op['id'],
                            '0x'+format(1 << 2, '064x')), 'cancel_reschedule')
        replacement = copy.deepcopy(op)
        replacement['salt'] = a.keccak(op['salt']+'01')
        replacement['id'] = operation_hash(op['targets'], op['data'], op['predecessor'], replacement['salt'], True)
        safe_action(op_call(replacement, 'schedule'))
        operation_state(rpc, replacement, 1)
        result['replacementOperation'] = replacement['id']
    finally:
        a.need('recovery_snapshot_restore', rpc('evm_revert', [snap]), True)
    a.need('recovery_nonces_restored', {who: a.nonce(rpc, who) for who in nonces}, nonces)
    a.need('recovery_safe_nonce_restored', a.word(rpc, SAFE, 'nonce()'), safe_n)
    return result


def run_upgrade(rpc, plan, out, remote=None, calibrate=False):
    a.need('upgrade_local_only', getattr(rpc, 'local', False), True)
    validate_plan(plan, frozen=not calibrate)
    frozen_plan = copy.deepcopy(plan) if not calibrate else None
    a.need('archive_estimator_present', remote is not None, True)
    overrides = copy.deepcopy(getattr(rpc, 'archive_overrides', {}))
    records, controls = [], []
    plan_digest = hashlib.sha256((json.dumps(plan, indent=2, sort_keys=True)+'\n').encode()).hexdigest()
    log(out, dict(phase='upgrade', status='START', a3aPlanSha256=plan['a3aPlanSha256'], upgradePlanSha256=plan_digest if not calibrate else None, calibrate=calibrate))
    controls.append(mint_control(rpc, plan, True))
    for step in plan['steps']:
        a.process_alive(rpc.engine_process)
        sid = step['id']
        if sid == 'upgrade_execute_approve':
            op = plan['operations']['upgrade']
            controls.append(cancel_control(rpc, plan))
            bad = dict(step['tx'], to=TL, data=op_call(op, 'execute'), **{'from': a.EXECUTOR})
            controls.append(a.negative(rpc, bad, a.calldata('AccessControlUnauthorizedAccount(address,bytes32)',
                    a.EXECUTOR, a.keccak('EXECUTOR_ROLE')), 'non_safe_execute'))
            # Exact early revert is checked through the Safe after its approval below.
        if sid == 'activation_schedule_approve':
            wait_until(rpc, upgrade_readback(rpc, plan)[8])
        if sid.endswith('execute_exec'):
            op = plan['operations'][step['operation']]
            controls.append(a.negative(rpc, step['tx'], a.error_string('GS013'),
                'early_upgrade' if step['operation'] == 'upgrade' else 'early_activation',
                inner=(TL, step['inner'], a.calldata('TimelockUnexpectedOperationState(bytes32,bytes32)',
                       op['id'], '0x'+format(1 << 2, '064x')))))
            wait_until(rpc, a.word(rpc, TL, 'getTimestamp(bytes32)', op['id']))
        pre_send(step, rpc, plan, check_gas=not calibrate)
        execution_ts = a.qty(a.block_data(rpc, 'latest')['timestamp'])+1
        evidence = measure_step(remote, rpc, plan, step, overrides, execution_ts, calibrate)
        # Re-read state after all snapshot trials; no trial is a completed package step.
        tx = pre_send(step, rpc, plan)
        rpc('evm_setNextBlockTimestamp', [execution_ts])
        r = receipt(rpc, tx)
        a.need('fork_gas_used', a.qty(r['gasUsed']), step['forkGasUsed'])
        a.need('mined_execution_timestamp', a.qty(a.block_data(rpc, r['blockNumber'])['timestamp']), execution_ts)
        if step['rrRequired']:
            a.need('rr_replayed_witness', reservoir_witness(rpc, tx, r), step['rrWitness'])
        a.mined_identity(rpc('eth_getTransactionByHash', [r['transactionHash']]), tx, sid)
        a.need('post_sender_nonce', a.nonce(rpc, tx['from']), a.qty(tx['nonce'])+1)
        a.need('post_safe_nonce', a.word(rpc, SAFE, 'nonce()'), step['safeNonce']+int(sid.endswith('_exec')))
        if sid == 'deploy':
            a.need('deployed_address', r['contractAddress'].lower(), plan['implementation'])
            runtime(rpc, 'SuperPaymaster', plan['implementation'], 'latest',
                    {**plan['pin']['immutables'], '__self': plan['implementation'], 'EXTENSION': plan['extension']})
            runtime(rpc, 'SuperPaymasterAdmin', plan['extension'], 'latest',
                    {**plan['pin']['immutables'], '__self': plan['extension']})
        elif sid == 'freeze':
            assert_frozen(rpc, plan['pin'])
            log(out, dict(phase='upgrade', step='enumerate_after_freeze', inventory=check_inventory(rpc, plan['pin'])))
            controls.append(mint_control(rpc, plan, False))
            # A deliberately unpaused member must cause the transfer gate to fail.
            snap = rpc('evm_snapshot', [])
            who = plan['pin']['pauseList'][0]
            try:
                a.receipt(rpc, fixture_tx(rpc, DEPLOYER, SP, a.calldata('setOperatorPaused(address,bool)', who, 'false')))
                try:
                    require_pauses(rpc, {'pauseList': [who]})
                except a.Gate as error:
                    a.need('pause_recovery_reason', error.record['gate'], 'operator_paused_'+who)
                    controls.append(dict(control='failed_pause_readback', failure=error.record))
                else:
                    raise a.Gate('failed_pause_control', 'accepted', 'pause read-back refusal')
            finally:
                a.need('pause_control_restore', rpc('evm_revert', [snap]), True)
        elif sid.startswith('pause_'):
            a.need('pause_readback', paused(rpc, step['operator']), True)
        elif sid == 'transfer':
            a.need('ownership_transfer', a.address(rpc, SP, 'owner()'), TL)
        if sid.endswith('schedule_exec'):
            eta = operation_state(rpc, plan['operations'][step['operation']], 1)
            included = a.qty(a.block_data(rpc, r['blockNumber'])['timestamp'])
            a.need('external_delay_readback', eta, included+DELAY)
        elif sid == 'upgrade_execute_exec':
            gas = upgrade_readback(rpc, plan)
            included = a.qty(a.block_data(rpc, r['blockNumber'])['timestamp'])
            a.need('internal_delay_readback', gas[8], included+DELAY)
            operation_state(rpc, plan['operations']['upgrade'], 3)
        if 'safeHash' in step:
            safe_trace(rpc, plan, step, r)
            if sid.endswith('_approve'):
                a.need('post_approved_hash', a.word(rpc, SAFE, 'approvedHashes(address,bytes32)', a.APPROVER, step['safeHash']), 1)
            else:
                success = a.keccak('ExecutionSuccess(bytes32,uint256)')
                a.need('safe_success_event', any(l['address'].lower() == SAFE and l['topics'] == [success]
                        and l['data'][2:66].lower() == step['safeHash'][2:] for l in r['logs']), True)
        record = dict(phase='upgrade', step=sid, receipt=r, gasUsed=a.qty(r['gasUsed']),
                      measurements={key: step[key] for key in sorted(MEASURED_KEYS)}, **evidence)
        records.append(record)
        log(out, record)
        a.trace_overrides(rpc, r, overrides)
    a.need('completed_upgrade_steps', [r['step'] for r in records], [s['id'] for s in plan['steps']])
    a.need('completed_upgrade_controls', sorted(c['control'] for c in controls), sorted(CONTROL_IDS))
    mint_records = {c['control']: c for c in controls if c['control'].startswith('safeMint_')}
    a.need('safe_mint_identical_call', mint_records['safeMint_positive']['calldata'],
           mint_records['safeMint_negative']['calldata'])
    gate = final_gate(rpc, plan)
    if calibrate:
        budget(plan)
    validate_plan(plan, frozen=True)
    if not calibrate:
        a.need('frozen_upgrade_unchanged', plan, frozen_plan)
    plan_digest = hashlib.sha256((json.dumps(plan, indent=2, sort_keys=True)+'\n').encode()).hexdigest()
    result = dict(status='PASS', phase='upgrade', upgradePlanSha256=plan_digest,
                  steps=records, negativeControls=controls, preRestore=gate)
    a.write_json(out/'upgrade-simulate.json', result)
    log(out, result)
    return result


def save_plan(out, plan):
    a.write_json(out/'plan.json', plan)
    digest = hashlib.sha256((out/'plan.json').read_bytes()).hexdigest()
    (out/'plan.json.sha256').write_text(digest+'  plan.json\n')


def plan_command(remote, secondary, block, out):
    a.git_state(out)
    build()
    pin = collect(remote, block)
    a.need('independent_pin', collect(secondary, block), pin)
    plan = build_plan(pin)
    validate_plan(plan, frozen=False)
    with a.fork(remote, pin, out) as local:
        run_upgrade(local, plan, out, remote=remote, calibrate=True)
    a.relay_evidence(out)
    a.need('engine_stderr', (out/'engine.stderr').stat().st_size, 0)
    a.need('pin_recheck', collect(remote, block), pin)
    save_plan(out, plan)
    return plan


def simulate_command(remote, a3a_path, out, frozen=None):
    ap = a.load_plan(a3a_path)
    a.validate_plan(ap, frozen=True)
    a.need('a3a_selected_timelock', ap['pin']['timelock'], TL)
    digest = hashlib.sha256(a3a_path.read_bytes()).hexdigest()
    if frozen is not None:
        validate_plan(frozen)
        a.need('bootstrap_a3a_digest', frozen['a3aPlanSha256'], digest)
    a.safe_hash_check(remote, ap)
    a.need('a3a_simulation_pin', a.preflight(remote, ap['pin']['block']), ap['pin'])
    result = {}
    def continuation(local):
        log(out, dict(phase='a3a', status='PASS', steps=list(a.STEP_IDS), a3aPlanSha256=digest))
        source = a.block_data(remote, ap['pin']['block'])
        pin = collect(local, 'latest', source)
        plan = build_plan(pin, digest)
        if frozen is not None:
            expected = copy.deepcopy(frozen)
            expected.pop('budgetsWei')
            for step in expected['steps']:
                for key in MEASURED_KEYS:
                    step.pop(key)
                step['tx'].pop('gas')
            a.need('independent_rederived_plan', plan, expected)
            plan = copy.deepcopy(frozen)
        result.update(run_upgrade(local, plan, out, remote=remote, calibrate=frozen is None))
        if frozen is None:
            save_plan(out, plan)
    a.rehearse(remote, ap, out, after=continuation)
    a.relay_evidence(out)
    a.write_json(out/'combined-simulate.json', dict(status='PASS', a3aPlanSha256=digest,
                  phases=['a3a', 'upgrade'], upgrade=result))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('plan')
    p.add_argument('--rpc-file', type=Path, required=True)
    p.add_argument('--rpc-file-secondary', type=Path, required=True)
    p.add_argument('--block', required=True, type=lambda x: hex(int(x, 0) if x.startswith('0x') else int(x)))
    p.add_argument('--out', type=Path, required=True)
    p = sub.add_parser('simulate')
    p.add_argument('--rpc-file', type=Path, required=True)
    p.add_argument('--a3a-plan', type=Path, required=True)
    p.add_argument('--plan', type=Path)
    p.add_argument('--out', type=Path, required=True)
    for name in ('sign', 'send'):
        p = sub.add_parser(name)
        p.add_argument('--out', type=Path)
        p.add_argument('--reviewed-plan-sha256')
    args = parser.parse_args(argv)
    try:
        if args.command in ('sign', 'send'):
            raise a.Gate(args.command+'_disabled', a.REFUSAL, 'unsigned package only')
        if args.out.exists():
            a.need('output_empty', args.out.is_dir() and not any(args.out.iterdir()), True)
        args.out.mkdir(parents=True, exist_ok=True)
        remote = a.RPC(args.rpc_file.read_text().strip())
        if args.command == 'plan':
            plan_command(remote, a.RPC(args.rpc_file_secondary.read_text().strip()), args.block, args.out)
        else:
            frozen = a.load_plan(args.plan) if args.plan else None
            simulate_command(remote, args.a3a_plan, args.out, frozen)
        return 0
    except a.Gate as error:
        if error.record['gate'] != 'output_empty':
            a.failure_record(args.out, error.record)
        print(json.dumps(error.record), file=sys.stderr)
        return 3 if args.command in ('sign', 'send') else 1
    except BaseException as error:
        record = dict(status='FAILURE', gate='executor_error', observed=type(error).__name__, expected='completed gated run; RPC redacted')
        a.failure_record(args.out, record)
        print(json.dumps(record), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
