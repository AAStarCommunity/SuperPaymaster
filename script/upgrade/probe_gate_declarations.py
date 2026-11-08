#!/usr/bin/env python3
"""Real declared-location counterexamples, with metadata and mutations in temp copies."""
import ast
import copy
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
from unittest.mock import patch
import gate_rename_ast_diff as d


def main():
    file = 'script/upgrade/old_owner_isolation.py'
    before, after = d.read('2acc71af', file), d.read('WORKTREE', file)
    mapping = json.loads((d.ROOT / d.MAP).read_text())
    rows = json.loads((d.ROOT / 'script/upgrade/gate_rename_references.json').read_text())
    row = next(r for r in rows if r['file'] == file and r['line'] == 1512)
    allowed, faults = d.compare(before, after, mapping, file)
    assert not faults, faults
    with tempfile.TemporaryDirectory(prefix='6e-declared-counterexamples-') as tmp:
        root = Path(tmp)
        directory = root / 'script/upgrade'
        directory.mkdir(parents=True)
        for name in ('gate_rename_references.json', 'gate_rename_structural.json',
                     'gate_production_additions.json', 'gate_typed_changes.json'):
            shutil.copyfile(d.ROOT / 'script/upgrade' / name, directory / name)
        node = next(n for n in ast.walk(ast.parse(after)) if isinstance(n, ast.Subscript)
                    and n.lineno == row['line'] and ast.unparse(n) == "case['gate']")
        lines = after.splitlines(keepends=True)
        start = sum(map(len, lines[:node.slice.lineno-1])) + node.slice.col_offset
        end = sum(map(len, lines[:node.slice.end_lineno-1])) + node.slice.end_col_offset
        changed = after[:start] + "'changed_lookup_key'" + after[end:]
        changed_rows = copy.deepcopy(rows)
        for declaration in changed_rows:
            if declaration['file'] == file:
                declaration['source_sha256'][1] = hashlib.sha256(changed.encode()).hexdigest()
        with patch.object(d, 'ROOT', root):
            for label, source, declarations in (
                    ('declared_lookup_key', changed, changed_rows),
                    ('stale_declaration', after, rows + [dict(row, path=row['path'] + '.unused')])):
                (directory / 'gate_rename_references.json').write_text(json.dumps(declarations))
                _, faults = d.compare(before, source, mapping, file)
                assert faults, label + ': counterexample accepted'
                for fault in faults:
                    print('REJECTED ' + fault)
                print('GATE_RENAME_AST_DIFF FAIL counterexample=' + label)
    print('GATE_DECLARATION_COUNTEREXAMPLES PASS baseline=green lookup=red stale=red')


if __name__ == '__main__':
    main()
