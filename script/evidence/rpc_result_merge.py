"""Union of the three rpc_result coverage drivers for one engine run (6e merge rule, COMMIT6_RESULTS.md 6e).

probe_typed_gates alone credits direct deletions only (69/88 at 678e68b0); the paired method
(probe_gate_dsr2_rpc) and the sole-producer probes (probe_gate_producer_controls) credit the rest.
Usage: rpc_result_merge.py <outdir> <engine>   (reads <outdir>/<engine>-<driver>.log written by run_all_6j.sh)
"""
import re, sys
out, e = sys.argv[1], sys.argv[2]
# 6e known gaps (COMMIT6_RESULTS.md 6e producer table; DSR c0cff66a): no qualifying sole producer.
KNOWN_GAPS = {'rpc_result_rebuild_artifacts_object', 'rpc_result_verify_deployment_record_txHash',
              'rpc_result_validate_deployed_identity', 'rpc_result_post_upgrade_check_stateBlock',
              'rpc_result_post_upgrade_check_target', 'rpc_result_inspect_data'}
rx = re.compile(r'^RPC_RESULT_PROBE (\S+) (PASS|BLOCKED)')
direct = {}
for line in open(f'{out}/{e}-probe_typed_gates.log'):
    m = rx.match(line)
    if m: direct[m[1]] = m[2]
paired = {l.split()[1] for l in open(f'{out}/{e}-probe_gate_dsr2_rpc.log') if l.startswith('DSR2_RPC ') and l.split()[2] == 'PASS'}
producer = {re.search(r'gate=(\S+)', l)[1] for l in open(f'{out}/{e}-probe_gate_producer_controls.log') if l.startswith('PRODUCER_PROBE') and ' PASS ' in l}
extra = (paired | producer) - set(direct)
assert not extra, f'credited gates outside the 88 discovered sites: {sorted(extra)}'
passed = {g for g, r in direct.items() if r == 'PASS'} | paired | producer
blocked = sorted(set(direct) - passed)
print(f'[{e}] direct={sum(r=="PASS" for r in direct.values())} paired={len(paired)} producer={len(producer)}')
for g in blocked: print(f'[{e}] REMAINING_BLOCKED {g}')
print(f'RPC_RESULT_MERGED [{e}] passed={len(passed)} total={len(direct)} blocked={len(blocked)}')
print(f'RPC_RESULT_MERGE {"PASS" if set(blocked) == KNOWN_GAPS and len(direct) == 88 else "FAIL"} blocked_equals_known_gaps={set(blocked) == KNOWN_GAPS}')
sys.exit(int(set(blocked) != KNOWN_GAPS or len(direct) != 88))
