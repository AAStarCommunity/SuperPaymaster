#!/usr/bin/env python3
"""Guarded deployment. Fork: RPC DEPLOYER [--stop]; live: --production DEPLOYER."""
import argparse
import hashlib
import shutil
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler
from deploylive_runtime import clean_source_commit
from deploylive_rehearse import RPC, ROOT, require, guard_bls_verbosity, NoRedirect
from deploylive_deploy_day import build, verify_build, config_path, checker_pass, broadcast_gates, price_sources, print_command, redact_error, build_paths


REQUEST_PATH = 'cache/deploylive-prediction/pop-request.json'
REQUEST_NAME = 'pop-request.json'


class ReadOnlyRPC:
    def __init__(self, url):
        self.url = url
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def __call__(self, method, *params):
        require(method in ('eth_chainId', 'eth_blockNumber', 'eth_config', 'eth_getBlockByNumber', 'eth_call', 'eth_simulateV1'), 'read-only RPC method required')
        payload = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
        for attempt in range(4):
            try:
                with self.opener.open(Request(self.url, payload, {'Content-Type':'application/json'}), timeout=120) as response:
                    result = json.load(response)
                require('error' not in result, 'read-only ' + method + ': ' + redact_error(json.dumps(result.get('error'))))
                return result['result']
            except HTTPError as error:
                if error.code == 429 and attempt < 3:
                    error.close()
                    time.sleep(2 ** attempt)
                    continue
                detail = f'HTTP {error.code} {error.reason}'
                try:
                    detail += ' ' + error.read().decode('utf-8', errors='replace')
                finally:
                    error.close()
                raise RuntimeError('STOP read-only ' + method + ': ' + redact_error(detail)) from None
            except Exception as error:
                raise RuntimeError('STOP read-only ' + method + ': ' + redact_error(error)) from None


def gate_sources(env, production, chain):
    # Gas always uses this real-chain source, independently of the price mode.
    real = ReadOnlyRPC(env['DEPLOYLIVE_SOURCE_RPC'])
    real_chain = int(real('eth_chainId'), 16)
    require(real_chain in (10, 11155111), 'gas source must be a real deployment chain')
    require(not production or real_chain == chain, 'broadcast/source chain mismatch')
    if env.get('DEPLOYLIVE_PRICE_SOURCE', 'chain') == 'fork':
        return real, None
    second = env['DEPLOYLIVE_SECOND_RPC']
    require(env['DEPLOYLIVE_SOURCE_RPC'] != second, 'two distinct real-chain endpoints required')
    corroborating = ReadOnlyRPC(second)
    require(real_chain == int(corroborating('eth_chainId'), 16), 'source chain mismatch')
    return real, corroborating


def stage(action, argv):
    parser = argparse.ArgumentParser()
    parser.add_argument('--production', action='store_true')
    parser.add_argument('--evidence')
    args = parser.parse_args(argv)
    env = dict(os.environ)
    price_sources(env, args.production, None, None, None)
    env.setdefault('FOUNDRY_OUT', 'cache/deploylive-rehearsal-out')
    env.setdefault('FOUNDRY_CACHE_PATH', 'cache/deploylive-rehearsal-cache')
    if action == 'build':
        build(env, True)
        return
    required = ('DEPLOYLIVE_RPC', 'DEPLOYER_ADDRESS', 'ENV', 'ENTRY_POINT', 'ETH_USD_FEED',
                'SIMPLE_ACCOUNT_FACTORY', 'CREATION_PINS', 'GOVERNANCE_OWNER', 'GUARDIAN_ADDRESS',
                'SP_GUARDIAN', 'GENESIS_AASTAR_OPERATOR', 'APNTS_CAP', 'GUARDIAN_N',
                'GUARDIAN_MIN_THRESHOLD', 'GUARDIAN_DEFAULT_THRESHOLD', 'DEPLOYLIVE_HARDFORK',
                'GUARDIAN_SLASH_THRESHOLD_0', 'GUARDIAN_SLASH_THRESHOLD_1', 'GUARDIAN_SLASH_THRESHOLD_2',
                'SLASH_POLICY_ADMIN', 'X402_OWNER', 'REPUTATION_OWNER', 'MPC_OWNER',
                'PAYMASTER_FACTORY_OWNER', 'DEPLOYER_GTOKEN_RECIPIENT')
    for key in required:
        require(bool(env.get(key)), 'missing input ' + key)
    require(bool(args.evidence), 'missing --evidence')
    evidence = (ROOT / args.evidence).resolve()
    require(evidence.is_relative_to(ROOT), 'evidence must be inside worktree')
    guard_bls_verbosity([], env)
    env.update(SP_COMMIT=clean_source_commit(), DEPLOYLIVE_REHEARSAL='0' if args.production else '1',
               DEPLOYLIVE_EVM_VERSION='prague', DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP='0')
    binary = verify_build(env, True)
    request = ROOT / REQUEST_PATH
    request.parent.mkdir(parents=True, exist_ok=True)
    request.unlink(missing_ok=True)
    config_path(env).parent.mkdir(parents=True, exist_ok=True)
    env['DEPLOYLIVE_POP_REQUEST_OUT'] = str(request.relative_to(ROOT))
    command = [binary, 'script', '--offline', 'contracts/script/v3/DeployLive.s.sol:DeployLive',
               '--rpc-url', env['DEPLOYLIVE_RPC'], '--sender', env['DEPLOYER_ADDRESS'],
               '--slow', '--evm-version', 'prague', '--hardfork', env['DEPLOYLIVE_HARDFORK'],
               '--gas-estimate-multiplier', env.get('DEPLOYLIVE_GAS_MULTIPLIER', '130'), '-vv']
    if not args.production:
        command.append('--unlocked')
    print_command(command)
    result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, text=True)
    require(result.returncode == 0 and request.is_file(), 'prediction failed or no fresh request')
    evidence.mkdir(parents=True, exist_ok=True)
    destination = evidence / REQUEST_NAME
    if destination != request:
        shutil.copyfile(request, destination)
    print('SHA256 ' + hashlib.sha256(destination.read_bytes()).hexdigest() + ' ' + str(destination))


