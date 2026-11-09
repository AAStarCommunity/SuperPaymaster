"""Pinned-source authority discovery and replayable old-owner isolation reads."""
import json
import hashlib
import os
import subprocess
import tempfile
from pathlib import Path
from functools import lru_cache
import sp_upgrade_exec as u

a = u.a
OLD_TIMELOCK = '0x86c86c789edc099801cc6a5f48334f1d67dc9564'
OLD = '0x92a30ef64b0b750220b2b3bafe4f3121263d45b3'
NEW = '0xd6e95a852d68f99759bf47e77d84fcc8d6f93494'
OLD_TOKEN = '0x696a73701b104c6ccbbaaddd2216788ea08eab89'
PNT_TOKEN = '0xe6579a90dc498a710008de12119812d0fb7aa224'
ROUND_CLONES = (OLD_TOKEN, PNT_TOKEN)
NAMES = ('Registry', 'SuperPaymaster', 'APNTsCapped', 'TimelockController', 'GTokenStaking', 'GToken', 'xPNTsFactory', 'xPNTsToken', 'MySBT', 'PaymasterFactory')

# Existing Sepolia deployment config; other addresses come from pinned getters.
PAYMASTER_FACTORY = '0xa936f8e3d682b0ecf280e6f5c05ff4204ee87180'
VERIFIED_PROXIES = frozenset((u.REG, u.SP))
IMPLEMENTATION_SLOT = hex(int(a.keccak('eip1967.proxy.implementation'),16)-1)
BEACON_SLOT = hex(int(a.keccak('eip1967.proxy.beacon'),16)-1)
PROXY_COMMIT = 'cf26915e032ccc9e8e02f9aaf3769afd4335027e'
ROLE_ANODE = '0x3aa2e9509f29532b71f822e18bcde843a8070a508d564188ec8a6adf59eff28a'
ROLE_KMS = '0x6fb2b25080d21c908f32ff8ff99eb1d552c210854f7de48a40406764c09c68f8'
NEVER_GRANTED = {u.REG: sorted([ROLE_ANODE, ROLE_KMS])}
ROLE_ENDUSER = '0x0c34ecc75d3bf122e0609d2576e167f53fb42429262ce8c9b33cab91ff670e3a'
# ROLE_ENDUSER added per the DSR ruling of 2026-11-05: at pin block 0xb826f8 (12068600) no control holder (Safe, deployer,
# pauseList) holds ENDUSER on either endpoint, so only the mapping-getter proof can show its zero is meaningful.
MAPPING_CONTROL_ROLES = {u.REG: [ROLE_ANODE, ROLE_KMS, ROLE_ENDUSER]}
ROLE_COMMUNITY = a.keccak('COMMUNITY')
TOKEN_EVENT = 'xPNTsTokenDeployed(address,address,string,string)'
ROLE_EVENT = 'RoleConfigured(bytes32,'+u.CONFIG_TYPE+',uint256)'


def inventory_source(release_tree=None, *, mode='deployed', rpc=None, pin=None, sources=None, names=NAMES):
    """The pin never uses a release layout, even when a deployed build is missing."""
    if mode == 'release':
        a.need('old_owner_release_tree', release_tree is not None, True)
        return extract(release_tree) if names == NAMES else extract(release_tree,names)
    a.need('old_owner_source_mode', mode, 'deployed')
    a.need('old_owner_deployed_sources', isinstance(sources, dict) and bool(sources), True)
    return deployed_inventory(rpc, pin, sources)


