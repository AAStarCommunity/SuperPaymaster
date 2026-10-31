"""Evidence regression tests. Run: python3 contracts/test/postop_multiop_evidence_test.py RUN_DIR.

Expected values live in fixtures/postop-multiop-expected.json; the runner never updates them.
The negative control removes a whole case, then re-seals hashes: inventory must still fail.
"""
import importlib.util, hashlib, json, pathlib, shutil, subprocess, sys, tempfile, unittest

RUN = pathlib.Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location('verify', 'script/evidence/postop-multiop-verify.py')
verify = importlib.util.module_from_spec(spec); spec.loader.exec_module(verify)

class MultiOpEvidenceTest(unittest.TestCase):
    def test_frozen_per_operation_measurements_and_complete_inventory(self):
        verify.verify(RUN)

    def test_missing_case_rejected_even_with_resealed_manifest(self):
        with tempfile.TemporaryDirectory(prefix='multiop-negative-', dir='/tmp') as tmp:
            out = pathlib.Path(tmp)/'run'
            shutil.copytree(RUN,out)
            rows = [json.loads(s) for s in (out/'commands.jsonl').read_text().splitlines()]
            missing = rows.pop(0)['id']
            (out/'commands.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows))
            (out/f'{missing}.log').unlink()
            (out/f'{missing}-steps.json').unlink()
            numbers = json.loads((out/'numbers.json').read_text()); del numbers[missing]
            (out/'numbers.json').write_text(json.dumps(numbers))
            (out/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(out.iterdir()) if p.is_file() and p.name != 'SHA256SUMS'))
            with self.assertRaisesRegex(AssertionError, 'requires 72 matrix cases'):
                verify.verify(out)
            result = subprocess.run([sys.executable, 'script/evidence/postop-multiop-verify.py', str(out)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn('requires 72 matrix cases', result.stderr)
            print('NEGATIVE CONTROL PASS: verifier exit 1; rejects missing case',missing)

if __name__ == '__main__': unittest.main()
