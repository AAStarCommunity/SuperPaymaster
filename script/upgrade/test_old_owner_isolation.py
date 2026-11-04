"""Offline L-1 controls, using synthetic compiler ASTs and strict RPC replies."""
import copy
import json
import os
import tempfile
import unittest
from functools import lru_cache
from pathlib import Path
from unittest.mock import patch
import old_owner_isolation as o

a, u = o.a, o.u
TOKEN = '0x'+'12'*20
STAKING, GTOKEN, FACTORY, SBT = ['0x'+v*20 for v in ('21','22','23','24')]
CUSTOM_ROLE = '0x'+'77'*32
BLOCK_HASH = '0x'+'88'*32
CAPPED = '0x'+'13'*20
OP_TYPES = ['uint128','bool','bool','address','uint32','uint48','address','uint256','uint256']


def fixture_ast(tree):
    sources, inputs, artifacts = {}, {}, {}
    counter = 0
    for name in o.NAMES:
        path = 'contracts/src/'+name+'.sol'
        members, abi = [], []
        def function(label, ins, outs):
            abi.append(dict(type='function', name=label, inputs=[dict(type=t) for t in ins], outputs=[dict(type=t) for t in outs]))
        def variable(label, typ, **kw):
            members.append(dict(nodeType='VariableDeclaration',name=label,src='7:1:0',stateVariable=True,visibility='public',typeDescriptions=dict(typeString=typ),**kw))
        if name in ('Registry','TimelockController'):
            label, value = ('ROLE_COMMUNITY','COMMUNITY') if name == 'Registry' else ('PROPOSER_ROLE','PROPOSER_ROLE')
            variable(label,'bytes32',constant=True,value=dict(nodeType='FunctionCall',expression=dict(name='keccak256'),arguments=[dict(value=value)]))
            function('hasRole',['bytes32','address'],['bool'])
        if name != 'TimelockController':
            members.append(dict(nodeType='FunctionDefinition',name='owner',src='7:1:0',visibility='public',stateMutability='view',parameters=dict(parameters=[]),returnParameters=dict(parameters=[dict(typeDescriptions=dict(typeString='address'))])))
            function('owner',[],['address'])
            variable('pendingOwner','address')
            function('pendingOwner',[],['address'])
        if name in ('Registry','SuperPaymaster'):
            variable('authorized','mapping(address => bool)',typeName=dict(nodeType='Mapping',keyType=dict(name='address'),valueType=dict(name='bool')))
            function('authorized',['address'],['bool'])
        if name == 'Registry':
            abi.append(dict(type='event',name='RoleConfigured',inputs=[
                dict(type='bytes32',indexed=True),
                dict(type='tuple',indexed=False,components=[dict(type=t) for t in u.CONFIG_TYPE[1:-1].split(',')]),
                dict(type='uint256',indexed=False)]))
        if name in ('GTokenStaking','xPNTsFactory','xPNTsToken'):
            label = {'GTokenStaking':'authorizedSlashers','xPNTsFactory':'isXPNTs','xPNTsToken':'autoApprovedSpenders'}[name]
            variable(label,'mapping(address => bool)',typeName=dict(nodeType='Mapping',keyType=dict(name='address'),valueType=dict(name='bool')))
            function(label,['address'],['bool'])
        if name in ('MySBT','xPNTsToken'):
            label = 'daoMultisig' if name == 'MySBT' else 'communityOwner'
            variable(label,'address')
            function(label,[],['address'])
        if name == 'SuperPaymaster':
            function('operators',['address'],OP_TYPES)
        counter += 1
        node = dict(nodeType='ContractDefinition',name=name,id=counter,contractKind='contract',linearizedBaseContracts=[counter],nodes=members)
        sources[path] = dict(ast=dict(nodes=[node]))
        inputs[path] = dict(content='// one\ncontract fixture {}')
        artifacts[name] = dict(abi=abi)
    directory = tree/'out/build-info'
    directory.mkdir(parents=True)
    (directory/'test.json').write_text(json.dumps(dict(input=dict(sources=inputs),output=dict(sources=sources))))
    return artifacts


