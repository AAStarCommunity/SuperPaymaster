import importlib.util, os
H = os.path.dirname(os.path.abspath(__file__))


def _load(n):
    s = importlib.util.spec_from_file_location(n, os.path.join(H, n + ".py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


m1, m2 = _load("muts"), _load("muts2")
MUTATIONS = m1.MUTATIONS + [m for m in m2.MUTATIONS if not m["id"].endswith("__v2")]
