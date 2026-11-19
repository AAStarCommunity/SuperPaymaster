"""forge must actually reach the node through the foundry.toml alias (acceptance at 6146e343:
predict failed because forge script has no ETH_RPC_URL binding)."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import tomllib
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploylive_controls as c

ROOT = Path(__file__).resolve().parents[2]
SECRET = 'https://rpc.invalid/key-abc123'
URL_ENV = {'DEPLOYLIVE_RPC': SECRET, 'DEPLOYLIVE_SOURCE_RPC': 'https://a.invalid/k', 'DEPLOYLIVE_SECOND_RPC': 'https://b.invalid/k',
           'REHEARSAL_SOURCE_RPC': 'https://c.invalid/k', 'ETH_RPC_URL': 'https://d.invalid/k', 'PATH': os.environ.get('PATH', '')}


class AliasTest(unittest.TestCase):
    def test_foundry_toml_alias(self):
        conf = tomllib.loads((ROOT / 'foundry.toml').read_text())
        self.assertEqual(conf['rpc_endpoints']['deploylive'], '${DEPLOYLIVE_FORGE_RPC_URL}')

    def test_forge_env_has_only_the_alias_variable(self):
        cmd, env = c.forge_endpoint(['forge', 'script', 'X'], URL_ENV)
        self.assertEqual(cmd[-2:], ['--rpc-url', 'deploylive'])
        self.assertFalse(any('://' in a for a in cmd))
        endpointish = {k for k, v in env.items() if '://' in str(v)}
        self.assertEqual(endpointish, {'DEPLOYLIVE_FORGE_RPC_URL'})
        self.assertEqual(env['DEPLOYLIVE_FORGE_RPC_URL'], SECRET)

    def test_refuses_a_second_endpoint_flag(self):
        with self.assertRaises(RuntimeError):
            c.forge_endpoint(['forge', 'script', '--rpc-url', 'x'], URL_ENV)

    def test_predict_and_deploy_paths_pass_forge_env(self):
        # Both call sites must hand forge the stripped env and the alias argv.
        source = (ROOT / 'script/rehearsal/deploylive_fork_deploy.py').read_text()
        self.assertEqual(source.count('forge_endpoint(command, env)'), 2)
        for line in [l for l in source.splitlines() if 'subprocess.run(' in l and "'script'" not in l and 'forge' in l.lower() and 'postdeploy_check' not in l]:
            self.assertNotIn('env=env,', line)
        self.assertIn("env=forge_env", source)
        self.assertIn("dict(forge_env, DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP='0')", source)

    def test_safe_logs_never_writes_the_alias_url(self):
        with tempfile.TemporaryDirectory() as d:
            result = type('R', (), dict(stdout='ok ' + SECRET, stderr=''))()
            with self.assertRaises(RuntimeError):
                c.safe_logs(Path(d), 'forge', result, dict(URL_ENV))
            self.assertFalse(any(SECRET in p.read_text() for p in Path(d).glob('*')))


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close(); return port


@unittest.skipUnless(shutil.which('anvil') and shutil.which('forge'), 'needs anvil and forge on PATH')
class RealForgeReachesNodeTest(unittest.TestCase):
    """Positive control with real binaries: through the repo's own foundry.toml alias, forge reads
    the node's chain id; without the variable it refuses instead of simulating on an empty EVM."""
    def test_forge_reaches_anvil_through_alias(self):
        port = free_port(); chain = 424242
        node = subprocess.Popen(['anvil', '--port', str(port), '--chain-id', str(chain), '--silent'])
        try:
            for _ in range(50):
                try: socket.create_connection(('127.0.0.1', port), .2).close(); break
                except OSError: time.sleep(.1)
            probe = ROOT / 'contracts/test/scripts/RpcAliasProbe.s.sol'
            cmd, env = c.forge_endpoint(['forge', 'script', '--offline', f'{probe}:RpcAliasProbe'], dict(URL_ENV, DEPLOYLIVE_RPC=f'http://127.0.0.1:{port}'))
            out = subprocess.run(cmd, cwd=ROOT, env=dict(env, FOUNDRY_DISABLE_NIGHTLY_WARNING='1'), capture_output=True, text=True)
            self.assertEqual(out.returncode, 0, out.stderr[-2000:])
            self.assertIn(f'chainId: uint256 {chain}', out.stdout)
            self.assertFalse(any('127.0.0.1' in a for a in cmd))
            env.pop('DEPLOYLIVE_FORGE_RPC_URL')
            missing = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn('DEPLOYLIVE_FORGE_RPC_URL', missing.stderr + missing.stdout)
        finally:
            node.terminate(); node.wait(10)


if __name__ == '__main__':
    unittest.main()
