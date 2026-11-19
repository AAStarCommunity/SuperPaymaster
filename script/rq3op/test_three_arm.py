"""Offline fail-first contracts for the fresh deployment adapter."""
import copy
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'upgrade'))
import test_manifest_exec as t
import plan_three_arm as q

m, a, u = t.m, t.a, t.u

def address(n): return '0x'+format(n, '040x')

class Fake:
    def __init__(self):
        self.values = {}
        self.chainId='0xa'; self.pending=0; self.code='0x'; self.balance=10**23
        self.reads = []; self.estimate = 7*10**6
        self.rewards = [10**6, 3*10**6, 2*10**6, 0, 5*10**6]
        self.head = dict(number='0x20', hash='0x'+'12'*32, timestamp='0x64', baseFeePerGas=hex(10**8))
    def __call__(self, method, params):
        self.reads.append((method, params))
        if method == 'eth_chainId': return self.chainId
        if method == 'eth_feeHistory':
            n=int(params[0],16); return dict(oldestBlock=hex(int(params[1],16)-n+1),baseFeePerGas=[], reward=[[hex(x)] for x in self.rewards[:n]])
        if method == 'eth_maxPriorityFeePerGas': return hex(self.estimate)
        if method == 'eth_getBlockByNumber': return self.head
        if method == 'eth_getTransactionCount': return hex(self.pending) if params[-1]=='pending' else '0x0'
        if method == 'eth_getBalance': return hex(self.balance)
        if method == 'eth_getCode':
            if params[0]==address(15): return (q.ROOT/'contracts/test/fixtures/entrypoint-v0.7.runtime.hex').read_text().strip()
            return self.code
        if method == 'eth_call':
            key=(params[0]['to'],params[0]['data'])
            if key in self.values:return self.values[key]
            selectors={a.calldata(sig,*args)[:10]:n for sig,args,n in [
                ('isXPNTs(address)',(address(0),),1),
                ('getDepositInfo(address)',(address(0),),5),
                ('balanceOf(address)',(address(0),),1),
                ('hasRole(bytes32,address)',(m.role_id('ENDUSER'),address(0)),1),
                ('verifyCommunityMembership(address,address)',(address(0),address(0)),1)]}
            if params[0]['data'][:10] in selectors:return '0x'+'0'*64*selectors[params[0]['data'][:10]]
            raise KeyError(key)
        raise AssertionError((method, params))
    def set(self, who, sig, *args, value):
        self.values[(who, a.calldata(sig, *args))] = value if isinstance(value,str) else '0x'+''.join(format(x,'064x') for x in (value if isinstance(value,list) else [value]))

