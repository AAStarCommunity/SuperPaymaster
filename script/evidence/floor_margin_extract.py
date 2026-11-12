"""Extract scaled floor measurements; ratio = minimum margin / maximum spread.

Trust boundary: trust the local git checkout, pinned binaries and tool. This
offline parser accepts caller assertions, not release provenance. Evidence writers
who also recompute hashes are out of scope; reviewers rerun the execution tool.

Repeat --log to union logs for the labelled engine. Rams crossings are synthetic
callback guard crossings, not settlement exhaustion. Unscaled floor checks are
admission-censored and excluded from the scaled crossing comparison.
"""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

LABELS = {'SETTLE': 'settle', 'CREDIT': 'credit', 'scaled minimum minPost': 'min_post',
          'real guard crossing': 'crossing', 'scaled margin': 'margin'}


def extract(logs, engine, head, engine_version, argv):
    if not re.fullmatch(r'[0-9a-fA-F]{40}', head) or not engine_version.strip() or not argv.strip():
        raise ValueError('head, engine version and argv are required')
    rows, forks, variance = {}, {}, {}
    seen_suite = False
    for log in logs:
        fields, suite, active, fork_settle = {}, False, False, None
        suite_ok = False
        variance_active = False
        vf = {}
        for line in log.splitlines():
            line = line.strip()
            if line == 'Failing tests:':
                break
            if line.startswith('Ran ') and ' tests' in line and ' for ' in line:
                if suite and not suite_ok:
                    raise ValueError('floor suite lacks passing summary')
                suite_ok = False
                if fields or vf:
                    raise ValueError('incomplete measurement')
                suite = bool(re.fullmatch(r'Ran \d+ tests? for contracts/test/measure/AmsterdamHandleOpsFloor\.t\.sol:AmsterdamHandleOpsFloorTest', line))
                variance_active = False
                active, fields = False, {}
                seen_suite |= suite
            if suite and line.startswith('Suite result:'):
                if not re.match(r'Suite result: ok\. \d+ passed; 0 failed; 0 skipped;', line):
                    raise ValueError('floor suite failed or skipped')
                if fields or vf:
                    raise ValueError('incomplete measurement')
                suite_ok = True
                active = variance_active = False
            if suite and line.startswith(('[FAIL', '[SKIP')):
                raise ValueError('floor suite failed or skipped')
            if line.startswith(('[PASS', '[FAIL', '[SKIP')):
                if fields:
                    raise ValueError('incomplete scaled measurement')
                active = suite and line.startswith('[PASS]') and 'test_handleOps_scaled_' in line
                variance_active = suite and line.startswith('[PASS]') and 'test_variance_' in line
                if vf:
                    raise ValueError('incomplete variance measurement')
            match = re.fullmatch(r'Analysis SETTLE: (\d+)', line)
            if match:
                fork_settle = int(match[1])
            match = re.fullmatch(r'Synthetic callback guard crossing \(not settlement exhaustion\): (\d+)', line)
            if match:
                if fork_settle is None:
                    raise ValueError('Rams crossing without Analysis SETTLE')
                value = int(match[1])
                if fork_settle in forks and forks[fork_settle] != value:
                    raise ValueError('conflicting Rams crossings')
                forks[fork_settle] = value
            match = re.fullmatch(r'(.+): (-?\d+)', line)
            if variance_active and match and match[1].startswith('variance '):
                key = match[1].removeprefix('variance ')
                if key in vf:
                    raise ValueError('duplicate variance label')
                vf[key] = int(match[2])
                if key == 'crossing':
                    if set(vf) != {'SETTLE', 'variant', 'position', 'minimum', 'crossing'}:
                        raise ValueError('incomplete variance measurement')
                    identity = (vf['SETTLE'], vf['variant'], vf['position'])
                    if vf['minimum'] != max(500000, vf['SETTLE'] + vf['SETTLE']//63 + 20000) or not 0 < vf['crossing'] <= vf['minimum']:
                        raise ValueError('invalid variance floor or crossing')
                    if identity in variance and variance[identity] != vf:
                        raise ValueError('conflicting variance measurements')
                    variance[identity], vf = vf, {}
            if not active or not match or match[1] not in LABELS:
                continue
            key = LABELS[match[1]]
            if key in fields:
                raise ValueError('duplicate measurement label')
            fields[key] = int(match[2])
            if key != 'margin':
                continue
            if set(fields) != set(LABELS.values()) or fields['credit'] not in (0, 1):
                raise ValueError('incomplete or invalid scaled measurement')
            if fields['min_post'] != max(500000, fields['settle'] + fields['settle']//63 + 20000):
                raise ValueError('wrong min_post')
            if fields['crossing'] <= 0 or fields['margin'] < 0:
                raise ValueError('invalid crossing or negative margin')
            if fields['margin'] != fields['min_post'] - fields['crossing']:
                raise ValueError('margin does not equal min_post - crossing')
            identity = (fields['settle'], 'credit' if fields['credit'] else 'balance')
            row = {k: fields[k] for k in ('min_post', 'crossing', 'margin')}
            if identity in rows and rows[identity] != row:
                raise ValueError('conflicting workload measurements')
            rows[identity], fields = row, {}
            active = False
        if suite and not suite_ok:
            raise ValueError('floor suite lacks passing summary')
        if fields or vf:
            raise ValueError('incomplete measurement')
    if not seen_suite:
        raise ValueError('missing floor suite header')
    if set(rows) != {(s, w) for s in (450000, 600000, 1000000) for w in ('balance', 'credit')}:
        raise ValueError('incomplete or unexpected scaled matrix')
    if set(variance) != {(s, v, p) for s in (450000, 600000) for v in range(5) for p in (range(3) if v == 0 else [0])}:
        raise ValueError('incomplete variance matrix')
    groups = []
    for settle in sorted({s for s, _ in rows}):
        workloads = {w: row for (s, w), row in sorted(rows.items()) if s == settle}
        crossings = [r['crossing'] for r in workloads.values()]
        crossings += [v['crossing'] for v in variance.values() if v['SETTLE'] == settle]
        group = dict(settle=settle, workloads=workloads,
                     crossing_spread=max(crossings) - min(crossings))
        if settle in forks:
            group['rams_synthetic_crossing'] = forks[settle]
            group['fork_minus_fixture_crossing'] = {w: forks[settle] - r['crossing'] for w, r in workloads.items()}
        groups.append(group)
    minimum = min(r['margin'] for r in rows.values())
    positions = [dict(settle=s, crossings={str(p): variance[s, 0, p]['crossing'] for p in range(3)},
                      spread=max(variance[s, 0, p]['crossing'] for p in range(3)) - min(variance[s, 0, p]['crossing'] for p in range(3)))
                 for s in (450000, 600000)]
    minimum = min(minimum, *(v['minimum'] - v['crossing'] for v in variance.values()))
    spread = max(g['crossing_spread'] for g in groups)
    return dict(provenance='caller-asserted', engine=engine, head=head, engine_version=engine_version, argv=argv,
                input_sha256=[hashlib.sha256(log.encode()).hexdigest() for log in logs],
                variance=list(variance.values()), position_spread=positions, bisection_resolution_gas=1,
                bracket='adjacent failing/settling gas values: crossing - 1 fails; crossing settles',
                measurements=groups, unmatched_rams_settles=sorted(set(forks) - {g['settle'] for g in groups}),
                summary=dict(min_margin=minimum, max_observed_spread=spread,
                             ratio=minimum / spread if spread else None,
                             ratio_definition='min_margin / max_observed_spread; null when spread is zero'))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--head', required=True)
    p.add_argument('--engine-version', required=True)
    p.add_argument('--argv', required=True)
    p.add_argument('--engine', required=True)
    p.add_argument('--log', action='append', required=True)
    p.add_argument('--out-json', required=True)
    a = p.parse_args(argv)
    try:
        report = extract([Path(f).read_text() for f in a.log], a.engine, a.head, a.engine_version, a.argv)
        report['inputs'] = [dict(path=f, sha256=hashlib.sha256(Path(f).read_bytes()).hexdigest()) for f in a.log]
        Path(a.out_json).write_text(json.dumps(report, indent=2) + '\n')
        print('caller-asserted: offline re-parse, not release evidence')
        return 0
    except (ValueError, OSError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
