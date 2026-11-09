import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from collections import Counter
from schedule import generate, digest, ARMS
from precheck import POLICY_GATES, before_sp_attempt, broadcast_disabled, stop_reason, timing_check, account_available
from export import export, normalized, write_csv, validate_csv, build_inventory, gate, VENDOR

ROOT = Path(__file__).parent


class ScheduleTests(unittest.TestCase):
    def test_schedule(self):
        golden=json.loads((ROOT/'examples/schedule.json').read_text())
        self.assertEqual(golden['sha256'],generate('synthetic-public-seed',[f'0x{i:040x}' for i in (2,3,4)])['sha256'])
        for seed in ('public-beacon-20261010', 'another-seed'):
            schedule = generate(seed, ['a','b','c'])
            self.assertEqual(schedule, generate(seed, ['a','b','c']))
            self.assertEqual(schedule['sha256'], digest(schedule['payload']))
            slots = schedule['payload']['slots']
            self.assertEqual(len(slots), 60)
            self.assertEqual(sorted(Counter(tuple(s['order']) for s in slots[:50]).values()), [8,8,8,8,9,9])
            for arm in ARMS:
                self.assertEqual(sorted(Counter(s['senders'][arm] for s in slots[:50]).values()), [16,17,17])
            for account in ['a','b','c']:
                selected = [s for s in slots if s['senders']['SP'] == account]
                for a,b in zip(selected, selected[1:]):
                    self.assertGreaterEqual(b['start_seconds'] - a['deadline_seconds'],60)
            self.assertTrue(all(s['deadline_seconds']-s['start_seconds']==20 for s in slots))
        with self.assertRaises(ValueError):
            generate('seed',['a','b','c'],20,1)


class Refusal(Exception):
    def __init__(self, gate, observed=1, expected=0):
        self.record = dict(gate=gate, observed=observed, expected=expected, url='not archived')