class ThreeArm(unittest.TestCase):
    def setUp(self):
        self.cfg = {k:address(i+10) for i,k in enumerate(q.CONFIG_ADDRESSES)}
        self.cfg.update(commit='a'*40, expectedCap=10**30, creationPinsSha256='0x'+'ab'*32)
        self.rpc = Fake()
        self.inputs = dict(experiment=address(100), genesis=self.cfg['genesisOperator'],
            bundler=address(101), verifyingSigner=address(102), gasFactor={'numerator':3,'denominator':2},
            feeFactor={'numerator':2,'denominator':1}, priorityRule={'blocks':5,'percentile':50},
            sdkRuns=1, sdkMaxOps=1, sdkMaxCostPerOp=1, minTxInterval=60, extraEndUsers=[], taskRecipients=[], feeCeiling=20*10**9, stakeWei=10**18, unstakeDelay=86400,
            accounts=[dict(account=address(200+i),accountOwner=address(300+i),salt=i,
                accountImplementation=t.PC_IMPL,runtimeKeccak=copy.deepcopy(t.PC_RUNTIMES)) for i in range(3)])
        self.cal = t.phase_c_inputs(lambda *args: {})['rehearsal']
        for arm in m.ARMS:
            del self.cal['arms'][arm]['preVerification']
        self.cal['arms']['SP']['postOp']=400000
        self.cal['setup'] = {sid:5000000 for sid in ('C2.approve','C2.deposit','C3.deploy','C3.configure','C3.limits','C5','C6','C7','C8','C20',*m.OWNER_PREPARATION,'C10','C11.S','C11.R','C12','C13.token','C13.oracle','C14','C15','C16.vpm','C16.tpm','C17.sp','C17.vpm','C17.tpm','C18.mint','C19')}
        self.cal['safeTransactions']={sid:500000 for sid in ('C1','GToken.transfer','SP.stake.schedule','SP.stake.execute')}
        self.cal['source'] = dict(kind='measured', blockHash=self.rpc.head['hash'], evidenceSha256='cd'*32)
        self.evidence = dict(result='PASS', configSha256=q.digest(self.cfg), commit=self.cfg['commit'], chainId=10,
            summary='SUMMARY 187 passed, 0 failed, 187 total',
            stdout='PASS synthetic offline checker fixture\nSUMMARY 187 passed, 0 failed, 187 total\n',exitCode=0)
        self.pins = []
        for account in self.inputs['accounts']:
            p=t.phase_c_pin(t.pin())
            p['owner']['address']=account['accountOwner']; p['bundler']['address']=self.inputs['bundler']
            p['verifyingSigner']['address']=self.inputs['verifyingSigner']
            p['account']['counterfactual']=account['account']
            p['account']['implementationEntryPoint']=self.cfg['entryPoint']
            p['capped'].update(minter=self.cfg['governanceOwner'],totalSupply=0,cap=10**30,deployerBalance=0)
            p['sp']['deployerOperator']=[0]*9
            p['endUser'].update(staking=self.cfg['staking'],gtoken=self.cfg['gToken'],mysbt=self.cfg['sbt'],deployerGToken=1000)
            self.pins.append(p)
        sp, ep = self.cfg['superPaymaster'], self.cfg['entryPoint']
        for who,sig,value in [(sp,'gasParams()',[500000,400000,10000,10000,0,0,0,0,0]),
            (sp,'totalTrackedBalance()',0),(sp,'protocolRevenue()',0),(sp,'paused()',0),
            (sp,'owner()',int(self.cfg['timelockController'],16)),
            (self.cfg['governanceOwner'],'getThreshold()',2),(self.cfg['governanceOwner'],'nonce()',0),
            (self.cfg['timelockController'],'getMinDelay()',172800),
            (self.cfg['xPNTsFactoryV2'],'getDeployedCount()',0)]: self.rpc.set(who,sig,value=value)
        self.rpc.set(ep,'getDepositInfo(address)',sp,value=[0,0,0,0,0])
        self.rpc.set(self.cfg['aPNTs'],'balanceOf(address)',sp,value=0)
        self.rpc.set(self.cfg['gToken'],'balanceOf(address)',self.cfg['governanceOwner'],value=10**25)
        self.rpc.set(self.cfg['xPNTsFactoryV2'],'getTokenAddress(address)',self.inputs['genesis'],value=0)
        # Round 2 reads pinned initial values as well as the old worksheet reads.
        self.rpc.set(self.cfg['aPNTs'],'allowance(address,address)',self.inputs['genesis'],sp,value=0)
        self.rpc.set(self.cfg['gToken'],'allowance(address,address)',self.inputs['genesis'],self.cfg['staking'],value=0)
        self.rpc.set(sp,'operators(address)',self.inputs['genesis'],value=[0]*9)
        for account in self.inputs['accounts']:
            who=account['account']
            for target,sig,args in [
                (self.cfg['registry'],'hasRole(bytes32,address)',(m.role_id('ENDUSER'),who)),
                (self.cfg['registry'],'getRoleStake(bytes32,address)',(m.role_id('ENDUSER'),who)),
                (self.cfg['sbt'],'verifyCommunityMembership(address,address)',(who,self.inputs['genesis'])),
                (sp,'sbtHolders(address)',(who,)),(sp,'isEligibleForSponsorship(address)',(who,))]:
                self.rpc.set(target,sig,*args,value=0)
        self.bases=copy.deepcopy(t.BASELINES)
    def build(self):
        with patch.object(m,'collect_phase_c',side_effect=copy.deepcopy(self.pins)):
            return q.build(self.cfg,self.inputs,self.rpc,self.evidence,self.cal,self.bases)
    def test_three_plans_shared_operator_and_senders(self):
        result=self.build(); plans=list(result['plans'].values())
        self.assertEqual([p['phaseC']['attempts'] for p in plans],[34,33,33])
        for key in ('X','T','Q','VPM','TPM','oracle'):
            self.assertEqual(len({p['phaseC']['addresses'][key] for p in plans}),1)
        steps=result['steps']; self.assertEqual(sum(s['id'].endswith('/C2.deposit') for s in steps),1)
        self.assertFalse(any(s['tx']['from']==self.cfg['deployer'] for s in steps))
        self.assertEqual([s['requiredSignatures'] for s in result['safeTransactions']],[2,2,2,2])
        self.assertEqual(result['timelockOperation']['delay'],172800)
        for p in plans:
            self.assertEqual(p['phaseC']['spPostOp'],600000)
            self.assertEqual(p['phaseC']['bounds']['SP']['call'],90000)
            self.assertEqual(p['phaseC']['addresses']['SP'],self.cfg['superPaymaster'])
        for s in steps:
            sid=s['id'].split('/')[-1]
            if sid.startswith(('C2.','C3.')) or sid in ('C6','C7','C8'): expected=self.inputs['genesis']
            elif s['sender']=='owner': expected=plans[int(s['id'][0])]['externalInputs']['data']['phaseC']['accountOwner']
            else: expected=self.inputs['experiment']
            self.assertEqual(s['tx']['from'],expected)
    def stop(self,gate,fn):
        with self.assertRaises(a.Gate) as caught: fn()
        self.assertEqual(caught.exception.record['gate'],gate)
    def test_missing_checker(self):
        self.evidence['result']='FAIL'; self.stop('rq3_checker_pass',self.build)
    def test_checker_binding(self):
        self.evidence['configSha256']='00'*32; self.stop('rq3_checker_binding',self.build)
    def test_commit_missing(self):
        self.cfg.pop('commit'); self.stop('rq3_commit',self.build)
    def test_arm_factor_differs(self):
        self.inputs['armFactors']={'SP':2,'VPM':3,'TPM':2}; self.stop('rq3_uniform_factor',self.build)
    def test_fee_above_ceiling(self):
        self.inputs['feeCeiling']=1; self.stop('rq3_fee_ceiling',self.build)
    def test_priority_is_median_of_fee_history(self):
        pc=next(iter(self.build()['plans'].values()))['phaseC']
        # rewards 1,3,2,0,5 (x1e6) -> median 2e6; the node estimate is recorded only.
        self.assertEqual(pc['priorityCap'],2*10**6)
        self.assertEqual(pc['feeRule']['priority']['value'],2*10**6)
        self.assertEqual(pc['feeRule']['priority']['rewards'],[0,10**6,2*10**6,3*10**6,5*10**6])
        self.assertEqual(pc['feeCap'],2*10**8+2*10**6)
    def test_priority_history_short_or_zero(self):
        self.rpc.rewards=self.rpc.rewards[:3]; self.stop('rq3_priority_history',self.build)
    def test_priority_zero(self):
        self.rpc.rewards=[0]*5; self.stop('rq3_priority_zero',self.build)
    def test_priority_rule_shape(self):
        for bad in ({'blocks':0,'percentile':50},{'blocks':5,'percentile':100},{'blocks':5},{'blocks':5,'percentile':50,'x':1}):
            self.inputs['priorityRule']=bad; self.stop('rq3_priority_rule',self.build)
    def test_priority_factor_rejected(self):
        self.inputs['priorityFactor']={'numerator':1,'denominator':10}; del self.inputs['priorityRule']
        self.stop('rq3_priority_rule',self.build)
    def test_factor_invalid(self):
        self.inputs['gasFactor']['denominator']=0; self.stop('rq3_factor',self.build)
    def test_stake_missing(self):
        self.inputs['stakeWei']=0; self.stop('rq3_stake',self.build)
    def test_genesis_wrong(self):
        self.inputs['genesis']=address(999); self.stop('rq3_genesis',self.build)
    def test_deployer_forbidden(self):
        self.inputs['experiment']=self.cfg['deployer']; self.stop('rq3_identities',self.build)
    def test_duplicate_owner(self):
        self.inputs['accounts'][1]['accountOwner']=self.inputs['accounts'][0]['accountOwner']; self.stop('rq3_identities',self.build)
    def test_pp_changed(self):
        result=self.build(); plan=next(iter(result['plans'].values()))
        self.rpc.set(self.cfg['superPaymaster'],'gasParams()',value=[500001,400000,10000,10000,0,0,0,0,0])
        self.stop('C_gas_tuple',lambda:q.pre_send(self.rpc,plan))
    def test_sp_address_precheck(self):
        plan=next(iter(self.build()['plans'].values())); pc=plan['phaseC']; sp=self.cfg['superPaymaster']
        self.rpc.set(sp,'cachedPrice()',value=[3000*10**8,100,1,8])
        for sig in ('renewalMode(address)','autoRenewUsed(address)'): self.rpc.set(pc['addresses']['X'],sig,pc['addresses']['S'],value=0)
        self.rpc.set(pc['addresses']['X'],'autoAllowance(address,address)',pc['addresses']['S'],sp,value=[m.PC_CAP_L,0])
        self.rpc.set(pc['addresses']['X'],'userTotal(address)',pc['addresses']['S'],value=[m.PC_CAP_L,0])
        self.assertEqual(m.price_gate(self.rpc,plan=plan)[0],3000*10**8)
        self.assertEqual(m.sp_attempt_precheck(self.rpc,plan)['Amax'],pc['Amax'])
    def test_readonly(self):
        self.stop('rq3_readonly',lambda:q.ReadOnly(self.rpc)('eth_sendTransaction',[]))


