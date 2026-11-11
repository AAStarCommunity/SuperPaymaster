"""Extract scaled floor measurements; ratio = minimum margin / maximum spread.

Repeat --log to union logs for the labelled engine. Rams crossings are synthetic
callback guard crossings, not settlement exhaustion. Unscaled floor checks are
admission-censored and excluded from the scaled crossing comparison.
"""
import argparse
import json
import re
import sys
from pathlib import Path

LABELS = {'SETTLE': 'settle', 'CREDIT': 'credit', 'scaled minimum minPost': 'min_post',
          'real guard crossing': 'crossing', 'scaled margin': 'margin'}


def extract(logs, engine):
    rows, forks = {}, {}
    for log in logs:
        fields, suite, active, fork_settle = {}, False, False, None
        for line in log.splitlines():
            line = line.strip()
            if line == 'Failing tests:':
                break
            if line.startswith('Ran ') and ' tests' in line and ' for ' in line:
                suite = 'contracts/test/measure/AmsterdamHandleOpsFloor.t.sol:AmsterdamHandleOpsFloorTest' in line
                active, fields = False, {}
            if line.startswith(('[PASS', '[FAIL', '[SKIP')):
                if fields:
                    raise ValueError('incomplete scaled measurement')
                active = suite and line.startswith('[PASS]') and 'test_handleOps_scaled_' in line
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
            if fields['margin'] != fields['min_post'] - fields['crossing']:
                raise ValueError('margin does not equal min_post - crossing')
            identity = (fields['settle'], 'credit' if fields['credit'] else 'balance')
            row = {k: fields[k] for k in ('min_post', 'crossing', 'margin')}
            if identity in rows and rows[identity] != row:
                raise ValueError('conflicting workload measurements')
            rows[identity], fields = row, {}
        if fields:
            raise ValueError('incomplete scaled measurement')
    if not rows:
        raise ValueError('no passing scaled floor measurements found')
    groups = []
    for settle in sorted({s for s, _ in rows}):
        workloads = {w: row for (s, w), row in sorted(rows.items()) if s == settle}
        crossings = [r['crossing'] for r in workloads.values()]
        group = dict(settle=settle, workloads=workloads,
                     crossing_spread=max(crossings) - min(crossings))
        if settle in forks:
            group['rams_synthetic_crossing'] = forks[settle]
            group['fork_minus_fixture_crossing'] = {w: forks[settle] - r['crossing'] for w, r in workloads.items()}
        groups.append(group)
    minimum = min(r['margin'] for r in rows.values())
    spread = max(g['crossing_spread'] for g in groups)
    return dict(engine=engine, bisection_resolution_gas=1,
                bracket='adjacent failing/settling gas values: crossing - 1 fails; crossing settles',
                measurements=groups, unmatched_rams_settles=sorted(set(forks) - {g['settle'] for g in groups}),
                summary=dict(min_margin=minimum, max_observed_spread=spread,
                             ratio=minimum / spread if spread else None,
                             ratio_definition='min_margin / max_observed_spread; null when spread is zero'))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--engine', required=True)
    p.add_argument('--log', action='append', required=True)
    p.add_argument('--out-json', required=True)
    a = p.parse_args(argv)
    try:
        report = extract([Path(f).read_text() for f in a.log], a.engine)
        Path(a.out_json).write_text(json.dumps(report, indent=2) + '\n')
        return 0
    except (ValueError, OSError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
