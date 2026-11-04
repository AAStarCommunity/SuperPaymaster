"""Pinned-source authority discovery and replayable old-owner isolation reads."""
import json
import os
import subprocess
import tempfile
from pathlib import Path
from functools import lru_cache
import sp_upgrade_exec as u

a = u.a
OLD = '0x92a30ef64b0b750220b2b3bafe4f3121263d45b3'
NEW = '0xd6e95a852d68f99759bf47e77d84fcc8d6f93494'
OLD_TOKEN = '0x696a73701b104c6ccbbaaddd2216788ea08eab89'
NAMES = ('Registry', 'SuperPaymaster', 'APNTsCapped', 'TimelockController', 'GTokenStaking', 'GToken', 'xPNTsFactory', 'xPNTsToken', 'MySBT', 'PaymasterFactory')

# Existing Sepolia deployment config; other addresses come from pinned getters.
PAYMASTER_FACTORY = '0xa936f8e3d682b0ecf280e6f5c05ff4204ee87180'
ROLE_EVENT = 'RoleConfigured(bytes32,'+u.CONFIG_TYPE+',uint256)'


def inventory_source(release_tree=None, *, mode='deployed', rpc=None, pin=None, sources=None, names=NAMES):
    """The pin never uses a release layout, even when a deployed build is missing."""
    if mode == 'release':
        a.need('old_owner_release_tree', release_tree is not None, True)
        return extract(release_tree) if names == NAMES else extract(release_tree,names)
    a.need('old_owner_source_mode', mode, 'deployed')
    a.need('old_owner_deployed_sources', isinstance(sources, dict) and bool(sources), True)
    return deployed_inventory(rpc, pin, sources)


def extract(tree, names=NAMES):
    result = {}
    units = sorted((tree/'out/build-info').glob('*.json'))
    a.need('old_owner_extraction_build_info', bool(units), True)
    for path in units:
        data = json.loads(path.read_text())
        sources = data['output']['sources']
        nodes = {n['id']:(p, n) for p,s in sources.items() for n in s['ast']['nodes']
                 if n.get('nodeType') == 'ContractDefinition'}
        for source, root in nodes.values():
            name = root['name']
            if name not in names or root.get('contractKind') == 'interface':
                continue
            abi = a.raw_artifact(tree, name)['abi']
            signatures = {f['name']+'('+','.join(i['type'] for i in f['inputs'])+')':f
                          for f in abi if f['type'] == 'function'}
            entries = []
            for base in root['linearizedBaseContracts']:
                p, node = nodes[base]
                entries.extend((p,n) for n in node['nodes'])
            # Registry imports file-level ROLE_* constants; they are not base members.
            pending, visited = [source], set()
            while pending:
                p = pending.pop()
                if p in visited:
                    continue
                visited.add(p)
                for n in sources[p]['ast']['nodes']:
                    if n.get('nodeType') == 'ImportDirective':
                        pending.append(n['absolutePath'])
                    elif n.get('nodeType') == 'VariableDeclaration':
                        entries.append((p,n))
            groups = dict(roles=[], authorities=[], mappings=[])
            seen = set()
            for p,n in entries:
                label = n.get('name', '')
                kind = n.get('nodeType')
                typ = n.get('typeDescriptions', {}).get('typeString', '')
                category, sig = None, label+'()'
                if kind == 'VariableDeclaration' and n.get('constant') and typ == 'bytes32' and (label.endswith('ROLE') or label.startswith('ROLE_')):
                    category = 'roles'
                elif kind == 'VariableDeclaration' and n.get('stateVariable') and n.get('visibility') == 'public':
                    if typ in ('address', 'address payable') or typ.startswith('contract '):
                        category = 'authorities'
                    t = n.get('typeName', {})
                    if t.get('nodeType') == 'Mapping' and t['keyType'].get('name') == 'address' and t['valueType'].get('name') == 'bool':
                        category, sig = 'mappings', label+'(address)'
                elif kind == 'FunctionDefinition' and n.get('visibility') in ('public','external') and n.get('stateMutability') in ('view','pure') and not n['parameters']['parameters']:
                    returns = n['returnParameters']['parameters']
                    if len(returns) == 1 and (returns[0]['typeDescriptions']['typeString'] in ('address','address payable') or returns[0]['typeDescriptions']['typeString'].startswith('contract ')):
                        category = 'authorities'
                key = (category,p,n.get('src')) if category == 'roles' else (category,label)
                if category is None or key in seen:
                    continue
                seen.add(key)
                content = data['input']['sources'][p]['content'].encode()
                offset = int(n['src'].split(':')[0])
                row = dict(name=label, signature=sig, file=p, line=content[:offset].count(b'\n')+1)
                if category == 'roles':
                    value = n['value']
                    if value.get('nodeType') == 'FunctionCall' and value.get('expression', {}).get('name') == 'keccak256':
                        row['value'] = a.keccak(value['arguments'][0]['value'])
                    elif value.get('nodeType') == 'Literal':
                        row['value'] = '0x'+format(int(value['value'], 0), '064x')
                    else:
                        a.need('old_owner_role_expression_'+label, False, True)
                else:
                    a.need('old_owner_getter_abi_'+name+'_'+label, sig in signatures, True)
                    a.need('old_owner_getter_output_'+label, [v['type'] for v in signatures[sig]['outputs']], ['address' if category == 'authorities' else 'bool'])
                groups[category].append(row)
            for rows in groups.values():
                rows.sort(key=lambda x:(x['name'],x['file']))
            if name == 'Registry':
                events = [f for f in abi if f['type'] == 'event' and f['name'] == 'RoleConfigured']
                def abi_type(v):
                    return '('+','.join(abi_type(c) for c in v['components'])+')' if v['type'] == 'tuple' else v['type']
                a.need('old_owner_role_event_abi', len(events), 1)
                event = events[0]
                a.need('old_owner_role_event_signature', event['name']+'('+','.join(abi_type(v) for v in event['inputs'])+')', ROLE_EVENT)
                a.need('old_owner_role_event_indexed', [v['indexed'] for v in event['inputs']], [True, False, False])
                groups['roleEventTopic'] = a.keccak(ROLE_EVENT)
            groups['hasRole'] = 'hasRole(bytes32,address)' in signatures
            groups['roleStatus'] = 'hasRole' if groups['hasRole'] else 'ABI has no hasRole(bytes32,address)'
            groups['operatorOutputs'] = [v['type'] for v in signatures.get('operators(address)', {}).get('outputs', [])]
            a.need('old_owner_duplicate_source_'+name, result.get(name, groups), groups)
            result[name] = groups
    a.need('old_owner_extraction_contracts', sorted(result), sorted(names))
    for name in names:
        if result[name]['hasRole']:
            a.need('old_owner_extraction_roles_'+name, bool(result[name]['roles']), True)
    a.need('old_owner_extraction_authorities', all(result[n]['authorities'] for n in names if n in NAMES and n != 'TimelockController'), True)
    a.need('old_owner_extraction_mappings', all(result[n]['mappings'] for n in ('Registry','SuperPaymaster') if n in names), True)
    return result