# Negative inputs exercise each new plan gate; the suppression harness records fail-first reds.
def negative(name,gate,mutate):
    def test(self):
        mutate(self)
        self.stop(gate,self.build)
    setattr(ThreeArm,'test_gate_'+name,test)

negative('checker_log','rq3_checker_log',lambda t:t.evidence.update(stdout='FAIL checker\n'+t.evidence['stdout']))
negative('checker_chain','rq3_checker_chain',lambda t:t.evidence.update(chainId=1))
negative('bad_address','rq3_address',lambda t:t.inputs.update(experiment='bad'))
negative('calibration','rq3_calibration',lambda t:t.cal['source'].update(evidenceSha256='bad'))
negative('measurement','rq3_measurement',lambda t:t.cal['arms']['SP'].update(call=-1))
negative('fields','rq3_gas_fields',lambda t:t.cal['arms']['TPM'].pop('call'))
negative('gas_bounds','rq3_gas_bounds',lambda t:t.cal['arms']['TPM'].update(call=2**129))
negative('pending_gas','rq3_gas_pending',lambda t:t.rpc.set(t.cfg['superPaymaster'],'gasParams()',value=[500000,400000,10000,10000,0,0,0,0,1]))
negative('accounting','rq3_fresh_accounting',lambda t:t.rpc.set(t.cfg['superPaymaster'],'totalTrackedBalance()',value=1))
negative('owner','rq3_sp_owner',lambda t:t.rpc.set(t.cfg['superPaymaster'],'owner()',value=1))
negative('paused','rq3_unpaused',lambda t:t.rpc.set(t.cfg['superPaymaster'],'paused()',value=1))
negative('factory','rq3_factory_fresh',lambda t:t.rpc.set(t.cfg['xPNTsFactoryV2'],'getDeployedCount()',value=1))
negative('threshold','rq3_safe_threshold',lambda t:t.rpc.set(t.cfg['governanceOwner'],'getThreshold()',value=1))
negative('delay','rq3_timelock_delay',lambda t:t.rpc.set(t.cfg['timelockController'],'getMinDelay()',value=1))
negative('unlocking','rq3_stake_not_unlocking',lambda t:t.rpc.set(t.cfg['entryPoint'],'getDepositInfo(address)',t.cfg['superPaymaster'],value=[0,0,0,0,1]))
negative('configured','rq3_genesis_unconfigured',lambda t:t.pins[0]['sp']['deployerOperator'].__setitem__(1,1))
negative('shared_pin','rq3_shared_pin',lambda t:t.pins[1]['capped'].update(totalSupply=1))
negative('gtoken','rq3_safe_gtoken',lambda t:([p['endUser'].update(deployerGToken=0) for p in t.pins],t.rpc.set(t.cfg['gToken'],'balanceOf(address)',t.cfg['governanceOwner'],value=0)))
negative('headroom','rq3_cap_headroom',lambda t:[p['capped'].update(cap=0) for p in t.pins])


