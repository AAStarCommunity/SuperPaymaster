#!/usr/bin/env python3
"""Execution checkout gates against real, temporary offline git repositories."""
import subprocess
from contextlib import contextmanager
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import manifest_exec as m
import execution_integrity as integrity
from gate_assertions import assert_stop


class ExecutionHeadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git('init', '-q')
        (self.root / 'tracked').write_text('committed\n')
        self.git('add', 'tracked')
        self.git('-c', 'user.name=Offline Test', '-c', 'user.email=offline@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
        self.plan = dict(externalInputs={}, rebuild=dict(commit=self.git('rev-parse', 'HEAD').strip()),
                         pin=dict(senders={}), steps=[], stage='a7')
        self.closed = False
        # These fixtures isolate checkout gates; BootstrapTests exercise the real loader.
        gates = patch.object(m, 'execution_tree_gates',
                             side_effect=lambda plan: integrity.tree_gates(plan['rebuild']['commit']))
        gates.start()
        self.addCleanup(gates.stop)

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.root, check=True,
                              capture_output=True, text=True).stdout

    def execute(self, calibrate=True):
        def closing(rpc, plan):
            self.closed = True
            return {}
        # Valid staged runner responses permit full acceptance when a gate is deleted.
        with patch.object(m.u, 'ROOT', self.root), \
             patch.object(m, 'validate_plan', return_value=self.plan), \
             patch.object(m, 'dvt_closing', side_effect=closing), \
             patch.object(m, 'stage_readback', return_value={}), patch.object(m, 'budget'), \
             tempfile.TemporaryDirectory() as output:
            result = m.run_manifest(None, SimpleNamespace(local=True), self.plan, Path(output), calibrate)
        self.assertEqual(result['status'], 'PASS')
        self.assertTrue(self.closed)
        return result

    def test_matching_clean_head(self):
        for calibrate in (True, False):
            with self.subTest(calibrate=calibrate):
                self.execute(calibrate)

    def test_tree_gates_inside_guard_stop(self):
        with patch.object(m.u, 'ROOT', self.root):
            with m.execution_reads.guard(frozenset()):
                with assert_stop(self, 'execution_repo_read'):
                    m.execution_tree_gates(self.plan)

    def test_tree_gates_before_guard_entry(self):
        calls = []
        tree_gates = m.execution_tree_gates
        guard = m.execution_reads.guard

        def recorded_tree_gates(plan):
            calls.append('execution_tree_gates')
            tree_gates(plan)
            calls.append('execution_tree_gates_complete')

        @contextmanager
        def recorded_guard(allowlist):
            with guard(allowlist):
                calls.append('guard_entry')
                yield

        with patch.object(m, 'execution_tree_gates', side_effect=recorded_tree_gates), \
             patch.object(m.execution_reads, 'guard', side_effect=recorded_guard):
            self.execute()
        self.assertEqual(calls, ['execution_tree_gates', 'execution_tree_gates_complete',
                                 'guard_entry'])

    def test_wrong_head(self):
        self.plan['rebuild']['commit'] = 'f'*40
        with assert_stop(self, 'execution_head'):
            self.execute()
        self.assertFalse(self.closed)

    def test_dirty_file(self):
        (self.root / 'tracked').write_text('changed\n')
        with assert_stop(self, 'execution_clean_tree'):
            self.execute()
        self.assertFalse(self.closed)

    def test_untracked_file(self):
        (self.root / 'untracked').write_text('new\n')
        with assert_stop(self, 'execution_clean_tree'):
            self.execute(False)
        self.assertFalse(self.closed)


if __name__ == '__main__':
    unittest.main()
