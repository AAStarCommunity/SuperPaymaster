"""Expected chain must precede planner exemptions."""
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import plan_three_arm as q

class RoundThree(unittest.TestCase):
    def test_expected_ten_endpoint_claims_local(self):
        with patch.object(q, 'load', return_value={}), patch.object(q, 'Pair') as pair, patch.object(q, 'run_checker', side_effect=RuntimeError('bypassed')) as checker:
            pair.return_value.return_value = '0x7a69'
            with self.assertRaises(q.a.Gate):
                q._generate('config', 'inputs', None, None, 'unused', None, None, None,
                            SimpleNamespace(env={'DEPLOYLIVE_EXPECTED_CHAIN_ID':'10'}))
            checker.assert_not_called()

    def test_expected_chain_crosses_sanitized_tool_boundary(self):
        from pinned_tools import PinnedTools
        from pathlib import Path
        with patch.dict('os.environ', DEPLOYLIVE_EXPECTED_CHAIN_ID='31337'), patch('pinned_tools.shutil.which', return_value='/bin/echo'), patch.object(Path, 'read_bytes', return_value=b'tool'), patch('pinned_tools.subprocess.run', return_value=SimpleNamespace(stdout='version')) as run:
            tools = PinnedTools()
            self.assertEqual(tools.env.get('DEPLOYLIVE_EXPECTED_CHAIN_ID'), '31337')
            tools.run(['checker'], env={'DEPLOYLIVE_EXPECTED_CHAIN_ID':'10'})
            self.assertEqual(run.call_args.kwargs['env']['DEPLOYLIVE_EXPECTED_CHAIN_ID'], '10')


class ExpectedChainRequired(unittest.TestCase):
    """DSR: no default — the operator must state the chain; unset stops on both sides."""
    def test_unset_is_refused(self):
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'script/rehearsal'))
        from deploylive_readback import expected_chain_id
        with self.assertRaisesRegex(ValueError, 'DEPLOYLIVE_EXPECTED_CHAIN_ID required'):
            expected_chain_id({})
        for bad in ('', '0', '010', 'ten', '-1'):
            with self.assertRaises(ValueError):
                expected_chain_id({'DEPLOYLIVE_EXPECTED_CHAIN_ID': bad})
        self.assertEqual(expected_chain_id({'DEPLOYLIVE_EXPECTED_CHAIN_ID': '11155111'}), 11155111)
