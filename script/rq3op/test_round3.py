import copy
import unittest
from unittest.mock import patch
from test_three_arm import ThreeArm, q, m, a, address

class Round3(ThreeArm):
    def test_shared(self):
        result=self.build(); shared=result['shared']
        for key in ('T','R','SP','chainId','commit','configSha256','taskCallData','taskRecipients'):
            self.assertIn(key,shared)
        self.assertEqual(shared['commit'],self.cfg['commit'])
        self.assertEqual(shared['chainId'],10)
        self.assertEqual(shared['configSha256'],q.digest(self.cfg))
        self.assertEqual(shared['SP'],self.cfg['superPaymaster'])
        self.assertEqual(shared['R'],m.DEAD)
        expected=a.calldata('execute(address,uint256,bytes)',shared['T'],0,a.calldata('transfer(address,uint256)',m.DEAD,1))
        self.assertEqual(shared['taskCallData'],expected)
        for plan in result['plans'].values():
            self.assertEqual(plan['phaseC']['addresses']['T'],shared['T'])
            self.assertEqual(plan['phaseC']['taskCallData'],expected)

    def test_recipients_required(self):
        del self.inputs['taskRecipients']; self.stop('rq3_task_recipients',self.build)

    def test_recipients_invalid(self):
        for entries in (None,{},[dict(address=address(900),amount=300)],
            [dict(address=address(0),amount=301)],
            [dict(address=m.DEAD,amount=301)],
            *[[dict(address=x['account'],amount=301)] for x in self.inputs['accounts']],
            [dict(address=address(900),amount=301)]*2,
            [dict(address='bad',amount=301)], [dict(address=address(900),amount=True)]):
            with self.subTest(entries=entries):
                self.inputs['taskRecipients']=entries
                self.stop('rq3_task_recipients',self.build)

    def extras(self):
        self.inputs['taskRecipients']=[dict(address=address(900+i),amount=301+i) for i in range(2)]
        self.cal['setup'].update({'C11.extra.0':51000,'C11.extra.1':52000})

    def test_extra_mints(self):
        self.extras(); result=self.build(); steps=result['steps']
        self.assertEqual(result['shared']['taskRecipients'],self.inputs['taskRecipients'])
        for plan in result['plans'].values(): self.assertEqual(plan['taskRecipients'],self.inputs['taskRecipients'])
        for i,entry in enumerate(self.inputs['taskRecipients']):
            sid='0/C11.extra.'+str(i); step=next(s for s in steps if s['id']==sid)
            self.assertGreater(steps.index(step),next(j for j,s in enumerate(steps) if s['id']=='0/C11.R'))
            self.assertEqual(step['tx']['from'],self.inputs['experiment'])
            self.assertEqual(step['tx']['to'],result['shared']['T'])
            self.assertEqual(step['tx']['data'],a.calldata('mint(address,uint256)',entry['address'],entry['amount']))
            self.assertIn(m.word_pred(result['shared']['T'],'balanceOf(address)',entry['amount'],entry['address']),step['readbacks'])
            self.assertEqual(a.qty(step['tx']['gas']),q.scale(self.cal['setup']['C11.extra.'+str(i)],self.inputs['gasFactor']))
        self.assertEqual(sum('C11.extra.' in s['id'] for s in steps),2)

    def test_extra_budget(self):
        self.extras(); self.cal['setup']['C11.extra.0']=10**30
        self.stop('rq3_setup_budget',self.build)

    def test_extra_calibration_required(self):
        self.extras(); del self.cal['setup']['C11.extra.0']
        self.stop('rq3_task_calibration',self.build)

    def test_shared_mismatch(self):
        original=m.build_phase_c
        def different(**kw):
            pc,n=original(**kw)
            if kw['inputs']['salt']==1: pc['addresses']['T']=address(999)
            return pc,n
        with patch.object(m,'build_phase_c',side_effect=different): self.stop('rq3_shared_task',self.build)

    def test_shared_calldata_mismatch(self):
        original=m.build_phase_c
        def different(**kw):
            pc,n=original(**kw)
            if kw['inputs']['salt']==1: pc['taskCallData']='0x'
            return pc,n
        with patch.object(m,'build_phase_c',side_effect=different): self.stop('rq3_shared_task',self.build)

def load_tests(loader,tests,pattern):
    return unittest.TestSuite(Round3(name) for name in Round3.__dict__ if name.startswith('test_'))
