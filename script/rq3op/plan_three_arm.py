#!/usr/bin/env python3
"""Fresh DeployLive RQ3 plans. Only read RPCs; no signing or broadcasting."""
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

a, u = m.a, m.u
ROOT = Path(__file__).resolve().parents[2]
CONFIG_ADDRESSES = ('superPaymaster','registry','aPNTs','xPNTsFactoryV2','globalTierSource',
    'entryPoint','simpleAccountFactory','genesisOperator','governanceOwner','timelockController',
    'gToken','staking','sbt','xPNTsTokenV2Impl','deployer')
PVG_RULE = json.loads((Path(__file__).with_name('pvg-rule.json')).read_text())
CALIBRATION_FIELDS = tuple(k for k in m.ARM_FIELDS if k != 'preVerification')


def check_calibration_fields(cal):
    a.need('rq3_calibration_pvg', all('preVerification' not in b for b in cal['arms'].values()), True)
    a.need('rq3_gas_fields', set(cal['arms']) == set(m.ARMS) and
           all(set(b) == set(CALIBRATION_FIELDS) for b in cal['arms'].values()), True)


READS = {'eth_chainId','eth_getBlockByNumber','eth_call','eth_getCode','eth_getStorageAt',
         'eth_getTransactionCount','eth_getBalance','eth_feeHistory','eth_maxPriorityFeePerGas'}


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
        results = [client(method,params) for client in self.clients]
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


def check_inputs(cfg, inputs, checker):
    a.need('rq3_commit',bool(re.fullmatch('[0-9a-f]{40}',str(cfg.get('commit','')))),True)
    a.need('rq3_checker_pass',checker.get('result')=='PASS' and bool(re.fullmatch(
        r'SUMMARY ([1-9][0-9]*) passed, 0 failed, \1 total',checker.get('summary',''))),True)
    stdout=checker.get('stdout','')
    a.need('rq3_checker_log',isinstance(stdout,str) and checker.get('exitCode')==0 and
           stdout.strip().endswith(checker['summary']) and not re.search(r'^FAIL\b',stdout,re.M) and
           bool(re.search(r'^(?:PASS|INFO-PASS)\b',stdout,re.M)),True)
    a.need('rq3_checker_binding',[checker.get('configSha256'),checker.get('commit')],[digest(cfg),cfg['commit']])
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
    recipients=inputs.get('taskRecipients')
    a.need('rq3_task_recipients',isinstance(recipients,list),True)
    seen={m.DEAD.lower(),a.ZERO.lower(),*(v['account'].lower() for v in accounts)}
    for entry in recipients:
        a.need('rq3_task_recipients',isinstance(entry,dict) and set(entry)=={'address','amount'},True)
        who,amount=entry['address'],entry['amount']
        a.need('rq3_task_recipients',isinstance(who,str) and bool(re.fullmatch('0x[0-9a-fA-F]{40}',who)) and
               who.lower() not in seen and type(amount) is int and 301<=amount<2**256,True)
        seen.add(who.lower())



