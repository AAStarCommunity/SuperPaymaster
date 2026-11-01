"""Independent integrity controls for the tuple480 retained run."""
import importlib.util
import json
import re
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
            self.assertEqual(p.returncode,1)
            self.assertIn('missing command inventory',p.stderr)

    def rejected(self, mutate, reason):
        with tempfile.TemporaryDirectory(prefix='tuple480-control-', dir='/tmp') as tmp:
            neg = Path(tmp)/'run'
            shutil.copytree(RUN, neg)
            mutate(neg)
            runner.seal(neg)
            result = subprocess.run(
                [sys.executable, str(ROOT/'script/evidence/tuple480-run.py'), '--verify', str(neg)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn(reason, result.stderr)

    def test_resealed_prague_flags_rejected(self):
        def mutate(out):
            rows = [json.loads(line) for line in (out/'commands.jsonl').read_text().splitlines()]
            for row in rows:
                if row['engine'] == 'prague':
                    for key in ('argv', 'base_args'):
                        row[key][row[key].index('--evm-version') + 1] = 'cancun'
            (out/'commands.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
        self.rejected(mutate, 'wrong engine flags')

    def test_resealed_wrong_versions_rejected(self):
        for engine in runner.ENGINES:
            with self.subTest(engine=engine):
                self.rejected(lambda out: (out/f'{engine}-version.txt').write_text(
                    (out/f'{engine}-version.txt').read_text().replace('forge Version:', 'wrong Version:')),
                    'wrong engine version')

    def test_resealed_r1_failure_rejected(self):
        def mutate(out):
            rows = [json.loads(line) for line in (out/'commands.jsonl').read_text().splitlines()]
            prefix = 'scan-amsterdam-450000-0-0-0-'
            old = [r for r in rows if r['id'].startswith(prefix)]
            template = (out/(old[0]['id']+'.log')).read_text()
            replacement = []
            low, high, step = 100000, 800000, 0
            while True:
                budget = low if step == 0 else high if step == 1 else (low + high)//2
                accepted = int(budget >= 470001)
                row = json.loads(json.dumps(old[0]))
                row.update(id=prefix+str(step), budget=budget)
                row['env']['T480_BUDGET'] = str(budget)
                log = re.sub(r'sample gas: \d+', f'sample gas: {budget}', template)
                log = re.sub(r'admission accepted: \d', f'admission accepted: {accepted}', log)
                log = re.sub(r'settlement completed: \d', f'settlement completed: {accepted}', log)
                (out/(row['id']+'.log')).write_text(log)
                replacement.append(row)
                if step >= 2:
                    if accepted: high = budget
                    else: low = budget
                step += 1
                if step >= 2 and high-low == 1: break
            for row in old[len(replacement):]:
                (out/(row['id']+'.log')).unlink()
            start = rows.index(old[0])
            rows[start:start+len(old)] = replacement
            (out/'commands.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
        self.rejected(mutate, 'R1 margin below 10000')

    def test_resealed_sample_budget_rejected(self):
        def mutate(out):
            for path in out.glob('scan-amsterdam-450000-0-0-0-*.log'):
                text = path.read_text()
                if 'sample gas: 469304' in text:
                    path.write_text(text.replace('sample gas: 469304', 'sample gas: 1'))
                    return
            self.fail('missing boundary sample')
        self.rejected(mutate, 'sample gas contradicts command budget')

    def test_resealed_penalty_operand_rejected(self):
        def mutate(out):
            path = out/'penalties.json'
            penalties = json.loads(path.read_text())
            penalties['multi-2-0-0'][0].update(unused=10, numerator=100, penalty=1)
            path.write_text(json.dumps(penalties, indent=2)+'\n')
        self.rejected(mutate, 'penalty extraction differs from pinned archive')

    def test_resealed_noncompleting_maximum_rejected(self):
        def mutate(out):
            for path in out.glob('scan-amsterdam-450000-0-0-0-*.log'):
                text = path.read_text()
                if 'sample gas: 469305' in text:
                    path.write_text(text.replace('settlement completed: 1', 'settlement completed: 0'))
                    return
            self.fail('missing maximum sample')
        self.rejected(mutate, 'R1 maximum did not complete')

    def test_source_hashes_bound_to_recorded_revision(self):
        with tempfile.TemporaryDirectory(prefix='tuple480-control-',dir='/tmp') as tmp:
            neg=Path(tmp)/'run';shutil.copytree(RUN,neg)
            hashes=json.loads((neg/'source-hashes.json').read_text())
            hashes['contracts/test/v2/NotAtRevision.t.sol']='0'*64
            (neg/'source-hashes.json').write_text(json.dumps(hashes,indent=2))
            runner.seal(neg)
            with self.assertRaisesRegex(AssertionError,'sources differ from the recorded revision'):
                runner.verify(neg)

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
