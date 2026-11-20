"""Offline planner/final-checker boundary regressions."""
import os
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import plan_three_arm as q
from pinned_tools import PinnedTools

PIN = '0x' + '12' * 32

def checker_config():
    address = lambda n: '0x'+format(n,'040x')
    return dict(commit='a'*40, guardianN=2, deployer=address(1), governanceOwner=address(6),
                genesisOperator=address(2), superPaymaster=address(5), pnts=address(0),
                guardians=[address(3),address(4)], stakeAccounts=[address(1),address(2),address(3),address(4)])


class CheckerIntegration(unittest.TestCase):
    def tools(self):
        with patch.dict(os.environ, {'PATH': os.environ['PATH']}, clear=True):
            tools = PinnedTools()
        tools.env.update(DEPLOYLIVE_SECOND_RPC_FILE='cache/second-rpc', DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura')
        return tools

    def invoke(self, tools, output=None):
        cfg = checker_config()
        self.calls = []
        def runner(command, **kwargs):
            self.calls.append((command, kwargs))
            return SimpleNamespace(returncode=0, stdout=output or f'SNAPSHOT_BLOCK_HASH {PIN}\nSUMMARY 299 passed, 0 failed, 299 total')
        with patch.object(q, 'authenticate_checker', return_value={}):
            return q.run_checker('config', cfg, 'unused', 11155111, runner=runner,
                                 commit_reader=lambda: cfg['commit'], block=PIN, tools=tools)

    def test_production_inputs_forwarded(self):
        inputs = dict(DEPLOYLIVE_SECOND_RPC_FILE='cache/second-rpc', DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura',
                      DEPLOYLIVE_LOCAL_EVIDENCE='cache/local', DEFAULT_ARTIFACTS_OUT='out')
        with patch.dict(os.environ, inputs):
            tools = PinnedTools()
        for key, value in inputs.items(): self.assertEqual(tools.env.get(key), value)
        result = self.invoke(tools)
        self.assertEqual(result['snapshotBlockHash'], PIN)
        for key, value in inputs.items(): self.assertEqual(self.calls[0][1]['env'][key], value)

    def test_each_missing_production_input_stops_before_process(self):
        for key in ('DEPLOYLIVE_SECOND_RPC_FILE', 'DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER'):
            tools = self.tools(); del tools.env[key]
            with self.subTest(key=key):
                with self.assertRaisesRegex(q.a.Gate, 'rq3_checker_execution.*'+key):
                    self.invoke(tools)
                self.assertEqual(self.calls, [])

    def test_snapshot_identity_required(self):
        for line in ('', 'SNAPSHOT_BLOCK_HASH 0x'+'34'*32, f'SNAPSHOT_BLOCK_HASH {PIN}\nSNAPSHOT_BLOCK_HASH {PIN}'):
            with self.subTest(line=line), self.assertRaises(q.a.Gate):
                self.invoke(self.tools(), line+'\nSUMMARY 299 passed, 0 failed, 299 total')

    def test_count_one_more_or_less_rejected(self):
        # A committed mapping change adds one runtime row. The expected value
        # must follow that input even when the checker output looks plausible.
        original_load = q.load
        def load(path):
            value = original_load(path)
            if str(path).endswith('readback-artifacts.json'):
                value = dict(value, extraRuntime='ERC1967Proxy')
            return value
        with patch.object(q, 'load', side_effect=load):
            for count in (299, 301):
                with self.subTest(count=count), self.assertRaises(q.a.Gate):
                    self.invoke(self.tools(), f'SNAPSHOT_BLOCK_HASH {PIN}\nSUMMARY {count} passed, 0 failed, {count} total')
            self.assertEqual(self.invoke(self.tools(), f'SNAPSHOT_BLOCK_HASH {PIN}\nSUMMARY 300 passed, 0 failed, 300 total')['total'], 300)

    def test_endpoint_override_survives_without_ambient_environment(self):
        tools = self.tools(); calls = []
        tools.runner = lambda command, **kw: calls.append(kw)
        tools.run(['cast', 'rpc', 'eth_chainId'], env={'ETH_RPC_URL':'http://127.0.0.1:1', 'GIT_DIR':'bad'})
        self.assertEqual(calls[0]['env']['ETH_RPC_URL'], 'http://127.0.0.1:1')
        self.assertNotIn('GIT_DIR', calls[0]['env'])
