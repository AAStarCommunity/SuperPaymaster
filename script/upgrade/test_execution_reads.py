#!/usr/bin/env python3
"""Offline execution barrier tests; prohibited reads have real successful targets."""
import builtins
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import execution_reads as e
import manifest_exec as m
from gate_assertions import assert_stop


class ExecutionReadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'repo'
        self.root.mkdir()
        self.file = self.root / 'source.json'
        self.file.write_text('{"value": 7}')
        self.alias = Path(self.tmp.name) / 'alias'
        self.alias.symlink_to(self.root, target_is_directory=True)
        outside = Path(self.tmp.name) / 'outside.json'
        outside.write_text('{}')
        self.outward = self.root / 'outward.json'
        self.outward.symlink_to(outside)
        p = patch.object(e.u, 'ROOT', self.root)
        p.start()
        self.addCleanup(p.stop)

    def test_deleted_gate(self):
        readers = [lambda: builtins.open(self.file).close(),
                   lambda: self.file.read_text(), lambda: self.file.read_bytes(),
                   lambda: json.load(self.file.open()),
                   lambda: (self.alias / self.file.name).read_text(),
                   lambda: io.open(self.file).close(),
                   lambda: self.outward.read_bytes(),
                   lambda: builtins.open(self.file, 'r+').close()]
        # The subprocess fake supplies the real target's successful completion;
        # deleting the gate cannot turn into a fake dispatch error.
        with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess(['git'], 0, 'abc\n')):
            readers += [lambda: subprocess.run(['git', 'show', 'HEAD:source.json']),
                        lambda: subprocess.run(['/usr/bin/git', '-C', str(self.root), 'rev-parse', 'HEAD']),
                        lambda: subprocess.run(args='git rev-parse HEAD', shell=True)]
            with e.guard(frozenset()):
                for read in readers:
                    with self.subTest(read=read), assert_stop(self, 'execution_repo_read'):
                        read()

    def test_allowlist_and_output(self):
        outside = Path(self.tmp.name) / 'outside'
        outside.write_text('outside')
        with e.guard(frozenset({self.file.resolve()})):
            self.assertEqual(json.loads(self.file.read_text()), {'value': 7})
            self.assertEqual(outside.read_bytes(), b'outside')
            (self.root / 'output').write_text('log')
            with (self.root / 'output').open('a') as stream:
                stream.write('append')

    def test_subprocess_output_pipes_are_not_repo_files(self):
        with e.guard(frozenset()):
            result = subprocess.run([sys.executable, '-c', 'print(7)'],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout, '7\n')

    def test_regular_read_descriptor_is_refused(self):
        with self.file.open('rb') as stream:
            with e.guard(frozenset()):
                with assert_stop(self, 'execution_repo_read'):
                    io.open(stream.fileno(), 'rb', closefd=False).close()

    def test_restoration_on_exception(self):
        originals = builtins.open, io.open, Path.read_text, Path.read_bytes, subprocess.run
        failure = RuntimeError('identity')
        with self.assertRaises(RuntimeError) as caught:
            with e.guard(frozenset()):
                raise failure
        self.assertIs(caught.exception, failure)
        self.assertEqual(originals, (builtins.open, io.open, Path.read_text, Path.read_bytes, subprocess.run))

    def test_run_manifest_installs_guard_after_validation(self):
        from execution_git_fixture import clean_checkout
        clean_checkout(self, 'a'*40)
        calls = []
        plan = {'externalInputs': {}, 'rebuild': {'commit': 'a'*40}}
        def validate(*args, **kwargs):
            calls.append('validate')
            self.file.read_text()
            return {'validated': True}
        def execute(remote, rpc, plan, out, calibrate, expected):
            self.assertEqual(calls, ['validate'])
            self.assertEqual(expected, {'validated': True})
            self.file.read_text()
        with patch.object(m, 'validate_plan', side_effect=validate), \
             patch.object(e, 'reviewed_allowlist', return_value=frozenset()), \
             patch.object(m, '_run_manifest', side_effect=execute):
            with assert_stop(self, 'execution_repo_read'):
                m.run_manifest(None, SimpleNamespace(local=True), plan, self.root)
        self.assertEqual(self.file.read_text(), '{"value": 7}')

    def test_guard_remains_active_through_real_runner_closing(self):
        from execution_git_fixture import clean_checkout
        clean_checkout(self, 'a'*40)
        plan = {'externalInputs': {}, 'rebuild': {'commit': 'a'*40},
                'pin': {'senders': {}}, 'steps': [], 'stage': 'a7'}
        def closing(rpc, plan):
            return json.loads(self.file.read_text())
        with patch.object(m, 'validate_plan', return_value=plan), \
             patch.object(e, 'reviewed_allowlist', return_value=frozenset()), \
             patch.object(m, 'dvt_closing', side_effect=closing), \
             patch.object(m, 'stage_readback', return_value={}), patch.object(m, 'budget'):
            with assert_stop(self, 'execution_repo_read'):
                m.run_manifest(None, SimpleNamespace(local=True), plan, self.root)

    def test_late_validation_uses_detached_expected(self):
        # Real validate_plan checks exact fields and transaction values, without build.
        expected = {'externalInputs': {}, 'steps': []}
        with patch.object(m, 'build_plan', side_effect=AssertionError('execution build')):
            with e.guard(frozenset()):
                m.validate_plan(dict(expected), {}, expected=expected)
                with assert_stop(self, 'manifest_externalInputs'):
                    m.validate_plan({'externalInputs': {'changed': True}, 'steps': []},
                                    {'changed': True}, expected=expected)

    def test_governance_uses_supplied_identity_without_build(self):
        u, a = e.u, e.u.a
        identities = {a.ZERO32 if label == 'DEFAULT_ADMIN' else a.keccak(label+'_ROLE'): members
                      for label, members in u.ROLES.items()}
        def word(rpc, target, sig, *args, **kwargs):
            return u.DELAY if sig == 'getMinDelay()' else int(args[1] in identities[args[0]])
        with patch.object(u, 'build', side_effect=AssertionError('execution build')), \
             patch.object(u, 'code', return_value='0x6000'), \
             patch.object(a, 'word', side_effect=word), patch.object(a, 'roles_readback'):
            with e.guard(frozenset()):
                u.governance(None, 'latest', 1, {'artifactRuntime': '0x6000', 'ranges': []})
                with assert_stop(self, 'runtime_unmasked_bytes'):
                    u.governance(None, 'latest', 1, {'artifactRuntime': '0x6001', 'ranges': []})

    def test_reviewed_allowlist_empty(self):
        self.assertEqual(e.reviewed_allowlist(), frozenset())


if __name__ == '__main__':
    unittest.main()
