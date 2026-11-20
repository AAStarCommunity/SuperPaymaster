import sys
import tempfile
import unittest
from pathlib import Path
import deploylive_deploy_day as d

class CleanupTest(unittest.TestCase):
    def test_clean_configured_directories(self):
        with tempfile.TemporaryDirectory(dir=d.ROOT) as tmp:
            paths = [Path(tmp)/name for name in ('out', 'cache', 'release', 'release-cache')]
            env = dict(zip(('FOUNDRY_OUT', 'FOUNDRY_CACHE_PATH', 'DEFAULT_ARTIFACTS_OUT', 'DEFAULT_CACHE_PATH'), map(str, paths)))
            for path in paths:
                path.mkdir()
                (path/'stale.json').write_text('stale')
            d.clean_build_directories(env)
            self.assertTrue(all(not p.exists() or not list(p.iterdir()) for p in paths))

    def test_refuse_unsafe_targets_before_deleting(self):
        with tempfile.TemporaryDirectory(dir=d.ROOT) as tmp:
            sentinel = Path(tmp)/'keep'
            sentinel.write_text('keep')
            for bad in ('/', str(d.ROOT), 'cache/../out'):
                with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                    d.clean_build_directories(dict(FOUNDRY_OUT=tmp, FOUNDRY_CACHE_PATH='cache/prague', DEFAULT_ARTIFACTS_OUT=bad))
                self.assertTrue(sentinel.exists())

class PriceSourceTest(unittest.TestCase):
    def test_chain_default_and_fork_selection(self):
        chain, second, fork = object(), object(), object()
        self.assertEqual(d.price_sources({}, False, chain, second, fork), (chain, second))
        self.assertEqual(d.price_sources({'DEPLOYLIVE_PRICE_SOURCE':'fork'}, False, chain, second, fork), (fork, fork))

    def test_production_refuses_fork(self):
        for mode in ('fork', 'typo'):
            with self.subTest(mode=mode), self.assertRaises(RuntimeError):
                d.price_sources({'DEPLOYLIVE_PRICE_SOURCE':mode}, True, None, None, None)

class CommandsTest(unittest.TestCase):
    def test_build_dispatch_without_rpc(self):
        import deploylive_fork_deploy as f
        from unittest.mock import patch
        with patch.object(f, 'build') as build, patch.object(f, 'RPC', side_effect=AssertionError('RPC')):
            f.stage('build', [])
            build.assert_called_once()

    def test_predict_missing_inputs_refused(self):
        import deploylive_fork_deploy as f
        from unittest.mock import patch
        with patch.dict(f.os.environ, {}, clear=True), self.assertRaisesRegex(RuntimeError, 'missing'):
            f.stage('predict', ['--evidence', 'cache/ddf2'])

    def test_redacted_command(self):
        import io
        import contextlib
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            d.print_command(['forge', 'script', '--rpc-url', 'https://secret', '--sender', '0x123'])
        self.assertNotIn('https://secret', output.getvalue())
        self.assertIn('--sender 0x123', output.getvalue())

class HandoffTest(unittest.TestCase):
    def test_staged_commands_and_scaffold(self):
        text = (d.ROOT/'script/rehearsal/DEPLOYLIVE_HANDOFF.md').read_text()
        for action in ('build', 'predict', 'deploy'):
            self.assertIn('deploylive_fork_deploy.py ' + action, text)
        self.assertIn('loopback forward proxy', text)
        self.assertIn('DEPLOYLIVE_PRICE_SOURCE=fork', text)

class PredictionOwnersTest(unittest.TestCase):
    def test_owner_choice_required_before_simulation(self):
        import deploylive_fork_deploy as f
        from unittest.mock import patch
        keys = ('DEPLOYLIVE_RPC DEPLOYER_ADDRESS ENV ENTRY_POINT ETH_USD_FEED SIMPLE_ACCOUNT_FACTORY CREATION_PINS GOVERNANCE_OWNER GUARDIAN_ADDRESS SP_GUARDIAN GENESIS_AASTAR_OPERATOR APNTS_CAP GUARDIAN_N GUARDIAN_MIN_THRESHOLD GUARDIAN_DEFAULT_THRESHOLD DEPLOYLIVE_HARDFORK GUARDIAN_SLASH_THRESHOLD_0 GUARDIAN_SLASH_THRESHOLD_1 GUARDIAN_SLASH_THRESHOLD_2').split()
        with patch.dict(f.os.environ, dict.fromkeys(keys, 'fixed'), clear=True):
            with self.assertRaisesRegex(RuntimeError, 'missing input SLASH_POLICY_ADMIN'):
                f.stage('predict', ['--evidence', 'cache/ddf2'])

