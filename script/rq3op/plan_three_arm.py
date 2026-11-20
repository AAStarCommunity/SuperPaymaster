#!/usr/bin/env python3
"""Fresh DeployLive RQ3 plans. Only read RPCs; no signing or broadcasting.

DEPLOYLIVE_EXPECTED_CHAIN_ID is required (e.g. 10, 11155111, 11155420, or 31337 for local runs); unset stops.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import copy
import hashlib
import json
import re
from pinned_tools import PinnedTools as pinned_tools
from pvg_reserve import reserve_pvg
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'upgrade'))
import manifest_exec as m
from setup_state import Projection

a, u = m.a, m.u
ROOT = Path(__file__).resolve().parents[2]
CONFIG_ADDRESSES = ('superPaymaster','registry','aPNTs','xPNTsFactoryV2','globalTierSource',
    'entryPoint','simpleAccountFactory','genesisOperator','governanceOwner','timelockController',
    'gToken','staking','sbt','xPNTsTokenV2Impl','deployer')
MAX_FEE = int(json.loads((ROOT/'script/fee-limits.json').read_text())['MAX_FEE'])
SAMPLER_MIN_SPACING_SECONDS = 60
PVG_RULE = json.loads((Path(__file__).with_name('pvg-rule.json')).read_text())
RELEASE_EXPECTATION = json.loads((ROOT/'docs/release/rq3-runtime-expectations.json').read_text())


def check_entrypoint_pin(pin):
    keys={'version','codehash','runtime','source','corroboration','derivation','chainIds'}
    a.need('rq3_entrypoint_schema',isinstance(pin,dict) and set(pin)==keys and
           pin['version']=='0.7' and isinstance(pin['codehash'],str) and
           bool(re.fullmatch('0x[0-9a-f]{64}',pin['codehash'])) and
           all(isinstance(pin[k],str) and pin[k].strip() for k in ('runtime','source','corroboration','derivation')) and
           pin['chainIds']==[10,11155111,11155420,31337] and
           all(type(x) is int for x in pin['chainIds']),True)


def load_entrypoint_pin(path):
    pin=json.loads(Path(path).read_text())
    check_entrypoint_pin(pin)
    return pin


ENTRYPOINT_PIN = load_entrypoint_pin(Path(__file__).with_name('entrypoint-v07.json'))


def addresses_in(value):
    if isinstance(value,str):
        return {value.lower()} if re.fullmatch('0x[0-9a-fA-F]{40}',value) else set()
    if isinstance(value,dict):
        return set().union(*(addresses_in(x) for x in [*value.keys(),*value.values()]))
    if isinstance(value,list):return set().union(*(addresses_in(x) for x in value))
    return set()


SDK_DERIVATION = 'a0=ceil_div(maxCost*priceCap*1e18,10**priceDecimals*aPNTsPriceUSD); Amax=ceil_div(a0*(10000+protocolFeeBPS+validationBufferBPS),10000); Xmax=ceil_div(Amax*exchangeRate,1e18); N=sdkRuns*(4+sdkMaxOps); perUserCap=(N+PC_BETA)*Xmax; perUserFloor=(N+1)*Xmax'


def cost_bounds(maxCost,priceCap,priceDecimals,aPNTsPriceUSD,protocolFeeBPS,validationBufferBPS,exchangeRate):
    maxCost,priceCap,priceDecimals,aPNTsPriceUSD,protocolFeeBPS,validationBufferBPS,exchangeRate=map(int,
        (maxCost,priceCap,priceDecimals,aPNTsPriceUSD,protocolFeeBPS,validationBufferBPS,exchangeRate))
    a0=m.ceil_div(maxCost*priceCap*10**18,10**priceDecimals*aPNTsPriceUSD)
    amax=m.ceil_div(a0*(10000+protocolFeeBPS+validationBufferBPS),10000)
    return a0,amax,m.ceil_div(amax*exchangeRate,10**18)


def contains_float(value):
    if isinstance(value,float): return True
    if isinstance(value,dict): return any(contains_float(v) for v in value.values())
    if isinstance(value,list): return any(contains_float(v) for v in value)
    return False


SDK_PROVISIONAL='provisional: live cells not cleared to run until the SDK pre-sign cost cap merges'


def sdk_live(inputs,pc):
    fields={k:pc[k] for k in ('priceCap','priceDecimals','aPNTsPriceUSD','protocolFeeBPS','validationBufferBPS','exchangeRate')}
    a0,amax,xmax=cost_bounds(inputs['sdkMaxCostPerOp'],**fields)
    n=inputs['sdkRuns']*(4+inputs['sdkMaxOps'])
    a.need('rq3_sdk_uint256',all(0<=v<2**256 for v in (a0,amax,xmax,(n+m.PC_BETA)*xmax,(n+1)*xmax)),True)
    # Extra users retain the deployed token's 5,000 aPNTs allowance/total defaults.
    a.need('rq3_sdk_downstream_budget',(n+m.PC_BETA)*amax<=5000*10**18 and xmax<2**128,True)
    return dict(fields,maxCostPerOpWei=inputs['sdkMaxCostPerOp'],a0=a0,Amax=amax,Xmax=xmax,
        # Xmax is computed at priceCap, so a validation-time lock stays <= Xmax iff cachedPrice <= priceCap; the SDK
        # signs only while cachedPrice <= priceCap*(1-priceHeadroomBPS/10000) (rc.8 updatePrice has no per-update
        # deviation cap, so the price can move between signing and validation).
        priceHeadroomBPS=inputs['priceHeadroomBPS'],
        sdkRuns=inputs['sdkRuns'],sdkMaxOps=inputs['sdkMaxOps'],opsPerUser=n,
        perUserCap=(n+m.PC_BETA)*xmax,perUserFloor=(n+1)*xmax,
        # 'cleared' (exact literal; the SDK runner refuses any other value) only once the planner is given the
        # SDK commit on which the pre-sign cost cap is merged; that commit is recorded next to the status.
        status='cleared' if inputs.get('sdkCostCapCommit') else SDK_PROVISIONAL,
        sdkCostCapCommit=inputs.get('sdkCostCapCommit'),derivation=SDK_DERIVATION)


CALIBRATION_FIELDS = tuple(k for k in m.ARM_FIELDS if k != 'preVerification')


def check_calibration_fields(cal):
    a.need('rq3_calibration_pvg', all('preVerification' not in b for b in cal['arms'].values()), True)
    a.need('rq3_gas_fields', set(cal['arms']) == set(m.ARMS) and
           all(set(b) == set(CALIBRATION_FIELDS) for b in cal['arms'].values()), True)


READS = {'eth_chainId','eth_getBlockByNumber','eth_call','eth_getCode','eth_getStorageAt',
         'eth_getTransactionCount','eth_getBalance','eth_feeHistory','eth_maxPriorityFeePerGas'}


# eth_feeHistory fields the planner reads (priority from reward; oldestBlock recorded; baseFeePerGas kept for audit).
FEE_HISTORY_FIELDS=('oldestBlock','baseFeePerGas','reward')


def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def inside(path):
    path = Path(path).resolve()
    a.need('rq3_path', path.is_relative_to(ROOT), True)
    return path


def load(path): return json.loads(inside(path).read_text())


class ReadOnly:
    def __init__(self, rpc): self.rpc = rpc
    def __call__(self, method, params):
        a.need('rq3_readonly', method in READS, True)
        return self.rpc(method, params)


class Pair:
    """Two injected transports, hash-pinned state reads and a final reorg check."""
    def __init__(self, left, right):
        self.clients = [ReadOnly(left),ReadOnly(right)]
        self.head = self('eth_getBlockByNumber',['latest',False])
    def __call__(self, method, params):
        if method in ('eth_call','eth_getCode','eth_getStorageAt','eth_getBalance','eth_getTransactionCount') and params[-1] != 'pending':
            params = [*params[:-1],dict(blockHash=self.head['hash'],requireCanonical=True)]
        if method == 'eth_getTransactionCount' and params[-1] == 'pending':
            pinned = [client(method, [params[0], dict(blockHash=self.head['hash'], requireCanonical=True)])
                      for client in self.clients]
            pending = [client(method, params) for client in self.clients]
            for current, frozen in zip(pending, pinned):
                a.need('rq3_pending_nonce', a.qty(current), a.qty(frozen))
            a.need('rq3_rpc_agreement', pinned[0], pinned[1])
            return pinned[0]
        results = [client(method,params) for client in self.clients]
        if method == 'eth_feeHistory':
            # Providers differ in JSON number formatting of the float ratio fields (a full-blob block's
            # blobGasUsedRatio is 1.0 on one and 1 on another), and the strict typed comparison treats that
            # as disagreement. The planner consumes only these integer fields; compare exactly those.
            used=lambda r: {k:r.get(k) for k in FEE_HISTORY_FIELDS} if isinstance(r,dict) else r
            a.need('rq3_rpc_agreement',used(results[0]),used(results[1]))
            return used(results[0])
        a.need('rq3_rpc_agreement',results[0],results[1])
        return results[0]
    def finish(self):
        a.need('rq3_reorg',self('eth_getBlockByNumber',[self.head['number'],False])['hash'],self.head['hash'])


def factor(value):
    a.need('rq3_factor', isinstance(value,dict) and set(value)=={'numerator','denominator'} and
           all(type(v) is int and v>0 for v in value.values()), True)
    return value['numerator'],value['denominator']


def scale(value, rule):
    n,d = factor(rule)
    a.need('rq3_measurement',type(value) is int and value>=0,True)
    return m.ceil_div(value*n,d)


def fee_cap(base,priority,rule):
    n,d=factor(rule['factor'])
    a.need('rq3_fee_ceiling',n>=d and type(base) is int and base>=0 and
           type(priority) is int and priority>=0 and type(rule['ceiling']) is int and
           0<rule['ceiling']<=MAX_FEE,True)
    return min(m.ceil_div(base*n,d)+priority,rule['ceiling'])


def fees_within_rule(fees,rule,current):
    try:
        return (type(current) is int and current>=0 and
                fees['maxFeePerGas']==fee_cap(rule['baseFee'],fees['maxPriorityFeePerGas'],rule) and
                current+fees['maxPriorityFeePerGas']<=fees['maxFeePerGas'])
    except (a.Gate,KeyError,TypeError): return False


def normalized_addresses(cfg, inputs):
    cfg, inputs = copy.deepcopy(cfg), copy.deepcopy(inputs)
    def address(value):
        a.need('rq3_address',isinstance(value,str) and
               bool(re.fullmatch('0x[0-9a-fA-F]{40}',value)) and value.lower()!=a.ZERO,True)
        a.need('rq3_address',value==value.lower() or value==a.cast('to-check-sum-address',value),True)
        return value.lower()
    for key in CONFIG_ADDRESSES: cfg[key]=address(cfg[key])
    for key in ('experiment','genesis','bundler','verifyingSigner'): inputs[key]=address(inputs[key])
    for account in inputs['accounts']:
        for key in ('account','accountOwner','accountImplementation'):
            if key in account: account[key]=address(account[key])
    for field in ('taskRecipients','extraEndUsers'):
        entries=inputs.get(field)
        if isinstance(entries,list):
            for entry in entries:
                if isinstance(entry,dict) and isinstance(entry.get('address'),str):
                    entry['address']=entry['address'].lower()
    return m.fresh_addresses(cfg),m.fresh_addresses(inputs)


def expected_cap(value):
    valid=type(value) is int or (isinstance(value,str) and bool(re.fullmatch('[0-9]+',value)))
    a.need('rq3_cap_headroom',valid,True)
    # Bound the string before conversion, including Python's integer parsing limit.
    if isinstance(value,str):
        value=value.lstrip('0') or '0'
        a.need('rq3_cap_headroom',len(value)<=78,True)
    value=int(value)
    a.need('rq3_cap_headroom',0<=value<2**256,True)
    return value


def transaction_gas_cap(chain, block_limit):
    caps=json.loads(Path(__file__).with_name('tx-gas-caps.json').read_text())
    if str(chain) not in caps:
        return block_limit
    entry=caps[str(chain)]
    a.need('rq3_transaction_gas_cap_parameters',type(entry.get('gasLimit')) is int and
           entry['gasLimit']>0 and isinstance(entry.get('source'),str) and bool(entry['source'].strip()),True)
    return min(block_limit,entry['gasLimit'])


def transaction_gas(step_id, limit, cap):
    a.need('rq3_transaction_gas/'+step_id,limit<=cap,True)


def check_inputs(cfg, inputs, checker):
    a.need('rq3_commit',bool(re.fullmatch('[0-9a-f]{40}',str(cfg.get('commit','')))),True)
    a.need('rq3_checker_pass',checker.get('result')=='PASS' and bool(re.fullmatch(
        r'SUMMARY ([1-9][0-9]*) passed, 0 failed, \1 total',checker.get('summary',''))),True)
    stdout=checker.get('stdout','')
    a.need('rq3_checker_log',isinstance(stdout,str) and checker.get('exitCode')==0 and
           stdout.strip().endswith(checker['summary']) and not re.search(r'^FAIL\b',stdout,re.M) and
           bool(re.search(r'^(?:PASS|INFO-PASS)\b',stdout,re.M)),True)
    a.need('rq3_checker_binding',[checker.get('configSha256'),checker.get('commit')],[digest(cfg),cfg['commit']])
    cfg,inputs=normalized_addresses(cfg,inputs)
    a.need('rq3_uniform_factor','armFactors' not in inputs,True)
    for key in ('gasFactor','feeFactor'): factor(inputs[key])
    a.need('rq3_priority_rule',set(inputs.get('priorityRule',{}))=={'blocks','percentile'} and
           type(inputs['priorityRule']['blocks']) is int and 1<=inputs['priorityRule']['blocks']<=1024 and
           type(inputs['priorityRule']['percentile']) is int and 0<inputs['priorityRule']['percentile']<100,True)
    a.need('rq3_factor',inputs['gasFactor']['numerator']>=inputs['gasFactor']['denominator'],True)
    a.need('rq3_stake',type(inputs.get('stakeWei')) is int and inputs['stakeWei']>0 and
           type(inputs.get('unstakeDelay')) is int and 0<inputs['unstakeDelay']<2**32,True)
    a.need('rq3_genesis',inputs['genesis'],cfg['genesisOperator'])
    accounts=inputs['accounts']
    identities=[inputs['experiment'],inputs['genesis'],inputs['bundler'],inputs['verifyingSigner'],cfg['deployer'],
                cfg['governanceOwner'],cfg['timelockController']]
    identities += [v[k] for v in accounts for k in ('account','accountOwner')]
    a.need('rq3_identities',len(accounts)==3 and len(set(identities))==len(identities),True)
    for value in identities+[cfg[k] for k in CONFIG_ADDRESSES]: m.pc_address('rq3_address',value)
    a.need('rq3_interval',type(inputs.get('minTxInterval')) is int and 0<=inputs['minTxInterval']<2**48,True)
    # SP rate-limits per (operator, user): a minTxInterval above the sampler's guaranteed per-account spacing
    # would make SP reject planned rows. The RQ3 sampler guarantees >= 60 s (script/rq3/schedule.py:31 on
    # cc127/rq3-sampler-draft: 3*slot_period - max_elapsed >= 60); reconcile here if that guarantee changes.
    a.need('rq3_interval_vs_schedule',inputs['minTxInterval']<=SAMPLER_MIN_SPACING_SECONDS,True)
    extras=inputs.get('extraEndUsers',[])
    a.need('rq3_extra_endusers',isinstance(extras,list),True)
    excluded=addresses_in(cfg)|addresses_in({k:v for k,v in inputs.items() if k not in ('extraEndUsers','taskRecipients')})|{a.ZERO.lower(),m.DEAD.lower()}
    seen=excluded.copy()
    for entry in extras:
        a.need('rq3_extra_endusers',isinstance(entry,dict) and set(entry)=={'address','xAmount'},True)
        who,amount=entry['address'],entry['xAmount']
        a.need('rq3_extra_endusers',isinstance(who,str) and bool(re.fullmatch('0x[0-9a-fA-F]{40}',who)) and
               who.lower() not in seen and type(amount) is int and 0<amount<2**256,True)
        seen.add(who.lower())
    a.need('rq3_sdk_inputs',all(type(inputs.get(k)) is int and inputs[k]>0 for k in ('sdkRuns','sdkMaxOps','sdkMaxCostPerOp')) and inputs['sdkMaxOps']<=32 and inputs['sdkRuns']<=10000 and inputs['sdkMaxCostPerOp']<=10**18,True)
    a.need('rq3_sdk_old_alias', 'sdkPriceHeadroomBPS' not in inputs, True)
    a.need('rq3_sdk_price_headroom',type(inputs.get('priceHeadroomBPS')) is int and 0<=inputs['priceHeadroomBPS']<10000,True)
    commit=inputs.get('sdkCostCapCommit')
    a.need('rq3_sdk_cost_cap_commit',commit is None or (isinstance(commit,str) and bool(re.fullmatch('[0-9a-f]{40}',commit))),True)
    recipients=inputs.get('taskRecipients')
    a.need('rq3_task_recipients',isinstance(recipients,list),True)
    seen=excluded.copy()
    for entry in recipients:
        a.need('rq3_task_recipients',isinstance(entry,dict) and set(entry)=={'address','amount'},True)
        who,amount=entry['address'],entry['amount']
        a.need('rq3_task_recipients',isinstance(who,str) and bool(re.fullmatch('0x[0-9a-fA-F]{40}',who)) and
               who.lower() not in seen and type(amount) is int and 301<=amount<2**256,True)
        seen.add(who.lower())
    return cfg,inputs



def sp_postop_limit(measured, gas_factor, minimum):
    """DSR 2026-11-18 ruling (b): max(measured × gasFactor, SP's on-chain minPostOpGas).

    The floor is imposed by the system under test, so every real SP-arm transaction must meet it.
    When it applies, EntryPoint's unused-gas penalty is part of the SP arm's cost; the returned
    record (floorApplied) is copied into every data row so the paper can report it."""
    scaled=scale(measured,gas_factor)
    a.need('rq3_postop_floor',type(minimum) is int and minimum>0 and minimum>=RELEASE_EXPECTATION['GP_MINPOST_MIN'],True)
    limit=max(scaled,minimum)
    return limit, dict(measurement=measured,factor=gas_factor,scaled=scaled,chainFloor=minimum,
                       limit=limit,floorApplied=limit>scaled)


def worksheet(pin,c,ctx,n,cal,gas_factor,fee,priority,gas_tuple,head):
    p=pin['phaseC']; facts=m.phase_c_pin_gates(pin,c,context=ctx)
    bounds={arm:{k:scale(v,gas_factor) for k,v in cal['arms'][arm].items()} for arm in m.ARMS}
    a.need('rq3_gas_fields',all(set(b)==set(CALIBRATION_FIELDS) for b in bounds.values()),True)
    # VerifyingPaymaster has no postOp (empty context; EntryPoint never calls it): its measured postOp
    # is structurally zero and must stay exactly zero. Every other bound must be positive.
    a.need('rq3_structural_zero',cal['arms']['VPM']['postOp'],0)
    a.need('rq3_gas_bounds',all((0<v or (arm,k)==('VPM','postOp')) and v<2**128 for arm,b in bounds.items() for k,v in b.items()) and gas_tuple[0]>0,True)
    bounds['SP']['postOp'],postop_rule=sp_postop_limit(cal['arms']['SP']['postOp'],gas_factor,gas_tuple[0])
    task_data=a.calldata('execute(address,uint256,bytes)', m.DEAD, 0,
                         a.calldata('transfer(address,uint256)', m.DEAD, m.PC_TASK_UNIT))
    lengths={arm:dict(initCode=0,callData=(len(task_data)-2)//2,
                     paymasterAndData={'SP':125,'VPM':181,'TPM':52}[arm],signature=65) for arm in m.ARMS}
    reserves={arm:reserve_pvg(lengths[arm]) for arm in m.ARMS}
    maxima={arm:(sum(v for k,v in b.items() if k != 'outer')+reserves[arm])*fee for arm,b in bounds.items()}
    price_a,fee_b=p['sp']['aPNTsPriceUSD'],p['sp']['protocolFeeBPS']
    a0,amax,xmax=cost_bounds(maxima['SP'],m.PC_PRICE_CAP,m.PC_PRICE_DECIMALS,price_a,fee_b,m.PC_VALIDATION_BUFFER_BPS,m.PC_RATE)
    a.need('C_amax_cap',amax<=m.PC_AMAX_CAP,True)
    qmax=maxima['TPM']+m.PC_TPM_REFUND*fee
    prep={k:scale(cal['ownerPreparation'][k],gas_factor) for k in m.OWNER_PREPARATION}
    maintenance=[dict(name=x['name'],gas=scale(x['gas'],gas_factor)) for x in cal['ownerMaintenance']]
    aux=[dict(name=x['name'],gas=scale(x['gas'],gas_factor)) for x in cal['bundlerMaintenance']]
    target_o=sum(prep.values())*fee+sum(x['gas'] for x in maintenance)*fee
    target_b=n*fee*sum(b['outer'] for b in bounds.values())+fee*sum(x['gas'] for x in aux)+m.PC_BUNDLER_BETA
    sources={arm:{k:dict(source=cal['source'],measurement=cal['arms'][arm].get(k),factor=gas_factor,
                        limit=v,block=head) for k,v in b.items()} for arm,b in bounds.items()}
    for arm in m.ARMS:
        bounds[arm]['preVerification'] = None
        sources[arm]['preVerification'] = dict(copy.deepcopy(PVG_RULE), reserve=reserves[arm], fixedLengths=lengths[arm])
    sources['SP']['postOp'].update(rule='max(measured*gasFactor, minPostOpGas)',target=ctx['SP'],**postop_rule)
    # DSR 2026-11-18: record the structural zero explicitly instead of a scaled limit.
    sources['VPM']['postOp'].update(rule='structural zero: VerifyingPaymaster has no postOp (empty context)',limit=0)
    return dict(attempts=n,feeCap=fee,priorityCap=priority,priceCap=m.PC_PRICE_CAP,priceDecimals=m.PC_PRICE_DECIMALS,
        exchangeRate=m.PC_RATE,betaMultiplier=m.PC_BETA,bundlerBeta=m.PC_BUNDLER_BETA,allowanceCap=m.PC_CAP_L,
        spRenew=False,spPostOp=bounds['SP']['postOp'],spPostOpRule=postop_rule,gasTuple=gas_tuple,gasSources=sources,bounds=bounds,
        pvgReserve=reserves,pvgLengths=lengths,maxPrefund=maxima,outerBound={arm:b['outer'] for arm,b in bounds.items()},aPNTsPriceUSD=price_a,
        protocolFeeBPS=fee_b,validationBufferBPS=m.PC_VALIDATION_BUFFER_BPS,A0=a0,Amax=amax,operatorTarget=(m.PC_ATTEMPTS+m.PC_BETA)*amax,
        operatorTopUp=0,cappedMint=0,cappedSupplyBefore=p['capped']['totalSupply'],Xmax=xmax,
        userTarget=(n+m.PC_BETA)*xmax,entryPointTargets={arm:(n+1+m.PC_BETA)*v for arm,v in maxima.items()},
        entryPointBefore=dict(SP=0,VPM=0,TPM=0),entryPointTopUps={},Qmax=qmax,feeTokenTarget=(n+m.PC_BETA)*qmax,
        taskSender=3*n*m.PC_TASK_UNIT+m.PC_TASK_UNIT,taskRecipient=m.PC_TASK_UNIT,
        bundlerMaintenance=aux,bundlerTarget=target_b,bundlerTopUp=m.positive(target_b-p['bundler']['balance']),
        ownerPreparation=prep,ownerMaintenance=maintenance,ownerMaintenanceWei=sum(x['gas'] for x in maintenance)*fee,
        ownerTarget=target_o,ownerTopUp=m.positive(target_o-p['owner']['balance']),
        endUserStake=facts['minStake'],endUserTicket=facts['ticketPrice'],accountExists=facts['accountExists'],
        accountMember=facts['member'],token=dict(zip(('name','symbol','communityName','communityENS'),m.PC_TOKEN)),
        treasury=ctx['safe'],recipient=m.DEAD,f1Provenance='F1TestToken (T/Q) and F1Oracle comparator fixtures permitted on chains 10, 11155111, 11155420 and 31337; not protocol contracts')


def require_f1_chain(chain):
    # Comparator fixture permission is independent of the EntryPoint deployment pin.
    a.need('rq3_f1_chain', chain in (10, 11155111, 11155420, 31337), True)


def build(cfg,inputs,rpc,checker,cal,baselines):
    # Pure assembly layer; generate() authenticates files, checker and deployment before calling.
    check_entrypoint_pin(ENTRYPOINT_PIN)
    config_digest=digest(cfg); inputs_digest=digest(inputs)
    cfg,inputs=check_inputs(cfg,inputs,checker)
    check_calibration_fields(cal)
    limit_gas=cal.get('setup',{}).get('C3.limits')
    a.need('rq3_limits_calibration',type(limit_gas) is int and limit_gas>0,True)
    for i in range(len(inputs['taskRecipients'])):
        value=cal.get('setup',{}).get('C11.extra.'+str(i))
        a.need('rq3_task_calibration',type(value) is int and value>0,True)
    rpc=ReadOnly(rpc)
    chain=a.qty(rpc('eth_chainId',[]))
    a.need('rq3_chain',chain in ENTRYPOINT_PIN['chainIds'],True)
    require_f1_chain(chain)
    a.need('rq3_checker_chain',checker['chainId'],chain)
    head=a.block_data(rpc,'latest'); block=head['number']
    gas_cap=transaction_gas_cap(chain,a.qty(head['gasLimit']))
    ep_hash=a.keccak(u.code(rpc,cfg['entryPoint'],block))
    a.need('rq3_entrypoint_v07',ep_hash,ENTRYPOINT_PIN['codehash'])
    ep_pin=dict(ENTRYPOINT_PIN,address=cfg['entryPoint'],blockHash=head['hash'])
    extras=inputs.get('extraEndUsers',[])
    for j,entry in enumerate(extras):
        for suffix in ('approve','role','mint'):
            value=cal['setup'].get(f'C8.extra.{j}.{suffix}')
            a.need('rq3_extra_calibration',type(value) is int and value>0,True)
    purposes={e['address']:['task recipient'] for e in inputs['taskRecipients']}
    for entry in extras:
        key=next((who for who in purposes if who.lower()==entry['address'].lower()),entry['address'])
        purposes.setdefault(key,[]).append('RQ2 live E2E')
    a.need('rq3_calibration',cal['source'].get('kind') in ('measured','estimate') and
           bool(re.fullmatch('[0-9a-f]{64}',cal['source'].get('evidenceSha256',''))) and
           bool(re.fullmatch('0x[0-9a-f]{64}',cal['source'].get('blockHash',''))),True)
    # Priority follows the price keeper's rule: the median, over the last N blocks, of each block's
    # p-th percentile reward from eth_feeHistory. The node's own estimate is recorded as a control only.
    rule=inputs['priorityRule']
    history=rpc('eth_feeHistory',[hex(rule['blocks']),block,[rule['percentile']]])
    rewards=sorted(a.qty(r[0]) for r in history.get('reward',[]) if r)
    a.need('rq3_priority_history',len(rewards),rule['blocks'])
    priority=rewards[(len(rewards)-1)//2]
    a.need('rq3_priority_zero',priority>0,True)
    # Nonhistorical node estimates are excluded so historical reconstruction is deterministic.
    fee=fee_cap(a.qty(head['baseFeePerGas']),priority,dict(factor=inputs['feeFactor'],ceiling=inputs['feeCeiling']))
    # Cap the base-fee rule; reject a cap that cannot cover the pinned base fee and priority.
    a.need('rq3_fee_ceiling',type(inputs['feeCeiling']) is int and 0<priority and a.qty(head['baseFeePerGas'])+priority<=fee<=inputs['feeCeiling']<=MAX_FEE,True)
    ctx=dict(operator=inputs['genesis'],experiment=inputs['experiment'],SP=cfg['superPaymaster'],safe=cfg['governanceOwner'],
        registry=cfg['registry'],accountFactory=cfg['simpleAccountFactory'],treasury=cfg['governanceOwner'],
        approver=cfg['governanceOwner'],fresh=True,stakeWei=inputs['stakeWei'],stakeDelay=inputs['unstakeDelay'])
    word=lambda target,sig,*args:a.word(rpc,target,sig,*args,block=block)
    gas=u.uints(a.call(rpc,ctx['SP'],'gasParams()',block=block))
    a.need('rq3_gas_pending',len(gas)==9 and gas[4:]==[0]*5,True)
    for key,sig in [('trackedBefore','totalTrackedBalance()'),('revenueBefore','protocolRevenue()')]: ctx[key]=word(ctx['SP'],sig)
    ctx['backingBefore']=word(cfg['aPNTs'],'balanceOf(address)',ctx['SP'])
    a.need('rq3_fresh_accounting',[ctx['trackedBefore'],ctx['revenueBefore'],ctx['backingBefore']],[0,0,0])
    a.need('rq3_sp_owner',word(ctx['SP'],'owner()'),int(cfg['timelockController'],16))
    a.need('rq3_unpaused',word(ctx['SP'],'paused()'),0)
    a.need('rq3_factory_fresh',[word(cfg['xPNTsFactoryV2'],'getDeployedCount()'),
        word(cfg['xPNTsFactoryV2'],'getTokenAddress(address)',ctx['operator'])],[0,0])
    threshold=word(ctx['safe'],'getThreshold()'); a.need('rq3_safe_threshold',threshold>=2,True)
    safe_nonce=word(ctx['safe'],'nonce()')
    delay=word(cfg['timelockController'],'getMinDelay()'); a.need('rq3_timelock_delay',delay,48*3600)
    ep_info=u.uints(a.call(rpc,cfg['entryPoint'],'getDepositInfo(address)',ctx['SP'],block=block))
    a.need('rq3_stake_not_unlocking',ep_info[4],0)
    senders={}
    for label,who in [('deployer',ctx['experiment']),('genesis',ctx['operator'])]:
        nonce=a.nonce(rpc,who,block); a.need('rq3_pending_nonce',a.nonce(rpc,who,'pending'),nonce)
        a.need('rq3_eoa',u.code(rpc,who,block),'0x')
        senders[label]=dict(address=who,nonce=nonce,balance=a.qty(rpc('eth_getBalance',[who,block])))
    counts=[m.PC_ATTEMPTS//3+int(i<m.PC_ATTEMPTS%3) for i in range(3)]
    pins=[]; worksheets=[]; cs=[]
    for account,n in zip(inputs['accounts'],counts):
        c=dict(account,bundler=inputs['bundler'],verifyingSigner=inputs['verifyingSigner'],rehearsal=cal)
        pin=dict(capped=cfg['aPNTs'],immutables=dict(entryPoint=cfg['entryPoint']),senders=copy.deepcopy(senders),
                 block=block,blockHash=head['hash'],stake=ep_info[2],stakeDelay=ep_info[3],entryPointDeposit=ep_info[0])
        pin['phaseC']=m.fresh_addresses(m.collect_phase_c(rpc,block,{'data':{'phaseC':c}},pin,context=ctx))
        p=pin['phaseC']; a.need('rq3_genesis_unconfigured',p['sp']['deployerOperator'][:4],[0]*4)
        # Three identical pricing/cap reads must refer to the same deployment state.
        if pins: a.need('rq3_shared_pin',[p[k] for k in ('sp','capped','endUser')],[pins[0]['phaseC'][k] for k in ('sp','capped','endUser')])
        ws=worksheet(pin,c,ctx,n,cal,inputs['gasFactor'],fee,priority,gas,head)
        pins.append(pin); worksheets.append(ws); cs.append(c)
    first=worksheets[0]; p=pins[0]['phaseC']
    sdk=sdk_live(inputs,first)
    for entry in extras:
        a.need('rq3_sdk_amount',sdk['perUserFloor']<=entry['xAmount']<=sdk['perUserCap'],True)
    operator_top=first['operatorTarget']; mint=m.positive(operator_top-p['capped']['deployerBalance'])
    a.need('rq3_cap_headroom',p['capped']['totalSupply']+mint<=p['capped']['cap'] and p['capped']['cap']==expected_cap(cfg['expectedCap']),True)
    tickets=sum(w['endUserStake']+w['endUserTicket'] for w in worksheets if not w['accountMember'])
    extra_tickets=len(extras)*(first['endUserStake']+first['endUserTicket'])
    tickets+=extra_tickets
    genesis_held=p['endUser']['deployerGToken']
    transfer=m.positive(tickets-genesis_held)
    a.need('rq3_safe_gtoken',word(cfg['gToken'],'balanceOf(address)',ctx['safe'])>=transfer,True)
    ep_targets={arm:sum(w['entryPointTargets'][arm] for w in worksheets) for arm in m.ARMS}
    bundler_target=sum(w['bundlerTarget'] for w in worksheets)-2*m.PC_BUNDLER_BETA
    counters={k:v['nonce'] for k,v in senders.items()}; all_steps=[]; plans={}; comparators={}; x_supply=0; gt_balance=p['endUser']['deployerGToken']+transfer
    projection=Projection(rpc,block)
    projection.put(dict(kind='balance',target=inputs['bundler'],expected=p['bundler']['balance']))
    projection.put(m.predicate(ctx['SP'],'operators(address)',[ctx['operator']],p['sp']['deployerOperator']))
    # Safe prerequisites execute before the local C steps.
    projection.put(m.word_pred(cfg['aPNTs'],'balanceOf(address)',p['capped']['deployerBalance']+mint,ctx['operator']))
    projection.put(m.word_pred(cfg['gToken'],'balanceOf(address)',gt_balance,ctx['operator']))
    projection.put(m.predicate(cfg['entryPoint'],'getDepositInfo(address)',[ctx['SP']],
                             [ep_info[0],1,ep_info[2]+inputs['stakeWei'],inputs['unstakeDelay'],0]))
    for i,(pin,c,ws) in enumerate(zip(pins,cs,worksheets)):
        projection.put(dict(kind='balance',target=c['accountOwner'],expected=pin['phaseC']['owner']['balance']))
        ws.update(operatorTopUp=operator_top if i==0 else 0,cappedMint=mint if i==0 else 0,
                  bundlerTarget=bundler_target,bundlerTopUp=m.positive(bundler_target-p['bundler']['balance']) if i==0 else 0)
        ws['entryPointTargets']=dict(ep_targets)
        ws['entryPointBefore']={arm:(ep_info[0] if arm=='SP' else 0) if i==0 else max(ep_info[0] if arm=='SP' else 0,ep_targets[arm]) for arm in m.ARMS}
        ws['entryPointTopUps']={arm:m.positive(ws['entryPointTargets'][arm]-ws['entryPointBefore'][arm]) for arm in m.ARMS}
        pin['phaseC']['endUser']['deployerGToken']=gt_balance
        local_ctx=dict(ctx,xSupplyBefore=x_supply,comparators=comparators); local_steps=[]
        counters['owner']=pin['phaseC']['owner']['nonce']
        def add(sid,target,data,checks,sender='deployer',value=0,**extra):
            # Operator/community setup is shared. Comparator deployments remain per S.
            if i and sid in ('C3.deploy','C3.configure','C3.limits','C11.R','C15','C16.vpm','C16.tpm'):
                return {'tx':{'chainId':hex(chain)}}
            if sid.startswith(('C2.','C3.','C8.extra.')) or sid in ('C6','C7','C8'): sender='genesis'
            who=c['accountOwner'] if sender=='owner' else senders[sender]['address']
            measured=cal['setup'][sid]
            limit=ws['ownerPreparation'][sid] if sender=='owner' else scale(measured,inputs['gasFactor'])
            tx=dict(to=target,data=data,value=hex(value),nonce=hex(counters[sender]),chainId=hex(chain),
                    maxFeePerGas=hex(fee),maxPriorityFeePerGas=hex(priority),gas=hex(limit),**{'from':who})
            state=projection.prepare(sid,checks)
            if state['initial']==state['target']: return {'tx':{'chainId':hex(chain)}}
            counters[sender]+=1
            step=dict(**state,id=sid,sender=sender,tx=tx,readbacks=checks,**extra,
                      gasEvidence=dict(source=cal['source'],measurement=cal['ownerPreparation'][sid] if sender=='owner' else measured,
                                       factor=inputs['gasFactor'],limit=limit,block=head))
            local_steps.append(step)
            if sid=='C3.configure':
                add('C3.limits',ctx['SP'],a.calldata('setOperatorLimits(uint48)',inputs['minTxInterval']),
                    [m.word_pred(ctx['SP'],'operators(address)',inputs['minTxInterval'],ctx['operator'],index=m.OP['minTxInterval'])],phase='C')
            return step
        pc,_=m.build_phase_c(pin=pin,inputs=c,context=local_ctx,chain_id=chain,commit=cfg['commit'],
            factory=cfg['xPNTsFactoryV2'],tier=cfg['globalTierSource'],ep=cfg['entryPoint'],
            addresses={'xPNTsTokenV2':cfg['xPNTsTokenV2Impl']},counters=counters,safe_n=safe_nonce,
            steps=local_steps,add=add,sp_deposit_before=ep_info[0],sp_stake=ep_info[2]+inputs['stakeWei'],
            worksheet=ws,baselines=baselines,policy='fresh',
            task_recipients=inputs['taskRecipients'] if i==0 else ())
        pc['minTxInterval']=inputs['minTxInterval']
        pc['operatorAfter']=list(pc['operatorAfter'])
        pc['operatorAfter'][m.OP['minTxInterval']]=inputs['minTxInterval']
        if i==0:
            for j,entry in enumerate(extras):
                who=entry['address']; ticket=ws['endUserStake']+ws['endUserTicket']
                def extra(suffix,target,sig,args,checks):
                    return add(f'C8.extra.{j}.{suffix}',target,a.calldata(sig,*args),checks,phase='C',purpose='RQ2 live E2E')
                extra('approve',cfg['gToken'],'approve(address,uint256)',(cfg['staking'],ticket),
                      [m.word_pred(cfg['gToken'],'allowance(address,address)',ticket,ctx['operator'],cfg['staking'])])
                extra('role',cfg['registry'],'safeMintForRole(bytes32,address,bytes)',
                      (m.role_id('ENDUSER'),who,a.cast('abi-encode','c(address,uint256)',ctx['operator'],ws['endUserStake'])),
                      [m.word_pred(cfg['registry'],'hasRole(bytes32,address)',1,m.role_id('ENDUSER'),who),
                       m.word_pred(cfg['sbt'],'balanceOf(address)',1,who),
                       m.word_pred(cfg['sbt'],'verifyCommunityMembership(address,address)',1,who,ctx['operator']),
                       m.word_pred(cfg['gToken'],'allowance(address,address)',0,ctx['operator'],cfg['staking']),
                       m.word_pred(cfg['gToken'],'balanceOf(address)',
                           gt_balance-(0 if ws['accountMember'] else ticket)-(j+1)*ticket,ctx['operator'])])
                extra('mint',pc['addresses']['X'],'mint(address,uint256)',(who,entry['xAmount']),
                      [m.word_pred(pc['addresses']['X'],'balanceOf(address)',entry['xAmount'],who),
                       m.word_pred(pc['addresses']['X'],'totalSupply()',ws['userTarget']+sum(e['xAmount'] for e in extras[:j+1]))])
            x_supply+=sum(e['xAmount'] for e in extras)
            gt_balance-=extra_tickets
        a.need('C_task_token_distinct', all(pc['addresses']['T'].lower()!=token.lower() for token in
               (pc['addresses']['X'],pc['addresses']['Q'],cfg['aPNTs'])), True)
        pc['addresses']['SP']=ctx['SP']
        comparators={key:pc['addresses'][label] for key,label in [('T','T'),('Q','Q'),('oracle','oracle'),('VerifyingPaymaster','VPM'),('TokenPaymaster','TPM')]}
        pc['fundingPolicy']=dict(operatorDeposit='shared',attemptAllocation=counts,owner='separate per S',
                                 remainder='first S receives indivisible remainder')
        pc['feeRule']=dict(baseFee=a.qty(head['baseFeePerGas']),factor=inputs['feeFactor'],ceiling=inputs['feeCeiling'],block=head,
                          priority=dict(rule='eth_feeHistory median of per-block percentile',blocks=rule['blocks'],
                                        percentile=rule['percentile'],newestBlock=block,oldestBlock=history.get('oldestBlock'),
                                        rewards=rewards,value=priority))
        plan=dict(entryPointPin=ep_pin,extraEndUsers=copy.deepcopy(extras),recipientPurposes=purposes,planIndex=i,taskRecipients=copy.deepcopy(inputs['taskRecipients']),schema='rq3-deploylive-1',deploymentContext=ctx,chainId=chain,commit=cfg['commit'],configSha256=config_digest,
                  checker=structured_checker(checker),pin=pin,phaseC=pc,steps=local_steps,addresses=address_table(cfg),
                  externalInputs={'sha256':inputs_digest,'data':{'phaseC':c,'sampled':[ctx['operator']]}},
                  gasPolicy=dict(factor=inputs['gasFactor'],frozen=True,source=cal['source']))
        plans[c['account']]=plan
        all_steps.extend(dict(s,id=str(i)+'/'+s['id']) for s in local_steps)
        x_supply+=ws['userTarget']
        if not ws['accountMember']: gt_balance-=ws['endUserStake']+ws['endUserTicket']
    # No Safe signing here: output inner calls, including schedule/execute for a value-bearing batch.
    target=ctx['SP']; data=a.calldata('addStake(uint32)',inputs['unstakeDelay']); salt=a.keccak('rq3/'+config_digest+'/'+inputs_digest)
    targets='['+target+']'; values='['+str(inputs['stakeWei'])+']'; datas='['+data+']'
    encoded=a.cast('abi-encode','c(address[],uint256[],bytes[],bytes32,bytes32)',targets,values,datas,a.ZERO32,salt)
    op=dict(targets=[target],values=[inputs['stakeWei']],data=[data],predecessor=a.ZERO32,salt=salt,id=a.keccak(encoded),delay=delay)
    def safe(sid,to,data,value=0):
        limit=scale(cal['safeTransactions'][sid],inputs['gasFactor'])
        a.need('rq3_safe_gas',limit>0,True)
        return dict(id=sid,**{'from':ctx['safe']},to=to,data=data,value=hex(value),
                    gas=hex(limit),maxFeePerGas=hex(fee),maxPriorityFeePerGas=hex(priority),requiredSignatures=threshold)
    safe_txs=[safe('C1',cfg['aPNTs'],a.calldata('mint(address,uint256)',ctx['operator'],mint)),
              safe('GToken.transfer',cfg['gToken'],a.calldata('transfer(address,uint256)',ctx['operator'],transfer)),
              safe('SP.stake.schedule',cfg['timelockController'],a.calldata('scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)',targets,values,datas,a.ZERO32,salt,delay)),
              safe('SP.stake.execute',cfg['timelockController'],a.calldata('executeBatch(address[],uint256[],bytes[],bytes32,bytes32)',targets,values,datas,a.ZERO32,salt),inputs['stakeWei'])]
    safe_states=[
        ([m.word_pred(cfg['aPNTs'],'balanceOf(address)',p['capped']['deployerBalance'],ctx['operator']),
          m.word_pred(cfg['aPNTs'],'totalSupply()',p['capped']['totalSupply'])],
         [m.word_pred(cfg['aPNTs'],'balanceOf(address)',p['capped']['deployerBalance']+mint,ctx['operator']),
          m.word_pred(cfg['aPNTs'],'totalSupply()',p['capped']['totalSupply']+mint)]),
        ([m.word_pred(cfg['gToken'],'balanceOf(address)',genesis_held,ctx['operator']),
          m.word_pred(cfg['gToken'],'balanceOf(address)',word(cfg['gToken'],'balanceOf(address)',ctx['safe']),ctx['safe'])],
         [m.word_pred(cfg['gToken'],'balanceOf(address)',genesis_held+transfer,ctx['operator']),
          m.word_pred(cfg['gToken'],'balanceOf(address)',word(cfg['gToken'],'balanceOf(address)',ctx['safe'])-transfer,ctx['safe'])]),
        ([m.word_pred(cfg['timelockController'],'getTimestamp(bytes32)',0,op['id'])],
         [dict(kind='eta',target=cfg['timelockController'],signature='getTimestamp(bytes32)',args=[op['id']],delay=delay)]),
        ([m.word_pred(cfg['timelockController'],'isOperationReady(bytes32)',1,op['id']),
          m.predicate(cfg['entryPoint'],'getDepositInfo(address)',[ctx['SP']],ep_info)],
         [m.word_pred(cfg['timelockController'],'getTimestamp(bytes32)',1,op['id']),
          m.predicate(cfg['entryPoint'],'getDepositInfo(address)',[ctx['SP']],
                      [ep_info[0],1,ep_info[2]+inputs['stakeWei'],inputs['unstakeDelay'],0])])]
    for step,(initial,target) in zip(safe_txs,safe_states):
        step.update(initial=initial,target=target)
        step['operation']=0
    safe_txs=[s for s in safe_txs if s['initial']!=s['target']]
    # Funding cannot be accepted merely because value fits: include all frozen setup gas.
    for label,entry in senders.items():
        required=sum(a.qty(s['tx']['value'])+a.qty(s['tx']['gas'])*fee for s in all_steps if s['sender']==label)
        a.need('rq3_setup_budget',entry['balance']>=required,True)
    if hasattr(rpc.rpc,'finish'): rpc.rpc.finish()
    pcs=[plan['phaseC'] for plan in plans.values()]
    a.need('rq3_shared_task',len({pc['addresses']['T'] for pc in pcs})==1 and
           len({pc['taskCallData'] for pc in pcs})==1,True)
    for pc in pcs:
        a.need('rq3_sdk_pricing',all(sdk[k]==pc[k] for k in ('priceCap','priceDecimals','aPNTsPriceUSD','protocolFeeBPS','validationBufferBPS','exchangeRate')),True)
    excluded=addresses_in(cfg)|addresses_in({k:v for k,v in inputs.items() if k not in ('extraEndUsers','taskRecipients')})|set().union(*(addresses_in(pc['addresses']) for pc in pcs))|{a.ZERO.lower(),m.DEAD.lower()}
    for entry in extras:
        a.need('rq3_extra_derived_exclusion',entry['address'].lower() not in excluded,True)
        a.need('rq3_extra_role_absent',a.word(rpc,cfg['registry'],'hasRole(bytes32,address)',
               m.role_id('ENDUSER'),entry['address'],block=block),0)
        if u.code(rpc,entry['address'],block)=='0x':
            print(f"INFO extraEndUser {entry['address']} has no code; sponsor-funded RQ2 live E2E",file=sys.stderr)
    shared=dict(sdkLive=sdk,extraEndUsersXTotal=sum(e['xAmount'] for e in extras),extraEndUsers=copy.deepcopy(extras),recipientPurposes=purposes,T=pcs[0]['addresses']['T'],R=m.DEAD,SP=ctx['SP'],chainId=chain,
                commit=cfg['commit'],configSha256=config_digest,taskCallData=pcs[0]['taskCallData'],
                taskRecipients=copy.deepcopy(inputs['taskRecipients']),experiment=inputs['experiment'])
    for step in all_steps: transaction_gas(step['id'],a.qty(step['tx']['gas']),gas_cap)
    for step in safe_txs: transaction_gas('Safe/'+step['id'],a.qty(step['gas']),gas_cap)
    for i,pc in enumerate(pcs):
        for sid,limit in pc['ownerPreparation'].items(): transaction_gas(f'{i}/'+sid,limit,gas_cap)
        for group in ('ownerMaintenance','bundlerMaintenance'):
            for step in pc[group]: transaction_gas(f'{i}/{group}/'+step['name'],step['gas'],gas_cap)
        for arm,bounds in pc['bounds'].items(): transaction_gas(f'{i}/{arm}/handleOps',bounds['outer'],gas_cap)
    funding=funding_table(all_steps,safe_txs,rpc,block,pcs,mint,transfer,cfg)
    funding['genesisGToken']=dict(address=ctx['operator'],stakeAndTickets=tickets,extraEndUsers=extra_tickets,
                                  held=genesis_held,safeTransfer=transfer)
    x=pcs[0]['addresses']['X'];funding['tokens'][x]+=sum(e['xAmount'] for e in extras)
    def bounded(v):
        if type(v) is int: return 0<=v<2**256
        if isinstance(v,dict): return all(bounded(x) for x in v.values())
        if isinstance(v,list): return all(bounded(x) for x in v)
        return True
    a.need('rq3_funding_uint256',bounded(funding) and bounded(shared),True)
    return dict(shared=shared,plans=plans,steps=all_steps,safeTransactions=safe_txs,timelockOperation=op,
                configSha256=config_digest,commit=cfg['commit'],chainId=chain,checker=structured_checker(checker),funding=funding)


def pre_send(rpc,plan,step=None):
    """Call before EVERY setup send and attempt; never re-estimate frozen limits."""
    rpc=ReadOnly(rpc); head=a.block_data(rpc,'latest'); block=head['number']; pc=plan['phaseC']; sp=pc['addresses']['SP']
    gas=u.uints(a.call(rpc,sp,'gasParams()',block=block))
    a.need('C_gas_tuple',gas,pc['gasTuple'])
    stake=u.uints(a.call(rpc,plan['addresses']['entryPoint'],'getDepositInfo(address)',sp,block=block))
    a.need('rq3_send_stake',stake[1]==1 and stake[2]==plan['pin']['stake']+plan['deploymentContext']['stakeWei'] and
           stake[3]==plan['deploymentContext']['stakeDelay'] and stake[4]==0,True)
    a.need('rq3_send_chain',a.qty(rpc('eth_chainId',[])),plan['chainId'])
    a.need('rq3_send_fee',fees_within_rule(dict(maxFeePerGas=pc['feeCap'],maxPriorityFeePerGas=pc['priorityCap']),pc['feeRule'],a.qty(head['baseFeePerGas'])),True)
    expected=pc['minTxInterval']
    if step is not None and plan['planIndex']==0:
        ids=[s['id'] for s in plan['steps']]
        if ids.index(step['id'])<=ids.index('C3.limits'):
            expected=plan['pin']['phaseC']['sp']['deployerOperator'][m.OP['minTxInterval']]
    observed=u.uints(a.call(rpc,sp,'operators(address)',plan['deploymentContext']['operator'],block=block))
    a.need('rq3_send_interval',observed[m.OP['minTxInterval']],expected)
    price=m.price_gate(rpc,block,plan)
    age=a.word(rpc,sp,'priceStalenessThreshold()',block=block)
    a.need('rq3_send_price_fresh',0<=a.qty(head['timestamp'])-price[1]<=age,True)
    a.need('rq3_send_unpaused',a.word(rpc,sp,'paused()',block=block),0)
    a.need('rq3_send_pricing',[a.word(rpc,sp,'aPNTsPriceUSD()',block=block),a.word(rpc,sp,'protocolFeeBPS()',block=block)],
           [pc['aPNTsPriceUSD'],pc['protocolFeeBPS']])
    return dict(block=block,blockHash=head['hash'],gasTuple=gas)


def load_baselines(cfg,inputs,tools=None):
    """Separate comparator pins; never modify DeployLive's 25 release pins."""
    a.need('rq3_commit',bool(re.fullmatch('[0-9a-f]{40}',str(cfg.get('commit','')))),True)
    pins=load(inputs['fixturePins']); result={}
    git=tools.run if tools else m.subprocess.run
    a.need('rq3_fixture_commit',isinstance(pins.get('commit'),str) and bool(re.fullmatch('[0-9a-fA-F]{40}',pins['commit'])),True)
    for name in ('F1TestToken','F1Oracle'):
        entry=pins['contracts'][name]; raw=inside(entry['artifact']).read_bytes(); art=json.loads(raw)
        a.need('rq3_fixture_artifact',hashlib.sha256(raw).hexdigest(),entry['artifactSha256'])
        a.need('rq3_fixture_creation',a.keccak(art['bytecode']['object']),entry['creationKeccak'])
        a.need('rq3_fixture_source',hashlib.sha256(inside(m.F1_SOURCE).read_bytes()).hexdigest(),pins['sourceSha256'])
        refs=art['deployedBytecode'].get('immutableReferences',{})
        identity=dict(artifactRuntime=art['deployedBytecode']['object'],ranges=[dict(name='MINTER',start=r['start'],length=r['length']) for group in refs.values() for r in group])
        a.need('rq3_fixture_runtime',entry['runtimeIdentity'],identity)
        result[name]=dict(bytecode=art['bytecode']['object'],runtimeIdentity=entry['runtimeIdentity'],source=m.F1_SOURCE,commit=cfg['commit'])
    for name,path in m.BASELINE_ARTIFACTS.items():
        raw=inside(path).read_bytes(); art=json.loads(raw)
        committed=git(['git','show',cfg['commit']+':'+path],cwd=ROOT,capture_output=True)
        a.need('rq3_baseline_commit',committed.returncode==0 and committed.stdout==raw,True)
        a.need('rq3_baseline_artifact',hashlib.sha256(raw).hexdigest(),inputs['baselineSha256'][name])
        a.need('rq3_baseline_source',hashlib.sha256(inside(art['source']).read_bytes()).hexdigest(),art['sourceSha256'])
        ctor=[x for x in art['abi'] if x.get('type')=='constructor']
        a.need('rq3_baseline_constructor',len(ctor),1)
        result[name]=dict(bytecode=art['bytecode'],artifact=path,artifactSha256=hashlib.sha256(raw).hexdigest(),
            source=art['source'],sourceSha256=art['sourceSha256'],commit=cfg['commit'],
            constructor='c('+','.join(m.abi_type(x) for x in ctor[0]['inputs'])+')')
    # generate() routes subprocess through the pinned git tool's active context.
    ancestry=git(['git','merge-base','--is-ancestor',pins['commit'],cfg['commit']],cwd=ROOT,capture_output=True)
    a.need('rq3_fixture_commit',ancestry.returncode==0,True)
    return result


def http_transport(url,opener=None):
    import urllib.request
    opener=opener or urllib.request.urlopen
    def rpc(method,params):
        a.need('rq3_readonly',method in READS,True)
        payload=json.dumps(dict(jsonrpc='2.0',id=1,method=method,params=params)).encode()
        try:
            with opener(urllib.request.Request(url,data=payload,headers={'Content-Type':'application/json'}),timeout=30) as response: value=json.load(response)
        except Exception: raise a.Gate('rq3_rpc_transport','redacted failure','successful read') from None
        a.need('rq3_rpc_result',isinstance(value,dict) and value.get('jsonrpc')=='2.0' and value.get('id')==1 and 'result' in value and 'error' not in value,True)
        return value['result']
    rpc.endpoint = url
    return rpc


def address_table(cfg):
    return {key:cfg[key].lower() for key in CONFIG_ADDRESSES}


def structured_checker(checker):
    fields=('result','exitCode','passed','failed','total','summary','configSha256','commit','chainId','stdoutSha256','checkerSha256','tools','checkerFiles','snapshotBlockHash')
    result={k:checker[k] for k in fields if k in checker}
    if 'stdout' in checker:
        result['stdoutSha256']=hashlib.sha256(checker['stdout'].encode()).hexdigest()
    return result


def output_bytes(value, secrets=(), patterns=()):
    # The SDK runner parses plans strictly (no exponents, no fractions): never emit a float.
    a.need('rq3_plan_no_float',not contains_float(value),True)
    raw=(json.dumps(value,indent=2,sort_keys=True)+'\n').encode()
    text=raw.decode()
    forbidden=(r'(?i)(?:https?|wss?|ftp)://', r'(?i)Bearer\s+[a-z0-9._~-]+',
               r'-----BEGIN [A-Z ]*PRIVATE KEY-----',
               r'(?i)"(?:api[_-]?key|private[_-]?key|password|secret|access[_-]?token)"\s*:',
               r'(?i)(?:api[_-]?key|password|secret|access[_-]?token)\s*[=:]\s*[^\s,}]+',
               r'\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16})\b')
    a.need('rq3_output_credentials',not any(re.search(p,text) for p in (*forbidden,*patterns)) and
           not any(secret and secret in text for secret in secrets),True)
    return raw


def authenticate_checker(cfg, tools):
    hashes={}
    for path in ('script/rehearsal/deploylive_postdeploy_check.py','script/rq3op/checker_runner.py',
                 'script/rehearsal/deploylive_check_count.py','script/rehearsal/deploylive_readback.py'):
        committed=tools.run(['git','show',cfg['commit']+':'+path],cwd=ROOT,capture_output=True)
        actual=hashlib.sha256(inside(ROOT/path).read_bytes()).hexdigest()
        a.need('rq3_checker_blob',committed.returncode==0 and
               hashlib.sha256(committed.stdout).hexdigest()==actual,True)
        hashes[path]=actual
    return hashes


def run_checker(config_path,cfg,url,chain,*,block,runner=None,commit_reader=None,tools=None):
    import subprocess
    sys.path.insert(0,str(ROOT/'script/rehearsal'))
    from deploylive_runtime import clean_source_commit
    tools=tools or pinned_tools()
    a.need('rq3_source_commit',cfg['commit'],commit_reader() if commit_reader else clean_source_commit(git_runner=tools.run))
    hashes=authenticate_checker(cfg,tools)
    if chain != 31337:
        for key in ('DEPLOYLIVE_SECOND_RPC_FILE', 'DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER'):
            if not tools.env.get(key):
                error = a.Gate('rq3_checker_execution', 'missing '+key, 'required checker input')
                error.args = ('rq3_checker_execution: missing '+key,)
                raise error
    a.need('rq3_checker_execution', isinstance(block, str) and bool(re.fullmatch(r'0x[0-9a-fA-F]{64}', block)), True)
    checker=ROOT/'script/rehearsal/deploylive_postdeploy_check.py'
    executable=[str(ROOT/'script/rq3op/checker_runner.py'),block]
    result=(runner or tools.run)([sys.executable,'-B',*executable,str(inside(config_path)),
        cfg['deployer'],cfg['governanceOwner']],capture_output=True,text=True,cwd=ROOT,env=dict(tools.env, ETH_RPC_URL=url, DEPLOYLIVE_EXPECTED_CHAIN_ID=str(chain)))
    matches=re.findall(r'^SUMMARY (\d+) passed, (\d+) failed, (\d+) total$',result.stdout,re.M)
    from deploylive_check_count import expected_check_count
    expected=expected_check_count(cfg, load(ROOT/'deployments/readback-policy.json'),
        load(ROOT/'deployments/readback-artifacts.json'), load(ROOT/'deployments/release-versions.rc8.json'))
    snapshots=re.findall(r'^SNAPSHOT_BLOCK_HASH(?:[ \t]+(.*))?$', result.stdout, re.M)
    a.need('rq3_checker_execution', True if snapshots == [block.lower()] else 'snapshot block hash mismatch', True)
    a.need('rq3_checker_execution',result.returncode==0 and len(matches)==1 and
        tuple(map(int,matches[0]))==(expected,0,expected) and not re.search(r'^FAIL\b',result.stdout,re.M),True)
    return dict(snapshotBlockHash=snapshots[0].lower() if len(snapshots)==1 else None,tools=tools.records,checkerFiles=hashes,result='PASS',exitCode=0,passed=expected,failed=0,total=expected,
        summary=f'SUMMARY {expected} passed, 0 failed, {expected} total',
        stdoutSha256=hashlib.sha256(result.stdout.encode()).hexdigest(),
        checkerSha256=hashlib.sha256(checker.read_bytes()).hexdigest(),
        configSha256=digest(cfg),commit=cfg['commit'],chainId=chain)


SYSTEM_SOURCES={
    'entryPoint':None,'superPaymaster':'paymasters/superpaymaster/v3/SuperPaymaster.sol',
    'registry':'core/Registry.sol','xPNTsFactoryV2':'tokens/v2/xPNTsFactoryV2.sol',
    'simpleAccountFactory':None,'staking':'core/GTokenStaking.sol',
    'gToken':'tokens/GTokenAuthorization.sol','aPNTs':'tokens/APNTsCapped.sol',
    'governanceOwner':None,'timelockController':None}


RELEASE_NAMES=dict(superPaymaster='SuperPaymaster',registry='Registry',xPNTsFactoryV2='xPNTsFactoryV2',
    staking='GTokenStaking',gToken='GTokenAuthorization',aPNTs='APNTsCapped')


DEPLOYED_RELEASE_NAMES = frozenset('AOAProtocolRegistry APNTsCapped BLSAggregator DVTValidator GTokenAuthorization GTokenStaking GlobalTierSource MicroPaymentChannel MySBT Paymaster PaymasterFactory PolicyRegistry Registry ReputationSystem SuperPaymaster SuperPaymasterLens X402Facilitator xPNTsFactory xPNTsFactoryV2 xPNTsToken xPNTsTokenV2'.split())
SOURCE_ONLY_RELEASE_NAMES = frozenset({"GToken"})


def verify_system(cfg,rpc,block,*,entrypoint_in_builder=False):
    try:
        versions=load(ROOT/'deployments/release-versions.rc8.json')
    except (ValueError, OSError):
        raise a.Gate('rq3_release_versions','invalid table','reviewed release table') from None
    a.need('rq3_release_versions',set(versions) == DEPLOYED_RELEASE_NAMES | SOURCE_ONLY_RELEASE_NAMES,True)
    for key in SYSTEM_SOURCES:
        if key=='entryPoint' and entrypoint_in_builder: continue
        address=cfg[key]
        code=rpc('eth_getCode',[address,block])
        a.need('rq3_system_code',isinstance(code,str) and bool(re.fullmatch(r'0x(?:[0-9a-fA-F]{2})+',code)),True)
        if key in RELEASE_NAMES:
            raw=bytes.fromhex(a.call(rpc,address,'version()',block=block)[2:])
            offset=int.from_bytes(raw[:32],'big');size=int.from_bytes(raw[offset:offset+32],'big')
            actual=raw[offset+32:offset+32+size].decode()
            a.need('rq3_system_version',actual,versions[RELEASE_NAMES[key]])


def verify_calibration(cfg,cal,chain,rpc):
    a.need('rq3_calibration_pvg', all('preVerification' not in b for b in cal['arms'].values()), True)
    source=cal['source'];raw=inside(source['evidenceFile']).read_bytes()
    a.need('rq3_calibration_hash',hashlib.sha256(raw).hexdigest(),source['evidenceSha256'])
    evidence=m.fresh_addresses(json.loads(raw));cfg=m.fresh_addresses(cfg)
    a.need('rq3_calibration_identity',[evidence.get(k) for k in ('chainId','superPaymaster','commit')],
           [chain,cfg['superPaymaster'],cfg['commit']])
    block=rpc('eth_getBlockByNumber',[evidence['blockNumber'],False])
    a.need('rq3_calibration_block',[block['number'],block['hash'],source['blockHash']],
           [evidence['blockNumber'],evidence['blockHash'],evidence['blockHash']])
    for key in ('arms','setup','ownerPreparation','ownerMaintenance','bundlerMaintenance','safeTransactions'):
        a.need('rq3_calibration_measurements',evidence[key],cal[key])
    # VPM postOp is structurally zero (checked in worksheet); every other limit must be positive.
    limits=[v for name,arm in cal['arms'].items() for k,v in arm.items() if (name,k)!=('VPM','postOp')]
    limits+=list(cal['setup'].values())+list(cal['ownerPreparation'].values())+list(cal['safeTransactions'].values())
    limits += [v['gas'] for key in ('ownerMaintenance','bundlerMaintenance') for v in cal[key]]
    a.need('rq3_positive_limits',all(type(v) is int and v>0 for v in limits),True)


def funding_table(steps,safe_txs,rpc,block,pcs,mint,transfer,cfg):
    rows={}
    for tx in [s['tx'] for s in steps]+safe_txs:
        who=tx['from'];row=rows.setdefault(who,dict(valueTotal=0,maxGasCost=0))
        row['valueTotal']+=a.qty(tx['value'])
        if 'gas' in tx:row['maxGasCost']+=a.qty(tx['gas'])*a.qty(tx['maxFeePerGas'])
    for who,row in rows.items():
        row['totalRequired']=row['valueTotal']+row['maxGasCost']
        row['currentBalance']=a.qty(rpc('eth_getBalance',[who,block]))
        row['incomingFunding']=sum(a.qty(s['tx']['value']) for s in steps if s['tx']['to']==who)
        row['shortfall']=max(0,row['totalRequired']-row['currentBalance']-row['incomingFunding'])
        row['gasScope']='emitted transactions' if who!=cfg['governanceOwner'] else 'calibrated Safe transaction allowance; executor also needs its own signing gas'
    tokens={cfg['aPNTs']:mint,cfg['gToken']:transfer}
    for pc in pcs:
        for label,field in [('X','userTarget'),('Q','feeTokenTarget')]:
            address=pc['addresses'][label];tokens[address]=tokens.get(address,0)+pc[field]
    # Count every mint, including task recipients, directly from emitted calldata.
    mint_selector=a.calldata('mint(address,uint256)',a.ZERO,0)[:10]
    for step in steps:
        tx=step['tx']
        if tx['to']==pcs[0]['addresses']['T'] and tx['data'].startswith(mint_selector):
            tokens[tx['to']]=tokens.get(tx['to'],0)+int(tx['data'][-64:],16)
    return dict(senders=rows,eth=dict(valueTotal=sum(r['valueTotal'] for r in rows.values()),
        maxGasCost=sum(r['maxGasCost'] for r in rows.values()),totalRequired=sum(r['totalRequired'] for r in rows.values())),tokens=tokens)


def generate(config_path,inputs_path,left,right,url,block=None,checker_runner=None,commit_reader=None):
    tools=pinned_tools()
    with tools.active():
        return _generate(config_path,inputs_path,left,right,url,block,checker_runner,commit_reader,tools)


def _generate(config_path,inputs_path,left,right,url,block,checker_runner,commit_reader,tools):
    cfg=load(config_path);inputs=load(inputs_path)
    pair=Pair(left,right)
    if block:
        pair.head=pair('eth_getBlockByNumber',[block,False])
    sys.path.insert(0, str(ROOT/'script/rehearsal'))
    from deploylive_readback import expected_chain_id
    try:
        chain = expected_chain_id(tools.env)
    except ValueError as error:
        raise a.Gate('rq3_expected_chain', str(error), 'DEPLOYLIVE_EXPECTED_CHAIN_ID: positive decimal chain id') from None
    a.need('rq3_expected_chain', a.qty(pair('eth_chainId', [])), chain)
    require_f1_chain(chain)
    if chain != 31337:
        sys.path.insert(0, str(ROOT/'script/rehearsal'))
        from deploylive_readback import independent_providers
        try:
            independent_providers(tools.env.get('DEPLOYLIVE_ENDPOINT_PROVIDER', ''),
                                  tools.env.get('DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER', ''),
                                  getattr(left, 'endpoint', ''), getattr(right, 'endpoint', ''))
        except ValueError:
            raise a.Gate('rq3_planner_providers', 'invalid provider pair', 'distinct approved bound endpoints') from None
    checker=run_checker(config_path,cfg,url,chain,block=pair.head['hash'],runner=checker_runner,commit_reader=commit_reader,tools=tools)
    verify_system(cfg,pair,pair.head['number'],entrypoint_in_builder=True)
    cal=load(inputs['calibration']);verify_calibration(cfg,cal,checker['chainId'],pair)
    def frozen(method,params):
        if method=='eth_getBlockByNumber' and params[0]=='latest':return pair.head
        return pair(method,params)
    # The pure builder consumes the same validated checker schema as its historical fixtures.
    internal=dict(checker,stdout='PASS verified checker execution\n'+checker['summary'])
    result=build(cfg,inputs,frozen,internal,cal,load_baselines(cfg,inputs,tools=tools))
    result['checker']=checker
    for plan in result['plans'].values():plan['checker']=checker
    pair.finish()
    return output_bytes(result,secrets=inputs.get('secrets',()),patterns=inputs.get('secretPatterns',()))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config');parser.add_argument('inputs');parser.add_argument('output')
    parser.add_argument('--rpc-a-file',required=True);parser.add_argument('--rpc-b-file',required=True)
    parser.add_argument('--block')
    args=parser.parse_args()
    urls=[inside(p).read_text().strip() for p in (args.rpc_a_file,args.rpc_b_file)]
    raw=generate(args.config,args.inputs,http_transport(urls[0]),http_transport(urls[1]),urls[0],args.block)
    if args.output=='-':sys.stdout.buffer.write(raw)
    else:inside(args.output).write_bytes(raw)


if __name__=='__main__': main()