class SendGates(unittest.TestCase):
    setUp=ThreeArm.setUp
    build=ThreeArm.build
    stop=ThreeArm.stop
    def ready(self):
        plan=next(iter(self.build()['plans'].values())); pc=plan['phaseC']; sp=self.cfg['superPaymaster']
        for sig,val in [('cachedPrice()',[3000*10**8,100,1,8]),('aPNTsPriceUSD()',pc['aPNTsPriceUSD']),
                        ('protocolFeeBPS()',pc['protocolFeeBPS']),('priceStalenessThreshold()',4200)]: self.rpc.set(sp,sig,value=val)
        self.rpc.set(self.cfg['entryPoint'],'getDepositInfo(address)',sp,value=[0,1,10**18,86400,0])
        self.rpc.set(sp,'operators(address)',self.inputs['genesis'],value=[0,1,0,0,0,60,0,0,0])
        return plan
    def test_send_clean(self): q.pre_send(self.rpc,self.ready())
    def test_send_stake_missing(self):
        plan=self.ready(); self.rpc.set(self.cfg['entryPoint'],'getDepositInfo(address)',self.cfg['superPaymaster'],value=[0,0,0,0,0])
        self.stop('rq3_send_stake',lambda:q.pre_send(self.rpc,plan))
    def test_send_stake_amount_or_delay_differs(self):
        # Readback must equal the plan's inputs exactly, not merely exceed them.
        for info in ([0,1,10**18+1,86400,0],[0,1,10**18,86401,0],[0,1,10**18,86400,1]):
            plan=self.ready(); self.rpc.set(self.cfg['entryPoint'],'getDepositInfo(address)',self.cfg['superPaymaster'],value=info)
            self.stop('rq3_send_stake',lambda:q.pre_send(self.rpc,plan))
    def test_send_stale_price(self):
        plan=self.ready(); self.rpc.head['timestamp']=hex(5000)
        self.stop('rq3_send_price_fresh',lambda:q.pre_send(self.rpc,plan))
    def test_send_fee(self):
        plan=self.ready(); plan['phaseC']['feeCap']=1
        self.stop('rq3_send_fee',lambda:q.pre_send(self.rpc,plan))
    def test_send_fee_above_input_ceiling(self):
        plan=self.ready(); plan['phaseC']['feeCap']=plan['phaseC']['feeRule']['ceiling']+1
        self.stop('rq3_send_fee',lambda:q.pre_send(self.rpc,plan))
    def test_send_chain(self):
        plan=self.ready(); plan['chainId']=1
        self.stop('rq3_send_chain',lambda:q.pre_send(self.rpc,plan))
    def test_send_paused(self):
        plan=self.ready(); self.rpc.set(self.cfg['superPaymaster'],'paused()',value=1)
        self.stop('rq3_send_unpaused',lambda:q.pre_send(self.rpc,plan))
    def test_send_pricing(self):
        plan=self.ready(); self.rpc.set(self.cfg['superPaymaster'],'aPNTsPriceUSD()',value=1)
        self.stop('rq3_send_pricing',lambda:q.pre_send(self.rpc,plan))