class PredictionExecutionTest(unittest.TestCase):
    def test_request_is_copied_without_broadcast_or_account(self):
        import contextlib
        import io
        import os
        from types import SimpleNamespace
        from unittest.mock import patch
        import deploylive_fork_deploy as f
        keys = ('DEPLOYLIVE_RPC DEPLOYER_ADDRESS ENV ENTRY_POINT ETH_USD_FEED SIMPLE_ACCOUNT_FACTORY CREATION_PINS GOVERNANCE_OWNER GUARDIAN_ADDRESS SP_GUARDIAN GENESIS_AASTAR_OPERATOR APNTS_CAP GUARDIAN_N GUARDIAN_MIN_THRESHOLD GUARDIAN_DEFAULT_THRESHOLD DEPLOYLIVE_HARDFORK GUARDIAN_SLASH_THRESHOLD_0 GUARDIAN_SLASH_THRESHOLD_1 GUARDIAN_SLASH_THRESHOLD_2 SLASH_POLICY_ADMIN X402_OWNER REPUTATION_OWNER MPC_OWNER PAYMASTER_FACTORY_OWNER DEPLOYER_GTOKEN_RECIPIENT').split()
        for production in (False, True):
            with tempfile.TemporaryDirectory(dir=d.ROOT) as tmp:
                root = Path(tmp)
                def run(command, **kwargs):
                    self.assertNotIn('--broadcast', command)
                    self.assertNotIn('--account', command)
                    self.assertEqual('--unlocked' in command, not production)
                    self.assertIn('--sender', command)
                    (root/kwargs['env']['DEPLOYLIVE_POP_REQUEST_OUT']).write_text('{"request":true}')
                    return SimpleNamespace(returncode=0, stdout="", stderr="")
                cast = root/'cast'
                cast.symlink_to(sys.executable)
                second = root/'second-rpc'
                second.write_text('https://secondary.infura.io/key')
                env = dict(dict.fromkeys(keys, 'fixed'), DEPLOYLIVE_EXPECTED_CHAIN_ID='11155111',
                           DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy', DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura',
                           DEPLOYLIVE_RPC='https://primary.alchemy.com/key', DEPLOYLIVE_SECOND_RPC=second.read_text(),
                           DEPLOYLIVE_SECOND_RPC_FILE=str(second), PATH='/usr/bin:/bin', CAST_1_7_1=str(cast))
                output = io.StringIO()
                with patch('deploylive_cast.stable_cast', return_value=True), patch.dict(os.environ, env, clear=True), patch.object(f, 'ROOT', root), patch.object(f, 'guard_bls_verbosity'), patch.object(f, 'clean_source_commit', return_value='a'*40), patch.object(f, 'verify_build', return_value='/forge') as verify, patch.object(f, 'config_path', return_value=root/'config.json'), patch.object(f.subprocess, 'run', side_effect=run), contextlib.redirect_stdout(output):
                    f.stage('predict', ['--evidence', 'evidence'] + (['--production'] if production else []))
                verify.assert_called_once()
                self.assertEqual((root/'evidence/pop-request.json').read_text(), '{"request":true}')
                self.assertIn('SHA256 ', output.getvalue())

class ProductionStageTest(unittest.TestCase):
    def test_production_stage_refuses_fork_source(self):
        from unittest.mock import patch
        import deploylive_fork_deploy as f
        with patch.dict(f.os.environ, {'DEPLOYLIVE_PRICE_SOURCE':'fork'}, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'production refuses fork'):
                f.stage('predict', ['--production', '--evidence', 'cache/ddf2'])
