#!/usr/bin/env python3
"""CC-125 Phase 2 launcher. Python 3.11; own unforked loopback anvil; no downloads.

Usage: python3.11 script/evidence/rr-matrix-run.py --out <new repo-relative dir>
       python3.11 script/evidence/rr-matrix-run.py --self-test
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
ENGINE_COMMIT = '4e8874b2bdc840929585ca73e170993c50a4a531'
DEFAULT_ENGINE = '/Users/jason/Dev/aastar/tools/foundry-rams/nightly-4e8874b/anvil'


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def manifest(out):
    files = sorted(p for p in out.rglob('*') if p.is_file() and p.name != 'SHA256SUMS')
    (out / 'SHA256SUMS').write_text(''.join(
        f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(out)}\n' for p in files))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--out', default='docs/design/aoa-balance-mode/data/rams-rr-matrix/phase2')
    parser.add_argument('--anvil', default=os.environ.get('RR_ANVIL', DEFAULT_ENGINE))
    parser.add_argument('--forge', default=os.environ.get('RR_FORGE'))
    parser.add_argument('--port', type=int, default=18952)
    parser.add_argument('--delta', type=int, default=100_000)
    parser.add_argument('--filter', default='', help='run only applicable cell IDs containing this string')
    args = parser.parse_args()
    if args.self_test:
        return subprocess.run(['node', 'script/b-layer/rr-matrix.mjs', '--self-test'], cwd=ROOT).returncode
    if not 1024 <= args.port <= 65535 or not 0 < args.delta < 30_000_000 - 2**24:
        parser.error('invalid port or reservoir delta')
    out = (ROOT / args.out).resolve()
    if not out.is_relative_to(ROOT) or out == ROOT or out.exists():
        parser.error('--out must name a new directory inside the repository')
    anvil = Path(args.anvil).resolve()
    forge = str(Path(args.forge).resolve() if args.forge else anvil.with_name('forge'))
    engine = subprocess.check_output([str(anvil), '--version'], text=True).strip()
    if ENGINE_COMMIT not in engine:
        parser.error(f'anvil must be calibrated nightly {ENGINE_COMMIT}')
    forge_version = subprocess.check_output([forge, '--version'], text=True).strip()
    if ENGINE_COMMIT not in forge_version:
        parser.error('forge must be from the same nightly (offline build/deployment)')
    out.mkdir(parents=True)
    rpc_url = f'http://127.0.0.1:{args.port}'
    header = dict(engineCommit=ENGINE_COMMIT, engine=engine, forge=forge_version,
                  repoCommit=git('rev-parse', 'HEAD'), dirtyCount=len(git('status', '--porcelain', '--untracked-files=all').splitlines()),
                  command=shlex.join(['python3.11', *sys.argv]), rpcUrl=rpc_url)
    sources = ['script/b-layer/rr-matrix.mjs', 'script/b-layer/rr-matrix-lib.mjs',
               'script/evidence/rr-matrix-run.py', 'script/b-layer/lib.mjs', 'script/b-layer/g1-lib.mjs',
               'script/b-layer/g1-setup.mjs', 'script/b-layer/ams-gasparams.mjs',
               'script/b-layer/ams-probe.mjs', 'contracts/script/v3/DeployBLayerAnvil.s.sol']
    header['scriptSha256'] = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in sources}
    (out / 'header.json').write_text(json.dumps(header, indent=2) + '\n')
    env = os.environ.copy()
    env.pop('G1_GAS_JSON', None)
    env.pop('G1_MIN_POST_OP_GAS', None)
    env.update(G1_DEPLOY_JSON=str(out / 'deploy.json'), BLAYER_CONFIG_OUT=str((out / 'deploy.json').relative_to(ROOT)),
               FOUNDRY_DISABLE_NIGHTLY_WARNING='1', FOUNDRY_PROFILE='default')

    def run(label, command):
        with (out / f'{label}.log').open('w') as log:
            log.write(json.dumps({**header, 'command': shlex.join(command), 'launcherCommand': header['command']}) + '\n')
            log.flush()
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(f'{label} failed (exit {result.returncode}); see {label}.log')

    def rpc(method, params):
        q = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
        with urllib.request.urlopen(urllib.request.Request(rpc_url, q, {'Content-Type': 'application/json'}), timeout=10) as response:
            r = json.load(response)
        if 'error' in r:
            raise RuntimeError(str(r['error']))
        return r['result']

    proc = None
    status = 0
    try:
        run('self-test', ['node', 'script/b-layer/rr-matrix.mjs', '--self-test'])
        run('dependencies', ['node', '--input-type=module', '-e', 'await import("viem");'])
        run('build', [forge, 'build', '--offline', 'contracts/script/v3/DeployBLayerAnvil.s.sol',
                      'contracts/test/bundler/BLayerAccounts.sol'])
        command = [str(anvil), '--host', '127.0.0.1', '--port', str(args.port), '--chain-id', '31337',
                   '--hardfork', 'amsterdam', '--gas-limit', '100000000', '--steps-tracing', '--order', 'fifo', '--silent']
        with (out / 'anvil.log').open('w') as log:
            log.write(json.dumps({**header, 'command': shlex.join(command), 'launcherCommand': header['command']}) + '\n')
            log.flush()
            proc = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
            for _ in range(120):
                if proc.poll() is not None:
                    raise RuntimeError('anvil exited; see anvil.log (loopback bind may be sandboxed)')
                try:
                    if rpc('eth_chainId', []) == '0x7a69':
                        # Avoid accepting an unrelated process already using this port.
                        time.sleep(0.2)
                        if proc.poll() is not None:
                            raise RuntimeError('our anvil did not acquire its port')
                        break
                except OSError:
                    time.sleep(0.25)
            else:
                raise RuntimeError('anvil did not start')
            run('entrypoint', ['node', '--input-type=module', '-e',
                'import {clients,etchEntryPoint} from "./script/b-layer/lib.mjs"; '
                'const u=process.argv[1]; await etchEntryPoint(u,clients(u).pub);', rpc_url])
            # Deployment/setup may estimate ordinary setup transactions; no RR conclusions
            # are derived from those estimates. All measured handleOps use explicit gas.
            run('deploy', [forge, 'script', '--offline', 'contracts/script/v3/DeployBLayerAnvil.s.sol:DeployBLayerAnvil',
                          '--rpc-url', rpc_url, '--broadcast', '--slow', '--skip-simulation', '--gas-estimate-multiplier', '110',
                          '--private-key', '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'])
            run('gasparams', ['node', 'script/b-layer/ams-gasparams.mjs', rpc_url, str(out / 'deploy.json'),
                             '440000', '420000', '5000', '340000', str(out / 'gasparams.json')])
            run('setup', ['node', 'script/b-layer/g1-setup.mjs', rpc_url, str(out / 'setup.json')])
            run('matrix', ['node', 'script/b-layer/rr-matrix.mjs', str(out / 'setup.json'), str(out), str(args.delta), args.filter])
    except Exception as error:
        status = 2
        (out / 'failure.json').write_text(json.dumps(dict(header=header, error=str(error)), indent=2) + '\n')
        print(error, file=sys.stderr)
    finally:
        if proc is not None:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=15)
        manifest(out)
    print(f'evidence: {out}; exit={status}')
    return status


if __name__ == '__main__':
    sys.exit(main())
