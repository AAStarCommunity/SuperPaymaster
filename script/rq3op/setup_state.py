"""Pinned state predicates and sequential setup-state projection (no sends)."""
import copy
import json
import manifest_exec as m

a, u = m.a, m.u


def predicate_key(p):
    return json.dumps({k:v for k,v in p.items() if k not in ('expected','delay')},sort_keys=True)


def observe(rpc,p):
    kind=p['kind']; target=p['target']
    if kind in ('code','codeHash'):
        code=u.code(rpc,target,'latest')
        return code if kind=='code' else a.keccak(code)
    if kind=='balance': return a.qty(rpc('eth_getBalance',[target,'latest']))
    if kind=='storage': return int(rpc('eth_getStorageAt',[target,p['slot'],'latest']),16)
    raw=a.call(rpc,target,p['signature'],*p.get('args',[]))
    if raw=='0x': return None
    words=u.uints(raw)
    if 'index' in p: return words[p['index']] if len(words)>p['index'] else None
    expected=p.get('expected',0)
    return words if isinstance(expected,list) else (int(raw,16) if isinstance(expected,int) else raw)


def precheck_state(rpc,step,completion=None):
    a.need('setup_predicates',bool(step.get('initial')) and bool(step.get('target')),True)
    reads={}
    def matches(predicates):
        good=True
        for p in predicates:
            key=predicate_key(p)
            if key not in reads: reads[key]=dict(predicate=p,observed=observe(rpc,p))
            good = (reads[key]['observed']==p.get('expected') and 'expected' in p) and good
        return good
    target=copy.deepcopy(step['target'])
    if completion is not None:
        for p in target:
            if p['kind']=='eta': p['expected']=int(completion['timestamp'])+p['delay']
    target_matches=matches(target)
    if completion is not None and target_matches:
        return dict(reads=list(reads.values()),status='already-satisfied')
    initial=matches(step['initial'])
    result=dict(reads=list(reads.values()))
    if completion is None and initial and not target_matches: return dict(result,status='initial')
    a.need('setup_state_STOP',dict(id=step['id'],**result), 'all target or all initial predicates')


class Projection:
    """Record pinned values, then advance only explicitly planned effects."""
    def __init__(self,rpc,block):
        self.rpc=lambda method,params:rpc(method,[*params[:-1],block])
        self.values={}; self.created=set()

    def put(self,p):
        self.values[predicate_key(p)]=copy.deepcopy(p['expected'])
        if p['kind']=='call':
            base={k:v for k,v in p.items() if k!='index'}
            if isinstance(p['expected'],list):
                for i,value in enumerate(p['expected']):
                    self.values[predicate_key(dict(base,index=i))]=value
            elif 'index' in p and predicate_key(base) in self.values:
                value=self.values[predicate_key(base)]
                if isinstance(value,list): value[p['index']]=p['expected']

    def before(self,p):
        key=predicate_key(p)
        if key in self.values: return self.values[key]
        if p['target'].lower() in self.created:
            signature=p.get('signature')
            if signature in ('autoAllowance(address,address)','userTotal(address)'):
                # xPNTsV2Base SP_DEFAULT_CAP / USER_TOTAL_DEFAULT.
                return [5000*10**18,0]
            if signature=='cachedPrice()': return 2**256-1
            a.need('setup_known_constructor_default',signature in (
                'balanceOf(address)','totalSupply()','allowance(address,address)',
                'debts(address)','renewalMode(address)','autoRenewUsed(address)',
                'cachedPriceTimestamp()'),True)
            return 0
        return observe(self.rpc,p)

    def prepare(self,sid,checks):
        target=copy.deepcopy(checks)
        initial=[]
        deployed={p['target'].lower() for p in target if p['kind'] in ('code','codeHash')}
        for address in deployed:
            p=dict(kind='code',target=address,expected='0x')
            a.need('setup_creation_absent',observe(self.rpc,p),'0x')
            initial.append(p)
        for p in target:
            if p['target'].lower() in deployed: continue
            before=copy.deepcopy(p)
            if p['kind']=='eta':
                before=dict(kind='call',target=p['target'],signature=p['signature'],args=[],expected=0)
            before['expected']=self.before(before)
            a.need('setup_initial_readable',before['expected'] is not None,True)
            initial.append(before)
        self.created.update(deployed)
        for p in target:
            if 'expected' in p:self.put(p)
        result=dict(initial=initial,target=target)
        return result
