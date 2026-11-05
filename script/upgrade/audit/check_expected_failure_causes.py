#!/usr/bin/env python3
"""Run the audit findings with expectedFailure removed and ASSERT each fails for its documented cause.

Exit 0 only if every finding test fails (not errors) with exactly the documented assertion message
and every evidence test passes. Any other cause - a different gate, an unmodelled fixture call
(UnexpectedFixtureCall), an unexpected success - exits 1 (review S-3).
Repository root: A3A_ENGINE_DIR=$HOME/.foundry/bin python3 -B script/upgrade/audit/check_expected_failure_causes.py
"""
import sys
sys.dont_write_bytecode = True
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_audit_findings as t

CAUSES = {
    'test_F01_sampled_set_must_be_deployer_only': 'AssertionError: Gate not raised',
    'test_F02_budget_stop_reports_exact_shortfall': "AssertionError: False is not an instance of <class 'dict'>",
    'test_F03_pending_token_eta_bound_to_reviewed_value': 'AssertionError: Gate not raised',
    'test_F04_collect_reads_back_old_slash_policy_admin': 'AssertionError: Gate not raised',
}

for cls in (t.F01SampledOperators, t.F02BudgetShortfall, t.F03TokenEtaBinding, t.F04OldAggregatorPolicyAdmin):
    for name in dir(cls):
        f = getattr(cls, name)
        if getattr(f, '__unittest_expecting_failure__', False):
            f.__unittest_expecting_failure__ = False
result = unittest.TextTestRunner(verbosity=0).run(unittest.defaultTestLoader.loadTestsFromModule(t))
failed = {test.id().rsplit('.', 1)[-1]: trace for test, trace in result.failures}
problems = [('error', test.id(), trace.strip().splitlines()[-1]) for test, trace in result.errors]
for name, cause in CAUSES.items():
    last = failed.get(name, '').strip().splitlines()[-1:] or ['<did not fail>']
    status = 'OK  ' if last[0] == cause else 'WRONG'
    print(f'{status} {name}: {last[0]}')
    if last[0] != cause:
        problems.append(('cause', name, last[0]))
extra = set(failed) - set(CAUSES)
problems += [('unexpected failure', name, '') for name in extra]
print('CAUSES', 'PASS' if not problems else 'FAIL ' + repr(problems))
sys.exit(1 if problems else 0)