def ast_walk(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from ast_walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from ast_walk(value)


def registry_role_writes(entries):
    """Conservatively prove the deployed Registry's configuration enumeration."""
    members = {n.get('id'): n for _, n in entries if 'id' in n}
    mappings = {i for i, n in members.items() if n.get('stateVariable') and n.get('name') == 'roleConfigs'}
    functions = {i: n for i, n in members.items() if n.get('nodeType') in ('FunctionDefinition', 'ModifierDefinition')
                 and n.get('body') is not None}
    init = {i for i, n in functions.items() if n.get('name') == '_initRole'}
    configure = {i for i, n in functions.items() if n.get('name') == 'configureRole'}
    declarations = {n['id']: n for n in ast_walk(list(functions.values()))
                    if n.get('nodeType') == 'VariableDeclaration' and 'id' in n}
    aliases = set(mappings)
    def references(node):
        return any(n.get('referencedDeclaration') in aliases for n in ast_walk(node))
    # Follow aliases to a fixed point, including aliases of aliases.
    changed = True
    while changed:
        before = set(aliases)
        for n in ast_walk(list(functions.values())):
            if n.get('nodeType') == 'VariableDeclarationStatement' and references(n.get('initialValue')):
                aliases.update(d['id'] for d in n['declarations'] if d and d.get('storageLocation') == 'storage')
            if n.get('nodeType') == 'Assignment' and references(n.get('rightHandSide')):
                aliases.update(v['referencedDeclaration'] for v in ast_walk(n['leftHandSide'])
                               if declarations.get(v.get('referencedDeclaration'), {}).get('storageLocation') == 'storage')
        changed = before != aliases
    writes, escapes = [], []
    callers = {i: set() for i in functions}
    for i, fn in functions.items():
        for n in ast_walk(fn):
            kind = n.get('nodeType')
            lhs = n.get('leftHandSide') if kind == 'Assignment' else n.get('subExpression')
            if (kind == 'Assignment' or kind == 'UnaryOperation' and n.get('operator') in ('delete', '++', '--')) and references(lhs):
                writes.append(i)
            callee = n.get('referencedDeclaration')
            if callee in callers:
                callers[callee].add(i)
            if kind == 'FunctionCall':
                # A storage reference passed away could hide a write in another function.
                if any(references(arg) and arg.get('typeDescriptions', {}).get('typeString', '').endswith(('storage pointer', 'storage ref'))
                       for arg in n.get('arguments', [])):
                    escapes.append(i)
            if kind == 'InlineAssembly' and any(r.get('declaration') in aliases
                                               for r in n.get('externalReferences', [])):
                escapes.append(i)
    a.need('old_owner_role_write_sites', len(mappings) == 1 and len(init) == 1 and len(configure) == 1
           and set(writes) == init | configure and not escapes, True)
    def initializer_only(i, path):
        if i in path:
            return False
        fn = functions[i]
        modifiers = [m.get('modifierName', {}).get('name') for m in fn.get('modifiers', [])]
        if 'reinitializer' in modifiers:
            return False
        if 'initializer' in modifiers:
            return True
        if fn.get('visibility') in ('public', 'external') or not callers[i]:
            return False
        return all(initializer_only(caller, path | {i}) for caller in callers[i])
    a.need('old_owner_role_initializer_only', all(initializer_only(i, set()) for i in init), True)
    def role_constant(node):
        declaration = members.get(node.get('referencedDeclaration'), {})
        name = declaration.get('name', '')
        if (node.get('nodeType') == 'Identifier'
                and declaration.get('nodeType') == 'VariableDeclaration'
                and declaration.get('constant')
                and declaration.get('typeDescriptions', {}).get('typeString') == 'bytes32'
                and (name.startswith('ROLE_') or name.endswith('ROLE'))):
            return {name}
        return None

    def init_ids(arg, fn):
        direct = role_constant(arg)
        if direct is not None:
            return direct
        base = arg.get('baseExpression', {})
        if arg.get('nodeType') != 'IndexAccess' or base.get('nodeType') != 'Identifier':
            return None
        local = base.get('referencedDeclaration')
        nodes = list(ast_walk(fn))
        declarations = [n for n in nodes if n.get('nodeType') == 'VariableDeclaration'
                        and n.get('id') == local]
        statements = [n for n in nodes if n.get('nodeType') == 'VariableDeclarationStatement'
                      and any(d and d.get('id') == local for d in n.get('declarations', []))]
        if (local is None or len(declarations) != 1 or len(statements) != 1
                or declarations[0].get('storageLocation') != 'memory'
                or declarations[0].get('stateVariable', False)):
            return None
        for n in nodes:
            kind = n.get('nodeType')
            target = n.get('leftHandSide') if kind == 'Assignment' else n.get('subExpression')
            if (kind == 'Assignment' or kind == 'UnaryOperation' and n.get('operator') in ('delete', '++', '--')):
                if any(v.get('referencedDeclaration') == local for v in ast_walk(target)):
                    return None
            # Passing or aliasing the memory array could hide a mutation.
            if kind == 'Identifier' and n.get('referencedDeclaration') == local:
                if not any(v.get('nodeType') == 'IndexAccess' and v.get('baseExpression') is n for v in nodes):
                    return None
            if kind == 'InlineAssembly' and any(r.get('declaration') == local for r in n.get('externalReferences', [])):
                return None
        value = statements[0].get('initialValue') or {}
        if value.get('nodeType') != 'TupleExpression' or not value.get('isInlineArray'):
            return None
        components = [role_constant(c or {}) for c in value.get('components', [])]
        if not components or any(c is None for c in components):
            return None
        return set().union(*components)

    resolved = [init_ids((n.get('arguments') or [{}])[0], fn)
                for fn in functions.values() for n in ast_walk(fn)
                if n.get('nodeType') == 'FunctionCall'
                and n.get('expression', {}).get('referencedDeclaration') in init]
    a.need('old_owner_role_init_ids', bool(resolved) and all(r is not None for r in resolved), True)
    events = {i for i, n in members.items() if n.get('nodeType') == 'EventDefinition' and n.get('name') == 'RoleConfigured'}
    def emits(i):
        body = functions[i].get('body', {})
        statements = body if isinstance(body, list) else body.get('statements', [])
        return not any(n.get('nodeType') == 'Return' for n in ast_walk(body)) and any(
            n.get('nodeType') == 'EmitStatement'
            and n.get('eventCall', {}).get('expression', {}).get('referencedDeclaration') in events
            for n in statements)
    a.need('old_owner_role_configure_emit', all(emits(i) for i in configure), True)
    return set().union(*(r for r in resolved if r is not None))


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
            if name == 'Registry':
                initialized_roles = registry_role_writes(entries)
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
            if name == 'Registry':
                a.need('old_owner_role_init_standard', sorted(initialized_roles), sorted({r['name'] for r in groups['roles']}))
            for rows in groups.values():
                rows.sort(key=lambda x:(x['name'],x['file']))
            if name == 'Registry' or any(f['type'] == 'event' and f['name'] == 'RoleConfigured' for f in abi):
                events = [f for f in abi if f['type'] == 'event' and f['name'] == 'RoleConfigured']
                def abi_type(v):
                    return '('+','.join(abi_type(c) for c in v['components'])+')' if v['type'] == 'tuple' else v['type']
                a.need('old_owner_role_event_abi', len(events), 1)
                event = events[0]
                a.need('old_owner_role_event_signature', event['name']+'('+','.join(abi_type(v) for v in event['inputs'])+')', ROLE_EVENT)
                a.need('old_owner_role_event_indexed', [v['indexed'] for v in event['inputs']], [True, False, False])
                groups['roleEventTopic'] = a.keccak(ROLE_EVENT)
            groups['hasRoleGetter'] = 'public-mapping' if any(
                n.get('nodeType') == 'VariableDeclaration' and n.get('name') == 'hasRole'
                and n.get('stateVariable') and n.get('visibility') == 'public'
                and n.get('typeName', {}).get('nodeType') == 'Mapping'
                and n['typeName']['keyType'].get('name') == 'bytes32'
                and n['typeName']['valueType'].get('nodeType') == 'Mapping'
                and n['typeName']['valueType']['keyType'].get('name') == 'address'
                and n['typeName']['valueType']['valueType'].get('name') == 'bool'
                for _, n in entries) else 'function'
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


def allowance_holders():
    return sorted({u.SAFE,u.TL,u.SP,u.REG,u.DEPLOYER,a.APPROVER,a.EXECUTOR,NEW})


def authority_rows(section):
    inventory = section['inventory']
    targets = dict(section['targets'])
    rows = []
    for name, target in [*sorted(targets.items()), *(('xPNTsToken', t) for t in section['xpnts'])]:
        spec = inventory.get('targetInventories', {}).get(target, inventory[name])
        for row in spec['authorities']:
            rows.append((target, row['signature'], [], 'address'))
        for row in spec['mappings']:
            rows.append((target, row['signature'], [OLD_TIMELOCK], 'bool'))
        roles = {r['value'] for r in spec['roles']} | set(section['roleHistory'].get(target, []))
        if name == 'Registry':
            roles.update(section['configuredRoles'])
            rows.extend((target, 'getRoleConfig(bytes32)', [r], 'config') for r in sorted(roles))
        if spec['hasRole']:
            rows.extend((target, 'hasRole(bytes32,address)', [r, OLD_TIMELOCK], 'bool') for r in sorted(roles))
    return rows


def audit(rpc, pin, inventory, fork=None):
    block = pin['stateBlock']
    reads, fork_controls, histories = [], [], {}
    history_counts, declared_never, never_reads, old_role_reads = {}, {}, [], []
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
    def old_role(target,role):
        # Every role membership of OLD read at the pin is re-read at pre_send and closing (DSR: safeMintForRole
        # lets any COMMUNITY holder grant OLD an active role after the pin).
        value = word(target,'hasRole(bytes32,address)',role,OLD)
        if (target,role) not in {(r['target'],r['role']) for r in old_role_reads}:
            old_role_reads.append(dict(target=target,role=role,result=value))
        return value
    def role_owner(target,role,gate):
        raw = call(target,'getRoleConfig(bytes32)',role)
        cfg = u.config(raw)
        changed = u.uints(raw)
        changed[11] = int(OLD,16)
        negative(gate,'0x'+''.join(format(v,'064x') for v in changed))
        a.need(gate,cfg['owner'] != OLD,True)
    def role_control(name,target,role,spec):
        values = [word(target,'hasRole(bytes32,address)',role,holder) for holder in sorted({u.SAFE,u.DEPLOYER,*pin['pauseList']})]
        if 1 in values:
            return
        if mapping_control(spec,target,role,word):
            return
        case = pin.get('isolationControlCases',{}).get(target+':'+role)
        if case is None and name == 'TimelockController':
            case = dict(sender=u.TL,gate='old_owner_event_role_'+name,
                        transactions=[dict(target=target,signature='grantRole(bytes32,address)',args=[role,'$ACCOUNT'])],
                        getter=dict(target=target,signature='hasRole(bytes32,address)',args=[role,'$ACCOUNT']))
        a.need('old_owner_role_control_path','available' if case else 'unverified','available')
        a.need('old_owner_role_control_case',isinstance(case,dict),True)
        a.need('old_owner_role_control_getter',case['getter'],dict(target=target,signature='hasRole(bytes32,address)',args=[role,'$ACCOUNT']))
        a.need('old_owner_role_control_gate',case['gate'],'old_owner_event_role_'+name)
        probe(case)
    def check_target(name, target):
        spec = inventory.get('targetInventories',{}).get(target,inventory[name])
        deployments = {r['target']:r['creationBlock'] for r in inventory.get('deployedSources',[])}
        creation = deployments.get(target,pin.get('isolationDeployments',{}).get(target))
        histories[target] = role_history(recorded,pin,target,spec,creation,history_counts,declared_never)
        for role in declared_never.get(target,[]):
            for holder in sorted(control_holders | {OLD}):
                value = word(target,'hasRole(bytes32,address)',role,holder)
                a.need('old_owner_never_granted_holder',value,0)
                never_reads.append(dict(target=target,role=role,holder=holder,result=value))
        if spec['hasRole']:
            for role in spec['roles']:
                value = old_role(target,role['value'])
                gate = 'old_owner_role_'+name+'_'+role['name']
                negative(gate,1)
                a.need(gate,value,0)
                if name == 'Registry':
                    role_owner(target,role['value'],'old_owner_role_admin_'+role['name'])
        for role in histories[target]:
            if spec['hasRole']:
                value = old_role(target,role)
                negative('old_owner_event_role_'+name,1)
                a.need('old_owner_event_role_'+name,value,0)
                role_control(name,target,role,spec)
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
    configured_by_target = {}
    configuration_targets = dict((target,name) for name,target in targets.items())
    for name, group in pin.get('isolationExtraTargets',{}).items():
        configuration_targets.update((target,name) for target in group)
    for target, name in configuration_targets.items():
        spec = inventory.get('targetInventories',{}).get(target,inventory[name])
        if 'roleEventTopic' not in spec:
            continue
        creation = next((r['creationBlock'] for r in inventory.get('deployedSources',[]) if r['target'] == target), pin.get('isolationDeployments',{}).get(target))
        if name == 'Registry':
            creation = pin['registryCreation']
        topic = spec['roleEventTopic']
        logs = bounded_history_logs(recorded, dict(address=target, fromBlock=hex(creation),
                                             toBlock=block, topics=[topic]))
        roles, canonical_blocks = set(), {}
        for log in logs:
            a.need('old_owner_role_log_address', log.get('address'), target)
            a.need('old_owner_role_log_removed', log.get('removed',False), False)
            topics = log.get('topics',[])
            a.need('old_owner_role_log_topics', len(topics), 2)
            a.need('old_owner_role_log_topic', topics[0], topic)
            role = a.typed(topics[1],a.HASH32)
            number = a.typed(log.get('blockNumber'),a.QTY)
            a.need('old_owner_role_log_range', creation <= a.qty(number) <= a.qty(block), True)
            if number not in canonical_blocks:
                canonical_blocks[number] = recorded('eth_getBlockByNumber',[number,False])
            canonical = canonical_blocks[number]
            a.need('old_owner_role_log_canonical', a.typed(log.get('blockHash'),a.HASH32), canonical['hash'])
            a.need('old_owner_role_log_block', canonical['number'], number)
            roles.add(role)
        canonical_pin()
        standard = {r['value'] for r in spec['roles']}
        if name == 'Registry':
            roles |= standard | set(histories.get(target, []))
            for role in sorted(standard):
                cfg = u.config(call(target, 'getRoleConfig(bytes32)', role))
                a.need('old_owner_role_config_control', cfg['isActive'] and int(cfg['owner'], 16) != 0, True)
        else:
            a.need('old_owner_role_extraction_empty', bool(roles) and standard <= roles, True)
        configured_by_target[target] = roles
        for role in sorted(roles-standard-set(histories.get(target, []))):
            value = old_role(target,role)
            negative('old_owner_role_'+name+'_'+role,1)
            a.need('old_owner_role_'+name+'_'+role,value,0)
            if name == 'Registry':
                role_owner(target,role,'old_owner_role_admin_'+role)
            role_control(name,target,role,spec)
    roles = configured_by_target[u.REG]
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
    enumerated = set(u.addr_array(call(targets['xPNTsFactory'],'getAllTokens()')))
    a.need('old_owner_factory_enumeration',bool(enumerated) and set(ROUND_CLONES) <= enumerated,True)
    xpnts = enumerated | set(pin.get('isolationLegacyTokens',[])) | set(ROUND_CLONES)
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
        owner = addr(token,'communityOwner()')
        a.need('old_owner_xpnts_owner_pin', owner not in (OLD, OLD_TIMELOCK), True)
        check_target('xPNTsToken',token)
        community = owner
        a.need('old_owner_control_xPNTsToken_owner', community != a.ZERO, True)
        token_factory = addr(token,'FACTORY()')
        community = token_deployment_community(recorded, pin, token_factory, token)
        a.need('old_owner_control_xPNTsToken', u.addr_word(word(token_factory,'communityToToken(address)',community)), token)
    tokens.update(xpnts)
    mapping_controls = []
    for name in ('Registry','SuperPaymaster'):
        for row in inventory[name]['mappings']:
            for who in sorted({u.DEPLOYER,*pin['pauseList']}):
                mapping_controls.append(word(targets[name],row['signature'],who))
    a.need('old_owner_control_mapping', 1 in mapping_controls or fork is not None, True)
    principals = allowance_holders()
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
    return dict(declaredNeverGranted=declared_never, neverGrantedReads=never_reads, oldRoleReads=old_role_reads, safeFallback=dict(address=FALLBACK_HANDLER,provenance='docs/release/a3a-precheck-v4/snapshot.json; DSR canonical deployment-list confirmation required'), forkControls=fork_controls, roleHistory=histories, roleHistoryCounts=history_counts, inventory=inventory, targets=targets, configuredRoles=sorted(roles), xpnts=sorted(xpnts), tokens=sorted(tokens), reverseAllowances=reverse, reads=reads)


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
        artifact_name = 'GTokenAuthorization' if name == 'GToken' and commit == 'cf26915e032ccc9e8e02f9aaf3769afd4335027e' else name
        art = a.raw_artifact(tree,artifact_name)
        art['immutableDeclarations'] = immutable_declarations(tree)
        metadata = art.get('metadata', {})
        if isinstance(metadata,str):
            metadata = json.loads(metadata)
        a.need('old_owner_compiler_settings', bool(metadata.get('settings')) and bool(metadata.get('compiler')), True)
        return dict(inventory={} if name == 'ERC1967Proxy' else extract(tree,(artifact_name,))[artifact_name], artifact=art,
                    compiler=metadata['compiler'], settings=metadata['settings'], forge=version)


def discover_targets(rpc, pin):
    block = pin['stateBlock']
    def address(target, sig):
        return u.addr_word(a.word(rpc,target,sig,block=block))
    targets = dict(Registry=[u.REG],SuperPaymaster=[u.SP],APNTsCapped=[pin['capped']],TimelockController=[u.TL],
                   GTokenStaking=[address(u.REG,'GTOKEN_STAKING()')],MySBT=[address(u.REG,'MYSBT()')],
                   xPNTsFactory=[address(u.SP,'xpntsFactory()')],PaymasterFactory=[PAYMASTER_FACTORY])
    targets['GToken'] = [address(targets['GTokenStaking'][0],'GTOKEN()')]
    enumerated = set(u.addr_array(a.call(rpc,targets['xPNTsFactory'][0],'getAllTokens()',block=block)))
    # Before the switch, the factory must enumerate every round clone itself.
    switched = 'discoveryOriginalFactory' in pin and targets['xPNTsFactory'][0] != pin['discoveryOriginalFactory']
    a.need('old_owner_factory_enumeration',switched or bool(enumerated) and set(ROUND_CLONES) <= enumerated,True)
    tokens = enumerated | set(ROUND_CLONES) | (set(pin['discoveryRetainedTokens']) if switched else set())
    for who in pin['pauseList']:
        values = u.uints(a.call(rpc,u.SP,'operators(address)',who,block=block))
        a.need('old_owner_discovery_operator_shape',len(values),9)
        token = u.addr_word(values[3])
        if token != a.ZERO:
            tokens.add(token)
    a.need('old_owner_discovery_tokens',bool(tokens),True)
    targets['xPNTsToken'] = sorted(tokens)
    return targets


def is_clone(code):
    code = code.lower()
    return len(code) == 92 and code.startswith('0x363d3d373d3d3d363d73') and code.endswith('5af43d82803e903d91602b57fd5bf3')


def clone_implementation(code):
    code = a.typed(code,a.HEXDATA).lower()
    a.need('old_owner_clone_standard',is_clone(code),True)
    return '0x'+code[22:62]


def factory_implementation(factory):
    """Constructor's first CREATE: keccak(rlp([factory, nonce=1]))[12:]."""
    return a.create_address(factory,1)


def verify_clone(code, factory, expected):
    implementation = clone_implementation(code)
    a.need('old_owner_clone_implementation',implementation,expected)
    a.need('old_owner_clone_factory_nonce1',implementation,factory_implementation(factory))
    return implementation


def committed_record(path, digest):
    """Read repository evidence from HEAD, never caller-supplied record contents."""
    a.need('old_owner_record_path', isinstance(path,str) and not Path(path).is_absolute() and '..' not in Path(path).parts, True)
    proc = subprocess.run(['git','show','HEAD:'+path],cwd=u.ROOT,capture_output=True)
    a.need('old_owner_record_committed',proc.returncode,0)
    a.need('old_owner_record_sha256',hashlib.sha256(proc.stdout).hexdigest(),digest)
    return json.loads(proc.stdout)


def verify_deployment_record(spec):
    ref = spec.get('deploymentRecord')
    a.need('old_owner_record_required',isinstance(ref,dict),True)
    record = committed_record(ref['path'],ref['sha256'])
    a.need('old_owner_record_commit',ref['commit'],spec['commit'])
    recorded_commit = record.get('commit',record.get('rebuild',{}).get('commit'))
    resolved = subprocess.run(['git','rev-parse','--verify',str(recorded_commit)+'^{commit}'],cwd=u.ROOT,capture_output=True,text=True)
    a.need('old_owner_record_source_commit',resolved.stdout.strip() if resolved.returncode == 0 else None,spec['commit'])
    address = ref['contractAddress']
    a.need('old_owner_record_address',address,spec['implementation'])
    a.typed(ref['txHash'],a.HASH32)
    receipts = record.get('receipts',[])
    if 'receipt' in ref:
        receipt_ref = ref['receipt']
        receipts = [committed_record(receipt_ref['path'],receipt_ref['sha256'])]
        a.need('old_owner_record_plan_address',record.get('pin',{}).get('capped'),address)
    matches = [r for r in receipts if r.get('transactionHash','').lower() == ref['txHash']]
    a.need('old_owner_record_receipt',len(matches),1)
    a.need('old_owner_record_receipt_address',matches[0].get('contractAddress','').lower(),address)
    a.need('old_owner_record_receipt_status',matches[0].get('status'),'0x1')
    return dict(ref,resolvedCommit=spec['commit'])


def source_provenance(comparison, deployment_record):
    """Rule 4: exact comparison determines behavior, not source identity.

    Source identity requires a deployment record.

    Rule 4 applies whenever metadata was masked or differs: select the candidate
    from a deployment record first. This prerequisite does not grant parity.
    """
    exact = all(comparison.get(k) is True for k in ('equal','metadataUnmasked','metadataEqual'))
    a.need('old_owner_source_rule4',exact or bool(deployment_record and deployment_record.get('resolvedCommit')),True)


def runtime_metadata(code):
    tail = a.cbor_tail(code)
    solc, ipfs = tail.get('solc'),tail.get('ipfs')
    a.need('old_owner_metadata_solc',isinstance(solc,bytes) and len(solc) == 3,True)
    a.need('old_owner_metadata_ipfs',ipfs is None or isinstance(ipfs,bytes),True)
    raw = bytes.fromhex(code[2:])
    return dict(solc='.'.join(str(v) for v in solc),ipfs=ipfs.hex() if ipfs is not None else None),len(raw)-int.from_bytes(raw[-2:],'big')-2


def immutable_declarations(tree):
    """Resolve compiler reference IDs in the same build's AST (including bases)."""
    declarations = {}
    def visit(node):
        if isinstance(node, dict):
            if node.get('nodeType') == 'VariableDeclaration' and node.get('mutability') == 'immutable':
                declarations[str(node['id'])] = dict(name=node['name'], type=node['typeDescriptions']['typeString'])
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)
    for path in sorted((tree/'out/build-info').glob('*.json')):
        visit(json.loads(path.read_text())['output']['sources'])
    return declarations