@lru_cache(maxsize=1)
def inventory():
    with tempfile.TemporaryDirectory() as directory:
        tree = Path(directory)
        artifacts = fixture_ast(tree)
        with patch.object(a,'raw_artifact',side_effect=lambda t,n:artifacts[n]):
            return o.extract(tree)


def raw(values):
    return '0x'+''.join(format(v,'064x') for v in values)


def fixture_rpc(pin, overrides=None, factory_token=TOKEN):
    answers = {}
    def put(target,sig,args,values):
        answers[(target,a.calldata(sig,*args))] = raw(values)
    principals = sorted({u.SAFE,u.TL,u.SP,u.REG,u.DEPLOYER,a.APPROVER,a.EXECUTOR,o.NEW})
    for name,target in dict(Registry=u.REG,SuperPaymaster=u.SP,APNTsCapped=pin['capped'],TimelockController=u.TL,GTokenStaking=STAKING,GToken=GTOKEN,xPNTsFactory=FACTORY,MySBT=SBT,PaymasterFactory=o.PAYMASTER_FACTORY,xPNTsToken=TOKEN).items():
        for row in inventory()[name]['roles']:
            put(target,'hasRole(bytes32,address)',[row['value'],o.OLD],[0])
            if name == 'Registry':
                w = [32]+[0]*13
                w[10],w[11] = 384,int(u.DEPLOYER,16)
                put(target,'getRoleConfig(bytes32)',[row['value']],w)
            else:
                put(target,'hasRole(bytes32,address)',[row['value'],u.SAFE],[1])
        for row in inventory()[name]['authorities']:
            put(target,row['signature'],[],[int(u.DEPLOYER,16)])
        for row in inventory()[name]['mappings']:
            for who in {o.OLD,u.DEPLOYER,*pin['pauseList']}:
                put(target,row['signature'],[who],[int(who != o.OLD)])
    for target,sig,value in [(u.REG,'GTOKEN_STAKING()',STAKING),(u.REG,'MYSBT()',SBT),
                              (u.SP,'xpntsFactory()',FACTORY),(STAKING,'GTOKEN()',GTOKEN)]:
        put(target,sig,[],[int(value,16)])
    if factory_token != TOKEN:
        for row in inventory()['xPNTsToken']['authorities']:
            put(factory_token,row['signature'],[],[int(o.NEW,16)])
        for row in inventory()['xPNTsToken']['mappings']:
            put(factory_token,row['signature'],[o.OLD],[0])
        put(FACTORY,'communityToToken(address)',[o.NEW],[int(factory_token,16)])
    put(FACTORY,'getAllTokens()',[],[32,1,int(factory_token,16)])
    put(FACTORY,'communityToToken(address)',[u.DEPLOYER],[int(TOKEN,16)])
    put(FACTORY,'communityToToken(address)',[o.OLD],[0])
    put(u.REG,'hasRole(bytes32,address)',[CUSTOM_ROLE,o.OLD],[0])
    cfg = [32]+[0]*13
    cfg[10],cfg[11] = 384,int(u.DEPLOYER,16)
    put(u.REG,'getRoleConfig(bytes32)',[CUSTOM_ROLE],cfg)
    put(u.REG,'getUserRoles(address)',[o.OLD],[32,0])
    put(u.REG,'getUserRoles(address)',[u.DEPLOYER],[32,1,99])
    put(u.SP,'operators(address)',[o.OLD],[0]*9)
    for who in pin['pauseList']:
        put(u.SP,'operators(address)',[who],[1,1,0,int(TOKEN,16),0,0,int(u.DEPLOYER,16),0,0])
    for token in set((pin['capped'],o.OLD_TOKEN,TOKEN,GTOKEN,factory_token)):
        for holder in principals:
            put(token,'allowance(address,address)',[holder,o.OLD],[0])
            for spender in (u.SP,u.REG):
                put(token,'allowance(address,address)',[holder,spender],[1])
        for spender in (u.SP,u.REG):
            put(token,'allowance(address,address)',[o.OLD,spender],[123])
    put(u.SAFE,'getOwners()',[],[32,2,int(a.APPROVER,16),int(a.EXECUTOR,16)])
    put(u.SAFE,'isOwner(address)',[a.APPROVER],[1])
    put(u.SAFE,'isModuleEnabled(address)',[o.OLD],[0])
    def rpc(method,params):
        if overrides and (method,str(params)) in overrides:
            return overrides[(method,str(params))]
        if method == 'eth_getLogs':
            assert params == [dict(address=u.REG,fromBlock=hex(pin['registryCreation']),toBlock=pin['stateBlock'],topics=[a.keccak(o.ROLE_EVENT)])]
            return [dict(address=u.REG,topics=[a.keccak(o.ROLE_EVENT),role],blockNumber=pin['stateBlock'],blockHash=pin['stateBlockHash'])
                    for role in [inventory()['Registry']['roles'][0]['value'],CUSTOM_ROLE]]
        if method == 'eth_getBlockByNumber':
            return dict(number=params[0],hash=pin['stateBlockHash'])
        assert params[-1] == pin['stateBlock'], params
        if method == 'eth_getStorageAt':
            return raw([0])
        assert method == 'eth_call', method
        return answers[(params[0]['to'],params[0]['data'])]
    return rpc


