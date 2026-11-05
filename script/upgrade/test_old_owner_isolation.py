"""Offline L-1 controls, using synthetic compiler ASTs and strict RPC replies."""
import copy
import json
import os
import subprocess
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
CBOR = 'a164736f6c6343000821000a'
IMPL = a.create_address(FACTORY,1)
CLONE = '0x363d3d373d3d3d363d73'+IMPL[2:]+'5af43d82803e903d91602b57fd5bf3'
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
        if name == 'Registry':
            for label in ('ANODE','KMS'):
                variable('ROLE_'+label,'bytes32',constant=True,value=dict(nodeType='FunctionCall',expression=dict(name='keccak256'),arguments=[dict(value=label)]))
                members[-1]['src'] = str(10+len(members))+':1:0'
            variable('hasRole','mapping(bytes32 => mapping(address => bool))',
                     typeName=dict(nodeType='Mapping',keyType=dict(name='bytes32'),
                                   valueType=dict(nodeType='Mapping',keyType=dict(name='address'),valueType=dict(name='bool'))))
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
        if name == 'xPNTsToken':
            variable('approvedFacilitators','mapping(address => bool)',typeName=dict(nodeType='Mapping',keyType=dict(name='address'),valueType=dict(name='bool')))
            function('approvedFacilitators',['address'],['bool'])
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
            result = o.inventory_source(tree,mode='release')
            return result


def raw(values):
    return '0x'+''.join(format(v,'064x') for v in values)


def fixture_rpc(pin, overrides=None, factory_token=TOKEN):
    answers = {}
    targets = [u.REG,u.SP,pin['capped'],u.TL,STAKING,GTOKEN,FACTORY,SBT,o.PAYMASTER_FACTORY,TOKEN,factory_token,*o.ROUND_CLONES]
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
        if name == 'Registry':
            put(target,'hasRole(bytes32,address)',[o.ROLE_COMMUNITY,u.DEPLOYER],[1])
            for role in o.NEVER_GRANTED[u.REG]:
                for who in {o.OLD,o.NEW,o.OLD_TOKEN,*principals,*targets,*pin['pauseList']}:
                    put(target,'hasRole(bytes32,address)',[role,who],[0])
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
    for token in o.ROUND_CLONES:
        for row in inventory()['xPNTsToken']['authorities']:
            put(token,row['signature'],[],[int(token,16)])
        for row in inventory()['xPNTsToken']['mappings']:
            for holder in {o.OLD,o.NEW,o.OLD_TOKEN,u.SAFE,u.TL,u.SP,u.REG,u.DEPLOYER,a.APPROVER,a.EXECUTOR,*targets,*pin['pauseList']}:
                put(token,row['signature'],[holder],[int(holder != o.OLD)])
        put(token,'FACTORY()',[],[int(FACTORY,16)])
        put(FACTORY,'communityToToken(address)',[token],[int(token,16)])
    put(TOKEN,'FACTORY()',[],[int(FACTORY,16)])
    put(factory_token,'FACTORY()',[],[int(FACTORY,16)])
    # Like the pinned chain: the factory enumerates the round clones (plus the fixture's own token).
    listed = sorted({*o.ROUND_CLONES, factory_token})
    put(FACTORY,'getAllTokens()',[],[32,len(listed),*[int(t,16) for t in listed]])
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
    for token in set((pin['capped'],*o.ROUND_CLONES,TOKEN,GTOKEN,factory_token)):
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
                        for role in [*[r['value'] for r in inventory()['Registry']['roles']],CUSTOM_ROLE]]
            if len(query['topics']) == 3:
                return []
            name = 'Registry' if query['address'] == u.REG else 'TimelockController' if query['address'] == u.TL else None
            rows = [r for r in inventory()[name]['roles'] if r['value'] not in o.NEVER_GRANTED.get(query['address'],[])] if name else []
            kinds = ([o.GRANTED]*15+[o.REGISTERED]*36) if name == 'Registry' else [o.GRANTED]*len(rows)
            return [dict(address=query['address'],topics=[a.keccak(kind),rows[i % len(rows)]['value'],'0x'+u.SAFE[2:].zfill(64)]+(['0x'+u.TL[2:].zfill(64)] if kind == o.GRANTED else []),
                         data=raw([0,123]),blockNumber=pin['stateBlock'],blockHash=pin['stateBlockHash'],transactionHash='0x'+'99'*32,transactionIndex='0x0',logIndex=hex(i))
                    for i,kind in enumerate(kinds)]

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
        except (TypeError, KeyError, IndexError) as error:
            outcome = 'crash:'+type(error).__name__
        else:
            outcome = 'accepted'
    print('L1_PROBE '+gate+' removed=red '+outcome)