def immutable_expectations(implementation=None):
    config = json.loads(subprocess.run(
        ['git', 'show', 'HEAD:deployments/config.sepolia.json'], cwd=u.ROOT,
        capture_output=True, check=True).stdout)
    aliases = dict(entryPoint='entryPoint', REGISTRY='registry', registry='registry',
                   FACTORY='xPNTsFactory', factory='xPNTsFactory', GTOKEN_STAKING='staking', GTOKEN='gToken',
                   MYSBT='sbt', ETH_USD_PRICE_FEED='priceFeed')
    result = {name: config[key].lower() for name, key in aliases.items()}
    result['implementation'] = factory_implementation(config['xPNTsFactory'].lower())
    result['_cachedChainId'] = a.CHAIN
    if implementation:
        result['__self'] = implementation.lower()
        result['_cachedThis'] = implementation.lower()
    return result


def decode_immutable(identity, values, artifact, expectations):
    declaration = artifact.get('immutableDeclarations', {}).get(identity)
    a.need('old_owner_immutable_ast', declaration is not None, True)
    a.need('old_owner_immutable_values', bool(values), True)
    name, typ = declaration['name'], declaration['type']
    number = int.from_bytes(values[0], 'big')
    address_type = typ in ('address', 'address payable') or typ.startswith('contract ')
    if address_type:
        a.need('old_owner_immutable_address_encoding', number < 2**160, True)
        value = '0x'+format(number, '040x')
        a.need('old_owner_immutable_not_old', value != OLD, True)
    elif typ.startswith('uint'):
        value = number
    elif typ.startswith('int'):
        value = int.from_bytes(values[0], 'big', signed=True)
    elif typ == 'bool':
        value = bool(number)
    else:
        value = '0x'+values[0].hex()
    if address_type:
        a.need('old_owner_immutable_expectation_missing', name in expectations and expectations[name] != 'no expected value', True)
    expected = expectations.get(name, 'no expected value')
    if expected != 'no expected value':
        a.need('old_owner_immutable_expected', value, expected)
    return dict(id=identity, name=name, type=typ, value=value, expected=expected,
                result='PASS' if expected != 'no expected value' else 'no expected value')


