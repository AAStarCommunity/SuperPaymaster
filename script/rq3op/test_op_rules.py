"""Offline F1 permissions and OP transaction caps."""
import unittest
from unittest.mock import patch
import plan_three_arm as q
import test_three_arm


class OPPlannerTest(unittest.TestCase):
    def test_registered_op_caps(self):
        for chain in (10,11155420):
            self.assertEqual(q.transaction_gas_cap(chain, 40_000_000), 16777216)

    def test_f1_permission_gate_runs_before_other_input_checks(self):
        fixture = test_three_arm.ThreeArm(); fixture.setUp()
        fixture.rpc.chainId = hex(1)
        with patch.object(q, 'check_entrypoint_pin'), patch.dict(q.ENTRYPOINT_PIN, chainIds=[1]):
            with self.assertRaisesRegex(Exception, 'rq3_f1_chain'):
                fixture.build()
        for chain in (10,11155111,11155420,31337):
            q.require_f1_chain(chain)