def audit(rpc, pin, inventory, fork=None):
    block = pin['stateBlock']
    reads, fork_controls, histories = [], [], {}
    fork = fork or getattr(rpc,'fork',None)
    def probe(case):
        a.need('old_owner_control_verified', 'available' if fork else 'unverified', 'available')
        def recorded_fork(method,params):
            value = fork(method,params)
            stored_params = ['snapshot'] if method == 'evm_revert' else params
            stored_value = 'snapshot' if method == 'evm_snapshot' else value
            reads.append(dict(kind='fork',method=method,params=stored_params,result=stored_value))
            return value
        recorded_fork.local = getattr(fork,'local',False)
        value = fork_probe(recorded_fork,pin,case)
        fork_controls.append(value)
        return value
    def negative(gate, value):
        reads[-1]['negativeControl'] = dict(gate=gate,result=value if isinstance(value,str) else '0x'+format(value,'064x'))
    def call(target, sig, *args):
        raw = a.typed(rpc('eth_call', [dict(to=target, data=a.calldata(sig, *args)), block]), a.HEXDATA)
        reads.append(dict(kind='call', target=target, signature=sig, args=list(args), block=block, result=raw))
        return raw
    def words(target, sig, *args):
        return u.uints(call(target,sig,*args))
    def word(target, sig, *args):
        w = words(target,sig,*args)
        a.need('old_owner_word_shape', len(w), 1)
        return w[0]
    def addr(target,sig):
        return u.addr_word(word(target,sig))
    def storage(slot):
        raw = a.typed(rpc('eth_getStorageAt',[u.SAFE,slot,block]), a.HASH32)
        reads.append(dict(kind='storage', target=u.SAFE, slot=slot, block=block, result=raw))
        return u.addr_word(int(raw,16))
    def recorded(method, params):
        try:
            result = rpc(method, params)
        except a.Gate as fault:
            if method != 'eth_getLogs' or not getattr(fault,'log_range_limit',False):
                raise
            reads.append(dict(kind='rpc', method=method, params=params, rangeError=fault.record))
            raise
        reads.append(dict(kind='rpc', method=method, params=params, result=result))
        return result
    a.need('old_owner_audit_pin_start',recorded('eth_getBlockByNumber',[block,False])['hash'],pin['stateBlockHash'])
    targets = dict(Registry=u.REG, SuperPaymaster=u.SP, APNTsCapped=pin['capped'], TimelockController=u.TL)
    targets.update(GTokenStaking=addr(u.REG,'GTOKEN_STAKING()'),
                   MySBT=addr(u.REG,'MYSBT()'), xPNTsFactory=addr(u.SP,'xpntsFactory()'),
                   PaymasterFactory=PAYMASTER_FACTORY)
    targets['GToken'] = addr(targets['GTokenStaking'],'GTOKEN()')
    for name in ('GTokenStaking','GToken','xPNTsFactory','MySBT','PaymasterFactory'):
        a.need('old_owner_target_'+name, targets[name] != a.ZERO, True)
    control_holders = {u.SAFE,u.TL,u.SP,u.REG,u.DEPLOYER,a.APPROVER,a.EXECUTOR,NEW,OLD_TOKEN,pin['capped'],*pin['pauseList'],*targets.values()}
    control_holders.update(u.addr_array(call(targets['xPNTsFactory'],'getAllTokens()')))
    control_holders.discard(OLD)
    def role_owner(target,role,gate):
        raw = call(target,'getRoleConfig(bytes32)',role)
        cfg = u.config(raw)
        changed = u.uints(raw)
        changed[11] = int(OLD,16)
        negative(gate,'0x'+''.join(format(v,'064x') for v in changed))
        a.need(gate,cfg['owner'] != OLD,True)
    def role_control(name,target,role):
        values = [word(target,'hasRole(bytes32,address)',role,holder) for holder in sorted({u.SAFE,u.DEPLOYER,*pin['pauseList']})]
        if 1 in values:
            return
        case = pin.get('isolationControlCases',{}).get(target+':'+role)
        if case is None and name == 'TimelockController':
            case = dict(sender=u.TL,gate='old_owner_event_role_'+name,
                        transactions=[dict(target=target,signature='grantRole(bytes32,address)',args=[role,'$ACCOUNT'])],
                        getter=dict(target=target,signature='hasRole(bytes32,address)',args=[role,'$ACCOUNT']))
        a.need('old_owner_role_control_path','available' if case else 'unverified','available')
        a.need('old_owner_role_control_getter',case['getter'],dict(target=target,signature='hasRole(bytes32,address)',args=[role,'$ACCOUNT']))
        a.need('old_owner_role_control_gate',case['gate'],'old_owner_event_role_'+name)
        probe(case)
    def check_target(name, target):
        spec = inventory.get('targetInventories',{}).get(target,inventory[name])
        if spec['hasRole']:
            for role in spec['roles']:
                value = word(target,'hasRole(bytes32,address)',role['value'],OLD)
                gate = 'old_owner_role_'+name+'_'+role['name']
                negative(gate,1)
                a.need(gate,value,0)
                if name == 'Registry':
                    role_owner(target,role['value'],'old_owner_role_admin_'+role['name'])
        deployments = {r['target']:r['creationBlock'] for r in inventory.get('deployedSources',[])}
        creation = deployments.get(target,pin.get('isolationDeployments',{}).get(target))
        histories[target] = role_history(recorded,pin,target,spec,creation)
        for role in histories[target]:
            if spec['hasRole']:
                value = word(target,'hasRole(bytes32,address)',role,OLD)
                negative('old_owner_event_role_'+name,1)
                a.need('old_owner_event_role_'+name,value,0)
                role_control(name,target,role)
                if name == 'Registry':
                    role_owner(target,role,'old_owner_event_role_admin')
        for row in spec['authorities']:
            value = addr(target,row['signature'])
            gate = 'old_owner_authority_'+name+'_'+row['name']
            negative(gate,int(OLD,16))
            a.need(gate,value != OLD,True)
        for row in spec['mappings']:
            gate = 'old_owner_mapping_'+name+'_'+row['name']
            value = word(target,row['signature'],OLD)
            negative(gate,1)
            a.need(gate,value,0)
            values = [word(target,row['signature'],who) for who in sorted(control_holders)]
            if 1 not in values:
                case = pin.get('isolationControlCases',{}).get(target+':'+row['signature'])
                a.need('old_owner_mapping_control_path', 'available' if case else 'unverified','available')
                a.need('old_owner_mapping_control_case',isinstance(case,dict),True)
                a.need('old_owner_mapping_control_getter',case['getter'],dict(target=target,signature=row['signature'],args=['$ACCOUNT']))
                a.need('old_owner_mapping_control_gate',case['gate'],gate)
                probe(case)
    for name,target in targets.items():
        check_target(name,target)
    for name, group in pin.get('isolationExtraTargets',{}).items():
        for target in group:
            check_target(name,target)
    for name in ('GTokenStaking','GToken','xPNTsFactory','MySBT','PaymasterFactory'):
        getter = 'daoMultisig()' if name == 'MySBT' else 'owner()'
        a.need('old_owner_control_'+name, addr(targets[name],getter), pin.get('isolationExpectedOwners',{}).get(targets[name],u.DEPLOYER))
    def canonical_pin():
        canonical = recorded('eth_getBlockByNumber',[block,False])
        a.need('old_owner_role_pin_canonical', canonical['hash'], pin['stateBlockHash'])
        a.need('old_owner_role_pin_number', canonical['number'], block)
    canonical_pin()
    for source in inventory.get('deployedSources',[]):
        if source['contract'] == 'Registry':
            a.need('old_owner_registry_creation_binding',pin['registryCreation'],source['creationBlock'])
    topic = inventory['Registry']['roleEventTopic']
    logs = a.schedule_logs(recorded, dict(address=u.REG, fromBlock=hex(pin['registryCreation']),
                                         toBlock=block, topics=[topic]))
    roles, canonical_blocks = set(), {}
    for log in logs:
        a.need('old_owner_role_log_address', log.get('address'), u.REG)
        a.need('old_owner_role_log_removed', log.get('removed',False), False)
        topics = log.get('topics',[])
        a.need('old_owner_role_log_topics', len(topics), 2)
        a.need('old_owner_role_log_topic', topics[0], topic)
        role = a.typed(topics[1],a.HASH32)
        number = a.typed(log.get('blockNumber'),a.QTY)
        a.need('old_owner_role_log_range', pin['registryCreation'] <= a.qty(number) <= a.qty(block), True)
        if number not in canonical_blocks:
            canonical_blocks[number] = recorded('eth_getBlockByNumber',[number,False])
        canonical = canonical_blocks[number]
        a.need('old_owner_role_log_canonical', a.typed(log.get('blockHash'),a.HASH32), canonical['hash'])
        a.need('old_owner_role_log_block', canonical['number'], number)
        roles.add(role)
    canonical_pin()
    standard = {r['value'] for r in inventory['Registry']['roles']}
    a.need('old_owner_role_extraction_empty', bool(roles | set(histories[u.REG])) and standard <= roles | set(histories[u.REG]), True)
    for role in sorted(roles-standard):
        value = word(u.REG,'hasRole(bytes32,address)',role,OLD)
        negative('old_owner_role_Registry_'+role,1)
        a.need('old_owner_role_Registry_'+role,value,0)
        role_owner(u.REG,role,'old_owner_role_admin_'+role)
        role_control('Registry',u.REG,role)
    proposer = next((r['value'] for r in inventory['TimelockController']['roles'] if r['name'] == 'PROPOSER_ROLE'), None)
    a.need('old_owner_control_role_extracted', proposer is not None, True)
    a.need('old_owner_control_authority', addr(u.SP,'owner()'), pin.get('isolationExpectedOwners',{}).get(u.SP,u.DEPLOYER))
    value = words(u.REG,'getUserRoles(address)',OLD)
    negative('old_owner_registry_user_roles','0x'+''.join(format(v,'064x') for v in (32,1,99)))
    a.need('old_owner_registry_user_roles',value,[32,0])
    holder_roles = words(u.REG,'getUserRoles(address)',u.DEPLOYER)
    a.need('old_owner_control_registration', len(holder_roles) > 2 and holder_roles[0] == 32 and holder_roles[1] == len(holder_roles)-2, True)
    operator_types = inventory['SuperPaymaster']['operatorOutputs']
    a.need('old_owner_operator_abi', operator_types, ['uint128','bool','bool','address','uint32','uint48','address','uint256','uint256'])
    value = words(u.SP,'operators(address)',OLD)
    negative('old_owner_operator','0x'+format(1,'064x')+'0'*64*(len(operator_types)-1))
    a.need('old_owner_operator',value,[0]*len(operator_types))
    tokens = {pin['capped'], OLD_TOKEN, targets['GToken']}
    xpnts = set(u.addr_array(call(targets['xPNTsFactory'],'getAllTokens()'))) | set(pin.get('isolationLegacyTokens',[]))
    configured = False
    for who in sorted(set(pin['pauseList'])):
        w = words(u.SP,'operators(address)',who)
        a.need('old_owner_operator_shape',len(w),len(operator_types))
        configured |= w[1] == 1
        token = u.addr_word(w[3])
        changed = list(w)
        changed[6] = int(OLD,16)
        negative('old_owner_operator_treasury_'+who,'0x'+''.join(format(v,'064x') for v in changed))
        a.need('old_owner_operator_treasury_'+who, u.addr_word(w[6]) != OLD, True)
        if token != a.ZERO:
            xpnts.add(token)
    a.need('old_owner_control_operator', configured, True)
    a.need('old_owner_extraction_xpnts', bool(xpnts), True)
    for token in sorted(xpnts):
        a.need('old_owner_xpnts_nonzero', token != a.ZERO, True)
        check_target('xPNTsToken',token)
        community = addr(token,'communityOwner()')
        a.need('old_owner_control_xPNTsToken_owner', community != a.ZERO, True)
        token_factory = addr(token,'FACTORY()')
        a.need('old_owner_control_xPNTsToken', u.addr_word(word(token_factory,'communityToToken(address)',community)), token)
    tokens.update(xpnts)
    mapping_controls = []
    for name in ('Registry','SuperPaymaster'):
        for row in inventory[name]['mappings']:
            for who in sorted({u.DEPLOYER,*pin['pauseList']}):
                mapping_controls.append(word(targets[name],row['signature'],who))
    a.need('old_owner_control_mapping', 1 in mapping_controls or fork is not None, True)
    principals = sorted({u.SAFE,u.TL,u.SP,u.REG,u.DEPLOYER,a.APPROVER,a.EXECUTOR,NEW})
    reverse, controls = [], []
    for token in sorted(tokens):
        for who in principals:
            value = word(token,'allowance(address,address)',who,OLD)
            gate = 'old_owner_allowance_'+token+'_'+who
            negative(gate,1)
            a.need(gate,value,0)
        live = [word(token,'allowance(address,address)',holder,spender) for holder in principals for spender in (u.SP,u.REG)]
        if not any(live):
            probe(dict(sender=u.SAFE,gate='old_owner_allowance_'+token+'_'+u.SAFE,
                       transactions=[dict(target=token,signature='approve(address,uint256)',args=['$ACCOUNT',1])],
                       getter=dict(target=token,signature='allowance(address,address)',args=[u.SAFE,'$ACCOUNT'])))
        for spender in (u.SP,u.REG):
            reverse.append(dict(token=token,spender=spender,value=word(token,'allowance(address,address)',OLD,spender)))
            for holder in principals:
                controls.append(word(token,'allowance(address,address)',holder,spender))
    a.need('old_owner_control_allowance', any(v > 0 for v in controls) or fork is not None, True)
    owners = u.addr_array(call(u.SAFE,'getOwners()'))
    negative('old_owner_safe_owners','0x'+''.join(format(v,'064x') for v in [32,len(owners)+1,*[int(who,16) for who in owners],int(OLD,16)]))
    a.need('old_owner_safe_owners', OLD not in owners, True)
    a.need('old_owner_control_safe_owners', a.APPROVER in owners and a.EXECUTOR in owners, True)
    a.need('old_owner_control_safe', word(u.SAFE,'isOwner(address)',a.APPROVER), 1)
    value = word(u.SAFE,'isModuleEnabled(address)',OLD)
    negative('old_owner_safe_modules',1)
    a.need('old_owner_safe_modules',value,0)
    for label in ('guard','fallback'):
        slot = a.keccak('guard_manager.guard.address' if label == 'guard' else 'fallback_manager.handler.address')
        value = storage(slot)
        negative('old_owner_safe_'+label,int(OLD,16))
        a.need('old_owner_safe_'+label, value != OLD, True)
        if label == 'fallback':
            a.need('old_owner_fallback_canonical',value,FALLBACK_HANDLER)
        else:
            probe(dict(sender=u.SAFE,gate='old_owner_safe_guard',guard=True,
                       transactions=[dict(target=u.SAFE,signature='setGuard(address)',args=['$ACCOUNT'])],
                       getter=dict(target=u.SAFE,slot=slot)))
    modules = words(u.SAFE,'getModulesPaginated(address,uint256)','0x'+'0'*39+'1',100)
    a.need('old_owner_module_page',modules,[64,1,0])
    probe(dict(sender=u.SAFE,gate='old_owner_safe_modules',module=True,
               transactions=[dict(target=u.SAFE,signature='enableModule(address)',args=['$ACCOUNT'])],
               getter=dict(target=u.SAFE,signature='isModuleEnabled(address)',args=['$ACCOUNT'])))
    canonical_pin()
    roles.update(histories.get(u.REG,[]))
    return dict(safeFallback=dict(address=FALLBACK_HANDLER,provenance='docs/release/a3a-precheck-v4/snapshot.json; DSR canonical deployment-list confirmation required'), forkControls=fork_controls, roleHistory=histories, inventory=inventory, targets=targets, configuredRoles=sorted(roles), xpnts=sorted(xpnts), tokens=sorted(tokens), reverseAllowances=reverse, reads=reads)


