#!/usr/bin/env python3
"""Audit 2026-11-04: executable findings against the manifest executor on origin/main.

Every test is a minimal reproduction of one finding in
docs/release/sp-upgrade-a6e/AUDIT-2026-11-04.md and is marked
``unittest.expectedFailure``: it asserts the behaviour the design requires, using the
*specific* gate name (or gate record field) a fix is expected to introduce, so it fails
today for the documented cause. Each docstring states the condition under which the
decorator must be removed and the test becomes a normal regression test.

Offline only: synthetic unit fixtures from test_manifest_exec.py, no RPC, no keys.
Run from the repository root:
  A3A_ENGINE_DIR=$HOME/.foundry/bin python3 -B script/upgrade/audit/test_audit_findings.py
"""
import sys
sys.dont_write_bytecode = True
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent), str(HERE.parents[1]/'a3a')]
import test_manifest_exec as tm  # noqa: E402  (fixture source; its tests are not re-run here)

m, a, u = tm.m, tm.a, tm.u


class AuditFixture(unittest.TestCase):
    """Borrow ManifestTests' synthetic pin/inputs/plan without inheriting its tests."""

    def setUp(self):
        self.base = tm.ManifestTests('test_determinism')
        self.base.setUp()
        self.addCleanup(self.base.doCleanups)
        self.pin, self.data, self.inputs, self.plan = (self.base.pin, self.base.data,
                                                       self.base.inputs, self.base.plan)

    def rebuild(self, data=None, pin=None):
        path = self.base.path
        path.write_text(json.dumps(data if data is not None else self.data))
        return m.build_plan(pin if pin is not None else self.pin, m.external(path))


class F01SampledOperators(AuditFixture):
    @unittest.expectedFailure
    def test_F01_sampled_set_must_be_deployer_only(self):
        """F-01 (Medium). MANIFEST-DESIGN.md section 3 Phase C (DSR 2026-11-02): "D is the only
        sampled operator. B3 unpauses D only; N stays paused". The executor accepts any
        nonempty subset of the pause list, and the shared fixture samples [D, Anni].

        Becomes a normal test when validate_external/build_plan rejects any `sampled`
        other than [deployer] with gate `sampled_deployer_only` (and the shared fixture
        input_data() and test_unsampled_operator_remains_paused are updated to [D])."""
        data = copy.deepcopy(self.data)
        data['sampled'] = sorted([u.DEPLOYER, m.ANNI])
        with self.assertRaises(a.Gate) as caught:
            self.rebuild(data)
        self.assertEqual(caught.exception.record['gate'], 'sampled_deployer_only')

    def test_F01_evidence_current_plan_unpauses_anni(self):
        """F-01 evidence (passes today): the derived 6c/6d activation batch contains
        setOperatorPaused(Anni, false), i.e. the packet would unpause N."""
        unpause_anni = a.calldata('setOperatorPaused(address,bool)', m.ANNI, 'false')
        self.assertIn(unpause_anni, self.plan['operations']['activation']['data'])


class F02BudgetShortfall(AuditFixture):
    @unittest.expectedFailure
    def test_F02_budget_stop_reports_exact_shortfall(self):
        """F-02 (Low). Section 4 / section 6: "If it is short, STOP and report the exact
        shortfall". budget() raises gate `budget_deployer` with observed=False and
        expected=True; the shortfall in wei is not reported anywhere.

        Becomes a normal test when the `budget_<label>` gate record's `observed` is a
        dict carrying `shortfallWei` (required - balance)."""
        plan = copy.deepcopy(self.plan)
        for step in plan['steps']:
            tm.freeze_gas(plan, step)
        m.budget(plan)
        required = plan['budgetsWei']['deployer']
        plan['pin']['senders']['deployer']['balance'] = required - 1
        with self.assertRaises(a.Gate) as caught:
            m.budget(plan)
        record = caught.exception.record
        self.assertEqual(record['gate'], 'budget_deployer')
        self.assertIsInstance(record['observed'], dict)
        self.assertEqual(record['observed'].get('shortfallWei'), 1)


