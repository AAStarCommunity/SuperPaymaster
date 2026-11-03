#!/usr/bin/env python3
"""DSR C2/C3 archived a6-gauge-credit fixtures, checked by the actual validator."""
from pathlib import Path
import subprocess
import unittest
ROOT=Path(__file__).resolve().parents[2]
class A6Controls(unittest.TestCase):
    def validate(self,name):
        return subprocess.run(['node',str(ROOT/'script/a6-collector/validate.mjs'),str(ROOT/'docs/design/aoa-balance-mode/data/a6-gauge-credit'/f'{name}.jsonl')],capture_output=True,text=True)
    def test_credit_off(self):
        result=self.validate('credit-off')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
    def test_credit_on(self):
        result=self.validate('credit-on')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('credit policy is not OFF',result.stdout+result.stderr)
    def test_credit_queued(self):
        result=self.validate('credit-queued')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('credit policy change is queued',result.stdout+result.stderr)
if __name__=='__main__': unittest.main()
