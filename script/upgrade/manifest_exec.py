#!/usr/bin/env python3
"""Phase A/B unsigned manifest builder and authenticated fork-only rehearsal."""
import sys
sys.dont_write_bytecode = True
import argparse
import copy
import hashlib
from functools import lru_cache
from pathlib import Path
import subprocess
import sp_upgrade_exec as u

a = u.a
BUFFER = 10**17
DAY = 86400
NAMES = ('SuperPaymaster', 'SuperPaymasterAdmin', 'GlobalTierSource', 'AOAProtocolRegistry',
         'xPNTsTokenV2Ext', 'xPNTsTokenV2', 'xPNTsFactoryV2', 'SuperPaymasterLens', 'Registry', 'BLSAggregator')
IMMUTABLES = dict(SuperPaymaster=u.SP_IMMUTABLES, SuperPaymasterAdmin=u.SP_IMMUTABLES[:-1],
    GlobalTierSource=('REGISTRY',), AOAProtocolRegistry=(),
    xPNTsTokenV2Ext=tuple(a.EIP712_IMMUTABLES)+('PROTOCOL_REGISTRY',),
    xPNTsTokenV2=tuple(a.EIP712_IMMUTABLES)+('PROTOCOL_REGISTRY', 'EXTENSION'),
    xPNTsFactoryV2=('REGISTRY', 'implementation', 'implementationCodehash', 'extensionCodehash'),
    SuperPaymasterLens=(), Registry=('__self',), BLSAggregator=('REGISTRY',))
POP = 'registerBLSPublicKey(address,(bytes32,bytes32,bytes32,bytes32),uint8,(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32))'
CONTROLS = ['early_unpause', 'factory_binding', 'early_bls', 'early_swap', 'funded_swap',
            'old_reputation', 'registry_nonowner', 'early_verifier', 'repeat_verifier', 'verifier_skip']


def required(obj, keys, label):
    a.need(label, isinstance(obj, dict) and set(keys) <= set(obj), True)


def external(path):
    a.need('external_inputs_required', path is not None and Path(path).is_file(), True)
    raw = Path(path).read_bytes()
    data = a.plan_json(raw)
    required(data, ('verifier', 'pop', 'anni', 'dvt', 'committee', 'sampled', 'depositTargetWei',
                    'releaseTag', 'releaseEvidence', 'registryBaselineCommit'), 'external_inputs_complete')
    v = data['verifier']
    required(v, ('commit', 'ciSha256', 'artifact', 'buildSha256'), 'verifier_provenance')
    required(v['artifact'], ('bytecode', 'runtimeIdentity'), 'verifier_artifact')
    for key in ('ciSha256', 'buildSha256'):
        a.need('verifier_'+key, len(v[key]) == 64 and all(c in '0123456789abcdef' for c in v[key]), True)
    a.need('verifier_commit', len(v['commit']) == 40 and all(c in '0123456789abcdef' for c in v['commit']), True)
    a.typed(v['artifact']['bytecode'], a.HEXDATA)
    a.need('verifier_bytecode_nonempty', v['artifact']['bytecode'] != '0x', True)
    for key in ('anni', 'dvt', 'committee'):
        a.typed(data[key], a.ADDRESS_RX)
        a.need('canonical_'+key, data[key], data[key].lower())
        a.need('nonzero_'+key, data[key] != a.ZERO, True)
    a.need('pop_three', len(data['pop']), 3)
    for p in data['pop']:
        a.exact_keys('pop_fields', p, ('validator', 'slot', 'calldata', 'aggregator', 'pinBlockHash'))
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
    for key in ('conformance', 'mutation', 'slither', 'sourceVerificationPlan'):
        digest = data['releaseEvidence'].get(key, '')
        a.need('release_evidence_'+key, len(digest) == 64 and all(c in '0123456789abcdef' for c in digest), True)
    return dict(sha256=hashlib.sha256(raw).hexdigest(), data=data)


