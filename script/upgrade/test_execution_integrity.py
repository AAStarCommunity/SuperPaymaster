"""Offline real temporary Git trees; named integrity and read-barrier failures."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import execution_integrity as e
import execution_reads as reads
from gate_assertions import assert_stop


class IntegrityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='commit6f-tree-')
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.root = self.base / 'repo'
        self.root.mkdir()
        self.git('init', '-q')
        self.source = self.root / 'executor.py'
        self.source.write_text('VALUE = 1\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Offline', '-c', 'user.email=offline@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
        self.commit = self.git('rev-parse', 'HEAD').strip()
        root = patch.object(e.u, 'ROOT', self.root)
        root.start()
        self.addCleanup(root.stop)
        modules = patch.dict(sys.modules, {'commit6f_fixture': self.load_module(self.source)})
        modules.start()
        self.addCleanup(modules.stop)

    def load_module(self, path):
        spec = importlib.util.spec_from_file_location('commit6f_fixture', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.root, check=True,
                              capture_output=True, text=True).stdout

    def track_first_party(self, name):
        path = self.root / 'script' / 'a3a' / (name + '.py')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('VALUE = 1\n')
        self.git('add', '.')
        self.git('-c', 'user.name=Offline', '-c', 'user.email=offline@example.invalid',
                 '-c', 'commit.gpgsign=false', 'commit', '-qm', 'first-party fixture')
        self.commit = self.git('rev-parse', 'HEAD').strip()
        return path

    def test_execution_module_origin(self):
        path = self.track_first_party('a3a_exec')
        external = self.base / 'a3a_exec.py'
        external.write_text('VALUE = 1\n')
        with patch.dict(sys.modules, {'a3a_exec': SimpleNamespace(__file__=str(path))}):
            e.check(self.commit)
        for origin in (str(external), None):
            with self.subTest(origin=origin), patch.dict(
                    sys.modules, {'a3a_exec': SimpleNamespace(__file__=origin)}):
                with assert_stop(self, 'execution_module_origin'):
                    e.check(self.commit)

    def test_preloaded_execution_integrity_cannot_replace_sender_check(self):
        import a3a_send as sender
        from unittest.mock import Mock
        self.track_first_party('execution_integrity')
        external = self.base / 'execution_integrity.py'
        external.write_text('def check(commit): pass\n')
        permissive = Mock()
        shadow = SimpleNamespace(__file__=str(external), check=permissive)
        import hashlib
        import json
        raw = json.dumps({'rebuild': {'commit': self.commit}}).encode()
        plan = self.base / 'plan.json'
        plan.write_bytes(raw)
        out = self.base / 'sender'
        out.mkdir()
        args = SimpleNamespace(plan=plan, out=out,
                               reviewed_plan_sha256=hashlib.sha256(raw).hexdigest())
        with patch.dict(sys.modules, {'execution_integrity': shadow,
                                     '_a3a_repository_execution_integrity': shadow}), \
             patch.object(sender.ex, 'plan_json', side_effect=json.loads), \
             patch.object(sender.ex, 'signing_transaction') as signing, \
             patch.object(sender, 'signed') as signed, \
             patch.object(sender, 'broadcast') as broadcast:
            with assert_stop(self, 'execution_module_origin'):
                sender.run(args, None, 'offline.invalid')
        permissive.assert_not_called()
        signing.assert_not_called()
        signed.assert_not_called()
        broadcast.assert_not_called()

    def test_clean(self):
        e.check(self.commit)

    def test_environment_redirect_cannot_hide_dirty_tree(self):
        clone = self.base / 'clone'
        self.git('clone', '-q', str(self.root), str(clone))
        self.source.write_text('VALUE = 2\n')
        with patch.dict(os.environ, {'GIT_DIR': str(clone / '.git'), 'GIT_WORK_TREE': str(clone),
                                     'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'status.showUntrackedFiles',
                                     'GIT_CONFIG_VALUE_0': 'no'}):
            with assert_stop(self, 'execution_clean_tree'):
                e.check(self.commit)

    def test_execution_root(self):
        child = self.root / 'child'
        child.mkdir()
        with patch.object(e.u, 'ROOT', child):
            with assert_stop(self, 'execution_root'):
                e.tree_gates(self.commit)

    def test_execution_index_flags(self):
        for flag in ('--skip-worktree', '--assume-unchanged'):
            with self.subTest(flag=flag):
                self.git('update-index', flag, 'executor.py')
                with assert_stop(self, 'execution_index_flags'):
                    e.tree_gates(self.commit)
                self.git('update-index', '--no-skip-worktree', '--no-assume-unchanged', 'executor.py')

    def test_execution_module_bytes(self):
        self.source.write_text('VALUE = 2\n')
        with assert_stop(self, 'execution_module_bytes'):
            e.module_gates(self.commit)

    def test_execution_module_tracked(self):
        shadow = self.root / 'shadow.py'
        shadow.write_text('VALUE = 1\n')
        original = e.git
        def git(*args):
            # Successful object bytes isolate the tracked assertion when deleted.
            if args == ('show', self.commit + ':shadow.py'):
                return shadow.read_bytes()
            return original(*args)
        with patch.dict(sys.modules, {'commit6f_fixture': self.load_module(shadow)}), \
             patch.object(e, 'git', side_effect=git):
            with assert_stop(self, 'execution_module_tracked'):
                e.module_gates(self.commit)

    def test_ignored_and_pyc_only(self):
        (self.root / '.git/info/exclude').write_text('shadow.py\n*.pyc\n')
        for name in ('shadow.py', 'only.pyc'):
            path = self.root / name
            path.write_bytes(b'ignored')
            with patch.dict(sys.modules, {'commit6f_fixture': SimpleNamespace(__file__=str(path))}):
                with assert_stop(self, 'execution_module_tracked'):
                    e.check(self.commit)

    def test_os_open(self):
        with reads.guard(frozenset()):
            for flags in (os.O_RDONLY, os.O_RDWR):
                with assert_stop(self, 'execution_repo_read'):
                    fd = os.open(self.source, flags)
                    os.close(fd)

    def test_popen(self):
        with reads.guard(frozenset()):
            with assert_stop(self, 'execution_repo_read'):
                with subprocess.Popen(['git', '--version'], stdout=subprocess.PIPE) as process:
                    process.communicate()

    def test_read_guard_restores_and_allows_write(self):
        originals = os.open, subprocess.Popen
        with reads.guard(frozenset()):
            fd = os.open(self.source, os.O_WRONLY)
            os.close(fd)
        self.assertEqual(originals, (os.open, subprocess.Popen))

    def test_manifest_checks_loaded_modules_before_runner(self):
        import manifest_exec as manifest
        shadow = self.root / 'shadow.py'
        shadow.write_text('VALUE = 1\n')
        (self.root / '.git/info/exclude').write_text('shadow.py\n')
        plan = {'rebuild': {'commit': self.commit}, 'externalInputs': {}}
        with patch.dict(sys.modules, {'commit6f_fixture': self.load_module(shadow)}), \
             patch.object(manifest, 'validate_plan', return_value={}), \
             patch.object(manifest, '_run_manifest') as runner:
            with assert_stop(self, 'execution_module_tracked'):
                manifest.run_manifest(None, SimpleNamespace(local=True), plan, self.base)
            runner.assert_not_called()

    def test_sender_integrity_before_signing_and_after_confirmation(self):
        import hashlib
        import json
        import a3a_send as sender
        for late in (False, True):
            with self.subTest(late=late):
                self.source.write_text('VALUE = 1\n')
                plan = {'rebuild': {'commit': self.commit},
                        'pin': {'senders': {'owner': {'address': '0x123'}}}}
                plan_file = self.base / 'plan.json'
                raw_plan = json.dumps(plan).encode()
                plan_file.write_bytes(raw_plan)
                accounts = self.base / 'accounts.json'
                accounts.write_text('{"owner": "offline-fixture"}')
                out = self.base / ('late' if late else 'early')
                out.mkdir()
                args = SimpleNamespace(plan=plan_file, out=out, step='S1', accounts=accounts,
                                       password_file=None, confirm=None,
                                       reviewed_plan_sha256=hashlib.sha256(raw_plan).hexdigest())
                def confirm(prompt):
                    self.source.write_text('VALUE = 2\n')
                    return 'SEND S1 ' + args.reviewed_plan_sha256[:12]
                if not late:
                    self.source.write_text('VALUE = 2\n')
                with patch.object(sender.ex, 'plan_json', side_effect=json.loads), \
                     patch.object(sender.ex, 'signing_transaction', return_value={'from': '0x123'}) as signing, \
                     patch.object(sender, 'signed', return_value=('0x12', '0xhash', {})) as signed, \
                     patch.object(sender, 'fee_fits'), patch.object(sender, 'broadcast') as broadcast:
                    with assert_stop(self, 'execution_clean_tree'):
                        sender.run(args, None, 'offline.invalid', confirm=confirm)
                    self.assertEqual(signing.call_count, 2 if late else 0)
                    self.assertEqual(signed.call_count, 1 if late else 0)
                    broadcast.assert_not_called()

    def test_new_names_unique_across_executor_sources(self):
        from test_gate_names import inventory
        root = Path(__file__).resolve().parents[2]
        files = ('script/a3a/a3a_exec.py', 'script/a3a/a3a_send.py',
                 'script/upgrade/sp_upgrade_exec.py', 'script/upgrade/manifest_exec.py',
                 'script/upgrade/old_owner_isolation.py', 'script/upgrade/execution_reads.py',
                 'script/upgrade/execution_integrity.py')
        literals, _ = inventory({file: (root / file).read_text() for file in files})
        for gate in ('execution_root', 'execution_index_flags', 'execution_module_tracked',
                     'execution_module_bytes', 'execution_module_origin', 'execution_head', 'execution_clean_tree'):
            self.assertEqual(len(literals[gate]), 1, gate)


class DeclarationTests(unittest.TestCase):
    def test_6f_declarations_reject_changed_bytes_and_gate_locations(self):
        import json
        import gate_rename_ast_diff as audit
        originals, changes = audit.declared_6f('WORKTREE')
        self.assertIn('script/upgrade/execution_integrity.py', originals)
        self.assertEqual(len(changes), 6)
        real_read = audit.read
        declaration = 'script/upgrade/gate_6f_additions.json'
        rows = json.loads(real_read('WORKTREE', declaration))
        rows[0]['gates'][0]['line'] += 1
        def changed_location(revision, file):
            return json.dumps(rows) if file == declaration else real_read(revision, file)
        with patch.object(audit, 'read', side_effect=changed_location):
            with self.assertRaisesRegex(ValueError, 'gate location/fingerprint mismatch'):
                audit.declared_6f('WORKTREE')
        def changed_bytes(revision, file):
            source = real_read(revision, file)
            if revision == 'WORKTREE' and file == 'script/upgrade/execution_integrity.py':
                return source + '\n'
            return source
        with patch.object(audit, 'read', side_effect=changed_bytes):
            with self.assertRaisesRegex(ValueError, 'after fingerprint mismatch'):
                audit.declared_6f('WORKTREE')


if __name__ == '__main__':
    unittest.main()
