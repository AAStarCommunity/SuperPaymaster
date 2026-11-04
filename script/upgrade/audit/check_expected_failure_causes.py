#!/usr/bin/env python3
"""Run the audit findings with expectedFailure removed, to show each fails for its documented cause.
Repository root: A3A_ENGINE_DIR=$HOME/.foundry/bin python3 -B script/upgrade/audit/check_expected_failure_causes.py"""
import sys, unittest
sys.path.insert(0, 'script/upgrade/audit')
import test_audit_findings as t
for cls in (t.F01SampledOperators, t.F02BudgetShortfall, t.F03TokenEtaBinding, t.F04OldAggregatorPolicyAdmin):
    for name in dir(cls):
        f = getattr(cls, name)
        if getattr(f, '__unittest_expecting_failure__', False):
            f.__unittest_expecting_failure__ = False
r = unittest.TextTestRunner(verbosity=0).run(unittest.defaultTestLoader.loadTestsFromModule(t))