def validate(section, pin, inventory):
    a.need('old_owner_evidence_present', isinstance(section,dict), True)
    a.need('old_owner_inventory',section.get('inventory'),inventory)
    endpoints = section.get('endpointResults', {})
    a.need('old_owner_endpoints', sorted(endpoints), ['primary','secondary'])
    expected = {k:v for k,v in section.items() if k != 'endpointResults'}
    for endpoint, transcript in endpoints.items():
        index = 0
        def replay(method, params):
            nonlocal index
            a.need('old_owner_replay_complete', index < len(transcript), True)
            row = transcript[index]
            index += 1
            if row['kind'] == 'call':
                want = ['eth_call',[dict(to=row['target'],data=a.calldata(row['signature'],*row['args'])),row['block']]]
            elif row['kind'] in ('rpc','fork'):
                want = [row['method'],row['params']]
            else:
                want = ['eth_getStorageAt',[row['target'],row['slot'],row['block']]]
            a.need('old_owner_replay_query', [method,params], want)
            if 'rangeError' in row:
                error = row['rangeError']
                fault = a.Gate(error['gate'],error['observed'],error['expected'])
                fault.log_range_limit = True
                raise fault
            return row['result']
        replay.local = True
        actual = audit(replay,pin,inventory,fork=replay)
        a.need('old_owner_replay_unused',index,len(transcript))
        a.need('old_owner_replay_transcript',actual['reads'],transcript)
        a.need('old_owner_revalidated_'+endpoint,actual,expected)