def main():
    if sys.argv[1:2] in (['build'], ['predict']):
        return stage(sys.argv[1], sys.argv[2:])
    if sys.argv[1:2] == ['deploy']:
        del sys.argv[1]

    production = sys.argv[1:2] == ['--production']
    if production:
        require(len(sys.argv) == 3, 'usage: --production DEPLOYER; RPCs from environment')
        url, deployer, stop = os.environ['DEPLOYLIVE_RPC'], sys.argv[2], False
    else:
        require(len(sys.argv) in (3, 4), 'usage: RPC DEPLOYER [--stop]')
        url, deployer = sys.argv[1:3]
        stop = sys.argv[3:] == ['--stop']
        require(len(sys.argv) == 3 or stop, 'unknown argument')
    price_sources(os.environ, production, None, None, None)
    guard_bls_verbosity([], os.environ)
    commit = clean_source_commit()
    rpc = ReadOnlyRPC(url) if production else RPC(url)
    chain = int(rpc('eth_chainId'), 16)
    require(chain == 31337 if stop else chain in (10, 31337, 11155111), 'unsupported deployment chain')
    require(not production or chain in (10, 11155111), 'production chain required')
    evidence = Path(os.environ['DEPLOYLIVE_EVIDENCE_DIR']).resolve()
    require(evidence.is_dir() and evidence.is_relative_to(ROOT), 'evidence directory required inside worktree')
    env = dict(os.environ, SP_COMMIT=commit, DEPLOYER_ADDRESS=deployer, DEPLOYLIVE_REHEARSAL='0' if production else '1', DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP='1' if stop else '0', DEPLOYLIVE_EVM_VERSION='prague')
    env.setdefault('FOUNDRY_OUT', 'cache/deploylive-rehearsal-out')
    env.setdefault('FOUNDRY_CACHE_PATH', 'cache/deploylive-rehearsal-cache')
    path = config_path(env)
    path.parent.mkdir(parents=True, exist_ok=True)
    build_paths(env)
    binary = verify_build(env, production)
    real, corroborating = gate_sources(env, production, chain)
    hardfork = env['DEPLOYLIVE_HARDFORK']
    require(not production or chain != 11155111 or hardfork == 'amsterdam', 'Sepolia requires hardfork amsterdam')
    command = [binary, 'script', '--offline', 'contracts/script/v3/DeployLive.s.sol:DeployLive',
               '--rpc-url', url, '--sender', deployer, '--slow', '--evm-version', 'prague',
               '--hardfork', hardfork, '--gas-estimate-multiplier', env.get('DEPLOYLIVE_GAS_MULTIPLIER', '130'), '-vv']
    if production:
        command += ['--account', env['DEPLOYER_ACCOUNT']]
    else:
        command += ['--unlocked']
        rpc('anvil_setCode', deployer, '0x')
        rpc('anvil_impersonateAccount', deployer)
        rpc('anvil_setBalance', deployer, hex(10**22))
    try:
        plan_path = ROOT / f'broadcast/DeployLive.s.sol/{chain}/dry-run/run-latest.json'
        plan_path.unlink(missing_ok=True)
        dry_env = dict(env, DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP='0')
        print_command(command)
        dry = subprocess.run(command, cwd=ROOT, env=dry_env, capture_output=True, text=True)
        (evidence/'forge.dry.stdout.log').write_text(dry.stdout)
        (evidence/'forge.dry.stderr.log').write_text(dry.stderr)
        require(dry.returncode == 0 and plan_path.is_file(), 'dry run failed or no fresh planned sequence')
        plan = json.loads(plan_path.read_text())
        lines, reads = [], []
        def recorded(label, transport):
            def read(method, *params):
                result = transport(method, *params)
                reads.append(dict(endpoint=label, method=method, params=params, result=result))
                return result
            return read
        try:
            broadcast_gates(env, plan, recorded('primary', real), recorded('secondary', corroborating),
                            lambda line: (lines.append(line), print(line)),
                            price_rpcs=price_sources(env, production, recorded('primary', real),
                                                    None, recorded('fork', ReadOnlyRPC(url)))
                            if env.get('DEPLOYLIVE_PRICE_SOURCE', 'chain') == 'fork' else None)
        finally:
            (evidence/'prebroadcast.log').write_text('\n'.join(lines) + '\n')
            (evidence/'prebroadcast.reads.json').write_text(json.dumps(reads, indent=2) + '\n')
        binary = verify_build(env, production)
        from deploylive_deploy_day import stamp_path
        record = json.loads(stamp_path(env).read_text())
        record['scriptForge'] = record['forge']
        release_out = ROOT / env.get('DEFAULT_ARTIFACTS_OUT', 'out')
        record['releaseBuild'] = json.loads(release_out.with_name(release_out.name + '.build-stamp.json').read_text())
        (evidence/'forge.build-and-script.json').write_text(json.dumps(record, indent=2) + '\n')
        print_command([binary, *command[1:], '--broadcast'])
        result = subprocess.run([binary, *command[1:], '--broadcast'], cwd=ROOT, env=env, capture_output=True, text=True)
        (evidence/'forge.stdout.log').write_text(result.stdout)
        (evidence/'forge.stderr.log').write_text(result.stderr)
        require(result.returncode == 0, 'deployment failed; config existence is not success')
    finally:
        if not production:
            rpc('anvil_stopImpersonatingAccount', deployer)
    if stop:
        print('PREPARED stopped before H; deployment is not successful')
        return
    result = subprocess.run([sys.executable, str(ROOT/'script/rehearsal/deploylive_postdeploy_check.py'), url, str(path), deployer, env['GOVERNANCE_OWNER']], cwd=ROOT, env=env, capture_output=True, text=True)
    (evidence/'checker.log').write_text(result.stdout)
    checker_pass(result)
    print(result.stdout, end='' if result.stdout.endswith('\n') else '\n')
    print('PASS full deployment; post-deploy checker PASS')