class OldOwnerIsolationTests(unittest.TestCase):
    def setUp(self):
        self.pin = dict(stateBlockHash=BLOCK_HASH,registryCreation=1,stateBlock='0x123', capped=CAPPED,pauseList=[u.DEPLOYER])

    def assert_gate(self, gate, action):
        with self.assertRaises(a.Gate) as caught:
            action()
        self.assertEqual(caught.exception.record['gate'],gate)

    def test_never_granted_range_grant(self):
        baseline = fixture_rpc(self.pin)
        def rpc(method,params):
            value = baseline(method,params)
            if method == 'eth_getLogs' and value and isinstance(params[0]['topics'][0],list):
                value = copy.deepcopy(value)
                value[0]['topics'][1] = o.ROLE_ANODE
            return value
        self.assert_gate('old_owner_never_granted_set',lambda:o.role_history(rpc,self.pin,u.REG,inventory()['Registry'],1))

    def test_never_granted_extra_zero(self):
        spec = copy.deepcopy(inventory()['Registry'])
        spec['roles'].append(dict(name='EXTRA_ROLE',value=CUSTOM_ROLE))
        self.assert_gate('old_owner_never_granted_set',lambda:o.role_history(fixture_rpc(self.pin),self.pin,u.REG,spec,1))

    def test_never_granted_missing_role(self):
        spec = copy.deepcopy(inventory()['Registry'])
        spec['roles'] = [r for r in spec['roles'] if r['value'] != o.ROLE_KMS]
        self.assert_gate('old_owner_never_granted_set',lambda:o.role_history(fixture_rpc(self.pin),self.pin,u.REG,spec,1))

    def never_holder(self, holder):
        key = ('eth_call',str([dict(to=u.REG,data=a.calldata('hasRole(bytes32,address)',o.ROLE_ANODE,holder)),self.pin['stateBlock']]))
        self.assert_gate('old_owner_never_granted_holder',lambda:o.audit(fixture_rpc(self.pin,{key:raw([1])}),self.pin,inventory()))

    def test_never_granted_old_holder(self):
        self.never_holder(o.OLD)

    def test_never_granted_control_holder(self):
        self.never_holder(u.SAFE)

    def test_mapping_function_falls_back(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            artifacts = fixture_ast(tree)
            path = tree/'out/build-info/test.json'
            data = json.loads(path.read_text())
            nodes = data['output']['sources']['contracts/src/Registry.sol']['ast']['nodes'][0]['nodes']
            node = next(n for n in nodes if n['name'] == 'hasRole')
            node.clear()
            node.update(nodeType='FunctionDefinition',name='hasRole',src='7:1:0',
                        visibility='public',stateMutability='view',parameters=dict(parameters=[{},{}]))
            path.write_text(json.dumps(data))
            with patch.object(a,'raw_artifact',side_effect=lambda t,n:artifacts[n]):
                spec = o.extract(tree)
            self.assertEqual(spec['Registry']['hasRoleGetter'],'function')
            self.assert_gate('old_owner_role_control_path',lambda:o.audit(fixture_rpc(self.pin),self.pin,spec))

    def test_mapping_unlisted_role_still_requires_control(self):
        key = ('eth_call',str([dict(to=u.REG,data=a.calldata('hasRole(bytes32,address)',CUSTOM_ROLE,u.SAFE)),self.pin['stateBlock']]))
        self.assert_gate('old_owner_role_control_path',lambda:o.audit(fixture_rpc(self.pin,{key:raw([0])}),self.pin,inventory()))

    def test_mapping_enduser_without_control_holder(self):
        # DSR 2026-11-05: ENDUSER has history but no control holder; the mapping-getter proof is its control path.
        self.assertEqual(o.ROLE_ENDUSER, a.keccak('ENDUSER'))
        def query(sig,args):
            return ('eth_call',str([dict(to=u.REG,data=a.calldata(sig,*args)),self.pin['stateBlock']]))
        cfg = [32]+[0]*13
        cfg[10],cfg[11] = 384,int(u.DEPLOYER,16)
        overrides = {query('hasRole(bytes32,address)',[o.ROLE_ENDUSER,who]):raw([0])
                     for who in {o.OLD,u.SAFE,u.DEPLOYER,*self.pin['pauseList']}}
        overrides[query('getRoleConfig(bytes32)',[o.ROLE_ENDUSER])] = raw(cfg)
        base = fixture_rpc(self.pin,overrides)
        seen = []
        def rpc(method,params):
            result = base(method,params)
            query = params[0] if method == 'eth_getLogs' else {}
            if query.get('address') == u.REG and len(query['topics']) == 1 and len(query['topics'][0]) == 4 and result:
                # One RoleGranted(ENDUSER) to the Safe, appended to the Registry grant history.
                grant = next(log for log in result if log['topics'][0] == a.keccak(o.GRANTED))
                result = result+[dict(grant,topics=[grant['topics'][0],o.ROLE_ENDUSER,*grant['topics'][2:]],logIndex=hex(len(result)))]
            if method == 'eth_call':
                seen.append(params[0]['data'])
            return result
        rpc.fork = base.fork
        result = o.audit(rpc,self.pin,inventory())
        self.assertIn(o.ROLE_ENDUSER, result['roleHistory'][u.REG])
        # The mapping controls ran: COMMUNITY read for DEPLOYER (positive) and OLD (negative).
        for who in (u.DEPLOYER,o.OLD):
            self.assertIn(a.calldata('hasRole(bytes32,address)',o.ROLE_COMMUNITY,who),seen)

    def test_role_control_case_without_path_gate(self):
        # With the path gate only recording (diagnostic mode), a missing case still STOPs as a gate, not a TypeError.
        key = ('eth_call',str([dict(to=u.REG,data=a.calldata('hasRole(bytes32,address)',CUSTOM_ROLE,u.SAFE)),self.pin['stateBlock']]))
        original = a.need
        def recording(name, observed, expected):
            if name != 'old_owner_role_control_path':
                return original(name, observed, expected)
        with patch.object(a,'need',side_effect=recording):
            self.assert_gate('old_owner_role_control_case',lambda:o.audit(fixture_rpc(self.pin,{key:raw([0])}),self.pin,inventory()))

    def test_mapping_positive_zero(self):
        self.assert_gate('old_owner_mapping_positive',lambda:o.mapping_control(inventory()['Registry'],u.REG,o.ROLE_ANODE,lambda *args:0))

    def test_mapping_negative_one(self):
        self.assert_gate('old_owner_mapping_negative',lambda:o.mapping_control(inventory()['Registry'],u.REG,o.ROLE_ANODE,lambda *args:1))

    def test_imported_roles_without_has_role_remain_in_standard_union(self):
        spec = copy.deepcopy(inventory()['SuperPaymaster'])
        spec['roles'] = copy.deepcopy(inventory()['Registry']['roles'])
        declared = {}
        result = o.role_history(fixture_rpc(self.pin),self.pin,u.SP,spec,1,declared=declared)
        self.assertEqual(result,sorted(r['value'] for r in spec['roles']))
        self.assertEqual(declared,{})

    def test_history_all_roles_zero(self):
        baseline = fixture_rpc(self.pin)
        rpc = lambda method,params: [] if method == 'eth_getLogs' else baseline(method,params)
        self.assert_gate('old_owner_history_positive',lambda:o.role_history(rpc,self.pin,u.TL,inventory()['TimelockController'],1))

    def test_extraction_and_no_has_role(self):
        data = inventory()
        self.assertEqual(data['Registry']['roles'][1]['name'],'ROLE_COMMUNITY')
        self.assertEqual(data['Registry']['roles'][1]['line'],2)
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
        value = dict(self.pin, oldActivityReads=dict(primary=[]),
                     oldOwnerIsolation=o.audit(fixture_rpc(self.pin),self.pin,inventory()))
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
        registry_role = inventory()['Registry']['roles'][1]['value']
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
        self.assertEqual(value['xpnts'],sorted([TOKEN,token,*o.ROUND_CLONES]))
        self.assertIn(GTOKEN,value['tokens'])
        query = ('eth_call',str([dict(to=token,data=a.calldata('autoApprovedSpenders(address)',o.OLD)),self.pin['stateBlock']]))
        with self.assertRaises(a.Gate) as caught:
            o.audit(fixture_rpc(self.pin,{query:raw([1])},factory_token=token),self.pin,inventory())
        self.assertEqual(caught.exception.record['gate'],'old_owner_mapping_xPNTsToken_autoApprovedSpenders')

    def test_decoded_arguments_both_cast_formats(self):
        values = ['0x0000000000000000000000000000000000000001', 5]
        self.assertEqual(o.decoded_arguments(values), values)
        self.assertEqual(o.decoded_arguments(dict(schema_version=1, success=True, data=values, errors=[], warnings=[])), values)
        for bad in (dict(success=False, data=values, errors=[]), dict(success=True, data=values, errors=['x']),
                    dict(success=True, data='x', errors=[]), 'x', None):
            with self.subTest(bad=bad), self.assertRaises(a.Gate) as caught:
                o.decoded_arguments(bad)
            self.assertEqual(caught.exception.record['gate'], 'old_owner_calldata_decode')

    def test_manifest_calldata_invalid_cast_output(self):
        signature = 'setOwner(address)'
        steps = [dict(tx=dict(to=u.REG,data=a.calldata(signature,o.NEW)))]
        original = a.cast
        for bad in ('invalid', None, 7, True):
            def cast(*args):
                return json.dumps(bad) if args[0] == 'decode-calldata' else original(*args)
            with self.subTest(output=bad), patch.object(a,'cast',side_effect=cast):
                with self.assertRaises(a.Gate) as caught:
                    o.assert_manifest_calldata(steps,[signature])
                self.assertEqual(caught.exception.record['gate'],'old_owner_calldata_decode')

    def test_safe_noncanonical_fallback_and_non_old_module(self):
        cases = [
            ('old_owner_fallback_canonical', 'eth_getStorageAt',
             [u.SAFE,a.keccak('fallback_manager.handler.address'),self.pin['stateBlock']],raw([int(TOKEN,16)])),
            ('old_owner_module_page', 'eth_call',
             [dict(to=u.SAFE,data=a.calldata('getModulesPaginated(address,uint256)','0x'+'0'*39+'1',100)),self.pin['stateBlock']],
             raw([64,1,1,int(TOKEN,16)])),
        ]
        for gate,method,params,value in cases:
            with self.subTest(gate=gate):
                rpc = fixture_rpc(self.pin,{(method,str(params)):value})
                action = lambda:o.audit(rpc,self.pin,inventory())
                with self.assertRaises(a.Gate) as caught:
                    action()
                self.assertEqual(caught.exception.record['gate'],gate)
                removed_probe(self,action,gate)

    def test_old_filtered_history_cannot_hide_grant(self):
        baseline = fixture_rpc(self.pin)
        def rpc(method,params):
            result = baseline(method,params)
            if method == 'eth_getLogs' and len(params[0]['topics']) == 1:
                result = copy.deepcopy(result)
                for log in result:
                    log['topics'][2] = '0x'+o.OLD[2:].zfill(64)
            return result
        action = lambda:o.role_history(rpc,self.pin,u.REG,inventory()['Registry'],1)
        with self.assertRaises(a.Gate) as caught:
            action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_history_old_filter')
        removed_probe(self,action,'old_owner_history_old_filter')
        original = a.need
        def removed(label,actual,expected):
            if label != 'old_owner_history_old_filter':
                original(label,actual,expected)
        with patch.object(a,'need',side_effect=removed), self.assertRaises(a.Gate) as caught:
            action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_uncancelled_grants')

    def test_immutable_expectations_ignore_dirty_worktree(self):
        committed = subprocess.run(['git','show','HEAD:deployments/config.sepolia.json'],
                                   cwd=u.ROOT,capture_output=True,check=True).stdout
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            # Build a temporary HEAD without creating a commit or changing the real checkout.
            subprocess.run(['git','init','-q',directory],check=True)
            blob = subprocess.run(['git','hash-object','-w','--stdin'],cwd=tree,input=committed,capture_output=True,check=True).stdout.decode().strip()
            subtree = subprocess.run(['git','mktree'],cwd=tree,input=f'100644 blob {blob}\tconfig.sepolia.json\n'.encode(),capture_output=True,check=True).stdout.decode().strip()
            root = subprocess.run(['git','mktree'],cwd=tree,input=f'040000 tree {subtree}\tdeployments\n'.encode(),capture_output=True,check=True).stdout.decode().strip()
            (tree/'.git/HEAD').write_text(root+'\n')
            path = tree/'deployments/config.sepolia.json'
            path.parent.mkdir()
            path.write_bytes(committed)
            with patch.object(u,'ROOT',tree):
                expected = o.immutable_expectations(o.NEW)
                dirty = json.loads(committed)
                dirty['entryPoint'] = o.OLD
                dirty['xPNTsFactory'] = o.OLD
                path.write_text(json.dumps(dirty))
                self.assertEqual(o.immutable_expectations(o.NEW),expected)
                self.assertEqual(expected['entryPoint'],json.loads(committed)['entryPoint'].lower())

    def test_factory_enumeration_must_stand_alone(self):
        query = ('eth_call',str([dict(to=FACTORY,data=a.calldata('getAllTokens()')),self.pin['stateBlock']]))
        for listed in ([], [o.ROUND_CLONES[0]]):
            with self.subTest(listed=listed):
                answer = raw([32,len(listed),*[int(t,16) for t in listed]])
                for run in (lambda rpc: o.audit(rpc,self.pin,inventory()), lambda rpc: o.discover_targets(rpc,self.pin)):
                    with self.assertRaises(a.Gate) as caught:
                        run(fixture_rpc(self.pin,{query:answer}))
                    self.assertEqual(caught.exception.record['gate'],'old_owner_factory_enumeration')

    def test_role_history_authentication_and_empty_probes(self):
        baseline = fixture_rpc(self.pin)
        query = dict(address=u.REG,fromBlock=hex(self.pin['registryCreation']),toBlock=self.pin['stateBlock'],topics=[a.keccak(o.ROLE_EVENT)])
        logs = baseline('eth_getLogs',[query])
        cases = []
        for gate,field,value in [('old_owner_role_log_address','address',u.SP),
                                 ('old_owner_role_log_removed','removed',True),
                                 ('old_owner_role_log_topic','topics',[a.ZERO32,inventory()['Registry']['roles'][1]['value']]),
                                 ('old_owner_role_log_canonical','blockHash',a.ZERO32),
                                 ('old_owner_role_log_range','blockNumber','0x124')]:
            bad = copy.deepcopy(logs)
            bad[0][field] = value
            cases.append((gate,bad))
        original = a.need
        for gate,bad in cases:
            def rpc(method,params):
                return (bad if params[0]['toBlock'] == self.pin['stateBlock'] else []) if method == 'eth_getLogs' and params[0]['topics'] == [a.keccak(o.ROLE_EVENT)] else baseline(method,params)
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
        self.assertEqual(len(queries),5)
        self.assertEqual(queries[1]['toBlock'],'0x92')
        self.assertEqual(queries[2]['fromBlock'],'0x93')
        value['endpointResults'] = dict(primary=copy.deepcopy(value['reads']),secondary=copy.deepcopy(value['reads']))
        o.validate(value,self.pin,inventory())

    def test_config_history_drop_truncation_both_endpoints(self):
        baseline = fixture_rpc(self.pin)
        full = dict(address=u.REG,fromBlock='0x1',toBlock=self.pin['stateBlock'],topics=[a.keccak(o.ROLE_EVENT)])
        for endpoint in ('primary','secondary'):
            def bad(method,params):
                logs = baseline(method,params)
                if method == 'eth_call' and params[0] == dict(to=u.REG,data=a.calldata('getRoleConfig(bytes32)',CUSTOM_ROLE)):
                    values = u.uints(logs)
                    values[11] = int(o.OLD,16)
                    return raw(values)
                return logs[:1] if method == 'eth_getLogs' and params[0] == full else logs
            bad.fork = baseline.fork
            action = lambda:o.audit(bad,self.pin,inventory())
            with self.subTest(endpoint=endpoint), self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],'old_owner_log_partition')
            removed_probe(self,action,'old_owner_log_partition')
            section = evidence(self.pin)
            for row in section['endpointResults'][endpoint]:
                if row.get('method') == 'eth_getLogs' and row['params'][0] == full:
                    row['result'] = row['result'][:1]
            with self.assertRaises(a.Gate) as caught: o.validate(section,self.pin,inventory())
            self.assertEqual(caught.exception.record['gate'],'old_owner_log_partition')
        query = dict(full,fromBlock=self.pin['stateBlock'])
        action = lambda:o.bounded_history_logs(lambda m,p:[{}]*1000,query)
        with self.assertRaises(a.Gate) as caught: action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_log_limit')
        removed_probe(self,action,'old_owner_log_limit')

    def test_legacy_timelock_source_targets(self):
        rpc, sources, build = self.source_fixture()
        sources[o.OLD_TIMELOCK] = sources.pop(u.TL)
        with patch.object(o, 'deployed_build', side_effect=build), self.assertRaises(a.Gate) as caught:
            o.deployed_inventory(rpc, self.pin, sources)
        self.assertEqual(caught.exception.record['gate'], 'old_owner_source_targets')

    def test_all_inventory_targets_read_both_slots_at_pin(self):
        baseline,sources,build = self.source_fixture()
        reads = []
        def rpc(method,params):
            if method == 'eth_getStorageAt': reads.append(params)
            return baseline(method,params)
        with patch.object(o,'deployed_build',side_effect=build):
            result = o.deployed_inventory(rpc,self.pin,sources)
        self.assertEqual(sorted(reads),sorted([target,slot,self.pin['stateBlock']]
                         for target in sources for slot in (o.IMPLEMENTATION_SLOT,o.BEACON_SLOT)))
        proxies = {row['target'] for row in result['deployedSources'] if row['proxy'] is not None}
        self.assertEqual(proxies,{u.REG,u.SP})

    def test_unexpected_indirection_and_gate_removals(self):
        baseline,sources,build = self.source_fixture()
        # Valid implementation bytes must never authorize an undeclared proxy.
        for slot in (o.IMPLEMENTATION_SLOT,o.BEACON_SLOT):
            changed = copy.deepcopy(sources)
            changed[GTOKEN]['implementation'] = IMPL if slot == o.IMPLEMENTATION_SLOT else GTOKEN
            def rpc(method,params):
                if method == 'eth_getStorageAt' and params == [GTOKEN,slot,self.pin['stateBlock']]:
                    return raw([int(IMPL,16)])
                return baseline(method,params)
            with self.subTest(slot=slot),patch.object(o,'deployed_build',side_effect=build):
                action = lambda:o.deployed_inventory(rpc,self.pin,changed)
                with self.assertRaises(a.Gate) as caught: action()
                self.assertEqual(caught.exception.record['gate'],'unexpected_proxy')
                removed_probe(self,action,'unexpected_proxy')
        def clone_rpc(method,params):
            if method == 'eth_getCode' and params == [GTOKEN,self.pin['stateBlock']]: return CLONE
            return baseline(method,params)
        def clone_build(commit,name):
            result = build(commit,name)
            if name == 'GToken': result['artifact']['deployedBytecode']['object'] = CLONE
            return result
        with patch.object(o,'deployed_build',side_effect=clone_build):
            action = lambda:o.deployed_inventory(clone_rpc,self.pin,sources)
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],'old_owner_undeclared_clone')
            removed_probe(self,action,'old_owner_undeclared_clone')

    def test_role_configured_independent_coverage_and_gate_removals(self):
        baseline = fixture_rpc(self.pin)
        for missing_standard in (False,True):
            def rpc(method,params):
                result = baseline(method,params)
                if method == 'eth_getLogs' and params[0]['topics'] == [a.keccak(o.ROLE_EVENT)]:
                    return [row for row in result if row['topics'][1] == CUSTOM_ROLE] if missing_standard else []
                return result
            rpc.fork = baseline.fork
            with self.subTest(missing_standard=missing_standard):
                action = lambda:o.audit(rpc,self.pin,inventory())
                with self.assertRaises(a.Gate) as caught: action()
                self.assertEqual(caught.exception.record['gate'],'old_owner_role_extraction_empty')
                removed_probe(self,action,'old_owner_role_extraction_empty')

    def test_role_configured_coverage_per_emitter(self):
        inv = copy.deepcopy(inventory())
        inv['TimelockController']['roleEventTopic'] = a.keccak(o.ROLE_EVENT)
        baseline = fixture_rpc(self.pin)
        empty = False
        def rpc(method,params):
            if method == 'eth_getLogs' and params[0]['address'] == u.TL and params[0]['topics'] == [a.keccak(o.ROLE_EVENT)]:
                if empty: return []
                logs = baseline(method,params)
                for row in logs:
                    row['address'] = u.TL
                    row['topics'][1] = inv['TimelockController']['roles'][0]['value']
                return logs[:1]
            return baseline(method,params)
        rpc.fork = baseline.fork
        o.audit(rpc,self.pin,inv)
        empty = True
        with self.assertRaises(a.Gate) as caught: o.audit(rpc,self.pin,inv)
        self.assertEqual(caught.exception.record['gate'],'old_owner_role_extraction_empty')
        removed_probe(self,lambda:o.audit(rpc,self.pin,inv),'old_owner_role_extraction_empty')

    def test_proxy_runtime_extra_selector_stops(self):
        baseline,sources,build = self.source_fixture()
        # Implementation remains correct; only the proxy bytecode is changed.
        impl = '0x'+'ab'*20
        for target in (u.REG,u.SP):
            sources[target]['implementation'] = impl
        for target in (u.REG,u.SP):
            def rpc(method,params):
                if method == 'eth_getStorageAt' and params[0] in (u.REG,u.SP) and params[1] == o.IMPLEMENTATION_SLOT: return raw([int(impl,16)])
                if method == 'eth_getCode' and params == [target,self.pin['stateBlock']]: return '0x6312345678506000'+CBOR
                return baseline(method,params)
            with patch.object(o,'deployed_build',side_effect=build):
                action = lambda:o.deployed_inventory(rpc,self.pin,sources)
                with self.assertRaises(a.Gate) as caught: action()
                self.assertEqual(caught.exception.record['gate'],'old_owner_runtime_length')
                removed_probe(self,action,'old_owner_runtime_length')
                original = a.need
                def removed(label,actual,expected):
                    if label not in ('old_owner_runtime_length','old_owner_runtime_parity'): original(label,actual,expected)
                with patch.object(a,'need',side_effect=removed): action()
                print('L1_PROBE proxy_runtime_all_parity_gates removed=red accepted')

    def test_deployment_record_binding_and_gate_removals(self):
        fragment = json.loads((Path(__file__).parent/'fixtures/old-owner/deployed-sources.json').read_text())
        spec = next(r for r in fragment['deployedSources'].values() if r['contract']=='APNTsCapped')
        self.assertEqual(o.verify_deployment_record(spec)['resolvedCommit'],spec['commit'])
        for field,value,gate in [
            ('sha256','0'*64,'old_owner_record_sha256'),
            ('commit','b'*40,'old_owner_record_commit'),
            ('contractAddress',TOKEN,'old_owner_record_address'),
            ('txHash',a.ZERO32,'old_owner_record_receipt')]:
            bad = copy.deepcopy(spec); bad['deploymentRecord'][field] = value
            action = lambda:o.verify_deployment_record(bad)
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],gate)
            removed_probe(self,action,gate)
        bad = copy.deepcopy(spec); bad['commit']='b'*40; bad['deploymentRecord']['commit']='b'*40
        action = lambda:o.verify_deployment_record(bad)
        with self.assertRaises(a.Gate) as caught: action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_record_source_commit')
        removed_probe(self,action,'old_owner_record_source_commit')
        rpc,sources,build = self.source_fixture()
        sources[u.SP]['claim']='deployment-record + runtime parity'
        with patch.object(o,'deployed_build',side_effect=build):
            action = lambda:o.deployed_inventory(rpc,self.pin,sources)
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],'old_owner_record_required')
            removed_probe(self,action,'old_owner_record_required')

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
        sources = {target:dict(contract=name,implementation=IMPL if name == 'xPNTsToken' else target,commit='a'*40,creationBlock=1,claim='behavioral-equivalence')
                   for name,group in targets.items() for target in group}
        def build(commit,name):
            self.assertEqual(commit,o.PROXY_COMMIT if name == 'ERC1967Proxy' else 'a'*40)
            return dict(inventory=inventory().get(name,{}),artifact=dict(deployedBytecode=dict(object='0x6000'+CBOR,immutableReferences={})),
                        compiler=dict(version='0.8.33'),settings=dict(optimizer=dict(enabled=True,runs=10000)),forge='fixture')
        def rpc(method,params):
            if method == 'eth_getCode': return '0x' if params[1] == '0x0' else CLONE if params[0] in targets['xPNTsToken'] else '0x6000'+CBOR
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
            duplicate = copy.deepcopy(value)
            duplicate['endpointIdentities']['secondary'] = duplicate['endpointIdentities']['primary']
            action = lambda:o.validate_deployed(duplicate,self.pin,sources)
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],'old_owner_endpoint_distinct')
            removed_probe(self,action,'old_owner_endpoint_distinct')
            self.assertEqual(len(value['inventory']['deployedSources']),12)
            bad = copy.deepcopy(value)
            next(r for r in bad['sourceReads'] if r['method'] == 'eth_getCode' and r['params'][1] == self.pin['stateBlock'])['result'] = '0x6001'+CBOR
            # Direct implementation code and runtime query are separate; mutate all pinned code reads.
            for r in bad['sourceReads']:
                if r['method'] == 'eth_getCode' and r['params'][1] == self.pin['stateBlock'] and r['params'][0] not in (TOKEN,*o.ROUND_CLONES):
                    r['result'] = '0x6001'+CBOR
            with self.assertRaises(a.Gate) as caught: o.validate_deployed(bad,self.pin,sources)
            self.assertEqual(caught.exception.record['gate'],'old_owner_runtime_parity')
            removed_probe(self,lambda:o.validate_deployed(bad,self.pin,sources),'old_owner_runtime_parity')
            with self.assertRaises(a.Gate): o.collect_deployed(rpc,self.pin,{})
            with patch.object(o,'deployed_build',side_effect=a.Gate('old_owner_deployed_build','missing','source required')):
                with self.assertRaises(a.Gate) as caught: o.collect_deployed(rpc,self.pin,sources)
                self.assertEqual(caught.exception.record['gate'],'old_owner_deployed_build')

    def test_registry_adopted_behavioral_claim(self):
        fragment = json.loads((Path(__file__).parent/'fixtures/old-owner/deployed-sources.json').read_text())
        self.assertNotIn('pendingDsrRuling', fragment)
        self.assertEqual(len(fragment['deployedSources']), 11)
        self.assertEqual(fragment['deployedSources'][u.REG]['claim'], 'behavioral-equivalence')
        rpc, sources, build = self.source_fixture()
        with patch.object(o, 'deployed_build', side_effect=build):
            o.collect_deployed(rpc, self.pin, sources)
            sources[u.REG]['claim'] = 'deployment-record + runtime parity'
            action = lambda:o.collect_deployed(rpc, self.pin, sources)
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'], 'old_owner_source_claim')
            removed_probe(self, action, 'old_owner_source_claim')

    def test_ast_extra_getter_revert_stops(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            artifacts = fixture_ast(tree)
            path = tree/'out/build-info/test.json'
            data = json.loads(path.read_text())
            root = data['output']['sources']['contracts/src/Registry.sol']['ast']['nodes'][0]
            root['nodes'].append(dict(nodeType='VariableDeclaration',name='extraOwner',src='7:1:0',
                stateVariable=True,visibility='public',typeDescriptions=dict(typeString='address')))
            artifacts['Registry']['abi'].append(dict(type='function',name='extraOwner',inputs=[],outputs=[dict(type='address')]))
            path.write_text(json.dumps(data))
            with patch.object(a,'raw_artifact',side_effect=lambda t,n:artifacts[n]):
                extracted = o.extract(tree)
        self.assertIn('extraOwner()', [r['signature'] for r in extracted['Registry']['authorities']])
        baseline = fixture_rpc(self.pin)
        def rpc(method, params):
            if method == 'eth_call' and params[0]['data'] == a.calldata('extraOwner()'):
                raise a.Gate('rpc_revert', 'execution reverted', 'successful getter')
            return baseline(method, params)
        with self.assertRaises(a.Gate) as caught: o.audit(rpc,self.pin,extracted)
        self.assertEqual(caught.exception.record['gate'], 'rpc_revert')

    def test_immutable_address_negative_controls_and_removals(self):
        artifact = dict(immutableDeclarations={'7':dict(name='entryPoint',type='contract IEntryPoint')},
            deployedBytecode=dict(object='0x'+'00'*32+CBOR,immutableReferences={'7':[dict(start=0,length=32)]}))
        good = o.immutable_expectations()['entryPoint']
        def run(value): return o.runtime_parity(raw([int(value,16)])+CBOR,artifact)
        self.assertEqual(run(good)['immutables'][0]['value'], good)
        for value,gate in [(o.OLD,'old_owner_immutable_not_old'),(TOKEN,'old_owner_immutable_expected')]:
            action = lambda:run(value)
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],gate)
            removed_probe(self,action,gate)
        artifact['immutableDeclarations']['7']['name'] = 'unknownAddress'
        action = lambda:run(o.OLD)
        with self.assertRaises(a.Gate): action()
        removed_probe(self,action,'old_owner_immutable_not_old')
        action = lambda:run(TOKEN)
        with self.assertRaises(a.Gate) as caught: action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_immutable_expectation_missing')
        removed_probe(self,action,'old_owner_immutable_expectation_missing')
        artifact['immutableDeclarations']['7']['type'] = 'uint256'
        self.assertEqual(run(TOKEN)['immutables'][0]['expected'],'no expected value')
        artifact['immutableDeclarations'] = {}
        with self.assertRaises(a.Gate) as caught: run(good)
        self.assertEqual(caught.exception.record['gate'],'old_owner_immutable_ast')
        removed_probe(self,lambda:run(good),'old_owner_immutable_ast')

    def test_pin_time_immutable_gates(self):
        baseline,sources,build = self.source_fixture()
        def compiled(commit,name):
            result = build(commit,name)
            if name in ('Registry','ERC1967Proxy'):
                result['artifact'] = dict(immutableDeclarations={'7':dict(name='__self',type='address')},
                    deployedBytecode=dict(object='0x'+'00'*32+CBOR,immutableReferences={'7':[dict(start=0,length=32)]}))
            return result
        for value,gate in [(o.OLD,'old_owner_immutable_not_old'),(TOKEN,'old_owner_immutable_expected'),(u.REG,None)]:
            def rpc(method,params):
                if method == 'eth_getCode' and params == [u.REG,self.pin['stateBlock']]:
                    return raw([int(value,16)])+CBOR
                return baseline(method,params)
            def only_registry(rpc,pin): return {'Registry':[u.REG]}
            with patch.object(o,'deployed_build',side_effect=compiled), patch.object(o,'discover_targets',side_effect=only_registry):
                action = lambda:o.deployed_inventory(rpc,self.pin,{u.REG:sources[u.REG]})
                if gate is None:
                    result = action()
                    row = next(r for r in result['deployedSources'] if r['contract']=='Registry')
                    self.assertEqual(row['parity']['immutables'][0]['result'],'PASS')
                else:
                    with self.assertRaises(a.Gate) as caught: action()
                    self.assertEqual(caught.exception.record['gate'],gate)
                    removed_probe(self,action,gate)

    def test_immutable_ast_and_malformed_reference_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            fixture_ast(tree)
            path = tree/'out/build-info/test.json'
            data = json.loads(path.read_text())
            root = data['output']['sources']['contracts/src/Registry.sol']['ast']['nodes'][0]
            root['nodes'].append(dict(nodeType='VariableDeclaration',id=7,name='entryPoint',mutability='immutable',
                typeDescriptions=dict(typeString='contract IEntryPoint')))
            path.write_text(json.dumps(data))
            declarations = o.immutable_declarations(tree)
        self.assertEqual(declarations, {'7':dict(name='entryPoint',type='contract IEntryPoint')})
        artifact = dict(immutableDeclarations=declarations,
            deployedBytecode=dict(object='0x'+'00'*32+CBOR,immutableReferences={'7':[dict(start=0,length=32)]}))
        action = lambda:o.runtime_parity(raw([2**160])+CBOR,artifact)
        with self.assertRaises(a.Gate) as caught: action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_immutable_address_encoding')
        removed_probe(self,action,'old_owner_immutable_address_encoding')
        artifact['deployedBytecode']['immutableReferences']['7'] = []
        action = lambda:o.runtime_parity(artifact['deployedBytecode']['object'],artifact)
        with self.assertRaises(a.Gate) as caught: action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_immutable_values')
        removed_probe(self,action,'old_owner_immutable_values')

    def test_clone_identity_and_factory_origin_controls(self):
        factory = '0x67422d2e44a33c8da99b3b776841bf316bd209a2'
        impl = '0xfdfb993ddce4d95407c893e09556e31732a5beb8'
        code = '0x363d3d373d3d3d363d73'+impl[2:]+'5af43d82803e903d91602b57fd5bf3'
        self.assertEqual(o.clone_implementation(code),impl)
        self.assertEqual(o.factory_implementation(factory),impl)
        cases = [
            (lambda:o.clone_implementation(code+'00'),'old_owner_clone_standard'),
            (lambda:o.clone_implementation('0x00'+code[4:]),'old_owner_clone_standard'),
            (lambda:o.verify_clone(code,factory,TOKEN),'old_owner_clone_implementation'),
            (lambda:o.verify_clone(code,TOKEN,impl),'old_owner_clone_factory_nonce1'),
            (lambda:o.verify_clone(code.replace(impl[2:],TOKEN[2:]),factory,impl),'old_owner_clone_implementation')]
        for action,gate in cases:
            with self.subTest(gate=gate):
                with self.assertRaises(a.Gate) as caught: action()
                self.assertEqual(caught.exception.record['gate'],gate)
                removed_probe(self,action,gate)

    def test_clone_collection_and_post_upgrade_gate_removals(self):
        rpc,sources,build = self.source_fixture()
        with patch.object(o,'deployed_build',side_effect=build):
            before = dict(sourceSelection=sources)
            tokens = (TOKEN,*o.ROUND_CLONES)
            result = o.post_upgrade_clones(rpc,self.pin,tokens,before)
            self.assertEqual(set(result['clones']),set(tokens))
            for code,gate in [(CLONE+'00','old_owner_clone_standard'),
                              (CLONE.replace(IMPL[2:],TOKEN[2:]),'old_owner_clone_implementation')]:
                def bad(method,params):
                    if method == 'eth_getCode' and params == [o.PNT_TOKEN,self.pin['stateBlock']]: return code
                    return rpc(method,params)
                for action in (lambda:o.deployed_inventory(bad,self.pin,sources),
                               lambda:o.post_upgrade_clones(bad,self.pin,tokens,before)):
                    with self.assertRaises(a.Gate) as caught: action()
                    self.assertEqual(caught.exception.record['gate'],gate)
                    removed_probe(self,action,gate)
            # A second valid factory/clone pair still cannot change the shared impl.
            other_factory = '0x'+'45'*20
            other_impl = o.factory_implementation(other_factory)
            changed = copy.deepcopy(sources)
            changed[o.PNT_TOKEN]['implementation'] = other_impl
            def different(method,params):
                if method == 'eth_getCode' and params == [o.PNT_TOKEN,self.pin['stateBlock']]:
                    return CLONE.replace(IMPL[2:],other_impl[2:])
                if method == 'eth_call' and params[0] == dict(to=o.PNT_TOKEN,data=a.calldata('FACTORY()')):
                    return raw([int(other_factory,16)])
                return rpc(method,params)
            action = lambda:o.deployed_inventory(different,self.pin,changed)
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],'old_owner_clone_same_implementation')
            removed_probe(self,action,'old_owner_clone_same_implementation')

    def test_named_clones_storage_authority_controls(self):
        for token in o.ROUND_CLONES:
            cases = [('communityOwner()',[],int(o.OLD,16),'old_owner_authority_xPNTsToken_communityOwner'),
                     ('approvedFacilitators(address)',[o.OLD],1,'old_owner_mapping_xPNTsToken_approvedFacilitators'),
                     ('autoApprovedSpenders(address)',[o.OLD],1,'old_owner_mapping_xPNTsToken_autoApprovedSpenders'),
                     ('allowance(address,address)',[u.SAFE,o.OLD],1,'old_owner_allowance_'+token+'_'+u.SAFE)]
            for signature,args,value,gate in cases:
                key = ('eth_call',str([dict(to=token,data=a.calldata(signature,*args)),self.pin['stateBlock']]))
                action = lambda:o.audit(fixture_rpc(self.pin,{key:raw([value])}),self.pin,inventory())
                with self.assertRaises(a.Gate) as caught: action()
                self.assertEqual(caught.exception.record['gate'],gate)
                removed_probe(self,action,gate)

    def test_metadata_bytes_cannot_be_masked_as_immutables(self):
        tail = 'a2646970667358221220'+'11'*32+'64736f6c6343000821'
        code = '0x6000'+tail+format(len(bytes.fromhex(tail)),'04x')
        artifact = dict(deployedBytecode=dict(object=code,immutableReferences={}))
        parity = o.runtime_parity(code,artifact)
        self.assertEqual(parity['cbor'],dict(solc='0.8.33',ipfs='1220'+'11'*32))
        changed = code.replace('11'*32,'22'*32)
        with self.assertRaises(a.Gate) as caught: o.runtime_parity(changed,artifact)
        self.assertEqual(caught.exception.record['gate'],'old_owner_source_rule4')
        removed_probe(self,lambda:o.runtime_parity(changed,artifact),'old_owner_source_rule4')
        with self.assertRaises(a.Gate) as caught:
            o.runtime_parity(changed,artifact,dict(resolvedCommit='a'*40))
        self.assertEqual(caught.exception.record['gate'],'old_owner_runtime_parity')
        artifact['deployedBytecode']['immutableReferences'] = {'7':[dict(start=12,length=32)]}
        action = lambda:o.runtime_parity(code,artifact)
        with self.assertRaises(a.Gate) as caught: action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_metadata_unmasked')
        removed_probe(self,action,'old_owner_metadata_unmasked')

    def test_metadata_masked_requires_rule4(self):
        exact = dict(equal=True,metadataUnmasked=True,metadataEqual=True)
        o.source_provenance(exact,None)
        for field in ('metadataUnmasked','metadataEqual','equal'):
            comparison = dict(exact,**{field:False})
            action = lambda:o.source_provenance(comparison,None)
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],'old_owner_source_rule4')
            removed_probe(self,action,'old_owner_source_rule4')
            o.source_provenance(comparison,dict(resolvedCommit='a'*40))

    def test_runtime_mask_ranges_and_nonimmutable_mismatch(self):
        artifact = dict(immutableDeclarations={'7':dict(name='fixture',type='uint256')},deployedBytecode=dict(object='0x60'+'00'*32+'00'+CBOR,immutableReferences={'7':[dict(start=1,length=32)]}))
        self.assertTrue(o.runtime_parity('0x60'+'11'*32+'00'+CBOR,artifact)['equal'])
        for data,gate in [('0x61'+'11'*32+'00'+CBOR,'old_owner_runtime_parity'),('0x60','old_owner_runtime_length')]:
            with self.assertRaises(a.Gate) as caught: o.runtime_parity(data,artifact)
            self.assertEqual(caught.exception.record['gate'],gate)
        artifact['deployedBytecode']['immutableReferences']['7'][0]['length'] = 33
        with self.assertRaises(a.Gate): o.runtime_parity('0x60'+'11'*32+'00'+CBOR,artifact)

    def test_immutable_repeated_values_must_agree(self):
        artifact = dict(immutableDeclarations={'7':dict(name='fixture',type='uint256')},deployedBytecode=dict(object='0x'+'00'*64+CBOR,
                        immutableReferences={'7':[dict(start=0,length=32),dict(start=32,length=32)]}))
        self.assertTrue(o.runtime_parity('0x'+'11'*64+CBOR,artifact)['equal'])
        with self.assertRaises(a.Gate) as caught:
            o.runtime_parity('0x'+'11'*32+'22'*32+CBOR,artifact)
        self.assertEqual(caught.exception.record['gate'],'old_owner_immutable_consistency')

    def test_proxy_slot_binds_parity_to_pinned_implementation(self):
        baseline,sources,build = self.source_fixture()
        implementation = '0x'+'34'*20
        sources[u.REG]['implementation'] = implementation
        sources[u.SP]['implementation'] = implementation
        slot = hex(int(a.keccak('eip1967.proxy.implementation'),16)-1)
        def rpc(method,params):
            if method == 'eth_getStorageAt' and params[0] in (u.REG,u.SP) and params[1] == o.IMPLEMENTATION_SLOT:
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

    def test_review_low_calldata_gates(self):
        cases = [
            ('creation_prefix','old_owner_calldata_bytes',[dict(tx=dict(to=None,data='0x60'+o.OLD[2:].upper()),constructor=dict(bytecode='0x60'+o.OLD[2:].upper(),signature='c()'))],[]),
            ('target','old_owner_calldata_target',[dict(tx=dict(to=o.OLD,data='0x'))],[]),
            ('variant_target','old_owner_calldata_target',[dict(tx=dict(to=u.REG,data='0x'),variants=dict(other=dict(to=o.OLD,data='0x')))],[]),
            ('payload','old_owner_calldata_payload',[dict(tx=dict(to=u.REG,data=a.calldata('execute(uint256)',1)))],['execute(uint256)'])]
        for name,gate,steps,signatures in cases:
            action = lambda:o.assert_manifest_calldata(steps,signatures)
            with self.subTest(case=name):
                with self.assertRaises(a.Gate) as caught: action()
                self.assertEqual(caught.exception.record['gate'],gate)
                removed_probe(self,action,gate)

    def test_calldata_payload_removal_hits_named_gate(self):
        steps = [dict(tx=dict(to=u.REG,data=a.calldata('execute(uint256)',1)))]
        original = a.need
        def removed(label,actual,expected):
            if label != 'old_owner_calldata_payload':
                original(label,actual,expected)
        with patch.object(a,'need',side_effect=removed):
            with self.assertRaises(a.Gate) as caught:
                o.assert_manifest_calldata(steps,['execute(uint256)'])
        self.assertEqual(caught.exception.record['gate'],'old_owner_calldata_payload_shape')

    def test_endpoint_without_hostname(self):
        from types import SimpleNamespace
        with self.assertRaises(a.Gate) as caught:
            o.endpoint_identity(SimpleNamespace(url='https:///rpc'),'primary')
        self.assertEqual(caught.exception.record['gate'],'old_owner_endpoint_host')

    def test_registered_wrong_data_length(self):
        baseline = fixture_rpc(self.pin)
        def rpc(method,params):
            result = baseline(method,params)
            if method == 'eth_getLogs':
                for log in result:
                    if log['topics'][0] == a.keccak(o.REGISTERED):
                        log['data'] = raw([123])
            return result
        with self.assertRaises(a.Gate) as caught:
            o.role_history(rpc,self.pin,u.REG,inventory()['Registry'],1)
        self.assertEqual(caught.exception.record['gate'],'old_owner_history_data')

    def test_safe_mint_exit_and_regrant(self):
        query = ('eth_call',str([dict(to=u.REG,data=a.calldata('hasRole(bytes32,address)',CUSTOM_ROLE,o.OLD)),self.pin['stateBlock']]))
        baseline = fixture_rpc(self.pin,{query:raw([0])})
        def event(kind,index):
            topics = [a.keccak(kind),CUSTOM_ROLE,raw([int(o.OLD,16)])]
            if kind in (o.GRANTED,o.REVOKED):
                topics.append(raw([int(u.TL,16)]))
            return dict(address=u.REG,topics=topics,data=raw([0,123]),
                        blockNumber=self.pin['stateBlock'],blockHash=BLOCK_HASH,
                        transactionHash='0x'+'ab'*32,transactionIndex='0x1',logIndex=hex(index))
        extra = [event(o.GRANTED,100),event(o.REGISTERED,101),event(o.EXITED,102)]
        def rpc(method,params):
            result = baseline(method,params)
            if method == 'eth_getLogs' and a.qty(params[0]['toBlock']) >= a.qty(self.pin['stateBlock']):
                result += list(reversed(extra))
            return result
        action = lambda:o.role_history(rpc,self.pin,u.REG,inventory()['Registry'],1)
        self.assertIn(CUSTOM_ROLE,action())
        self.assertEqual(a.word(baseline,u.REG,'hasRole(bytes32,address)',
                               CUSTOM_ROLE,o.OLD,block=self.pin['stateBlock']),0)
        for kind in (o.GRANTED,o.REGISTERED):
            with self.subTest(regrant=kind):
                extra.append(event(kind,103))
                with self.assertRaises(a.Gate) as caught: action()
                self.assertEqual(caught.exception.record['gate'],'old_owner_uncancelled_grants')
                extra.pop()
        extra[-1] = event(o.REVOKED,102)
        self.assertIn(CUSTOM_ROLE,action())

    def test_review_low_endpoint_identity(self):
        from types import SimpleNamespace
        first = o.endpoint_identity(SimpleNamespace(url='https://user:secret@rpc.example/a?key=x'),'primary')
        second = o.endpoint_identity(SimpleNamespace(url='https://rpc.example/b'),'secondary')
        self.assertEqual(first,second)
        action = lambda:o.assert_endpoint_identities(dict(primary=first,secondary=second))
        with self.assertRaises(a.Gate) as caught: action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_endpoint_distinct')
        removed_probe(self,action,'old_owner_endpoint_distinct')
        o.assert_endpoint_identities(dict(primary=first,secondary=o.endpoint_identity(SimpleNamespace(url='https://other.example'),'secondary')))
        import manifest_exec as m
        value = dict(oldActivityReads=dict(primary=[]), oldOwnerIsolation=dict(reads=[],sourceSelection={}))
        with patch.object(m,'collect',side_effect=lambda *args:copy.deepcopy(value)):
            action = lambda:m.collect_pair(SimpleNamespace(url='https://rpc.example/a'),SimpleNamespace(url='https://rpc.example/b'),'0x123',{})
            with self.assertRaises(a.Gate) as caught: action()
            self.assertEqual(caught.exception.record['gate'],'old_owner_endpoint_distinct')
            removed_probe(self,action,'old_owner_endpoint_distinct')

    def test_review_low_registry_registered_exited(self):
        baseline = fixture_rpc(self.pin)
        counts = {}
        o.role_history(baseline,self.pin,u.REG,inventory()['Registry'],1,counts)
        self.assertEqual(counts[u.REG],dict(RoleGranted=15,RoleRevoked=0,RoleRegistered=36,RoleExited=0))
        role = CUSTOM_ROLE
        def event(kind,index):
            return dict(address=u.REG,topics=[a.keccak(kind),role,raw([int(o.OLD,16)])],data=raw([0,123]),
                        blockNumber=self.pin['stateBlock'],blockHash=BLOCK_HASH,transactionHash='0x'+'99'*32,transactionIndex='0x1',logIndex=hex(index))
        extra = [event(o.REGISTERED,100)]
        def rpc(method,params):
            result = baseline(method,params)
            if method == 'eth_getLogs' and a.qty(params[0]['toBlock']) >= a.qty(self.pin['stateBlock']):
                result += extra
            return result
        action = lambda:o.role_history(rpc,self.pin,u.REG,inventory()['Registry'],1)
        with self.assertRaises(a.Gate) as caught: action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_uncancelled_grants')
        removed_probe(self,action,'old_owner_uncancelled_grants')
        extra.append(event(o.EXITED,101))
        extra.reverse()  # RPC order must not determine cancellation.
        self.assertIn(role,action())
        # Exit for a different role cannot cancel OLD's registration.
        extra[0]['topics'][1] = a.ZERO32
        with self.assertRaises(a.Gate) as caught: action()
        self.assertEqual(caught.exception.record['gate'],'old_owner_uncancelled_grants')
        # Standard roles may be evidenced solely by registerRole history.
        def registered_only(method,params):
            result = baseline(method,params)
            if method == 'eth_getLogs':
                result = [row for row in result if row['topics'][0] == a.keccak(o.REGISTERED)]
            return result
        self.assertIn(inventory()['Registry']['roles'][1]['value'],
                      o.role_history(registered_only,self.pin,u.REG,inventory()['Registry'],1))

    def test_grants_cancellation_union_and_truncation(self):
        baseline = fixture_rpc(self.pin)
        role = inventory()['Registry']['roles'][1]['value']
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
        self.assertEqual(o.role_history(rpc,self.pin,u.REG,inventory()['Registry'],1),sorted([role,CUSTOM_ROLE,*o.NEVER_GRANTED[u.REG]]))
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
        expanded['xPNTsToken']['authorities'] = []
        targets = {name:[u.SP if name == 'SuperPaymaster' else FACTORY if name == 'xPNTsFactoryV2' else TOKEN] for name in m.NAMES}
        rpc = fixture_rpc(self.pin)
        with patch.object(o,'inventory_source',return_value=expanded) as source, patch.object(o,'audit',return_value=value) as audit, \
             patch.object(o,'negative_controls',return_value=report) as negatives, \
             patch.object(o,'post_upgrade_clones',return_value=dict(verified=True,inventory=inventory()['xPNTsToken'])) as clones:
            result = o.post_upgrade_check(rpc,self.pin,Path('/release-fixture'),targets,{t:'xPNTsTokenV2' for t in (TOKEN,*o.ROUND_CLONES)},value,fork=rpc.fork)
            self.assertEqual(source.call_args.kwargs['mode'],'release')
            self.assertIn('SuperPaymasterAdmin',source.call_args.kwargs['names'])
            self.assertEqual(result['negativeControls'],report)
            self.assertEqual(audit.call_args.args[1]['isolationExtraTargets'],targets)
            negatives.assert_called_once()
            self.assertEqual(set(clones.call_args.args[2]),{TOKEN,*o.ROUND_CLONES})
            for token in (TOKEN,*o.ROUND_CLONES):
                self.assertEqual(audit.call_args.args[2]['targetInventories'][token],inventory()['xPNTsToken'])

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
