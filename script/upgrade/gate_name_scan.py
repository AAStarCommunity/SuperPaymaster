"""Static scan of gate-name producers and consumers in the release executors. Never executes source.

Producers: the name argument of need / Gate / typed / exact_keys, followed through function
parameters (a helper that receives the name and passes it on) to the literal or the prefix-concat
at each call site.

Consumers: every place that compares a caught gate name (an expression subscripted or .get() by
'gate', or a local assigned from one) against something: ==, !=, in, not in, and need(x, A, B)
where A or B is the caught name. The other side is followed through function parameters and
module-level constant collections.

Matching is one-directional and exact: a consumer literal must equal a producer literal, or start
with a producer prefix and be longer; a consumer prefix must equal a producer prefix.
"""
import ast
import hashlib
import json
import subprocess
import tempfile
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SKIP = ('test_', 'probe_', 'gate_', 'make_')
# How the executors import each other (import a3a_exec as a / ex, sp_upgrade_exec as u, ...).
CORE_HELPERS = {'need', 'typed', 'exact_keys', 'Gate'}
MODULE_ALIASES = {'a', 'ex', 'u', 'm', 'o', 'e', 'p', 's', 'sd', 'isolation', 'manifest'}


def runtime_files(root=ROOT):
    """Every executor module: script/a3a and script/upgrade, excluding tests, probes, scanners, fixtures."""
    files = []
    for directory in ('script/a3a', 'script/upgrade'):
        for path in sorted((root/directory).glob('*.py')):
            if not path.name.startswith(SKIP) and 'fixture' not in path.name:
                files.append(path.relative_to(root).as_posix())
    return files


def _name(func):
    return func.id if isinstance(func, ast.Name) else func.attr if isinstance(func, ast.Attribute) else None


def _producer_arg(call):
    fn = _name(call.func)
    if fn in ('need', 'Gate', 'exact_keys'):
        return call.args[0] if call.args else None
    if fn == 'typed':
        return next((k.value for k in call.keywords if k.arg == 'gate'), call.args[2] if len(call.args) > 2 else None)
    return 'skip'


def _call_arg(call, index, name):
    for k in call.keywords:
        if k.arg == name:
            return k.value
    return call.args[index] if index < len(call.args) else None


def _prefix(expr):
    """Leading literal of 'lit' + x (left-nested) or f'lit{x}'; None otherwise."""
    if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.Add):
        left = expr.left
        while isinstance(left, ast.BinOp) and isinstance(left.op, ast.Add):
            left = left.left
        return left.value if isinstance(left, ast.Constant) and isinstance(left.value, str) else None
    if isinstance(expr, ast.JoinedStr) and expr.values and isinstance(expr.values[0], ast.Constant):
        return expr.values[0].value
    return None


