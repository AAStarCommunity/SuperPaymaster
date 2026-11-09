"""Union of the three rpc_result coverage drivers for one engine run (6e merge rule, COMMIT6_RESULTS.md 6e).

probe_typed_gates alone credits direct deletions only (69/88 at 678e68b0); the paired method
(probe_gate_dsr2_rpc) and the sole-producer probes (probe_gate_producer_controls) credit the rest.
Usage: rpc_result_merge.py <outdir> <engine>   (reads <outdir>/SUMMARY.txt and <outdir>/<engine>-<driver>.log
written by run_all_6j.sh)

A credit counts only if its driver completed: the driver's rc in SUMMARY.txt, its exact terminal line,
and the exact set of gates it reports are all checked. A crash after the decisive rows, or a PASS row
for a gate the driver does not own, fails the merge.
"""
import re, sys
out, e = sys.argv[1], sys.argv[2]
# 6e known gaps (COMMIT6_RESULTS.md 6e producer table; DSR c0cff66a): no qualifying sole producer.
KNOWN_GAPS = {'rpc_result_rebuild_artifacts_object', 'rpc_result_verify_deployment_record_txHash',
              'rpc_result_validate_deployed_identity', 'rpc_result_post_upgrade_check_stateBlock',
              'rpc_result_post_upgrade_check_target', 'rpc_result_inspect_data'}
# Gates each auxiliary driver owns (probe_gate_dsr2_rpc CASES; probe_gate_producer_controls sites).
PAIRED = {'rpc_result_fraud_fixture_' + g for g in ('key', 'key_2', 'who', 'fraudProof', 'address', 'address_2',
                                                    'runtime', 'fraudProof_2', 'domainDigest')} | \
         {'rpc_result_validate_external_key', 'rpc_result_validate_external_who'}
PRODUCER = {'rpc_result_scheduled_eta_data', 'rpc_result_rebuild_artifacts_object_2'}
faults = []


def lines(driver):
    return [l.rstrip('\n') for l in open(f'{out}/{e}-{driver}.log')]


def rc(driver):
    hits = [int(m[1]) for m in (re.match(rf'^\[{e}\] {driver} rc=(\d+)\b', l) for l in open(f'{out}/SUMMARY.txt')) if m]
    if len(hits) != 1:
        faults.append(f'{driver}: expected one rc line in SUMMARY.txt, found {len(hits)}')
        return None
    return hits[0]


typed = lines('probe_typed_gates')
rx = re.compile(r'^RPC_RESULT_PROBE (\S+) (PASS|BLOCKED) ')
direct = {}
for line in typed:
    m = rx.match(line)
    if m:
        if m[1] in direct: faults.append(f'probe_typed_gates: duplicate row {m[1]}')
        direct[m[1]] = m[2]
final = re.fullmatch(r'RPC_RESULT_PROBES passed=(\d+) total=88 blocked=(\d+) errors_accepted=0', typed[-1] if typed else '')
if not final or len(direct) != 88 or int(final[1]) != sum(r == 'PASS' for r in direct.values()) \
        or int(final[2]) != sum(r == 'BLOCKED' for r in direct.values()):
    faults.append('probe_typed_gates: terminal line missing or inconsistent with its 88 rows')
if rc('probe_typed_gates') != (1 if 'BLOCKED' in direct.values() else 0):
    faults.append('probe_typed_gates: rc does not match its BLOCKED rows')

dsr2 = lines('probe_gate_dsr2_rpc')
paired = {l.split()[1] for l in dsr2 if l.startswith('DSR2_RPC ') and l.split()[2] == 'PASS'}
if rc('probe_gate_dsr2_rpc') != 0 or not re.fullmatch(
        r'DSR2_RPC_AGGREGATE scope=\S+ processed=11 accepted=11 blocked=0 errors_accepted=0', dsr2[-1] if dsr2 else ''):
    faults.append('probe_gate_dsr2_rpc: did not complete (rc or terminal aggregate)')
if paired != PAIRED:
    faults.append(f'probe_gate_dsr2_rpc: PASS set differs from owned set: {sorted(paired ^ PAIRED)}')

prod = lines('probe_gate_producer_controls')
producer = {re.search(r' gate=(\S+) ', l)[1] for l in prod if l.startswith('PRODUCER_PROBE ') and ' PASS ' in l}
if rc('probe_gate_producer_controls') != 0 or not (prod and prod[-1].startswith('PRODUCER_PROBE ')
                                                    and 'gate=rpc_result_rebuild_artifacts_object_2 PASS' in prod[-1]):
    faults.append('probe_gate_producer_controls: did not complete (rc or terminal line)')
if producer != PRODUCER:
    faults.append(f'probe_gate_producer_controls: PASS set differs from owned set: {sorted(producer ^ PRODUCER)}')

extra = (paired | producer) - set(direct)
if extra: faults.append(f'credited gates outside the 88 discovered sites: {sorted(extra)}')
passed = {g for g, r in direct.items() if r == 'PASS'} | paired | producer
blocked = sorted(set(direct) - passed)
print(f'[{e}] direct={sum(r == "PASS" for r in direct.values())} paired={len(paired)} producer={len(producer)}')
for g in blocked: print(f'[{e}] REMAINING_BLOCKED {g}')
for f in faults: print(f'[{e}] FAULT {f}')
print(f'RPC_RESULT_MERGED [{e}] passed={len(passed)} total={len(direct)} blocked={len(blocked)}')
ok = not faults and set(blocked) == KNOWN_GAPS
print(f'RPC_RESULT_MERGE {"PASS" if ok else "FAIL"} blocked_equals_known_gaps={set(blocked) == KNOWN_GAPS} faults={len(faults)}')
sys.exit(int(not ok))