def sp_postop_limit(measured, gas_factor, minimum):
    """DSR 2026-11-18 ruling (b): max(measured × gasFactor, SP's on-chain minPostOpGas).

    The floor is imposed by the system under test, so every real SP-arm transaction must meet it.
    When it applies, EntryPoint's unused-gas penalty is part of the SP arm's cost; the returned
    record (floorApplied) is copied into every data row so the paper can report it."""
    scaled=scale(measured,gas_factor)
    a.need('rq3_postop_floor',type(minimum) is int and minimum>0,True)
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
    a0=m.ceil_div(maxima['SP']*m.PC_PRICE_CAP*10**18,10**m.PC_PRICE_DECIMALS*price_a)
    amax=m.ceil_div(a0*(10000+fee_b+m.PC_VALIDATION_BUFFER_BPS),10000)
    a.need('C_amax_cap',amax<=m.PC_AMAX_CAP,True)
    xmax=m.ceil_div(amax*m.PC_RATE,10**18)
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
        protocolFeeBPS=fee_b,A0=a0,Amax=amax,operatorTarget=(m.PC_ATTEMPTS+m.PC_BETA)*amax,
        operatorTopUp=0,cappedMint=0,cappedSupplyBefore=p['capped']['totalSupply'],Xmax=xmax,
        userTarget=(n+m.PC_BETA)*xmax,entryPointTargets={arm:(n+1+m.PC_BETA)*v for arm,v in maxima.items()},
        entryPointBefore=dict(SP=0,VPM=0,TPM=0),entryPointTopUps={},Qmax=qmax,feeTokenTarget=(n+m.PC_BETA)*qmax,
        taskSender=3*n*m.PC_TASK_UNIT+m.PC_TASK_UNIT,taskRecipient=m.PC_TASK_UNIT,
        bundlerMaintenance=aux,bundlerTarget=target_b,bundlerTopUp=m.positive(target_b-p['bundler']['balance']),
        ownerPreparation=prep,ownerMaintenance=maintenance,ownerMaintenanceWei=sum(x['gas'] for x in maintenance)*fee,
        ownerTarget=target_o,ownerTopUp=m.positive(target_o-p['owner']['balance']),
        endUserStake=facts['minStake'],endUserTicket=facts['ticketPrice'],accountExists=facts['accountExists'],
        accountMember=facts['member'],token=dict(zip(('name','symbol','communityName','communityENS'),m.PC_TOKEN)),
        treasury=ctx['safe'],recipient=m.DEAD,f1Provenance=m.F1_SCOPE_NOTE)


