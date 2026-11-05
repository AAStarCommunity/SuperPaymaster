#!/usr/bin/env python3
"""Offline tracked-file gate; historical exceptions are explicit and reviewable.

This guards accidental hardcoding, not deliberate evasion. Solidity hex literals,
split string literals, and raw bytes are out of scope."""
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
OLD_TIMELOCK = '0x86c86c789edc099801cc6a5f48334f1d67dc9564'
PATTERN = re.compile(re.escape(OLD_TIMELOCK.encode()), re.I)
ALLOWLIST = ROOT / 'script/upgrade/legacy_timelock_allowlist.json'


def scan(root, paths, allowlist):
    errors = []
    for name in paths:
        path = root / name
        # Never open environment files, including tracked example templates.
        if path.name == '.env.example':
            continue
        # A tracked environment file must be removed from the index.
        if path.name == '.env' or path.name.startswith('.env.'):
            errors.append(f'{name}: environment file in tracked scan (refused to read)')
            continue
        if path.is_dir():  # gitlink, not a blob
            continue
        if (name.startswith('docs/design/') and path.suffix in {'.md', '.json', '.jsonl', '.csv', '.tsv', '.txt', '.log', '.out', '.err', '.stdout', '.diff', '.patch', '.gz', '.hex', '.sha256', '.toml', '.ref', '.redacted', '.exit', '.start', '.end', '.load', '.ps-after', '.superseded'}) or name in allowlist:
            continue
        data = str(path.readlink()).encode() if path.is_symlink() else path.read_bytes()
        for number, line in enumerate(data.splitlines(), 1):
            # Exceptions apply to the exact field / constant assignment, not the whole line/file.
            allowed = rb'(?!)'
            if name == 'deployments/config.sepolia.json':
                allowed = rb'"timelockControllerLegacy"\s*:\s*"' + PATTERN.pattern + rb'"'
            elif name in ('script/upgrade/old_owner_isolation.py', 'script/upgrade/test_no_legacy_timelock.py'):
                allowed = rb'^OLD_TIMELOCK\s*=\s*[\x27\x22]' + PATTERN.pattern + rb'[\x27\x22]'
            remainder = re.sub(allowed, b'', line, flags=re.I)
            if PATTERN.search(remainder):
                errors.append(f'{name}:{number}: forbidden legacy timelock')
        if name.startswith('deployments/') and path.suffix == '.json':
            decoded = json.loads(data)
            if name == 'deployments/config.sepolia.json' and isinstance(decoded, dict):
                legacy = decoded.get('timelockControllerLegacy')
                if isinstance(legacy, str) and legacy.lower() == OLD_TIMELOCK:
                    decoded.pop('timelockControllerLegacy')
            if PATTERN.search(json.dumps(decoded, ensure_ascii=False).encode()) and not any(e.startswith(name+':') for e in errors):
                errors.append(f'{name}: forbidden decoded legacy timelock')
    return errors


def tracked(root):
    return subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')[:-1]


class NoLegacyTimelockTests(unittest.TestCase):
    def test_tracked_files_have_no_unapproved_legacy_address(self):
        allowlist = json.loads(ALLOWLIST.read_text())
        paths = tracked(ROOT)
        for path, reason in allowlist.items():
            self.assertIn(path, paths)
            self.assertTrue(isinstance(reason, str) and reason.strip() and '\n' not in reason)
            self.assertNotIn('*', path)
        self.assertEqual(scan(ROOT, paths, allowlist), [])

    def test_negative_injected_occurrence_in_temp_copy(self):
        # Copy a real tracked source; never change the checkout or its git index.
        name = 'contracts/script/v3/UpgradeLive.s.sol'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / name
            target.parent.mkdir(parents=True)
            original = (ROOT / name).read_bytes()
            target.write_bytes(original)
            self.assertEqual(scan(root, [name], {}), [])
            for address in (OLD_TIMELOCK, OLD_TIMELOCK.upper(), '0x' + OLD_TIMELOCK[2:20].upper() + OLD_TIMELOCK[20:]):
                target.write_bytes(original + b'\n// injected ' + address.encode())
                self.assertEqual(len(scan(root, [name], {})), 1)

    def test_negative_canonical_field_not_exempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = 'deployments/config.sepolia.json'
            (root / name).parent.mkdir()
            (root / name).write_text(json.dumps({'timelockControllerLegacy': OLD_TIMELOCK}))
            self.assertEqual(scan(root, [name], {}), [])
            (root / name).write_text(json.dumps({'timelockControllerLegacy': OLD_TIMELOCK, 'timelockController': OLD_TIMELOCK}))
            self.assertEqual(len(scan(root, [name], {})), 1)

    def test_negative_design_executable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = 'docs/design/run.sh'
            (root / name).parent.mkdir(parents=True)
            (root / name).write_text(OLD_TIMELOCK)
            self.assertEqual(len(scan(root, [name], {})), 1)

    def test_negative_decoded_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = 'deployments/config.test.json'
            (root / name).parent.mkdir()
            (root / name).write_text(json.dumps({'owner': OLD_TIMELOCK}).replace('x', r'\u0078'))
            self.assertEqual(len(scan(root, [name], {})), 1)

    def test_negative_release_source_not_blanket_exempt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = 'docs/release/new-run.sh'
            (root / name).parent.mkdir(parents=True)
            (root / name).write_text(OLD_TIMELOCK)
            self.assertEqual(len(scan(root, [name], {})), 1)


if __name__ == '__main__':
    unittest.main(verbosity=2)