@lru_cache(maxsize=32)
def deployed_build(commit, name):
    """Archive exact local objects, including submodules; never install dependencies."""
    a.need('old_owner_source_commit', len(commit) == 40 and all(c in '0123456789abcdef' for c in commit), True)
    with tempfile.TemporaryDirectory(prefix='old-owner-source-') as directory:
        tree = Path(directory)/'tree'
        a.archive_commit(u.ROOT, commit, tree)
        env = {k: os.environ[k] for k in ('HOME','PATH','TMPDIR','USER','LOGNAME','LANG','LC_ALL','SVM_HOME') if k in os.environ}
        env['FOUNDRY_PROFILE'] = 'default'
        try:
            version = subprocess.run([str(a.REBUILD_FORGE),'--version'], capture_output=True, text=True, check=True).stdout.strip()
            built = subprocess.run([str(a.REBUILD_FORGE),'build','--offline','--ast','--build-info'], cwd=tree, env=env, capture_output=True)
        except (OSError, subprocess.CalledProcessError) as error:
            raise a.Gate('old_owner_deployed_build', type(error).__name__, 'rebuildable deployed source; DSR decision required') from None
        a.need('old_owner_deployed_build', built.returncode, 0)
        art = a.raw_artifact(tree,name)
        metadata = art.get('metadata', {})
        if isinstance(metadata,str):
            metadata = json.loads(metadata)
        a.need('old_owner_compiler_settings', bool(metadata.get('settings')) and bool(metadata.get('compiler')), True)
        return dict(inventory=extract(tree,(name,))[name], artifact=art,
                    compiler=metadata['compiler'], settings=metadata['settings'], forge=version)


