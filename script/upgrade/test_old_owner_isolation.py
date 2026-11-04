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
            return o.inventory_source(tree,mode='release')


def raw(values):
    return '0x'+''.join(format(v,'064x') for v in values)


def fixture_rpc(pin, overrides=None, factory_token=TOKEN):
    answers = {}
    targets = [u.REG,u.SP,pin['capped'],u.TL,STAKING,GTOKEN,FACTORY,SBT,o.PAYMASTER_FACTORY,TOKEN,factory_token]
    pin.setdefault('isolationDeployments',{target:1 for target in targets})
    pin['isolationDeployments'].update({target:1 for target in targets})
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
            put(target,'hasRole(bytes32,address)',[row['value'],u.SAFE],[1])
            for holder in {u.DEPLOYER,*pin['pauseList']}:
                put(target,'hasRole(bytes32,address)',[row['value'],holder],[0])
        for row in inventory()[name]['authorities']:
            put(target,row['signature'],[],[int(u.DEPLOYER,16)])
        for row in inventory()[name]['mappings']:
            for who in {o.OLD,o.NEW,o.OLD_TOKEN,u.SAFE,u.TL,u.SP,u.REG,u.DEPLOYER,a.APPROVER,a.EXECUTOR,*targets,*pin['pauseList']}:
                put(target,row['signature'],[who],[int(who != o.OLD)])
    for target,sig,value in [(u.REG,'GTOKEN_STAKING()',STAKING),(u.REG,'MYSBT()',SBT),
                              (u.SP,'xpntsFactory()',FACTORY),(STAKING,'GTOKEN()',GTOKEN)]:
        put(target,sig,[],[int(value,16)])
    if factory_token != TOKEN:
        for row in inventory()['xPNTsToken']['authorities']:
            put(factory_token,row['signature'],[],[int(o.NEW,16)])
        for row in inventory()['xPNTsToken']['mappings']:
            put(factory_token,row['signature'],[o.OLD],[0])
            for holder in {o.NEW,o.OLD_TOKEN,u.SAFE,u.TL,u.SP,u.REG,u.DEPLOYER,a.APPROVER,a.EXECUTOR,*targets,*pin['pauseList']}:
                put(factory_token,row['signature'],[holder],[1])
        put(FACTORY,'communityToToken(address)',[o.NEW],[int(factory_token,16)])
    put(TOKEN,'FACTORY()',[],[int(FACTORY,16)])
    put(factory_token,'FACTORY()',[],[int(FACTORY,16)])
    put(FACTORY,'getAllTokens()',[],[32,1,int(factory_token,16)])
    put(FACTORY,'communityToToken(address)',[u.DEPLOYER],[int(TOKEN,16)])
    put(FACTORY,'communityToToken(address)',[o.OLD],[0])
    put(u.REG,'hasRole(bytes32,address)',[CUSTOM_ROLE,o.OLD],[0])
    put(u.REG,'hasRole(bytes32,address)',[CUSTOM_ROLE,u.SAFE],[1])
    for holder in {u.DEPLOYER,*pin['pauseList']}:
        put(u.REG,'hasRole(bytes32,address)',[CUSTOM_ROLE,holder],[0])
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
    put(u.SAFE,'getModulesPaginated(address,uint256)',['0x'+'0'*39+'1',100],[64,1,0])
    def rpc(method,params):
        if overrides and (method,str(params)) in overrides:
            return overrides[(method,str(params))]
        if method == 'eth_getLogs':
            query = params[0]
            if not a.qty(query['fromBlock']) <= a.qty(pin['stateBlock']) <= a.qty(query['toBlock']):
                return []
            if query['topics'] == [a.keccak(o.ROLE_EVENT)]:
                return [dict(address=u.REG,topics=[a.keccak(o.ROLE_EVENT),role],blockNumber=pin['stateBlock'],blockHash=pin['stateBlockHash'])
                        for role in [inventory()['Registry']['roles'][0]['value'],CUSTOM_ROLE]]
            if len(query['topics']) == 3:
                return []
            name = 'Registry' if query['address'] == u.REG else 'TimelockController' if query['address'] == u.TL else None
            return [dict(address=query['address'],topics=[a.keccak(o.GRANTED),row['value'],'0x'+u.SAFE[2:].zfill(64),'0x'+u.TL[2:].zfill(64)],
                         blockNumber=pin['stateBlock'],blockHash=pin['stateBlockHash'],transactionHash='0x'+'99'*32,transactionIndex='0x0',logIndex=hex(i))
                    for i,row in enumerate(inventory()[name]['roles'])] if name else []
        if method == 'eth_getBlockByNumber':
            return dict(number=params[0],hash=pin['stateBlockHash'])
        assert params[-1] == pin['stateBlock'], params
        if method == 'eth_getStorageAt':
            return raw([int(o.FALLBACK_HANDLER,16) if params[1] == a.keccak('fallback_manager.handler.address') else 0])
        assert method == 'eth_call', method
        return answers[(params[0]['to'],params[0]['data'])]
    rpc.fork = fixture_fork(pin)
    return rpc



