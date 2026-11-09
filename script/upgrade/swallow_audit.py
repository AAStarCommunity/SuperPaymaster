"""Offline conservative AST call-closure audit for the fork rehearsal."""
import ast
import hashlib
import json
from pathlib import Path
import sp_upgrade_exec as u

PATHS = {
    'manifest_exec': 'script/upgrade/manifest_exec.py',
    'sp_upgrade_exec': 'script/upgrade/sp_upgrade_exec.py',
    'a3a_exec': 'script/a3a/a3a_exec.py',
    'old_owner_isolation': 'script/upgrade/old_owner_isolation.py',
    'release_evidence': 'script/upgrade/release_evidence.py',
    'rpc_strict': 'script/evidence/lib/rpc_strict.py',
}


def sources():
    return {name: (u.ROOT/path).read_text() for name, path in PATHS.items()}


def dotted(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        base = dotted(node.value)
        return base+'.'+node.attr if base else None
    return None


def call_closure(texts):
    trees = {name: ast.parse(text) for name, text in texts.items()}
    functions, classes, aliases = {}, set(), {}
    def collect(module, body, prefix=''):
        for node in body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                name = prefix+node.name
                key = module+'.'+name
                if isinstance(node, ast.ClassDef):
                    classes.add(key)
                else:
                    functions[key] = node
                collect(module, node.body, name+'.')
            else:
                for child in ast.iter_child_nodes(node):
                    collect(module, [child], prefix)
    for module, tree in trees.items():
        collect(module, tree.body)
        for node in tree.body:
            if isinstance(node, ast.Import):
                for item in node.names:
                    if item.name in trees:
                        aliases[module+'.'+(item.asname or item.name)] = item.name
            elif isinstance(node, ast.ImportFrom) and node.module in trees:
                for item in node.names:
                    aliases[module+'.'+(item.asname or item.name)] = node.module+'.'+item.name
            elif isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                value = dotted(node.value)
                if value:
                    aliases[module+'.'+node.targets[0].id] = module+'.'+value
    def expand(name):
        seen = set()
        while name not in seen:
            seen.add(name)
            parts = name.split('.')
            match = next(('.'.join(parts[:i]) for i in range(len(parts), 0, -1)
                          if '.'.join(parts[:i]) in aliases), None)
            if match is None:
                break
            name = aliases[match]+name[len(match):]
        return name
    def resolve(owner, ref):
        module = owner.split('.')[0]
        scope = owner.rsplit('.', 1)[0]
        if ref.startswith('self.'):
            while scope != module:
                if scope in classes:
                    return {scope+ref[4:]} & functions.keys()
                scope = scope.rsplit('.', 1)[0]
        while True:
            candidate = expand(scope+'.'+ref)
            if candidate in functions:
                return {candidate}
            if candidate in classes:
                return {name for name in functions if name.startswith(candidate+'.')}
            if scope == module:
                break
            scope = scope.rsplit('.', 1)[0]
        # RPC values are passed into run_manifest and helpers, rather than constructed there.
        if ref in ('rpc', 'remote', 'secondary', 'fork'):
            return {'a3a_exec.RPC.__call__'}
        return set()
    pending, reached = ['manifest_exec.run_manifest'], set()
    while pending:
        owner = pending.pop()
        if owner in reached or owner not in functions:
            continue
        reached.add(owner)
        node = functions[owner]
        # Include nested callbacks conservatively even when their invocation is indirect.
        pending.extend(name for name in functions if name.startswith(owner+'.'))
        for item in ast.walk(node):
            if isinstance(item, (ast.Name, ast.Attribute)):
                ref = dotted(item)
                if ref:
                    pending.extend(resolve(owner, ref))
    return functions, reached


def handler_identity(module, function, handler):
    body = ast.dump(ast.Module(body=handler.body, type_ignores=[]), include_attributes=False)
    return dict(module=module, function=function, exception=ast.unparse(handler.type) if handler.type else 'bare',
                body_sha256=hashlib.sha256(body.encode()).hexdigest())


def always_raises(body):
    # Fail closed for complex control flow; a Raise on only one branch is insufficient.
    if any(isinstance(item, (ast.Return, ast.Break, ast.Continue))
           for node in body for item in ast.walk(node)):
        return False
    for node in body:
        if isinstance(node, ast.Raise):
            return True
        if isinstance(node, (ast.Return, ast.Break, ast.Continue)):
            return False
        if isinstance(node, ast.If) and always_raises(node.body) and always_raises(node.orelse):
            return True
    return False


def swallowed_handlers(texts):
    functions, reached = call_closure(texts)
    rows = []
    class Handlers(ast.NodeVisitor):
        def visit_FunctionDef(self, node):
            pass
        visit_AsyncFunctionDef = visit_FunctionDef
        def visit_ClassDef(self, node):
            pass
        def visit_ExceptHandler(self, node):
            types = node.type.elts if isinstance(node.type, ast.Tuple) else [node.type]
            if any(t is None or dotted(t) in ('Exception', 'BaseException') for t in types) and not always_raises(node.body):
                rows.append(handler_identity(module, function, node))
            self.generic_visit(node)
    for name in sorted(reached):
        module, function = name.split('.', 1)
        visitor = Handlers()
        for statement in functions[name].body:
            visitor.visit(statement)
    return rows, sorted(reached)


def assert_no_swallow(texts, allowlist):
    rows, reached = swallowed_handlers(texts)
    keys = ('module', 'function', 'exception', 'body_sha256')
    approved = [{k: row[k] for k in keys} for row in allowlist if row.get('reason') and row.get('continues_when')]
    unreviewed = [row for row in rows if row not in approved]
    u.a.need('swallow_exception', unreviewed, [])
    return reached


def reviewed_allowlist():
    return json.loads(Path(__file__).with_name('swallow_allowlist.json').read_text())