@lru_cache(maxsize=1)
def rebuild():
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=u.ROOT, capture_output=True, text=True, check=True).stdout.strip()
    version = subprocess.run([str(a.REBUILD_FORGE), '--version'], capture_output=True, text=True, check=True).stdout
    a.need('forge_version', version.splitlines()[0], 'forge Version: 1.7.1')
    arts, cfg = a.compile_commit(head, version, NAMES, tuple(IMMUTABLES.items()))
    return dict(commit=head, forgeVersion=version.strip(), contracts={name: dict(
        bytecode=art['bytecode']['object'], runtimeIdentity=art['runtimeIdentity'],
        storageLayout=art.get('storageLayout', {}), metadata=a.metadata_identity(art, cfg))
        for name, art in arts.items()})


def release_gate(inputs, build):
    data = inputs['data']
    tag = subprocess.run(['git', 'rev-parse', '--verify', 'refs/tags/'+data['releaseTag']+'^{commit}'],
                         cwd=u.ROOT, capture_output=True, text=True)
    a.need('release_tag', tag.returncode, 0)
    a.need('release_tag_head', tag.stdout.strip(), build['commit'])
    old, _ = a.compile_commit(data['registryBaselineCommit'], build['forgeVersion'], ('Registry',))
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


def collect(rpc, block, inputs):
    pin = u.collect(rpc, block)
    d = inputs['data']
    block = pin['stateBlock']
    who = d['anni']
    n = a.nonce(rpc, who, block)
    a.need('anni_pending_nonce', a.nonce(rpc, who, 'pending'), n)
    a.need('anni_eoa', u.code(rpc, who, block), '0x')
    pin['senders']['anni'] = dict(address=who, nonce=n, balance=a.qty(rpc('eth_getBalance', [who, block])))
    a.need('registry_version', a.call(rpc, u.REG, 'version()', block=block), a.cast('abi-encode', 'c(string)', 'Registry-5.8.0'))
    pin['oldAggregator'] = a.address(rpc, u.REG, 'blsAggregator()', block)
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


def build_plan(pin, inputs=None):
    a.need('manifest_inputs_required', inputs is not None, True)
    required(inputs, ('sha256', 'data'), 'external_binding')
    d = inputs['data']
    required(d, ('verifier', 'pop', 'anni', 'dvt', 'committee', 'sampled', 'depositTargetWei'), 'manifest_external_complete')
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
    counters = {label: x['nonce'] for label, x in pin['senders'].items()}
    steps, addresses, runtimes = [], {}, {}
    safe_n = pin['safeNonce']
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
        art = d['verifier']['artifact'] if name == 'OverIssueFraudProofVerifier' else arts['contracts'][name]
        vals = values(target) if callable(values) else (values or {})
        rt = runtime_bytes(art, vals)
        a.need('nonempty_runtime_'+name, rt != '0x', True)
        runtimes[target] = rt
        add(sid, None, art['bytecode']+a.cast('abi-encode', signature, *args)[2:],
            [dict(kind='code', target=target, expected=rt)], creates=target)
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
    for suffix, target, setter, getter in (('registry', u.REG, 'setBLSAggregator', 'blsAggregator'),
        ('dvt', d['dvt'], 'setBLSAggregator', 'BLS_AGGREGATOR'), ('committee', d['committee'], 'setBlsAggregator', 'blsAggregator')):
        call('A8.'+suffix, target, setter+'(address)', (agg,), [address_pred(target, getter+'()', agg)])
    for suffix, who, active in (('new', agg, True), ('old', pin['oldAggregator'], False)):
        call('A9.'+suffix, u.REG, 'setReputationSource(address,bool)', (who, str(active).lower()),
            [word_pred(u.REG, 'isReputationSource(address)', int(active), who)])
    a.need('pop_count', len(d['pop']), 3)
    for i, pop in enumerate(d['pop']):
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
    steps[-1]['readbacks'] += [address_pred(verifier, 'AGGREGATOR()', agg), address_pred(verifier, 'REGISTRY()', u.REG)]
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
        op = dict(batch=True, targets=[u.SP]*len(data), data=data, predecessor=predecessor,
                  salt=a.keccak('manifest-v3/'+pin['blockHash']+'/'+inputs['sha256']+'/'+name))
        op['id'] = u.operation_hash(op['targets'], data, predecessor, op['salt'], True)
        operations[name] = op
        predecessor = op['id']
        for verb in ('schedule', 'execute'):
            inner = u.op_call(op, verb)
            h = u.safe_hash(inner, safe_n)
            sid = name+'_'+verb
            add(sid+'_approve', u.SAFE, a.calldata('approveHash(bytes32)', h),
                [word_pred(u.SAFE, 'approvedHashes(address,bytes32)', 1, a.APPROVER, h)],
                sender='approver', safeHash=h, inner=inner, operation=name)
            checks = [word_pred(u.TL, 'getOperationState(bytes32)', 1 if verb == 'schedule' else 3, op['id'])]
            if verb == 'schedule':
                checks += [dict(kind='eta', target=u.TL, signature='getTimestamp(bytes32)', args=[op['id']], delay=u.DELAY)]
            else:
                checks += [dict(kind=name)]
            add(sid+'_exec', u.SAFE, u.safe_payload(inner), checks, sender='executor', safeHash=h, inner=inner, operation=name)
            safe_n += 1
    call('B4', agg, 'applyFraudProofVerifier()', (), [address_pred(agg, 'fraudProofVerifier()', verifier)],
         skipIf=address_pred(agg, 'fraudProofVerifier()', verifier))
    return dict(schema=3, route='manifest-A-B', pin=copy.deepcopy(pin), externalInputs=copy.deepcopy(inputs),
        rebuild=arts, addresses=addresses, implementation=impl, extension=extension, operations=operations,
        steps=steps, controls=CONTROLS, gasPolicy=copy.deepcopy(u.GAS_POLICY), gasParams=list(u.GAS),
        activationScheduleNotBefore=max(0, pin['pendingAPNTsTokenEta']-u.DELAY))