class F03TokenEtaBinding(AuditFixture):
    @unittest.expectedFailure
    def test_F03_pending_token_eta_bound_to_reviewed_value(self):
        """F-03 (Low). Section 2 / section 4: SP `pendingAPNTsTokenEta == 1794226596`
        (S7 block 12048088). The value is only read from the pin and type-checked
        (u.validate_pin pin_integer); any other ETA silently re-derives the 6c schedule
        floor (activationScheduleNotBefore) instead of stopping.

        Becomes a normal test when the pin is rejected unless pendingAPNTsTokenEta equals
        the reviewed literal, with gate `pin_pending_token_eta` (fixtures then use the
        literal)."""
        pin = copy.deepcopy(self.pin)
        pin['pendingAPNTsTokenEta'] = 1794226596 + 3600
        with self.assertRaises(a.Gate) as caught:
            self.rebuild(pin=pin)
        self.assertEqual(caught.exception.record['gate'], 'pin_pending_token_eta')

    def test_F03_evidence_schedule_floor_follows_any_eta(self):
        """F-03 evidence (passes today): a shifted ETA is accepted and moves the floor."""
        pin = copy.deepcopy(self.pin)
        pin['pendingAPNTsTokenEta'] = 1794226596 + 3600
        plan = self.rebuild(pin=pin)
        self.assertEqual(plan['activationScheduleNotBefore'], 1794226596 + 3600 - u.DELAY)


class F04OldAggregatorPolicyAdmin(AuditFixture):
    @unittest.expectedFailure
    def test_F04_collect_reads_back_old_slash_policy_admin(self):
        """F-04 (Low). Section 3 Phase D: old BLSAggregator "Ownable, owner D;
        `slashPolicyAdmin` also D (read back)". collect() reads the old aggregator's
        owner() (gate old_aggregator_owner) but never slashPolicyAdmin(); a pin whose old
        slashPolicyAdmin is a third party is accepted.

        Becomes a normal test when collect() reads slashPolicyAdmin() on the old
        aggregator at the pin and requires the deployer, with gate
        `old_aggregator_slash_policy_admin`."""
        stranger = '0x' + '77'*20
        history = self.base.history_rpc()
        def rpc(method, params):
            if method == 'eth_getBalance': return '0x100'
            if method == 'eth_getStorageAt': return '0x'+m.ANNI[2:].zfill(64)
            return history(method, params)
        def address(rpc, target, sig, block):
            if sig == 'slashPolicyAdmin()':
                return stranger
            return u.DEPLOYER if sig == 'owner()' else m.OLD_AGGREGATOR
        def word(rpc, target, sig, *args, **kw):
            if sig == 'MAX_VALIDATORS()': return 13
            if sig == 'validatorAtSlot(uint8)': return args[0] if args[0] <= 3 else 0
            raise AssertionError(sig)
        def call(rpc, target, sig, *args, **kw):
            if sig == 'version()': return a.cast('abi-encode', 'c(string)', 'Registry-5.8.0')
            if sig.startswith('getDepositInfo'):
                return a.cast('abi-encode', 'c(uint256,bool,uint256,uint256,uint256)', 1, 'true', 1, 86400, 0)
            raise AssertionError(sig)
        with patch.object(u, 'collect', return_value=copy.deepcopy(self.pin)), \
             patch.object(a, 'nonce', return_value=55), \
             patch.object(u, 'code', side_effect=lambda r, t, b: '0x' if t == m.ANNI else '0x6000'), \
             patch.object(a, 'call', side_effect=call), patch.object(a, 'word', side_effect=word), \
             patch.object(a, 'address', side_effect=address), patch.object(m, 'old_activity', return_value={}), \
             patch.object(m, 'dvt_activity', return_value=[]), \
             patch.object(m, 'balances', return_value={k: self.pin[k] for k in
                          ('totalTrackedBalance', 'protocolRevenue', 'operatorBalances')}):
            with self.assertRaises(a.Gate) as caught:
                m.collect(rpc, '0x100', self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'old_aggregator_slash_policy_admin')


if __name__ == '__main__':
    unittest.main()
