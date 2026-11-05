#!/usr/bin/env python3
"""Audit 2026-11-04: executable findings against the manifest executor on origin/main.

Regression tests for findings F-01..F-04 of docs/release/sp-upgrade-a6e/AUDIT-2026-11-04.md
(fixed per DSR rulings 2026-11-05; formerly expectedFailure). Each rejection asserts its exact gate.

Offline only: synthetic unit fixtures from test_manifest_exec.py, no RPC, no keys.
Run from the repository root:
  A3A_ENGINE_DIR=$HOME/.foundry/bin python3 -B script/upgrade/audit/test_audit_findings.py
"""
import sys
sys.dont_write_bytecode = True
import contextlib
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE.parent), str(HERE.parents[1]/'a3a')]
import test_manifest_exec as tm  # noqa: E402  (fixture source; its tests are not re-run here)

m, a, u = tm.m, tm.a, tm.u


class UnexpectedFixtureCall(Exception):
    """Reject an RPC/ABI call not modelled by the offline fixture."""


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
    def test_F01_sampled_set_must_be_deployer_only(self):
        """F-01: sampled must be exactly [D] (MD section 3 Phase C); gate sampled_deployer_only."""
        data = copy.deepcopy(self.data)
        data['sampled'] = sorted([u.DEPLOYER, m.ANNI])
        with self.assertRaises(a.Gate) as caught:
            self.rebuild(data)
        self.assertEqual(caught.exception.record['gate'], 'sampled_deployer_only')

    def test_F01_plan_keeps_anni_paused(self):
        """Only D is unpaused in the activation batch."""
        unpause_anni = a.calldata('setOperatorPaused(address,bool)', m.ANNI, 'false')
        self.assertNotIn(unpause_anni, self.plan['operations']['activation']['data'])


class F02BudgetShortfall(AuditFixture):
    def test_F02_budget_stop_reports_exact_shortfall(self):
        """F-02: budget STOP reports {requiredWei, balanceWei, shortfallWei} (MD section 4; DSR 2026-11-05 key names)."""
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
        observed = record['observed']
        self.assertEqual(set(observed), {'requiredWei', 'balanceWei', 'shortfallWei'})
        self.assertEqual((observed['shortfallWei'], observed['requiredWei']-observed['balanceWei']), (1, 1))


class F03TokenEtaBinding(AuditFixture):
    def test_F03_pending_token_eta_bound_to_reviewed_value(self):
        """F-03: pendingAPNTsTokenEta must equal 1794226596 (S7 block 12048088); gate pin_pending_token_eta."""
        pin = copy.deepcopy(self.pin)
        pin['pendingAPNTsTokenEta'] = 1794226596 + 3600
        with self.assertRaises(a.Gate) as caught:
            self.rebuild(pin=pin)
        self.assertEqual(caught.exception.record['gate'], 'pin_pending_token_eta')

    def test_F03_schedule_floor_uses_reviewed_eta(self):
        """The schedule floor follows the reviewed ETA."""
        pin = copy.deepcopy(self.pin)
        pin['pendingAPNTsTokenEta'] = 1794226596
        plan = self.rebuild(pin=pin)
        self.assertEqual(plan['activationScheduleNotBefore'], 1794226596 - u.DELAY)


class F04OldAggregatorPolicyAdmin(AuditFixture):
    def test_F04_collect_reads_back_old_slash_policy_admin(self):
        """F-04: old aggregator slashPolicyAdmin() read at the pin must be D; gate old_aggregator_slash_policy_admin."""
        stranger = '0x' + '77'*20
        history = self.base.history_rpc()
        def rpc(method, params):
            if method == 'eth_getBalance': return '0x100'
            if method == 'eth_getStorageAt': return '0x'+m.ANNI[2:].zfill(64)
            try:
                return history(method, params)
            except AssertionError as error:
                raise UnexpectedFixtureCall(error.args) from None
        def address(rpc, target, sig, block):
            if sig == 'slashPolicyAdmin()':
                return stranger
            return u.DEPLOYER if sig == 'owner()' else m.OLD_AGGREGATOR
        def word(rpc, target, sig, *args, **kw):
            if sig == 'MAX_VALIDATORS()': return 13
            if sig == 'validatorAtSlot(uint8)': return args[0] if args[0] <= 3 else 0
            raise UnexpectedFixtureCall(sig)
        def call(rpc, target, sig, *args, **kw):
            if sig == 'version()': return a.cast('abi-encode', 'c(string)', 'Registry-5.8.0')
            if sig.startswith('getDepositInfo'):
                return a.cast('abi-encode', 'c(uint256,bool,uint256,uint256,uint256)', 1, 'true', 1, 86400, 0)
            raise UnexpectedFixtureCall(sig)
        with patch.object(u, 'collect', return_value=copy.deepcopy(self.pin)), \
             patch.object(a, 'nonce', return_value=55), \
             patch.object(u, 'code', side_effect=lambda r, t, b: '0x' if t == m.ANNI else '0x6000'), \
             patch.object(a, 'call', side_effect=call), patch.object(a, 'word', side_effect=word), \
             patch.object(a, 'address', side_effect=address), patch.object(m, 'old_activity', return_value={}), \
             patch.object(m, 'dvt_activity', return_value=[]), \
             patch.object(m, 'balances', return_value={k: self.pin[k] for k in
                          ('totalTrackedBalance', 'protocolRevenue', 'operatorBalances')}):
            with contextlib.ExitStack() as stack:
                if hasattr(m, 'isolation'):
                    # Post-#601 main: stub old-owner isolation exactly as
                    # test_manifest_exec.test_collect_direct_fake_chain does.
                    stack.enter_context(patch.object(m.isolation, 'collect_deployed',
                                                     return_value=self.pin['oldOwnerIsolation']))
                with self.assertRaises(a.Gate) as caught:
                    m.collect(rpc, '0x100', self.inputs)
        self.assertEqual(caught.exception.record['gate'], 'old_aggregator_slash_policy_admin')


if __name__ == '__main__':
    unittest.main()