def runtime_parity(code, artifact, deployment_record=None, expectations=None):
    deployed = artifact['deployedBytecode']
    actual = bytearray.fromhex(a.typed(code,a.HEXDATA)[2:])
    expected = bytearray.fromhex(a.typed(deployed['object'],a.HEXDATA)[2:])
    a.need('old_owner_runtime_length',len(actual),len(expected))
    a.need('old_owner_runtime_nonempty',bool(actual),True)
    cbor, metadata_start = runtime_metadata(code)
    _, expected_metadata_start = runtime_metadata(deployed['object'])
    metadata_equal = actual[metadata_start:] == expected[expected_metadata_start:]
    source_provenance(dict(equal=metadata_equal,metadataUnmasked=True,metadataEqual=metadata_equal),deployment_record)
    if expectations is None:
        expectations = immutable_expectations()
    occupied, ranges, immutables = set(), [], []
    for identity, entries in deployed.get('immutableReferences',{}).items():
        values = []
        for entry in entries:
            start, size = entry['start'], entry['length']
            a.need('old_owner_immutable_range', type(start) is int and size == 32 and 0 <= start <= len(expected)-size, True)
            a.need('old_owner_metadata_unmasked',start+size <= min(metadata_start,expected_metadata_start),True)
            span = set(range(start,start+size))
            a.need('old_owner_immutable_overlap',bool(span & occupied),False)
            occupied.update(span)
            values.append(bytes(actual[start:start+size]))
            actual[start:start+size] = expected[start:start+size] = bytes(size)
            ranges.append(dict(start=start,length=size))
        a.need('old_owner_immutable_consistency',len(set(values)) <= 1,True)
        immutables.append(decode_immutable(identity, values, artifact, expectations))
    a.need('old_owner_runtime_parity',actual == expected,True)
    return dict(equal=True,immutables=immutables,immutableRanges=ranges,runtimeKeccak=a.keccak(code),
                comparisonType='immutable-only masking; metadata UNMASKED and byte-for-byte equal',
                metadataUnmasked=True,metadataEqual=metadata_equal,cbor=cbor)


