"""Opt-in genuine forge script / non-fork Anvil regression; all files stay in worktree."""
import json
import sys
import os
from pathlib import Path
import socket
import subprocess
import time
import unittest
from urllib.request import Request, build_opener, ProxyHandler

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT/'cache/deploylive-tests/round7'


@unittest.skipUnless(os.environ.get('DEPLOYLIVE_LOCAL_TEST') == '1', 'set DEPLOYLIVE_LOCAL_TEST=1 for local Anvil')
class LocalForgeTest(unittest.TestCase):
    def test_real_forge_config(self):
        EVIDENCE.mkdir(parents=True, exist_ok=True)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        url = f'http://127.0.0.1:{port}'
        opener = build_opener(ProxyHandler({}))
        def rpc(method, *params):
            body = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
            with opener.open(Request(url, body, {'Content-Type': 'application/json'}), timeout=30) as response:
                result = json.load(response)
            if 'error' in result: raise AssertionError(result['error'])
            return result['result']
        def run(command, name, env):
            with (EVIDENCE/name).open('w') as log:
                result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 0, (EVIDENCE/name).read_text()[-6000:])
        with (EVIDENCE/'anvil.log').open('w') as log:
            anvil = subprocess.Popen(['anvil', '--port', str(port), '--chain-id', '31337', '--hardfork', 'prague', '--silent'], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(100):
                    try: rpc('eth_chainId'); break
                    except Exception: time.sleep(.1)
                else: self.fail('local Anvil startup failed')
                sender = rpc('eth_accounts')[0]
                env = dict(os.environ, FOUNDRY_VERBOSITY='2', DEPLOYER_ADDRESS=sender,
                           DEFAULT_ARTIFACTS_OUT='out', FOUNDRY_OUT='out-round7-prague', FOUNDRY_CACHE_PATH='cache/round7-prague',
                           ENABLE_AGENT_REGISTRIES='1', AGENT_IDENTITY_REGISTRY='0x'+f'{103:040x}', AGENT_REPUTATION_REGISTRY='0x'+f'{104:040x}',
                           ENV='round7-local', ENTRY_POINT='0x0000000071727De22E5E9d8BAf0edAc6f37da032', ETH_USD_FEED='0x'+f'{100:040x}', SIMPLE_ACCOUNT_FACTORY='0x'+f'{101:040x}',
                           GOVERNANCE_OWNER='0x'+f'{200:040x}', GUARDIAN_ADDRESS='0x'+f'{202:040x}', SP_GUARDIAN='0x'+f'{203:040x}', GENESIS_AASTAR_OPERATOR='0x'+f'{204:040x}',
                           APNTS_CAP=str(10**24), GUARDIAN_N='3', GUARDIAN_MIN_THRESHOLD='2', GUARDIAN_DEFAULT_THRESHOLD='2',
                           DEPLOYLIVE_REHEARSAL='1', DEPLOYLIVE_EVM_VERSION='prague', CREATION_PINS='deployments/creation-pins.31337.json', DEPLOYER_GTOKEN_RECIPIENT='safe')
                for key in ('SLASH_POLICY_ADMIN', 'REPUTATION_OWNER', 'MPC_OWNER', 'PAYMASTER_FACTORY_OWNER'): env[key] = 'timelock'
                env['X402_OWNER'] = 'safe'
                for i in range(3): env[f'GUARDIAN_SLASH_THRESHOLD_{i}'] = '2'
                # Build the WHOLE tree into the Prague output first. With a partial build forge's
                # broadcast decoder can match a contract to a variant with a different length
                # (APNTsCapped runs=200 vs 500) and fail with "Failed to decode constructor arguments".
                run(['forge', 'build', '--offline', '--evm-version', 'prague'], 'prague-build.log', env)
                # Public deterministic test scalars only; do not increase verbosity.
                run(['forge', 'script', '--offline', 'contracts/test/scripts/DeployLiveLocalFixture.s.sol:DeployLiveLocalBundle', '--rpc-url', url, '--evm-version', 'prague', '-vv'], 'local-bundle.log', env)
                env['GUARDIANS'] = (EVIDENCE/'guardians.txt').read_text().strip()
                def code(name, folder):
                    for path in (ROOT/'out-round7-prague'/folder).glob(name+'*.json'):
                        obj = json.loads(path.read_text())
                        if obj.get('metadata', {}).get('settings', {}).get('evmVersion') == 'prague':
                            return obj['deployedBytecode']['object']
                    raise AssertionError('missing Prague fixture artifact: ' + name)
                for address, name in ((100, 'LocalDeployFeed'), (101, 'LocalDeployFactory'), (102, 'LocalDeployAccount'), (888, 'LocalExternalToken')):
                    rpc('anvil_setCode', '0x'+f'{address:040x}', code(name, 'DeployLiveLocalFixture.s.sol'))
                safe_artifact = next((ROOT/'out/Round6Safe.sol').glob('*.json'), None)
                if safe_artifact is None: safe_artifact = next((ROOT/'out/DeployLiveProduction.t.sol').glob('Round6Safe*.json'))
                rpc('anvil_setCode', env['GOVERNANCE_OWNER'], json.loads(safe_artifact.read_text())['deployedBytecode']['object'])
                official = json.loads((ROOT/'deployments/safe-official.json').read_text())
                rpc('anvil_setStorageAt', env['GOVERNANCE_OWNER'], '0x'+'0'*64, '0x'+official['singletons'][0][2:].lower().zfill(64))
                slot = subprocess.check_output(['cast', 'keccak', 'fallback_manager.handler.address'], text=True).strip()
                rpc('anvil_setStorageAt', env['GOVERNANCE_OWNER'], slot, '0x'+official['fallbackHandlers'][0][2:].lower().zfill(64))
                for address in (env['ENTRY_POINT'], '0x'+f'{103:040x}', '0x'+f'{104:040x}'):
                    rpc('anvil_setCode', address, '0x00')
                rpc('evm_mine')
                command = ['forge', 'script', '--offline', 'contracts/script/v3/DeployLive.s.sol:DeployLive', '--rpc-url', url, '--sender', sender, '--unlocked', '--broadcast', '--slow', '--evm-version', 'prague', '-vv']
                run(command, 'local-deploy.log', env)
                config = ROOT/'deployments/config.round7-local.json'
                original = config.read_bytes()
                baseline = EVIDENCE/'original-checker.py'
                if baseline.exists():
                    with (EVIDENCE/'local-checker-baseline-red.log').open('w') as old_log:
                        old = subprocess.run([sys.executable, str(baseline), url, str(config), sender, env['GOVERNANCE_OWNER']], cwd=ROOT, env=env, stdout=old_log, stderr=subprocess.STDOUT)
                    self.assertEqual(old.returncode, 1)
                    self.assertIn('FAIL  GToken ticket ledger', (EVIDENCE/'local-checker-baseline-red.log').read_text())
                run([sys.executable, 'script/rehearsal/deploylive_postdeploy_check.py', url, str(config), sender, env['GOVERNANCE_OWNER']], 'local-checker.log', env)
                self.assertEqual(config.read_bytes(), original, 'checker must use exact forge config')
                (EVIDENCE/'config.real-forge.json').write_bytes(original)
                print((EVIDENCE/'local-checker.log').read_text().splitlines()[-1])
            finally:
                anvil.terminate()
                try: anvil.wait(timeout=10)
                except subprocess.TimeoutExpired: anvil.kill(); anvil.wait()