def evidence(pin):
    value = o.audit(fixture_rpc(pin),pin,inventory())
    value['endpointResults'] = dict(primary=copy.deepcopy(value['reads']),secondary=copy.deepcopy(value['reads']))
    return value


class OldOwnerIsolationTests(unittest.TestCase):
    def setUp(self):
        self.pin = dict(stateBlockHash=BLOCK_HASH,registryCreation=1,stateBlock='0x123', capped=CAPPED,pauseList=[u.DEPLOYER])

    def test_extraction_and_no_has_role(self):
        data = inventory()
        self.assertEqual(data['Registry']['roles'][0]['name'],'ROLE_COMMUNITY')
        self.assertEqual(data['Registry']['roles'][0]['line'],2)
        self.assertFalse(data['APNTsCapped']['hasRole'])
        self.assertIn('no hasRole',data['SuperPaymaster']['roleStatus'])

    def test_empty_extraction_categories_stop(self):
        for category, gate in [('roles','old_owner_extraction_roles_Registry'),
                               ('authorities','old_owner_extraction_authorities'),
                               ('mappings','old_owner_extraction_mappings')]:
            with self.subTest(category=category), tempfile.TemporaryDirectory() as directory:
                tree = Path(directory)
                artifacts = fixture_ast(tree)
                path = tree/'out/build-info/test.json'
                data = json.loads(path.read_text())
                root = data['output']['sources']['contracts/src/Registry.sol']['ast']['nodes'][0]
                labels = {r['name'] for r in inventory()['Registry'][category]}
                root['nodes'] = [n for n in root['nodes'] if n['name'] not in labels]
                path.write_text(json.dumps(data))
                with patch.object(a,'raw_artifact',side_effect=lambda t,n:artifacts[n]), self.assertRaises(a.Gate) as caught:
                    o.extract(tree)
                self.assertEqual(caught.exception.record['gate'],gate)

    def test_role_event_abi_and_inventory_source_seam(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            artifacts = fixture_ast(tree)
            with patch.object(o,'inventory_source',return_value=tree) as source, patch.object(a,'raw_artifact',side_effect=lambda t,n:artifacts[n]):
                self.assertEqual(o.extract(tree)['Registry']['roleEventTopic'],a.keccak(o.ROLE_EVENT))
                source.assert_called_once_with(tree)
                event = next(f for f in artifacts['Registry']['abi'] if f['type'] == 'event')
                event['inputs'][1]['components'][0]['type'] = 'address'
                with self.assertRaises(a.Gate) as caught:
                    o.extract(tree)
                self.assertEqual(caught.exception.record['gate'],'old_owner_role_event_signature')

    def test_inherited_and_file_level_constants(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            artifacts = fixture_ast(tree)
            path = tree/'out/build-info/test.json'
            data = json.loads(path.read_text())
            source = data['output']['sources']['contracts/src/Registry.sol']['ast']['nodes']
            root = source[0]
            role = root['nodes'].pop(0)
            source.append(role)
            inherited = root['nodes'].pop(0)
            source.append(dict(nodeType='ContractDefinition', name='Base', id=900,
                               nodes=[inherited], contractKind='contract', linearizedBaseContracts=[900]))
            root['linearizedBaseContracts'].append(900)
            path.write_text(json.dumps(data))
            with patch.object(a,'raw_artifact',side_effect=lambda t,n:artifacts[n]):
                result = o.extract(tree)
            self.assertEqual(result['Registry'], inventory()['Registry'])

    def test_pair_and_independent_endpoint_failure(self):
        import manifest_exec as m
        value = dict(self.pin,oldOwnerIsolation=o.audit(fixture_rpc(self.pin),self.pin,inventory()))
        with patch.object(m,'collect',side_effect=[copy.deepcopy(value),copy.deepcopy(value)]) as collect:
            paired = m.collect_pair('primary','secondary','0x123',{})
            self.assertEqual(collect.call_count,2)
            o.validate(paired['oldOwnerIsolation'],self.pin,inventory())
        bad = copy.deepcopy(value)
        bad['oldOwnerIsolation']['reverseAllowances'][0]['value'] += 1
        with patch.object(m,'collect',side_effect=[value,bad]), self.assertRaises(a.Gate) as caught:
            m.collect_pair('primary','secondary','0x123',{})
        self.assertEqual(caught.exception.record['gate'],'independent_pin')

    @unittest.skipUnless(os.environ.get('OLD_OWNER_FORK_PIN') and os.environ.get('OLD_OWNER_FORK_RPC') and (a.ENGINE/'anvil').is_file(),
                         'optional local Anvil fork control: engine and OLD_OWNER_FORK_PIN/RPC required')
    def test_optional_anvil_fork_role_grant(self):
        # Opt-in only: use an already hydrated local fork, never a public RPC URL.
        from urllib.parse import urlsplit
        import manifest_exec as m
        url = os.environ['OLD_OWNER_FORK_RPC']
        self.assertIn(urlsplit(url).hostname, ('localhost','127.0.0.1','::1'))
        rpc = a.RPC(url, local=True)
        pin = json.loads(Path(os.environ['OLD_OWNER_FORK_PIN']).read_text())
        inventory = m.rebuild()['oldOwnerInventory']
        pin['stateBlock'] = rpc('eth_blockNumber',[])
        o.audit(rpc,pin,inventory)
        snapshot = rpc('evm_snapshot',[])
        try:
            rpc('anvil_impersonateAccount',[u.TL])
            rpc('anvil_setBalance',[u.TL,hex(10**18)])
            role = next(r['value'] for r in inventory['TimelockController']['roles'] if r['name'] == 'PROPOSER_ROLE')
            tx = dict(
                to=u.TL,data=a.calldata('grantRole(bytes32,address)',role,o.OLD),gas=hex(300000))
            tx['from'] = u.TL
            receipt = a.receipt(rpc,tx)
            pin['stateBlock'] = receipt['blockNumber']
            with self.assertRaises(a.Gate) as caught:
                o.audit(rpc,pin,inventory)
            self.assertEqual(caught.exception.record['gate'],'old_owner_role_TimelockController_PROPOSER_ROLE')
        finally:
            rpc('anvil_stopImpersonatingAccount',[u.TL])
            self.assertTrue(rpc('evm_revert',[snapshot]))

    def test_offline_replay_and_reverse_allowances(self):
        value = evidence(self.pin)
        o.validate(value,self.pin,inventory())
        self.assertTrue(all(r['value'] == 123 for r in value['reverseAllowances']))
        for key in ('inventory','reads','tokens','reverseAllowances','endpointResults'):
            bad = copy.deepcopy(value)
            bad[key] = {} if isinstance(value[key],dict) else []
            with self.subTest(key=key), self.assertRaises(a.Gate):
                o.validate(bad,self.pin,inventory())
        bad = copy.deepcopy(value)
        bad['endpointResults']['secondary'][0]['block'] = '0x124'
        with self.assertRaises(a.Gate):
            o.validate(bad,self.pin,inventory())

    def mutations(self):
        def query(target,sig,args):
            return ('eth_call',str([dict(to=target,data=a.calldata(sig,*args)),self.pin['stateBlock']]))
        role = inventory()['TimelockController']['roles'][0]['value']
        yield 'old_owner_role_TimelockController_PROPOSER_ROLE',query(u.TL,'hasRole(bytes32,address)',[role,o.OLD]),raw([1])
        yield 'old_owner_authority_SuperPaymaster_pendingOwner',query(u.SP,'pendingOwner()',[]),raw([int(o.OLD,16)])
        yield 'old_owner_mapping_Registry_authorized',query(u.REG,'authorized(address)',[o.OLD]),raw([1])
        registry_role = inventory()['Registry']['roles'][0]['value']
        cfg = [32]+[0]*13
        cfg[10],cfg[11] = 384,int(o.OLD,16)
        yield 'old_owner_role_admin_ROLE_COMMUNITY',query(u.REG,'getRoleConfig(bytes32)',[registry_role]),raw(cfg)
        for name,target in [('GTokenStaking',STAKING),('GToken',GTOKEN),('xPNTsFactory',FACTORY),('xPNTsToken',TOKEN),('MySBT',SBT),('PaymasterFactory',o.PAYMASTER_FACTORY)]:
            getter = {'xPNTsToken':'communityOwner','MySBT':'daoMultisig'}.get(name,'owner')
            yield 'old_owner_authority_'+name+'_'+getter,query(target,getter+'()',[]),raw([int(o.OLD,16)])
        for name,target,label in [('GTokenStaking',STAKING,'authorizedSlashers'),('xPNTsFactory',FACTORY,'isXPNTs'),('xPNTsToken',TOKEN,'autoApprovedSpenders')]:
            yield 'old_owner_mapping_'+name+'_'+label,query(target,label+'(address)',[o.OLD]),raw([1])
        yield 'old_owner_role_Registry_'+CUSTOM_ROLE,query(u.REG,'hasRole(bytes32,address)',[CUSTOM_ROLE,o.OLD]),raw([1])
        yield 'old_owner_role_admin_'+CUSTOM_ROLE,query(u.REG,'getRoleConfig(bytes32)',[CUSTOM_ROLE]),raw(cfg)
        yield 'old_owner_allowance_'+GTOKEN+'_'+u.SAFE,query(GTOKEN,'allowance(address,address)',[u.SAFE,o.OLD]),raw([1])
        yield 'old_owner_operator_treasury_'+u.DEPLOYER,query(u.SP,'operators(address)',[u.DEPLOYER]),raw([1,1,0,int(TOKEN,16),0,0,int(o.OLD,16),0,0])
        yield 'old_owner_operator',query(u.SP,'operators(address)',[o.OLD]),raw([1]+[0]*8)
        yield 'old_owner_registry_user_roles',query(u.REG,'getUserRoles(address)',[o.OLD]),raw([32,1,99])
        yield 'old_owner_allowance_'+o.OLD_TOKEN+'_'+u.SAFE,query(o.OLD_TOKEN,'allowance(address,address)',[u.SAFE,o.OLD]),raw([1])
        yield 'old_owner_safe_owners',query(u.SAFE,'getOwners()',[]),raw([32,3,int(a.APPROVER,16),int(a.EXECUTOR,16),int(o.OLD,16)])
        yield 'old_owner_safe_modules',query(u.SAFE,'isModuleEnabled(address)',[o.OLD]),raw([1])
        for label,slot in [('guard','guard_manager.guard.address'),('fallback','fallback_manager.handler.address')]:
            yield 'old_owner_safe_'+label,('eth_getStorageAt',str([u.SAFE,a.keccak(slot),self.pin['stateBlock']])),raw([int(o.OLD,16)])

    def test_negative_controls_and_gate_removal_probes(self):
        original = a.need
        for gate,key,value in self.mutations():
            rpc = fixture_rpc(self.pin,{key:value})
            with self.subTest(gate=gate), self.assertRaises(a.Gate) as caught:
                o.audit(rpc,self.pin,inventory())
            self.assertEqual(caught.exception.record['gate'],gate)
            # Removing the isolation gate must make the same negative assertion red.
            def removed(label,actual,expected):
                if label != gate:
                    original(label,actual,expected)
            with patch.object(a,'need',side_effect=removed):
                with self.assertRaises(AssertionError):
                    with self.assertRaises(a.Gate) as removed_result:
                        o.audit(rpc,self.pin,inventory())
                    self.assertEqual(removed_result.exception.record['gate'],gate)

    def test_factory_only_token_and_operator_union(self):
        token = '0x'+'39'*20
        rpc = fixture_rpc(self.pin,factory_token=token)
        value = o.audit(rpc,self.pin,inventory())
        self.assertEqual(value['xpnts'],sorted([TOKEN,token]))
        self.assertIn(GTOKEN,value['tokens'])
        query = ('eth_call',str([dict(to=token,data=a.calldata('autoApprovedSpenders(address)',o.OLD)),self.pin['stateBlock']]))
        with self.assertRaises(a.Gate) as caught:
            o.audit(fixture_rpc(self.pin,{query:raw([1])},factory_token=token),self.pin,inventory())
        self.assertEqual(caught.exception.record['gate'],'old_owner_mapping_xPNTsToken_autoApprovedSpenders')

    def test_role_history_authentication_and_empty_probes(self):
        baseline = fixture_rpc(self.pin)
        query = dict(address=u.REG,fromBlock=hex(self.pin['registryCreation']),toBlock=self.pin['stateBlock'],topics=[a.keccak(o.ROLE_EVENT)])
        logs = baseline('eth_getLogs',[query])
        cases = [('old_owner_role_extraction_empty',[]),
                 ('old_owner_role_extraction_empty',logs[1:])]
        for gate,field,value in [('old_owner_role_log_address','address',u.SP),
                                 ('old_owner_role_log_removed','removed',True),
                                 ('old_owner_role_log_topic','topics',[a.ZERO32,inventory()['Registry']['roles'][0]['value']]),
                                 ('old_owner_role_log_canonical','blockHash',a.ZERO32),
                                 ('old_owner_role_log_range','blockNumber','0x124')]:
            bad = copy.deepcopy(logs)
            bad[0][field] = value
            cases.append((gate,bad))
        original = a.need
        for gate,bad in cases:
            def rpc(method,params):
                return bad if method == 'eth_getLogs' else baseline(method,params)
            with self.subTest(gate=gate),self.assertRaises(a.Gate) as caught:
                o.audit(rpc,self.pin,inventory())
            self.assertEqual(caught.exception.record['gate'],gate)
            def removed(label,actual,expected):
                if label != gate:
                    original(label,actual,expected)
            with patch.object(a,'need',side_effect=removed),self.assertRaises(AssertionError):
                with self.assertRaises(a.Gate):
                    o.audit(rpc,self.pin,inventory())

    def test_bisected_history_replay(self):
        baseline = fixture_rpc(self.pin)
        queries = []
        full = dict(address=u.REG,fromBlock='0x1',toBlock=self.pin['stateBlock'],topics=[a.keccak(o.ROLE_EVENT)])
        def rpc(method,params):
            if method != 'eth_getLogs':
                return baseline(method,params)
            queries.append(params[0])
            if params[0] == full:
                fault = a.Gate('rpc_range','too large','bounded range')
                fault.log_range_limit = True
                raise fault
            return baseline(method,[full]) if params[0]['toBlock'] == self.pin['stateBlock'] else []
        value = o.audit(rpc,self.pin,inventory())
        self.assertEqual(len(queries),3)
        self.assertEqual(queries[1]['toBlock'],'0x92')
        self.assertEqual(queries[2]['fromBlock'],'0x93')
        value['endpointResults'] = dict(primary=copy.deepcopy(value['reads']),secondary=copy.deepcopy(value['reads']))
        o.validate(value,self.pin,inventory())

    def test_optional_fork_harness_with_mock_rpc(self):
        import manifest_exec as m
        state = dict(granted=False,restored=False)
        baseline = fixture_rpc(self.pin)
        role = inventory()['TimelockController']['roles'][0]['value']
        old_role_call = a.calldata('hasRole(bytes32,address)',role,o.OLD)
        def rpc(method,params):
            if method == 'eth_blockNumber': return self.pin['stateBlock']
            if method == 'evm_snapshot': return '0x1'
            if method == 'evm_revert':
                state['restored'] = True
                return True
            if method.startswith('anvil_'): return True
            if method == 'eth_sendTransaction':
                self.assertEqual(params[0]['data'],a.calldata('grantRole(bytes32,address)',role,o.OLD))
                self.assertEqual(params[0]['from'],u.TL)
                state['granted'] = True
                return '0x'+'11'*32
            if method == 'eth_getTransactionReceipt':
                return dict(status='0x1',gasUsed='0x100',blockNumber=self.pin['stateBlock'])
            if state['granted'] and method == 'eth_call' and params[0] == dict(to=u.TL,data=old_role_call):
                return raw([1])
            return baseline(method,params)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'pin.json'
            path.write_text(json.dumps(self.pin))
            with patch.dict(os.environ,OLD_OWNER_FORK_PIN=str(path),OLD_OWNER_FORK_RPC='http://127.0.0.1:12345'), \
                 patch.object(a,'RPC',return_value=rpc), patch.object(m,'rebuild',return_value=dict(oldOwnerInventory=inventory())):
                self.test_optional_anvil_fork_role_grant.__wrapped__(self)
        self.assertTrue(state['granted'] and state['restored'])

    def test_positive_controls_fail_closed(self):
        section = evidence(self.pin)
        extra = [('old_owner_control_'+name, lambda r,t=target:r.get('target') == t and r.get('signature') == 'owner()',raw([0]))
                 for name,target in [('GTokenStaking',STAKING),('GToken',GTOKEN),('xPNTsFactory',FACTORY),('PaymasterFactory',o.PAYMASTER_FACTORY)]]
        extra += [('old_owner_control_MySBT',lambda r:r.get('target') == SBT and r.get('signature') == 'daoMultisig()',raw([0])),
                  ('old_owner_control_xPNTsToken',lambda r:r.get('signature') == 'communityToToken(address)',raw([0]))]
        for gate, predicate, replacement in extra + [
            ('old_owner_control_role', lambda r:r.get('signature') == 'hasRole(bytes32,address)' and r['args'][-1] == u.SAFE, raw([0])),
            ('old_owner_control_authority', lambda r:r.get('target') == u.SP and r.get('signature') == 'owner()', raw([0])),
            ('old_owner_control_registration', lambda r:r.get('signature') == 'getUserRoles(address)' and r['args'] == [u.DEPLOYER], raw([32,0])),
            ('old_owner_control_operator', lambda r:r.get('signature') == 'operators(address)' and r['args'] != [o.OLD], raw([1,0,0,int(TOKEN,16),0,0,int(u.DEPLOYER,16),0,0])),
            ('old_owner_control_mapping', lambda r:r.get('signature') == 'authorized(address)' and r['args'] != [o.OLD], raw([0])),
            ('old_owner_control_allowance', lambda r:r.get('signature') == 'allowance(address,address)' and r['args'][0] != o.OLD and r['args'][1] != o.OLD, raw([0])),
            ('old_owner_control_safe', lambda r:r.get('signature') == 'isOwner(address)', raw([0])),
        ]:
            overrides = {}
            for row in section['reads']:
                if predicate(row):
                    key = ('eth_call',str([dict(to=row['target'],data=a.calldata(row['signature'],*row['args'])),self.pin['stateBlock']]))
                    overrides[key] = replacement
            with self.subTest(gate=gate), self.assertRaises(a.Gate) as caught:
                o.audit(fixture_rpc(self.pin,overrides),self.pin,inventory())
            self.assertEqual(caught.exception.record['gate'],gate)
            original = a.need
            def removed(label,actual,expected):
                if label != gate:
                    original(label,actual,expected)
            with patch.object(a,'need',side_effect=removed), self.assertRaises(AssertionError):
                with self.assertRaises(a.Gate):
                    o.audit(fixture_rpc(self.pin,overrides),self.pin,inventory())


if __name__ == '__main__':
    unittest.main(verbosity=2)
