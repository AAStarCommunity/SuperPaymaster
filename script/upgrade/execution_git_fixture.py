"""Test-only integrity substitution for synthetic executor plans.

Real checkout/module checks are exercised in test_execution_head/integrity.
"""
from unittest.mock import patch
import manifest_exec


def clean_checkout(test, commit):
    fixture = patch.object(manifest_exec, 'execution_tree_gates')
    fixture.start()
    test.addCleanup(fixture.stop)
