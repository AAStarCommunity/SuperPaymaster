#!/usr/bin/env python3
"""Summarise phase2/cells.jsonl: I9, guard changes, EntryPoint per-op actualGasUsed under RR vs R0, bundler gap.
Usage: python3 rr-matrix-analyze.py <phase2 dir> <out.json>"""
import gzip, json, os, statistics as st, sys
D, out = sys.argv[1], sys.argv[2]
src = D + '/cells.jsonl' if os.path.exists(D + '/cells.jsonl') else D + '/cells.jsonl.gz'
rows = [json.loads(l) for l in (gzip.open(src, 'rt') if src.endswith('.gz') else open(src))]
comp = json.load(open(D + '/comparisons.json'))
by = {}
for r in rows:
    by.setdefault(r['cell']['id'], {})[r['regime']['id']] = r
def opsum(r, k):
    return sum(int(o[k]) for o in r['perOp'] if o.get(k) is not None)
res = {'rows': len(rows), 'cells': len(by), 'I9AllTrue': all(r['I9'] for r in rows), 'perRegime': {}, 'epUndercountVsR0': {}}
for k in ('R0', 'RR30M', 'RRdelta'):
    rs = [r for r in rows if r['regime']['id'] == k]
    gap = [int(r['receiptGasUsed']) - opsum(r, 'actualGasUsed') for r in rs]
    tops = [o for r in rs for o in r['perOp'] if o.get('target')]
    g2 = [o['g2NoSubsidy'] for o in tops if o.get('g2NoSubsidy') is not None]
    cmb = [int(o['chargeMinusBareCost']) for o in tops if o.get('chargeMinusBareCost') is not None]
    ok = [r for r in rs if r['txStatus'] == '0x1']  # MIN-1 rows revert by design before reservation
    gok = [int(r['receiptGasUsed']) - opsum(r, 'actualGasUsed') for r in ok]
    g_steps = [o['gasleftAtFirstGuardGAS'] for r in rs for o in r['perOp'] if o.get('target') and isinstance(o.get('gasleftAtFirstGuardGAS'), dict)]
    guard = [s['gasleftReturned'] for s in g_steps]
    guard_res = [s['stateGasReservoir'] for s in g_steps]
    res['perRegime'][k] = {'rows': len(rs), 'txGasUsedMinusSumOpActualGasUsed': {'min': min(gap), 'median': int(st.median(gap)), 'max': max(gap)},
                           'successRows': len(ok), 'successOnlyGap': {'min': min(gok), 'median': int(st.median(gok)), 'max': max(gok),
                                                                      'positive': sum(1 for x in gok if x > 0)},
                           'gasleftAtGuard': {'min': min(guard), 'max': max(guard), 'n': len(guard), 'reservoirAtGuardMax': max(guard_res)} if guard else None,
                           'G2true': sum(1 for g in g2 if g is True), 'G2n': len(g2),
                           'chargeMinusBareCostNegative': sum(1 for x in cmb if x < 0), 'chargeMinusBareCostN': len(cmb)}
for k in ('RR30M', 'RRdelta'):
    d = []
    for cid, reg in by.items():
        if 'R0' in reg and k in reg and reg[k]['txStatus'] == '0x1' and reg['R0']['txStatus'] == '0x1' and reg[k]['cell']['scenario'] != 'state-demand':
            a0, a1 = opsum(reg['R0'], 'actualGasUsed'), opsum(reg[k], 'actualGasUsed')
            d.append((a1 - a0, a1 / a0))
    res['epUndercountVsR0'][k] = {'cells': len(d), 'deltaMin': min(x[0] for x in d), 'deltaMedian': int(st.median(x[0] for x in d)),
                                  'deltaMax': max(x[0] for x in d), 'ratioMin': round(min(x[1] for x in d), 4), 'ratioMedian': round(st.median(x[1] for x in d), 4)}
res['guardPassFailChanges'] = sum(1 for c in comp if isinstance(c, dict) and c.get('guardPassFailChanged')) if isinstance(comp, list) else comp
json.dump(res, open(out, 'w'), indent=1)
print(json.dumps(res, indent=1))
