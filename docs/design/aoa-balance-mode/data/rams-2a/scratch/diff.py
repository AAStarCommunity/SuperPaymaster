import sys; sys.path.insert(0, '/tmp/rams/tools')
from parse import parse
def load(spec):
    # 'main.log+rerun.log': results of the rerun override the main log (environment-artefact reruns)
    parts = spec.split('+'); r = parse(parts[0])
    for p in parts[1:]:
        rr = parse(p); suites = {k.split('::')[0] for k in rr}
        r = {k: v for k, v in r.items() if k.split('::')[0] not in suites}
        r.update(rr)
    return r
def cls(reason):
    r = reason
    if 'AA33' in r: return 'EntryPoint AA33 (paymaster validation reverted/OOG)'
    if 'OutOfGas' in r or 'OOG' in r or 'no OOG band' in r or 'no-OOG' in r: return 'OOG / no-OOG band'
    if 'vm.readFile' in r or 'artifact' in r: return 'environment (reads ./out)'
    if 'NotLive' in r: return 'NotLive()'
    if r.startswith('FailedOp'): return 'EntryPoint FailedOp'
    if '!=' in r or '>' in r or '<' in r or 'assert' in r: return 'assertion'
    return 'revert/other'
def diff(a, b, na, nb):
    A, B = load(a), load(b)
    keys = sorted(set(A) | set(B))
    rows = [(k, A.get(k, ('—','','')), B.get(k, ('—','',''))) for k in keys if A.get(k, ('—',))[0] != B.get(k, ('—',))[0]]
    print(f"\n### {na} vs {nb}: {len(rows)} tests differ ({len(A)} vs {len(B)} result lines)\n")
    print(f"| # | suite | test | {na} | {nb} | class | failure reason |")
    print("|---|---|---|---|---|---|---|")
    for i, (k, sa, sb) in enumerate(rows, 1):
        suite, test = k.split('::')
        fr = sb[1] if sb[0] == 'FAIL' else sa[1]
        print(f"| {i} | `{suite.split('/')[-1]}` | `{test}` | {sa[0]} | {sb[0]} | {cls(fr) if fr else ''} | {fr.replace('|','/')[:200]} |")
    return rows
if __name__ == '__main__':
    for spec in sys.argv[1:]:
        a, b, na, nb = spec.split(',')
        diff(a, b, na, nb)