def activation_eta_gate(plan, schedule_timestamp, execute_timestamp):
    a.need('6c_schedule_floor', schedule_timestamp >= plan['activationScheduleNotBefore'], True)
    a.need('6d_timelock_eta', execute_timestamp >= schedule_timestamp+u.DELAY, True)
    a.need('6d_token_eta', execute_timestamp >= plan['pin']['pendingAPNTsTokenEta'], True)


def b2_gate(rpc, plan, upgrade_block):
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


def check_predicate(rpc, p, timestamp=None):
    kind = p['kind']
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
        cost = sum(a.qty(s['tx']['gas'])*a.qty(s['tx']['maxFeePerGas'])+a.qty(s['tx']['value'])
                   for s in plan['steps'] if s['sender'] == label and not s.get('skipped', False))
        a.need('budget_'+label, plan['pin']['senders'][label]['balance'] >= cost, True)
        result[label] = cost
    plan['budgetsWei'] = result


def validate_plan(plan, inputs, frozen=False):
    a.need('external_inputs_match', plan['externalInputs'], inputs)
    expected = build_plan(plan['pin'], inputs)
    a.exact_keys('manifest_keys', plan, set(expected) | ({'budgetsWei'} if frozen else set()))
    for key in set(expected)-{'steps'}:
        a.need('manifest_'+key, plan[key], expected[key])
    a.need('manifest_length', len(plan['steps']), len(expected['steps']))
    for actual, derived in zip(plan['steps'], expected['steps']):
        extra = u.MEASURED_KEYS | {'skipped'} if frozen else set()
        if frozen and actual.get('skipped'):
            a.need('skip_only_B4', actual['id'], 'B4')
            extra = {'skipped'}
        a.exact_keys('manifest_step', actual, set(derived) | extra)
        for key in set(derived)-{'tx'}:
            a.need('manifest_step_'+key, actual[key], derived[key])
        a.exact_keys('manifest_tx', actual['tx'], set(derived['tx']) | ({'gas'} if frozen and not actual.get('skipped') else set()))
        for key, value in derived['tx'].items():
            a.need('manifest_tx_'+key, actual['tx'][key], value)
        if frozen and not actual.get('skipped'):
            u.validate_gas(actual)
    if frozen:
        checked = copy.deepcopy(plan)
        budget(checked)
        a.need('manifest_budget', checked['budgetsWei'], plan['budgetsWei'])


