import sys; sys.path.insert(0, '/tmp/sweep')
from parse import parse
L = '/tmp/sweep/logs/'
def cls(reason):
    r = reason
    if 'AA33' in r: return 'EntryPoint AA33 (paymaster validation reverted/OOG)'
    if 'OutOfGas' in r or 'OOG' in r: return 'OOG'
    if 'NotLive' in r: return 'NotLive()'
    if r.startswith('FailedOp'): return 'EntryPoint FailedOp'
    if '!=' in r or '>' in r or '<' in r or 'assert' in r: return 'assertion'
    return 'revert/other'
def diff(a, b, na, nb):
    A, B = parse(L + a), parse(L + b)
    keys = sorted(set(A) | set(B))
    rows = []
    for k in keys:
        sa = A.get(k, ('—', '', '')); sb = B.get(k, ('—', '', ''))
        if sa[0] != sb[0]: rows.append((k, sa, sb))
    print(f"\n### {na} vs {nb}: {len(rows)} tests differ ({len(A)} vs {len(B)} result lines)\n")
    print(f"| # | suite | test | {na} | {nb} | class | failure reason ({nb if any(r[2][0]=='FAIL' for r in rows) else na}) |")
    print("|---|---|---|---|---|---|---|")
    for i, (k, sa, sb) in enumerate(rows, 1):
        suite, test = k.split('::')
        fr = sb[1] if sb[0] == 'FAIL' else sa[1]
        print(f"| {i} | `{suite.split('/')[-1]}` | `{test}` | {sa[0]} | {sb[0]} | {cls(fr) if fr else ''} | {fr.replace('|','/')[:220]} |")
diff('b_186_prague.log', 'c_186_amsterdam.log', '1.8.6 prague', '1.8.6 amsterdam')
diff('d_171_cancun.log', 'a_186_cancun.log', '1.7.1 cancun', '1.8.6 cancun')
diff('a_186_cancun.log', 'b_186_prague.log', '1.8.6 cancun', '1.8.6 prague')
