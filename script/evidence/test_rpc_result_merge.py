"""Controls for rpc_result_merge.py on synthetic driver logs (Codex 6l review: crash-after-rows / spurious PASS)."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MERGE = Path(__file__).resolve().parent / 'rpc_result_merge.py'
sys.path.insert(0, str(MERGE.parent))
GAPS = ['rpc_result_rebuild_artifacts_object', 'rpc_result_verify_deployment_record_txHash',
        'rpc_result_validate_deployed_identity', 'rpc_result_post_upgrade_check_stateBlock',
        'rpc_result_post_upgrade_check_target', 'rpc_result_inspect_data']
PAIRED = ['rpc_result_fraud_fixture_' + g for g in ('key', 'key_2', 'who', 'fraudProof', 'address', 'address_2',
                                                    'runtime', 'fraudProof_2', 'domainDigest')] + \
         ['rpc_result_validate_external_key', 'rpc_result_validate_external_who']
PRODUCER = ['rpc_result_scheduled_eta_data', 'rpc_result_rebuild_artifacts_object_2']
INVENTORY = [r['gate'] for r in json.loads((MERGE.parents[2] / 'script/upgrade/gate_typed_inventory.json').read_text())]
DIRECT = [g for g in INVENTORY if g not in set(GAPS + PAIRED + PRODUCER)]
PAIRED_OK = ' method=paired source_sites=1 baseline=green shadow=exact_E s1_failures=1 s1_errors=0 s1_named=True failures=1 errors=0 named=True'
PROD_OK = ' PASS source_sites=1 baseline=green failures=1 errors=0 named=True'


def logs():
    blocked = GAPS + PAIRED + PRODUCER
    typed = [f'RPC_RESULT_PROBE {g} PASS sites=1' for g in DIRECT] + \
            [f'RPC_RESULT_PROBE {g} BLOCKED sites=1 reason=x' for g in blocked] + \
            [f'RPC_RESULT_PROBES passed={len(DIRECT)} total=88 blocked={len(blocked)} errors_accepted=0']
    dsr2 = [f'DSR2_RPC {g} PASS' + (PAIRED_OK.replace('paired', 'three-level') if g.endswith('address_2') else PAIRED_OK)
            for g in PAIRED] + \
           ['DSR2_RPC_AGGREGATE scope=manifest_exec.py:1 processed=11 accepted=11 blocked=0 errors_accepted=0']
    prod = ['PRODUCER_PROBE scope=script/a3a/a3a_exec.py:1525 gate=rpc_result_scheduled_eta_data' + PROD_OK,
            'PRODUCER_PAIR scope=script/a3a/a3a_exec.py:1525 BLOCKED E=x',
            'PRODUCER_PROBE scope=script/a3a/a3a_exec.py:669 gate=rpc_result_rebuild_artifacts_object_2' + PROD_OK]
    summary = ['[bin] probe_typed_gates rc=1 :: x', '[bin] probe_gate_dsr2_rpc rc=0 :: x',
               '[bin] probe_gate_producer_controls rc=0 :: x']
    return dict(typed=typed, dsr2=dsr2, prod=prod, summary=summary)


class MergeControls(unittest.TestCase):
    def run_merge(self, mutate=None):
        parts = logs()
        if mutate: mutate(parts)
        with tempfile.TemporaryDirectory() as d:
            for key, name in (('typed', 'bin-probe_typed_gates.log'), ('dsr2', 'bin-probe_gate_dsr2_rpc.log'),
                              ('prod', 'bin-probe_gate_producer_controls.log'), ('summary', 'SUMMARY.txt')):
                Path(d, name).write_text('\n'.join(parts[key]) + '\n')
            p = subprocess.run([sys.executable, '-B', str(MERGE), d, 'bin'], capture_output=True, text=True)
        return p.returncode, p.stdout

    def test_complete_run_passes(self):
        rc, out = self.run_merge()
        self.assertEqual(rc, 0, out)
        self.assertIn('RPC_RESULT_MERGED [bin] passed=82 total=88 blocked=6', out)

    def assertFails(self, mutate, fault):
        rc, out = self.run_merge(mutate)
        self.assertEqual(rc, 1, out)
        self.assertIn(fault, out)

    def test_paired_driver_crash_after_rows(self):
        self.assertFails(lambda p: p['dsr2'].pop(), 'probe_gate_dsr2_rpc: did not complete')

    def test_paired_driver_nonzero_rc(self):
        self.assertFails(lambda p: p['summary'].__setitem__(1, '[bin] probe_gate_dsr2_rpc rc=1 :: x'),
                         'probe_gate_dsr2_rpc: did not complete')

    def test_paired_pass_for_unowned_gate(self):
        def mutate(p): p['dsr2'][-2] = 'DSR2_RPC rpc_result_inspect_data PASS' + PAIRED_OK
        self.assertFails(mutate, 'probe_gate_dsr2_rpc: PASS set differs from owned set')

    def test_producer_truncated(self):
        self.assertFails(lambda p: p['prod'].pop(), 'probe_gate_producer_controls: did not complete')

    def test_producer_spurious_pass_mid_log(self):
        self.assertFails(lambda p: p['prod'].insert(0, 'PRODUCER_PROBE scope=script/a3a/a3a_exec.py:1 gate=rpc_result_inspect_data' + PROD_OK),
                         'probe_gate_producer_controls: expected exactly 2 well-formed PASS rows')

    def test_direct_foreign_gate_same_count(self):
        self.assertFails(lambda p: p['typed'].__setitem__(0, 'RPC_RESULT_PROBE rpc_result_foreign_unowned PASS sites=1'),
                         'probe_typed_gates: row set differs from gate_typed_inventory.json')

    def test_paired_duplicate_row(self):
        self.assertFails(lambda p: p['dsr2'].insert(0, p['dsr2'][0]),
                         'probe_gate_dsr2_rpc: expected exactly 11 well-formed PASS rows')

    def test_paired_malformed_row(self):
        self.assertFails(lambda p: p['dsr2'].__setitem__(0, p['dsr2'][0].replace('errors=0 named', 'errors=1 named')),
                         'probe_gate_dsr2_rpc: expected exactly 11 well-formed PASS rows')

    def test_paired_wrong_method(self):
        self.assertFails(lambda p: p['dsr2'].__setitem__(0, p['dsr2'][0].replace('method=paired', 'method=three-level')),
                         "credit method differs from the driver's method")

    def test_producer_duplicate_row(self):
        self.assertFails(lambda p: p['prod'].insert(0, p['prod'][0]),
                         'probe_gate_producer_controls: expected exactly 2 well-formed PASS rows')

    def test_producer_malformed_terminal(self):
        self.assertFails(lambda p: p['prod'].__setitem__(-1,
                         'PRODUCER_PROBE malformed gate=rpc_result_rebuild_artifacts_object_2 PASS malformed'),
                         'probe_gate_producer_controls: did not complete')

    def test_direct_row_missing(self):
        self.assertFails(lambda p: p['typed'].pop(0), 'probe_typed_gates: terminal line missing or inconsistent')

    def test_direct_terminal_missing(self):
        self.assertFails(lambda p: p['typed'].pop(), 'probe_typed_gates: terminal line missing or inconsistent')

    def test_missing_rc_line(self):
        self.assertFails(lambda p: p['summary'].pop(2), 'probe_gate_producer_controls: expected one rc line')

    def test_extra_blocked_gate(self):
        def mutate(p):
            p['typed'][0] = p['typed'][0].replace(' PASS ', ' BLOCKED ')
            p['typed'][-1] = 'RPC_RESULT_PROBES passed=68 total=88 blocked=20 errors_accepted=0'
        rc, out = self.run_merge(mutate)
        self.assertEqual(rc, 1, out)
        self.assertIn('blocked_equals_known_gaps=False', out)


if __name__ == '__main__':
    unittest.main()
