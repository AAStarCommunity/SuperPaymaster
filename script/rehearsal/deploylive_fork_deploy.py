#!/usr/bin/env python3
"""Guarded fresh deployment; supply production inputs in the process environment."""
import os
from pathlib import Path
import subprocess
import sys
from deploylive_rehearse import RPC, ROOT, require, guard_bls_verbosity


def main():
    require(len(sys.argv) in (3, 4), 'usage: RPC DEPLOYER [--stop]')
    url, deployer = sys.argv[1:3]
    stop = sys.argv[3:] == ['--stop']
    require(len(sys.argv) == 3 or stop, 'unknown argument')
    guard_bls_verbosity([], os.environ)
    rpc = RPC(url)
    chain = int(rpc('eth_chainId'), 16)
    require(chain == 31337 if stop else chain in (10, 31337), 'failure requires chain 31337; happy requires chain 10 or 31337')
    evidence = Path(os.environ['DEPLOYLIVE_EVIDENCE_DIR']).resolve()
    require(evidence.is_dir(), 'evidence directory required')
    env = dict(os.environ, DEPLOYER_ADDRESS=deployer, DEPLOYLIVE_REHEARSAL='1', DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP='1' if stop else '0', DEPLOYLIVE_EVM_VERSION='prague')
    env.setdefault('FOUNDRY_OUT', 'cache/deploylive-rehearsal-out')
    env.setdefault('FOUNDRY_CACHE_PATH', 'cache/deploylive-rehearsal-cache')
    require((ROOT / env['FOUNDRY_OUT']).resolve() != (ROOT / env.get('DEFAULT_ARTIFACTS_OUT', 'out')).resolve(), 'execution output must differ from release artifacts')
    name = env.get('ENV', '')
    require(name and all(c.isalnum() or c in '-_' for c in name), 'set a rehearsal ENV name')
    # OP's default mnemonic accounts may carry EIP-7702 delegation.
    rpc('anvil_setCode', deployer, '0x')
    rpc('anvil_impersonateAccount', deployer)
    try:
        rpc('anvil_setBalance', deployer, hex(10**22))
        result = subprocess.run([
            os.environ.get('FORGE', 'forge'), 'script', '--offline',
            'contracts/script/v3/DeployLive.s.sol:DeployLive', '--rpc-url', url,
            '--sender', deployer, '--unlocked', '--broadcast', '--slow', '--evm-version', 'prague', '-vv'],
            cwd=ROOT, env=env, capture_output=True, text=True)
        (evidence/'forge.stdout.log').write_text(result.stdout)
        (evidence/'forge.stderr.log').write_text(result.stderr)
        require(result.returncode == 0, 'deployment failed')
    finally:
        rpc('anvil_stopImpersonatingAccount', deployer)
    print('PASS deployment stopped before H' if stop else 'PASS full deployment')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('FAIL deployment (details redacted)')
        sys.exit(1)
