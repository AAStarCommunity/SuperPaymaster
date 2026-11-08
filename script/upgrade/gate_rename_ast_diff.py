#!/usr/bin/env python3
"""Fail-closed gate-only AST comparison of two revisions (or HEAD WORKTREE).

Deleted files are rejected. Added files are fingerprinted for review.
No test-structure or infrastructure exemptions are implicit.
"""
import ast
import json
import hashlib
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MAP = 'script/upgrade/gate_rename_map.json'
from gate_name_flow import Flow


def gate_sites(tree, expand=False):
    yield from Flow(tree).sites(expand)


def reference_sites(tree):
    """Follow expected-name parameters from comparisons against caught Gate records."""
    flow = Flow(tree, historical=True)
    refs = {fn: set() for fn in flow.rules}
    seeds = []
    for scope, call in flow.calls:
        if ast.unparse(call.func) != 'a.need' or len(call.args) < 3 or scope is None:
            continue
        observed = call.args[1]
        if not isinstance(observed, ast.Name):
            continue
        assignments = [n for n in ast.walk(scope) if isinstance(n, ast.Assign) and flow.owner.get(n) is scope
                       and any(isinstance(t, ast.Name) and t.id == observed.id for t in n.targets)]
        def caught_record(value):
            return (isinstance(value, ast.Subscript) and isinstance(value.slice, ast.Constant)
                    and value.slice.value == 'gate' and isinstance(value.value, ast.Attribute)
                    and value.value.attr == 'record' and isinstance(value.value.value, ast.Name)
                    and any(isinstance(n, ast.ExceptHandler) and n.name == value.value.value.id
                            and flow.owner.get(n) is scope and n.type is not None and ast.unparse(n.type) == 'a.Gate'
                            and len(n.body) == 1 and isinstance(n.body[0], ast.Assign)
                            and n.body[0].value is value
                            and not any(isinstance(other, ast.Name) and other.id == n.name
                                        and isinstance(other.ctx, ast.Store) for other in ast.walk(scope))
                            for n in ast.walk(scope)))
        stores = [n for n in ast.walk(scope) if isinstance(n, ast.Name) and n.id == observed.id
                  and isinstance(n.ctx, ast.Store)]
        if len(assignments) == len(stores) == 1 and assignments[0].lineno < call.lineno and caught_record(assignments[0].value):
            seeds.append((scope, call.args[2]))
    positions = list(seeds)
    changed = True
    while changed:
        changed = False
        for scope, value in positions:
            if scope is None:
                continue
            params = [p.arg for p in scope.args.posonlyargs + scope.args.args]
            if isinstance(value, ast.Name) and value.id in params:
                rule = (params.index(value.id), value.id)
                if rule not in refs[scope]:
                    refs[scope].add(rule)
                    changed = True
        positions = list(seeds)
        from gate_name_flow import argument
        for scope, call in flow.calls:
            if isinstance(call.func, ast.Name):
                for index, name in refs.get(flow.resolve(scope, call.func.id), ()):
                    value = argument(call, index, name)
                    if value is not None:
                        positions.append((scope, value))
    # A parameter used as data as well as an expected name is not a rename proof.
    while True:
        permitted = {id(value) for _, value in positions}
        removed = False
        for fn, rules in refs.items():
            for rule in list(rules):
                uses = [n for n in ast.walk(fn) if isinstance(n, ast.Name) and n.id == rule[1]]
                if any(isinstance(n.ctx, ast.Store) or id(n) not in permitted for n in uses):
                    rules.remove(rule)
                    removed = True
        if not removed:
            break
        positions = list(seeds)
        for scope, call in flow.calls:
            if isinstance(call.func, ast.Name):
                for index, name in refs.get(flow.resolve(scope, call.func.id), ()):
                    value = argument(call, index, name)
                    if value is not None:
                        positions.append((scope, value))
    return {id(value) for _, value in positions}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True)


def files(revision):
    if revision == 'WORKTREE':
        return {file for file in git('ls-files', '--cached', '--others', '--exclude-standard', 'script').splitlines()
                if (ROOT / file).is_file()}
    return set(git('ls-tree', '-r', '--name-only', revision, '--', 'script').splitlines())


