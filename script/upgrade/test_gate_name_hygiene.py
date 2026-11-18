"""Gate-name hygiene for the release executors (#608 split PR-2, COMMIT 6e renames).

The 6e renames changed gate-name strings only. A rename can break three things; this file checks
each mechanically with gate_name_scan over every executor module (gate_name_scan.runtime_files()):
  (a) two gates merged into one name: the per-name count of every name raised more than once is
      frozen; a new repeat or a grown count fails.
  (b) a consumer that compares a caught gate name still holding an old name: every consumer
      literal/prefix must be exactly producible, and the names replaced between the base and the
      PR-2 head (generated, gate_names_replaced_pr2.json) survive nowhere as string literals in
      executor code, tests or workflows.
  (c) rpc_result sites: typed() reports exactly the name its caller passes, and every
      rpc_result_* site passes a unique literal; the site count is pinned.
"""
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'script'/'a3a'))
sys.path.insert(0, str(ROOT/'script'/'upgrade'))
import a3a_exec as a  # noqa: E402
import gate_name_scan  # noqa: E402

RPC_RESULT_SITES = 89
# Per-name counts of names raised from more than one site. All predate 6e (6e removed 47 others);
# none may grow and no new name may join.
FROZEN_REPEATS = {
    'abi_address_padding': 2, 'artifact_bytecode': 2, 'artifact_source_unresolved': 2, 'block_gas_limit': 5,
    'chain': 2, 'engine_start': 2, 'engine_stderr': 4, 'fork_config_missing': 2, 'fresh_estimate': 2,
    'frozen_budgets': 2, 'frozen_plan_unchanged': 4, 'immutable_range_bounds': 2, 'immutable_range_overlap': 2,
    'independent_pin': 2, 'metadata_cbor': 9, 'negative_order_reason': 2, 'negative_trace': 2,
    'onchain_safe_hash': 2, 'output_empty': 4, 'pin_keys': 3, 'pin_recheck': 3, 'pinned_block': 2,
    'plan_budgets': 2, 'plan_keys': 2, 'post_safe_nonce': 2, 'pre_send_chain': 2,
    'rebuild_forge_unavailable': 2, 'rebuild_submodule_unavailable': 3, 'reviewed_plan_hash': 3,
    'rpc_envelope': 2, 'rr_create_only': 2, 'rr_mined_need': 2, 'safe_guard': 2, 'safe_modules': 2,
    'safe_threshold': 2, 'schedule_canonical_block': 2, 'schedule_log_removed': 2, 'schedule_log_tx_block': 2,
    'schedule_log_tx_block_hash': 2, 'schedule_log_tx_hash': 2, 'schedule_receipt_block': 2,
    'schedule_receipt_missing': 3, 'simulation_pin': 2,
}
REPLACED_FILE = ROOT/'script'/'upgrade'/'gate_names_replaced_pr2.json'
# Consumers whose compared value is itself data (a control case's recorded gate); reviewed by hand.
OPAQUE_CONSUMERS = {
    "a.need('old_owner_release_negative_control', stopped, control['gate'])",
}

# Consumer literals that no producer raises verbatim and that are matched only through a producer
# prefix (the suffix is runtime data); each was checked by hand against its producer. Any other
# prefix-only match fails, because a short prefix (e.g. 'verifier_') would accept any old name.
PREFIX_ONLY_CONSUMERS = {
    'pre_send_code_S4': 'pre_send_code_',
    'C_funding_bundler': 'C_funding_',
    'readback_value_fraudProofVerifier()': 'readback_value_',
}


def gate_sites(scan=None):
    """Producer sites as (file, line, kind, name): kind is literal, prefix, dynamic or missing."""
    scan = scan or gate_name_scan.Scan()
    kinds = {'opaque': 'dynamic'}
    return [(f, line, kinds.get(kind, kind), value) for kind, value, (f, line) in scan.producers]


class GateNameHygieneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scan = gate_name_scan.Scan()
        cls.sites = gate_sites(cls.scan)
        cls.literals = [s[3] for s in cls.sites if s[2] == 'literal']

    def test_enumeration_control(self):
        # Positive control: the scan sees every executor and both producer and consumer sides
        # (a broken scan would pass every check below).
        self.assertGreaterEqual(len(self.scan.files), 12)
        self.assertGreater(len(self.literals), 1000)
        self.assertIn('rpc_result_inventory_1', self.literals)
        consumed = {v for k, v, _ in self.scan.consumers}
        for name in ('send_after_broadcast', 'operator_paused_', 'old_owner_fork_case_', 'C_price_bound_exec'):
            self.assertIn(name, consumed)

    def test_no_new_repeated_gate_name(self):
        counts = {}
        for name in self.literals:
            counts[name] = counts.get(name, 0)+1
        repeats = {k: v for k, v in counts.items() if v > 1}
        self.assertEqual(repeats, FROZEN_REPEATS)

    def test_every_typed_call_names_its_gate(self):
        self.assertEqual([s for s in self.sites if s[2] == 'missing'], [])

    def test_rpc_result_sites_are_unique_literals_and_counted(self):
        rpc = [s for s in self.sites if s[2] == 'literal' and s[3].startswith('rpc_result')]
        self.assertEqual(len(rpc), RPC_RESULT_SITES)
        self.assertEqual(len({s[3] for s in rpc}), RPC_RESULT_SITES)
        self.assertEqual([s for s in self.sites if s[2] in ('dynamic', 'prefix') and 'rpc_result' in s[3]], [])

    def test_typed_reports_the_name_it_was_given(self):
        for name in ('rpc_result_inventory_1', 'rpc_result_qty_value', 'any_caller_supplied_name'):
            with self.assertRaises(a.Gate) as caught:
                a.typed('not-hex', a.HASH32, name)
            self.assertEqual(caught.exception.record['gate'], name)
            self.assertEqual(a.typed('0x'+'ab'*32, a.HASH32, name), '0x'+'ab'*32)
        with self.assertRaises(TypeError):
            a.typed('0x'+'ab'*32, a.HASH32)  # no default name since 6e

    def test_replaced_names_have_no_literal_left(self):
        replaced = json.loads(REPLACED_FILE.read_text())
        names = replaced['literals']+replaced['prefixes']
        self.assertGreater(len(names), 50)
        files = [ROOT/p for p in self.scan.files]
        files += sorted(f for f in (ROOT/'script').glob('**/test_*.py') if f.resolve() != Path(__file__).resolve())
        files += sorted((ROOT/'.github'/'workflows').glob('*.yml'))
        hits = []
        for path in files:
            text = path.read_text()
            for name in names:
                if re.search(r"""['"]%s['"]""" % re.escape(name), text):
                    hits.append((path.relative_to(ROOT).as_posix(), name))
        self.assertEqual(hits, [])

    def test_consumed_gate_names_are_exactly_producible(self):
        self.assertEqual(self.scan.unproducible(), [])
        literals, prefixes = self.scan.producer_names()
        prefix_only = {v: sorted(p for p in prefixes if v.startswith(p) and len(v) > len(p))
                       for k, v, _ in self.scan.consumers if k == 'literal' and v not in literals}
        self.assertEqual(prefix_only, {k: [v] for k, v in PREFIX_ONLY_CONSUMERS.items()})
        opaque = {v for k, v, _ in self.scan.consumers if k == 'opaque'}
        self.assertEqual(opaque, OPAQUE_CONSUMERS)

    def test_scanner_rejects_an_orphaned_consumer(self):
        # Negative controls on a copy: renaming the producer of a consumed literal, or of a consumed
        # prefix, must make that consumer unproducible.
        mutations = [
            ('script/a3a/a3a_send.py', "Gate('send_after_broadcast',", "Gate('send_after_broadcast_x',"),
            ('script/upgrade/sp_upgrade_exec.py', "a.need('operator_paused_'+who, paused",
             "a.need('operator_paused_x_'+who, paused"),
        ]
        for path, old, new in mutations:
            with self.subTest(path=path), tempfile.TemporaryDirectory() as tmp:
                for f in self.scan.files:
                    (Path(tmp)/f).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy(ROOT/f, Path(tmp)/f)
                text = (Path(tmp)/path).read_text()
                self.assertEqual(text.count(old), 1)
                self.assertEqual(gate_name_scan.Scan(root=tmp).unproducible(), [])
                (Path(tmp)/path).write_text(text.replace(old, new))
                self.assertNotEqual(gate_name_scan.Scan(root=tmp).unproducible(), [])

    def test_frozen_renames_are_raised_where_recorded(self):
        import probe_phase_c_gates as probe
        rows = json.loads((ROOT/probe.RENAMES_FILE).read_text())['renamed']
        self.assertEqual(len(rows), probe.RENAMED_COUNT)
        source = (ROOT/'script'/'upgrade'/'manifest_exec.py').read_text()
        for row in rows:
            self.assertEqual(set(row['functions']), probe._defining_functions(source, row['name']), row['name'])


if __name__ == '__main__':
    unittest.main()
