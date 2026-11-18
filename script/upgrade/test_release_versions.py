#!/usr/bin/env python3
"""Offline source/release pin agreement and runtime literal hygiene; no executor imports."""
import ast
import re
import shutil
import tempfile
import unittest
from pathlib import Path
from gate_name_scan import ROOT, runtime_files

TABLE = 'script/upgrade/release_versions.py'
SEMVER = r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?'


def source_versions(root):
    versions = {}
    for path in sorted((Path(root)/'contracts/src').rglob('*.sol')):
        text = re.sub(r'/\*.*?\*/|//[^\n]*', '', path.read_text(), flags=re.S)
        # Scope each function to its declaring contract, including multi-contract files.
        for match in re.finditer(r'\bcontract\s+(\w+)\b[^{}]*\{', text):
            start, depth, end = match.end(), 1, match.end()
            while depth and end < len(text):
                depth += (text[end] == '{') - (text[end] == '}')
                end += 1
            body = text[start:end-1]
            version = re.search(r'\bfunction\s+version\s*\(\s*\)[^;{]*\{\s*return\s+["\']([^"\']+)["\']\s*;', body)
            if version:
                name = match.group(1)
                if name in versions:
                    raise AssertionError('duplicate contract: '+name)
                versions[name] = version.group(1)
    return versions


def check_release_versions(root=ROOT):
    root = Path(root)
    tree = ast.parse((root/TABLE).read_text())
    tables = {n.targets[0].id: ast.literal_eval(n.value) for n in tree.body
              if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name)}
    release = tables['RELEASE_VERSIONS']
    source = source_versions(root)
    for name, version in release.items():
        assert source.get(name) == version, f'{name}: release {version}, source {source.get(name)}'
    pattern = re.compile(r'(?:'+ '|'.join(re.escape(n) for n in release) + r')-' + SEMVER)
    for file in runtime_files(root):
        parsed = ast.parse((root/file).read_text())
        allowed = set()
        if file == TABLE:
            for node in parsed.body:
                if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name) and node.targets[0].id in ('RELEASE_VERSIONS', 'LIVE_VERSIONS'):
                    allowed.update(id(n) for n in ast.walk(node.value))
        for node in ast.walk(parsed):
            if isinstance(node, ast.Constant) and isinstance(node.value, str) and pattern.fullmatch(node.value):
                assert id(node) in allowed, f'stray version literal: {file}:{node.lineno}: {node.value}'


class ReleaseVersionTests(unittest.TestCase):
    def test_release_versions(self):
        check_release_versions()

    def test_negative_controls(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'cache/i0') as tmp:
            root = Path(tmp)
            for directory in ('contracts/src', 'script/a3a', 'script/upgrade'):
                shutil.copytree(ROOT/directory, root/directory)
            check_release_versions(root)
            path = root/'contracts/src/modules/monitoring/BLSAggregator.sol'
            original = path.read_text()
            version = source_versions(root)['BLSAggregator']
            path.write_text(original.replace(version, 'BLSAggregator-999.0.0'))
            with self.assertRaisesRegex(AssertionError, 'BLSAggregator: release'):
                check_release_versions(root)
            path.write_text(original)
            for version in (version, 'Registry-5.8.0'):
                path = root/'script/upgrade/manifest_exec.py'
                original = path.read_text()
                path.write_text(original+'\nSTRAY = '+repr(version)+'\n')
                with self.assertRaisesRegex(AssertionError, 'stray version literal'):
                    check_release_versions(root)
                path.write_text(original)

    def test_contract_names_not_version_prefixes(self):
        versions = source_versions(ROOT)
        self.assertNotEqual(versions['xPNTsToken'], versions['xPNTsTokenV2'])


if __name__ == '__main__':
    (ROOT/'cache/i0').mkdir(parents=True, exist_ok=True)
    unittest.main()