def fixture_fork(pin):
    state = {}
    def rpc(method,params):
        if method == 'eth_blockNumber': return pin['stateBlock']
        if method == 'eth_getBlockByNumber': return dict(hash=pin['stateBlockHash'])
        if method == 'evm_snapshot': return '0x1'
        if method == 'evm_revert':
            state.clear()
            return True
        if method.startswith('anvil_'): return True
        if method == 'eth_sendTransaction':
            data = params[0]['data']
            state['account'] = '0x'+(data[10:74][-40:] if data.startswith(a.keccak('approve(address,uint256)')[:10]) else data[-40:])
            return '0x'+'11'*32
        if method == 'eth_getTransactionReceipt':
            return dict(status='0x1',gasUsed='0x100',blockNumber=pin['stateBlock'])
        if method == 'eth_getStorageAt': return raw([int(state['account'],16)])
        if method == 'eth_call':
            if params[0]['data'].startswith(a.keccak('getModulesPaginated(address,uint256)')[:10]):
                return raw([64,1,1,int(state['account'],16)])
            return raw([int('0x'+params[0]['data'][-40:] == state['account'])])
        raise AssertionError((method,params))
    rpc.local = True
    return rpc


def evidence(pin):
    value = o.audit(fixture_rpc(pin),pin,inventory())
    value['endpointResults'] = dict(primary=copy.deepcopy(value['reads']),secondary=copy.deepcopy(value['reads']))
    return value


