import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'upgrade'))
import json
import os
import subprocess
import tempfile
import unittest
import importlib.util
from unittest.mock import patch
import test_manifest_exec as t

ROOT = Path(__file__).resolve().parents[2]
REV = 'a6139689'

def encoded(plan):
    return json.dumps({'phaseC': plan['phaseC'], 'steps': [s for s in plan['steps'] if s.get('phase') == 'C']}, sort_keys=True, separators=(',', ':')).encode()

def original_bytes(compare_current=False):
    current=t.m
    # Separate original module, with original dependencies verified against the loaded
    # files. Fixture patches only artifact/evidence acquisition, never the planner.
    with tempfile.TemporaryDirectory(dir=ROOT/'script') as directory:
        for module in (t.m.u, t.m.a, t.m.isolation, t.m.execution_reads):
            path=Path(module.__file__)
            raw=subprocess.check_output(['git','show',REV+':'+str(path.relative_to(ROOT))],cwd=ROOT)
            if raw != path.read_bytes():
                raise AssertionError('Original dependency changed: '+str(path))
            (Path(directory)/path.name).write_bytes(raw)
        for name in ('release-evidence.schema.json','fraud-proof-fixture.schema.json'):
            (Path(directory)/name).write_bytes(subprocess.check_output(['git','show',REV+':script/upgrade/'+name],cwd=ROOT))
        path=Path(directory)/'manifest_original.py'
        path.write_bytes(subprocess.check_output(['git','show',REV+':script/upgrade/manifest_exec.py'],cwd=ROOT))
        spec=importlib.util.spec_from_file_location('manifest_original',path)
        original=importlib.util.module_from_spec(spec); spec.loader.exec_module(original)
        fixture=t.ManifestTests()
        try:
            with patch.object(t,'m',original):
                fixture.setUp()
                if compare_current:
                    actual=current.build_plan(fixture.pin,fixture.inputs)
                    if json.dumps(actual,sort_keys=True).encode() != json.dumps(fixture.plan,sort_keys=True).encode():
                        raise AssertionError('Full legacy plan differs from original bytes')
                return encoded(fixture.plan)
        finally:
            fixture.doCleanups()

GOLDEN_SHA256 = '5c9b6c4430a68a911f06f087983a533e93fbbd8c5fb0bef2376ae1351c3c4796'


class Regression(unittest.TestCase):
    def setUp(self):
        t.ManifestTests.setUp(self)

    def test_sepolia_bytes(self):
        expected=original_bytes(compare_current=True)
        self.assertEqual(encoded(self.plan),expected)
        self.assertEqual((ROOT/'script/rq3op/sepolia-phase-c.json').read_bytes(),expected)

    def test_golden_sha256_pinned(self):
        # DSR 2026-11-18: the golden file is pinned so it cannot be silently "regenerated".
        import hashlib
        raw=(ROOT/'script/rq3op/sepolia-phase-c.json').read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(),GOLDEN_SHA256)
        provenance=json.loads((ROOT/'script/rq3op/sepolia-phase-c.provenance.json').read_text())
        self.assertEqual(provenance['sha256'],GOLDEN_SHA256)
        self.assertIn(REV,provenance['generatedBy'])

    def test_one_byte_diff(self):
        expected=original_bytes()
        actual=bytearray(expected); actual[-2]^=1
        with self.assertRaises(AssertionError): self.assertEqual(bytes(actual),expected)

if __name__ == '__main__': unittest.main()