def pre_send(rpc, plan, step, context, measured=False):
    a.need('manifest_local_only', getattr(rpc, 'local', False), True)
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
    a.need('registry_owner', a.address(rpc, u.REG, 'owner()'), u.DEPLOYER)
    a.need('SP_owner', a.address(rpc, u.SP, 'owner()'), u.TL if context.get('transferred') else u.DEPLOYER)
    if context.get('frozen'):
        u.assert_frozen(rpc, plan['pin'])
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
            u.TL, 0, step['inner'], 0, 0, 0, 0, a.ZERO, a.ZERO, step['safeNonce'])
        a.need('onchain_safe_hash', h, step['safeHash'])
        u.check_op_hash(rpc, plan['operations'][step['operation']])
    if measured:
        u.validate_gas(step)
        probe = {k: v for k, v in a.tx_rpc(tx, gas_cap=u.MAX_CREATE_GAS if tx['to'] is None else a.GAS_CAP).items() if k != 'gas'}
        a.need('fresh_estimate', a.qty(rpc('eth_estimateGas', [probe, 'latest'])) <= a.qty(tx['gas']), True)
        a.need('block_gas_limit', a.qty(tx['gas']) <= a.qty(a.block_data(rpc, 'latest')['gasLimit']), True)
    return tx


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
        a.need('early_swap_window', a.qty(a.block_data(rpc, 'latest')['timestamp'])+1 < plan['pin']['pendingAPNTsTokenEta'], True)
        negative('early_swap', u.DEPLOYER, u.SP, 'executeAPNTsTokenChange()', (), 'InvalidConfiguration()')
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
        before = a.nonce(rpc, u.DEPLOYER)
        a.need('B4_skip', b4_needed(rpc, plan), False)
        a.need('B4_skip_nonce', a.nonce(rpc, u.DEPLOYER), before)
        controls.append(dict(control='verifier_skip', nonce=before, sent=False))


def run_manifest(remote, rpc, plan, out, calibrate=True):
    a.need('manifest_local_only', getattr(rpc, 'local', False), True)
    validate_plan(plan, plan['externalInputs'], frozen=not calibrate)
    for sender in plan['pin']['senders'].values():
        rpc('anvil_impersonateAccount', [sender['address']])
    context, records, controls = {}, [], []
    overrides = copy.deepcopy(getattr(rpc, 'archive_overrides', {}))
    for step in plan['steps']:
        a.process_alive(rpc.engine_process)
        sid = step['id']
        controls_at(rpc, plan, sid, controls)
        if sid == 'B4' and not b4_needed(rpc, plan):
            if not calibrate:
                a.need('frozen_B4_skip', step['skipped'], True)
            step['skipped'] = True
            records.append(dict(step=sid, skipped=True))
            continue
        if not calibrate:
            a.need('frozen_step_not_skipped', step['skipped'], False)
        if sid == 'activation_schedule_approve':
            gas_eta = u.uints(a.call(rpc, u.SP, 'gasParams()'))[8]
            u.wait_until(rpc, max(gas_eta, plan['activationScheduleNotBefore']))
        if sid.endswith('execute_exec'):
            u.wait_until(rpc, a.word(rpc, u.TL, 'getTimestamp(bytes32)', plan['operations'][step['operation']]['id']))
        if sid == 'B4':
            u.wait_until(rpc, a.word(rpc, plan['addresses']['BLSAggregator'], 'pendingFraudProofVerifierReadyAt()'))
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
        if sid == 'A16':
            context['frozen'] = True
            u.check_inventory(rpc, plan['pin'])
        if sid == 'upgrade_execute_exec':
            context['upgradeBlock'] = r['blockNumber']
        if sid == 'activation_schedule_exec':
            context['activationScheduledAt'] = timestamp
            activation_eta_gate(plan, timestamp, a.word(rpc, u.TL, 'getTimestamp(bytes32)', plan['operations']['activation']['id']))
        if 'safeHash' in step:
            u.safe_trace(rpc, plan, step, r)
            if sid.endswith('_exec'):
                u.safe_exec_events(r['logs'], step['safeHash'])
        step['skipped'] = False
        record = dict(step=sid, receipt=r, readbacks=observed, **evidence)
        records.append(record)
        u.log(out, record)
        a.trace_overrides(rpc, r, overrides)
    controls_at(rpc, plan, 'after_B4', controls)
    a.need('controls_complete', sorted(x['control'] for x in controls), sorted(CONTROLS))
    a.need('steps_complete', [x['step'] for x in records], [x['id'] for x in plan['steps']])
    u.assert_frozen(rpc, plan['pin'])
    accounting = balances(rpc, plan['pin']['pauseList'])
    accounting['cappedBalance'] = a.word(rpc, plan['pin']['capped'], 'balanceOf(address)', u.SP)
    a.need('post_swap_tracked', accounting['totalTrackedBalance'], BUFFER)
    a.need('post_swap_revenue', accounting['protocolRevenue'], BUFFER)
    a.need('post_swap_capped_balance', accounting['cappedBalance'], 0)
    solvency = solvency_probe(rpc, plan, accounting)
    a.write_json(out/'manifest-solvency.json', solvency)
    a.need('post_swap_solvency', solvency['allSolvent'], True)
    budget(plan)
    validate_plan(plan, plan['externalInputs'], frozen=True)
    result = dict(status='PASS', scope='Phases A/B only', steps=records, negativeControls=controls,
                  B2=context['B2'], postSwapAccounting=accounting)
    a.write_json(out/'manifest-simulate.json', result)
    return result


