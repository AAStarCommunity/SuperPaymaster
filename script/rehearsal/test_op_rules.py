"""Offline OP chain rules: injected transport only."""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
import deploylive_deploy_day as d
import deploylive_controls as c
import deploylive_fork_deploy as f


class OPRulesTest(unittest.TestCase):
    def test_op_bounds_never_use_amsterdam_reservoir(self):
        for chain in (10, 11155420):
            self.assertEqual(d.gas_bounds([16_000_000], 40_000_000, chain=chain), [[16_000_000, 16777216]])
            with self.assertRaises(RuntimeError):
                d.gas_bounds([16777217], 40_000_000, chain=chain)

    def test_explicit_sepolia_unchanged(self):
        values = [100, 16_000_000, 20_000_000]
        self.assertEqual(d.gas_bounds(values, 60_000_000, chain=11155111),
                         [[100, 60_000_000], [16777217, 60_000_000], [20_000_000, 60_000_000]])

    def test_explicit_sepolia_gas_output_matches_legacy_bytes(self):
        rows = [dict(transactionType='CREATE', contractName=name, transaction={'gas':hex(16777217)})
                for name in d.LARGE_CREATES]
        rows.append(dict(transactionType='CALL', contractName='LargeCall', transaction={'gas':hex(60_000_000)}))
        def run(**kwargs):
            rpc = Mock(side_effect=[dict(gasLimit=hex(60_000_000), baseFeePerGas='0x1'),
                                   [dict(calls=[dict(status='0x1', gasUsed=hex(16_000_000))]) for _ in rows]])
            lines = []
            result = d.gas_crosscheck({'transactions':rows}, rpc, 'latest', .05, lines.append, **kwargs)
            return ('\n'.join(lines) + json.dumps(result)).encode(), d.gas_bounds(result[0], result[1], **kwargs)
        # chain is a required keyword: a caller that forgets it fails instead of silently getting Amsterdam rules.
        with self.assertRaises(TypeError): run()
        # Golden computed from fc59e8d3 via git show, loaded under /tmp.
        self.assertEqual(run(chain=11155111), (b'GAS single-endpoint real-chain tolerance=0.05 multiplier=100\nGAS fees index=0 maxFeePerGas=0x3b9aca02 maxPriorityFeePerGas=0x3b9aca00\nGAS fees index=1 maxFeePerGas=0x3b9aca02 maxPriorityFeePerGas=0x3b9aca00\nGAS fees index=2 maxFeePerGas=0x3b9aca02 maxPriorityFeePerGas=0x3b9aca00\nGAS fees index=3 maxFeePerGas=0x3b9aca02 maxPriorityFeePerGas=0x3b9aca00\nGAS fees index=4 maxFeePerGas=0x3b9aca02 maxPriorityFeePerGas=0x3b9aca00\nGAS fees index=5 maxFeePerGas=0x3b9aca02 maxPriorityFeePerGas=0x3b9aca00\nGAS fees index=6 maxFeePerGas=0x3b9aca02 maxPriorityFeePerGas=0x3b9aca00\nGAS fees index=7 maxFeePerGas=0x3b9aca02 maxPriorityFeePerGas=0x3b9aca00\nGAS fees index=8 maxFeePerGas=0x3b9aca02 maxPriorityFeePerGas=0x3b9aca00\nGAS index=0 contract=Registry limit=16777217 simulated=16777217 real=16000000 tolerance=0.05\nGAS index=1 contract=xPNTsFactory limit=16777217 simulated=16777217 real=16000000 tolerance=0.05\nGAS index=2 contract=MySBT limit=16777217 simulated=16777217 real=16000000 tolerance=0.05\nGAS index=3 contract=SuperPaymaster limit=16777217 simulated=16777217 real=16000000 tolerance=0.05\nGAS index=4 contract=xPNTsTokenV2Ext limit=16777217 simulated=16777217 real=16000000 tolerance=0.05\nGAS index=5 contract=xPNTsTokenV2 limit=16777217 simulated=16777217 real=16000000 tolerance=0.05\nGAS index=6 contract=BLSAggregator limit=16777217 simulated=16777217 real=16000000 tolerance=0.05\nGAS index=7 contract=TimelockHandoverBootstrap limit=16777217 simulated=16777217 real=16000000 tolerance=0.05[[16000000, 16000000, 16000000, 16000000, 16000000, 16000000, 16000000, 16000000, 16000000], 60000000]', [[16777217, 60000000], [16777217, 60000000], [16777217, 60000000], [16777217, 60000000], [16777217, 60000000], [16777217, 60000000], [16777217, 60000000], [16777217, 60000000], [16777217, 60000000]]))

    def test_op_every_transaction_stops_before_simulation(self):
        for chain in (10, 11155420):
            for kind in ('CREATE', 'CALL'):
                rpc = Mock(side_effect=AssertionError('must stop before RPC'))
                plan = {'transactions': [dict(transactionType=kind, contractName='NamedTx', transaction={'gas':hex(16777217)})]}
                with self.assertRaisesRegex(RuntimeError, 'NamedTx'):
                    d.gas_crosscheck(plan, rpc, 'latest', .05, chain=chain)
                rpc.assert_not_called()

    def test_op_cap_control_skip_without_mutation(self):
        with tempfile.TemporaryDirectory() as tmp:
            for chain in (10, 11155420):
                rpc = Mock(side_effect=AssertionError('no mutation'))
                record = c.cap_control(rpc, Path(tmp), chain=chain)
                self.assertEqual(record['status'], 'SKIP')
                self.assertIn('Karst', record['reason'])
                self.assertFalse(record['passed'])
                rpc.assert_not_called()

    def test_op_hardfork_requires_operator_validated_allowlist(self):
        # DSR ruling 2026-11-21: only 'op:karst' (run end to end on an OP Sepolia fork with nightly 4e8874b);
        # forge also parses the alias 'optimism:karst', which stays refused.
        rules = json.loads(c.EXPECTATIONS.read_text())
        for chain in (10, 11155420):
            self.assertEqual(rules[str(chain)]['allowedHardforks'], ['op:karst'])
            c.validate_hardfork(chain, 'op:karst')
            for value in ('', 'amsterdam', 'optimism:karst', 'OP:KARST', 'op:isthmus'):
                with self.assertRaisesRegex(RuntimeError, 'validated.*hardfork'):
                    c.validate_hardfork(chain, value)
        c.validate_hardfork(11155111, 'amsterdam')

    def test_op_hardfork_supported_and_http400_unavailable(self):
        with tempfile.TemporaryDirectory() as tmp:
            for chain, fork, activation in ((10, '0xc29239af', 1783526401), (11155420, '0x91620456', 1781712001)):
                def rpc(method, *args):
                    if method == 'eth_chainId': return hex(chain)
                    if method == 'eth_blockNumber': return '0x64'
                    if method == 'eth_config': return {'current':dict(forkId=fork, activationTime=activation)}
                    return dict(number=args[0], hash='0xabc', timestamp=hex(activation+1))
                c.hardfork_check(rpc, rpc, Path(tmp))
                unavailable = f.ReadOnlyRPC('https://unused.invalid')
                unavailable.opener = Mock()
                body = json.dumps(dict(jsonrpc='2.0', id=1, error=dict(code=-32600, message='eth_config is not available'))).encode()
                unavailable.opener.open.side_effect = HTTPError('https://unused.invalid', 400, 'Bad Request', {}, io.BytesIO(body))
                def second(method, *args):
                    return unavailable(method, *args) if method == 'eth_config' else rpc(method, *args)
                result = c.hardfork_check(second, rpc, Path(tmp))
                self.assertIn('unsupported', result['endpointA']['eth_config'])

    def test_http400_other_errors_stop(self):
        for body in (b'not available -32600', b'{}', b'{"error":{"code":-32600,"message":"not available"}}',
                     b'{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"invalid request"}}',
                     b'{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"not available"}}'):
            rpc = f.ReadOnlyRPC('https://unused.invalid'); rpc.opener = Mock()
            rpc.opener.open.side_effect = HTTPError('https://unused.invalid', 400, 'Bad Request', {}, io.BytesIO(body))
            with self.assertRaisesRegex(RuntimeError, 'HTTP 400'):
                rpc('eth_config')

    def test_four_chain_pins_and_external_dependencies(self):
        for kind in ('creation', 'runtime'):
            for left, right in ((10, 31337), (11155111, 11155420)):
                with self.subTest(kind=kind, chains=(left, right)):
                    self.assertEqual((d.ROOT / f'deployments/{kind}-pins.{left}.json').read_bytes(),
                                     (d.ROOT / f'deployments/{kind}-pins.{right}.json').read_bytes())
        deps = json.loads((d.ROOT/'deployments/external-deps.11155420.json').read_text())
        original = json.loads((d.ROOT/'deployments/external-deps.11155111.json').read_text())
        self.assertEqual(deps.keys(), original.keys())
        self.assertEqual(deps['ethUsdFeed'], '0x61Ec26aA57019C486B10502285c5A3D4A4750AD7')
        for key in original.keys() - {'ethUsdFeed','source'}:
            self.assertEqual(deps[key], original[key])

    def test_op_sepolia_gas_source_allowed(self):
        with patch.object(f, 'ReadOnlyRPC', return_value=lambda *args: hex(11155420)):
            f.gate_sources({'DEPLOYLIVE_SOURCE_RPC':'unused','DEPLOYLIVE_PRICE_SOURCE':'fork'}, True, 11155420)

    def test_op_at_headroom_boundary_is_accepted(self):
        for chain in (10, 11155420):
            plan = {'transactions':[dict(transactionType='CALL', contractName='AtCap', transaction={'gas':hex(int(d.CAP_FRACTION*d.TX_GAS_CAP))})]}
            rpc = Mock(side_effect=[dict(gasLimit=hex(40_000_000), baseFeePerGas='0x1'),
                                   [dict(calls=[dict(status='0x1', gasUsed=hex(14_000_000))])]])
            with patch.object(d, 'large_creates', return_value=[]):
                self.assertEqual(d.gas_crosscheck(plan, rpc, 'latest', .05, chain=chain), ([14_000_000], 40_000_000))

    def test_op_hardfork_operator_filled_allowlist(self):
        rules = json.loads(c.EXPECTATIONS.read_text())
        rules['11155420']['allowedHardforks'] = ['op:karst']
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'rules.json'; path.write_text(json.dumps(rules))
            with patch.object(c, 'EXPECTATIONS', path):
                c.validate_hardfork(11155420, 'op:karst')
                with self.assertRaises(RuntimeError):
                    c.validate_hardfork(11155420, 'amsterdam')

    def test_broadcast_gate_propagates_op_semantics(self):
        with patch.object(d, 'price_window', return_value=('0x1', 2)), patch.object(d, 'gas_crosscheck', return_value=([16_000_000], 40_000_000)) as gas:
            result = d.broadcast_gates({'PRICE_STALENESS_THRESHOLD':'4200','ETH_USD_FEED':'unused'}, {}, None, None, chain=11155420)
        self.assertEqual(gas.call_args.kwargs['chain'], 11155420)
        self.assertEqual(result, [[16_000_000,16777216]])

    def test_op_sepolia_driver_and_production_checker_chain(self):
        import test_deploylive_round9
        rpc, run = test_deploylive_round9.Round9Test().run_fork(11155420)
        self.assertTrue(any('--broadcast' in call.args[0] for call in run.call_args_list))
        rpc.assert_any_call('eth_chainId')
        # This positive test reaches provider validation, then executable validation on the new chain.
        with tempfile.TemporaryDirectory() as tmp:
            cast = Path(tmp)/'cast'; cast.write_text('#!/bin/sh\n'); cast.chmod(0o755)
            second = Path(tmp)/'rpc'; second.write_text('https://secondary.infura.io/key')
            env = dict(DEPLOYLIVE_EXPECTED_CHAIN_ID='11155420', DEPLOYLIVE_RPC='https://primary.alchemy.com/key',
                       DEPLOYLIVE_SECOND_RPC=second.read_text(), DEPLOYLIVE_SECOND_RPC_FILE=str(second),
                       DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy', DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura', PATH='/usr/bin:/bin', CAST_1_7_1=str(cast))
            with patch('deploylive_cast.stable_cast', return_value=True):
                f.require_checker_inputs(env, 11155420, production=True)
