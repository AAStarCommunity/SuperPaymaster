"""AST inventory of a3a_exec.typed calls, including imported and assigned aliases."""
import ast
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def calls(source, file):
    tree = ast.parse(source, file)
    found = []
    scopes = [{'typed': 'typed'} if file.endswith('/a3a_exec.py') else {}]
    functions = []

    def resolve(node):
        if isinstance(node, ast.Name):
            return next((scope[node.id] for scope in reversed(scopes) if node.id in scope), None)
        if isinstance(node, ast.Attribute):
            parent = resolve(node.value)
            if parent == 'module' and node.attr == 'typed':
                return 'typed'
            if parent == 'upgrade' and node.attr == 'a':
                return 'module'
        return None

    class Scan(ast.NodeVisitor):
        def visit_Import(self, node):
            for item in node.names:
                if item.name.endswith('a3a_exec'):
                    scopes[-1][item.asname or item.name] = 'module'
                elif item.name.endswith(('sp_upgrade_exec', 'manifest_exec', 'old_owner_isolation')):
                    scopes[-1][item.asname or item.name] = 'upgrade'

        def visit_ImportFrom(self, node):
            for item in node.names:
                kind = ('typed' if (node.module or '').endswith('a3a_exec') and item.name == 'typed'
                        else 'module' if item.name == 'a3a_exec' else None)
                if kind:
                    scopes[-1][item.asname or item.name] = kind

        def visit_Assign(self, node):
            self.visit(node.value)
            for target in node.targets:
                if isinstance(target, ast.Name):
                    scopes[-1][target.id] = resolve(node.value)

        def visit_FunctionDef(self, node):
            functions.append(node.name)
            scopes.append({arg.arg: None for arg in node.args.posonlyargs + node.args.args + node.args.kwonlyargs})
            for child in node.body:
                self.visit(child)
            scopes.pop()
            functions.pop()

        visit_AsyncFunctionDef = visit_FunctionDef

        def visit_Call(self, node):
            if resolve(node.func) == 'typed':
                found.append((functions[-1] if functions else 'module', node))
            self.generic_visit(node)
    Scan().visit(tree)
    return sorted(found, key=lambda row: (row[1].lineno, row[1].col_offset))


def inventory(sources=None, require_gate=True):
    if sources is None:
        files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard',
                                         '--', '*.py'], cwd=ROOT, text=True).splitlines()
        sources = {file: (ROOT / file).read_text() for file in sorted(set(files)) if (ROOT / file).is_file()}
    rows = []
    for file, source in sorted(sources.items()):
        for function, call in calls(source, file):
            gate = next((k.value for k in call.keywords if k.arg == 'gate'),
                        call.args[2] if len(call.args) > 2 else None)
            if gate is None and require_gate:
                raise ValueError(f'typed missing gate: {file}:{call.lineno}:{call.col_offset}')
            rows.append(dict(file=file, function=function, line=call.lineno, column=call.col_offset,
                             gate=gate, call=call))
    return rows
