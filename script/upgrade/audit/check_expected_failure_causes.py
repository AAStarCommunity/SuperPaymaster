#!/usr/bin/env python3
"""Require all four audit findings to pass without expectedFailure markers.

Exit 1 for a retained marker, failure, error or skipped finding.
Run from the repository root with A3A_ENGINE_DIR=$HOME/.foundry/bin.
"""
import sys
sys.dont_write_bytecode = True
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_audit_findings as t

FINDINGS = (
    (t.F01SampledOperators, 'test_F01_sampled_set_must_be_deployer_only'),
    (t.F02BudgetShortfall, 'test_F02_budget_stop_reports_exact_shortfall'),
    (t.F03TokenEtaBinding, 'test_F03_pending_token_eta_bound_to_reviewed_value'),
    (t.F04OldAggregatorPolicyAdmin, 'test_F04_collect_reads_back_old_slash_policy_admin'),
)

marked = [name for cls, name in FINDINGS
          if getattr(cls, '__unittest_expecting_failure__', False)
          or getattr(getattr(cls, name), '__unittest_expecting_failure__', False)]
result = unittest.TextTestRunner(verbosity=0).run(unittest.defaultTestLoader.loadTestsFromModule(t))
passed = result.wasSuccessful() and not marked and not result.expectedFailures and not result.skipped
print('FINDINGS', 'PASS' if passed else 'FAIL', 'expectedFailure markers:', marked)
sys.exit(0 if passed else 1)