def removed_probe(test, action, gate):
    original = a.need
    def removed(label,actual,expected):
        if label != gate:
            original(label,actual,expected)
    with patch.object(a,'need',side_effect=removed):
        try:
            action()
        except a.Gate as error:
            test.assertNotEqual(error.record['gate'],gate)
            outcome = 'caught_elsewhere:'+error.record['gate']
        else:
            outcome = 'accepted'
    print('L1_PROBE '+gate+' removed=red '+outcome)


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
            with patch.object(a,'raw_artifact',side_effect=lambda t,n:artifacts[n]):
                self.assertEqual(o.inventory_source(tree,mode='release')['Registry']['roleEventTopic'],a.keccak(o.ROLE_EVENT))
                with self.assertRaises(a.Gate): o.inventory_source(tree)
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
        url = os.environ['OLD_OWNER_FORK_RPC']
        self.assertIn(urlsplit(url).hostname, ('localhost','127.0.0.1','::1'))
        rpc = a.RPC(url, local=True)
        pin = json.loads(Path(os.environ['OLD_OWNER_FORK_PIN']).read_text())
        role = a.keccak('PROPOSER_ROLE')
        case = dict(sender=u.TL,gate='old_owner_event_role_TimelockController',
                    transactions=[dict(target=u.TL,signature='grantRole(bytes32,address)',args=[role,'$ACCOUNT'])],
                    getter=dict(target=u.TL,signature='hasRole(bytes32,address)',args=[role,'$ACCOUNT']))
        self.assertEqual(o.fork_probe(rpc,pin,case)['status'],'verified')

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
            removed_probe(self,lambda:o.audit(rpc,self.pin,inventory()),gate)

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
        cases = []
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
                return bad if method == 'eth_getLogs' and params[0]['topics'] == [a.keccak(o.ROLE_EVENT)] else baseline(method,params)
            with self.subTest(gate=gate),self.assertRaises(a.Gate) as caught:
                o.audit(rpc,self.pin,inventory())
            self.assertEqual(caught.exception.record['gate'],gate)
            def removed(label,actual,expected):
                if label != gate:
                    original(label,actual,expected)
            rpc.fork = baseline.fork
            removed_probe(self,lambda:o.audit(rpc,self.pin,inventory()),gate)

    def test_bisected_history_replay(self):
        baseline = fixture_rpc(self.pin)
        queries = []
        full = dict(address=u.REG,fromBlock='0x1',toBlock=self.pin['stateBlock'],topics=[a.keccak(o.ROLE_EVENT)])
        def rpc(method,params):
            if method != 'eth_getLogs' or params[0]['topics'] != [a.keccak(o.ROLE_EVENT)]:
                return baseline(method,params)
            queries.append(params[0])
            if params[0] == full:
                fault = a.Gate('rpc_range','too large','bounded range')
                fault.log_range_limit = True
                raise fault
            return baseline(method,[full]) if params[0]['toBlock'] == self.pin['stateBlock'] else []
        rpc.fork = baseline.fork
        value = o.audit(rpc,self.pin,inventory())
        self.assertEqual(len(queries),3)
        self.assertEqual(queries[1]['toBlock'],'0x92')
        self.assertEqual(queries[2]['fromBlock'],'0x93')
        value['endpointResults'] = dict(primary=copy.deepcopy(value['reads']),secondary=copy.deepcopy(value['reads']))
        o.validate(value,self.pin,inventory())

    def test_optional_fork_harness_with_mock_rpc(self):
        baseline = fixture_fork(self.pin)
        transactions, restores = [], []
        def rpc(method,params):
            if method == 'eth_sendTransaction': transactions.append(params[0])
            if method == 'evm_revert': restores.append(params)
            return baseline(method,params)
        rpc.local = True
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'pin.json'
            path.write_text(json.dumps(self.pin))
            with patch.dict(os.environ,OLD_OWNER_FORK_PIN=str(path),OLD_OWNER_FORK_RPC='http://127.0.0.1:12345'), \
                 patch.object(a,'RPC',return_value=rpc):
                self.test_optional_anvil_fork_role_grant.__wrapped__(self)
        self.assertEqual(len(transactions),2)
        self.assertEqual(len(restores),2)
        role = a.keccak('PROPOSER_ROLE')
        self.assertEqual([tx['data'] for tx in transactions],[a.calldata('grantRole(bytes32,address)',role,who) for who in (o.CONTROL,o.OLD)])

    def test_positive_controls_fail_closed(self):
        section = evidence(self.pin)
        extra = [('old_owner_control_'+name, lambda r,t=target:r.get('target') == t and r.get('signature') == 'owner()',raw([0]))
                 for name,target in [('GTokenStaking',STAKING),('GToken',GTOKEN),('xPNTsFactory',FACTORY),('PaymasterFactory',o.PAYMASTER_FACTORY)]]
        extra += [('old_owner_control_MySBT',lambda r:r.get('target') == SBT and r.get('signature') == 'daoMultisig()',raw([0])),
                  ('old_owner_control_xPNTsToken',lambda r:r.get('signature') == 'communityToToken(address)',raw([0]))]
        for gate, predicate, replacement in extra + [
            ('old_owner_control_authority', lambda r:r.get('target') == u.SP and r.get('signature') == 'owner()', raw([0])),
            ('old_owner_control_registration', lambda r:r.get('signature') == 'getUserRoles(address)' and r['args'] == [u.DEPLOYER], raw([32,0])),
            ('old_owner_control_operator', lambda r:r.get('signature') == 'operators(address)' and r['args'] != [o.OLD], raw([1,0,0,int(TOKEN,16),0,0,int(u.DEPLOYER,16),0,0])),
            ('old_owner_mapping_control_path', lambda r:r.get('signature') == 'authorized(address)' and r['args'] != [o.OLD], raw([0])),
            ('old_owner_control_safe', lambda r:r.get('signature') == 'isOwner(address)', raw([0])),
        ]:
            overrides = {}
            for row in section['reads']:
                if predicate(row):
                    key = ('eth_call',str([dict(to=row['target'],data=a.calldata(row['signature'],*row['args'])),self.pin['stateBlock']]))
                    overrides[key] = replacement
            with self.subTest(gate=gate), self.assertRaises(a.Gate) as caught:
                rpc = fixture_rpc(self.pin,overrides)
                o.audit(rpc,self.pin,inventory())
            self.assertEqual(caught.exception.record['gate'],gate)
            original = a.need
            def removed(label,actual,expected):
                if label != gate:
                    original(label,actual,expected)
            removed_probe(self,lambda:o.audit(rpc,self.pin,inventory()),gate)

    def source_fixture(self):
        baseline = fixture_rpc(self.pin)
        targets = o.discover_targets(baseline,self.pin)
        sources = {target:dict(contract=name,implementation=target,commit='a'*40,creationBlock=1)
                   for name,group in targets.items() for target in group}
        def build(commit,name):
            self.assertEqual(commit,'a'*40)
            return dict(inventory=inventory()[name],artifact=dict(deployedBytecode=dict(object='0x6000',immutableReferences={})),
                        compiler=dict(version='0.8.33'),settings=dict(optimizer=dict(enabled=True,runs=10000)),forge='fixture')
        def rpc(method,params):
            if method == 'eth_getCode': return '0x' if params[1] == '0x0' else '0x6000'
            if method == 'eth_getStorageAt' and params[0] != u.SAFE: return raw([0])
            return baseline(method,params)
        rpc.fork = baseline.fork
        return rpc,sources,build

    def test_deployed_source_collection_replay_and_missing_source(self):
        rpc,sources,build = self.source_fixture()
        with patch.object(o,'deployed_build',side_effect=build):
            value = o.collect_deployed(rpc,self.pin,sources)
            value['endpointResults'] = dict(primary=copy.deepcopy(value['reads']),secondary=copy.deepcopy(value['reads']))
            value['endpointIdentities'] = dict(primary=a.ZERO32,secondary=BLOCK_HASH)
            o.validate_deployed(value,self.pin,sources)
            self.assertEqual(len(value['inventory']['deployedSources']),10)
            bad = copy.deepcopy(value)
            next(r for r in bad['sourceReads'] if r['method'] == 'eth_getCode' and r['params'][1] == self.pin['stateBlock'])['result'] = '0x6001'
            # Direct implementation code and runtime query are separate; mutate all pinned code reads.
            for r in bad['sourceReads']:
                if r['method'] == 'eth_getCode' and r['params'][1] == self.pin['stateBlock']:
                    r['result'] = '0x6001'
            with self.assertRaises(a.Gate) as caught: o.validate_deployed(bad,self.pin,sources)
            self.assertEqual(caught.exception.record['gate'],'old_owner_runtime_parity')
            removed_probe(self,lambda:o.validate_deployed(bad,self.pin,sources),'old_owner_runtime_parity')
            with self.assertRaises(a.Gate): o.collect_deployed(rpc,self.pin,{})
            with patch.object(o,'deployed_build',side_effect=a.Gate('old_owner_deployed_build','missing','source required')):
                with self.assertRaises(a.Gate) as caught: o.collect_deployed(rpc,self.pin,sources)
                self.assertEqual(caught.exception.record['gate'],'old_owner_deployed_build')

    def test_runtime_mask_ranges_and_nonimmutable_mismatch(self):
        artifact = dict(deployedBytecode=dict(object='0x60'+'00'*32+'00',immutableReferences={'7':[dict(start=1,length=32)]}))
        self.assertTrue(o.runtime_parity('0x60'+'11'*32+'00',artifact)['equal'])
        for data,gate in [('0x61'+'11'*32+'00','old_owner_runtime_parity'),('0x60','old_owner_runtime_length')]:
            with self.assertRaises(a.Gate) as caught: o.runtime_parity(data,artifact)
            self.assertEqual(caught.exception.record['gate'],gate)
        artifact['deployedBytecode']['immutableReferences']['7'][0]['length'] = 33
        with self.assertRaises(a.Gate): o.runtime_parity('0x60'+'11'*32+'00',artifact)

    def test_immutable_repeated_values_must_agree(self):
        artifact = dict(deployedBytecode=dict(object='0x'+'00'*64,
                        immutableReferences={'7':[dict(start=0,length=32),dict(start=32,length=32)]}))
        self.assertTrue(o.runtime_parity('0x'+'11'*64,artifact)['equal'])
        with self.assertRaises(a.Gate) as caught:
            o.runtime_parity('0x'+'11'*32+'22'*32,artifact)
        self.assertEqual(caught.exception.record['gate'],'old_owner_immutable_consistency')

    def test_proxy_slot_binds_parity_to_pinned_implementation(self):
        baseline,sources,build = self.source_fixture()
        implementation = '0x'+'12'*20
        sources[u.REG]['implementation'] = implementation
        sources[u.SP]['implementation'] = implementation
        slot = hex(int(a.keccak('eip1967.proxy.implementation'),16)-1)
        def rpc(method,params):
            if method == 'eth_getStorageAt' and params[0] in (u.REG,u.SP):
                self.assertEqual(params[1:],[slot,self.pin['stateBlock']])
                return raw([int(implementation,16)])
            return baseline(method,params)
        with patch.object(o,'deployed_build',side_effect=build):
            value = o.deployed_inventory(rpc,self.pin,sources)
            self.assertEqual([r['implementation'] for r in value['deployedSources'][:2]],
                             [implementation,implementation])
            for target in (u.REG,u.SP):
                bad = copy.deepcopy(sources)
                bad[target]['implementation'] = target
                with self.assertRaises(a.Gate) as caught: o.deployed_inventory(rpc,self.pin,bad)
                self.assertEqual(caught.exception.record['gate'],'old_owner_implementation')

    def test_recursive_manifest_abi_controls(self):
        inner = 'setOwner(address)'
        nested = 'nested((address,bytes)[])'
        schedule = 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)'
        safe = 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)'
        signatures = [inner,nested,schedule,safe]
        def steps(who):
            data = a.calldata(inner,who)
            data = a.calldata(schedule,u.REG,0,data,a.ZERO32,a.ZERO32,1)
            data = a.calldata(safe,u.TL,0,data,0,0,0,0,a.ZERO,a.ZERO,'0x')
            return [dict(tx=dict(to=u.SAFE,data=data))]
        self.assertGreaterEqual(len(o.assert_manifest_calldata(steps(o.NEW),signatures)),3)
        with self.assertRaises(a.Gate) as caught: o.assert_manifest_calldata(steps(o.OLD),signatures)
        self.assertEqual(caught.exception.record['gate'],'old_owner_calldata_bytes')
        removed_probe(self,lambda:o.assert_manifest_calldata(steps(o.OLD),signatures),'old_owner_calldata_bytes')
        data = a.calldata(nested,'[('+o.OLD+',0x)]')
        with self.assertRaises(a.Gate): o.assert_manifest_calldata([dict(tx=dict(to=u.REG,data=data))],signatures)
        data = a.calldata(schedule,u.REG,0,'0x12345678',a.ZERO32,a.ZERO32,1)
        with self.assertRaises(a.Gate) as caught: o.assert_manifest_calldata([dict(tx=dict(to=u.TL,data=data))],signatures)
        self.assertEqual(caught.exception.record['gate'],'old_owner_calldata_abi')
        ctor = dict(signature='c(address)',bytecode='0x6000')
        with self.assertRaises(a.Gate):
            o.assert_manifest_calldata([dict(tx=dict(to=None,data='0x6000'+a.cast('abi-encode','c(address)',o.OLD)[2:]),constructor=ctor)],signatures)

    def test_grants_cancellation_union_and_truncation(self):
        baseline = fixture_rpc(self.pin)
        role = inventory()['Registry']['roles'][0]['value']
        def event(kind,index,who=o.OLD,r=CUSTOM_ROLE):
            return dict(address=u.REG,topics=[a.keccak(kind),r,'0x'+who[2:].zfill(64),'0x'+u.TL[2:].zfill(64)],
                        blockNumber=self.pin['stateBlock'],blockHash=BLOCK_HASH,transactionHash='0x'+'99'*32,transactionIndex='0x0',logIndex=hex(index))
        standard = event(o.GRANTED,0,u.SAFE,role)
        logs = [standard,event(o.GRANTED,1),event(o.REVOKED,2)]
        def rpc(method,params):
            if method != 'eth_getLogs': return baseline(method,params)
            q = params[0]
            if a.qty(q['toBlock']) < a.qty(self.pin['stateBlock']): return []
            return logs[1:] if len(q['topics']) == 3 else logs
        self.assertEqual(o.role_history(rpc,self.pin,u.REG,inventory()['Registry'],1),sorted([role,CUSTOM_ROLE]))
        logs.pop()
        with self.assertRaises(a.Gate) as caught: o.role_history(rpc,self.pin,u.REG,inventory()['Registry'],1)
        self.assertEqual(caught.exception.record['gate'],'old_owner_uncancelled_grants')
        removed_probe(self,lambda:o.role_history(rpc,self.pin,u.REG,inventory()['Registry'],1),'old_owner_uncancelled_grants')
        logs.append(event(o.REVOKED,2))
        def truncated(method,params):
            result = rpc(method,params)
            if method == 'eth_getLogs' and params[0]['fromBlock'] == '0x1' and params[0]['toBlock'] == self.pin['stateBlock']:
                return result[:1]
            return result
        with self.assertRaises(a.Gate) as caught: o.role_history(truncated,self.pin,u.REG,inventory()['Registry'],1)
        self.assertEqual(caught.exception.record['gate'],'old_owner_log_partition')
        removed_probe(self,lambda:o.role_history(truncated,self.pin,u.REG,inventory()['Registry'],1),'old_owner_log_partition')

    def test_missing_fork_and_bad_live_getter_stop(self):
        rpc = fixture_rpc(self.pin)
        rpc.fork = None
        with self.assertRaises(a.Gate) as caught: o.audit(rpc,self.pin,inventory())
        self.assertEqual(caught.exception.record['observed'],'unverified')
        for response in ('0x','0x01'):
            query = ('eth_call',str([dict(to=u.SAFE,data=a.calldata('isModuleEnabled(address)',o.OLD)),self.pin['stateBlock']]))
            with self.assertRaises(a.Gate): o.audit(fixture_rpc(self.pin,{query:response}),self.pin,inventory())
        value = evidence(self.pin)
        self.assertEqual([c['status'] for c in value['forkControls']],['verified','verified'])
        for control in value['forkControls']:
            self.assertFalse(control['results'][0]['stopped'])
            self.assertTrue(control['results'][1]['stopped'])

    def test_fork_role_and_approval_rpc_doubles(self):
        role = inventory()['TimelockController']['roles'][0]['value']
        for sig,args,getter in [('grantRole(bytes32,address)',[role,'$ACCOUNT'],dict(target=u.TL,signature='hasRole(bytes32,address)',args=[role,'$ACCOUNT'])),
                               ('approve(address,uint256)',['$ACCOUNT',1],dict(target=TOKEN,signature='allowance(address,address)',args=[u.SAFE,'$ACCOUNT']))]:
            case = dict(sender=u.TL if sig.startswith('grant') else u.SAFE,gate='injected_old',
                        transactions=[dict(target=getter['target'],signature=sig,args=args)],getter=getter)
            self.assertEqual(o.fork_probe(fixture_fork(self.pin),self.pin,case)['status'],'verified')

    @unittest.skipUnless(os.environ.get('OLD_OWNER_CONTROL_RPC') and os.environ.get('OLD_OWNER_FORK_PIN') and (a.ENGINE/'anvil').is_file(),
                         'opt-in hydrated local engine and fixed pin required')
    def test_optional_all_fork_controls(self):
        pin = json.loads(Path(os.environ['OLD_OWNER_FORK_PIN']).read_text())
        rpc = o.local_control_fork()
        cases = list(pin.get('isolationControlCases',{}).values())
        cases += [dict(sender=u.SAFE,gate='old_owner_safe_guard',guard=True,
                       transactions=[dict(target=u.SAFE,signature='setGuard(address)',args=['$ACCOUNT'])],
                       getter=dict(target=u.SAFE,slot=a.keccak('guard_manager.guard.address'))),
                  dict(sender=u.SAFE,gate='old_owner_safe_modules',module=True,
                       transactions=[dict(target=u.SAFE,signature='enableModule(address)',args=['$ACCOUNT'])],
                       getter=dict(target=u.SAFE,signature='isModuleEnabled(address)',args=['$ACCOUNT'])),
                  dict(sender=u.SAFE,gate='old_owner_allowance_'+pin['capped']+'_'+u.SAFE,
                       transactions=[dict(target=pin['capped'],signature='approve(address,uint256)',args=['$ACCOUNT',1])],
                       getter=dict(target=pin['capped'],signature='allowance(address,address)',args=[u.SAFE,'$ACCOUNT']))]
        for case in cases:
            self.assertEqual(o.fork_probe(rpc,pin,case)['status'],'verified')

    def test_release_source_hook_and_negative_controls(self):
        import manifest_exec as m
        value = evidence(self.pin)
        report = o.negative_controls(value,self.pin,inventory())
        self.assertEqual(len(report),sum('negativeControl' in row for row in value['reads']))
        self.assertTrue(all(row['status'] == 'STOP' for row in report))
        expanded = copy.deepcopy(inventory())
        for name in m.NAMES:
            expanded.setdefault(name,copy.deepcopy(inventory()['APNTsCapped']))
        targets = {name:[u.SP if name == 'SuperPaymaster' else FACTORY if name == 'xPNTsFactoryV2' else TOKEN] for name in m.NAMES}
        rpc = fixture_rpc(self.pin)
        with patch.object(o,'inventory_source',return_value=expanded) as source, patch.object(o,'audit',return_value=value) as audit, \
             patch.object(o,'negative_controls',return_value=report) as negatives:
            result = o.post_upgrade_check(rpc,self.pin,Path('/release-fixture'),targets,{TOKEN:'xPNTsTokenV2'},value,fork=rpc.fork)
            self.assertEqual(source.call_args.kwargs['mode'],'release')
            self.assertIn('SuperPaymasterAdmin',source.call_args.kwargs['names'])
            self.assertEqual(result['negativeControls'],report)
            self.assertEqual(audit.call_args.args[1]['isolationExtraTargets'],targets)
            negatives.assert_called_once()

    def test_history_identity_gate_removals(self):
        baseline = fixture_rpc(self.pin)
        spec = inventory()['Registry']
        query = dict(address=u.REG,fromBlock='0x1',toBlock=self.pin['stateBlock'],topics=[[a.keccak(o.GRANTED),a.keccak(o.REVOKED)]])
        event = baseline('eth_getLogs',[query])[0]
        cases = [('old_owner_history_address','address',u.SP),('old_owner_history_removed','removed',True),
                 ('old_owner_history_signature','topics',[a.ZERO32,*event['topics'][1:]]),
                 ('old_owner_history_canonical','blockHash',a.ZERO32),
                 ('old_owner_history_log_range','blockNumber','0x124')]
        for gate,key,value in cases:
            bad = dict(event,**{key:value})
            def rpc(method,params):
                if method != 'eth_getLogs': return baseline(method,params)
                if len(params[0]['topics']) == 3 or a.qty(params[0]['toBlock']) < a.qty(self.pin['stateBlock']): return []
                return [bad]
            action = lambda:o.role_history(rpc,self.pin,u.REG,spec,1)
            with self.subTest(gate=gate),self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],gate)
            removed_probe(self,action,gate)
        empty = lambda method,params: [] if method == 'eth_getLogs' else baseline(method,params)
        with self.assertRaises(a.Gate) as caught: o.role_history(empty,self.pin,u.REG,spec,1)
        self.assertEqual(caught.exception.record['gate'],'old_owner_history_positive')
        removed_probe(self,lambda:o.role_history(empty,self.pin,u.REG,spec,1),'old_owner_history_positive')

    def test_source_implementation_and_boundary_gate_removals(self):
        rpc,sources,build = self.source_fixture()
        with patch.object(o,'deployed_build',side_effect=build):
            bad = copy.deepcopy(sources)
            bad[u.REG]['implementation'] = TOKEN
            action = lambda:o.inventory_source(rpc=rpc,pin=self.pin,sources=bad)
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],'old_owner_implementation')
            removed_probe(self,action,'old_owner_implementation')
            bad[u.REG]['implementation'] = u.REG
            bad[u.REG]['creationBlock'] = 2
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],'old_owner_creation_before')
            removed_probe(self,action,'old_owner_creation_before')

    def test_fork_pin_positive_and_restore_gates(self):
        role = inventory()['TimelockController']['roles'][0]['value']
        case = dict(sender=u.TL,gate='old_injected',transactions=[dict(target=u.TL,signature='grantRole(bytes32,address)',args=[role,'$ACCOUNT'])],
                    getter=dict(target=u.TL,signature='hasRole(bytes32,address)',args=[role,'$ACCOUNT']))
        for gate,method,result in [('old_owner_fork_pin','eth_getBlockByNumber',dict(hash=a.ZERO32)),
                                   ('old_owner_fork_head','eth_blockNumber','0x124'),
                                   ('old_owner_fork_positive','eth_call',raw([0])),
                                   ('old_owner_fork_restore','evm_revert',False)]:
            baseline = fixture_fork(self.pin)
            def rpc(m,p): return result if m == method else baseline(m,p)
            rpc.local = True
            action = lambda:o.fork_probe(rpc,self.pin,case)
            with self.subTest(gate=gate),self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],gate)
            removed_probe(self,action,gate)


if __name__ == '__main__':
    unittest.main(verbosity=2)