def build(cfg,inputs,rpc,checker,cal,baselines):
    # Pure assembly layer; generate() authenticates files, checker and deployment before calling.
    check_inputs(cfg,inputs,checker)
    check_calibration_fields(cal)
    for i in range(len(inputs['taskRecipients'])):
        value=cal.get('setup',{}).get('C11.extra.'+str(i))
        a.need('rq3_task_calibration',type(value) is int and value>0,True)
    rpc=ReadOnly(rpc)
    chain=a.qty(rpc('eth_chainId',[])); a.need('rq3_chain',chain in (10,11155111,31337),True)
    a.need('rq3_checker_chain',checker['chainId'],chain)
    head=a.block_data(rpc,'latest'); block=head['number']
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
    requested_fee=scale(a.qty(head['baseFeePerGas']),inputs['feeFactor'])+priority
    fee=min(requested_fee,inputs['feeCeiling'])
    # Cap the base-fee rule; reject a cap that cannot cover the pinned base fee and priority.
    a.need('rq3_fee_ceiling',type(inputs['feeCeiling']) is int and 0<priority and a.qty(head['baseFeePerGas'])+priority<=fee<=inputs['feeCeiling']<=a.MAX_FEE,True)
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
        pin['phaseC']=m.collect_phase_c(rpc,block,{'data':{'phaseC':c}},pin,context=ctx)
        p=pin['phaseC']; a.need('rq3_genesis_unconfigured',p['sp']['deployerOperator'][:4],[0]*4)
        # Three identical pricing/cap reads must refer to the same deployment state.
        if pins: a.need('rq3_shared_pin',[p[k] for k in ('sp','capped','endUser')],[pins[0]['phaseC'][k] for k in ('sp','capped','endUser')])
        ws=worksheet(pin,c,ctx,n,cal,inputs['gasFactor'],fee,priority,gas,head)
        pins.append(pin); worksheets.append(ws); cs.append(c)
    first=worksheets[0]; p=pins[0]['phaseC']
    operator_top=first['operatorTarget']; mint=m.positive(operator_top-p['capped']['deployerBalance'])
    a.need('rq3_cap_headroom',p['capped']['totalSupply']+mint<=p['capped']['cap'] and p['capped']['cap']==cfg['expectedCap'],True)
    tickets=sum(w['endUserStake']+w['endUserTicket'] for w in worksheets if not w['accountMember'])
    transfer=m.positive(tickets-p['endUser']['deployerGToken'])
    a.need('rq3_safe_gtoken',word(cfg['gToken'],'balanceOf(address)',ctx['safe'])>=transfer,True)
    ep_targets={arm:sum(w['entryPointTargets'][arm] for w in worksheets) for arm in m.ARMS}
    bundler_target=sum(w['bundlerTarget'] for w in worksheets)-2*m.PC_BUNDLER_BETA
    counters={k:v['nonce'] for k,v in senders.items()}; all_steps=[]; plans={}; comparators={}; x_supply=0; gt_balance=p['endUser']['deployerGToken']+transfer
    for i,(pin,c,ws) in enumerate(zip(pins,cs,worksheets)):
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
            if i and sid in ('C3.deploy','C3.configure','C11.R','C15','C16.vpm','C16.tpm'):
                return {'tx':{'chainId':hex(chain)}}
            if sid.startswith(('C2.','C3.')) or sid in ('C6','C7','C8'): sender='genesis'
            who=c['accountOwner'] if sender=='owner' else senders[sender]['address']
            measured=cal['setup'][sid]
            limit=ws['ownerPreparation'][sid] if sender=='owner' else scale(measured,inputs['gasFactor'])
            tx=dict(to=target,data=data,value=hex(value),nonce=hex(counters[sender]),chainId=hex(chain),
                    maxFeePerGas=hex(fee),maxPriorityFeePerGas=hex(priority),gas=hex(limit),**{'from':who})
            counters[sender]+=1
            step=dict(id=sid,sender=sender,tx=tx,readbacks=checks,**extra,
                      gasEvidence=dict(source=cal['source'],measurement=cal['ownerPreparation'][sid] if sender=='owner' else measured,
                                       factor=inputs['gasFactor'],limit=limit,block=head))
            local_steps.append(step); return step
        pc,_=m.build_phase_c(pin=pin,inputs=c,context=local_ctx,chain_id=chain,commit=cfg['commit'],
            factory=cfg['xPNTsFactoryV2'],tier=cfg['globalTierSource'],ep=cfg['entryPoint'],
            addresses={'xPNTsTokenV2':cfg['xPNTsTokenV2Impl']},counters=counters,safe_n=safe_nonce,
            steps=local_steps,add=add,sp_deposit_before=ep_info[0],sp_stake=ep_info[2]+inputs['stakeWei'],
            worksheet=ws,baselines=baselines,policy='fresh',
            task_recipients=inputs['taskRecipients'] if i==0 else ())
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
        plan=dict(planIndex=i,taskRecipients=copy.deepcopy(inputs['taskRecipients']),schema='rq3-deploylive-1',deploymentContext=ctx,chainId=chain,commit=cfg['commit'],configSha256=digest(cfg),
                  checker=structured_checker(checker),pin=pin,phaseC=pc,steps=local_steps,addresses=address_table(cfg),
                  externalInputs={'sha256':digest(inputs),'data':{'phaseC':c,'sampled':[ctx['operator']]}},
                  gasPolicy=dict(factor=inputs['gasFactor'],frozen=True,source=cal['source']))
        plans[c['account']]=plan
        all_steps.extend(dict(s,id=str(i)+'/'+s['id']) for s in local_steps)
        x_supply+=ws['userTarget']
        if not ws['accountMember']: gt_balance-=ws['endUserStake']+ws['endUserTicket']
    # No Safe signing here: output inner calls, including schedule/execute for a value-bearing batch.
    target=ctx['SP']; data=a.calldata('addStake(uint32)',inputs['unstakeDelay']); salt=a.keccak('rq3/'+digest(cfg)+'/'+digest(inputs))
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
    # Funding cannot be accepted merely because value fits: include all frozen setup gas.
    for label,entry in senders.items():
        required=sum(a.qty(s['tx']['value'])+a.qty(s['tx']['gas'])*fee for s in all_steps if s['sender']==label)
        a.need('rq3_setup_budget',entry['balance']>=required,True)
    if hasattr(rpc.rpc,'finish'): rpc.rpc.finish()
    pcs=[plan['phaseC'] for plan in plans.values()]
    a.need('rq3_shared_task',len({pc['addresses']['T'] for pc in pcs})==1 and
           len({pc['taskCallData'] for pc in pcs})==1,True)
    shared=dict(T=pcs[0]['addresses']['T'],R=m.DEAD,SP=ctx['SP'],chainId=chain,
                commit=cfg['commit'],configSha256=digest(cfg),taskCallData=pcs[0]['taskCallData'],
                taskRecipients=copy.deepcopy(inputs['taskRecipients']),experiment=inputs['experiment'])
    funding=funding_table(all_steps,safe_txs,rpc,block,pcs,mint,transfer,cfg)
    return dict(shared=shared,plans=plans,steps=all_steps,safeTransactions=safe_txs,timelockOperation=op,
                configSha256=digest(cfg),commit=cfg['commit'],chainId=chain,checker=structured_checker(checker),funding=funding)


