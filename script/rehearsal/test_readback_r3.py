"""Daybreak reverse tests; all transports are offline fixtures."""
import copy
import json
import unittest
from pathlib import Path
from unittest.mock import patch
import deploylive_readback as r

ADDR = '0x' + '12' * 20
ABI = [{'type': 'function', 'name': 'target', 'inputs': [], 'stateMutability': 'view', 'outputs': [{'type': 'address'}]}]

class PolicyTest(unittest.TestCase):
    def test_H1_required_zero(self):
        self.assertEqual(r.runtime_rows({'superPaymasterLens': r.ZERO}, {'superPaymasterLens': 'SuperPaymasterLens'}, {}, lambda _: '0x'), [('superPaymasterLens', False)])

    def test_M2_duplicate_labels(self):
        labels = r.resolutions({'a': ADDR, 'b': ADDR}, {'c': ADDR})
        self.assertEqual(r.project({'type': 'address'}, ADDR, labels)[1], ['config:a', 'config:b', 'external:c'])

    def test_M2_intersection_and_narrow_policy(self):
        rule = dict(allowed=['config:a'], why='Must hold a')
        self.assertTrue(r.policy_matches(ADDR, ['config:a', 'config:b'], rule))
        self.assertFalse(r.policy_matches(ADDR, ['config:b'], rule))
        self.assertFalse(r.policy_matches(ADDR, [], rule))

    def test_empty_flag_passes(self):
        self.assertTrue(r.policy_matches([], [], dict(allowed=['config:a'], why='Fresh factory', emptyAllowed=True)))

    def test_empty_without_flag_fails(self):
        self.assertFalse(r.policy_matches([], [], dict(allowed=['config:a'], why='Must contain tokens')))

    def test_one_unaccounted_array_leaf_fails(self):
        self.assertFalse(r.policy_matches([ADDR, ADDR], [['config:a'], []], dict(allowed=['config:a'], why='Tokens')))

    def test_empty_only_getter_has_no_allowed_address_leaf(self):
        abi = [dict(ABI[0], outputs=[{'type':'address[]'}])]
        policy = dict(schema='readback-policy/1', rule=r.RULE, getters={'A': {'target':dict(allowed=[], why='Uninitialized implementation has no supported tokens', emptyAllowed=True)}}, unreadableAllowed={}, zeroAllowedConfigKeys={})
        with patch.object(r, 'release_artifact', return_value={'abi':abi}):
            r.validate_policy(policy, {'a':'A'}, {'a':ADDR}, {})
        rule = policy['getters']['A']['target']
        self.assertTrue(r.policy_matches([],[],rule))
        self.assertFalse(r.policy_matches([ADDR],[['config:a']],rule))

    def test_policy_refuses_multi_field_and_scalar_empty(self):
        # SDK 2026-11-19: one entry = one address leaf; emptyAllowed only on array outputs.
        policy = lambda rule: dict(schema='readback-policy/1', rule=r.RULE, getters={'A': {'target': rule}}, unreadableAllowed={}, zeroAllowedConfigKeys={})
        cases = {
            'tuple': ([{'type': 'tuple', 'components': [{'type': 'address', 'name': 'x'}]}], dict(allowed=['config:a'], why='a')),
            'two_leaves': ([{'type': 'address'}, {'type': 'address'}], dict(allowed=['config:a'], why='a')),
            'scalar_empty': ([{'type': 'address'}], dict(allowed=['config:a'], why='a', emptyAllowed=True)),
        }
        for name, (outputs, rule) in cases.items():
            abi = [dict(ABI[0], outputs=outputs)]
            with self.subTest(case=name), patch.object(r, 'release_artifact', return_value={'abi': abi}), self.assertRaises(ValueError):
                r.validate_policy(policy(rule), {'a': 'A'}, {'a': ADDR}, {})

    def test_spec_states_the_full_rule(self):
        spec = (Path(__file__).resolve().parents[2]/'cache/readback/SPEC.md')
        if spec.exists():
            self.assertIn('**The full rule** is the `rule` string together with `emptyAllowed`', spec.read_text())

    def test_H2_unreadable_fails(self):
        with self.assertRaises(ValueError):
            r.address_getters(ABI, lambda _: (_ for _ in ()).throw(ValueError()), {}, {'target': dict(allowed=['config:a'], why='a')}, {})

    def test_M2_policy_coverage_both_ways(self):
        policy = dict(schema='readback-policy/1', rule=r.RULE, getters={'A': {'target': dict(allowed=['config:a'], why='a')}}, unreadableAllowed={}, zeroAllowedConfigKeys={})
        with patch.object(r, 'release_artifact', return_value={'abi': ABI}):
            r.validate_policy(policy, {'a': 'A'}, {'a': ADDR}, {})
            for change in ('missing', 'stale', 'unreadable', 'wide', 'zero'):
                p = copy.deepcopy(policy)
                if change == 'missing': del p['getters']['A']['target']
                if change == 'stale': p['getters']['A']['gone'] = p['getters']['A']['target']
                if change == 'unreadable': p['unreadableAllowed']['A'] = {'gone': 'stale'}
                if change == 'wide': p['getters']['A']['target']['allowed'] = ['config:*']
                if change == 'zero': p['getters']['A']['target']['allowed'] += ['zero']
                with self.subTest(change=change), self.assertRaises(ValueError): r.validate_policy(p, {'a': 'A'}, {'a': ADDR}, {})

    def test_M1_unknown_and_missing_key(self):
        for cfg in ({'a': ADDR, 'unknown': ADDR}, {}):
            with self.assertRaises(ValueError): r.validate_config(cfg, {'a': 'A'}, {}, {})

    def test_H3_hash_rechecked(self):
        with self.assertRaises(ValueError): r.recheck_block({'number': '0x2a', 'hash': '0x'+'12'*32}, lambda *args: (0, json.dumps({'hash': '0x'+'34'*32})))

    def test_H2_snapshot_replays_once_and_freezes(self):
        count = []
        def transport(*args):
            count.append(args)
            return 0, str(len(count))
        snapshot = r.Snapshot(transport)
        self.assertEqual(snapshot('code', ADDR), snapshot('code', ADDR))
        snapshot.freeze()
        self.assertEqual(snapshot('code', ADDR), (0, '1'))
        with self.assertRaises(ValueError): snapshot('storage', ADDR, '0')
        self.assertEqual(len(count), 1)