def discover_targets(rpc, pin):
    block = pin['stateBlock']
    def address(target, sig):
        return u.addr_word(a.word(rpc,target,sig,block=block))
    targets = dict(Registry=[u.REG],SuperPaymaster=[u.SP],APNTsCapped=[pin['capped']],TimelockController=[u.TL],
                   GTokenStaking=[address(u.REG,'GTOKEN_STAKING()')],MySBT=[address(u.REG,'MYSBT()')],
                   xPNTsFactory=[address(u.SP,'xpntsFactory()')],PaymasterFactory=[PAYMASTER_FACTORY])
    targets['GToken'] = [address(targets['GTokenStaking'][0],'GTOKEN()')]
    tokens = set(u.addr_array(a.call(rpc,targets['xPNTsFactory'][0],'getAllTokens()',block=block)))
    for who in pin['pauseList']:
        values = u.uints(a.call(rpc,u.SP,'operators(address)',who,block=block))
        a.need('old_owner_discovery_operator_shape',len(values),9)
        token = u.addr_word(values[3])
        if token != a.ZERO:
            tokens.add(token)
    a.need('old_owner_discovery_tokens',bool(tokens),True)
    targets['xPNTsToken'] = sorted(tokens)
    return targets


def runtime_parity(code, artifact):
    deployed = artifact['deployedBytecode']
    actual = bytearray.fromhex(a.typed(code,a.HEXDATA)[2:])
    expected = bytearray.fromhex(a.typed(deployed['object'],a.HEXDATA)[2:])
    a.need('old_owner_runtime_length',len(actual),len(expected))
    a.need('old_owner_runtime_nonempty',bool(actual),True)
    occupied, ranges = set(), []
    for entries in deployed.get('immutableReferences',{}).values():
        for entry in entries:
            start, size = entry['start'], entry['length']
            a.need('old_owner_immutable_range', type(start) is int and size == 32 and 0 <= start <= len(expected)-size, True)
            span = set(range(start,start+size))
            a.need('old_owner_immutable_overlap',bool(span & occupied),False)
            occupied.update(span)
            actual[start:start+size] = expected[start:start+size] = bytes(size)
            ranges.append(dict(start=start,length=size))
    a.need('old_owner_runtime_parity',actual == expected,True)
    return dict(equal=True,immutableRanges=ranges,runtimeKeccak=a.keccak(code))


