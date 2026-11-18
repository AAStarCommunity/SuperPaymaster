"""Offline round-two regressions; no Git writes or sockets."""
import ast
import builtins
from contextlib import contextmanager, ExitStack
import io
import os
from types import SimpleNamespace
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / 'a3a')]
import execution_set as execution
import a3a_send as sender
import a3a_exec as a
import sp_upgrade_exec as u
import manifest_exec as m


@contextmanager
def password_opens(sentinel):
    attempts = []
    def instrument(original):
        def checked(path, *args, **kwargs):
            if not isinstance(path, int) and Path(path).resolve() == sentinel.resolve():
                attempts.append(str(path))
                raise AssertionError('sentinel password opened')
            return original(path, *args, **kwargs)
        return checked
    with ExitStack() as stack:
        for owner, name in ((builtins, 'open'), (io, 'open'), (os, 'open'),
                            (Path, 'open'), (Path, 'read_text'), (Path, 'read_bytes')):
            stack.enter_context(patch.object(owner, name, instrument(getattr(owner, name))))
        yield attempts


class RoundTwoTests(unittest.TestCase):
    def test_password_zero_actual_opens(self):
        import execution_integrity
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / 'plan.json'
            binary = root / 'cast'
            binary.write_text('#!/bin/sh\necho fixture-cast\n')
            binary.chmod(0o700)
            signer = execution.cast_identity(binary)
            sentinel = root / 'NEVER_OPEN'
            for gate in ('execution_clean_tree', 'send_cast_path', 'send_cast_sha256', 'send_cast_version'):
                pin = dict(signer)
                if gate.startswith('send_cast_'):
                    pin[gate.removeprefix('send_cast_')] = 'incorrect'
                file.write_text(json.dumps({'rebuild': {'commit': 'reviewed'}, 'execution': {'cast': pin}}))
                args = SimpleNamespace(plan=file, out=root, password_file=sentinel,
                                       reviewed_plan_sha256=hashlib.sha256(file.read_bytes()).hexdigest())
                with self.subTest(gate=gate), password_opens(sentinel) as attempts, \
                     patch.object(sender, 'CAST', str(binary)), \
                     patch.object(execution_integrity, 'packet_check', return_value={}), \
                     patch.object(sender, 'integrity_check', side_effect=(
                         RuntimeError(gate) if gate == 'execution_clean_tree' else None), return_value={}):
                    caught = None
                    try:
                        sender.run(args, None, 'offline')
                    except Exception as error:
                        caught = error
                    self.assertEqual(attempts, [], 'password path must have zero actual opens')
                    self.assertIn(gate, str(caught))

    def test_read_inventory(self):
        inventory = execution.ROOT / 'script/upgrade/execution_data_reads.json'
        self.assertTrue(inventory.is_file(), 'missing reviewed read-site inventory')
        reviewed = json.loads(inventory.read_text())
        files = set(execution.execution_files())
        self.assertEqual(list(execution.SUPPLEMENTARY), reviewed['supplementary'])
        self.assertLessEqual(set(reviewed['supplementary']), files, 'supplementary inputs missing from manifest')
        for relative in sorted(files):
            if relative.endswith('.py'):
                entry = reviewed['modules'].get(relative, {})
                self.assertEqual(execution.read_sites((execution.ROOT / relative).read_text()),
                                 entry.get('reads', []), 'unregistered repository read: ' + relative)
                targets = {p.relative_to(execution.ROOT).as_posix() for p in
                           execution.static_files(execution.ROOT, execution.ROOT / relative)}
                self.assertEqual(targets, set(entry.get('targets', [])), 'unregistered repository target: ' + relative)
                self.assertLessEqual(set(entry.get('targets', [])), files, 'read target missing from manifest: ' + relative)

    def test_repository_data_in_manifest(self):
        files = execution.execution_files()
        for name in ('registry_ast_allowlist.json', 'registry_ast_node_types.json',
                     'release-evidence.schema.json', 'fraud-proof-fixture.schema.json',
                     'gate_name_frozen.json', 'gate_names_replaced_pr2.json',
                     'gate_renames_pr2.json', 'legacy_timelock_allowlist.json'):
            self.assertIn('script/upgrade/' + name, files, name)
        self.assertIn('abis/SuperPaymaster.full.json', files)

    def test_cli_never_refreshes_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan, packet, manifest = (root / n for n in ('plan.json', 'packet.json', 'manifest'))
            frozen = {'execution': {'manifestSha256': hashlib.sha256(b'A').hexdigest(), 'extra': 'keep'}}
            plan.write_text(json.dumps(frozen))
            packet.write_text('original packet')
            manifest.write_text('original manifest')
            with patch.object(sys, 'argv', ['freeze', '--plan', str(plan), '--packet', str(packet),
                                           '--manifest', str(manifest), '--cast', 'unused']), \
                 patch.object(execution, 'manifest', return_value='B'), \
                 patch.object(execution, 'cast_identity', return_value={'path': '/cast', 'sha256': 'x', 'version': 'v'}) as cast:
                with self.assertRaisesRegex(RuntimeError, 'execution_set_sha256'):
                    execution.main()
            self.assertEqual(json.loads(plan.read_text()), frozen)
            self.assertEqual(packet.read_text(), 'original packet')
            self.assertEqual(manifest.read_text(), 'original manifest')
            cast.assert_not_called()

    def test_cli_preserves_existing_execution_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan, packet, manifest = (root / n for n in ('plan.json', 'packet.json', 'manifest'))
            pin = {'path': '/reviewed/cast', 'sha256': 'hash', 'version': 'v'}
            frozen = {'execution': {'manifestSha256': hashlib.sha256(b'A').hexdigest(),
                                    'extra': 'keep', 'cast': pin}}
            plan.write_text(json.dumps(frozen))
            with patch.object(sys, 'argv', ['freeze', '--plan', str(plan), '--packet', str(packet),
                                           '--manifest', str(manifest), '--cast', 'unused']), \
                 patch.object(execution, 'manifest', return_value='A'), \
                 patch.object(execution, 'cast_identity', return_value=pin):
                execution.main()
                self.assertEqual(json.loads(packet.read_text()), frozen)
                with patch.object(execution, 'cast_identity', return_value=dict(pin, path='/other/cast')):
                    with self.assertRaisesRegex(RuntimeError, 'execution_cast_identity'):
                        execution.main()
                self.assertEqual(json.loads(packet.read_text()), frozen)

    def test_cast_identical_bytes_different_path(self):
        with tempfile.TemporaryDirectory() as directory:
            first, second = (Path(directory) / n for n in ('first', 'second'))
            for path in (first, second):
                path.write_text('#!/bin/sh\necho cast-test\n')
                path.chmod(0o700)
            pin = dict(path=str(first.resolve()), sha256=hashlib.sha256(first.read_bytes()).hexdigest(), version='cast-test')
            with patch.object(sender, 'CAST', str(second)), patch.object(sender.subprocess, 'run') as run:
                run.return_value.stdout = 'cast-test'
                run.return_value.returncode = 0
                with self.assertRaisesRegex(Exception, 'send_cast_path'):
                    sender.verify_cast({'execution': {'cast': pin}})
                run.assert_not_called()

    def test_all_freeze_writers_preserve_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            initial = {'execution': {'manifestSha256': hashlib.sha256(b'A').hexdigest(), 'extra': 'keep'}}
            with patch.object(execution, 'manifest', return_value='A'):
                execution.freeze_manifest(initial, out)
            for writer in ('helper', 'save_plan', 'plan_command', 'manifest_save'):
                plan = copy.deepcopy(initial)
                with self.subTest(writer=writer), patch.object(execution, 'manifest', return_value='B'), \
                     patch.object(a, 'require_final_artifact'), patch.object(a, 'preflight', return_value={'balance': 10**30}), \
                     patch.object(a, 'check_keccak'), patch.object(a, 'build_plan', return_value=plan), \
                     patch.object(a, 'safe_hash_check'), patch.object(a, 'rehearse'), patch.object(a, 'budget'):
                    with self.assertRaisesRegex(RuntimeError, 'execution_set_sha256'):
                        if writer == 'helper':
                            execution.freeze_manifest(plan, out)
                        elif writer == 'save_plan':
                            u.save_plan(out, plan)
                        elif writer == 'plan_command':
                            a.plan_command(None, None, out)
                        else:
                            m.save_artifact(out, plan)
                    self.assertEqual(plan, initial)
                    self.assertEqual((out / 'execution-set.sha256').read_text(), 'A')


if __name__ == '__main__':
    unittest.main()