class Scan:
    def __init__(self, root=ROOT, files=None):
        self.root = Path(root)
        self.files = files or runtime_files(self.root)
        self.trees = {f: ast.parse((self.root/f).read_text()) for f in self.files}
        self.functions = defaultdict(list)   # name -> [(file, FunctionDef)]
        self.calls = defaultdict(list)       # callee name -> [(file, enclosing fn or None, Call)]
        self.toplevel = set()                # id(FunctionDef) defined at module level
        self.parent = {}                     # id(FunctionDef) -> enclosing FunctionDef or None
        self.owner = {}                      # id(node) -> (file, enclosing FunctionDef or None)
        self.constants = {}                  # module-level NAME = tuple/set/list/frozenset of str
        for f, tree in self.trees.items():
            for node in tree.body:
                if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
                    items = self._str_collection(node.value)
                    if items is not None:
                        self.constants[node.targets[0].id] = items
            for node in tree.body:
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    self.toplevel.add(id(node))
            self._walk(f, tree, None)
        self.producers = self._producers()
        self.consumers = self._consumers()

    @staticmethod
    def _str_collection(value):
        if isinstance(value, ast.Call) and _name(value.func) in ('frozenset', 'set', 'tuple') and value.args:
            value = value.args[0]
        if isinstance(value, (ast.Tuple, ast.List, ast.Set)) and value.elts and all(
                isinstance(e, ast.Constant) and isinstance(e.value, str) for e in value.elts):
            return [e.value for e in value.elts]
        return None

    def _walk(self, f, node, fn):
        self.owner[id(node)] = (f, fn)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            self.functions[node.name].append((f, node))
            self.parent[id(node)] = fn
            fn = node
        if isinstance(node, ast.Call) and _name(node.func):
            self.calls[_name(node.func)].append((f, fn, node))
        for child in ast.iter_child_nodes(node):
            self._walk(f, child, fn)

    def _within(self, fn, scope):
        """True if fn is scope or nested inside it."""
        while fn is not None:
            if fn is scope:
                return True
            fn = self.parent.get(id(fn))
        return False

    def _in_scope(self, fn, cf, cfn, call):
        """A call reaches fn only by bare name from fn's defining scope (nested defs are visible only
        inside their parent), or, for module-level fn, also as module-alias attribute calls."""
        own_file = self.owner[id(fn)][0]
        if isinstance(call.func, ast.Name):
            if cf != own_file:
                return False
            parent = self.parent.get(id(fn))
            return parent is None or self._within(cfn, parent)
        return (id(fn) in self.toplevel and isinstance(call.func, ast.Attribute)
                and isinstance(call.func.value, ast.Name) and call.func.value.id in MODULE_ALIASES)

    def _local_values(self, fn, name):
        """Values a local name can hold inside fn: every `name = expr`, plus the matching column of a
        for-loop over a literal tuple of tuples. None if neither applies."""
        if name in [a.arg for a in fn.args.posonlyargs + fn.args.args + fn.args.kwonlyargs]:
            return None
        assigns = [n.value for n in ast.walk(fn) if isinstance(n, ast.Assign) and len(n.targets) == 1
                   and isinstance(n.targets[0], ast.Name) and n.targets[0].id == name]
        loops = []
        for n in ast.walk(fn):
            if isinstance(n, ast.For) and isinstance(n.target, ast.Tuple) and isinstance(n.iter, (ast.Tuple, ast.List)):
                names = [t.id if isinstance(t, ast.Name) else None for t in n.target.elts]
                if name in names:
                    i = names.index(name)
                    loops.extend(row.elts[i] for row in n.iter.elts
                                 if isinstance(row, (ast.Tuple, ast.List)) and len(row.elts) > i)
        # Every value the name can be bound to (an over-approximation: each must be producible).
        return assigns + loops or None

    @staticmethod
    def _param(fn, expr):
        """(index, name) if expr is a bare parameter of fn."""
        if fn is None or not isinstance(expr, ast.Name):
            return None
        params = [a.arg for a in fn.args.posonlyargs + fn.args.args + fn.args.kwonlyargs]
        return (params.index(expr.id), expr.id) if expr.id in params else None

    def _resolve(self, f, fn, expr, seen):
        """Yield ('literal'|'prefix'|'opaque', value, (file, line)) for a name-valued expression."""
        site = (f, getattr(expr, 'lineno', 0))
        if isinstance(expr, ast.Constant) and isinstance(expr.value, str):
            yield 'literal', expr.value, site
            return
        prefix = _prefix(expr)
        if prefix is not None:
            yield 'prefix', prefix, site
            return
        if isinstance(expr, ast.Name) and expr.id in self.constants:
            for item in self.constants[expr.id]:
                yield 'literal', item, site
            return
        if isinstance(expr, (ast.Tuple, ast.List, ast.Set)):
            items = self._str_collection(expr)
            if items is not None:
                for item in items:
                    yield 'literal', item, site
                return
        if isinstance(expr, ast.Name) and fn is not None:
            bound = self._local_values(fn, expr.id)
            if bound is not None:
                for value in bound:
                    yield from self._resolve(f, fn, value, seen)
                return
        param = self._param(fn, expr)
        if param is not None and (fn.name, param) not in seen:
            seen = seen | {(fn.name, param)}
            # Callers of fn: bare-name calls in fn's own file; for a module-level fn also
            # module-alias calls (a.need, u.call, ...) from any file. Never method calls on
            # values (set.add, list.append), which only share the name.
            callers = [(cf, cfn, call) for cf, cfn, call in self.calls.get(fn.name, [])
                       if self._in_scope(fn, cf, cfn, call)]
            for cf, cfn, call in callers:
                arg = _call_arg(call, param[0] - (1 if fn.args.args and fn.args.args[0].arg in ('self', 'cls') else 0),
                                param[1])
                if arg is not None:
                    yield from self._resolve(cf, cfn, arg, seen)
            if not callers:
                yield 'opaque', ast.unparse(expr), site
            return
        yield 'opaque', ast.unparse(expr), site

    def _producers(self):
        out = []
        for f, tree in self.trees.items():
            for node in ast.walk(tree):
                if isinstance(node, ast.Call):
                    arg = _producer_arg(node)
                    if arg == 'skip':
                        continue
                    _, fn = self.owner[id(node)]
                    if fn is not None and fn.name in CORE_HELPERS:
                        continue  # the helpers' own raise sites forward their callers' names
                    if arg is None:
                        out.append(('missing', None, (f, node.lineno)))
                    else:
                        out.extend(self._resolve(f, fn, arg, frozenset()))
        return out

    def _gate_valued(self, expr, fn):
        if isinstance(expr, ast.Subscript) and isinstance(expr.slice, ast.Constant) and expr.slice.value == 'gate':
            return True
        if (isinstance(expr, ast.Call) and _name(expr.func) == 'get' and expr.args
                and isinstance(expr.args[0], ast.Constant) and expr.args[0].value == 'gate'):
            return True
        if isinstance(expr, ast.Name) and fn is not None:
            for node in ast.walk(fn):
                if (isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == expr.id for t in node.targets)
                        and self._gate_valued(node.value, None)):
                    return True
        return False

    def _consumers(self):
        out = []
        for f, tree in self.trees.items():
            for node in ast.walk(tree):
                _, fn = self.owner[id(node)]
                sides = []
                if isinstance(node, ast.Compare) and len(node.comparators) == 1:
                    left, right = node.left, node.comparators[0]
                    if self._gate_valued(left, fn) and not self._gate_valued(right, fn):
                        sides.append(right)
                    elif self._gate_valued(right, fn) and not self._gate_valued(left, fn):
                        sides.append(left)
                elif isinstance(node, ast.Call) and _name(node.func) == 'need' and len(node.args) >= 3:
                    observed, expected = node.args[1], node.args[2]
                    if self._gate_valued(observed, fn) and not self._gate_valued(expected, fn):
                        sides.append(expected)
                    elif self._gate_valued(expected, fn) and not self._gate_valued(observed, fn):
                        sides.append(observed)
                    elif self._gate_valued(observed, fn) and self._gate_valued(expected, fn):
                        out.append(('opaque', ast.unparse(node), (f, node.lineno)))
                for side in sides:
                    out.extend(self._resolve(f, fn, side, frozenset()))
        return out

    def producer_names(self):
        literals = {v for k, v, _ in self.producers if k == 'literal'}
        prefixes = {v for k, v, _ in self.producers if k == 'prefix'}
        return literals, prefixes

    def unproducible(self):
        """Consumer literals/prefixes that no producer can emit exactly."""
        literals, prefixes = self.producer_names()
        bad = []
        for kind, value, site in self.consumers:
            if kind == 'literal':
                ok = value in literals or any(value.startswith(p) and len(value) > len(p) for p in prefixes)
            elif kind == 'prefix':
                ok = value in prefixes
            else:
                continue
            if not ok:
                bad.append((kind, value, site))
        return bad

    def uses(self):
        """Every use of a caught gate name, classified as ('consumer'|'passthrough'|'reraise'|'unsupported', file, line, src).

        consumer:    a comparison or need() handled by _consumers().
        passthrough: the name is carried on without being matched (string concatenation into a message,
                     a dict value, a dict()/Gate() argument other than Gate's name, a plain assignment, or
                     trusted_gate(), which checks the name's shape for redaction, not its value).
        reraise:     Gate(caught_name, ...), re-raising under the same name (adds no name).
        unsupported: anything else (d[gate], d.get(gate), gate.startswith(...), match, a call into an
                     unknown helper, ...); the scan cannot check it, so it must fail, not skip.
        """
        out = []
        for f, tree in self.trees.items():
            parent = {}
            for node in ast.walk(tree):
                for child in ast.iter_child_nodes(node):
                    parent[id(child)] = node
            for node in ast.walk(tree):
                _, fn = self.owner[id(node)]
                if isinstance(node, (ast.Subscript, ast.Call)):
                    caught = self._gate_valued(node, None)
                elif isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
                    caught = self._gate_valued(node, fn)
                else:
                    caught = False
                if not caught:
                    continue
                p = parent.get(id(node))
                kind = 'unsupported'
                if isinstance(p, ast.Compare) and len(p.comparators) == 1:
                    kind = 'consumer'
                elif isinstance(p, ast.Call) and _name(p.func) == 'need' and node in p.args[1:3]:
                    kind = 'consumer'
                elif isinstance(p, ast.BinOp) and isinstance(p.op, ast.Add):
                    kind = 'passthrough'
                elif isinstance(p, ast.Dict) and node in p.values:
                    kind = 'passthrough'
                elif isinstance(p, ast.Assign) and p.value is node:
                    kind = 'passthrough'
                elif isinstance(p, ast.Call) and _name(p.func) in PASSTHROUGH_CALLS and node in p.args \
                        and not (_name(p.func) == 'Gate' and p.args and p.args[0] is node):
                    kind = 'passthrough'
                elif isinstance(p, ast.Call) and _name(p.func) == 'Gate' and p.args and p.args[0] is node:
                    kind = 'reraise'  # Gate(caught_name, ...): re-raises under the same name, adds none
                elif isinstance(p, ast.keyword) and isinstance(parent.get(id(p)), ast.Call) \
                        and _name(parent[id(p)].func) in PASSTHROUGH_CALLS:
                    kind = 'passthrough'
                out.append((kind, f, node.lineno, ast.unparse(p) if p is not None else ast.unparse(node)))
        return out