def pre_send(rpc,plan):
    """Call before EVERY setup send and attempt; never re-estimate frozen limits."""
    rpc=ReadOnly(rpc); head=a.block_data(rpc,'latest'); block=head['number']; pc=plan['phaseC']; sp=pc['addresses']['SP']
    gas=u.uints(a.call(rpc,sp,'gasParams()',block=block))
    a.need('C_gas_tuple',gas,pc['gasTuple'])
    stake=u.uints(a.call(rpc,plan['addresses']['entryPoint'],'getDepositInfo(address)',sp,block=block))
    a.need('rq3_send_stake',stake[1]==1 and stake[2]==plan['pin']['stake']+plan['deploymentContext']['stakeWei'] and
           stake[3]==plan['deploymentContext']['stakeDelay'] and stake[4]==0,True)
    a.need('rq3_send_chain',a.qty(rpc('eth_chainId',[])),plan['chainId'])
    a.need('rq3_send_fee',a.qty(head['baseFeePerGas'])+pc['priorityCap']<=pc['feeCap']<=pc['feeRule']['ceiling'],True)
    price=m.price_gate(rpc,block,plan)
    age=a.word(rpc,sp,'priceStalenessThreshold()',block=block)
    a.need('rq3_send_price_fresh',0<=a.qty(head['timestamp'])-price[1]<=age,True)
    a.need('rq3_send_unpaused',a.word(rpc,sp,'paused()',block=block),0)
    a.need('rq3_send_pricing',[a.word(rpc,sp,'aPNTsPriceUSD()',block=block),a.word(rpc,sp,'protocolFeeBPS()',block=block)],
           [pc['aPNTsPriceUSD'],pc['protocolFeeBPS']])
    return dict(block=block,blockHash=head['hash'],gasTuple=gas)


def load_baselines(cfg,inputs):
    """Separate comparator pins; never modify DeployLive's 25 release pins."""
    a.need('rq3_commit',bool(re.fullmatch('[0-9a-f]{40}',str(cfg.get('commit','')))),True)
    pins=load(inputs['fixturePins']); result={}
    a.need('rq3_fixture_commit',pins['commit'],cfg['commit'])
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
        committed=m.subprocess.run(['git','show',cfg['commit']+':'+path],cwd=ROOT,capture_output=True)
        a.need('rq3_baseline_commit',committed.returncode==0 and committed.stdout==raw,True)
        a.need('rq3_baseline_artifact',hashlib.sha256(raw).hexdigest(),inputs['baselineSha256'][name])
        a.need('rq3_baseline_source',hashlib.sha256(inside(art['source']).read_bytes()).hexdigest(),art['sourceSha256'])
        ctor=[x for x in art['abi'] if x.get('type')=='constructor']
        a.need('rq3_baseline_constructor',len(ctor),1)
        result[name]=dict(bytecode=art['bytecode'],artifact=path,artifactSha256=hashlib.sha256(raw).hexdigest(),
            source=art['source'],sourceSha256=art['sourceSha256'],commit=cfg['commit'],
            constructor='c('+','.join(m.abi_type(x) for x in ctor[0]['inputs'])+')')
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
    return rpc


