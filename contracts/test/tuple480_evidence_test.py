"""Independent integrity controls for the tuple480 retained run."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
RUN=Path(sys.argv.pop(1)).resolve()
spec=importlib.util.spec_from_file_location('runner',ROOT/'script/evidence/tuple480-run.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
runner.EVIDENCE=RUN

class EvidenceTest(unittest.TestCase):
    def test_complete_inventory(self):
        rows=runner.verify(RUN)
        self.assertEqual(sum(r['kind']=='full' for r in rows),6)
        self.assertEqual(sum(r['kind']=='multi' for r in rows),24)
        self.assertEqual(sum(r['kind']=='worst-net' for r in rows),6)
        self.assertEqual(len({(r['engine'],r['settle'],r['credit'],r['legacy'],r['nonfresh']) for r in rows if r['kind']=='scan'}),96)

    def test_resealed_missing_command_cli_rejected(self):
        with tempfile.TemporaryDirectory(prefix='tuple480-control-',dir='/tmp') as tmp:
            neg=Path(tmp)/'run';shutil.copytree(RUN,neg)
            rows=(neg/'commands.jsonl').read_text().splitlines()
            (neg/'commands.jsonl').write_text('\n'.join(rows[1:])+'\n')
            runner.seal(neg)
            p=subprocess.run([sys.executable,str(ROOT/'script/evidence/tuple480-run.py'),'--verify',str(neg)],capture_output=True,text=True)
            (RUN.parent/'missing-command-control.log').write_text(p.stdout+p.stderr+f'\nexit {p.returncode}\n')
            self.assertEqual(p.returncode,1)
            self.assertIn('missing command inventory',p.stderr)

    def test_outcome_changes_and_reimbursement(self):
        for engine in runner.ENGINES:
            current,candidate=[runner.statuses((RUN/f'full-{engine}-{n}.log').read_text()) for n in (0,1)]
            self.assertEqual(set(current),set(candidate))
            failures=[k for k in current if current[k]=='PASS' and candidate[k]=='FAIL']
            self.assertEqual(len(failures),14)
            for key in failures:
                self.assertTrue(any(name in key for name in ('SuperPaymasterPostOpGasMatrix.t.sol','SuperPaymasterPostOpGasProfile.t.sol','SuperPaymasterPostOpMultiOp.t.sol')),key)
            for key in current:
                if 'RR5' in key: self.assertEqual(current[key],candidate[key],key)
                if 'testFuzz_G2_I8_I9_I10_conservation' in key or 'test_G2_coverage_replay_fixed_seeds' in key:
                    self.assertEqual(candidate[key],'PASS',key)

    def test_boundaries_and_accounting_reduction(self):
        p=subprocess.run([sys.executable,str(ROOT/'script/evidence/tuple480-report.py'),str(RUN)],capture_output=True,text=True,check=True)
        data=json.loads(p.stdout)
        self.assertEqual(len(data['boundaries']),96)
        for engine in runner.ENGINES:
            bounds=[r['boundary'] for r in data['boundaries'] if r['engine']==engine and r['settle']==450000]
            self.assertEqual(len(bounds),8)
            self.assertGreaterEqual(480000-max(bounds),10000)
        for r in data['accounting']:
            if r['limit']==480000: self.assertGreater(r['margin_gas'],0)
            self.assertEqual(r['prefund_increase_to480'],480000-r['limit'])
            self.assertEqual(r['penalty_increase_to480'],(480000-r['limit'])//10)

if __name__=='__main__': unittest.main()
