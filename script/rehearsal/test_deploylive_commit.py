import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
import sys
import deploylive_runtime as runtime
import deploylive_fork_deploy as fork
import deploylive_rehearse as rehearsal


class CommitTest(unittest.TestCase):
    def test_clean_commit(self):
        runner = Mock(side_effect=[SimpleNamespace(returncode=0, stdout="a" * 40 + "\n"), SimpleNamespace(returncode=0, stdout="")])
        self.assertEqual(runtime.clean_source_commit(git_runner=runner), "a" * 40)
        self.assertEqual(runner.call_args.args[0], ["git", "-C", str(runtime.ROOT), "status", "--porcelain"])

    def test_dirty_and_git_failure_refused(self):
        for status, rc in ((" M file\n", 0), ("?? new\n", 0), ("", 1)):
            runner = Mock(side_effect=[SimpleNamespace(returncode=0, stdout="a" * 40), SimpleNamespace(returncode=rc, stdout=status)])
            with self.subTest(status=status, rc=rc), self.assertRaises(RuntimeError):
                runtime.clean_source_commit(git_runner=runner)

    def test_drivers_refuse_dirty_before_rpc(self):
        for module, args in ((fork, ["fork", "http://127.0.0.1:1", "deployer"]),
                             (rehearsal, ["rehearse", "happy", "http://127.0.0.1:1", str(runtime.ROOT / "cache/dlpop/config.json"), "deployer", "safe"])):
            with self.subTest(module=module.__name__), patch.object(sys, "argv", args), patch.object(module, "clean_source_commit", create=True, side_effect=RuntimeError("dirty worktree")), patch.object(module, "RPC") as rpc, patch.object(module, "guard_bls_verbosity"):
                with self.assertRaisesRegex(RuntimeError, "dirty worktree"):
                    module.main()
                rpc.assert_not_called()
