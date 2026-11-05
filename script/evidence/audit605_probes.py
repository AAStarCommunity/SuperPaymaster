#!/usr/bin/env python3
"""Gate-removal acceptance for the #605 audit fixes (DSR rulings 2026-11-05; offline only).

Every required gate (F-01..F-04, #606 L1 closing gates, the F-05 list and the Q3 control gates) is listed
explicitly and bound to the test that must defend it. For each a.need statement of a required gate,
from probe_gate_removal.py --list on the current source:
  1. baseline: the bound test passes on the unmodified module;
  2. full suite, --failfast, statement removed: `killed`, zero errors;
  3. bound test only, statement removed: `killed` by assertion failures of that test alone, zero errors.
PASS only if the source tree is clean, the unmodified full suite is green, every required gate is found
and every probe and baseline meets the above with exit status 0.

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
SUITE = ROOT/'script/upgrade/test_manifest_exec.py'
F05_CLASS = dict(pre_send='F05PreSendGates', run_manifest='F05RunManifestGates', execute_b4='F05ExecuteB4Gates',
                 collect='F05CollectGates', build_plan='F05BuildPlanGates', collect_pair='F05MainGates',
                 main='F05MainGates', b4_controls='F05Q3ForkControls', unbacked_swap_control='F05Q3ForkControls',
                 mint_trace='F05Q3ForkControls')
F05 = {
    'pre_send': ['sender_nonce', 'pending_nonce', 'safe_nonce', 'safe_state', 'dvt_activity_unchanged', 'SP_owner',
                 'pending_token', 'pending_token_eta', 'onchain_safe_hash', 'fresh_estimate', 'block_gas_limit'],
    'run_manifest': ['post_nonce', 'post_safe_nonce', 'manifest_receipt_gas', 'steps_complete', 'controls_complete',
                     'post_swap_tracked', 'post_swap_revenue', 'post_swap_capped_balance', 'post_swap_solvency'],
    'execute_b4': ['B4_timestamp', 'B4_nonce_consumed', 'B4_safe_nonce'],
    'collect': ['old_aggregator_owner', 'anni_eoa', 'stake_not_unlocking'],
    'build_plan': ['stake_not_unlocking'],
    'collect_pair': ['independent_pin'],
    'main': ['simulation_pin', 'pin_recheck'],
    # Q3: offline fake-chain controls.
    'b4_controls': ['B4_control_initial', 'B4_control_placeholder', 'B4_wrong_gate', 'B4_wrong_status',
                    'B4_wrong_must_stop', 'B4_control_status', 'B4_next_nonce', 'B4_later_nonce', 'B4_control_restore'],
    'mint_trace': ['mint_trace_top', 'mint_trace_success', 'mint_trace_count', 'mint_trace_call'],
    'unbacked_swap_control': ['unbacked_initial', 'unbacked_shortfall', 'unbacked_refusal_gate',
                              'unbacked_plan_refusal_gate', 'unbacked_restore'],
}
CLOSING = 'ManifestTests.test_dvt_closing_binds_pointer_and_stale_proposals'
REQUIRED = {
    ('old_timelock_holds_nothing', 'old_timelock_approval_history'): 'ManifestTests.test_old_timelock_approval_history',
    **{('validate_old_timelock', g): 'ManifestTests.test_'+g for g in
       ('old_timelock_required', 'old_timelock_schema', 'old_timelock_block', 'old_timelock_replay', 'old_timelock_unused')},
    ('old_timelock_holds_nothing', 'old_timelock_allowance'): 'ManifestTests.test_old_timelock_allowance',
    ('closing_timelock_inventory', 'old_timelock_inventory'): 'ManifestTests.test_old_timelock_inventory_new_role',
    **{('old_timelock_holds_nothing', g): 'ManifestTests.test_'+g for g in
       ('old_timelock_holds_nothing', 'old_timelock_tl_roles', 'old_timelock_authority', 'old_timelock_safe')},
    ('validate_external', 'sampled_deployer_only'): 'ManifestTests.test_sampled_deployer_only',
    ('budget', "'budget_' + label"): 'ManifestTests.test_budget_includes_stake_and_deposit',
    ('build_plan', 'pin_pending_token_eta'): 'ManifestTests.test_pin_pending_token_eta',
    ('collect', 'old_aggregator_slash_policy_admin'): 'ManifestTests.test_collect_direct_fake_chain',
    **{('dvt_closing', g): CLOSING for g in ('closing_registry_pointer', 'closing_dvt_pointer',
                                             'closing_committee_pointer', 'closing_dvt_activity',
                                             'closing_stale_unexecuted')},
    **{('old_pointers', g): 'ManifestTests.test_old_pointers_require_old_aggregator' for g in ('old_pointer', 'pointer_owner')},
    **{(fn, g): f'{F05_CLASS[fn]}.test_{g}' for fn, gates in F05.items() for g in gates},
}

ISOLATION_FUNCTIONS = {'role_history','audit','mapping_control','never_granted_recheck'}
REQUIRED.update({
    ('role_history', 'old_owner_history_positive'): 'OldOwnerIsolationTests.test_history_all_roles_zero',
    ('role_history', 'old_owner_never_granted_set'): 'OldOwnerIsolationTests.test_never_granted_range_grant',
    ('audit', 'old_owner_never_granted_holder'): 'OldOwnerIsolationTests.test_never_granted_control_holder',
    ('mapping_control', 'old_owner_mapping_getter'): 'OldOwnerIsolationTests.test_mapping_function_falls_back',
    ('mapping_control', 'old_owner_mapping_positive'): 'OldOwnerIsolationTests.test_mapping_positive_zero',
    ('mapping_control', 'old_owner_mapping_negative'): 'OldOwnerIsolationTests.test_mapping_negative_one',
    ('never_granted_recheck', 'old_owner_never_granted_recheck'): 'ManifestTests.test_never_granted_closing_change',
    ('never_granted_recheck', 'old_owner_role_recheck'): 'ManifestTests.test_old_role_closing_change',
})


def sh(*args, module="manifest_exec", tests="test_manifest_exec"):
    p = subprocess.run([sys.executable, '-B', str(PROBE), '--module', module, '--tests', tests, *args], cwd=ROOT, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def parse(rc, out):
    m = re.search(r'^PROBE_RESULT (\w+) ran (\d+) failures (\d+) errors (\d+)', out, re.M)
    if rc != 0 or not m or 'PROBE_ERROR' in out:
        return dict(status='harness-error', ran=0, failures=0, errors=-1, failed=[])
    failed = [l.split()[1] for l in out.splitlines() if l.startswith('FAILED_TEST ')]
    return dict(status=m.group(1), ran=int(m.group(2)), failures=int(m.group(3)), errors=int(m.group(4)), failed=failed)


def probe(row):
    line, function, gate = row
    bound = REQUIRED[(function, gate)]
    tests = 'test_old_owner_isolation' if bound.startswith('OldOwnerIsolationTests.') else 'test_manifest_exec'
    options = dict(module='old_owner_isolation' if function in ISOLATION_FUNCTIONS else 'manifest_exec',tests=tests)
    base = parse(*sh('--baseline', '--select', bound, **options))
    full = parse(*sh('--site', str(line), '--failfast', **options))
    only = parse(*sh('--site', str(line), '--select', bound, **options))
    ok = (base['status'] == 'survived' and base['ran'] >= 1 and base['errors'] == 0
          and full['status'] == 'killed' and full['errors'] == 0
          and only['status'] == 'killed' and only['errors'] == 0 and only['failures'] >= 1
          and all(t == tests+'.'+bound for t in only['failed']))
    return dict(line=line, function=function, gate=gate, bound=bound, base=base['status'], full=full['status'],
                only=f"{only['status']} failures={only['failures']} errors={only['errors']}", ok=ok)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--jobs', type=int, default=3)
    args = p.parse_args()
    status = subprocess.run(['git', 'status', '--porcelain'], cwd=ROOT, capture_output=True, text=True)
    head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT, capture_output=True, text=True)
    clean = status.returncode == 0 and head.returncode == 0 and status.stdout.strip() == ''
    print('HEAD', head.stdout.strip(), 'clean', int(clean), 'engine', os.environ.get('A3A_ENGINE_DIR', 'default'), flush=True)
    suite = subprocess.run([sys.executable, '-B', str(SUITE)], cwd=ROOT, capture_output=True, text=True)
    green = suite.returncode == 0 and re.search(r'^OK\b', suite.stderr, re.M) is not None
    print('BASELINE_SUITE', 'green' if green else 'RED', (re.findall(r'^Ran .*$', suite.stderr, re.M) or ['?'])[-1], flush=True)
    rc, listing = sh('--list')
    isolation_rc, isolation_listing = sh('--list',module='old_owner_isolation')
    rc = rc or isolation_rc
    listing += '\n'+isolation_listing
    rows = []
    for l in listing.splitlines():
        m = re.match(r'\s*(\d+) (\S+)\s+(.+)$', l)
        if m and (m.group(2), m.group(3).strip()) in REQUIRED:
            rows.append((int(m.group(1)), m.group(2), m.group(3).strip()))
    missing = sorted(set(REQUIRED) - {(fn, g) for _, fn, g in rows})
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        results = list(pool.map(probe, rows))
    print('| line | function | gate | bound test | baseline | full suite | bound test, gate removed | ok |')
    print('|---:|---|---|---|---|---|---|---|')
    for r in results:
        print(f"| {r['line']} | {r['function']} | {r['gate']} | {r['bound']} | {r['base']} | {r['full']} | {r['only']} | {int(r['ok'])} |")
    print('PROBED', len(results), 'OK', sum(r['ok'] for r in results), 'MISSING', missing)
    ok = rc == 0 and clean and green and not missing and results and all(r['ok'] for r in results)
    print('AUDIT605_PROBES', 'PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