def deployed_inventory(rpc, pin, sources):
    canonical = rpc('eth_getBlockByNumber',[pin['stateBlock'],False])
    a.need('old_owner_source_pin',canonical['hash'],pin['stateBlockHash'])
    a.need('old_owner_source_pin_number',canonical['number'],pin['stateBlock'])
    targets = discover_targets(rpc,pin)
    wanted = {target for group in targets.values() for target in group}
    a.need('old_owner_source_targets',sorted(sources),sorted(wanted))
    result, mapping, variants = {}, [], {}
    block = pin['stateBlock']
    for name, group in targets.items():
        for target in group:
            spec = sources[target]
            a.exact_keys('old_owner_source_fields',spec,('contract','implementation','commit','creationBlock'))
            a.need('old_owner_source_name',spec['contract'],name)
            creation = spec['creationBlock']
            a.need('old_owner_creation_range',type(creation) is int and 0 < creation <= a.qty(block),True)
            # Verify the supplied deployment boundary instead of trusting a late start.
            a.need('old_owner_creation_before',rpc('eth_getCode',[target,hex(creation-1)]),'0x')
            a.need('old_owner_creation_at',rpc('eth_getCode',[target,hex(creation)]) != '0x',True)
            code = a.typed(rpc('eth_getCode',[target,block]),a.HEXDATA)
            slot = hex(int(a.keccak('eip1967.proxy.implementation'),16)-1)
            implementation = u.addr_word(int(a.typed(rpc('eth_getStorageAt',[target,slot,block]),a.HASH32),16))
            if code.startswith('0x363d3d373d3d3d363d73') and code.endswith('5af43d82803e903d91602b57fd5bf3') and len(code) == 92:
                implementation = '0x'+code[22:62]
            if implementation == a.ZERO:
                implementation = target
            a.need('old_owner_implementation',spec['implementation'],implementation)
            built = deployed_build(spec['commit'],name)
            parity = runtime_parity(rpc('eth_getCode',[implementation,block]),built['artifact'])
            variants[target] = built['inventory']
            result.setdefault(name,built['inventory'])
            mapping.append(dict(contract=name,target=target,implementation=implementation,commit=spec['commit'],
                                creationBlock=creation,compiler=built['compiler'],settings=built['settings'],forge=built['forge'],parity=parity))
    a.need('old_owner_source_pin_after',rpc('eth_getBlockByNumber',[block,False]),canonical)
    result['deployedSources'] = mapping
    result['targetInventories'] = variants
    return result


def collect_deployed(rpc, pin, sources, fork=None):
    reads = []
    def recorded(method, params):
        value = rpc(method,params)
        reads.append(dict(method=method,params=params,result=value))
        return value
    inventory = inventory_source(rpc=recorded,pin=pin,sources=sources)
    section = audit(rpc,pin,inventory,fork=fork)
    section['sourceReads'] = reads
    section['sourceSelection'] = sources
    return section


def validate_deployed(section, pin, sources):
    a.need('old_owner_evidence_present',isinstance(section,dict),True)
    a.need('old_owner_source_selection',section.get('sourceSelection'),sources)
    rows = iter(section.get('sourceReads',[]))
    def replay(method, params):
        row = next(rows,None)
        a.need('old_owner_source_replay_present',row is not None,True)
        a.need('old_owner_source_replay_query',[row['method'],row['params']],[method,params])
        return row['result']
    inventory = inventory_source(rpc=replay,pin=pin,sources=sources)
    a.need('old_owner_source_replay_unused',next(rows,None),None)
    identities = section.get('endpointIdentities',{})
    a.need('old_owner_endpoint_identities',sorted(identities),['primary','secondary'])
    for identity in identities.values():
        a.typed(identity,a.HASH32)
    clean = {k:v for k,v in section.items() if k not in ('sourceReads','sourceSelection','endpointIdentities')}
    validate(clean,pin,inventory)


def post_upgrade_check(rpc, pin, release_tree, release_targets, token_kinds, pre_upgrade, fork=None):
    """M2.5 hook; all manifest release contracts and discovered token kinds are explicit."""
    import copy
    import manifest_exec as manifest
    a.typed(pin['stateBlock'],a.QTY)
    a.need('old_owner_post_targets',sorted(release_targets),sorted(manifest.NAMES))
    for group in release_targets.values():
        a.need('old_owner_post_target_nonempty',isinstance(group,list) and bool(group),True)
        for target in group:
            a.typed(target,a.ADDRESS_RX)
            a.need('old_owner_post_target_nonzero',target != a.ZERO,True)
    inventory = inventory_source(release_tree,mode='release',names=tuple(sorted(set(NAMES) | set(manifest.NAMES))))
    # Every extraction above is release source, including delegated getter surfaces.
    def merge(core, extension):
        spec = copy.deepcopy(inventory[core])
        for group in ('roles','authorities','mappings'):
            rows = {r['signature']:r for r in spec[group]}
            rows.update({r['signature']:r for r in inventory[extension][group]})
            spec[group] = list(rows.values())
        return spec
    inventory['SuperPaymaster'] = merge('SuperPaymaster','SuperPaymasterAdmin')
    current = discover_targets(rpc,pin)
    a.need('old_owner_post_factory',current['xPNTsFactory'],release_targets['xPNTsFactoryV2'])
    a.need('old_owner_post_legacy_targets',sorted(pre_upgrade['targets']),sorted(n for n in NAMES if n != 'xPNTsToken'))
    a.need('old_owner_post_token_kinds',sorted(token_kinds),sorted(set(current['xPNTsToken']) | set(pre_upgrade['xpnts'])))
    inventory['targetInventories'] = {current['xPNTsFactory'][0]:inventory['xPNTsFactoryV2']}
    for token,kind in token_kinds.items():
        a.need('old_owner_post_token_kind',kind in ('xPNTsToken','xPNTsTokenV2'),True)
        inventory['targetInventories'][token] = merge('xPNTsTokenV2','xPNTsTokenV2Ext') if kind == 'xPNTsTokenV2' else inventory[kind]
    post = copy.deepcopy(pin)
    post['isolationExtraTargets'] = copy.deepcopy(release_targets)
    for name,target in pre_upgrade['targets'].items():
        if target not in current.get(name,[]):
            post['isolationExtraTargets'].setdefault(name,[]).append(target)
    post['isolationLegacyTokens'] = pre_upgrade['xpnts']
    section = audit(rpc,post,inventory,fork=fork)
    section['negativeControls'] = negative_controls(section,post,inventory)
    return section


GRANTED = 'RoleGranted(bytes32,address,address)'
REVOKED = 'RoleRevoked(bytes32,address,address)'
CONTROL = '0x00000000000000000000000000000000000c0170'
FALLBACK_HANDLER = '0xfd0732dc9e303f09fcef3a7388ad10a83459ec99'


