import io
import json
import unittest
from unittest.mock import MagicMock, patch

import calibrate as c
import derive_inputs as d
import tpm_gas_probe as p

SECRET = 'upstream https://host/v2/SECRET wss://host/SECRET'


class RpcSafety(unittest.TestCase):
    def invoke(self, module, response):
        opener = MagicMock()
        opener.open.return_value.__enter__.return_value = io.StringIO(json.dumps(response))
        with patch.object(module.urllib.request, 'build_opener', return_value=opener):
            if module is c:
                rpc = c.Fork(18555)
            elif module is d:
                with patch.object(d.Path, 'read_text', return_value='https://host/v2/SECRET'):
                    rpc = d.Provider('test', 'unused')
            else:
                rpc = p.rpc_factory('http://127.0.0.1:18555')
        return rpc('eth_call', [])

    def check_guard(self, module, error):
        # A result alongside an error makes deleting the guard return success, not KeyError.
        with self.assertRaises(error) as caught:
            self.invoke(module, {'error': {'message': SECRET, 'data': SECRET}, 'result': '0x123'})
        printed = io.StringIO()
        print(caught.exception, file=printed)
        self.assertNotIn('SECRET', printed.getvalue())
        self.assertNotIn('SECRET', str(vars(caught.exception)))

    def test_calibrate_error_guard(self):
        self.check_guard(c, c.ForkError)

    def test_derive_error_guard(self):
        self.check_guard(d, d.RpcError)

    def test_probe_error_guard(self):
        self.check_guard(p, RuntimeError)

    def test_transport_errors_are_private(self):
        for module in (c, d, p):
            with self.subTest(module=module.__name__), patch.object(module.urllib.request, 'Request', side_effect=ValueError(SECRET)):
                with self.assertRaises((RuntimeError, SystemExit)) as caught:
                    self.invoke(module, {})
                self.assertNotIn('SECRET', str(caught.exception))


class ForkIdentity(unittest.TestCase):
    def test_identity_before_writes(self):
        from calibration_safety import require_fork
        for alive, client, pin in [(True, 'anvil/v1', 123), (False, 'anvil/v1', 123),
                                   (True, 'geth/v1', 123), (True, 'anvil/v1', 124), (True, 'anvil/v1', None)]:
            proc = MagicMock()
            proc.poll.return_value = None if alive else 1
            rpc = MagicMock(side_effect=lambda method, params: {
                'web3_clientVersion': client,
                'anvil_nodeInfo': {'forkConfig': {'forkBlockNumber': pin}},
            }[method])
            with self.subTest(alive=alive, client=client, pin=pin):
                if alive and client.startswith('anvil') and pin == 123:
                    require_fork(proc, rpc, 123)
                else:
                    with self.assertRaisesRegex(SystemExit, 'STOP'):
                        require_fork(proc, rpc, 123)
                self.assertTrue(all(call.args[0] in ('web3_clientVersion', 'anvil_nodeInfo', 'anvil_metadata') for call in rpc.call_args_list))

    def test_metadata_fallback_and_liveness_race(self):
        from calibration_safety import require_fork
        proc = MagicMock()
        proc.poll.return_value = None
        def rpc(method, params):
            if method == 'web3_clientVersion': return 'anvil/v1'
            if method == 'anvil_nodeInfo': raise RuntimeError('unsupported')
            return {'forkedNetwork': {'forkBlockNumber': '0x7b'}}
        require_fork(proc, rpc, 123)
        proc.poll.side_effect = [None, 1]
        with self.assertRaisesRegex(SystemExit, 'STOP'):
            require_fork(proc, rpc, 123)