class PrecheckTests(unittest.TestCase):
    def test_both_endpoints_even_if_refused(self):
        plans = {'alice': {'phaseC': {'addresses': {'S':'alice'}}}}
        calls, seen = [], []
        def helper(rpc, plan, flags):
            calls.append(plan['phaseC']['addresses']['S'])
            head = rpc('eth_getBlockByNumber',['latest',False])
            reply = rpc('eth_call',[{}, head['number']])
            if reply == 'refuse':
                raise Refusal('precheck_total')
            if reply == 'bug':
                raise KeyError('sampler defect')
            return dict(block=head['number'],blockHash=head['hash'],flags=flags)
        def rpc(hash='0xaa', reply='ok', number='0x1'):
            def call(method, params):
                seen.append((method, list(params)))
                return dict(number=number,hash=hash) if method=='eth_getBlockByNumber' else reply
            return call
        run = lambda eps, who='alice': before_sp_attempt(eps,plans,who,helper,Refusal)
        result=run([rpc(),rpc()])
        self.assertFalse(result['precheck_refused'])
        self.assertEqual(len(calls),2)
        # the second endpoint is asked for the first endpoint's block, never its own 'latest'
        heads = [p for m, p in seen if m == 'eth_getBlockByNumber']
        self.assertEqual([h[0] for h in heads], ['latest', '0x1', '0x1', '0x1'])
        result=run([rpc(),rpc('0xbb')])
        self.assertEqual(result['invalid_reason'],'rpc_mismatch')
        self.assertTrue(result['precheck_refused'])
        result=run([rpc(reply='refuse'),rpc(reply='refuse')])
        self.assertTrue(result['precheck_refused'])
        self.assertEqual(result['invalid_reason'],'')
        self.assertEqual([r['blockHash'] for r in result['endpoints']],['0xaa','0xaa'])
        self.assertEqual(len(calls),6)
        # a non-Gate exception is a defect: it propagates instead of being logged as a refusal
        with self.assertRaises(KeyError):
            run([rpc(reply='bug'),rpc()])
        with self.assertRaises(KeyError):
            run([rpc(),rpc()],'bob')
        with self.assertRaises(NotImplementedError):
            broadcast_disabled()
        # every state read reaches the endpoint bound to the anchor HASH (EIP-1898)
        state = [p for m, p in seen if m == 'eth_call']
        self.assertTrue(state and all(p[-1] in ({'blockHash':'0xaa','requireCanonical':True},
                                                {'blockHash':'0xbb','requireCanonical':True}) for p in state))

    def test_state_read_must_name_the_anchor_block(self):
        plans = {'alice': {'phaseC': {'addresses': {'S':'alice'}}}}
        rpc = lambda method, params: dict(number='0x1',hash='0xaa') if method=='eth_getBlockByNumber' else 'ok'
        for bad in (['latest'], ['0x2'], []):
            def helper(rpc, plan, flags, bad=bad):
                rpc('eth_getBlockByNumber',['latest',False])
                rpc('eth_call',[{}, *bad])
            with self.assertRaisesRegex(ValueError,'not bound to the anchor block'):
                before_sp_attempt([rpc,rpc],plans,'alice',helper,Refusal)
        def before_head(rpc, plan, flags):
            rpc('eth_call',[{}, '0x1'])
        with self.assertRaisesRegex(ValueError,'not bound to the anchor block'):
            before_sp_attempt([rpc,rpc],plans,'alice',before_head,Refusal)

    def test_policy_gates_and_unpinned_refusal(self):
        plans = {'alice': {'phaseC': {'addresses': {'S':'alice'}}}}
        def rpc(method, params):
            return dict(number='0x1',hash='0xaa')
        for name in POLICY_GATES | {'rpc_result', 'canonical_quantity', 'unknown'}:
            calls = []
            def helper(rpc, plan, flags):
                calls.append(flags)
                raise Refusal(name)
            if name in POLICY_GATES:
                result=before_sp_attempt([rpc,rpc],plans,'alice',helper,Refusal)
                self.assertEqual(len(calls),2)
                self.assertEqual(result['endpoint_pins'],[None,None])
                self.assertEqual(result['invalid_reason'],'')
                self.assertTrue(result['precheck_refused'])
                self.assertEqual(result['endpoints'][0]['refusal'],dict(gate=name,observed=1,expected=0))
            else:
                with self.assertRaises(Refusal):
                    before_sp_attempt([rpc,rpc],plans,'alice',helper,Refusal)
        def helper(rpc, plan, flags):
            if not seen:
                seen.append(True)
                raise Refusal('SP_RENEW_never')
            head=rpc('eth_getBlockByNumber',['latest',False])
            return dict(block=head['number'],blockHash=head['hash'])
        seen, reads = [], []
        def second(method, params):
            reads.append(params[0])
            return rpc(method,params)
        result=before_sp_attempt([rpc,second],plans,'alice',helper,Refusal)
        self.assertEqual(reads,['latest','0x1'])
        self.assertEqual(result['endpoint_pins'],[None,None])
        for gates in [('precheck_total','precheck_allowance'), ('precheck_total','precheck_total')]:
            names=iter(gates)
            values=iter([1,2])
            def refuse(rpc, plan, flags):
                raise Refusal(next(names),next(values))
            result=before_sp_attempt([rpc,rpc],plans,'alice',refuse,Refusal)
            self.assertEqual(result['invalid_reason'],'rpc_mismatch')
        def no_anchor(rpc, plan, flags):
            return dict(block='0x1',blockHash='0xaa')
        with self.assertRaisesRegex(ValueError,'anchor missing'):
            before_sp_attempt([rpc,rpc],plans,'alice',no_anchor,Refusal)

    def test_post_read_reorg_after_acceptance_or_refusal(self):
        plans = {'alice': {'phaseC': {'addresses': {'S':'alice'}}}}
        for refused in (False,True):
            for endpoint in (0,1):
                def helper(rpc, plan, flags):
                    head=rpc('eth_getBlockByNumber',['latest',False])
                    if refused: raise Refusal('precheck_total')
                    return dict(block=head['number'],blockHash=head['hash'])
                def rpc(changed):
                    hashes=iter(['0xaa','0xbb' if changed else '0xaa'])
                    return lambda method,params: dict(number='0x1',hash=next(hashes))
                result=before_sp_attempt([rpc(endpoint==0),rpc(endpoint==1)],plans,'alice',helper,Refusal)
                self.assertEqual(result['invalid_reason'],'chain_reorg')
                self.assertTrue(result['precheck_refused'])

    def test_observed_timing_and_timeout_account_lock(self):
        slot=generate('seed',['a','b','c'])['payload']['slots'][0]
        starts={a:i*3 for i,a in enumerate(slot['order'])}
        finishes={a:t+2 for a,t in starts.items()}
        timing_check(slot,starts,finishes,{})
        with self.assertRaises(ValueError):
            timing_check(slot,starts,finishes,{slot['senders']['SP']:0})
        attempts=[dict(sender='a',failure_reason='receipt_timeout')]
        self.assertFalse(account_available('a',attempts))
        attempts[0]['resolution']='included_late'
        self.assertTrue(account_available('a',attempts))

    def test_stop_rules(self):
        make=lambda values:[dict(infrastructure_failure=x) for x in values]
        self.assertIsNone(stop_reason(make([True]+[False]*19)))
        self.assertIsNone(stop_reason(make([True,False,True]+[False]*16)))
        self.assertEqual(stop_reason(make([True,False,True]+[False]*17)), 'infrastructure_failures_above_5_percent')
        self.assertEqual(stop_reason(make([True]*3)), 'three_consecutive_infrastructure_failures')


class ExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.directory=Path(cls.temp.name)
        records=cls.directory/'records.json'
        subprocess.run(['node',str(ROOT/'fixtures.mjs'),str(records)],check=True)
        cls.records=json.loads(records.read_text())

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_supplied_state_columns_are_flagged_and_blank_by_default(self):
        tpm=[r for r in self.records if r['arm']=='TokenPaymaster' and r.get('tokenChargeWei') not in (None,'')]
        self.assertTrue(tpm)
        rows=normalized(copy.deepcopy(self.records))
        out=[r for r in rows if r['arm']=='TokenPaymaster' and r['unverified_columns']]
        self.assertEqual(len(out),len(tpm))
        self.assertTrue(all(r['tokenChargeWei']=='' and 'tokenChargeWei' in r['unverified_columns'].split(';') for r in out))
        kept=normalized(copy.deepcopy(self.records),include_unverified=True)
        self.assertTrue(all(r['tokenChargeWei'] not in ('',None) for r in kept if r['unverified_columns']))
        # an incoming claim is ignored: the exporter recomputes the flag
        forged=copy.deepcopy(self.records); forged[0]['unverified_columns']=''
        self.assertEqual([r['unverified_columns'] for r in normalized(forged)],[r['unverified_columns'] for r in rows])
        legacy=copy.deepcopy(self.records)
        sp=next(r for r in legacy if r['arm']=='SP' and r.get('feeBps') not in (None,''))
        sp['feeSnap']=0
        flagged=next(r for r in normalized(legacy) if r['userOpHash']==sp['userOpHash'])
        self.assertEqual(flagged['feeBps'],'')
        self.assertIn('feeBps',flagged['unverified_columns'])

    def test_vendor_hashes(self):
        for file,sha in json.loads((ROOT/'vendor/SHA256SUMS.json').read_text()).items():
            self.assertEqual(hashlib.sha256((ROOT/'vendor'/file).read_bytes()).hexdigest(),sha)

    def test_real_gate_cli_incomplete_and_pass(self):
        path=self.directory/'window.csv'
        export(path,self.records)
        out=self.directory/'result.json'
        result=subprocess.run(['python3','-B',str(VENDOR),'--design','aoa','--csv',str(path),'--out',str(out)],capture_output=True,text=True)
        self.assertEqual(result.returncode,3,result.stderr)
        report=json.loads(out.read_text())
        self.assertEqual(report['complete_pairs'],49)
        self.assertEqual(report['incomplete_block_count'],3)
        self.assertEqual(report['arm_counts']['SP']['precheck_refusals'],1)
        self.assertEqual(report['arm_counts']['TokenPaymaster']['failed_formal_attempts'],1)
        # 48 initial complete blocks + retry at 51 + a fresh complete slot 52.
        rows=copy.deepcopy(self.records)
        for original in self.records[-3:]:
            r=copy.deepcopy(original)
            r.update(pair_id='block-52',block_slot=52,attempt_index=52,userOpHash=r['userOpHash']+'52',retry_of='')
            rows.append(r)
        export(path,rows)
        result=subprocess.run(['python3','-B',str(VENDOR),'--design','aoa','--csv',str(path),'--out',str(out)],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(out.read_text())['complete_pairs'],50)

    def test_negative_controls_own_checks_and_real_gate(self):
        base=normalized(self.records)
        def corrupt(kind):
            rows=copy.deepcopy(base)
            if kind=='refused_broadcast': next(r for r in rows if r['precheck_refused'])['txGasUsed']=1
            elif kind=='exclusion': rows[0]['exclusion_reason']='unsuccessful_attempt'
            elif kind=='penalty': rows[0].update(gasBeforePenalty=500000,preOpGas=100000,actualGasUsed=1)
            elif kind=='chat': next(r for r in rows if r['arm']=='SP')['chargeHatAPNTs']=1
            elif kind=='slot': rows[0]['block_slot']=60
            elif kind=='duplicate':
                r=copy.deepcopy(rows[0]); r['attempt_index']=59; r['userOpHash']='unique'; rows.append(r)
            return rows
        diagnostics = {
            'refused_broadcast': ('broadcast field on refused row', 'precheck_refused attempt was not broadcast'),
            'exclusion': ('wrong exclusion_reason', 'exclusion_reason='),
            'penalty': ('actualGasUsed - gasBeforePenalty', 'actualGasUsed - gasBeforePenalty'),
            'chat': ('reconstructed c_hat', 'reconstructed c_hat'),
            'slot': ('block_slot=60 outside', 'block_slot=60 outside'),
            'duplicate': ('several formal attempts for the same (pair_id, arm)', 'several formal attempts for the same (pair_id, arm)'),
        }
        for kind, (export_message, gate_message) in diagnostics.items():
            with self.subTest(kind=kind):
                rows=corrupt(kind)
                path=self.directory/f'{kind}.csv'
                with self.assertRaises((ValueError,gate.GateError)) as caught:
                    export(path,rows)
                self.assertIn(export_message,str(caught.exception))
                write_csv(path,rows)
                result=subprocess.run(['python3','-B',str(VENDOR),'--design','aoa','--csv',str(path)],capture_output=True,text=True)
                self.assertEqual(result.returncode,2,result.stderr)
                self.assertIn(gate_message,result.stderr)

    def test_cross_window_inventory(self):
        first=[r for r in self.records if r['block_slot']<20]
        second=copy.deepcopy([r for r in self.records if r['block_slot']>=20])
        for r in second: r.update(window_id='fixture-2',prior_formal_slots=20)
        a,b=self.directory/'a.csv',self.directory/'b.csv'
        export(a,first); export(b,second)
        inventory=build_inventory([a,b])
        self.assertEqual(inventory['payload']['consumed_formal_slots'],52)
        self.assertEqual(inventory['sha256'],digest(inventory['payload']))
        for r in second: r['prior_formal_slots']=19
        export(b,second)
        with self.assertRaises(ValueError): build_inventory([a,b])


if __name__=='__main__':
    unittest.main(verbosity=2)