def read(revision, file):
    if revision == 'WORKTREE':
        path = ROOT / file
        return path.read_text() if path.is_file() else None
    result = subprocess.run(['git', 'show', revision + ':' + file], cwd=ROOT,
                            capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def compare(before, after, mapping, file, rejection_details=None):
    left, right = ast.parse(before, file), ast.parse(after, file)
    additions = json.loads((ROOT / 'script/upgrade/gate_production_additions.json').read_text())
    addition_changes = []
    keyword_rows = json.loads((ROOT / 'script/upgrade/gate_typed_changes.json').read_text())
    for row in keyword_rows:
        if row['file'] != file or row['kind'] != 'keyword':
            continue
        matches = [n for n in ast.walk(right) if isinstance(n, ast.Call)
                   and n.lineno == row['line'] and n.col_offset == row['column']
                   and any(k.arg == 'gate' for k in n.keywords)]
        if len(matches) != 1:
            return [], [file + ': typed keyword declaration location mismatch']
        call = matches[0]
        owners = [n for n in ast.walk(right) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
                  and n.lineno <= call.lineno <= n.end_lineno]
        function = min(owners, key=lambda n: n.end_lineno - n.lineno).name if owners else 'module'
        if function != row['function']:
            return [], [file + ': typed keyword declaration function mismatch']
        keywords = [k for k in call.keywords if k.arg == 'gate'
                    and isinstance(k.value, ast.Constant) and k.value.value == row['gate']
                    and hashlib.sha256(ast.dump(k).encode()).hexdigest() == row['ast_sha256']]
        if len(keywords) != 1:
            return [], [file + ': typed keyword declaration fingerprint mismatch']
        call.keywords.remove(keywords[0])
        addition_changes.append(f"{file}:{row['line']}:{row['column']} REVIEWED_NON_RENAME_KEYWORD "
                                f"{row['gate']} ast_sha256={row['ast_sha256']}")
    for row in additions:
        if row['file'] != file:
            continue
        matches = [n for n in ast.walk(right) if isinstance(n, ast.Expr)
                   and n.lineno == row['line'] and n.col_offset == row['column']
                   and isinstance(n.value, ast.Call) and n.value.args
                   and isinstance(n.value.args[0], ast.Constant) and n.value.args[0].value == row['gate']
                   and hashlib.sha256(ast.dump(n).encode()).hexdigest() == row['ast_sha256']]
        if len(matches) != 1:
            return [], [file + ': declared production addition fingerprint/location mismatch']
        node = matches[0]
        owners = [n for n in ast.walk(right) if isinstance(n, ast.FunctionDef)
                  and n.name == row['function'] and node in list(ast.walk(n))]
        if len(owners) != 1 or any(ast.dump(n) == ast.dump(node) for n in ast.walk(left)):
            return [], [file + ': production addition is not a unique new statement in declared function']
        for parent in ast.walk(right):
            for _, value in ast.iter_fields(parent):
                if isinstance(value, list) and node in value:
                    value.remove(node)
        addition_changes.append(f"{file}:{row['line']}:{row['column']} REVIEWED_PRODUCTION_ADDITION "
                                f"{row['gate']} ast_sha256={row['ast_sha256']}")
    def gate_values(tree):
        # Only the argument itself and literal concatenation operands are labels.
        # In particular, never descend into lookups, calls, or format arguments.
        def atoms(value):
            yield value
            if isinstance(value, ast.BinOp) and isinstance(value.op, ast.Add):
                yield from atoms(value.left)
                yield from atoms(value.right)
        flow = Flow(tree, historical=True)
        for function, call, value in flow.sites():
            if isinstance(call.func, ast.Name):
                target = flow.resolve(flow.owner[call], call.func.id)
                if target is not None and any(not flow.label_only(target, rule[1]) for rule in flow.rules[target]):
                    continue
            for atom in atoms(value):
                yield function, atom
    right_values, left_values = list(gate_values(right)), list(gate_values(left))
    gates = {id(value): (function, value.lineno) for function, value in right_values}
    old_gates = {id(value) for _, value in left_values}
    old_refs = reference_sites(left)
    new_refs = reference_sites(right)
    is_test = Path(file).name.startswith(('test_', 'probe_')) or 'probes' in Path(file).stem
    allowed, rejected = addition_changes, []

    review_path = ROOT / 'script/upgrade/gate_rename_structural.json'
    reviews = json.loads(review_path.read_text()) if review_path.exists() else []

    declarations_path = ROOT / 'script/upgrade/gate_rename_references.json'
    declarations = json.loads(declarations_path.read_text()) if declarations_path.exists() else []
    file_pair = [hashlib.sha256(text.encode()).hexdigest() for text in (before, after)]
    used_declarations, used_reviews, used_signatures, used_mappings = set(), set(), set(), set()
    declarations = [r for r in declarations if r['file'] == file]
    reviews = [r for r in reviews if r['file'] == file]
    signatures = [r for r in keyword_rows if r['file'] == file and r['kind'] == 'signature']

    def mapping_owner(node, row):
        owners = [n for n in ast.walk(right) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
                  and n.lineno <= node.lineno <= n.end_lineno]
        owner = min(owners, key=lambda n: n.end_lineno - n.lineno).name if owners else '<module>'
        return row.get('function', owner) == owner

    def mapped_subtree(x, y):
        for old, rows in mapping.items():
            old_present = any((isinstance(n, ast.Constant) and n.value == old) or ast.unparse(n) == old
                              for n in ast.walk(x))
            if not old_present:
                continue
            for row in rows:
                if row['file'] == file and any(getattr(n, 'lineno', None) == row['line'] and mapping_owner(n, row) and
                        ((isinstance(n, ast.Constant) and n.value == row['new']) or ast.unparse(n) == row['new'])
                        for n in ast.walk(y)):
                    used_mappings.add(id(row))

    def record_rejection(x, y, location):
        if rejection_details is not None and isinstance(x, ast.AST) and isinstance(y, ast.AST):
            rejection_details.append(dict(file=file, line=y.lineno, path=location,
                before=ast.unparse(x), after=ast.unparse(y),
                ast_sha256=[hashlib.sha256(ast.dump(n).encode()).hexdigest() for n in (x, y)],
                source_sha256=file_pair))

    def walk(x, y, location):
        if isinstance(x, ast.AST) and isinstance(y, ast.AST):
            pair = [hashlib.sha256(ast.dump(n).encode()).hexdigest() for n in (x, y)]
            candidates = [r for r in declarations if r['path'] == location]
            declared = [r for r in candidates if r['line'] == getattr(y, 'lineno', None)
                        and r['ast_sha256'] == pair and r['source_sha256'] == file_pair and r.get('reason')]
            if candidates and (len(candidates) != 1 or len(declared) != 1):
                rejected.append(file + ': declaration fingerprint/location mismatch ' + location)
                return
            signature = [r for r in signatures if r['path'] == location and r['ast_sha256'] == pair]
            if signature:
                used_signatures.add(id(signature[0]))
                allowed.append(file + ': REVIEWED_NON_RENAME_SIGNATURE ' + location + ' ast_sha256=' + repr(pair))
                return
            if len(declared) == 1:
                used_declarations.add(id(declared[0]))
                mapped_subtree(x, y)
                allowed.append(f'{file}:{y.lineno} REVIEWED_GATE_REFERENCE {ast.unparse(x)} -> {ast.unparse(y)}')
                return
        if (isinstance(x, ast.AST) and isinstance(y, ast.BinOp) and isinstance(y.op, ast.Add)
                and isinstance(y.left, ast.Constant) and isinstance(y.left.value, str)
                and ast.dump(x) == ast.dump(y.right)):
            rows = mapping.get(ast.unparse(x), [])
            matched = any(row.get('kind') == 'prefix_expression' and row['file'] == file
                          and row['line'] == y.lineno and row['new'] == ast.unparse(y) and mapping_owner(y, row) for row in rows)
            if matched and (id(x) in old_gates and id(y) in gates or
                            id(x) in old_refs and id(y) in new_refs):
                used_mappings.update(id(row) for row in rows if row.get('kind') == 'prefix_expression' and row['file'] == file and row['line'] == y.lineno and row['new'] == ast.unparse(y) and mapping_owner(y, row))
                allowed.append(f'{file}:{y.lineno} mapped gate prefix expression')
                return
        if isinstance(x, ast.AST) and isinstance(y, ast.AST):
            pair = [hashlib.sha256(ast.dump(n).encode()).hexdigest() for n in (x, y)]
            reviewed = next((r for r in reviews if r['file'] == file and r['ast_sha256'] == pair
                             and r['name'] == getattr(y, 'name', 'REQUIRED' if isinstance(y, ast.Assign) else None)), None)
            structural_test = (is_test and isinstance(x, ast.FunctionDef) and isinstance(y, ast.FunctionDef)
                               and x.name == y.name and (x.name.startswith('test_') or x.name == 'approval_history_control'))
            binding_table = (file == 'script/evidence/audit605_probes.py' and isinstance(x, ast.Assign)
                             and isinstance(y, ast.Assign) and all(len(n.targets) == 1 and isinstance(n.targets[0], ast.Name)
                                                                 and n.targets[0].id == 'REQUIRED' for n in (x, y)))
            if reviewed and reviewed.get('reason') and (structural_test or binding_table):
                used_reviews.add(id(reviewed))
                mapped_subtree(x, y)
                allowed.append(file + ': REVIEWED_STRUCTURE ' + reviewed['name'])
                return
        if type(x) is not type(y):
            record_rejection(x, y, location)
            rejected.append(f'{file}:{getattr(y, "lineno", 0)}: {ast.unparse(x) if isinstance(x, ast.AST) else x!r} -> {ast.unparse(y) if isinstance(y, ast.AST) else y!r} (AST node type changed)')
            return
        if isinstance(x, ast.Constant) and isinstance(x.value, str) and isinstance(y.value, str) and x.value != y.value:
            rows = mapping.get(x.value, [])
            mapped = any(row['new'] == y.value for row in rows)
            gate = gates.get(id(y))
            source = id(x) in old_gates and gate and any(
                row['new'] == y.value and row['file'] == file and
                row['function'] == gate[0] and row['line'] == gate[1] for row in rows)
            if mapped and id(x) in old_refs and id(y) in new_refs:
                mapped_subtree(x, y)
                allowed.append(f'{file}:{y.lineno} mapped expected-gate reference {x.value!r} -> {y.value!r}')
                return
            disjoint_exception = any(row['new'] == y.value and row.get('disjointness_exception')
                                     and row.get('reason') and row['file'] == file and row['line'] == y.lineno
                                     for row in rows)
            if mapped and x.kind == y.kind and (y.value.startswith(x.value if x.value.endswith('_') else x.value + '_') or disjoint_exception) and source:
                used_mappings.update(id(row) for row in rows if row['new'] == y.value and row['file'] == file and row['function'] == gate[0] and row['line'] == gate[1])
                allowed.append(f'{file}:{y.lineno} {x.value!r} -> {y.value!r}')
                return
        if isinstance(x, ast.Constant) and isinstance(y, ast.Constant) and x.value != y.value:
            record_rejection(x, y, location)
            rejected.append(f'{file}:{y.lineno}: {ast.unparse(x)} -> {ast.unparse(y)}')
            return
        if isinstance(x, ast.AST):
            for field in x._fields:
                walk(getattr(x, field), getattr(y, field), location + '.' + field)
        elif isinstance(x, list):
            if len(x) != len(y):
                rejected.append(location + ': AST list length changed')
            for index, (a, b) in enumerate(zip(x, y)):
                walk(a, b, f'{location}[{index}]')
        elif x != y:
            rejected.append(f'{location}: {x!r} -> {y!r}')
    walk(left, right, file)
    for category, rows, used in (('reference', declarations, used_declarations),
                                  ('structure', reviews, used_reviews), ('signature', signatures, used_signatures),
                                  ('mapping', [r for rows in mapping.values() for r in rows if r['file'] == file], used_mappings)):
        for row in rows:
            if id(row) not in used:
                rejected.append(file + ': stale/unused or mismatched ' + category + ' declaration ' + str(row.get('path', row.get('name', row))))
    return allowed, rejected


def main(argv):
    changes, faults = [], []
    try:
        if len(argv) != 2:
            raise ValueError('usage: gate_rename_ast_diff.py BEFORE AFTER (AFTER may be WORKTREE)')
        before, after = argv
        mapping = json.loads(read(after, MAP))
        old_files, new_files = files(before), files(after)
        for file in sorted(new_files - old_files):
            if after == 'WORKTREE':
                raw = (ROOT / file).read_bytes()
            else:
                raw = subprocess.check_output(['git', 'show', after + ':' + file], cwd=ROOT)
            print('ADDED ' + file + ' sha256=' + hashlib.sha256(raw).hexdigest() +
                  ' lines=' + str(len(raw.splitlines())))
        for file in sorted(old_files - new_files):
            print('DELETED ' + file)
            faults.append(file + ': undeclared file deletion')
        declared_files = set()
        for name in ('gate_rename_references.json', 'gate_rename_structural.json',
                     'gate_production_additions.json', 'gate_typed_changes.json'):
            for row in json.loads((ROOT / 'script/upgrade' / name).read_text()):
                declared_files.add(row['file'])
                if row['file'] not in old_files & new_files:
                    faults.append(name + ': stale/unused declaration file ' + row['file'])
        for rows in mapping.values():
            for row in rows:
                declared_files.add(row['file'])
                if row['file'] not in old_files & new_files:
                    faults.append('mapping: stale/unused declaration file ' + row['file'])
        for file in sorted(declared_files):
            if not file.endswith('.py'):
                faults.append(file + ': stale/unused declaration outside Python AST comparison')
        for file in sorted(old_files & new_files):
            if not file.endswith('.py'):
                continue
            old, new = read(before, file), read(after, file)
            if old == new and file not in declared_files:
                continue
            allowed, rejected = compare(old, new, mapping, file)
            changes.extend(allowed)
            faults.extend(rejected)
    except (SyntaxError, ValueError, TypeError, KeyError, OSError, subprocess.CalledProcessError) as error:
        faults.append(str(error))
    for change in changes:
        print('ALLOWED ' + change)
    for fault in faults:
        print('REJECTED ' + fault)
    print(f'GATE_RENAME_AST_DIFF {"FAIL" if faults else "PASS"} n_changes={len(changes)}')
    return int(bool(faults))


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
