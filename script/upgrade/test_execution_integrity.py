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
import sp_upgrade_exec as u
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
        bootstrap = patch.object(e, 'bootstrap')
        bootstrap.start()
        self.addCleanup(bootstrap.stop)
        import manifest_exec as manifest
        import a3a_send as sender
        for module, name, callback in ((manifest, 'execution_tree_gates', lambda plan: e.check(plan['rebuild']['commit'])),
                                       (sender, 'integrity_check', e.check)):
            wrapper = patch.object(module, name, side_effect=callback)
            wrapper.start()
            self.addCleanup(wrapper.stop)
        root = patch.object(u, 'ROOT', self.root)
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
        with patch.object(u, 'ROOT', child):
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
                     'execution_module_bytes', 'execution_module_origin', 'execution_bootstrap_origin', 'execution_head', 'execution_clean_tree'):
            self.assertEqual(len(literals[gate]), 1, gate)


class BootstrapTests(unittest.TestCase):
    def run_shadow(self, entry, shadow_name):
        import shutil
        with tempfile.TemporaryDirectory(prefix='commit6h-bootstrap-') as directory:
            root = Path(directory) / 'repo'
            shutil.copytree(Path(__file__).resolve().parents[2] / 'script', root / 'script',
                            ignore=shutil.ignore_patterns('__pycache__'))
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(PYTHONDONTWRITEBYTECODE='1', PYTHONPATH=os.pathsep.join(
                str(root / path) for path in ('script/upgrade', 'script/a3a')),
                GIT_CONFIG_NOSYSTEM='1')
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, env=env, check=True,
                                      capture_output=True, text=True).stdout.strip()
            git('init', '-q')
            git('add', '.')
            git('-c', 'user.name=Offline', '-c', 'user.email=offline@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'bootstrap fixture')
            commit = git('rev-parse', 'HEAD')
            external = Path(directory) / (shadow_name + '.py')
            external.write_text('def check(commit): pass\n')
            code = f"""
import sys
import unittest
from types import SimpleNamespace
import a3a_exec as a
import manifest_exec as manifest
import a3a_send as sender
from gate_assertions import assert_stop
class Regression(unittest.TestCase):
    def runTest(self):
        sender.integrity_check(COMMIT)
        manifest.execution_tree_gates({{'rebuild': {{'commit': COMMIT}}}})
        shadow = SimpleNamespace(__file__={str(external)!r}, check=lambda commit: None,
                                 ROOT={str(root)!r}, a=SimpleNamespace(need=lambda *args: None))
        from pathlib import Path
        shadow.ROOT = Path(shadow.ROOT)
        sys.modules[{shadow_name!r}] = shadow
        with assert_stop(self, 'execution_bootstrap_origin'):
            {entry}
unittest.main()
"""
            result = subprocess.run([sys.executable, '-B', '-c', code.replace('COMMIT', repr(commit))],
                                    cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_preloaded_execution_integrity_manifest(self):
        self.run_shadow("manifest.execution_tree_gates({'rebuild': {'commit': COMMIT}})",
                        'execution_integrity')

    def test_preloaded_execution_integrity_sender(self):
        self.run_shadow('sender.integrity_check(COMMIT)', 'execution_integrity')

    def test_execution_bootstrap_origin(self):
        self.run_shadow('sender.integrity_check(COMMIT)', 'sp_upgrade_exec')


class HelperSourceTests(unittest.TestCase):
    """An edited execution_integrity.py is refused before any of it runs."""
    def run_altered(self, entry, gate):
        import shutil
        with tempfile.TemporaryDirectory(prefix='commit6i-helper-') as directory:
            root = Path(directory) / 'repo'
            shutil.copytree(Path(__file__).resolve().parents[2] / 'script', root / 'script',
                            ignore=shutil.ignore_patterns('__pycache__'))
            env = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
            env.update(PYTHONDONTWRITEBYTECODE='1', PYTHONPATH=os.pathsep.join(
                str(root / path) for path in ('script/upgrade', 'script/a3a')),
                GIT_CONFIG_NOSYSTEM='1')
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, env=env, check=True,
                                      capture_output=True, text=True).stdout.strip()
            git('init', '-q')
            git('add', '.')
            git('-c', 'user.name=Offline', '-c', 'user.email=offline@example.invalid',
                '-c', 'commit.gpgsign=false', 'commit', '-qm', 'helper fixture')
            commit = git('rev-parse', 'HEAD')
            helper = root / 'script/upgrade/execution_integrity.py'
            # The accidental edit this guards against: a debugging early return left behind.
            helper.write_text(helper.read_text() + '\n\ndef check(commit):\n    return\n')
            code = f"""
import unittest
import manifest_exec as manifest
import a3a_send as sender
from gate_assertions import assert_stop
class Regression(unittest.TestCase):
    def runTest(self):
        with assert_stop(self, {gate!r}):
            {entry}
unittest.main()
"""
            result = subprocess.run([sys.executable, '-B', '-c', code.replace('COMMIT', repr(commit))],
                                    cwd=root, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_execution_integrity_source(self):
        self.run_altered('sender.integrity_check(COMMIT)', 'execution_integrity_source')

    def test_execution_integrity_source_manifest(self):
        self.run_altered("manifest.execution_tree_gates({'rebuild': {'commit': COMMIT}})",
                         'execution_integrity_source_manifest')


class DeclarationTests(unittest.TestCase):
    def test_6f_declarations_reject_changed_bytes_and_gate_locations(self):
        import json
        import gate_rename_ast_diff as audit
        originals, changes = audit.declared_6f('WORKTREE')
        self.assertIn('script/upgrade/execution_integrity.py', originals)
        # 6f-6i production/fixture deltas plus the 6j-6l test/probe-only deltas (baseline d21042ad).
        self.assertEqual(sorted(originals), sorted([
            'script/upgrade/execution_integrity.py', 'script/upgrade/manifest_exec.py', 'script/a3a/a3a_send.py',
            'script/upgrade/execution_reads.py', 'script/upgrade/execution_git_fixture.py', 'script/a3a/test_a3a_send.py',
            'script/a3a/a3a_exec.py', 'script/upgrade/test_execution_head.py',
            'script/upgrade/test_manifest_exec.py', 'script/upgrade/probe_phase_c_gates.py',
            'script/evidence/enduser_mapping_probes.py', 'script/upgrade/probe_execution_head.py',
            'script/evidence/audit605_probes.py', 'script/upgrade/audit/probe_gate_removal.py']))
        self.assertEqual(len(changes), 14)
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