def deployed_inventory(rpc, pin, sources):
    canonical = rpc('eth_getBlockByNumber',[pin['stateBlock'],False])
    a.need('old_owner_source_pin',canonical['hash'],pin['stateBlockHash'])
    a.need('old_owner_source_pin_number',canonical['number'],pin['stateBlock'])
    targets = discover_targets(rpc,pin)
    wanted = {target for group in targets.values() for target in group}
    a.need('old_owner_source_targets',sorted(sources),sorted(wanted))
    result, mapping, variants = {}, [], {}
    block = pin['stateBlock']
    clone_impl = None
    for name, group in targets.items():
        for target in group:
            spec = sources[target]
            a.exact_keys('old_owner_source_fields',spec,('contract','implementation','commit','creationBlock','claim',*(['deploymentRecord'] if 'deploymentRecord' in spec else [])))
            a.need('old_owner_source_claim', spec['claim'] in (('behavioral-equivalence',) if name == 'Registry' else ('behavioral-equivalence','deployment-record + runtime parity')), True)
            record = verify_deployment_record(spec) if spec['claim'] == 'deployment-record + runtime parity' else None
            a.need('old_owner_source_name',spec['contract'],name)
            creation = spec['creationBlock']
            a.need('old_owner_creation_range',type(creation) is int and 0 < creation <= a.qty(block),True)
            # Verify the supplied deployment boundary instead of trusting a late start.
            a.need('old_owner_creation_before',rpc('eth_getCode',[target,hex(creation-1)]),'0x')
            a.need('old_owner_creation_at',rpc('eth_getCode',[target,hex(creation)]) != '0x',True)
            code = a.typed(rpc('eth_getCode',[target,block]),a.HEXDATA)
            implementation_word = int(a.typed(rpc('eth_getStorageAt',[target,IMPLEMENTATION_SLOT,block]),a.HASH32),16)
            beacon_word = int(a.typed(rpc('eth_getStorageAt',[target,BEACON_SLOT,block]),a.HASH32),16)
            a.need('unexpected_proxy', not (implementation_word or beacon_word) or target in VERIFIED_PROXIES, True)
            # The allowlist verifies ERC1967Proxy runtime, which does not use beacons.
            a.need('unexpected_proxy', beacon_word == 0, True)
            implementation = u.addr_word(implementation_word)
            a.need('old_owner_undeclared_clone', name == 'xPNTsToken' or not is_clone(code), True)
            proxy = None
            if target in VERIFIED_PROXIES:
                proxy_build = deployed_build(PROXY_COMMIT,'ERC1967Proxy')
                proxy = dict(commit=PROXY_COMMIT, contract='ERC1967Proxy',
                             parity=runtime_parity(code,proxy_build['artifact'],expectations=immutable_expectations(target)))
            if name == 'xPNTsToken':
                factory = u.addr_word(a.word(rpc,target,'FACTORY()',block=block))
                implementation = verify_clone(code,factory,spec['implementation'])
                if clone_impl is None:
                    clone_impl = implementation
                a.need('old_owner_clone_same_implementation',implementation,clone_impl)
            if implementation == a.ZERO:
                implementation = target
            a.need('old_owner_implementation',spec['implementation'],implementation)
            built = deployed_build(spec['commit'],name)
            parity = runtime_parity(rpc('eth_getCode',[implementation,block]),built['artifact'], expectations=immutable_expectations(implementation))
            source_provenance(parity,record)
            variants[target] = built['inventory']
            result.setdefault(name,built['inventory'])
            mapping.append(dict(contract=name,target=target,implementation=implementation,commit=spec['commit'],
                                claim=spec['claim'],creationBlock=creation,compiler=built['compiler'],settings=built['settings'],forge=built['forge'],parity=parity,proxy=proxy,deploymentRecord=record))
    a.need('old_owner_source_pin_after',rpc('eth_getBlockByNumber',[block,False]),canonical)
    result['deployedSources'] = mapping
    result['targetInventories'] = variants
    return result


