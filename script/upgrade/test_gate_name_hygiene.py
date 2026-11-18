#!/usr/bin/env python3
"""Gate-name hygiene for the release executors (#608 split PR-2, COMMIT 6e renames).

The 6e renames changed gate-name strings only. A rename can break three things, and this file
checks each mechanically from the source AST:
  (a) two gates merged into one name: the set of names that still repeat is frozen; a new
      repeat fails. (All 41 predate 6e; the renames removed 42 others.)
  (b) a consumer that compares gate names (allow lists, expected-gate checks) still holding an
      old name: the 46 replaced names must not appear as string literals in executor code,
      tests or workflows, and every gate name a consumer compares against must still be raised.
  (c) rpc_result sites: typed() reports exactly the name its caller passes, and every
      rpc_result_* call site passes a unique literal; the site count is pinned.
"""
import ast
import re
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'script'/'a3a'))
import a3a_exec as a  # noqa: E402

RUNTIME = ['script/upgrade/manifest_exec.py', 'script/upgrade/old_owner_isolation.py',
           'script/upgrade/sp_upgrade_exec.py', 'script/a3a/a3a_exec.py', 'script/a3a/a3a_send.py']
RPC_RESULT_SITES = 89
# Names raised from more than one site before and after 6e (6e removed 42 others).
FROZEN_REPEATS = {
    'abi_address_padding', 'artifact_bytecode', 'artifact_source_unresolved', 'block_gas_limit', 'chain',
    'engine_start', 'engine_stderr', 'fork_config_missing', 'fresh_estimate', 'frozen_budgets',
    'frozen_plan_unchanged', 'immutable_range_bounds', 'immutable_range_overlap', 'independent_pin',
    'metadata_cbor', 'negative_order_reason', 'negative_trace', 'onchain_safe_hash', 'output_empty',
    'pin_recheck', 'pinned_block', 'plan_budgets', 'post_safe_nonce', 'pre_send_chain',
    'rebuild_forge_unavailable', 'rebuild_submodule_unavailable', 'reviewed_plan_hash', 'rpc_envelope',
    'rr_create_only', 'rr_mined_need', 'safe_guard', 'safe_modules', 'safe_threshold',
    'schedule_canonical_block', 'schedule_log_removed', 'schedule_log_tx_block', 'schedule_log_tx_block_hash',
    'schedule_log_tx_hash', 'schedule_receipt_block', 'schedule_receipt_missing', 'simulation_pin',
}
# Gate names 6e replaced; they must not survive as string literals anywhere a gate can be raised
# or compared (the rename records under script/upgrade/gate_rename_*.json and historical docs
# are deliberately out of scope).
REPLACED = {
    'a3a_gap_mined_before_pin', 'a3a_mined_', 'a3a_plan', 'built_aggregator_version',
    'evidence_scope_recomputed', 'evidence_slither_rederived', 'evidence_unique_findings',
    'fixed_old_aggregator', 'fraud_token_fields', 'manifest_', 'manifest_local_only', 'manifest_step_',
    'manifest_tx_', 'old_owner_allowance_', 'old_owner_authority_', 'old_owner_calldata_bytes',
    'old_owner_deployed_build', 'old_owner_event_role_', 'old_owner_evidence_present',
    'old_owner_factory_enumeration', 'old_owner_mapping_', 'old_owner_role_', 'old_owner_role_admin_',
    'old_timelock_approval_history', 'old_timelock_replay', 'phase_c_account_evidence', 'phase_c_measurement',
    'phase_c_rehearsal_evidence', 'prefix_boundary', 'readback_', 'rpc_result', 'safe_gap_endpoints',
    'safe_gap_gas_price', 'safe_gap_gas_used', 'safe_gap_hash', 'safe_gap_log_data', 'safe_gap_miner_balance',
    'safe_gap_owner_eoa', 'safe_gap_pin_nonce', 'safe_gap_pin_owners', 'safe_gap_pin_threshold',
    'safe_gap_receipt_identity', 'safe_gap_trace_storage', 'stage_not_final', 'stake_not_unlocking',
    'unexpected_proxy', 'verifier_commit',
}
# Gate names (or prefixes) that executor code compares a caught Gate against.
CONSUMED = ['operator_paused_', 'output_empty', 'rebuild_submodule_unavailable', 'pre_send_code_S4',
            'old_owner_event_role_member_', 'old_owner_mapping_getter', 'rpc_fault', 'rpc_transport',
            'rpc_envelope', 'readback_value_fraudProofVerifier()', 'B2_capped_buffer', 'manifest_length']


