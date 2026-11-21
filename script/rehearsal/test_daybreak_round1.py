"""Daybreak regression tests; all transports are injected."""
import io
import inspect
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError
import deploylive_controls as c
import deploylive_deploy_day as d
import deploylive_fork_deploy as f
import deploylive_rehearse as r
import test_ddf4


class DaybreakTest(unittest.TestCase):
    def transport(self, envelope, http=False, local=False):
        rpc = object.__new__(r.RPC) if local else f.ReadOnlyRPC('https://unused.invalid')
        rpc.url = 'https://unused.invalid'
        rpc.opener = Mock()
        raw = json.dumps(envelope).encode()
        if http:
            rpc.opener.open.side_effect = HTTPError(rpc.url, 400, 'Bad Request', {}, io.BytesIO(raw))
        else:
            rpc.opener.open.return_value = io.BytesIO(raw)
        return rpc

    def check_config(self, envelope, http=False):
        transport = self.transport(envelope, http)
        primary = test_ddf4.Ddf4Test().rpc()
        def second(method, *args):
            return transport(method, *args) if method == 'eth_config' else primary(method, *args)
        with tempfile.TemporaryDirectory() as tmp:
            return c.hardfork_check(primary, second, Path(tmp))

    def test_message_digits_are_not_method_not_found(self):
        with self.assertRaises(RuntimeError):
            self.check_config(dict(jsonrpc='2.0', id=1, error=dict(code=-32000, message='upstream -32601')))

    def test_structured_method_not_found_evidence(self):
        result = self.check_config(dict(jsonrpc='2.0', id=1, error=dict(code=-32601, message='missing')))
        self.assertEqual(result['endpointB']['eth_config'], 'eth_config unsupported (-32601) → header-field rule')

    def test_http400_method_not_found_stops(self):
        with self.assertRaises(RuntimeError):
            self.check_config(dict(jsonrpc='2.0', id=1, error=dict(code=-32601, message='missing')), True)

    def test_malformed_method_not_found_stops(self):
        base = dict(jsonrpc='2.0', id=1, error=dict(code=-32601, message='missing'))
        for envelope in (dict(base, id=2), dict(base, id=True), dict(base, jsonrpc='1.0'), dict(base, result=None),
                         dict(base, error=dict(code='-32601', message='missing')), dict(base, error=dict(code=-32601))):
            with self.subTest(envelope=envelope), self.assertRaises(RuntimeError):
                self.check_config(envelope)

    def test_both_transports_raise_typed_method_not_found(self):
        for local in (False, True):
            with self.subTest(local=local), self.assertRaises(c.MethodNotFound):
                self.transport(dict(jsonrpc='2.0', id=1, error=dict(code=-32601, message='missing')), local=local)('eth_config')

    def test_karst_one_above_headroom_stops_before_simulation(self):
        for chain in (10, 11155420):
            for kind in ('CREATE', 'CALL'):
                rpc = Mock()
                plan = {'transactions':[dict(transactionType=kind, contractName='NamedTx', transaction={'gas':hex(int(d.CAP_FRACTION*d.TX_GAS_CAP)+1)})]}
                with self.subTest(chain=chain, kind=kind), self.assertRaisesRegex(RuntimeError, 'NamedTx'):
                    d.gas_crosscheck(plan, rpc, 'latest', .05, chain=chain)
                rpc.assert_not_called()

    def test_final_plan_headroom_both_sides(self):
        cap = int(d.CAP_FRACTION*d.TX_GAS_CAP)
        for chain in (10, 11155420):
            for gas in (cap, cap+1):
                plan = {'transactions':[dict(contractName='NamedTx', transaction=dict(gas=hex(gas),nonce='0x0',to='0x1',input='0x',value='0x0',chainId=hex(chain),**{'from':'0x2'}))]}
                diff = c.plan_diff(plan, plan, [[1,d.TX_GAS_CAP]], chain=chain)
                self.assertEqual(bool(diff), gas > cap)
                if diff: self.assertIn('NamedTx', str(diff))

    def test_cap_control_requires_keyword_chain(self):
        parameter = inspect.signature(c.cap_control).parameters['chain']
        self.assertEqual(parameter.kind, inspect.Parameter.KEYWORD_ONLY)
        self.assertIs(parameter.default, inspect.Parameter.empty)
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(TypeError):
            c.cap_control(Mock(), Path(tmp))

    def test_local_endpoint_op_source_stops(self):
        for source in (10, 11155420):
            with patch.object(f, 'ReadOnlyRPC', return_value=lambda *args: hex(source)):
                with self.assertRaisesRegex(RuntimeError, '31337.*OP'):
                    f.gate_sources({'DEPLOYLIVE_SOURCE_RPC':'unused','DEPLOYLIVE_PRICE_SOURCE':'fork'}, False, 31337)
