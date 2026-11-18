import unittest
from unittest.mock import patch
import deploylive_rehearse as r

class ModesTest(unittest.TestCase):
    def test_governance_cannot_execute_before_delay(self):
        calls = []
        class RPC:
            delay = 172800
            warped = False
            def __call__(self, method, *args):
                calls.append((method, *args))
                if method == 'evm_increaseTime': self.warped = True
                if method == 'eth_call': raise r.RPCRevert('sig|TimelockUnexpectedOperationState(bytes32,bytes32)')
            def call(self, target, sig, *args):
                return '0x' + f'{self.delay:064x}'
            def send(self, sender, data, to):
                calls.append(('send', data))
                if self.warped: self.delay = 172801
        with patch.object(r, 'cast', side_effect=lambda *args: '|'.join(map(str, args))):
            r.governance(RPC(), {'timelockController': 'tl'}, 'safe')
        self.assertIn(('evm_increaseTime', 172800), calls)
        self.assertEqual(len([c for c in calls if c[0] == 'send']), 2)

    def test_governance_transport_error_is_not_a_delay_revert(self):
        class RPC:
            def __call__(self, *args):
                if args[0] == 'eth_call': raise RuntimeError('transport failure')
            def call(self, *args): return '0x' + f'{172800:064x}'
            def send(self, *args): return None
        with patch.object(r, 'cast', return_value='0x12345678'), self.assertRaisesRegex(RuntimeError, 'transport failure'):
            r.governance(RPC(), {'timelockController': 'tl'}, 'safe')

    def test_failure_uses_storage_write_and_predicted_nonce(self):
        calls = []
        class RPC:
            def __call__(self, method, *args):
                calls.append((method, *args))
                if method == 'eth_getCode': return '0x'
                if method == 'eth_getTransactionCount': return '0x16'
                if method == 'eth_getLogs':
                    return [dict(blockNumber='0x1', logIndex=hex(i), topics=['RoleGranted(bytes32,address,address)', role+'()', '0x'+(tl if i == 0 else h)[2:].zfill(64)]) for i, role in enumerate(('DEFAULT_ADMIN_ROLE', *r.ROLES))]
            def call(self, target, sig, *args):
                return '0x'+f'{1:064x}' if sig.startswith('hasRole') else sig
            def send(self, *args, **kwargs):
                calls.append(('send', args, kwargs)); return {'status': '0x0'}
        tl, h = '0x'+'11'*20, '0x'+'22'*20
        cfg = dict(registry='reg', handoverBootstrap=h, timelockController=tl, deploymentStartBlock=1, handoverBootstrapNonce='22', handoverCreationCode='0x1234')
        with patch.object(r, 'cast', side_effect=lambda kind, value: value):
            r.fail_bootstrap(RPC(), cfg, 'deployer')
        self.assertTrue(any(c[0] == 'anvil_setStorageAt' for c in calls))
        send = next(c for c in calls if c[0] == 'send')
        self.assertEqual(send[2], dict(nonce=22, expected_status=0))
        self.assertEqual(send[1], ('deployer', '0x1234'))

    def test_round7_failure_external_tokens_option(self):
        import json
        import os
        import sys
        import tempfile
        from pathlib import Path
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory(dir=r.ROOT/'cache/deploylive-tests/round7') as tmp:
            root = Path(tmp)
            config = root/'config.json'; config.write_text('{}')
            tokens = root/'tokens.json'
            groups = {'31337': [{'label': 'fixture', 'address': '0x'+'88'*20, 'decimals': 18}]}
            tokens.write_text(json.dumps(groups))
            captured = []
            def inventory(rpc, cfg, emit):
                captured.append(cfg.get('externalTokens'))
                emit('PASS external tokens')
                return cfg.get('externalTokens') == groups
            argv = ['driver', 'failure', 'http://127.0.0.1:12345', str(config), 'deployer', 'safe', '--external-tokens', str(tokens)]
            env = {'DEPLOYLIVE_EVIDENCE_DIR': str(root), 'REHEARSAL_BLS_SCALARS': '[123456789]', 'REHEARSAL_SOURCE_RPC': 'http://source.invalid/token', 'FOUNDRY_VERBOSITY': '2'}
            with patch.object(sys, 'argv', argv), patch.dict(os.environ, env), patch.object(r, 'RPC', return_value=lambda *a: '0x7a69'), patch.object(r, 'fail_bootstrap'), patch.object(r, 'scan_evidence'), patch('deploylive_failed_set_check.inventory', side_effect=inventory), patch.object(r.subprocess, 'run', side_effect=[SimpleNamespace(returncode=0), SimpleNamespace(returncode=1, stdout='FAIL expected failed H')]):
                r.main()
            self.assertEqual(captured, [groups])