class ReverseTest(unittest.TestCase):
    def test_L2_every_mapped_runtime_and_metadata(self):
        from runtime_pins import runtime_pin
        mapping = json.loads((r.ROOT/'deployments/readback-artifacts.json').read_text())
        pin = runtime_pin({'object':'0x6000a164736f6c6343000821000a', 'immutableReferences':{'1':[{'start':1,'length':1}]}}, 500)
        for key, name in mapping.items():
            if name is None: continue
            for code in ('0x6100a164736f6c6343000821000a', '0x6000a164736f6c6343000821000b'):
                with self.subTest(key=key, code=code):
                    self.assertEqual(r.runtime_rows({key: ADDR}, {key:name}, {name:pin}, lambda _: code), [(key,False)])

    def record(self):
        return dict(block={'number':'42','hash':'0x'+'12'*32}, contracts=[dict(configKey=k, address=ADDR, artifact='ERC1967Proxy', maskedMatchesPin=True,
            runtimeKeccak='expected', immutableBindings={}, erc1967={'implementation':ADDR}, addressGetters={}, unreadable=[]) for k in ('registry','superPaymaster')])

    def test_H2_each_implementation_slot(self):
        cfg=dict(registryImpl=ADDR, spImpl=ADDR)
        for key in ('registry','superPaymaster'):
            record=self.record()
            next(x for x in record['contracts'] if x['configKey']==key)['erc1967']['implementation']=r.ZERO
            with self.subTest(key=key), self.assertRaises(ValueError): r.validate_record(record,cfg,{'zeroAllowedConfigKeys':{}, 'immutableBindings': {'ERC1967Proxy': {}}})

    def test_H2_masked_comparison_is_asserted(self):
        record=self.record();record['contracts'][0]['maskedMatchesPin']=False
        with self.assertRaises(ValueError): r.validate_record(record,{}, {'zeroAllowedConfigKeys':{}, 'immutableBindings': {'ERC1967Proxy': {}}})

    def test_H3_second_provider_ignoring_block_detected(self):
        for mutation in ('header','runtime','slot'):
            def transport(kind,*args):
                if kind=='rpc':return 0,json.dumps({'hash':'0x'+('34' if mutation=='header' else '12')*32})
                if kind=='code':return 0,'wrong' if mutation=='runtime' else 'expected'
                return 0,'0x'+(r.ZERO if mutation=='slot' else ADDR)[2:].zfill(64)
            with patch.object(r,'keccak',side_effect=lambda value:value): result=r.corroborate(self.record(),transport,'Independent')
            self.assertFalse(all(result[k] for k in ('blockHashMatches','runtimeKeccakMatches','implSlotsMatch')))

    def test_H2_unreadable_explicit_exception(self):
        values, unreadable=r.address_getters(ABI,lambda _: (_ for _ in ()).throw(ValueError()),{}, {'target':{'allowed':['zero'],'why':'Inert'}},{'target':'Documented revert'})
        self.assertEqual(unreadable,['target'])
        self.assertTrue(values['target']['policyMatches'])

    def test_M2_committed_coverage_and_narrowness(self):
        policy=json.loads((r.ROOT/'deployments/readback-policy.json').read_text())
        mapping=json.loads((r.ROOT/'deployments/readback-artifacts.json').read_text())
        non=json.loads((r.ROOT/'deployments/readback-noncontracts.json').read_text())['production']
        cfg={k:ADDR for k in set(mapping)|set(non)}
        deps=json.loads((r.ROOT/'deployments/external-deps.10.json').read_text())
        from test_deploylive_postdeploy_check import fixture_artifact
        with patch.object(r, 'release_artifact', side_effect=fixture_artifact):
            r.validate_policy(policy,mapping,cfg,deps)
        for name, entries in policy['getters'].items():
            for getter, rule in entries.items():
                self.assertLessEqual(len(set(rule['allowed'])-{'zero'}),2,(name,getter))
                self.assertNotIn('*',str(rule['allowed']))

    def test_M1_schema_matches_DeployLive_serialization(self):
        import re
        source=(r.ROOT/'contracts/script/v3/DeployLive.s.sol').read_text().split('function _generateConfig()')[1]
        scalar=set(re.findall(r'vm\.serializeAddress\(\s*jsonObj,\s*"([^"]+)"',source))
        scalar-={'expectedGovernor'}
        scalar|={'SLASH_POLICY_ADMIN','X402_OWNER','REPUTATION_OWNER','MPC_OWNER','PAYMASTER_FACTORY_OWNER','spAdminImplOwner'}
        mapping=json.loads((r.ROOT/'deployments/readback-artifacts.json').read_text())
        non=json.loads((r.ROOT/'deployments/readback-noncontracts.json').read_text())['production']
        self.assertEqual(scalar,set(mapping)|set(non))