def role_history(rpc, pin, target, spec, creation):
    """Bounded history, canonical event identities, and independent OLD filter."""
    start, stop = creation, a.qty(pin['stateBlock'])
    a.need('old_owner_history_range',type(start) is int and 0 < start <= stop,True)
    topics = [a.keccak(GRANTED),a.keccak(REVOKED)]
    def fetch(query):
        def bounded(method, params):
            result = rpc(method,params)
            if method == 'eth_getLogs':
                a.need('old_owner_log_array',isinstance(result,list),True)
                if len(result) >= 1000:
                    fault = a.Gate('old_owner_log_limit',len(result),'< 1000; bisect')
                    fault.log_range_limit = True
                    raise fault
            return result
        logs = a.schedule_logs(bounded,query)
        # Detect inconsistent pagination / silent truncation using a disjoint range cover.
        if start < stop:
            middle = (start+stop)//2
            parts = a.schedule_logs(bounded,dict(query,toBlock=hex(middle))) + a.schedule_logs(bounded,dict(query,fromBlock=hex(middle+1)))
            a.need('old_owner_log_partition',sorted(logs,key=lambda x:json.dumps(x,sort_keys=True)),sorted(parts,key=lambda x:json.dumps(x,sort_keys=True)))
        return logs
    query = dict(address=target,fromBlock=hex(start),toBlock=pin['stateBlock'],topics=[topics])
    logs = fetch(query)
    old_logs = fetch(dict(query,topics=[topics,None,'0x'+OLD[2:].zfill(64)]))
    canonical, identities = {}, set()
    for log in logs+old_logs:
        a.need('old_owner_history_address',log.get('address'),target)
        a.need('old_owner_history_removed',log.get('removed',False),False)
        ts = log.get('topics',[])
        a.need('old_owner_history_topics',len(ts),4)
        a.need('old_owner_history_signature',ts[0] in topics,True)
        for topic in ts[1:]:
            a.typed(topic,a.HASH32)
        for topic in ts[2:]:
            u.addr_word(int(topic,16))
        number = a.qty(a.typed(log.get('blockNumber'),a.QTY))
        a.need('old_owner_history_log_range',start <= number <= stop,True)
        if number not in canonical:
            canonical[number] = rpc('eth_getBlockByNumber',[hex(number),False])
        a.need('old_owner_history_canonical',log['blockHash'],canonical[number]['hash'])
        a.need('old_owner_history_number',canonical[number]['number'],hex(number))
        a.typed(log.get('transactionHash'),a.HASH32)
        a.typed(log.get('transactionIndex'),a.QTY)
        a.typed(log.get('logIndex'),a.QTY)
    for log in logs:
        identity = (log['blockHash'],log['transactionHash'],log['logIndex'])
        a.need('old_owner_history_duplicate',identity not in identities,True)
        identities.add(identity)
    expected_old = [l for l in logs if u.addr_word(int(l['topics'][2],16)) == OLD]
    a.need('old_owner_history_old_filter',old_logs,expected_old)
    standard = {r['value'] for r in spec['roles']}
    roles = {l['topics'][1] for l in logs}
    a.need('old_owner_history_positive',not spec['hasRole'] or standard <= roles,True)
    active = set()
    for log in sorted(old_logs,key=lambda l:(a.qty(l['blockNumber']),a.qty(l['transactionIndex']),a.qty(l['logIndex']))):
        if log['topics'][0] == topics[0]:
            active.add(log['topics'][1])
        else:
            active.discard(log['topics'][1])
    a.need('old_owner_uncancelled_grants',sorted(active),[])
    return sorted(roles | standard)


def absent(raw, gate):
    raw = a.typed(raw,a.HASH32,gate='old_owner_live_return_shape')
    a.need(gate,int(raw,16),0)
    return raw


def fork_probe(rpc, pin, case):
    """Execute identical setter/getter paths for CONTROL and OLD, restoring each trial."""
    a.need('old_owner_fork_local',getattr(rpc,'local',False),True)
    a.need('old_owner_fork_pin',rpc('eth_getBlockByNumber',[pin['stateBlock'],False])['hash'],pin['stateBlockHash'])
    a.need('old_owner_fork_head',rpc('eth_blockNumber',[]),pin['stateBlock'])
    results = []
    for who in (CONTROL,OLD):
        snapshot = rpc('evm_snapshot',[])
        sender = case['sender']
        try:
            rpc('anvil_impersonateAccount',[sender])
            rpc('anvil_setBalance',[sender,hex(10**18)])
            if case.get('guard'):
                # Safe checks IERC165 on the supplied guard. Only fork code is changed.
                rpc('anvil_setCode',[who,'0x600160005260206000f3'])
            for tx in case['transactions']:
                args = [arg.replace('$ACCOUNT',who) if isinstance(arg,str) else arg for arg in tx['args']]
                a.receipt(rpc,dict(to=tx['target'],data=a.calldata(tx['signature'],*args),gas=hex(3000000),**{'from':sender}))
            getter = case['getter']
            if 'slot' in getter:
                raw = rpc('eth_getStorageAt',[getter['target'],getter['slot'],'latest'])
                a.typed(raw,a.HASH32)
                value = u.addr_word(int(raw,16))
                a.need('old_owner_fork_readback',value,who)
                normalized = '0x'+format(int(value == OLD),'064x')
            else:
                args = [who if arg == '$ACCOUNT' else arg for arg in getter['args']]
                raw = rpc('eth_call',[dict(to=getter['target'],data=a.calldata(getter['signature'],*args)),'latest'])
                a.typed(raw,a.HASH32)
                a.need('old_owner_fork_positive',int(raw,16) > 0,True)
                normalized = raw
            if case.get('module'):
                page = rpc('eth_call',[dict(to=u.SAFE,data=a.calldata('getModulesPaginated(address,uint256)','0x'+'0'*39+'1',100)),'latest'])
                words = u.uints(page)
                a.need('old_owner_fork_module_page',words,[64,1,1,int(who,16)])
            stopped = False
            if who == OLD:
                try:
                    absent(normalized,case['gate'])
                except a.Gate as error:
                    a.need('old_owner_fork_stop_gate',error.record['gate'],case['gate'])
                    stopped = True
                a.need('old_owner_fork_negative',stopped,True)
            results.append(dict(account=who,raw=raw,stopped=stopped))
        finally:
            rpc('anvil_stopImpersonatingAccount',[sender])
            a.need('old_owner_fork_restore',rpc('evm_revert',[snapshot]),True)
    return dict(case=case,results=results,status='verified')


