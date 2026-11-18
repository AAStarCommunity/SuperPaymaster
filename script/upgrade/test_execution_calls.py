"""Sender/manifest boundary regressions with real integrity checks in committed copies.

Only transaction construction and external effects are stubbed; integrity_check,
bootstrap, module.check and all checkout gates execute normally. No sockets/keys.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CallTests(unittest.TestCase):
    def scenario(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = base / 'repo'
            shutil.copytree(ROOT / 'script', root / 'script', ignore=shutil.ignore_patterns('__pycache__'))
            (root / 'tracked').write_text('original')
            env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', PYTHONPATH=os.pathsep.join(
                str(root / p) for p in ('script/upgrade', 'script/a3a')))
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, env=env, check=True,
                                      capture_output=True, text=True).stdout.strip()
            git('init', '-q')
            git('add', '.')
            git('-c', 'user.name=Offline', '-c', 'user.email=offline@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
            commit = git('rev-parse', 'HEAD')
            if mode == 'head':
                git('-c', 'user.name=Offline', '-c', 'user.email=offline@example.invalid',
                    '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'wrong branch')
            code = '''
import hashlib, json, unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import a3a_send as sender
import manifest_exec as manifest
import execution_set
from test_execution_r2 import password_opens
ROOT = Path.cwd()
BASE = ROOT.parent
MODE = MODE_VALUE
COMMIT = COMMIT_VALUE
class Boundary(unittest.TestCase):
    def runTest(self):
        binary = BASE / 'cast'
        binary.write_text('#!/bin/sh\\necho fixture-cast\\n')
        binary.chmod(0o700)
        pin = execution_set.cast_identity(binary)
        plan = dict(rebuild=dict(commit=COMMIT), externalInputs={},
                    execution=dict(manifestSha256=hashlib.sha256(execution_set.manifest().encode()).hexdigest(),
                                   cast=pin), pin=dict(senders={'owner': {'address': '0x123'}}))
        file = BASE / 'plan.json'
        file.write_text(json.dumps(plan))
        accounts = BASE / 'accounts.json'
        accounts.write_text('{"owner": "offline"}')
        out = BASE / 'out'
        out.mkdir()
        args = SimpleNamespace(plan=file, out=out, step='S1', accounts=accounts,
                               reviewed_plan_sha256=hashlib.sha256(file.read_bytes()).hexdigest(),
                               password_file=BASE / 'NEVER_OPEN', confirm=None)
        if MODE == 'cast_hash':
            plan['execution']['cast']['sha256'] = '0' * 64
        if MODE == 'cast_version':
            plan['execution']['cast']['version'] = 'wrong'
        if MODE == 'packet':
            plan['execution']['manifestSha256'] = '0' * 64
        file.write_text(json.dumps(plan))
        args.reviewed_plan_sha256 = hashlib.sha256(file.read_bytes()).hexdigest()
        calls = []
        real_run = sender.subprocess.run
        def process(argv, *a, **kw):
            if 'mktx' in argv:
                calls.append('mktx')
                raise RuntimeError('signing reached')
            return real_run(argv, *a, **kw)
        def confirm(prompt):
            if MODE == 'late':
                (ROOT / 'tracked').write_text('dirty after confirmation')
            return 'SEND S1 ' + args.reviewed_plan_sha256[:12]
        if MODE in ('early', 'manifest'):
            (ROOT / 'tracked').write_text('dirty before entry')
        caught = None
        with password_opens(args.password_file) as password_attempts, \\
             patch.object(sender, 'CAST', str(binary)), \\
             patch.object(sender.ex, 'signing_transaction', return_value={'from': '0x123', 'nonce': '0x0', 'gas': '0x5208', 'maxFeePerGas': '0x2', 'maxPriorityFeePerGas': '0x1', 'value': '0x0', 'to': '0x456', 'data': '0x'}) as tx, \\
             patch.object(sender, 'fee_fits'), \\
             patch.object(sender, 'password_file_check', side_effect=lambda p: calls.append('password')), \\
             patch.object(sender.subprocess, 'run', side_effect=process), \\
             patch.object(manifest, 'validate_plan', return_value={}), \\
             patch.object(manifest, '_run_manifest', side_effect=lambda *a: calls.append('runner')):
            try:
                if MODE == 'manifest':
                    manifest.run_manifest(None, SimpleNamespace(local=True), plan, out)
                else:
                    sender.run(args, None, 'offline', confirm=confirm)
            except Exception as error:
                caught = error
        self.assertEqual(password_attempts, [], 'password path must have zero actual opens')
        self.assertNotIn('mktx', calls, 'signing wrapper must never be called')
        self.assertNotIn('password', calls, 'password must never be touched')
        self.assertNotIn('runner', calls)
        expected = {'head': 'execution_head', 'cast_hash': 'send_cast_sha256',
                    'cast_version': 'send_cast_version', 'packet': 'execution_set_sha256'}.get(MODE, 'execution_clean_tree')
        self.assertIsNotNone(caught, expected + ' must stop execution')
        self.assertIn(expected, str(caught))
        if MODE in ('early', 'head', 'cast_hash', 'cast_version', 'packet'):
            self.assertEqual(tx.call_count, 0, 'first integrity call must precede transaction preparation')
unittest.main()
'''.replace('MODE_VALUE', repr(mode)).replace('COMMIT_VALUE', repr(commit))
            result = subprocess.run([sys.executable, '-B', '-c', code], cwd=root, env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_first_call(self):
        self.scenario('early')

    def test_second_call(self):
        self.scenario('late')

    def test_head(self):
        self.scenario('head')

    def test_manifest_call(self):
        self.scenario('manifest')

    def test_cast_hash_before_signing(self):
        self.scenario('cast_hash')

    def test_cast_version_before_signing(self):
        self.scenario('cast_version')

    def test_packet_before_signing(self):
        self.scenario('packet')

    def test_cli_checks_before_dependency_side_effect(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            shutil.copytree(ROOT / 'script', root / 'script', ignore=shutil.ignore_patterns('__pycache__'))
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, capture_output=True, text=True,
                                      check=True).stdout.strip()
            git('init', '-q')
            git('add', '.')
            git('-c', 'user.name=Offline', '-c', 'user.email=offline@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
            import json
            plan = root.parent / 'plan.json'
            plan.write_text(json.dumps({'rebuild': {'commit': git('rev-parse', 'HEAD')}}))
            marker = root.parent / 'executed'
            dependency = root / 'script/a3a/a3a_exec.py'
            dependency.write_text(dependency.read_text() +
                                  f"\nPath({str(marker)!r}).write_text('unexpected import')\n")
            result = subprocess.run([sys.executable, '-B', str(root / 'script/a3a/a3a_send.py'),
                                     '--plan', str(plan)], capture_output=True, text=True)
            self.assertFalse(marker.exists(), 'dependency executed before integrity check')
            self.assertNotEqual(result.returncode, 0)

    def test_bootstrap_checks_dependency_before_import(self, dependency_name='sp_upgrade_exec'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            shutil.copytree(ROOT / 'script', root / 'script', ignore=shutil.ignore_patterns('__pycache__'))
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, capture_output=True, text=True,
                                      check=True).stdout.strip()
            git('init', '-q')
            git('add', '.')
            git('-c', 'user.name=Offline', '-c', 'user.email=offline@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
            commit = git('rev-parse', 'HEAD')
            marker = root.parent / 'executed'
            dependency = root / ('script/upgrade/' + dependency_name + '.py')
            dependency.write_text(dependency.read_text() +
                                  f"\nPath({str(marker)!r}).write_text('unexpected import')\n")
            env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', PYTHONPATH=os.pathsep.join(
                str(root / p) for p in ('script/upgrade', 'script/a3a')))
            result = subprocess.run([sys.executable, '-B', '-c',
                                     f'import a3a_send; a3a_send.integrity_check({commit!r})'],
                                    cwd=root, env=env, capture_output=True, text=True)
            self.assertFalse(marker.exists(), 'bootstrap dependency executed before verification')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('execution_bootstrap_source', result.stderr)

    def test_bootstrap_checks_generator_before_import(self):
        self.test_bootstrap_checks_dependency_before_import('execution_set')


if __name__ == '__main__':
    unittest.main()
