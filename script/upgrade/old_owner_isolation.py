"""Pinned-source authority discovery and replayable old-owner isolation reads."""
import json
import sp_upgrade_exec as u

a = u.a
OLD = '0x92a30ef64b0b750220b2b3bafe4f3121263d45b3'
NEW = '0xd6e95a852d68f99759bf47e77d84fcc8d6f93494'
OLD_TOKEN = '0x696a73701b104c6ccbbaaddd2216788ea08eab89'
NAMES = ('Registry', 'SuperPaymaster', 'APNTsCapped', 'TimelockController', 'GTokenStaking', 'GToken', 'xPNTsFactory', 'xPNTsToken', 'MySBT', 'PaymasterFactory')

# Existing Sepolia deployment config; other addresses come from pinned getters.
PAYMASTER_FACTORY = '0xa936f8e3d682b0ecf280e6f5c05ff4204ee87180'
ROLE_EVENT = 'RoleConfigured(bytes32,'+u.CONFIG_TYPE+',uint256)'


def inventory_source(release_tree):
    """DSR seam: retain the existing release-source selection."""
    return release_tree


def extract(tree):
    tree = inventory_source(tree)
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
            if name not in NAMES or root.get('contractKind') == 'interface':
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
    a.need('old_owner_extraction_contracts', sorted(result), sorted(NAMES))
    for name in NAMES:
        if result[name]['hasRole']:
            a.need('old_owner_extraction_roles_'+name, bool(result[name]['roles']), True)
    a.need('old_owner_extraction_authorities', all(result[n]['authorities'] for n in NAMES if n != 'TimelockController'), True)
    a.need('old_owner_extraction_mappings', all(result[n]['mappings'] for n in ('Registry','SuperPaymaster')), True)
    return result