class CheckerReverseTest(unittest.TestCase):
    def test_L2_checker_fail_closed(self):
        from test_deploylive_postdeploy_check import CheckerTest
        for mutation, op in [(('config','superPaymasterLens',r.ZERO),False),
                             (('config','unexpectedContract',ADDR),False),
                             ('getter_revert',False),('getter_unaccounted',False),('version_revert',False),
                             ('slot_registry',False),('slot_superPaymaster',False),('reorg',False),
                             ('second_header',True),('second_runtime',True),('second_slot',True),('second_missing',True),('second_same',True)]:
            with self.subTest(mutation=mutation):
                code, output = CheckerTest().run_checker(mutation,op=op)
                self.assertEqual(code,1,output)
                self.assertIn('FAIL',output)
                if mutation == ('config','superPaymasterLens',r.ZERO):
                    self.assertIn('FAIL  runtime superPaymasterLens',output)
                    self.assertIn('FAIL  version superPaymasterLens',output)

    def test_same_asserted_record_is_written(self):
        from test_deploylive_postdeploy_check import CheckerTest
        for production in (False,True):
            records=[]
            code, output=CheckerTest().run_checker(op=production,capture_record=records)
            self.assertEqual(code,0,output)
            self.assertEqual(len(records),1)
            record=records[0]
            self.assertTrue(record['block']['hashRechecked'])
            self.assertEqual(record['singleProvider'],not production)
            self.assertEqual(record['singleProviderNote'],None if production else 'single provider: not evidence of on-chain state')
            self.assertEqual(record['readbackPolicySha256'],'0x'+'ab'*32)
            self.assertEqual(record['externalDepsSha256'],'0x'+'ab'*32)
            if production:
                self.assertEqual({k:v for k,v in record['secondProvider'].items() if k!='name'},dict(blockHashMatches=True,runtimeKeccakMatches=True,implSlotsMatch=True))
            else: self.assertIsNone(record['secondProvider'])
            for item in record['contracts']:
                for getter in (item['addressGetters'] or {}).values(): self.assertTrue(getter['policyMatches'])
            self.assertEqual(record['wiring']['SP.xpntsFactory'], next(c for c in record['contracts'] if c['configKey']=='superPaymaster')['addressGetters']['xpntsFactory']['value'])

    def test_zero_template_exception_does_not_excuse_proxy(self):
        from test_deploylive_postdeploy_check import CheckerTest
        code, output=CheckerTest().run_checker(('superPaymaster','xpntsFactory()(address)',[],r.ZERO))
        self.assertEqual(code,1,output)
        self.assertIn('FAIL  readback snapshot policy',output)