class LifecycleSafety(unittest.TestCase):
    def test_start_rejects_wrong_pin_and_uses_chosen_port(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            upstream = Path(tmp)/'upstream'
            upstream.write_text('https://host/v2/SECRET')
            fork = c.Fork(9999)
            with patch.object(c, 'choose_port', return_value=18432), patch.object(c.subprocess, 'Popen') as popen, \
                 patch.object(c.threading, 'Thread'), patch.object(c.Fork, 'stop') as stop, \
                 patch.object(c.Fork, '__call__', side_effect=lambda method, params: {
                     'eth_chainId': hex(11155420), 'web3_clientVersion': 'anvil/v1',
                     'anvil_nodeInfo': {'forkConfig': {'forkBlockNumber': 124}},
                 }[method]):
                popen.return_value.poll.return_value = None
                with self.assertRaisesRegex(SystemExit, 'STOP'):
                    fork.start(upstream, 123, Path(tmp)/'log', 11155420)
                stop.assert_called_once()
                argv = popen.call_args.args[0]
                self.assertEqual(argv[argv.index('--port') + 1], '18432')
                self.assertEqual(fork.url, 'http://127.0.0.1:18432')

    def test_runner_checks_child_before_mutation(self):
        from types import SimpleNamespace
        runner = object.__new__(c.Runner)
        runner.args = SimpleNamespace(pin=123)
        runner.fork = MagicMock()
        runner.fork.proc.poll.return_value = 1
        for method in ('anvil_setBalance', 'evm_revert', 'eth_sendTransaction'):
            with self.assertRaisesRegex(SystemExit, 'STOP'):
                runner.rpc(method, [])
        runner.fork.assert_not_called()

    def test_probe_refuses_foreign_endpoint_before_any_write(self):
        import tempfile
        from pathlib import Path
        for dead, client, block in [(True, 'anvil/v1', 123), (False, 'geth/v1', 123), (False, 'anvil/v1', 124)]:
            with self.subTest(dead=dead, client=client, block=block), tempfile.TemporaryDirectory() as tmp:
                upstream = Path(tmp)/'upstream'
                upstream.write_text('wss://host/SECRET')
                case = dict(upstream=str(upstream), block=123, anvil='mock', name='case')
                rpc = MagicMock(side_effect=lambda method, params: {
                    'eth_chainId': hex(11155420), 'web3_clientVersion': client,
                    'anvil_nodeInfo': {'forkConfig': {'forkBlockNumber': block}},
                }[method])
                with patch.object(p, 'choose_port', return_value=18432), patch.object(p.subprocess, 'Popen') as popen, \
                     patch.object(p.threading, 'Thread'), patch.object(p, 'rpc_factory', return_value=rpc):
                    popen.return_value.poll.return_value = 1 if dead else None
                    if dead:
                        self.assertIn('exited', p.run_case(case, {'chainId': 11155420}, tmp, 9999)['error'])
                    else:
                        with self.assertRaisesRegex(SystemExit, 'STOP'):
                            p.run_case(case, {'chainId': 11155420}, tmp, 9999)
                    argv = popen.call_args.args[0]
                    self.assertEqual(argv[argv.index('--port') + 1], '18432')
                    self.assertFalse(any(call.args[0] in ('anvil_setCode', 'anvil_setBalance', 'eth_sendTransaction') for call in rpc.call_args_list))
                    popen.return_value.terminate.assert_called_once()

    def test_anvil_output_never_copies_file_contents(self):
        import tempfile
        from pathlib import Path
        # Run the actual capture target synchronously with mocked process output.
        with tempfile.TemporaryDirectory() as tmp:
            upstream = Path(tmp)/'upstream'
            upstream.write_text('BARE_FILE_SECRET')
            log = Path(tmp)/'log'
            def thread(*, target, args, **kwargs):
                target(*args)
                return MagicMock()
            with patch.object(c, 'choose_port', return_value=18432), patch.object(c.subprocess, 'Popen') as popen, \
                 patch.object(c.threading, 'Thread', side_effect=thread), \
                 patch.object(c.Fork, '__call__', side_effect=lambda method, params: {
                     'eth_chainId': hex(11155420), 'web3_clientVersion': 'anvil/v1',
                     'anvil_nodeInfo': {'forkConfig': {'forkBlockNumber': 123}},
                 }[method]):
                popen.return_value.poll.return_value = None
                popen.return_value.stdout = [b'https://host/v2/SECRET wss://host/SECRET BARE_FILE_SECRET\n']
                c.Fork(9999).start(upstream, 123, log, 11155420)
            self.assertNotIn('SECRET', log.read_text())

class SharedRedaction(unittest.TestCase):
    def test_all_url_schemes_and_opaque_contents(self):
        from calibration_safety import redact, read_upstream
        for text in (SECRET, SECRET.upper(), 'ws://host/SECRET http://host/SECRET'):
            printed = io.StringIO()
            print(redact(text), file=printed)
            self.assertNotIn('SECRET', printed.getvalue())
        self.assertNotIn('BARE_FILE_SECRET', redact('BARE_FILE_SECRET', opaque=True))
        with patch('calibration_safety.Path.read_text', side_effect=ValueError('BARE_FILE_SECRET')):
            with self.assertRaises(SystemExit) as caught:
                read_upstream('unused')
            self.assertNotIn('SECRET', str(caught.exception))
