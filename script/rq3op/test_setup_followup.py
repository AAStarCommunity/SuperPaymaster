"""Offline follow-up behavior; recorded red before implementation."""
import copy
import io
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch
import test_three_arm as t
from test_three_arm import address, q, m, a

class Followup(unittest.TestCase):
    setUp=t.ThreeArm.setUp
    build=t.ThreeArm.build
    stop=t.ThreeArm.stop

    def ready_inputs(self):
        self.inputs.update(minTxInterval=60, extraEndUsers=[])
        self.cal['setup']['C3.limits']=123456

    def test_limits_step_and_calibration(self):
        self.ready_inputs()
        bundle=self.build(); steps=bundle['steps']
        step=next(s for s in steps if s['id']=='0/C3.limits')
        self.assertEqual(steps[steps.index(step)-1]['id'],'0/C3.configure')
        self.assertEqual(step['tx']['from'],self.inputs['genesis'])
        self.assertEqual(step['tx']['data'],a.calldata('setOperatorLimits(uint48)',60))
        self.assertEqual(a.qty(step['tx']['gas']),185184)
        self.assertEqual(step['readbacks'][0]['expected'],60)
        configured=steps[steps.index(step)-1]
        self.assertEqual(configured['readbacks'][0]['expected'][5],0)
        self.assertEqual(len([s for s in steps if s['id'].endswith('/C3.limits')]),1)
        for p in bundle['plans'].values(): self.assertEqual(p['phaseC']['minTxInterval'],60)

    def test_required_interval(self):
        for value in (None,True,-1,2**48):
            self.ready_inputs()
            if value is None:self.inputs.pop('minTxInterval')
            else:self.inputs['minTxInterval']=value
            self.stop('rq3_interval',self.build)

    def test_interval_above_sampler_spacing_stops(self):
        # schedule.py guarantees >= 60 s per account; a larger SP limit would reject planned rows.
        self.ready_inputs(); self.inputs['minTxInterval']=61
        self.stop('rq3_interval_vs_schedule',self.build)

    def test_extra_endusers_overlap_and_funding(self):
        self.ready_inputs(); who=address(900)
        amount=self.build()['shared']['sdkLive']['perUserFloor']
        self.inputs['extraEndUsers']=[dict(address=who,xAmount=amount)]
        self.inputs['taskRecipients']=[dict(address=address(901),amount=456)]
        self.cal['setup'].update({'C11.extra.0':100000,**{f'C8.extra.0.{s}':100000 for s in ('approve','role','mint')}})
        self.rpc.set(self.cfg['registry'],'hasRole(bytes32,address)',m.role_id('ENDUSER'),who,value=0)
        with redirect_stderr(io.StringIO()) as log: bundle=self.build()
        self.assertIn(who,log.getvalue()); self.assertIn('no code',log.getvalue())
        self.assertEqual(bundle['shared']['recipientPurposes'][who],['RQ2 live E2E'])
        p=next(iter(bundle['plans'].values())); pc=p['phaseC']
        mint=next(s for s in bundle['steps'] if s['id']=='0/C8.extra.0.mint')
        self.assertEqual(mint['tx']['to'],pc['addresses']['X'])
        self.assertEqual(mint['tx']['from'],self.inputs['genesis'])
        self.assertEqual(mint['tx']['data'],a.calldata('mint(address,uint256)',who,amount))
        role=next(s for s in bundle['steps'] if s['id']=='0/C8.extra.0.role')
        self.assertEqual(role['tx']['data'],a.calldata('safeMintForRole(bytes32,address,bytes)',m.role_id('ENDUSER'),who,a.cast('abi-encode','c(address,uint256)',self.inputs['genesis'],pc['endUserStake'])))
        self.assertEqual(bundle['funding']['genesisGToken']['held'],1000)
        self.assertEqual(bundle['funding']['genesisGToken']['extraEndUsers'],pc['endUserStake']+pc['endUserTicket'])
        self.assertEqual(bundle['funding']['tokens'][pc['addresses']['X']],sum(p['phaseC']['userTarget'] for p in bundle['plans'].values())+amount)
        self.assertNotIn(who,bundle['plans'])

    def test_extra_rejects_collisions_and_duplicates(self):
        self.ready_inputs()
        forbidden=[a.ZERO,self.inputs['experiment'],self.inputs['bundler'],self.inputs['verifyingSigner']]
        forbidden += [x[k] for x in self.inputs['accounts'] for k in ('account','accountOwner')]
        for who in forbidden:
            self.inputs['extraEndUsers']=[dict(address=who,xAmount=1)]
            self.stop('rq3_extra_endusers',self.build)
        self.inputs['extraEndUsers']=[dict(address=address(900),xAmount=1)]*2
        self.stop('rq3_extra_endusers',self.build)

    def test_entrypoint_pin_and_single_read(self):
        self.ready_inputs(); bundle=self.build()
        for p in bundle['plans'].values():self.assertEqual(p['entryPointPin']['codehash'],'0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58')
        self.assertEqual(len([r for r in self.rpc.reads if r[0]=='eth_getCode' and r[1][0]==self.cfg['entryPoint']]),1)

    def test_entrypoint_mismatch(self):
        self.ready_inputs()
        original=self.rpc
        def rpc(method,params):
            if method=='eth_getCode' and params[0]==self.cfg['entryPoint']:return '0x6000'
            return original(method,params)
        self.rpc=rpc
        self.stop('rq3_entrypoint_v07',self.build)

    def test_interval_changed_pre_send(self):
        self.ready_inputs(); plan=t.SendGates.ready(self)
        self.rpc.set(self.cfg['superPaymaster'],'operators(address)',self.inputs['genesis'],value=[0,1,0,0,0,61,0,0,0])
        self.stop('rq3_send_interval',lambda:q.pre_send(self.rpc,plan))

    def test_limits_calibration_required(self):
        self.ready_inputs(); del self.cal['setup']['C3.limits']
        self.stop('rq3_limits_calibration',self.build)