def _name(func):
    return func.id if isinstance(func, ast.Name) else func.attr if isinstance(func, ast.Attribute) else None


def gate_sites():
    """Every need/typed/Gate call in the runtime files: (file, line, kind, name-or-source)."""
    sites = []
    for path in RUNTIME:
        for node in ast.walk(ast.parse((ROOT/path).read_text())):
            if not isinstance(node, ast.Call):
                continue
            fn = _name(node.func)
            if fn in ('need', 'Gate'):
                arg = node.args[0] if node.args else None
            elif fn == 'typed':
                arg = next((k.value for k in node.keywords if k.arg == 'gate'),
                           node.args[2] if len(node.args) > 2 else None)
            else:
                continue
            if arg is None:
                sites.append((path, node.lineno, 'missing', None))
            elif isinstance(arg, ast.Constant) and isinstance(arg.value, str):
                sites.append((path, node.lineno, 'literal', arg.value))
            else:
                sites.append((path, node.lineno, 'dynamic', ast.unparse(arg)))
    return sites


class GateNameHygieneTests(unittest.TestCase):
    def setUp(self):
        self.sites = gate_sites()
        self.literals = [s[3] for s in self.sites if s[2] == 'literal']

    def test_enumeration_control(self):
        # Positive control: the scan sees the executors (a broken scan would pass every check below).
        self.assertGreater(len(self.literals), 1000)
        self.assertIn('rpc_result_inventory_1', self.literals)

    def test_no_new_repeated_gate_name(self):
        seen, repeats = set(), set()
        for name in self.literals:
            (repeats if name in seen else seen).add(name)
        self.assertEqual(repeats - FROZEN_REPEATS, set(), 'a gate name now repeats')
        self.assertEqual(FROZEN_REPEATS - repeats, set(), 'a frozen repeat is gone: shrink FROZEN_REPEATS')

    def test_every_typed_call_names_its_gate(self):
        self.assertEqual([s for s in self.sites if s[2] == 'missing'], [])

    def test_rpc_result_sites_are_unique_literals_and_counted(self):
        rpc = [s for s in self.sites if s[2] == 'literal' and s[3].startswith('rpc_result')]
        self.assertEqual(len(rpc), RPC_RESULT_SITES)
        self.assertEqual(len({s[3] for s in rpc}), RPC_RESULT_SITES)
        dynamic = [s for s in self.sites if s[2] == 'dynamic' and 'rpc_result' in s[3]]
        self.assertEqual(dynamic, [])

    def test_typed_reports_the_name_it_was_given(self):
        for name in ('rpc_result_inventory_1', 'rpc_result_qty_value', 'any_caller_supplied_name'):
            with self.assertRaises(a.Gate) as caught:
                a.typed('not-hex', a.HASH32, name)
            self.assertEqual(caught.exception.record['gate'], name)
            self.assertEqual(a.typed('0x'+'ab'*32, a.HASH32, name), '0x'+'ab'*32)

    def test_replaced_names_have_no_literal_left(self):
        files = [ROOT/p for p in RUNTIME]
        files += sorted(f for f in (ROOT/'script').glob('**/test_*.py') if f.resolve() != Path(__file__).resolve())
        files += sorted((ROOT/'.github'/'workflows').glob('*.yml'))
        hits = []
        for path in files:
            text = path.read_text()
            for name in REPLACED:
                if re.search(r"""['"]%s['"]""" % re.escape(name), text):
                    hits.append((path.relative_to(ROOT).as_posix(), name))
        self.assertEqual(hits, [])

    def test_consumed_gate_names_are_still_raised(self):
        prefixes = []
        for _, _, kind, source in self.sites:
            if kind == 'dynamic':
                m = re.match(r"""^f?'([^'{]+)""", source)
                if m:
                    prefixes.append(m.group(1))
        literals = set(self.literals)
        for name in CONSUMED:
            self.assertTrue(name in literals or any(name.startswith(p) for p in prefixes)
                            or any(p.startswith(name) for p in prefixes), name)


if __name__ == '__main__':
    unittest.main()
