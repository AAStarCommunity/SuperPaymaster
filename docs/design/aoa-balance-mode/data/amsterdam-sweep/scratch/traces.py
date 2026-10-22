import re, sys, json, statistics as st
FN = r'(SuperPaymaster|xPNTsTokenV2)::(validatePaymasterUserOp|postOp|tryLockForGas|settleLocked|tryReserveCredit|settleCredit)\('
def parse(path):
    out = {}; suite = None; test = None
    rx = re.compile(r'^\s*[│├└─\s]*\[(\d+)\] ' + FN)
    for line in open(path, errors='replace'):
        if line.startswith('Ran '):
            m = re.match(r'^Ran \d+ tests? for (\S+)', line)
            if m: suite = m.group(1)
            continue
        m = re.match(r'^\[(PASS|FAIL)[^\]]*\] (\w+)', line)
        if m: test = (suite, m.group(2), m.group(1)); out.setdefault(test, []); continue
        if test and '[delegatecall]' in line[:400] or (test and 'SuperPaymaster::' in line[:200]):
            m = rx.match(line)
            if m: out[test].append((m.group(2) + '::' + m.group(3), int(m.group(1)), 'revert' in line[-60:]))
    return out
p = parse(sys.argv[1]); a = parse(sys.argv[2])
pk = {(s, t): v for (s, t, r), v in p.items() if r == 'PASS'}
ak = {(s, t): v for (s, t, r), v in a.items() if r == 'PASS'}
both = sorted(set(pk) & set(ak))
agg = {}
for k in both:
    P, A = pk[k], ak[k]
    if [x[0] for x in P] != [x[0] for x in A]: continue  # call sequence differs -> not comparable
    for (f, gp, _), (_, ga, _) in zip(P, A):
        agg.setdefault(f, []).append((gp, ga))
print(f"tests passing under both: {len(both)}")
print("| function (implementation frame) | samples | Prague min / median / max | Amsterdam min / median / max | ratio of medians | paired ratio min..max |")
print("|---|---|---|---|---|---|")
for f in sorted(agg):
    v = agg[f]; gp = [x[0] for x in v]; ga = [x[1] for x in v]; r = [b / a for a, b in v if a]
    print(f"| `{f}` | {len(v)} | {min(gp):,} / {int(st.median(gp)):,} / {max(gp):,} | {min(ga):,} / {int(st.median(ga)):,} / {max(ga):,} | {st.median(ga)/st.median(gp):.2f}x | {min(r):.2f}x..{max(r):.2f}x |")