# Calls that carry a caught gate name on without matching it (see Scan.uses).
PASSTHROUGH_CALLS = {'Gate', 'trusted_gate', 'dict'}

# ---- frozen PR-2 records ---------------------------------------------------------------------------
# These helpers import nothing from the executors (which shell out to cast at import time), so the
# hygiene test can run before Foundry is installed.
RENAMES_FILE = 'script/upgrade/gate_renames_pr2.json'
RENAMED_COUNT = 77
REPLACED_FILE = 'script/upgrade/gate_names_replaced_pr2.json'
REPLACED_BASE = '4029a23e64744066d99c5d81d71bd39eedee7f5e'


def defining_functions(source, name):
    """Dotted names of the functions in which the string literal `name` occurs ('<module>' at top level)."""
    owner = set()
    def walk(node, fn):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            fn = node.name if fn is None else fn+'.'+node.name
        if isinstance(node, ast.Constant) and node.value == name:
            owner.add(fn or '<module>')
        for child in ast.iter_child_nodes(node):
            walk(child, fn)
    walk(ast.parse(source), None)
    return owner


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def generate_replaced(root=ROOT, base=REPLACED_BASE):
    """The REPLACED_FILE content: names raised at `base` but not at the working tree, by this scanner."""
    root = Path(root)
    with tempfile.TemporaryDirectory() as tmp:
        archive = subprocess.run(['git', 'archive', base, 'script'], cwd=root, capture_output=True, check=True).stdout
        subprocess.run(['tar', '-x', '-C', tmp], input=archive, check=True)
        old, new = Scan(root=tmp), Scan(root=root)
    lits = lambda s: {v for k, v, _ in s.producers if k == 'literal'}
    pres = lambda s: {v for k, v, _ in s.producers if k == 'prefix'}
    return dict(base=base, literals=sorted(lits(old)-lits(new)), prefixes=sorted(pres(old)-pres(new)),
                generated='literals and prefixes raised (need/Gate/typed/exact_keys, through forwarding) at the '
                          'base but not at the PR-2 head, by gate_name_scan.generate_replaced()')


if __name__ == '__main__':
    import sys
    if sys.argv[1:] == ['--write-replaced']:
        (ROOT/REPLACED_FILE).write_text(json.dumps(generate_replaced(), indent=1)+'\n')
        print('wrote', REPLACED_FILE)
    else:
        raise SystemExit('usage: gate_name_scan.py --write-replaced')
