"""Union of the three rpc_result coverage drivers for one engine run (6e merge rule, COMMIT6_RESULTS.md 6e).

probe_typed_gates alone credits direct deletions only (69/88 at 678e68b0); the paired method
(probe_gate_dsr2_rpc) and the sole-producer probes (probe_gate_producer_controls) credit the rest.
Usage: rpc_result_merge.py <outdir> <engine>   (reads <outdir>/SUMMARY.txt and <outdir>/<engine>-<driver>.log
written by run_all_6j.sh)

A credit counts only if its driver completed: the driver's rc in SUMMARY.txt, its exact terminal line,
and the exact set of gates it reports are all checked. A crash after the decisive rows, or a PASS row
for a gate the driver does not own, fails the merge.
"""
import json, re, sys
from pathlib import Path
out, e = sys.argv[1], sys.argv[2]
# Trust root for the direct driver: the committed 88-site inventory (one gate name per site).
INVENTORY = {r['gate'] for r in json.loads((Path(__file__).resolve().parents[2] / 'script/upgrade/gate_typed_inventory.json').read_text())}
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
if set(direct) != INVENTORY or len(INVENTORY) != 88:
    faults.append(f'probe_typed_gates: row set differs from gate_typed_inventory.json: {sorted(set(direct) ^ INVENTORY)}')
if not final or len(direct) != 88 or int(final[1]) != sum(r == 'PASS' for r in direct.values()) \
        or int(final[2]) != sum(r == 'BLOCKED' for r in direct.values()):
    faults.append('probe_typed_gates: terminal line missing or inconsistent with its 88 rows')
if rc('probe_typed_gates') != (1 if 'BLOCKED' in direct.values() else 0):
    faults.append('probe_typed_gates: rc does not match its BLOCKED rows')

dsr2 = lines('probe_gate_dsr2_rpc')
# probe_gate_dsr2_rpc credits address_2 by its three-level method; the other ten are paired.
METHOD = {g: ('three-level' if g == 'rpc_result_fraud_fixture_address_2' else 'paired') for g in PAIRED}
PAIRED_ROW = re.compile(r'DSR2_RPC (\S+) PASS method=(paired|three-level) source_sites=1 baseline=green shadow=exact_E '
                        r's1_failures=[1-9]\d* s1_errors=0 s1_named=True failures=[1-9]\d* errors=0 named=True')
rows = [l for l in dsr2 if l.startswith('DSR2_RPC ')]
paired_rows = [PAIRED_ROW.fullmatch(l) for l in rows]
if not all(paired_rows) or len(rows) != len(PAIRED):
    faults.append(f'probe_gate_dsr2_rpc: expected exactly {len(PAIRED)} well-formed PASS rows, got {len(rows)} rows')
paired = {m[1] for m in paired_rows if m}
wrong = sorted(m[1] for m in paired_rows if m and METHOD.get(m[1]) != m[2])
if wrong: faults.append(f'probe_gate_dsr2_rpc: credit method differs from the driver\'s method for {wrong}')
if rc('probe_gate_dsr2_rpc') != 0 or not re.fullmatch(
        r'DSR2_RPC_AGGREGATE scope=\S+ processed=11 accepted=11 blocked=0 errors_accepted=0', dsr2[-1] if dsr2 else ''):
    faults.append('probe_gate_dsr2_rpc: did not complete (rc or terminal aggregate)')
if paired != PAIRED:
    faults.append(f'probe_gate_dsr2_rpc: PASS set differs from owned set: {sorted(paired ^ PAIRED)}')

prod = lines('probe_gate_producer_controls')
PRODUCER_ROW = re.compile(r'PRODUCER_PROBE scope=script/a3a/a3a_exec\.py:\d+ gate=(\S+) PASS source_sites=1 '
                          r'baseline=green failures=[1-9]\d* errors=0 named=True')
rows = [l for l in prod if l.startswith('PRODUCER_PROBE ')]
producer_rows = [PRODUCER_ROW.fullmatch(l) for l in rows]
if not all(producer_rows) or len(rows) != len(PRODUCER):
    faults.append(f'probe_gate_producer_controls: expected exactly {len(PRODUCER)} well-formed PASS rows, got {len(rows)} rows')
producer = {m[1] for m in producer_rows if m}
last = PRODUCER_ROW.fullmatch(prod[-1]) if prod else None
if rc('probe_gate_producer_controls') != 0 or not (last and last[1] == 'rpc_result_rebuild_artifacts_object_2'):
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
