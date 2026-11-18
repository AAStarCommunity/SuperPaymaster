"""Offline review regressions; no RPC, keystore or installed cast required."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import execution_integrity as integrity
import a3a_send as sender
from test_execution_head import ExecutionHeadTests


class GitReviewTests(ExecutionHeadTests):
    def test_replace_ref_refused(self):
        original = self.plan['rebuild']['commit']
        (self.root / 'tracked').write_text('replacement\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Offline', '-c', 'user.email=offline@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'replacement')
        replacement = self.git('rev-parse', 'HEAD').strip()
        self.git('replace', original, replacement)
        self.git('reset', '--soft', original)
        with patch.object(sender.ex, 'ROOT', self.root, create=True), patch.object(__import__('sp_upgrade_exec'), 'ROOT', self.root):
            with self.assertRaisesRegex(Exception, 'execution_replace_refs'):
                integrity.tree_gates(original)

    def test_grafts_refused(self):
        (self.root / '.git/info/grafts').write_text('')
        with patch.object(__import__('sp_upgrade_exec'), 'ROOT', self.root):
            with self.assertRaisesRegex(Exception, 'execution_grafts'):
                integrity.tree_gates(self.plan['rebuild']['commit'])

    def test_git_evidence(self):
        with patch.object(__import__('sp_upgrade_exec'), 'ROOT', self.root):
            self.assertTrue(hasattr(integrity, 'git_evidence'), 'missing git binary evidence')
            evidence = integrity.git_evidence(self.root)
        self.assertTrue(Path(evidence['path']).is_absolute())
        self.assertTrue(evidence['version'].startswith('git version '))


class ExecutionSetTests(unittest.TestCase):
    def test_manifest_and_transitive_import(self):
        path = Path(__file__).with_name('execution_set.py')
        self.assertTrue(path.exists(), 'missing execution-set generator')
        spec = importlib.util.spec_from_file_location('execution_set', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for relative in ('script/a3a/a3a_send.py', 'script/upgrade/execution_integrity.py',
                             'script/upgrade/execution_set.py', 'script/a3a/extra.py', 'script/a3a/leaf.py'):
                file = root / relative
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('')
            before = module.manifest(root)
            (root / 'script/a3a/a3a_send.py').write_text('import extra\n')
            (root / 'script/a3a/extra.py').write_text('from leaf import VALUE\n')
            after = module.manifest(root)
            self.assertNotIn('script/a3a/leaf.py', before)
            self.assertIn('script/a3a/extra.py', after)
            self.assertIn('script/a3a/leaf.py', after)
            plan = {}
            digest = module.freeze_manifest(plan, root, root)
            self.assertEqual(plan['execution']['manifestSha256'], digest)
            self.assertEqual(hashlib.sha256((root / 'execution-set.sha256').read_bytes()).hexdigest(), digest)
            plan['execution']['manifestSha256'] = '0' * 64
            with self.assertRaisesRegex(RuntimeError, 'execution_set_sha256'):
                module.freeze_manifest(plan, root, root)
            result = subprocess.run(['shasum', '-a', '256', '-c', '-'], input=after,
                                    cwd=root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_freeze_cli_packet(self):
        script = Path(__file__).with_name('execution_set.py')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'cast'
            binary.write_text('#!/bin/sh\necho frozen-cast\n')
            binary.chmod(0o700)
            source, packet, manifest = root / 'source.json', root / 'packet.json', root / 'execution.sha256'
            source.write_text('{"fixture": true}')
            result = subprocess.run([sys.executable, '-B', str(script), '--plan', str(source),
                                     '--packet', str(packet), '--manifest', str(manifest), '--cast', str(binary)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            frozen = json.loads(packet.read_bytes())
            self.assertTrue(frozen['fixture'])
            self.assertEqual(frozen['execution'], {
                'manifestSha256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
                'cast': {'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'version': 'frozen-cast'}})

    def test_packet_digest_refused(self):
        self.assertTrue(hasattr(integrity, 'packet_check'), 'missing frozen execution-set check')
        with self.assertRaisesRegex(Exception, 'execution_set_sha256'):
            integrity.packet_check({'execution': {'manifestSha256': '0' * 64}})


class SignerTests(unittest.TestCase):
    def test_cast_hash_refused_before_password_or_account(self):
        self.assertTrue(hasattr(sender, 'verify_cast'), 'missing pinned cast verification')
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'cast'
            binary.write_text('#!/bin/sh\necho cast-test\n')
            binary.chmod(0o700)
            with patch.object(sender, 'CAST', str(binary)), \
                 patch('builtins.open', side_effect=AssertionError('password opened')), \
                 patch.object(sender, 'password_file_check', side_effect=AssertionError('password touched')), \
                 patch.object(sender.subprocess, 'run', side_effect=AssertionError('unverified cast executed')):
                with self.assertRaisesRegex(Exception, 'send_cast_sha256'):
                    sender.verify_cast({'execution': {'cast': {'sha256': '0'*64, 'version': 'cast-test'}}})

    def test_cast_missing_refused(self):
        self.assertTrue(hasattr(sender, 'verify_cast'), 'missing pinned cast verification')
        with tempfile.TemporaryDirectory() as directory, patch.object(sender, 'CAST', str(Path(directory)/'missing')):
            with self.assertRaisesRegex(Exception, 'send_cast_available'):
                sender.verify_cast({'execution': {'cast': {}}})

    def test_cast_version_failure_refused(self):
        self.assertTrue(hasattr(sender, 'verify_cast'), 'missing pinned cast verification')
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'cast'
            binary.write_text('#!/bin/sh\necho cast-test\nexit 1\n')
            binary.chmod(0o700)
            pin = {'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'version': 'cast-test'}
            with patch.object(sender, 'CAST', str(binary)):
                with self.assertRaisesRegex(Exception, 'send_cast_version_exit'):
                    sender.verify_cast({'execution': {'cast': pin}})

    def test_cast_version_and_evidence(self):
        self.assertTrue(hasattr(sender, 'verify_cast'), 'missing pinned cast verification')
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'cast'
            binary.write_text('#!/bin/sh\necho cast-test\n')
            binary.chmod(0o700)
            pin = {'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'version': 'wrong'}
            with patch.object(sender, 'CAST', str(binary)):
                with self.assertRaisesRegex(Exception, 'send_cast_version'):
                    sender.verify_cast({'execution': {'cast': pin}})
                pin['version'] = 'cast-test'
                self.assertEqual(sender.verify_cast({'execution': {'cast': pin}}), dict(pin, path=str(binary.resolve())))


if __name__ == '__main__':
    unittest.main()
