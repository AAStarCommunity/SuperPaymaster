#!/usr/bin/env python3
"""Offline Phase C tests: builder, worksheet, live gates and reverted-snapshot controls.

Every gate has a named control that asserts the gate name. probe_phase_c_gates.py suppresses
each gate in memory (a.need for that name becomes a no-op) and requires its control to fail.
"""
import sys
sys.dont_write_bytecode = True
import copy
from gate_assertions import assert_stop
import contextlib
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import test_manifest_exec as t

m, a, u = t.m, t.a, t.u
D, SP = u.DEPLOYER, u.SP
REAL_REBUILD_BASELINES = m.rebuild_baselines
REAL_FUNDING_GATE = m.funding_gate
WORDS9 = 'c(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)'


def config_raw(active=True, stake=1, ticket=2):
    return a.cast('abi-encode', 'c('+u.CONFIG_TYPE+')',
        '(%d,%d,3,4,5,6,7,%s,8,"ENDUSER",%s,9)' % (stake, ticket, str(active).lower(), D))


class Chain:
    """Pre-step state for one Phase C transaction. Unknown reads fail the test."""
    def __init__(self, plan, sid):
        self.local = True
        self.plan, pc, pin = plan, plan['phaseC'], plan['pin']
        c, p = plan['externalInputs']['data']['phaseC'], pin['phaseC']
        ids = [s['id'] for s in plan['steps']]
        done = set(ids[:ids.index(sid)]) if sid in ids else set(pc['steps'])
        addr, capped = pc['addresses'], pin['capped']
        self.X, self.S, self.O, self.B = addr['X'], addr['S'], c['accountOwner'], c['bundler']
        self.factory, self.ep = plan['addresses']['xPNTsFactoryV2'], pin['immutables']['entryPoint']
        self.now = pin['pendingAPNTsTokenEta']+10
        self.context = dict(passed={'activation_execute_exec', 'B4'} | done, activated=True)
        self.codes, self.storage, self.snapshots, self.sent = {}, {}, [], []
        self.balances = {self.O: p['owner']['balance']+(pc['ownerTopUp'] if 'C20' in done else 0),
                         self.B: p['bundler']['balance']}
        operator = list(pc['operatorBefore'])
        if 'C2.deposit' not in done:
            operator[0] = 0
        if 'C3.configure' in done:
            operator = list(pc['operatorAfter'])
        member = pc['accountMember'] or 'C7' in done
        allowance = [m.PC_CAP_L, 0] if 'C9.allowance' in done else [0, 0]
        total = [m.PC_CAP_L, 0] if 'C9.total' in done else [0, 0]
        held = p['capped']['deployerBalance']+(pc['cappedMint'] if 'C1_exec' in done else 0)
        w = {(SP, 'APNTS_TOKEN()'): int(capped, 16), (SP, 'gasParams()'): u.GAS+[0]*5, (SP, 'paused()'): 0,
             (SP, 'cachedPrice()'): [3000*10**8, self.now, 1, 8], (SP, 'aPNTsPriceUSD()'): pc['aPNTsPriceUSD'],
             (SP, 'protocolFeeBPS()'): pc['protocolFeeBPS'], (SP, 'xpntsFactory()'): int(self.factory, 16),
             (SP, 'totalTrackedBalance()'): m.BUFFER+pc['operatorTopUp'], (SP, 'protocolRevenue()'): m.BUFFER,
             (capped, 'minter()'): int(u.SAFE, 16), (capped, 'cap()'): p['capped']['cap'],
             (capped, 'totalSupply()'): pc['cappedSupplyBefore']+(pc['cappedMint'] if 'C1_exec' in done else 0),
             (capped, 'balanceOf(address)', D): held,
             (capped, 'balanceOf(address)', SP): m.BUFFER+pc['operatorTopUp'],
             (u.REG, 'hasRole(bytes32,address)', m.role_id('PAYMASTER_SUPER'), D): 1,
             (u.REG, 'hasRole(bytes32,address)', m.role_id('COMMUNITY'), D): 1,
             (u.REG, 'hasRole(bytes32,address)', m.role_id('ENDUSER'), self.S): int(member),
             (u.REG, 'getRoleConfig(bytes32)', m.role_id('ENDUSER')): p['endUser']['roleConfig'],
             (p['endUser']['mysbt'], 'verifyCommunityMembership(address,address)', self.S, D): int(member),
             (SP, 'sbtHolders(address)', self.S): int(member),
             (p['endUser']['gtoken'], 'balanceOf(address)', D): p['endUser']['deployerGToken'],
             (self.factory, 'getTokenAddress(address)', D): int(self.X, 16) if 'C3.deploy' in done else 0,
             (self.factory, 'getDeployedCount()'): int('C3.deploy' in done),
             (m.ACCOUNT_FACTORY, 'getAddress(address,uint256)', self.O, c['salt']): int(self.S, 16),
             (self.X, 'communityOwner()'): int(D, 16), (self.X, 'creditPolicy()'): 0, (self.X, 'pendingPolicyEta()'): 0,
             (self.X, 'maxSingleTxLimit()'): m.PC_XPNTS_TX_LIMIT, (self.S, 'owner()'): int(self.O, 16),
             (self.X, 'autoAllowance(address,address)', self.S, SP): allowance, (self.X, 'userTotal(address)', self.S): total,
             (self.X, 'renewalMode(address)', self.S): 0, (self.X, 'autoRenewUsed(address)', self.S): 0}
        for sig in ('debts(address)', 'lockedOf(address)', 'creditReservedOf(address)', 'balanceOf(address)'):
            w[(self.X, sig, self.S)] = 0
        for who in pin['pauseList']:
            w[(SP, 'operators(address)', who)] = operator if who == D else [0, 1, 1, 0, 0, 0, 0, 0, 0]
        for arm, target in (('SP', SP), ('VPM', addr['VPM']), ('TPM', addr['TPM'])):
            w[(self.ep, 'balanceOf(address)', target)] = pc['entryPointBefore'][arm]
        w[(addr['Q'], 'balanceOf(address)', self.S)] = 0
        if sid not in ids:
            # Post-Phase-C state: every funding target met, executed or omitted.
            for arm, target in (('SP', SP), ('VPM', addr['VPM']), ('TPM', addr['TPM'])):
                w[(self.ep, 'balanceOf(address)', target)] = pc['entryPointTargets'][arm]
            self.balances[self.B] = p['bundler']['balance']+pc['bundlerTopUp']
            w[(self.X, 'balanceOf(address)', self.S)] = pc['userTarget']
            w[(addr['Q'], 'balanceOf(address)', self.S)] = pc['feeTokenTarget']
            w[(addr['Q'], 'allowance(address,address)', self.S, addr['TPM'])] = pc['feeTokenTarget']
            w[(addr['T'], 'balanceOf(address)', self.S)] = pc['taskSender']
            w[(addr['T'], 'balanceOf(address)', m.DEAD)] = pc['taskRecipient']
        self.words = w
        if 'C5' in done or pc['accountExists']:
            self.codes[self.S] = '0x6000'

    def key(self, target, sig, args):
        return (target.lower(), sig, *[x.lower() if isinstance(x, str) else x for x in args])

    def call(self, rpc, target, sig, *args, block='latest'):
        value = self.words[self.key(target, sig, args)]
        if isinstance(value, str):
            return value
        values = value if isinstance(value, list) else [value]
        return '0x'+''.join(format(x, '064x') for x in values)

    def set(self, target, sig, *args, value):
        self.words[self.key(target, sig, args)] = value

    def get(self, target, sig, *args):
        return self.words[self.key(target, sig, args)]

    def __call__(self, method, params):
        if method == 'eth_getBlockByNumber':
            return dict(number='0x200', hash=t.base.HASH, timestamp=hex(self.now), gasLimit='0xbebc200')
        if method == 'eth_getCode':
            return self.codes.get(params[0], '0x')
        if method == 'eth_getBalance':
            return hex(self.balances.get(params[0], 0))
        if method == 'eth_getTransactionCount':
            return '0x0'
        if method in ('anvil_impersonateAccount',):
            return True
        if method == 'anvil_setBalance':
            self.balances[params[0]] = int(params[1], 16)
            return True
        if method == 'evm_snapshot':
            self.snapshots.append(copy.deepcopy((self.words, self.codes, self.balances, self.storage)))
            return hex(len(self.snapshots))
        if method == 'evm_revert':
            self.words, self.codes, self.balances, self.storage = self.snapshots.pop()
            return not getattr(self, 'fail_revert', False)
        if method == 'eth_getStorageAt':
            return '0x'+format(self.storage.get((params[0], int(params[1], 16)), 0), '064x')
        if method == 'anvil_setStorageAt':
            slot, value = int(params[1], 16), int(params[2], 16)
            self.storage[(params[0], slot)] = value
            self.hook(params[0], slot, value)
            return True
        raise AssertionError((method, params))

    def hook(self, target, slot, value):
        plan = self.plan
        if target == SP and slot == m.layout_slot(plan, 'SuperPaymaster', 'cachedPrice'):
            self.words[(SP, 'cachedPrice()')][0] = value
        for label, key in (('_auto', (self.X, 'autoAllowance(address,address)', self.S, SP)),
                           ('_budget', (self.X, 'userTotal(address)', self.S))):
            base = m.layout_slot(plan, 'xPNTsTokenV2', label)
            expected = m.mapping_slot(self.S, m.mapping_slot(SP, base)) if label == '_auto' else m.mapping_slot(self.S, base)
            if target == self.X and slot == expected:
                self.words[key][1] = value & (2**128-1)

    def receipt(self, rpc, tx, status='0x1'):
        """Effects of the fixture transactions sent by the snapshot controls."""
        self.sent.append(tx)
        to, data = tx['to'], tx['data']
        if data.startswith(a.keccak('mint(address,uint256)')[:10]) and to == self.plan['pin']['capped']:
            self.words[(to, 'totalSupply()')] += u.uints('0x'+data[10:])[1]
        elif to == self.factory:
            self.words[(self.factory, 'getDeployedCount()')] += 1
            self.words[(self.factory, 'getTokenAddress(address)', D)] = int(self.X, 16)
        elif to == u.REG:
            self.words[(u.REG, 'getRoleConfig(bytes32)', m.role_id('ENDUSER'))] = u.frozen_config(
                self.words[(u.REG, 'getRoleConfig(bytes32)', m.role_id('ENDUSER'))])
        elif to == SP:
            self.words[(SP, 'sbtHolders(address)', self.S)] = 0
        elif to == self.X:
            self.words[(self.X, 'pendingPolicyEta()')] = self.now+86400
        elif to == self.ep:
            target = u.addr_word(u.uints('0x'+data[10:])[0])
            self.words[(self.ep, 'balanceOf(address)', target)] += int(tx['value'], 16)
        elif to == self.S:
            self.words[(self.X, 'renewalMode(address)', self.S)] = 1
        else:
            raise AssertionError(tx)
        return dict(status=status, transactionHash='0x'+'34'*32)

    def patches(self):
        return [patch.object(a, 'call', side_effect=self.call), patch.object(u, 'receipt', side_effect=self.receipt)]


