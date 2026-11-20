"""Checker preconditions must fail before the first Forge invocation (offline)."""
from contextlib import ExitStack
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import deploylive_controls as controls
import deploylive_fork_deploy as driver


class CheckerPreflight(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name).resolve()
        self.cast = self.root/'cast'
        self.cast.write_text('#!/bin/sh\necho "cast Version: 1.7.1-stable"\n')
        self.cast.chmod(0o755)
        second = self.root/'second'
        second.write_text('https://secondary.infura.io/key')
        self.evidence = self.root/'evidence'
        self.evidence.mkdir()
        checker = self.root/'script/rehearsal/deploylive_postdeploy_check.py'
        checker.parent.mkdir(parents=True)
        checker.write_text('# checker fixture\n')
        self.env = {key: 'value' for key in controls.input_keys() if not key.endswith('_FILE')}
        self.env.update(CAST_1_7_1=str(self.cast), DEPLOYLIVE_RPC='https://primary.alchemy.com/key',
            DEPLOYLIVE_SECOND_RPC=second.read_text(), DEPLOYLIVE_SECOND_RPC_FILE=str(second),
            DEPLOYLIVE_SOURCE_RPC='https://primary.alchemy.com/key', DEPLOYLIVE_PRICE_SOURCE='chain',
            DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy', DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura',
            DEPLOYLIVE_EXPECTED_CHAIN_ID='11155111', ENV='test', FOUNDRY_VERBOSITY='2',
            GOVERNANCE_OWNER='0x'+'22'*20, DEPLOYER_ADDRESS='0x'+'11'*20,
            DEPLOYLIVE_EVIDENCE_DIR=str(self.evidence))

    def check_stop(self, message, predict=False):
        real_run = subprocess.run
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            if argv == [str(self.cast), '--version']:
                return real_run(argv, **kwargs)
            raise AssertionError('unexpected subprocess')
        with ExitStack() as stack:
            for obj, key, value in ((driver, 'ROOT', self.root),
                    (driver, 'clean_source_commit', lambda: 'a'*40),
                    (driver, 'ReadOnlyRPC', lambda url: lambda *args: hex(11155111)),
                    (driver, 'config_path', lambda env: self.root/'config.json'),
                    (controls, 'verify_manifest', lambda *args: None),
                    (controls, 'verify_conversion', lambda *args: '[]'),
                    (driver, 'build_paths', lambda *args: None)):
                stack.enter_context(patch.object(obj, key, value))
            build = stack.enter_context(patch.object(driver, 'verify_build', side_effect=AssertionError('reached build verification')))
            stack.enter_context(patch.object(driver.subprocess, 'run', side_effect=run))
            stack.enter_context(patch.dict(os.environ, self.env, clear=True))
            stack.enter_context(patch.object(sys, 'argv', ['driver', '--production', self.env['DEPLOYER_ADDRESS']]))
            with self.assertRaisesRegex(RuntimeError, message):
                if predict:
                    driver.stage('predict', ['--production', '--evidence', str(self.evidence)])
                else:
                    driver.main()
            build.assert_not_called()
        self.assertTrue(all(cmd == [str(self.cast), '--version'] for cmd in calls))

    def test_bad_cast_before_forge(self):
        for predict in (False, True):
            for kind in ('missing', 'absent', 'not executable', 'nightly', 'failed'):
                with self.subTest(predict=predict, kind=kind):
                    self.env['CAST_1_7_1'] = str(self.cast)
                    self.cast.write_text('#!/bin/sh\necho "cast Version: 1.7.1-nightly"\n' + ('exit 1\n' if kind == 'failed' else ''))
                    self.cast.chmod(0o644 if kind == 'not executable' else 0o755)
                    if kind == 'missing': self.env.pop('CAST_1_7_1')
                    if kind == 'absent': self.env['CAST_1_7_1'] = str(self.root/'absent')
                    self.check_stop('STOP CAST_1_7_1', predict)

    def test_checker_arguments_before_forge(self):
        for key in ('GOVERNANCE_OWNER', 'DEPLOYER_ADDRESS'):
            original = self.env[key]
            for value in ('', 'invalid'):
                with self.subTest(key=key, value=value):
                    self.env[key] = value
                    self.check_stop('STOP invalid checker ' + key)
            self.env[key] = original

    def test_checker_script_before_forge(self):
        (self.root/'script/rehearsal/deploylive_postdeploy_check.py').unlink()
        self.check_stop('STOP checker script unavailable')

    def test_checker_directory_before_forge(self):
        (self.root/'cache').write_text('blocked')
        self.check_stop('STOP checker evidence unavailable')

    def test_checker_symlink_before_forge(self):
        (self.root/'cache').symlink_to(self.evidence, target_is_directory=True)
        self.check_stop('STOP checker evidence unavailable')

    def test_evidence_destinations_before_forge(self):
        for name in ('readback.json', 'checker.log', 'checker.stdout.log', 'checker.stderr.log',
                     'checker.PASS.json', 'forge.stdout.log', 'forge.stderr.log',
                     'postbroadcast.diff.json', 'postbroadcast.gas.json', 'REDACTED_AFTER_BROADCAST'):
            with self.subTest(name=name):
                target = self.evidence/name
                target.mkdir()
                self.check_stop('STOP deployment evidence unavailable')
                target.rmdir()

    def test_checker_readback_destination_before_forge(self):
        target = self.root/'cache/deploylive-checker/test/readback.json'
        target.mkdir(parents=True)
        self.check_stop('STOP checker evidence unavailable')

    def test_evidence_write_probe_before_forge(self):
        with patch('tempfile.TemporaryFile', side_effect=PermissionError('sensitive path')):
            self.check_stop('STOP deployment evidence unavailable')

    def test_provider_before_forge(self):
        self.env['DEPLOYLIVE_ENDPOINT_PROVIDER'] = ''
        self.check_stop('STOP invalid checker provider pair')

    def test_checker_directory_write_probe_before_forge(self):
        original = tempfile.TemporaryFile
        def probe(*args, **kwargs):
            if kwargs.get('dir') != self.evidence:
                raise PermissionError('sensitive path')
            return original(*args, **kwargs)
        with patch('tempfile.TemporaryFile', side_effect=probe):
            self.check_stop('STOP checker evidence unavailable')

    def test_shared_version_matching(self):
        from deploylive_cast import stable_cast
        for version, accepted in (('1.7.1', True), ('1.7.1-stable', True),
                ('1.7.1-stable (build)', True), ('1.7.1-nightly', False),
                ('1.7.10-stable', False)):
            with self.subTest(version=version):
                self.cast.write_text('#!/bin/sh\necho "cast Version: '+version+'"\n')
                self.assertEqual(stable_cast(str(self.cast)), accepted)
        for error in (OSError('sensitive path'), subprocess.TimeoutExpired('sensitive path', 10)):
            with patch('deploylive_cast.subprocess.run', side_effect=error):
                self.assertFalse(stable_cast(str(self.cast)))