def require_adopted_sources(pending):
    # Pending rulings cannot authorize a source, even if also listed as adopted.
    a.need('deployed_source_pending', pending or {}, {})


def collect_deployed(rpc, pin, sources, fork=None, pending=None):
    require_adopted_sources(pending)
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


def validate_deployed(section, pin, sources, pending=None):
    require_adopted_sources(pending)
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
    assert_endpoint_identities(identities)
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
    clone_reads = []
    def clone_rpc(method,params):
        value = rpc(method,params)
        clone_reads.append(dict(method=method,params=params,result=value))
        return value
    clone_evidence = post_upgrade_clones(clone_rpc,pin,token_kinds,pre_upgrade)
    for token,kind in token_kinds.items():
        a.need('old_owner_post_token_kind',kind in ('xPNTsToken','xPNTsTokenV2'),True)
        inventory['targetInventories'][token] = clone_evidence['inventory']
    post = copy.deepcopy(pin)
    post['isolationExtraTargets'] = copy.deepcopy(release_targets)
    for name,target in pre_upgrade['targets'].items():
        if target not in current.get(name,[]):
            post['isolationExtraTargets'].setdefault(name,[]).append(target)
    post['isolationLegacyTokens'] = pre_upgrade['xpnts']
    section = audit(rpc,post,inventory,fork=fork)
    section['cloneEvidence'] = clone_evidence
    section['cloneReads'] = clone_reads
    section['negativeControls'] = negative_controls(section,post,inventory)
    return section


