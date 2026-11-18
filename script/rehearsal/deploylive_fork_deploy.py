#!/usr/bin/env python3
"""Guarded fresh deployment; supply production inputs in the process environment."""
import os
from pathlib import Path
import subprocess
import sys
from deploylive_rehearse import RPC, ROOT, require


def main():
    require(len(sys.argv) in (3, 4), 'usage: RPC DEPLOYER [--stop]')
    url, deployer = sys.argv[1:3]
    stop = sys.argv[3:] == ['--stop']
    require(len(sys.argv) == 3 or stop, 'unknown argument')
    rpc = RPC(url)
    require(int(rpc('eth_chainId'), 16) == 31337, 'fork must use chain ID 31337')
    env = dict(os.environ, DEPLOYER_ADDRESS=deployer, DEPLOYLIVE_REHEARSAL='1', DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP='1' if stop else '0')
    name = env.get('ENV', '')
    require(name and all(c.isalnum() or c in '-_' for c in name), 'set a rehearsal ENV name')
    rpc('anvil_impersonateAccount', deployer)
    try:
        rpc('anvil_setBalance', deployer, hex(10**22))
        result = subprocess.run([
            '/Users/jason/.foundry/bin/forge', 'script', '--offline',
            'contracts/script/v3/DeployLive.s.sol:DeployLive', '--rpc-url', url,
            '--sender', deployer, '--unlocked', '--broadcast', '--slow'],
            cwd=ROOT, env=env, capture_output=True, text=True)
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