def solvency_probe(rpc, plan, initial):
    """Observe the design's buffer across real deposits/withdrawal, then revert.

    The manifest is unchanged. A known deficit is evidence and a hard STOP,
    never an implicit mint/top-up added to the reviewed transaction sequence.
    """
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
        u.receipt(rpc, u.fixture_tx(rpc, u.TL, u.SP,
            a.calldata('withdrawProtocolRevenue(address,uint256)', u.DEPLOYER, BUFFER)))
        observe('after_revenue_withdrawal')
    finally:
        a.need('solvency_fixture_restore', rpc('evm_revert', [snap]), True)
    for state in observations:
        state['solvent'] = state['cappedBalance'] >= state['totalTrackedBalance']
        state['shortfall'] = max(0, state['totalTrackedBalance']-state['cappedBalance'])
        a.need('solvency_accounting_sum', state['totalTrackedBalance'],
               state['protocolRevenue']+sum(state['operatorBalances'].values()))
    return dict(observations=observations, allSolvent=all(x['solvent'] for x in observations),
                invariant='APNTsCapped.balanceOf(SP) >= totalTrackedBalance', restored=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('plan', 'simulate'):
        p = sub.add_parser(name)
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
        sub.add_parser(name)
    args = parser.parse_args(argv)
    out = getattr(args, 'out', None)
    try:
        if args.command in ('sign', 'send'):
            print('STOP: manifest signing and sending are not implemented', file=sys.stderr)
            return 3
        a.need('output_empty', not out.exists() or (out.is_dir() and not any(out.iterdir())), True)
        out.mkdir(parents=True, exist_ok=True)
        inputs = external(args.inputs)
        release_gate(inputs, rebuild())
        if args.command == 'plan':
            pin = a.plan_json(args.pin.read_bytes())
            plan = build_plan(pin, inputs)
            # A skeleton is explicitly not a calibrated/reviewable release packet.
            a.write_json(out/'manifest-draft.json', plan)
        else:
            remote = a.RPC(args.rpc_file.read_text().strip())
            secondary = a.RPC(args.rpc_file_secondary.read_text().strip())
            pin = collect(remote, args.block, inputs)
            a.need('independent_pin', collect(secondary, args.block, inputs), pin)
            plan = a.load_plan(args.plan) if args.plan else build_plan(pin, inputs)
            a.need('simulation_pin', plan['pin'], pin)
            validate_plan(plan, inputs, frozen=bool(args.plan))
            frozen = copy.deepcopy(plan)
            with a.fork(remote, pin, out) as local:
                run_manifest(remote, local, plan, out, calibrate=not bool(args.plan))
            a.relay_evidence(out)
            a.need('engine_stderr', (out/'engine.stderr').stat().st_size, 0)
            a.need('pin_recheck', collect(remote, args.block, inputs), pin)
            if args.plan:
                a.need('frozen_plan_unchanged', plan, frozen)
            u.save_plan(out, plan)
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
