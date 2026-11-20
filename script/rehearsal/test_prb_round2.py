"""Exercise the actual checker local boundary without invoking any transport."""
import ast
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import deploylive_readback as r
import test_deploylive_local as local_tests

PIN = '0x'+'12'*32
BLOCK = dict(hash=PIN, number='0x20')

class RoundTwo(unittest.TestCase):
    def local(self, block=BLOCK, requested=PIN):
        path = Path(__file__).with_name('deploylive_postdeploy_check.py')
        tree = ast.parse(path.read_text())
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'local')
        transport = Mock(return_value=SimpleNamespace(returncode=0, stdout='[]'))
        scope = dict(block=block, requested_hash=requested, log_heights=set(), RPC='unused', LOCAL=set(),
                     subprocess=SimpleNamespace(run=transport), os=os, json=json, re=__import__('re'))
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(path), 'exec'), scope)
        return scope['local'], transport, scope

    def test_unknown_request_never_reaches_transport(self):
        local, transport, _ = self.local()
        with self.assertRaises(ValueError): local('rpc', 'eth_unrecognized', '{}')
        transport.assert_not_called()

    def test_header_requests_refused(self):
        for method, selector in [('eth_getBlockByNumber', tag) for tag in ('latest','pending','safe','finalized','0x21','0x1')] + [('eth_getBlockByHash','0x'+'34'*32)]:
            with self.subTest(method=method, selector=selector):
                local, transport, _ = self.local()
                with self.assertRaises(ValueError): local('rpc', method, selector, 'false')
                transport.assert_not_called()
        local, transport, _ = self.local()
        local('rpc', 'eth_getBlockByNumber', '0x20', 'false')
        local('rpc', 'eth_getBlockByHash', PIN, 'false')
        self.assertEqual(transport.call_count, 2)

    def test_header_arity_refused(self):
        for args in [('eth_getBlockByHash',PIN), ('eth_getBlockByNumber','0x20','false','extra'), ('eth_getBlockByHash',PIN,'true')]:
            with self.subTest(args=args):
                local, transport, _ = self.local()
                with self.assertRaises(ValueError): local('rpc', *args)
                transport.assert_not_called()

    def test_initial_resolution_refuses_unrequested_hash_or_number(self):
        for method, selector in [('eth_getBlockByHash','0x'+'34'*32), ('eth_getBlockByNumber','latest'), ('eth_getBlockByNumber','0x20')]:
            with self.subTest(method=method, selector=selector):
                local, transport, _ = self.local(block=None)
                with self.assertRaises(ValueError): local('rpc', method, selector, 'false')
                transport.assert_not_called()

        local, transport, _ = self.local(block=None)
        local('rpc', 'eth_getBlockByHash', PIN, 'false')
        transport.assert_called_once()

    def test_only_returned_log_heights_allowed(self):
        local, transport, scope = self.local()
        transport.return_value.stdout = json.dumps([dict(blockNumber='0x10')])
        local('rpc', 'eth_getLogs', json.dumps(dict(fromBlock='0x1',toBlock='0x20')))
        local('rpc', 'eth_getBlockByNumber', '0x10', 'false')
        transport.reset_mock()
        with self.assertRaises(ValueError): local('rpc', 'eth_getBlockByNumber', '0xf', 'false')
        transport.assert_not_called()

    def test_logs_cannot_authorize_future_or_outside_query_header(self):
        for number in ('0x21', '0x0'):
            with self.subTest(number=number):
                local, transport, _ = self.local()
                transport.return_value.stdout = json.dumps([dict(blockNumber=number)])
                with self.assertRaises(ValueError):
                    local('rpc', 'eth_getLogs', json.dumps(dict(fromBlock='0x1',toBlock='0x20')))

    def test_enabled_local_socket_failure_fails(self):
        with patch.dict(os.environ, DEPLOYLIVE_LOCAL_TEST='1'), patch.object(local_tests.socket, 'socket', side_effect=OSError('injected')):
            with self.assertRaises(AssertionError):
                try: local_tests.LocalForgeTest().run_real_forge_config()
                except unittest.SkipTest as error: raise RuntimeError('enabled acceptance skipped') from error

    def test_enabled_local_anvil_start_failure_fails(self):
        with patch.dict(os.environ, DEPLOYLIVE_LOCAL_TEST='1'), patch.object(local_tests.socket, 'socket'), patch.object(local_tests.subprocess, 'Popen', side_effect=OSError('injected')):
            with self.assertRaises(AssertionError):
                try: local_tests.LocalForgeTest().run_real_forge_config()
                except unittest.SkipTest as error: raise RuntimeError('enabled acceptance skipped') from error

    def test_enabled_local_anvil_timeout_fails(self):
        with patch.dict(os.environ, DEPLOYLIVE_LOCAL_TEST='1'), patch.object(local_tests.socket, 'socket'), patch.object(local_tests.subprocess, 'Popen'), patch.object(local_tests, 'build_opener') as opener, patch.object(local_tests.time, 'sleep'):
            opener.return_value.open.side_effect = OSError('injected')
            with self.assertRaises(AssertionError):
                try: local_tests.LocalForgeTest().run_real_forge_config()
                except unittest.SkipTest as error: raise RuntimeError('enabled acceptance skipped') from error
