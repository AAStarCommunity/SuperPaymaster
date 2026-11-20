import contextlib
import io
import os
import sys
import unittest
from unittest.mock import patch
import deploylive_fork_deploy as driver


class BroadcastProgressTest(unittest.TestCase):
    def test_running_forge_captures_output_and_reports_confirmed_nonce(self):
        calls = []
        def rpc(method, sender, block):
            calls.append((method, sender, block))
            return hex(39 + min(len(calls), 2))
        output = io.StringIO()
        plan = {'transactions': [{'transaction': {'nonce': '0x27'}}, {}]}
        command = [sys.executable, '-c',
                   "import time,sys; print('private stdout'); sys.stderr.write('private stderr'); time.sleep(2)"]
        with patch.object(driver, 'BROADCAST_PROGRESS_SECONDS', 0.2, create=True), contextlib.redirect_stdout(output):
            result = driver.run_broadcast(command, os.environ.copy(), rpc, 'sender', plan)
        self.assertEqual(result.returncode, 0)
        self.assertIn('private stdout', result.stdout)
        self.assertIn('private stderr', result.stderr)
        self.assertIn('BROADCAST progress: deployer nonce 40 (advanced by 1; plan has 2 transactions)', output.getvalue())
        self.assertIn('BROADCAST progress: deployer nonce 41 (advanced by 2; plan has 2 transactions)', output.getvalue())
        self.assertNotIn('private', output.getvalue())
        self.assertTrue(all(call == ('eth_getTransactionCount', 'sender', 'latest') for call in calls))
        self.assertLessEqual(len(calls), 10)

    def test_fast_broadcast_never_polls(self):
        from unittest.mock import Mock
        rpc = Mock()
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = driver.run_broadcast([sys.executable, '-c', 'pass'], os.environ.copy(),
                                          rpc, 'sender', {'transactions': [{'transaction': {'nonce': '0x0'}}]})
        self.assertEqual(driver.BROADCAST_PROGRESS_SECONDS, 30)
        self.assertEqual(result.returncode, 0)
        rpc.assert_not_called()
        self.assertEqual(output.getvalue(), '')

    def test_unknown_stderr_cause_is_fixed_exit_label(self):
        import subprocess
        result = subprocess.CompletedProcess([], 7, '', 'https://secret.invalid/key')
        self.assertEqual(driver.broadcast_failure_cause(result), 'forge exit 7')

    def test_rpc_failure_does_not_fail_broadcast_or_leak(self):
        output = io.StringIO()
        with patch.object(driver, 'BROADCAST_PROGRESS_SECONDS', 0.05, create=True), contextlib.redirect_stdout(output):
            result = driver.run_broadcast(
                [sys.executable, '-c', 'import time; time.sleep(.2)'], os.environ.copy(),
                lambda *args: (_ for _ in ()).throw(RuntimeError('https://secret.invalid/key')),
                'sender', {'transactions': [{'transaction': {'nonce': '0x0'}}]})
        self.assertEqual(result.returncode, 0)
        self.assertNotIn('secret', output.getvalue())