class ReadGates(unittest.TestCase):
    def test_agreement(self):
        with self.assertRaises(a.Gate) as caught: q.Pair(lambda *x:1,lambda *x:2)
        self.assertEqual(caught.exception.record['gate'],'rq3_rpc_agreement')
    def test_reorg(self):
        rpc=Fake(); pair=q.Pair(rpc,rpc); rpc.head=dict(rpc.head,hash='0x'+'34'*32)
        with self.assertRaises(a.Gate) as caught: pair.finish()
        self.assertEqual(caught.exception.record['gate'],'rq3_reorg')
    def test_no_outside_path(self):
        with self.assertRaises(a.Gate) as caught: q.inside(q.ROOT.parent)
        self.assertEqual(caught.exception.record['gate'],'rq3_path')

negative('chain','rq3_chain',lambda t:setattr(t.rpc,'chainId','0x1'))
negative('nonce','rq3_pending_nonce',lambda t:setattr(t.rpc,'pending',1))
negative('eoa','rq3_eoa',lambda t:setattr(t.rpc,'code','0x6000'))

def setup_budget_test(self):
    bundle=self.build()
    self.rpc.balance=sum(a.qty(s['tx']['value']) for s in bundle['steps'] if s['sender']=='deployer')
    self.stop('rq3_setup_budget',self.build)
ThreeArm.test_setup_gas_budget=setup_budget_test

def builder_chain_test(self):
    original=m.build_phase_c
    def wrong_chain(**kw):
        kw['chain_id']=1
        return original(**kw)
    with patch.object(m,'build_phase_c',side_effect=wrong_chain): self.stop('C_chain_binding',self.build)
ThreeArm.test_builder_chain_binding=builder_chain_test

negative('amax','C_amax_cap',lambda t:t.cal['arms']['SP'].update(call=10**9))

class Transport(unittest.TestCase):
    def test_bad_envelope(self):
        import io
        rpc=q.http_transport('https://example.invalid',opener=lambda *a,**k:io.StringIO('{}'))
        with self.assertRaises(a.Gate) as c:rpc('eth_chainId',[])
        self.assertEqual(c.exception.record['gate'],'rq3_rpc_result')
    def test_transport_redacts(self):
        def fail(*args,**kw):raise OSError('secret URL')
        with self.assertRaises(a.Gate) as c:q.http_transport('https://example.invalid',opener=fail)('eth_chainId',[])
        self.assertEqual(c.exception.record['gate'],'rq3_rpc_transport')
        self.assertNotIn('secret',str(c.exception.record))

if __name__=='__main__': unittest.main()
