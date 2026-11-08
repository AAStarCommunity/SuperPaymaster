"""Test-only integrity substitution for synthetic executor plans.

Real checkout/module checks are exercised in test_execution_head/integrity.
"""
from unittest.mock import patch
import execution_integrity


def clean_checkout(test, commit):
    fixture = patch.object(execution_integrity, 'check')
    fixture.start()
    test.addCleanup(fixture.stop)
