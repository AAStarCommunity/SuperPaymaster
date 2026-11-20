"""Item 4: checker uses stable cast even when deploy-day PATH starts with nightly."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import test_ddf5 as fixture

CHECKER = Path(__file__).with_name('deploylive_postdeploy_check.py')

class DriverCastPin(unittest.TestCase):
    setUp = fixture.Ddf5Test.setUp
    driver = fixture.Ddf5Test.driver

    def test_checker_path_starts_with_cast_pin(self):
        cast = self.root/'stable'/'cast'
        cast.parent.mkdir(); cast.write_text('#!/bin/sh\nexit 0\n'); cast.chmod(0o755)
        self.driver(env_overrides={'CAST_1_7_1': str(cast), 'PATH': '/nightly:/usr/bin:/bin'})
        self.assertEqual(self.checker_env['PATH'].split(os.pathsep)[0], str(cast.parent))

    def test_missing_or_nonexecutable_pin_stops_before_checker(self):
        cast = self.root/'not-executable'; cast.write_text('not executable')
        for value in (None, str(cast), str(self.root/'absent')):
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, 'STOP.*CAST_1_7_1'):
                self.driver(env_overrides={'CAST_1_7_1': value})
            self.assertFalse(any('deploylive_postdeploy_check.py' in ' '.join(cmd) for cmd in self.calls))

class CheckerCastPin(unittest.TestCase):
    def test_version_gate_precedes_rpc(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); cast = root/'cast'; calls = root/'calls'
            for version in ('1.7.1-nightly', '1.7.10-stable', '1.7.1-stable'):
                calls.unlink(missing_ok=True)
                cast.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "'+str(calls)+'"\n'
                                'if [ "$1" = --version ]; then echo "cast Version: '+version+'"; exit 0; fi\nexit 99\n')
                cast.chmod(0o755)
                result = subprocess.run([sys.executable, str(CHECKER), 'unused', '0x'+'11'*20, '0x'+'22'*20],
                    env={'PATH': tmp, 'ETH_RPC_URL': 'unused'}, capture_output=True, text=True)
                self.assertEqual(calls.read_text().splitlines() if calls.exists() else [], ['--version'])
                self.assertNotEqual(result.returncode, 0)
                if version == '1.7.1-stable':
                    self.assertIn('FAIL explicit evidence directory required', result.stdout)
                else:
                    self.assertEqual(result.stdout, 'FAIL STOP checker requires cast 1.7.1\n')