def cli(argv=None):
    """Public entry point: every command requires the complete approved input file."""
    from deploylive_controls import load_inputs, evidence_dir, hardfork_check, cap_control, archive
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('build','predict','deploy','hardfork-check','cap-control','archive'))
    parser.add_argument('--inputs', required=True)
    parser.add_argument('--production', action='store_true')
    parser.add_argument('--to')
    parser.add_argument('--stop', action='store_true')
    args = parser.parse_args(argv)
    require(not args.stop or (args.action == 'deploy' and not args.production), '--stop requires rehearsal deploy')
    env = load_inputs(args.inputs)
    evidence = evidence_dir(env)
    evidence.mkdir(parents=True, exist_ok=True)
    if args.action == 'hardfork-check':
        require(env['DEPLOYLIVE_SOURCE_RPC'] != env['DEPLOYLIVE_SECOND_RPC'], 'distinct endpoints required')
        return hardfork_check(ReadOnlyRPC(env['DEPLOYLIVE_SOURCE_RPC']), ReadOnlyRPC(env['DEPLOYLIVE_SECOND_RPC']), evidence)
    if args.action == 'cap-control':
        require(not args.production, 'cap-control refused in production')
        return cap_control(RPC(env['DEPLOYLIVE_RPC']), evidence)
    if args.action == 'archive':
        require(bool(args.to), 'archive requires --to')
        return archive(evidence,args.to)
    previous = dict(os.environ)
    previous_argv = sys.argv[:]
    try:
        os.environ.clear()
        os.environ.update(env)
        if args.action in ('build','predict'):
            flags = ['--production'] if args.production else []
            if args.action == 'predict': flags += ['--evidence', str(evidence)]
            stage(args.action,flags)
            print(args.action.upper() + ' PASS')
        else:
            # GUARDIANS is generated from the approved DVT export after prediction.
            os.environ['GUARDIANS'] = (evidence/'guardians.hex').read_text().strip()
            sys.argv = [sys.argv[0], 'deploy'] + (['--production', env['DEPLOYER_ADDRESS']] if args.production else [env['DEPLOYLIVE_RPC'], env['DEPLOYER_ADDRESS']])
            if args.stop: sys.argv.append('--stop')
            main()
    finally:
        os.environ.clear()
        os.environ.update(previous)
        sys.argv = previous_argv


if __name__ == '__main__':
    try:
        cli()
    except Exception as error:
        # Preserve diagnostics while removing endpoint URLs and credentials.
        print('STOP deployment: ' + redact_error(error))
        sys.exit(1)