def audit(rpc, pin, inventory):
    block = pin['stateBlock']
    reads = []
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
    targets = dict(Registry=u.REG, SuperPaymaster=u.SP, APNTsCapped=pin['capped'], TimelockController=u.TL)
    targets.update(GTokenStaking=addr(u.REG,'GTOKEN_STAKING()'),
                   MySBT=addr(u.REG,'MYSBT()'), xPNTsFactory=addr(u.SP,'xpntsFactory()'),
                   PaymasterFactory=PAYMASTER_FACTORY)
    targets['GToken'] = addr(targets['GTokenStaking'],'GTOKEN()')
    for name in ('GTokenStaking','GToken','xPNTsFactory','MySBT','PaymasterFactory'):
        a.need('old_owner_target_'+name, targets[name] != a.ZERO, True)
    def check_target(name, target):
        spec = inventory[name]
        if spec['hasRole']:
            for role in spec['roles']:
                a.need('old_owner_role_'+name+'_'+role['name'], word(target,'hasRole(bytes32,address)',role['value'],OLD), 0)
                if name == 'Registry':
                    cfg = u.config(call(target,'getRoleConfig(bytes32)',role['value']))
                    a.need('old_owner_role_admin_'+role['name'], cfg['owner'] != OLD, True)
        for row in spec['authorities']:
            a.need('old_owner_authority_'+name+'_'+row['name'], addr(target,row['signature']) != OLD, True)
        for row in spec['mappings']:
            a.need('old_owner_mapping_'+name+'_'+row['name'], word(target,row['signature'],OLD), 0)
    for name,target in targets.items():
        check_target(name,target)
    for name in ('GTokenStaking','GToken','xPNTsFactory','MySBT','PaymasterFactory'):
        getter = 'daoMultisig()' if name == 'MySBT' else 'owner()'
        a.need('old_owner_control_'+name, addr(targets[name],getter), u.DEPLOYER)
    def canonical_pin():
        canonical = recorded('eth_getBlockByNumber',[block,False])
        a.need('old_owner_role_pin_canonical', canonical['hash'], pin['stateBlockHash'])
        a.need('old_owner_role_pin_number', canonical['number'], block)
    canonical_pin()
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
    a.need('old_owner_role_extraction_empty', bool(roles) and standard <= roles, True)
    for role in sorted(roles-standard):
        a.need('old_owner_role_Registry_'+role, word(u.REG,'hasRole(bytes32,address)',role,OLD), 0)
        a.need('old_owner_role_admin_'+role, u.config(call(u.REG,'getRoleConfig(bytes32)',role))['owner'] != OLD, True)
    proposer = next((r['value'] for r in inventory['TimelockController']['roles'] if r['name'] == 'PROPOSER_ROLE'), None)
    a.need('old_owner_control_role_extracted', proposer is not None, True)
    a.need('old_owner_control_role', word(u.TL,'hasRole(bytes32,address)',proposer,u.SAFE), 1)
    a.need('old_owner_control_authority', addr(u.SP,'owner()'), u.DEPLOYER)
    a.need('old_owner_registry_user_roles', words(u.REG,'getUserRoles(address)',OLD), [32,0])
    holder_roles = words(u.REG,'getUserRoles(address)',u.DEPLOYER)
    a.need('old_owner_control_registration', len(holder_roles) > 2 and holder_roles[0] == 32 and holder_roles[1] == len(holder_roles)-2, True)
    operator_types = inventory['SuperPaymaster']['operatorOutputs']
    a.need('old_owner_operator_abi', operator_types, ['uint128','bool','bool','address','uint32','uint48','address','uint256','uint256'])
    a.need('old_owner_operator', words(u.SP,'operators(address)',OLD), [0]*len(operator_types))
    tokens = {pin['capped'], OLD_TOKEN, targets['GToken']}
    xpnts = set(u.addr_array(call(targets['xPNTsFactory'],'getAllTokens()')))
    configured = False
    for who in sorted(set(pin['pauseList'])):
        w = words(u.SP,'operators(address)',who)
        a.need('old_owner_operator_shape',len(w),len(operator_types))
        configured |= w[1] == 1
        token = u.addr_word(w[3])
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
        a.need('old_owner_control_xPNTsToken', u.addr_word(word(targets['xPNTsFactory'],'communityToToken(address)',community)), token)
    tokens.update(xpnts)
    mapping_controls = []
    for name in ('Registry','SuperPaymaster'):
        for row in inventory[name]['mappings']:
            for who in sorted({u.DEPLOYER,*pin['pauseList']}):
                mapping_controls.append(word(targets[name],row['signature'],who))
    a.need('old_owner_control_mapping', 1 in mapping_controls, True)
    principals = sorted({u.SAFE,u.TL,u.SP,u.REG,u.DEPLOYER,a.APPROVER,a.EXECUTOR,NEW})
    reverse, controls = [], []
    for token in sorted(tokens):
        for who in principals:
            a.need('old_owner_allowance_'+token+'_'+who, word(token,'allowance(address,address)',who,OLD), 0)
        for spender in (u.SP,u.REG):
            reverse.append(dict(token=token,spender=spender,value=word(token,'allowance(address,address)',OLD,spender)))
            for holder in principals:
                controls.append(word(token,'allowance(address,address)',holder,spender))
    a.need('old_owner_control_allowance', any(v > 0 for v in controls), True)
    owners = u.addr_array(call(u.SAFE,'getOwners()'))
    a.need('old_owner_safe_owners', OLD not in owners, True)
    a.need('old_owner_control_safe_owners', a.APPROVER in owners and a.EXECUTOR in owners, True)
    a.need('old_owner_control_safe', word(u.SAFE,'isOwner(address)',a.APPROVER), 1)
    a.need('old_owner_safe_modules', word(u.SAFE,'isModuleEnabled(address)',OLD), 0)
    for label in ('guard','fallback'):
        slot = a.keccak('guard_manager.guard.address' if label == 'guard' else 'fallback_manager.handler.address')
        a.need('old_owner_safe_'+label, storage(slot) != OLD, True)
    return dict(inventory=inventory, targets=targets, configuredRoles=sorted(roles), xpnts=sorted(xpnts), tokens=sorted(tokens), reverseAllowances=reverse, reads=reads)


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
            elif row['kind'] == 'rpc':
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
        actual = audit(replay,pin,inventory)
        a.need('old_owner_replay_unused',index,len(transcript))
        a.need('old_owner_revalidated_'+endpoint,actual,expected)
