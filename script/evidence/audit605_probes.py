#!/usr/bin/env python3
"""Gate-removal acceptance for the #605 audit fixes (DSR rulings 2026-11-05; offline only).

Selects every a.need statement for the named gates (F-01..F-04, #606 L1 closing gates, F-05 list) and every
statement in the Q3 control functions, from probe_gate_removal.py --list on the current source, and runs
probe_gate_removal.py --site LINE --failfast for each. PASS only if every selected statement is `killed`
with zero errors (a kill must be an assertion failure), every named gate was found, and the source is clean.

Repository root: A3A_ENGINE_DIR=$HOME/.foundry/bin python3 -B script/evidence/audit605_probes.py [--jobs 3]
"""
import sys
sys.dont_write_bytecode = True
import argparse
import concurrent.futures
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROBE = ROOT/'script/upgrade/audit/probe_gate_removal.py'
GATES = {
    'F-01': ['sampled_deployer_only'], 'F-02': ["'budget_' + label"], 'F-03': ['pin_pending_token_eta'],
    'F-04': ['old_aggregator_slash_policy_admin'],
    'L1': ['closing_registry_pointer', 'closing_dvt_pointer', 'closing_committee_pointer', 'closing_dvt_activity',
           'closing_stale_unexecuted'],
    'F-05': ['sender_nonce', 'pending_nonce', 'safe_nonce', 'safe_state', 'dvt_activity_unchanged', 'SP_owner',
             'pending_token', 'pending_token_eta', 'onchain_safe_hash', 'fresh_estimate', 'block_gas_limit',
             'post_nonce', 'post_safe_nonce', 'manifest_receipt_gas', 'steps_complete', 'controls_complete',
             'post_swap_tracked', 'post_swap_revenue', 'post_swap_capped_balance', 'post_swap_solvency',
             'B4_nonce_consumed', 'B4_safe_nonce', 'old_aggregator_owner', 'anni_eoa', 'stake_not_unlocking',
             'independent_pin', 'simulation_pin', 'pin_recheck', 'old_pointer', 'pointer_owner'],
}
Q3_FUNCTIONS = ('b4_controls', 'unbacked_swap_control', 'mint_trace')


def probe(row):
    line, function, gate = row
    out = subprocess.run([sys.executable, '-B', str(PROBE), '--site', str(line), '--failfast'],
                         cwd=ROOT, capture_output=True, text=True).stdout
    result = re.search(r'^PROBE_RESULT (\w+) ran (\d+) failures (\d+) errors (\d+)', out, re.M)
    first = re.search(r'^FIRST_FAILING_TEST (\S+)', out, re.M)
    status, errors = (result.group(1), int(result.group(4))) if result else ('harness-error', -1)
    return dict(line=line, function=function, gate=gate, status=status, errors=errors,
                first=first.group(1) if first else '-')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--jobs', type=int, default=3)
    args = p.parse_args()
    dirty = subprocess.run(['git', 'status', '--porcelain', '--', 'script/upgrade'], cwd=ROOT,
                           capture_output=True, text=True).stdout.strip()
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    print('HEAD', head, 'dirty', int(bool(dirty)), 'engine', os.environ.get('A3A_ENGINE_DIR', 'default'), flush=True)
    listing = subprocess.run([sys.executable, '-B', str(PROBE), '--list'], cwd=ROOT, capture_output=True, text=True,
                             check=True).stdout
    rows = []
    for l in listing.splitlines():
        m = re.match(r'\s*(\d+) (\S+)\s+(.+)$', l)
        if m:
            rows.append((int(m.group(1)), m.group(2), m.group(3).strip()))
    names = {g for gates in GATES.values() for g in gates}
    selected = [r for r in rows if r[2] in names or r[1] in Q3_FUNCTIONS]
    missing = sorted(names - {r[2] for r in selected})
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        results = list(pool.map(probe, selected))
    print('| line | function | gate | result | errors | first failing test |')
    print('|---:|---|---|---|---:|---|')
    for r in results:
        print(f"| {r['line']} | {r['function']} | {r['gate']} | {r['status']} | {r['errors']} | {r['first']} |")
    bad = [r for r in results if r['status'] != 'killed' or r['errors'] != 0]
    print('PROBED', len(results), 'KILLED', sum(r['status'] == 'killed' for r in results), 'MISSING', missing)
    ok = not bad and not missing and not dirty
    print('AUDIT605_PROBES', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