def abi_signature(entry):
    def typ(item):
        if item['type'].startswith('tuple'):
            return '('+','.join(typ(c) for c in item['components'])+')'+item['type'][5:]
        return item['type']
    return entry['name']+'('+','.join(typ(i) for i in entry['inputs'])+')'


def signature_catalogue(tree):
    signatures = {'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)',
                  'approveHash(bytes32)', 'setBlsAggregator(address)'}
    for path in (tree/'out').glob('*/*.json'):
        for entry in json.loads(path.read_text()).get('abi',[]):
            if entry['type'] == 'function':
                signatures.add(abi_signature(entry))
    return sorted(signatures)


def assert_manifest_calldata(steps, signatures):
    catalogue = {}
    for sig in signatures:
        key = a.keccak(sig)[:10]
        a.need('old_owner_selector_collision',catalogue.get(key,sig),sig)
        catalogue[key] = sig
    decoded = []
    def inspect(data, signature=None, depth=0):
        a.need('old_owner_calldata_depth',depth <= 32,True)
        a.typed(data,a.HEXDATA)
        # Also catches packed addresses and opaque bytes, independently of ABI types.
        a.need('old_owner_calldata_bytes',OLD[2:] not in data[2:].lower(),True)
        if data == '0x':
            return []
        sig = signature or catalogue.get(data[:10])
        a.need('old_owner_calldata_abi',sig is not None,True)
        if sig.endswith('()'):
            a.need('old_owner_calldata_empty_args',len(data),10)
            values = []
        else:
            envelope = json.loads(a.cast('decode-calldata','--json',sig,data))
            a.need('old_owner_calldata_decode',envelope.get('success'),True)
            values = envelope['data']
        def visit(value):
            if isinstance(value,list):
                for child in value: visit(child)
            elif isinstance(value,str):
                a.need('old_owner_calldata_argument',OLD[2:] not in value.lower(),True)
                if value.startswith('0x') and value[:10] in catalogue:
                    inspect(value,depth=depth+1)
        visit(values)
        # These bytes are calls, not opaque signatures/proofs; unknown selectors stop.
        payload_index = 2 if sig.startswith(('execTransaction(', 'schedule(', 'execute(', 'scheduleBatch(', 'executeBatch(')) else 1 if sig.startswith('upgradeToAndCall(') else 0 if sig.startswith('multicall(bytes[])') else None
        if payload_index is not None:
            payload = values[payload_index]
            for child in payload if isinstance(payload,list) else [payload]:
                inspect(child,depth=depth+1)
        decoded.append(dict(signature=sig,arguments=values))
        return values
    for step in steps:
        for tx in [step['tx'],*step.get('variants',{}).values()]:
            if tx.get('to') is None:
                ctor = step.get('constructor')
                a.need('old_owner_constructor_abi',isinstance(ctor,dict),True)
                a.need('old_owner_constructor_prefix',tx['data'].startswith(ctor['bytecode']),True)
                tail = tx['data'][len(ctor['bytecode']):]
                inspect(a.keccak(ctor['signature'])[:10]+tail,ctor['signature'])
            else:
                inspect(tx['data'])
    return decoded


def local_control_fork():
    """Opt-in hydrated local engine only. No upstream RPC is started by this module."""
    from urllib.parse import urlsplit
    url = os.environ.get('OLD_OWNER_CONTROL_RPC')
    if not url:
        return None
    a.need('old_owner_control_local_url',urlsplit(url).hostname in ('localhost','127.0.0.1','::1'),True)
    a.need('old_owner_control_engine',(a.ENGINE/'anvil').is_file(),True)
    return a.RPC(url,local=True)


def endpoint_identity(rpc, label):
    """Hash only the public origin and label; never retain credentials, paths or queries."""
    from urllib.parse import urlsplit
    parsed = urlsplit(getattr(rpc,'url',''))
    return a.keccak(label+'|'+str(parsed.scheme)+'|'+str(parsed.hostname)+'|'+str(parsed.port))


def negative_controls(section, pin, inventory):
    """Replay each inventoried exclusion with one forbidden result; never mutate live state."""
    results = []
    for injected, row in enumerate(section['reads']):
        control = row.get('negativeControl')
        if control is None:
            continue
        cursor = 0
        def replay(method,params):
            nonlocal cursor
            a.need('old_owner_negative_transcript',cursor < len(section['reads']),True)
            entry = section['reads'][cursor]
            index = cursor
            cursor += 1
            if entry['kind'] == 'call':
                expected = ['eth_call',[dict(to=entry['target'],data=a.calldata(entry['signature'],*entry['args'])),entry['block']]]
            elif entry['kind'] in ('rpc','fork'):
                expected = [entry['method'],entry['params']]
            else:
                expected = ['eth_getStorageAt',[entry['target'],entry['slot'],entry['block']]]
            a.need('old_owner_negative_query',[method,params],expected)
            if 'rangeError' in entry:
                error = entry['rangeError']
                fault = a.Gate(error['gate'],error['observed'],error['expected'])
                fault.log_range_limit = True
                raise fault
            return control['result'] if index == injected else entry['result']
        replay.local = True
        stopped = None
        try:
            audit(replay,pin,inventory,fork=replay)
        except a.Gate as error:
            stopped = error.record['gate']
        a.need('old_owner_release_negative_control',stopped,control['gate'])
        results.append(dict(read=injected,gate=stopped,status='STOP'))
    a.need('old_owner_release_negative_nonempty',bool(results),True)
    return results