def post_upgrade_clones(rpc, pin, tokens, pre_upgrade):
    """Resolve every legacy/current/manifest-created clone at the post-upgrade pin.

    A new implementation is a STOP under this ruling, even for a V2 token kind.
    Release inventory selection cannot waive the parity-verified binding.
    """
    sources = pre_upgrade['sourceSelection']
    rows = [v for v in sources.values() if v['contract'] == 'xPNTsToken']
    a.need('old_owner_post_clone_source',bool(rows),True)
    bindings = {(v['implementation'],v['commit']) for v in rows}
    a.need('old_owner_post_clone_binding',len(bindings),1)
    implementation,commit = sorted(bindings)[0]
    block = pin['stateBlock']
    built = deployed_build(commit,'xPNTsToken')
    parity = runtime_parity(rpc('eth_getCode',[implementation,block]),built['artifact'], expectations=immutable_expectations(implementation))
    source_provenance(parity,None)
    resolved = {}
    for token in sorted(tokens):
        factory = u.addr_word(a.word(rpc,token,'FACTORY()',block=block))
        resolved[token] = verify_clone(rpc('eth_getCode',[token,block]),factory,implementation)
    return dict(implementation=implementation,commit=commit,parity=parity,clones=resolved,inventory=built['inventory'],
                originMethod='CREATE keccak(rlp([factory, nonce=1]))[12:]')


GRANTED = 'RoleGranted(bytes32,address,address)'
REVOKED = 'RoleRevoked(bytes32,address,address)'
REGISTERED = 'RoleRegistered(bytes32,address,uint256,uint256)'
EXITED = 'RoleExited(bytes32,address,uint256,uint256)'
CONTROL = '0x00000000000000000000000000000000000c0170'
FALLBACK_HANDLER = '0xfd0732dc9e303f09fcef3a7388ad10a83459ec99'


def bounded_history_logs(rpc, query):
    start, stop = a.qty(query["fromBlock"]), a.qty(query["toBlock"])
    def bounded(method, params):
        result = rpc(method,params)
        if method == 'eth_getLogs':
            a.need('old_owner_log_array',isinstance(result,list),True)
            try:
                a.need('old_owner_log_limit',len(result) < 1000,True)
            except a.Gate as fault:
                fault.log_range_limit = True
                raise
        return result
    logs = a.schedule_logs(bounded,query)
    # Detect inconsistent pagination / silent truncation using a disjoint range cover.
    if start < stop:
        middle = (start+stop)//2
        parts = a.schedule_logs(bounded,dict(query,toBlock=hex(middle))) + a.schedule_logs(bounded,dict(query,fromBlock=hex(middle+1)))
        a.need('old_owner_log_partition',sorted(logs,key=lambda x:json.dumps(x,sort_keys=True)),sorted(parts,key=lambda x:json.dumps(x,sort_keys=True)))
    return logs


def role_history(rpc, pin, target, spec, creation, counts=None, declared=None):
    """Bounded history, canonical event identities, and independent OLD filter."""
    start, stop = creation, a.qty(pin['stateBlock'])
    a.need('old_owner_history_range',type(start) is int and 0 < start <= stop,True)
    events = [GRANTED, REVOKED] + ([REGISTERED, EXITED] if target == u.REG else [])
    topics = [a.keccak(event) for event in events]
    grants = {a.keccak(GRANTED), a.keccak(REGISTERED)}
    query = dict(address=target,fromBlock=hex(start),toBlock=pin['stateBlock'],topics=[topics])
    logs = bounded_history_logs(rpc,query)
    old_logs = bounded_history_logs(rpc,dict(query,topics=[topics,None,'0x'+OLD[2:].zfill(64)]))
    canonical, identities = {}, set()
    for log in logs+old_logs:
        a.need('old_owner_history_address',log.get('address'),target)
        a.need('old_owner_history_removed',log.get('removed',False),False)
        ts = log.get('topics',[])
        a.need('old_owner_history_topics',len(ts),3 if ts and ts[0] in (a.keccak(REGISTERED),a.keccak(EXITED)) else 4)
        if ts and ts[0] in (a.keccak(REGISTERED),a.keccak(EXITED)):
            a.need('old_owner_history_data',len(a.typed(log.get('data'),a.HEXDATA)),130)
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
    grant_roles = {l['topics'][1] for l in logs if l['topics'][0] in grants}
    a.need('old_owner_history_positive',not spec['hasRole'] or (standard - set(NEVER_GRANTED.get(target, []))) <= grant_roles,True)
    # Imported constants on contracts without hasRole are not local role memberships.
    never = sorted(standard - roles) if spec['hasRole'] else []
    a.need('old_owner_never_granted_set',never,NEVER_GRANTED.get(target,[]))
    if declared is not None and never:
        declared[target] = never
    if counts is not None:
        counts[target] = {event.split('(')[0]:sum(l['topics'][0] == topic for l in logs) for event,topic in zip(events,topics)}
    active = set()
    for log in sorted(expected_old,key=lambda l:(a.qty(l['blockNumber']),a.qty(l['transactionIndex']),a.qty(l['logIndex']))):
        if log['topics'][0] in grants:
            active.add(log['topics'][1])
        else:
            active.discard(log['topics'][1])
    a.need('old_owner_uncancelled_grants',sorted(active),[])
    return sorted(roles | standard)


