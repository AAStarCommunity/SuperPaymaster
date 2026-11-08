"""Static, lexical, transitive gate-argument forwarding; never executes source."""
import ast


HELPERS = {'a.need': (0, 'gate'), 'a.Gate': (0, 'gate'),
           'a.exact_keys': (0, 'gate'), 'a.typed': (2, 'gate')}


def argument(call, index, name):
    return next((k.value for k in call.keywords if k.arg == name),
                call.args[index] if len(call.args) > index else None)


def record_forwarding(call):
    if ast.unparse(call.func) != 'a.Gate' or len(call.args) != 3:
        return False
    values = call.args
    return (all(isinstance(v, ast.Subscript) and isinstance(v.slice, ast.Constant) for v in values)
            and [v.slice.value for v in values] == ['gate', 'observed', 'expected']
            and len({ast.dump(v.value) for v in values}) == 1)


class Flow:
    def __init__(self, tree, *, historical=False):
        self.historical = historical
        self.parent, self.owner, self.functions, self.calls = {}, {}, {}, []
        def walk(node, scope):
            self.owner[node] = scope
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                self.functions.setdefault(scope, {})[node.name] = node
                self.parent[node] = scope
                scope = node
            if isinstance(node, ast.Call):
                self.calls.append((scope, node))
            for child in ast.iter_child_nodes(node):
                walk(child, scope)
        walk(tree, None)
        self.aliases = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign) and ast.unparse(node.value) in HELPERS:
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        key = (self.owner[node], target.id)
                        bindings = [n for n in ast.walk(tree) if isinstance(n, ast.Name)
                                    and isinstance(n.ctx, ast.Store) and n.id == target.id
                                    and self.owner[n] is self.owner[node]]
                        if len(bindings) != 1:
                            raise ValueError('unsupported ambiguous helper alias: ' + target.id)
                        self.aliases[key] = ast.unparse(node.value)
        parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}
        for node in ast.walk(tree):
            if isinstance(node, ast.Attribute) and ast.unparse(node) in HELPERS and ast.unparse(node) != 'a.Gate':
                parent = parents.get(node)
                direct_call = isinstance(parent, ast.Call) and parent.func is node
                simple_alias = (isinstance(parent, ast.Assign) and parent.value is node
                                and all(isinstance(t, ast.Name) for t in parent.targets))
                if not direct_call and not simple_alias:
                    raise ValueError('unsupported helper binding at line ' + str(node.lineno))
        for node in ast.walk(tree):
            if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
                scope = self.owner[node]
                while True:
                    if (scope, node.id) in self.aliases:
                        parent = parents.get(node)
                        if not isinstance(parent, ast.Call) or parent.func is not node:
                            raise ValueError('unsupported helper alias escape: ' + node.id)
                        break
                    if scope is None:
                        break
                    scope = self.parent[scope]
        self.rules = {fn: set() for scope in self.functions.values() for fn in scope.values()}
        changed = True
        rounds = 0
        while changed:
            rounds += 1
            if rounds > len(self.rules) + 2:
                raise ValueError("cyclic gate suffix forwarding has no finite expansion")
            changed = False
            for scope, call in self.calls:
                if scope is None:
                    continue
                params = [p.arg for p in scope.args.posonlyargs + scope.args.args + scope.args.kwonlyargs]
                for value, suffix, origin in self.positions(scope, call):
                    base, tail = self.split(value)
                    if isinstance(base, ast.Name) and base.id in params:
                        rule = (params.index(base.id), base.id, tail + suffix, origin)
                        if rule not in self.rules[scope]:
                            self.rules[scope].add(rule)
                            changed = True

    @staticmethod
    def split(value):
        suffix = ''
        while (isinstance(value, ast.BinOp) and isinstance(value.op, ast.Add)
               and isinstance(value.right, ast.Constant) and isinstance(value.right.value, str)):
            suffix = value.right.value + suffix
            value = value.left
        return value, suffix

    def resolve(self, scope, name):
        while True:
            if name in self.functions.get(scope, {}):
                return self.functions[scope][name]
            if scope is None:
                return None
            scope = self.parent[scope]

    def positions(self, scope, call):
        helper = ast.unparse(call.func)
        if isinstance(call.func, ast.Name):
            enclosing = scope
            while True:
                if (enclosing, helper) in self.aliases:
                    helper = self.aliases[enclosing, helper]
                    break
                if enclosing is None:
                    break
                enclosing = self.parent[enclosing]
        if helper in HELPERS:
            index, name = HELPERS[helper]
            value = argument(call, index, name)
            if value is None and helper == 'a.typed' and self.historical:
                return
            if value is None:
                raise ValueError('unsupported helper argument binding at line ' + str(call.lineno))
            if not record_forwarding(call):
                yield value, '', (call.lineno, call.col_offset)
        elif isinstance(call.func, ast.Name):
            fn = self.resolve(scope, call.func.id)
            for index, name, suffix, origin in sorted(self.rules.get(fn, ())):
                positional = fn.args.posonlyargs + fn.args.args
                value = argument(call, index, name) if index < len(positional) else next((k.value for k in call.keywords if k.arg == name), None)
                if value is None:
                    positional = fn.args.posonlyargs + fn.args.args
                    defaults = dict(zip([p.arg for p in positional[-len(fn.args.defaults):]], fn.args.defaults))
                    defaults.update({p.arg: v for p, v in zip(fn.args.kwonlyargs, fn.args.kw_defaults) if v is not None})
                    value = defaults.get(name)
                if value is None or any(isinstance(v, ast.Starred) for v in call.args) or any(k.arg is None for k in call.keywords):
                    raise ValueError('unsupported gate argument binding at line ' + str(call.lineno))
                yield value, suffix, origin

    def label_only(self, fn, name, visiting=frozenset()):
        """Prove that a forwarded parameter has no non-label consumers."""
        key = (fn, name)
        if key in visiting:
            return False
        permitted = set()
        for scope, call in self.calls:
            if scope is not fn:
                continue
            target = self.resolve(scope, call.func.id) if isinstance(call.func, ast.Name) else None
            if target is not None and any(not self.label_only(target, rule[1], visiting | {key})
                                          for rule in self.rules[target]):
                continue
            for value, _, _ in self.positions(scope, call):
                base, _ = self.split(value)
                if isinstance(base, ast.Name):
                    permitted.add(id(base))
        uses = [n for n in ast.walk(fn) if isinstance(n, ast.Name) and n.id == name
                and isinstance(n.ctx, ast.Load)]
        writes = [n for n in ast.walk(fn) if isinstance(n, ast.Name) and n.id == name
                  and isinstance(n.ctx, ast.Store)]
        return bool(uses) and not writes and all(id(n) in permitted for n in uses)

    def sites(self, expand=False):
        for scope, call in self.calls:
            params = {p.arg for p in scope.args.posonlyargs + scope.args.args + scope.args.kwonlyargs} if scope else set()
            for value, suffix, origin in self.positions(scope, call):
                base, tail = self.split(value)
                # The definition belongs to each caller, not the forwarding body.
                if expand and isinstance(base, ast.Name) and base.id in params:
                    continue
                if expand and suffix:
                    value = ast.copy_location(ast.BinOp(left=value, op=ast.Add(), right=ast.Constant(suffix)), value)
                if expand:
                    base, tail = self.split(value)
                    if isinstance(base, ast.Constant) and isinstance(base.value, str):
                        value = ast.copy_location(ast.Constant(base.value + tail), value)
                call.gate_primitive_line, call.gate_primitive_column = origin
                yield scope.name if scope else '<module>', call, value