def address_table(cfg):
    return {key:cfg[key].lower() for key in CONFIG_ADDRESSES}


def structured_checker(checker):
    fields=('result','exitCode','passed','failed','total','summary','configSha256','commit','chainId','stdoutSha256','checkerSha256','tools','checkerFiles')
    result={k:checker[k] for k in fields if k in checker}
    if 'stdout' in checker:
        result['stdoutSha256']=hashlib.sha256(checker['stdout'].encode()).hexdigest()
    return result


def output_bytes(value, secrets=(), patterns=()):
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
    for path in ('script/rehearsal/deploylive_postdeploy_check.py','script/rq3op/checker_runner.py'):
        committed=tools.run(['git','show',cfg['commit']+':'+path],cwd=ROOT,capture_output=True)
        actual=hashlib.sha256(inside(ROOT/path).read_bytes()).hexdigest()
        a.need('rq3_checker_blob',committed.returncode==0 and
               hashlib.sha256(committed.stdout).hexdigest()==actual,True)
        hashes[path]=actual
    return hashes


def run_checker(config_path,cfg,url,chain,runner=None,commit_reader=None,block=None,tools=None):
    import subprocess
    sys.path.insert(0,str(ROOT/'script/rehearsal'))
    from deploylive_runtime import clean_source_commit
    tools=tools or pinned_tools()
    a.need('rq3_source_commit',cfg['commit'],commit_reader() if commit_reader else clean_source_commit(git_runner=tools.run))
    hashes=authenticate_checker(cfg,tools)
    checker=ROOT/'script/rehearsal/deploylive_postdeploy_check.py'
    executable=[str(ROOT/'script/rq3op/checker_runner.py'),block] if block else [str(checker)]
    result=(runner or tools.run)([sys.executable,'-B',*executable,url,str(inside(config_path)),
        cfg['deployer'],cfg['governanceOwner']],capture_output=True,text=True,cwd=ROOT,env=tools.env)
    matches=re.findall(r'^SUMMARY (\d+) passed, (\d+) failed, (\d+) total$',result.stdout,re.M)
    expected=234+2*int(cfg['guardianN'])  # prior rows + coverage, snapshot policy, hash recheck, second provider
    a.need('rq3_checker_execution',result.returncode==0 and len(matches)==1 and
        tuple(map(int,matches[0]))==(expected,0,expected) and not re.search(r'^FAIL\b',result.stdout,re.M),True)
    return dict(tools=tools.records,checkerFiles=hashes,result='PASS',exitCode=0,passed=expected,failed=0,total=expected,
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


def verify_system(cfg,rpc,block):
    try:
        versions=load(ROOT/'deployments/release-versions.rc8.json')
    except (ValueError, OSError):
        raise a.Gate('rq3_release_versions','invalid table','reviewed release table') from None
    a.need('rq3_release_versions',set(versions) == DEPLOYED_RELEASE_NAMES | SOURCE_ONLY_RELEASE_NAMES,True)
    for key in SYSTEM_SOURCES:
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
    evidence=json.loads(raw)
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
    checker=run_checker(config_path,cfg,url,a.qty(pair('eth_chainId',[])),checker_runner,commit_reader,pair.head['number'],tools)
    verify_system(cfg,pair,pair.head['number'])
    cal=load(inputs['calibration']);verify_calibration(cfg,cal,checker['chainId'],pair)
    def frozen(method,params):
        if method=='eth_getBlockByNumber' and params[0]=='latest':return pair.head
        if block and method=='eth_getTransactionCount' and params[-1]=='pending':params=[params[0],pair.head['number']]
        return pair(method,params)
    # The pure builder consumes the same validated checker schema as its historical fixtures.
    internal=dict(checker,stdout='PASS verified checker execution\n'+checker['summary'])
    result=build(cfg,inputs,frozen,internal,cal,load_baselines(cfg,inputs))
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