def mapping_control(spec, target, role, word):
    if role not in MAPPING_CONTROL_ROLES.get(target, []):
        return False
    try:
        a.need('old_owner_mapping_getter',spec.get('hasRoleGetter'),'public-mapping')
    except a.Gate as fault:
        if fault.record['gate'] != 'old_owner_mapping_getter':
            raise
        return False
    a.need('old_owner_mapping_positive',word(target,'hasRole(bytes32,address)',ROLE_COMMUNITY,u.DEPLOYER),1)
    a.need('old_owner_mapping_negative',word(target,'hasRole(bytes32,address)',ROLE_COMMUNITY,OLD),0)
    return True


def token_deployment_community(rpc, pin, factory, token):
    block = pin['stateBlock']
    topic = a.keccak(TOKEN_EVENT)
    logs = bounded_history_logs(rpc, dict(address=factory, fromBlock='0x0', toBlock=block,
                                        topics=[topic, None, '0x'+token[2:].zfill(64)]))
    a.need('old_owner_xpnts_deployment_count', len(logs), 1)
    # Unreachable unless a gate above is deleted; the zero fallback keeps a deletion probe an assertion
    # failure (communityToToken(0) is never a token) instead of a TypeError, and never matches a real community.
    log = logs[0] if logs else {}
    topics = log.get('topics', [])
    number = log.get('blockNumber', block)
    canonical = rpc('eth_getBlockByNumber', [number, False])
    pin_block = rpc('eth_getBlockByNumber', [block, False])
    valid = (len(topics) == 3 and topics[0] == topic and
             topics[2] == '0x'+token[2:].zfill(64) and
             isinstance(topics[1], str) and len(topics[1]) == 66 and
             topics[1][:26] == '0x'+'0'*24 and
             log.get('address') == factory and not log.get('removed', False) and
             0 <= a.qty(number) <= a.qty(block) and canonical['number'] == number and
             log.get('blockHash') == canonical['hash'] and
             pin_block['number'] == block and pin_block['hash'] == pin['stateBlockHash'])
    a.need('old_owner_xpnts_deployment_log', valid, True)
    return '0x'+topics[1][-40:] if len(topics) == 3 else a.ZERO


def never_granted_recheck(rpc, pin, block):
    # One statement per gate: a missing pin field (None) and a changed membership both STOP under the gate's name.
    section = pin['oldOwnerIsolation']
    def reread(field, holder_of):
        rows = section.get(field)
        if not isinstance(rows, list):
            return rows, None, 'present'
        values = [u.uints(a.call(rpc,row['target'],'hasRole(bytes32,address)',row['role'],holder_of(row),block=block))
                  for row in rows]
        return rows, values, [[row['result']] for row in rows]
    rows, values, expected = reread('neverGrantedReads', lambda row: row['holder'])
    a.need('old_owner_never_granted_recheck',values,expected)
    # Built from the same audit and replayed at build time, so it is never empty for a valid pin.
    old_rows, old_values, old_expected = reread('oldRoleReads', lambda row: OLD)
    a.need('old_owner_role_recheck',old_values,old_expected)
    owner_values = [u.addr_word(u.uints(a.call(rpc, token, 'communityOwner()', block=block))[0])
                    for token in section['xpnts']]
    a.need('old_owner_xpnts_owner_recheck', all(v not in (OLD, OLD_TIMELOCK) for v in owner_values), True)
    return dict(communityOwners=owner_values,block=block,rows=rows,values=values,oldRows=old_rows,oldValues=old_values)


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


def decoded_arguments(output):
    """`cast decode-calldata --json`: stable 1.7.1 prints a bare list, the nightly an envelope."""
    if isinstance(output, list):
        return output
    a.need('old_owner_calldata_decode', isinstance(output, dict) and output.get('success') is True
           and output.get('errors') == [] and isinstance(output.get('data'), list), True)
    return output['data']


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
            values = decoded_arguments(json.loads(a.cast('decode-calldata','--json',sig,data)))
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
            a.need('old_owner_calldata_payload',len(values) > payload_index,True)
            payload = next(iter(values[payload_index:payload_index+1]),None)
            for child in payload if isinstance(payload,list) else [payload]:
                a.typed(child,a.HEXDATA,gate='old_owner_calldata_payload_shape')
                inspect(child,depth=depth+1)
        decoded.append(dict(signature=sig,arguments=values))
        return values
    for step in steps:
        for tx in [step['tx'],*step.get('variants',{}).values()]:
            a.need('old_owner_calldata_target',str(tx.get('to')).lower() != OLD,True)
            a.typed(tx['data'],a.HEXDATA)
            a.need('old_owner_calldata_bytes',OLD[2:] not in tx['data'][2:].lower(),True)
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
    """Hash the public host without the endpoint label or credentials."""
    from urllib.parse import urlsplit
    parsed = urlsplit(getattr(rpc,'url',''))
    a.need('old_owner_endpoint_host',parsed.hostname is not None,True)
    return a.keccak(parsed.hostname.lower())


def assert_endpoint_identities(identities):
    a.need('old_owner_endpoint_distinct',identities['primary'] != identities['secondary'],True)


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