class PhaseCTests(unittest.TestCase):
    def setUp(self):
        t.ManifestTests.setUp(self)
        real = patch.object(m, 'funding_gate', REAL_FUNDING_GATE)
        real.start(); self.addCleanup(real.stop)
        self.pc = self.plan['phaseC']
        self.base_data = copy.deepcopy(self.data)

    def stop(self, gate, action):
        with assert_stop(self, gate) as caught:
            action()
        self.assertEqual(caught.exception.record['gate'], gate)
        return caught.exception.record

    def step(self, sid):
        return next(s for s in self.plan['steps'] if s['id'] == sid)

    # -- builder -----------------------------------------------------------------------
    def build(self, data=None, pin=None, stage='full'):
        path = Path(self.tmp.name)/('external-%d.json' % id(data))
        path.write_text(json.dumps(data or self.data))
        return m.build_plan(pin or self.pin, m.external(path, stage), stage)

    def test_full_plan_expands_every_row(self):
        ids = self.pc['steps']
        self.assertEqual(ids, ['C1_approve', 'C1_exec', 'C2.approve', 'C2.deposit', 'C3.deploy', 'C3.configure', 'C5',
            'C6', 'C7', 'C8', 'C20', 'C9.allowance', 'C9.total', 'C9.mode', 'C10', 'C11.S', 'C11.R', 'C12',
            'C13.token', 'C13.oracle', 'C14', 'C15', 'C16.vpm', 'C16.tpm', 'C17.vpm', 'C17.tpm',
            'C18.mint', 'C18.approve', 'C19'])
        # The post-A13 SP deposit (1e18) already exceeds 106 x M_SP: C17.sp is omitted before nonces.
        self.assertGreaterEqual(self.pc['entryPointBefore']['SP'], self.pc['entryPointTargets']['SP'])
        self.assertEqual(self.pc['entryPointTopUps']['SP'], 0)
        all_ids = [s['id'] for s in self.plan['steps']]
        self.assertEqual(all_ids[all_ids.index('B4')+1:all_ids.index('B4')+1+len(ids)], ids)
        self.assertEqual(all_ids[all_ids.index('B4')+1+len(ids)], 'D.registry.transfer')
        for s in self.plan['steps']:
            if s.get('phase') == 'C':
                self.assertTrue(s['readbacks'])
                self.assertNotIn('gas', s['tx'])
                self.assertEqual((s['tx']['maxFeePerGas'], s['tx']['maxPriorityFeePerGas']), (hex(a.MAX_FEE), hex(a.PRIORITY)))
        m.validate_plan(self.plan, self.inputs)

    def test_nonces_and_safe_order(self):
        steps = self.plan['steps']
        owner = [s for s in steps if s['sender'] == 'owner']
        self.assertEqual([s['id'] for s in owner], ['C9.allowance', 'C9.total', 'C9.mode', 'C18.approve'])
        self.assertEqual([a.qty(s['tx']['nonce']) for s in owner], [0, 1, 2, 3])
        self.assertTrue(all(s['tx']['from'] == t.PC_OWNER for s in owner))
        ids = [s['id'] for s in steps]
        # C20 funds O before O's first call.
        self.assertLess(ids.index('C20'), ids.index('C9.allowance'))
        safe = [(s['id'], s['safeNonce']) for s in steps if s['id'].endswith('_exec') and 'safeHash' in s]
        names = [x[0] for x in safe]
        self.assertEqual(names[names.index('activation_execute_exec')+1], 'C1_exec')
        self.assertEqual([n for _, n in safe], list(range(safe[0][1], safe[0][1]+len(safe))))
        c1 = self.step('C1_exec')
        self.assertEqual(c1['safeHash'], m.safe_hash(c1['inner'], c1['safeNonce'], self.pin['capped']))
        self.assertEqual(c1['inner'], a.calldata('mint(address,uint256)', D, self.pc['cappedMint']))
        d_steps = [s for s in steps if s['sender'] == 'deployer']
        self.assertEqual([a.qty(s['tx']['nonce']) for s in d_steps],
                         list(range(self.pin['senders']['deployer']['nonce'], self.pin['senders']['deployer']['nonce']+len(d_steps))))
        for s in steps:
            if s['tx']['to'] is None:
                self.assertEqual(s['creates'], a.create_address(D, a.qty(s['tx']['nonce'])))
        self.assertEqual(self.pc['addresses']['X'], a.create_address(self.plan['addresses']['xPNTsFactoryV2'], 1))

    def test_worksheet_formulas(self):
        pc, r = self.pc, self.data['phaseC']['rehearsal']
        arm = r['arms']['SP']
        bound = lambda x: (3*x+1)//2
        g = sum(bound(arm[k]) for k in ('call', 'verification', 'paymasterVerification', 'preVerification'))+480000
        M = g*5*10**9
        self.assertEqual(pc['maxPrefund']['SP'], M)
        a0 = -(-M*3500*10**8*10**18//(10**8*2*10**16))
        amax = -(-a0*(10000+1000+1000)//10000)
        self.assertEqual((pc['A0'], pc['Amax']), (a0, amax))
        self.assertEqual(pc['operatorTarget'], 105*amax)
        self.assertEqual(pc['cappedMint'], 105*amax-10**18)
        self.assertEqual(pc['userTarget'], 105*amax)
        for name in m.ARMS:
            self.assertEqual(pc['entryPointTargets'][name], 106*pc['maxPrefund'][name])
        self.assertEqual(pc['entryPointBefore']['SP'], 10**18)
        tpm = pc['maxPrefund']['TPM']
        self.assertEqual(pc['feeTokenTarget'], 105*(tpm+40000*5*10**9))
        outer = sum(bound(r['arms'][x]['outer']) for x in m.ARMS)
        self.assertEqual(pc['bundlerTarget'], 100*5*10**9*outer+5*10**9*bound(40000)+2*10**17)
        self.assertEqual(pc['bundlerTopUp'], pc['bundlerTarget']-10**17)
        self.assertEqual(pc['ownerTarget'], 4*bound(100000)*a.MAX_FEE+bound(50000)*5*10**9)
        self.assertEqual((pc['taskSender'], pc['taskRecipient']), (301, 1))
        self.assertEqual(pc['spRenew'], False)
        self.assertEqual(pc['callDataHash'], a.keccak(a.calldata('execute(address,uint256,bytes)', pc['addresses']['T'], 0,
            a.calldata('transfer(address,uint256)', m.DEAD, 1))))
        self.assertEqual(self.step('C8')['tx']['data'], a.calldata('mint(address,uint256)', t.PC_ACCOUNT, 105*amax))
        self.assertEqual(self.step('C9.allowance')['tx']['data'], a.calldata('execute(address,uint256,bytes)',
            pc['addresses']['X'], 0, a.calldata('setAutoAllowance(address,uint256)', SP, 50000*10**18)))
        self.assertEqual(self.step('C9.mode')['tx']['data'], a.calldata('execute(address,uint256,bytes)',
            pc['addresses']['X'], 0, a.calldata('setRenewalMode(uint8)', 0)))
        self.assertEqual(a.qty(self.step('C16.vpm')['tx']['value']), 10**18)
        self.assertEqual(a.qty(self.step('C17.tpm')['tx']['value']), 106*tpm)
        self.assertEqual(a.qty(self.step('C19')['tx']['value']), pc['bundlerTopUp'])
        self.assertEqual(self.step('C3.deploy')['tx']['data'], a.calldata('deployxPNTsToken(string,string,string,string,uint256,address)',
            'AOA Research Points', 'xARP', 'AOA Research', '', 10**18, a.ZERO))
        self.assertEqual(self.step('C3.configure')['tx']['data'], a.calldata('configureOperator(address,address)',
            pc['addresses']['X'], u.SAFE))

    def test_rounding_is_up_with_non_dividing_inputs(self):
        # Odd measurements and a non-dividing aPNTs price: ceil and floor differ at every step,
        # and the expected values come from exact rational arithmetic, not the executor's helpers.
        from fractions import Fraction
        from math import ceil, floor
        data, pin = copy.deepcopy(self.data), copy.deepcopy(self.pin)
        arms = data['phaseC']['rehearsal']['arms']
        arms['SP'].update(call=60001, verification=80003, paymasterVerification=120005, preVerification=50007)
        pin['phaseC']['sp']['aPNTsPriceUSD'] = 3*10**16+7
        pin['phaseC']['sp']['protocolFeeBPS'] = 1001
        pc = self.build(data, pin)['phaseC']
        raw = [arms['SP'][k] for k in ('call', 'verification', 'paymasterVerification', 'preVerification')]
        for value in raw:
            self.assertNotEqual(ceil(Fraction(3*value, 2)), floor(Fraction(3*value, 2)))
        M = (sum(ceil(Fraction(3*v, 2)) for v in raw)+480000)*5*10**9
        self.assertEqual(pc['maxPrefund']['SP'], M)
        a0 = Fraction(M*3500*10**8*10**18, 10**8*(3*10**16+7))
        self.assertNotEqual(ceil(a0), floor(a0))
        self.assertEqual(pc['A0'], ceil(a0))
        amax = Fraction(ceil(a0)*(10000+1001+1000), 10000)
        self.assertNotEqual(ceil(amax), floor(amax))
        self.assertEqual(pc['Amax'], ceil(amax))
        self.assertEqual(pc['operatorTarget'], 105*ceil(amax))

    def test_pin_price_zero(self):
        pin = copy.deepcopy(self.pin)
        pin['phaseC']['sp']['cachedPrice'] = [0, 0, 0, 8]
        self.stop('C_price_bound_pin', lambda: self.build(None, pin))

    def test_operator_fields_match_solidity_struct(self):
        import re
        source = (Path(m.u.ROOT)/'contracts/src/interfaces/ISuperPaymaster.sol').read_text()
        body = re.search(r'struct OperatorConfig \{(.*?)\n    \}', source, re.S).group(1)
        body = re.sub(r'//[^\n]*', '', body)
        fields = re.findall(r'^\s*\w+\s+(\w+);', body, re.M)
        self.assertEqual(tuple(fields), m.OPERATOR_FIELDS)
        index = {name: i for i, name in enumerate(fields)}
        before, after = self.pc['operatorBefore'], self.pc['operatorAfter']
        changed = {i for i, (x, y) in enumerate(zip(before, after)) if x != y}
        self.assertEqual(changed, {index['isConfigured'], index['xPNTsToken'], index['treasury']} - (
            {index['isConfigured']} if before[index['isConfigured']] == 1 else set()))
        self.assertEqual(after[index['xPNTsToken']], int(self.pc['addresses']['X'], 16))
        self.assertEqual(after[index['treasury']], int(u.SAFE, 16))
        self.assertEqual((after[index['aPNTsBalance']], after[index['isPaused']]), (self.pc['operatorTarget'], 0))
        pinned = self.pin['phaseC']['sp']['deployerOperator']
        for name in ('reputation', 'minTxInterval', 'totalSpent', 'totalTxSponsored'):
            self.assertEqual(after[index[name]], pinned[index[name]])

    def test_reduced_n_or_amount_is_refused(self):
        # n is never reduced to fit a budget; every amount is rebuilt from the pin.
        for key, mutate in (('manifest_plan_key_phaseC', lambda p: p['phaseC'].update(attempts=99)),
                            ('manifest_plan_key_phaseC', lambda p: p['phaseC'].update(Amax=p['phaseC']['Amax']-1)),
                            ('manifest_tx_field_value', lambda p: next(s for s in p['steps'] if s['id'] == 'C19')['tx'].update(value='0x1')),
                            ('manifest_tx_field_data', lambda p: next(s for s in p['steps'] if s['id'] == 'C9.mode')['tx'].update(
                                data=a.calldata('execute(address,uint256,bytes)', p['phaseC']['addresses']['X'], 0,
                                                a.calldata('setRenewalMode(uint8)', 1)))),
                            ('manifest_length', lambda p: p['steps'].remove(next(s for s in p['steps'] if s['id'] == 'C16.tpm')))):
            bad = copy.deepcopy(self.plan)
            mutate(bad)
            with self.subTest(gate=key):
                self.stop(key, lambda: m.validate_plan(bad, self.inputs))

    def test_tpm_constructor_and_baseline_provenance(self):
        step = self.step('C14')
        args = a.cast('abi-encode', m.TPM_CONSTRUCTOR, self.pc['addresses']['Q'], self.pin['immutables']['entryPoint'],
            m.DEAD, m.DEAD, '(%d,0,40000,864000)' % 10**26,
            '(864000,864000,%s,%s,true,false,false,%d)' % (self.pc['addresses']['oracle'], a.ZERO, 10**25), '(1,3000,5)', D)
        self.assertEqual(step['tx']['data'], t.BASELINES['TokenPaymaster']['bytecode']+args[2:])
        self.assertEqual(step['readbacks'][0], dict(kind='codeHash', target=step['creates'], expected=t.PC_RUNTIMES['TokenPaymaster']))
        self.assertEqual(self.pc['artifacts']['F1TestToken']['source'], m.F1_SOURCE)
        self.assertIn('local nodes only', self.pc['f1Provenance'])
        token = self.step('C10')['readbacks'][0]
        self.assertEqual(token['expected'], '0x'+D[2:].zfill(64)+'60')

    def test_omitted_rows_never_skip_nonces(self):
        data, pin = copy.deepcopy(self.data), copy.deepcopy(self.pin)
        p = pin['phaseC']
        p['capped']['deployerBalance'] = 10**30                     # no C1 mint deficit
        p['account'].update(codeHash=t.PC_RUNTIMES['account'], owner=t.PC_OWNER,
                            entryPoint=pin['immutables']['entryPoint'], implementationSlot=t.PC_IMPL, status=[1, 1, 1])
        p['owner']['balance'] = 10**20                               # no C20
        p['bundler']['balance'] = 10**20                             # no C19
        pin['entryPointDeposit'] = 10**20                            # no A13/C17 SP deposit
        plan = self.build(data, pin)
        ids = plan['phaseC']['steps']
        for omitted in ('C1_approve', 'C1_exec', 'C5', 'C6', 'C7', 'C17.sp', 'C19', 'C20'):
            self.assertNotIn(omitted, ids)
        d_steps = [s for s in plan['steps'] if s['sender'] == 'deployer']
        self.assertEqual([a.qty(s['tx']['nonce']) for s in d_steps],
                         list(range(pin['senders']['deployer']['nonce'], pin['senders']['deployer']['nonce']+len(d_steps))))
        m.validate_plan(plan, plan['externalInputs'])

    def test_stage_c_boundary_and_prefix(self):
        plan = self.build(stage='c')
        self.assertEqual((plan['stage'], plan['final']), ('c', False))
        self.assertEqual(plan['steps'][-1]['id'], plan['phaseC']['steps'][-1])
        m.verify_prefix(self.plan, plan, 'c')
        bad = copy.deepcopy(plan)
        bad['steps'] = bad['steps'][:-1]
        bad['prefixDigest'] = m.prefix_digest(bad)
        self.stop('prefix_boundary_phase_c', lambda: m.verify_prefix(self.plan, bad, 'c'))
        b4 = copy.deepcopy(self.plan)
        b4['steps'] = b4['steps'][:[s['id'] for s in b4['steps']].index('B4')+1]
        b4.update(stage='c', prefixDigest=m.prefix_digest(b4))
        self.stop('prefix_boundary_phase_c', lambda: m.verify_prefix(self.plan, b4, 'c'))
        # Phase C pin reads never change the A/B prefix digest.
        stripped = copy.deepcopy(self.plan)
        stripped['pin'].pop('phaseC')
        self.assertEqual(m.prefix_digest(stripped), m.prefix_digest(self.plan))

    def test_stage_c_artifact_never_final(self):
        plan = self.build(stage='c')
        out = Path(self.tmp.name)/'stage-c'
        out.mkdir()
        m.save_artifact(out, plan)
        self.assertTrue((out/'stage-c.json.sha256').exists())
        self.stop('final_stage', lambda: m.require_final(dict(plan, final=True)))
        self.stop('stage_not_final_save_artifact', lambda: m.save_artifact(out, dict(plan, final=True)))

    def test_stage_c_prefix_must_end_in_phase_c(self):
        plan = self.build(stage='c')
        bad = copy.deepcopy(plan)
        bad['steps'].append(copy.deepcopy(self.step('D.registry.transfer')))
        bad['prefixDigest'] = m.prefix_digest(bad)
        self.stop('prefix_boundary_last', lambda: m.verify_prefix(self.plan, bad, 'c'))

    def collect_fixture(self, pending=0, account_code='0x'):
        c, p = self.data['phaseC'], self.pin['phaseC']
        values = {('cap()',): 10**27, ('totalSupply()',): 0, ('aPNTsPriceUSD()',): 2*10**16, ('protocolFeeBPS()',): 1000}
        def word(rpc, target, sig, *args, block='latest'):
            if sig == 'hasRole(bytes32,address)': return 1
            if sig == 'verifyCommunityMembership(address,address)' or sig == 'sbtHolders(address)': return 0
            if sig == 'balanceOf(address)': return 1000*10**18 if target == t.PC_GTOKEN else 10**18
            if sig == 'accountImplementation()': return int(t.PC_IMPL, 16)
            if sig == 'owner()': return int(t.PC_OWNER, 16)
            if sig in ('entryPoint()',): return int(self.pin['immutables']['entryPoint'], 16)
            if sig == 'getAddress(address,uint256)': return int(t.PC_ACCOUNT, 16)
            return values[(sig, *args)]
        def address(rpc, target, sig, block='latest'):
            return dict(**{'minter()': u.SAFE, 'GTOKEN_STAKING()': t.PC_STAKING, 'GTOKEN()': t.PC_GTOKEN, 'MYSBT()': t.PC_MYSBT})[sig]
        def call(rpc, target, sig, *args, block='latest'):
            if sig == 'cachedPrice()': return '0x'+''.join(format(x, '064x') for x in p['sp']['cachedPrice'])
            if sig == 'operators(address)': return '0x'+''.join(format(x, '064x') for x in p['sp']['deployerOperator'])
            if sig == 'getRoleConfig(bytes32)': return p['endUser']['roleConfig']
            return '0x'+format(word(rpc, target, sig, *args), '064x')
        def nonce(rpc, who, block):
            return pending if block == 'pending' else 0
        def code(rpc, target, block):
            if target == t.PC_ACCOUNT: return account_code
            return {m.ACCOUNT_FACTORY: '0x6001', t.PC_IMPL: '0x6002'}.get(target, '0x')
        def rpc(method, params):
            if method == 'eth_getBalance': return {t.PC_BUNDLER: hex(10**17)}.get(params[0], '0x0')
            if method == 'eth_getStorageAt': return '0x'+t.PC_IMPL[2:].zfill(64)
            raise AssertionError((method, params))
        return rpc, [patch.object(a, 'word', side_effect=word), patch.object(a, 'address', side_effect=address),
                     patch.object(a, 'call', side_effect=call), patch.object(a, 'nonce', side_effect=nonce),
                     patch.object(u, 'code', side_effect=code)]

    def run_collect(self, **kw):
        rpc, patches = self.collect_fixture(**kw)
        with contextlib.ExitStack() as stack:
            for p in patches: stack.enter_context(p)
            return m.collect_phase_c(rpc, '0x100', self.inputs, self.pin)

    def test_collect_phase_c_reads(self):
        out = self.run_collect()
        self.assertEqual(set(out), {'owner', 'bundler', 'verifyingSigner', 'capped', 'sp', 'roles', 'endUser', 'account'})
        self.assertEqual(out['bundler'], dict(address=t.PC_BUNDLER, nonce=0, balance=10**17, code='0x'))
        self.assertEqual(out['capped'], self.pin['phaseC']['capped'])
        self.assertEqual(out['account']['factoryCodeHash'], a.keccak('0x6001'))
        self.assertEqual(out['account']['codeHash'], a.EMPTY_KECCAK)
        self.assertNotIn('owner', out['account'])
        existing = self.run_collect(account_code='0x6003')
        self.assertEqual((existing['account']['owner'], existing['account']['implementationSlot']),
                         (t.PC_OWNER, t.PC_IMPL))

    def test_collect_phase_c_pending_nonce(self):
        self.stop('phase_c_pending_nonce_owner', lambda: self.run_collect(pending=1))

    def baseline_tree(self, case=None):
        """Synthetic archive and forge outputs for rebuild_baselines' own gates."""
        def archive(repo, commit, tree):
            out = tree/'out/F1Fixtures.sol'
            out.mkdir(parents=True)
            for name, refs in (('F1TestToken', {'7': [dict(start=0, length=32)]}), ('F1Oracle', {})):
                out.joinpath(name+'.json').write_text(json.dumps(dict(bytecode=dict(object='0x6000'),
                    deployedBytecode=dict(object='0x'+'00'*32, immutableReferences=refs))))
            for name, path in m.BASELINE_ARTIFACTS.items():
                source = tree/('src/'+name+'.sol')
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text('contract '+name+' {}')
                import hashlib
                ctor = [dict(type='constructor', inputs=[dict(type='address')])]
                if case == 'constructors' and name == 'TokenPaymaster':
                    ctor = ctor*2
                art = dict(source='src/'+name+'.sol', sourceSha256=('0'*64 if case == 'source' and name == 'VerifyingPaymaster'
                           else hashlib.sha256(source.read_bytes()).hexdigest()), abi=ctor, bytecode='0x6000')
                (tree/path).parent.mkdir(parents=True, exist_ok=True)
                (tree/path).write_text(json.dumps(art))
        def run(args, **kw):
            version = 'forge Version: 1.7.0' if case == 'version' else 'forge Version: 1.7.1'
            if args[1:] == ['--version']:
                return unittest.mock.Mock(stdout=version+'\n', returncode=0)
            return unittest.mock.Mock(returncode=int(case == 'build'), stdout=b'', stderr=b'')
        identity = lambda art, info, name, allowed: dict(artifactRuntime=art['deployedBytecode']['object'],
            ranges=[dict(name='OWNER' if case == 'immutables' else 'MINTER', start=0, length=32)])
        return [patch.object(a, 'archive_commit', side_effect=archive), patch.object(m.subprocess, 'run', side_effect=run),
                patch.object(a, 'immutable_identity', side_effect=identity)]

    def rebuild(self, case=None):
        with contextlib.ExitStack() as stack:
            for p in self.baseline_tree(case): stack.enter_context(p)
            return REAL_REBUILD_BASELINES.__wrapped__('a'*40)

    def test_rebuild_baselines_synthetic(self):
        out = self.rebuild()
        self.assertEqual(sorted(out), ['F1Oracle', 'F1TestToken', 'TokenPaymaster', 'VerifyingPaymaster'])
        self.assertEqual(out['VerifyingPaymaster']['constructor'], 'c(address)')
        self.assertEqual(out['F1Oracle']['runtimeIdentity']['ranges'], [])

    def test_a7_b4_ignore_phase_c_pin(self):
        early = copy.deepcopy(self.inputs)
        early['data'].pop('pop'); early['data'].pop('fraudProofFixture')
        stripped = {k: v for k, v in self.pin.items() if k != 'phaseC'}
        self.assertEqual(m.build_plan(self.pin, early, 'a7'), m.build_plan(stripped, early, 'a7'))
        self.assertNotIn('phaseC', m.build_plan(self.pin, early, 'a7'))


def data_case(path, value=None, delete=False):
    def mutate(data, pin, case):
        target = data
        for key in path[:-1]:
            target = target[key]
        if delete:
            del target[path[-1]]
        else:
            target[path[-1]] = value(case) if callable(value) else copy.deepcopy(value)
    return mutate


def pin_case(path, value):
    def mutate(data, pin, case):
        target = pin
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value(case) if callable(value) else copy.deepcopy(value)
    return mutate


def evidence(name, content):
    def value(case):
        return case.file_ref(name, content) if not isinstance(content, str) else ref_bytes(case, name, content)
    return value


def ref_bytes(case, name, content):
    path = Path(case.tmp.name)/(name+'.txt')
    path.write_text(content)
    import hashlib
    return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())


ARM = ['phaseC', 'rehearsal', 'arms']
BUILD_CASES = {
    'phase_c_inputs': data_case(['phaseC', 'extra'], 1),
    'phase_c_address_bundler': data_case(['phaseC', 'bundler'], t.PC_BUNDLER.upper().replace('0X', '0x')),
    'phase_c_identity_distinct': data_case(['phaseC', 'bundler'], u.DEPLOYER),
    'phase_c_account_distinct': data_case(['phaseC', 'account'], m.DEAD),
    'phase_c_salt': data_case(['phaseC', 'salt'], -1),
    'phase_c_runtime_keys': data_case(['phaseC', 'runtimeKeccak', 'unexpected'], a.EMPTY_KECCAK),
    'phase_c_runtime_VerifyingPaymaster': data_case(['phaseC', 'runtimeKeccak', 'VerifyingPaymaster'], a.EMPTY_KECCAK),
    'phase_c_account_evidence_bytes': data_case(['phaseC', 'accountEvidence', 'sha256'], '9'*64),
    'phase_c_account_evidence_nonempty': data_case(['phaseC', 'accountEvidence'], evidence('blank-account', ' \n')),
    'phase_c_rehearsal': data_case(['phaseC', 'rehearsal', 'extra'], []),
    'phase_c_rehearsal_evidence_nonempty': data_case(['phaseC', 'rehearsal', 'evidence'], evidence('blank-rehearsal', '\n')),
    'phase_c_arms': data_case(ARM+['extra'], {}),
    'phase_c_arm_fields_SP': data_case(ARM+['SP', 'postOp'], 1),
    'phase_c_measurement_arms': data_case(ARM+['VPM', 'call'], 0),
    'phase_c_owner_preparation': data_case(['phaseC', 'rehearsal', 'ownerPreparation', 'extra'], 1),
    'phase_c_maintenance_list': data_case(['phaseC', 'rehearsal', 'ownerMaintenance'], {}),
    'phase_c_maintenance_fields': data_case(['phaseC', 'rehearsal', 'bundlerMaintenance'], [dict(name='x', gas=1, extra=1)]),
    'phase_c_maintenance_name': data_case(['phaseC', 'rehearsal', 'bundlerMaintenance'], [dict(name=' x', gas=1)]),
    'phase_c_maintenance_unique': data_case(['phaseC', 'rehearsal', 'bundlerMaintenance'],
                                            [dict(name='x', gas=1), dict(name='x', gas=2)]),
    'stage_inputs': data_case(['phaseC'], delete=True),
    'sampled_deployer_only': data_case(['sampled'], sorted([u.DEPLOYER, t.ANNI])),
    'C_amax_cap': data_case(ARM+['SP', 'call'], 10**9),
    'stage_pin_phase_c': lambda data, pin, case: pin.pop('phaseC'),
    'phase_c_pin': pin_case(['phaseC', 'extra'], 1),
    'phase_c_pin_identity_owner': pin_case(['phaseC', 'owner', 'address'], '0x'+'99'*20),
    'phase_c_eoa_bundler': pin_case(['phaseC', 'bundler', 'code'], '0x6000'),
    'C1_minter_pin': pin_case(['phaseC', 'capped', 'minter'], u.DEPLOYER),
    'C_price_shape': pin_case(['phaseC', 'sp', 'cachedPrice'], [1, 2, 3]),
    'C_price_bound_pin': pin_case(['phaseC', 'sp', 'cachedPrice'], [3500*10**8+1, 0, 1, 8]),
    'C_pricing_nonzero': pin_case(['phaseC', 'sp', 'aPNTsPriceUSD'], 0),
    'C_operator_shape': pin_case(['phaseC', 'sp', 'deployerOperator'], [0]*8),
    'C2_operator_role_pin': pin_case(['phaseC', 'roles', 'PAYMASTER_SUPER'], 0),
    'C3_community_pin': pin_case(['phaseC', 'roles', 'COMMUNITY'], 0),
    'C7_enduser_active_pin': pin_case(['phaseC', 'endUser', 'roleConfig'], lambda case: config_raw(active=False)),
    'C5_factory_runtime': pin_case(['phaseC', 'account', 'factoryCodeHash'], '0x'+'77'*32),
    'C5_factory_implementation': pin_case(['phaseC', 'account', 'implementation'], '0x'+'77'*20),
    'C5_implementation_runtime': pin_case(['phaseC', 'account', 'implementationCodeHash'], '0x'+'77'*32),
    'C5_implementation_entrypoint': pin_case(['phaseC', 'account', 'implementationEntryPoint'], '0x'+'77'*20),
    'C5_counterfactual_pin': pin_case(['phaseC', 'account', 'counterfactual'], '0x'+'77'*20),
    'C5_existing_account': pin_case(['phaseC', 'account', 'codeHash'], t.PC_RUNTIMES['account']),
    'C_account_status_pin': pin_case(['phaseC', 'account', 'status'], [1, 0, 0]),
    'C1_cap_headroom_worksheet': pin_case(['phaseC', 'capped', 'cap'], 10**18),
    'C6_gtoken_balance_worksheet': pin_case(['phaseC', 'endUser', 'deployerGToken'], 2),
    'budget_deployer_values': pin_case(['senders', 'deployer', 'balance'], 10**18),
}


def make_build_test(gate, mutate):
    def test(self):
        data, pin = copy.deepcopy(self.data), copy.deepcopy(self.pin)
        mutate(data, pin, self)
        if gate == 'C_pricing_nonzero':
            self.stop(gate, lambda: m.phase_c_pin_gates(pin, data['phaseC']))
            return
        if gate == 'stage_inputs':
            self.stop(gate, lambda: m.required(data, ('phaseC',), gate))
            return
        if gate == 'stage_pin_phase_c':
            self.stop(gate, lambda: m.stage_pin(pin, 'full'))
            return
        record = self.stop(gate, lambda: self.build(data, pin))
        if gate.startswith('budget_'):
            self.assertGreater(record['observed']['shortfallWei'], 0)
            self.assertEqual(record['observed']['requiredWei']-record['observed']['balanceWei'], record['observed']['shortfallWei'])
    return test


for _gate, _mutate in BUILD_CASES.items():
    setattr(PhaseCTests, 'test_build_'+_gate, make_build_test(_gate, _mutate))
REBUILD_CASES = {'baseline_forge_version': 'version', 'baseline_offline_build': 'build',
                 'baseline_immutables_F1TestToken': 'immutables', 'baseline_source_VerifyingPaymaster': 'source',
                 'baseline_constructor_count_TokenPaymaster': 'constructors'}
for _gate, _case in REBUILD_CASES.items():
    setattr(PhaseCTests, 'test_rebuild_'+_gate, lambda self, g=_gate, c=_case: self.stop(g, lambda: self.rebuild(c)))


class BaselineGateTests(PhaseCTests):
    def baseline(self, name, **change):
        bad = copy.deepcopy(t.BASELINES)
        bad[name].update(change)
        with patch.object(m, 'rebuild_baselines', return_value=bad):
            return self.build()

    def test_build_C12_constructor_abi(self):
        self.stop('C12_constructor_abi', lambda: self.baseline('VerifyingPaymaster', constructor='c(address)'))

    def test_build_C14_constructor_abi(self):
        self.stop('C14_constructor_abi', lambda: self.baseline('TokenPaymaster', constructor=m.VPM_CONSTRUCTOR))

    def test_build_C_baseline_commit_F1TestToken(self):
        self.stop('C_baseline_commit_F1TestToken', lambda: self.baseline('F1TestToken', commit='9'*40))


for _name in [n for n in dir(PhaseCTests) if n.startswith('test_')]:
    setattr(BaselineGateTests, _name, None)


# -- live gates (pre_send, precheck, accounting) ------------------------------------------
LIVE_CASES = {
    'C_after_activation': ('C2.approve', lambda c: c.context['passed'].discard('B4')),
    'C_after_token_eta': ('C2.approve', lambda c: setattr(c, 'now', c.plan['pin']['pendingAPNTsTokenEta']-1)),
    'C_token_swapped': ('C2.approve', lambda c: c.set(SP, 'APNTS_TOKEN()', value=int(m.DEAD, 16))),
    'C_gas_tuple': ('C2.approve', lambda c: c.set(SP, 'gasParams()', value=u.GAS+[1, 0, 0, 0, 0])),
    'C_global_unpaused': ('C2.approve', lambda c: c.set(SP, 'paused()', value=1)),
    'C_sampled_unpaused': ('C2.approve', lambda c: c.get(SP, 'operators(address)', D).__setitem__(2, 1)),
    'C_unsampled_paused': ('C2.approve', lambda c: c.get(SP, 'operators(address)', t.ANNI).__setitem__(2, 0)),
    'C_price_decimals': ('C2.approve', lambda c: c.get(SP, 'cachedPrice()').__setitem__(3, 18)),
    'C_price_bound_exec': ('C2.approve', lambda c: c.get(SP, 'cachedPrice()').__setitem__(0, 3500*10**8+1)),
    'C_pricing_unchanged': ('C2.approve', lambda c: c.set(SP, 'protocolFeeBPS()', value=1001)),
    'C1_minter_exec': ('C1_approve', lambda c: c.set(c.plan['pin']['capped'], 'minter()', value=int(D, 16))),
    'C1_cap_headroom_exec': ('C1_exec', lambda c: c.set(c.plan['pin']['capped'], 'totalSupply()', value=10**27)),
    'C1_pinned_balance': ('C1_approve', lambda c: c.set(c.plan['pin']['capped'], 'balanceOf(address)', D, value=0)),
    'C2_operator_role_exec': ('C2.approve', lambda c: c.set(u.REG, 'hasRole(bytes32,address)', m.role_id('PAYMASTER_SUPER'), D, value=0)),
    'C2_token_balance': ('C2.approve', lambda c: c.set(c.plan['pin']['capped'], 'balanceOf(address)', D,
                                                        value=c.plan['phaseC']['operatorTopUp']-1)),
    'C_operator_before_configure': ('C3.configure', lambda c: c.get(SP, 'operators(address)', D).__setitem__(4, 1)),
    'C3_factory_active': ('C3.deploy', lambda c: c.set(SP, 'xpntsFactory()', value=0)),
    'C3_community_exec': ('C3.deploy', lambda c: c.set(u.REG, 'hasRole(bytes32,address)', m.role_id('COMMUNITY'), D, value=0)),
    'C3_factory_fresh': ('C3.deploy', lambda c: c.set(c.factory, 'getDeployedCount()', value=1)),
    'C5_counterfactual_exec': ('C5', lambda c: c.set(m.ACCOUNT_FACTORY, 'getAddress(address,uint256)', c.O, 7, value=1)),
    'C5_absent': ('C5', lambda c: c.codes.__setitem__(c.S, '0x6000')),
    'C7_enduser_active_exec': ('C6', lambda c: c.set(u.REG, 'getRoleConfig(bytes32)', m.role_id('ENDUSER'), value=config_raw(False))),
    'C7_enduser_config': ('C7', lambda c: c.set(u.REG, 'getRoleConfig(bytes32)', m.role_id('ENDUSER'), value=config_raw(True, 5))),
    'C_account_status_exec': ('C6', lambda c: c.set(SP, 'sbtHolders(address)', c.S, value=1)),
    'C6_gtoken_balance_exec': ('C6', lambda c: c.set(c.plan['pin']['phaseC']['endUser']['gtoken'], 'balanceOf(address)', D, value=1)),
    'C8_community_owner': ('C8', lambda c: c.set(c.X, 'communityOwner()', value=1)),
    'C8_policy_off': ('C8', lambda c: c.set(c.X, 'pendingPolicyEta()', value=1)),
    'C8_user_clean': ('C8', lambda c: c.set(c.X, 'debts(address)', c.S, value=1)),
    'C8_amax_limit': ('C8', lambda c: c.set(c.X, 'maxSingleTxLimit()', value=c.plan['phaseC']['Amax']-1)),
    'C9_account_owner': ('C9.allowance', lambda c: c.set(c.S, 'owner()', value=1)),
    'C_owner_budget': ('C9.allowance', lambda c: c.balances.__setitem__(c.O, c.balances[c.O]-1)),
    'C9_counters': ('C9.total', lambda c: c.set(c.X, 'autoAllowance(address,address)', c.S, SP, value=[m.PC_CAP_L, 1])),
    'C_create_unused': ('C10', lambda c: c.codes.__setitem__(c.plan['phaseC']['addresses']['T'], '0x6000')),
    'C17_deposit_before': ('C17.vpm', lambda c: c.set(c.ep, 'balanceOf(address)', c.plan['phaseC']['addresses']['VPM'], value=1)),
    'C18_fee_balance': ('C18.mint', lambda c: c.set(c.plan['phaseC']['addresses']['Q'], 'balanceOf(address)', c.S, value=1)),
    'C19_recipient_balance': ('C19', lambda c: c.balances.__setitem__(c.B, 1)),
    'C19_recipient_eoa': ('C19', lambda c: c.codes.__setitem__(c.B, '0xef0100'+'11'*20)),
    'C20_recipient_balance': ('C20', lambda c: c.balances.__setitem__(c.O, 1)),
    'C20_recipient_eoa': ('C20', lambda c: c.codes.__setitem__(c.O, '0x6000')),
}
PRECHECK_CASES = {
    'SP_RENEW_never': (m.FLAG_SP_RENEW, lambda c: None),
    'precheck_renewal_mode': (0, lambda c: c.set(c.X, 'renewalMode(address)', c.S, value=1)),
    'precheck_allowance': (0, lambda c: c.set(c.X, 'autoAllowance(address,address)', c.S, SP,
                                               value=[m.PC_CAP_L, m.PC_CAP_L-c.plan['phaseC']['Amax']+1])),
    'precheck_total': (0, lambda c: c.set(c.X, 'userTotal(address)', c.S, value=[m.PC_CAP_L, m.PC_CAP_L-c.plan['phaseC']['Amax']+1])),
    # DSR H1: a raised cap would hide exhausted L; a lowered cap is a changed packet. Both STOP.
    'precheck_allowance_cap': (0, lambda c: c.set(c.X, 'autoAllowance(address,address)', c.S, SP, value=[2*m.PC_CAP_L, m.PC_CAP_L])),
    'precheck_total_cap': (0, lambda c: c.set(c.X, 'userTotal(address)', c.S, value=[m.PC_CAP_L-1, 0])),
    # Each cap in the other direction too (`__` suffix: same gate, second control).
    'precheck_allowance_cap__lowered': (0, lambda c: c.set(c.X, 'autoAllowance(address,address)', c.S, SP, value=[m.PC_CAP_L-1, 0])),
    'precheck_total_cap__raised': (0, lambda c: c.set(c.X, 'userTotal(address)', c.S, value=[2*m.PC_CAP_L, m.PC_CAP_L])),
}
FUNDING_CASES = {
    'C_funding_entrypoint_SP': lambda c: c.set(c.ep, 'balanceOf(address)', SP, value=c.plan['phaseC']['entryPointTargets']['SP']-1),
    'C_funding_entrypoint_VPM': lambda c: c.set(c.ep, 'balanceOf(address)', c.plan['phaseC']['addresses']['VPM'], value=0),
    'C_funding_entrypoint_TPM': lambda c: c.set(c.ep, 'balanceOf(address)', c.plan['phaseC']['addresses']['TPM'], value=1),
    'C_funding_bundler': lambda c: c.balances.__setitem__(c.B, c.plan['phaseC']['bundlerTarget']-1),
    'C_funding_owner': lambda c: c.balances.__setitem__(c.O, c.plan['phaseC']['ownerMaintenanceWei']-1),
    'C_funding_user': lambda c: c.set(c.X, 'balanceOf(address)', c.S, value=1),
    'C_funding_feeToken': lambda c: c.set(c.plan['phaseC']['addresses']['Q'], 'balanceOf(address)', c.S, value=1),
    'C_funding_taskSender': lambda c: c.set(c.plan['phaseC']['addresses']['T'], 'balanceOf(address)', c.S, value=300),
    'C_funding_taskRecipient': lambda c: c.set(c.plan['phaseC']['addresses']['T'], 'balanceOf(address)', m.DEAD, value=0),
    'C_funding_feeAllowance': lambda c: c.set(c.plan['phaseC']['addresses']['Q'], 'allowance(address,address)', c.S,
                                              c.plan['phaseC']['addresses']['TPM'], value=1),
    # The allowance is exact: a larger approval is also a changed state.
    'C_funding_feeAllowance__above': lambda c: c.set(c.plan['phaseC']['addresses']['Q'], 'allowance(address,address)', c.S,
                                              c.plan['phaseC']['addresses']['TPM'], value=c.plan['phaseC']['feeTokenTarget']+1),
    'C_funding_operator': lambda c: c.get(SP, 'operators(address)', D).__setitem__(0, c.plan['phaseC']['operatorTarget']-1),
}


class LiveGateTests(PhaseCTests):
    def chain(self, sid):
        return Chain(self.plan, sid)

    def pre(self, chain, sid):
        with contextlib.ExitStack() as stack:
            for p in chain.patches():
                stack.enter_context(p)
            return m.phase_c_pre_send(chain, self.plan, self.step(sid), chain.context)

    def test_every_phase_c_step_passes_clean_state(self):
        for sid in self.pc['steps']:
            with self.subTest(step=sid):
                self.pre(self.chain(sid), sid)

    def precheck(self, chain, flags=0):
        with chain.patches()[0]:
            return m.sp_attempt_precheck(chain, self.plan, flags)

    def test_precheck_clean_state(self):
        result = self.precheck(self.chain('after_phase_c'))
        self.assertEqual(result['Amax'], self.pc['Amax'])

    def test_accounting(self):
        chain = self.chain('after_phase_c')
        with chain.patches()[0]:
            state = m.phase_c_accounting(chain, self.plan)
            self.assertEqual(state['cappedBalance'], m.BUFFER+self.pc['operatorTopUp'])
            chain.set(SP, 'totalTrackedBalance()', value=m.BUFFER)
            self.stop('C_accounting', lambda: m.phase_c_accounting(chain, self.plan))

    def test_owner_gas_bound(self):
        plan = copy.deepcopy(self.plan)
        for s in plan['steps']:
            t.freeze_gas(plan, s)
        target = next(s for s in plan['steps'] if s['id'] == 'C9.allowance')
        target.update(estimateGas=200000, localEstimateGas=200000, forkGasUsed=200000)
        target['tx']['gas'] = hex(u.margin_limit(200000))
        plan['budgetsWei'] = {}
        self.stop('C_owner_gas_bound', lambda: m.validate_plan(plan, self.inputs, frozen=True))
        self.stop('C_owner_gas_bound', lambda: m.owner_gas_gate(target))
        target['tx']['gas'] = hex(target['gasBound'])
        m.owner_gas_gate(target)

    def test_budget_owner_shortfall(self):
        plan = copy.deepcopy(self.plan)
        for s in plan['steps']:
            s['tx']['gas'] = hex(s.get('gasBound', 100000))
            for tx in s.get('variants', {}).values(): tx['gas'] = hex(100000)
        m.budget(plan)
        target = next(s for s in plan['steps'] if s['id'] == 'C18.approve')
        target['tx']['gas'] = hex(target['gasBound']+1)
        record = self.stop('budget_owner', lambda: m.budget(plan))
        self.assertEqual(record['observed']['shortfallWei'], a.MAX_FEE)

    def test_budget_reports_exact_one_wei_shortfall(self):
        # DSR F-02 (2026-11-05): both Phase C budget reports use {requiredWei, balanceWei, shortfallWei} and
        # report the shortfall to the wei.
        values = self.pc['deployerValueWei']
        pin = copy.deepcopy(self.pin)
        pin['senders']['deployer']['balance'] = values-1
        record = self.stop('budget_deployer_values', lambda: self.build(pin=pin))
        self.assertEqual(record['observed'], dict(balanceWei=values-1, requiredWei=values, shortfallWei=1))
        # O must hold a real (non-negative) balance: build with O already holding some ETH, so the planned C20
        # top-up covers only the rest, then lose one wei of it before sending.
        pin = copy.deepcopy(self.pin)
        held = 10**15
        pin['phaseC']['owner']['balance'] = held
        plan = self.build(pin=pin)
        for s in plan['steps']:
            s['tx']['gas'] = hex(s.get('gasBound', 100000))
            for tx in s.get('variants', {}).values(): tx['gas'] = hex(100000)
        m.budget(plan)
        pc = plan['phaseC']
        required = plan['budgetsWei']['owner']+pc['ownerMaintenanceWei']
        self.assertEqual(held+pc['ownerTopUp'], required)
        plan['pin']['phaseC']['owner']['balance'] = held-1
        record = self.stop('budget_owner', lambda: m.budget(plan))
        self.assertEqual(record['observed'], dict(balanceWei=required-1, requiredWei=required, shortfallWei=1))

    def test_handover_requires_phase_c(self):
        step = self.step('D.registry.transfer')
        passed = {s['id'] for s in self.plan['steps'] if not s['id'].startswith('D.')}
        with patch.object(m, 'funding_gate', return_value={'synthetic': True}) as funding:
            context = dict(passed=passed)
            m.handover_gate(None, self.plan, step, context)
            self.assertEqual(context['handoverFunding'], [{'synthetic': True}])
            self.stop('handover_dependencies', lambda: m.handover_gate(None, self.plan, step, dict(passed=passed-{'C19'})))
            self.assertEqual(funding.call_count, 1)

    def funding(self, chain):
        with chain.patches()[0]:
            return m.funding_gate(chain, self.plan)

    def test_funding_clean_state_and_block_binding(self):
        result = self.funding(self.chain('after_phase_c'))
        self.assertEqual((result['block'], result['blockHash']), ('0x200', t.base.HASH))
        self.assertEqual(result['entryPointSP'], self.pc['entryPointTargets']['SP'])
        precheck = self.precheck(self.chain('after_phase_c'))
        self.assertEqual((precheck['block'], precheck['blockHash'], precheck['L']), ('0x200', t.base.HASH, m.PC_CAP_L))

    def test_funding_omitted_rows_rechecked(self):
        # DSR M1: C17.sp and C19 omitted at build time (targets already met at the pin);
        # a later drop below target still STOPs.
        pin = copy.deepcopy(self.pin)
        pin['entryPointDeposit'] = 10**20
        pin['phaseC']['bundler']['balance'] = 10**20
        plan = self.build(None, pin)
        self.assertNotIn('C17.sp', plan['phaseC']['steps'])
        self.assertNotIn('C19', plan['phaseC']['steps'])
        self.plan, self.pc = plan, plan['phaseC']
        chain = self.chain('after_phase_c')
        self.funding(chain)
        chain.set(chain.ep, 'balanceOf(address)', SP, value=self.pc['entryPointTargets']['SP']-1)
        self.stop('C_funding_entrypoint_SP', lambda: self.funding(chain))
        chain = self.chain('after_phase_c')
        chain.balances[chain.B] = self.pc['bundlerTarget']-1
        self.stop('C_funding_bundler', lambda: self.funding(chain))



def make_live_test(gate, sid, mutate):
    def test(self):
        chain = self.chain(sid)
        self.pre(chain, sid)
        mutate(chain)
        self.stop(gate, lambda: self.pre(chain, sid))
    return test


def make_precheck_test(gate, flags, mutate):
    gate = gate.split('__')[0]
    def test(self):
        chain = self.chain('after_phase_c')
        self.precheck(chain)
        mutate(chain)
        self.stop(gate, lambda: self.precheck(chain, flags))
    return test


for _gate, (_sid, _mutate) in LIVE_CASES.items():
    setattr(LiveGateTests, 'test_live_'+_gate, make_live_test(_gate, _sid, _mutate))
for _gate, (_flags, _mutate) in PRECHECK_CASES.items():
    setattr(LiveGateTests, 'test_precheck_'+_gate, make_precheck_test(_gate, _flags, _mutate))


def make_funding_test(gate, mutate):
    gate = gate.split('__')[0]
    def test(self):
        chain = self.chain('after_phase_c')
        self.funding(chain)
        mutate(chain)
        self.stop(gate, lambda: self.funding(chain))
    return test


for _gate, _mutate in FUNDING_CASES.items():
    setattr(LiveGateTests, 'test_funding_'+_gate, make_funding_test(_gate, _mutate))
for _name in [n for n in dir(PhaseCTests) if n.startswith('test_')]:
    setattr(LiveGateTests, _name, None)


# -- reverted-snapshot controls -----------------------------------------------------------
class SnapshotControlTests(PhaseCTests):
    def run_controls(self, sids=None):
        controls = []
        for sid in sids or self.pc['steps']+['after_phase_c']:
            chain = Chain(self.plan, sid)
            with contextlib.ExitStack() as stack:
                for p in chain.patches():
                    stack.enter_context(p)
                m.phase_c_controls(chain, self.plan, sid, controls, chain.context)
            self.assertEqual(chain.snapshots, [])
        return controls

    def test_all_controls_fire_and_restore(self):
        controls = self.run_controls()
        self.assertEqual(sorted(x['control'] for x in controls), sorted(m.PC_CONTROLS))
        gates = {x['control']: x['gate'] for x in controls}
        self.assertEqual(gates, {'C_price_above_cap': 'C_price_bound_exec', 'C_cap_exhausted': 'C1_cap_headroom_exec',
            'C_factory_used': 'C3_factory_fresh', 'C_enduser_inactive': 'C7_enduser_active_exec',
            'C_status_mismatch': 'C_account_status_exec', 'C_policy_pending': 'C8_policy_off',
            'C_owner_underfunded': 'C_owner_budget', 'C_deposit_front_run': 'C17_deposit_before',
            'C_allowance_exhausted': 'precheck_allowance', 'C_total_exhausted': 'precheck_total',
            'C_sp_renew': 'SP_RENEW_never', 'C_renewal_mode': 'precheck_renewal_mode',
            'C_bundler_drained': 'C_funding_bundler'})
        self.assertTrue(all(x['restored'] for x in controls))

    def test_not_applicable_controls_are_explicit(self):
        data, pin = copy.deepcopy(self.data), copy.deepcopy(self.pin)
        pin['phaseC']['capped']['deployerBalance'] = 10**30
        plan = self.build(data, pin)
        self.assertNotIn('C1_approve', plan['phaseC']['steps'])
        self.plan, self.pc = plan, plan['phaseC']
        controls = self.run_controls()
        self.assertEqual(sorted(x['control'] for x in controls), sorted(m.PC_CONTROLS))
        self.assertEqual(next(x for x in controls if x['control'] == 'C_cap_exhausted')['notApplicable'],
                         'C1 omitted: zero mint deficit')

    def test_control_must_fire_named_gate(self):
        chain = Chain(self.plan, 'C2.approve')
        with chain.patches()[0]:
            check = lambda: m.phase_c_pre_send(chain, self.plan, self.step('C2.approve'), chain.context)
            self.stop('X_gate', lambda: m.stop_control(chain, 'X', 'C_price_bound_exec', lambda: None, check))
            mutate = lambda: chain.set(SP, 'paused()', value=1)
            self.stop('X_gate', lambda: m.stop_control(chain, 'X', 'C_price_bound_exec', mutate, check))
            try:
                record = m.stop_control(chain, 'X', 'C_global_unpaused', mutate, check)
            except a.Gate as fault:
                self.fail(f'X_restore: successful control did not restore state before {fault.record["gate"]}')
            self.assertEqual(record['gate'], 'C_global_unpaused')
            self.assertEqual(chain.get(SP, 'paused()'), 0)
            chain.fail_revert = True
            self.stop('X_restore', lambda: m.stop_control(chain, 'X', 'C_global_unpaused', mutate, check))

    def test_control_slot_readback(self):
        bad = copy.deepcopy(self.plan)
        bad['rebuild']['contracts']['SuperPaymaster']['storageLayout']['storage'][-1]['slot'] = '99'
        chain = Chain(self.plan, self.pc['steps'][0])
        chain.plan = self.plan
        with contextlib.ExitStack() as stack:
            for p in chain.patches(): stack.enter_context(p)
            self.stop('C_control_slot_cached_price', lambda: m.phase_c_controls(chain, bad, self.pc['steps'][0], [], chain.context))
        duplicate = copy.deepcopy(self.plan)
        storage = duplicate['rebuild']['contracts']['SuperPaymaster']['storageLayout']['storage']
        storage.append(copy.deepcopy(next(row for row in storage if row['label'] == 'cachedPrice')))
        # Keep a readable first slot: deleting the uniqueness gate must permit acceptance.
        self.stop('C_control_layout_cachedPrice', lambda: m.layout_slot(duplicate, 'SuperPaymaster', 'cachedPrice'))

    def test_control_slot_missing(self):
        missing = copy.deepcopy(self.plan)
        missing['rebuild']['contracts']['SuperPaymaster']['storageLayout']['storage'].pop()
        self.stop('C_control_layout_cachedPrice', lambda: m.layout_slot(missing, 'SuperPaymaster', 'cachedPrice'))



for _name in [n for n in dir(PhaseCTests) if n.startswith('test_')]:
    setattr(SnapshotControlTests, _name, None)


if __name__ == '__main__':
    unittest.main()
