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
        require(method in ('eth_getTransactionCount', 'eth_chainId', 'eth_blockNumber', 'eth_config', 'eth_getBlockByNumber', 'eth_call', 'eth_simulateV1'), 'read-only RPC method required')
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


def require_checker_inputs(env, chain=None, production=True):
    # Provider independence is enforced only before a production broadcast: a fork rehearsal
    # (anvil --chain-id 11155111 on 127.0.0.1) has no second provider bound to its endpoint.
    from deploylive_readback import expected_chain_id, independent_providers
    try:
        expected = expected_chain_id(env)
    except ValueError:
        require(False, 'STOP DEPLOYLIVE_EXPECTED_CHAIN_ID required or invalid')
    require(chain is None or expected == chain, 'DEPLOYLIVE_EXPECTED_CHAIN_ID differs from the broadcast endpoint chain')
    # A production predict must fail now, not after PoP/DVT signing, for a chain deploy will refuse.
    require(not production or expected in (10, 11155111), 'STOP production requires DEPLOYLIVE_EXPECTED_CHAIN_ID 10 or 11155111')
    if production and expected != 31337:
        try:
            second = Path(env['DEPLOYLIVE_SECOND_RPC_FILE']).read_text().strip()
            if second != env.get('DEPLOYLIVE_SECOND_RPC'):
                raise ValueError('second endpoint mismatch')
            independent_providers(env.get('DEPLOYLIVE_ENDPOINT_PROVIDER', ''),
                                  env.get('DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER', ''),
                                  env.get('DEPLOYLIVE_RPC', ''), second)
        except (ValueError, OSError, KeyError):
            require(False, 'STOP invalid checker provider pair; distinct approved bound endpoints required')


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
    if args.production:
        require_checker_inputs(env)
    binary = verify_build(env, True)
    request = ROOT / REQUEST_PATH
    request.parent.mkdir(parents=True, exist_ok=True)
    request.unlink(missing_ok=True)
    config_path(env).parent.mkdir(parents=True, exist_ok=True)
    env['DEPLOYLIVE_POP_REQUEST_OUT'] = str(request.relative_to(ROOT))
    command = [binary, 'script', '--offline', 'contracts/script/v3/DeployLive.s.sol:DeployLive',
               '--sender', env['DEPLOYER_ADDRESS'],
               '--slow', '--evm-version', 'prague', '--hardfork', env['DEPLOYLIVE_HARDFORK'],
               '--gas-estimate-multiplier', env.get('DEPLOYLIVE_GAS_MULTIPLIER', '130'), '-vv']
    if not args.production:
        command.append('--unlocked')
    from deploylive_controls import forge_endpoint, safe_logs, write_manifest
    command, forge_env = forge_endpoint(command, env)
    print_command(command)
    result = subprocess.run(command, cwd=ROOT, env=forge_env, capture_output=True, text=True)
    evidence.mkdir(parents=True, exist_ok=True)
    # Logs are written (after the redaction scan) whether or not the step succeeded.
    safe_logs(evidence, 'forge.predict', result, env)
    require(result.returncode == 0 and request.is_file(), 'prediction failed or no fresh request; see forge.predict.* in evidence')
    destination = evidence / REQUEST_NAME
    if destination != request:
        shutil.copyfile(request, destination)
    write_manifest(env, evidence)
    print('SHA256 ' + hashlib.sha256(destination.read_bytes()).hexdigest() + ' ' + str(destination))


BROADCAST_PROGRESS_SECONDS = 30


def run_broadcast(command, env, rpc, deployer, plan):
    """Capture forge privately while reporting confirmed nonce progress."""
    from concurrent.futures import ThreadPoolExecutor, TimeoutError
    from deploylive_controls import integer
    start = integer(plan['transactions'][0]['transaction']['nonce'])
    total = len(plan['transactions'])
    with ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(subprocess.run, command, cwd=ROOT, env=env,
                                 capture_output=True, text=True)
        while True:
            try:
                return future.result(timeout=BROADCAST_PROGRESS_SECONDS)
            except TimeoutError:
                try:
                    nonce = integer(rpc('eth_getTransactionCount', deployer, 'latest'))
                except Exception:
                    print('BROADCAST progress: nonce unavailable', flush=True)
                    continue
                print(f'BROADCAST progress: deployer nonce {nonce} (advanced by {nonce - start}; plan has {total} transactions)', flush=True)


PRE_SIGNING_CAUSES = ('keystore unlock failed',)


def broadcast_failure_cause(result):
    # Only fixed labels reach the terminal; stderr may contain RPC credentials.
    if 'failed to decrypt keystore: incorrect password' in result.stderr.lower():
        return 'keystore unlock failed'
    return f'forge exit {result.returncode}'


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
    require_checker_inputs(dict(os.environ, DEPLOYLIVE_RPC=url), chain, production)
    evidence = Path(os.environ['DEPLOYLIVE_EVIDENCE_DIR']).resolve()
    require(evidence.is_dir() and evidence.is_relative_to(ROOT), 'evidence directory required inside worktree')
    env = dict(os.environ, SP_COMMIT=commit, DEPLOYER_ADDRESS=deployer, DEPLOYLIVE_REHEARSAL='0' if production else '1', DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP='1' if stop else '0', DEPLOYLIVE_EVM_VERSION='prague')
    env.setdefault('FOUNDRY_OUT', 'cache/deploylive-rehearsal-out')
    env.setdefault('FOUNDRY_CACHE_PATH', 'cache/deploylive-rehearsal-cache')
    path = config_path(env)
    path.parent.mkdir(parents=True, exist_ok=True)
    from deploylive_controls import deployment_rule, forge_endpoint, safe_logs, verify_manifest, check_start_nonce, plan_diff, write_success, gas_changes, verify_conversion, plan_digest
    verify_manifest(env, evidence)
    approved_env = dict(env)
    env['GUARDIANS'] = verify_conversion(approved_env, evidence)
    build_paths(env)
    binary = verify_build(env, production)
    real, corroborating = gate_sources(env, production, chain)
    (evidence/'checker.PASS.json').unlink(missing_ok=True)
    deployment_rule(env, evidence, ReadOnlyRPC, chain)
    request = json.loads((evidence/REQUEST_NAME).read_text())
    hardfork = env['DEPLOYLIVE_HARDFORK']
    require(not production or chain != 11155111 or hardfork == 'amsterdam', 'Sepolia requires hardfork amsterdam')
    command = [binary, 'script', '--offline', 'contracts/script/v3/DeployLive.s.sol:DeployLive',
               '--sender', deployer, '--slow', '--evm-version', 'prague',
               '--hardfork', hardfork, '--gas-estimate-multiplier', env.get('DEPLOYLIVE_GAS_MULTIPLIER', '130'), '-vv']
    env['DEPLOYLIVE_RPC'] = url
    env['ETH_RPC_URL'] = url  # for the checker and cast (both read ETH_RPC_URL from env)
    command, forge_env = forge_endpoint(command, env)
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
        dry_env = dict(forge_env, DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP='0')
        print_command(command)
        dry = subprocess.run(command, cwd=ROOT, env=dry_env, capture_output=True, text=True)
        safe_logs(evidence, 'forge.dry', dry, env)
        require(dry.returncode == 0 and plan_path.is_file(), 'dry run failed or no fresh planned sequence')
        plan = json.loads(plan_path.read_text())
        (evidence/'gated-plan.json').write_text(json.dumps(plan)+'\n')
        lines, reads = [], []
        def recorded(label, transport):
            def read(method, *params):
                result = transport(method, *params)
                reads.append(dict(endpoint=label, method=method, params=params, result=result))
                return result
            return read
        try:
            gas_bounds = broadcast_gates(env, plan, recorded('primary', real), recorded('secondary', corroborating),
                            lambda line: (lines.append(line), print(line)),
                            price_rpcs=price_sources(env, production, recorded('primary', real),
                                                    None, recorded('fork', ReadOnlyRPC(url)))
                            if env.get('DEPLOYLIVE_PRICE_SOURCE', 'chain') == 'fork' else None)
        finally:
            (evidence/'prebroadcast.log').write_text('\n'.join(lines) + '\n')
            (evidence/'prebroadcast.reads.json').write_text(json.dumps(reads, indent=2) + '\n')
        (evidence/'gas-bounds.json').write_text(json.dumps(gas_bounds)+'\n')
        require(verify_conversion(approved_env, evidence) == env['GUARDIANS'], 'conversion changed during deployment')
        binary = verify_build(env, production)
        from deploylive_deploy_day import stamp_path
        record = json.loads(stamp_path(env).read_text())
        record['scriptForge'] = record['forge']
        release_out = ROOT / env.get('DEFAULT_ARTIFACTS_OUT', 'out')
        record['releaseBuild'] = json.loads(release_out.with_name(release_out.name + '.build-stamp.json').read_text())
        (evidence/'forge.build-and-script.json').write_text(json.dumps(record, indent=2) + '\n')
        plan_path.unlink(missing_ok=True)
        require(verify_conversion(approved_env, evidence) == env['GUARDIANS'], 'conversion changed during deployment')
        final = subprocess.run(command, cwd=ROOT, env=dry_env, capture_output=True, text=True)
        safe_logs(evidence, 'forge.final', final, env)
        require(final.returncode == 0 and plan_path.is_file(), 'final simulation failed')
        final_plan = json.loads(plan_path.read_text())
        diff = plan_diff(plan, final_plan)
        (evidence/'prebroadcast.diff.json').write_text(json.dumps(dict(gatedPlanSha256=plan_digest(plan), diff=diff))+'\n')
        require(not diff, 'final simulation differs from gated plan')
        broadcast_plan = plan
        if stop:
            plan_path.unlink(missing_ok=True)
            stopped = subprocess.run(command, cwd=ROOT, env=forge_env, capture_output=True, text=True)
            safe_logs(evidence, 'forge.stop', stopped, env)
            require(stopped.returncode == 0 and plan_path.is_file(), 'stop simulation failed')
            broadcast_plan = json.loads(plan_path.read_text())
            count = len(broadcast_plan['transactions'])
            tail = plan['transactions'][count:]
            require(count > 0 and tail and tail[0].get('transactionType') == 'CREATE'
                    and tail[0].get('contractName', '').split('.')[0] == 'TimelockHandoverBootstrap',
                    'stop simulation must omit the bootstrap tail')
            diff = plan_diff(dict(plan, transactions=plan['transactions'][:count]), broadcast_plan)
            (evidence/'stop-plan.json').write_text(json.dumps(broadcast_plan)+'\n')
            (evidence/'stop.diff.json').write_text(json.dumps(dict(gatedPlanSha256=plan_digest(plan), diff=diff))+'\n')
            require(not diff, 'stop simulation differs from gated prefix')
        check_start_nonce(final_plan, request['pin']['senders']['deployer']['nonce'], rpc, deployer)
        verify_manifest(approved_env, evidence)
        require(verify_conversion(approved_env, evidence) == env['GUARDIANS'], 'conversion changed during deployment')
        binary = verify_build(env, production)
        actual_path = ROOT / f'broadcast/DeployLive.s.sol/{chain}/run-latest.json'
        actual_path.unlink(missing_ok=True)
        print_command([binary, *command[1:], '--broadcast'])
        require(verify_conversion(approved_env, evidence) == env['GUARDIANS'], 'conversion changed during deployment')
        result = run_broadcast([binary, *command[1:], '--broadcast'], forge_env, rpc, deployer, broadcast_plan)
        safe_logs(evidence, 'forge', result, env, after_broadcast=True)
        try:
            actual = json.loads(actual_path.read_text())
            receipts = actual.get('receipts', [])
            mined = len(receipts) if isinstance(receipts, list) else 0
        except (OSError, ValueError, AttributeError):
            actual, mined = {}, 0
        total = len(broadcast_plan['transactions'])
        if not mined:
            # forge writes run-latest.json before signing, so a missing record proves nothing. Say "not
            # broadcast" only when forge failed for a recognised pre-signing cause AND every nonce read
            # (latest and pending, on each provider) still equals the plan's start nonce.
            from deploylive_controls import integer
            start = integer(broadcast_plan['transactions'][0]['transaction']['nonce'])
            providers = [('primary', real if production else rpc)] + ([('second', corroborating)] if production and corroborating is not None else [])
            readings, unchanged = [], production is False or corroborating is not None
            for label, transport in providers:
                for tag in ('latest', 'pending'):
                    try:
                        nonce = integer(transport('eth_getTransactionCount', deployer, tag))
                        readings.append(f'{label} {tag}={nonce} (advanced by {nonce - start})')
                        unchanged = unchanged and nonce == start
                    except Exception:
                        readings.append(f'{label} {tag}=unreadable')
                        unchanged = False
            cause = broadcast_failure_cause(result)
            if unchanged and cause in PRE_SIGNING_CAUSES:
                print('NOT BROADCAST: forge failed before signing (' + cause + '); deployer nonce unchanged: ' + '; '.join(readings))
            else:
                print('BROADCAST STATE UNKNOWN — do not retry: no receipts recorded; forge: ' + cause + '; deployer nonce: ' + '; '.join(readings))
            require(False, 'deployment failed; config existence is not success')
        partial = mined < total
        if partial:
            print(f'PARTIAL BROADCAST: forge recorded {mined}/{total} receipts; deployment NOT successful')
        elif result.returncode != 0:
            require(False, 'deployment failed; config existence is not success')
        try:
            diff = plan_diff(broadcast_plan, actual, gas_bounds)
        except (OSError, ValueError, KeyError, TypeError, IndexError):
            diff = ['missing or malformed fresh broadcast record']
        (evidence/'postbroadcast.diff.json').write_text(json.dumps(dict(gatedPlanSha256=plan_digest(plan), broadcastPlanSha256=plan_digest(broadcast_plan), diff=diff))+'\n')
        require(not diff, 'post-broadcast diff is not empty; deployment NOT successful')
        changed = gas_changes(broadcast_plan, actual, gas_bounds)
        (evidence/'postbroadcast.gas.json').write_text(json.dumps(changed, indent=2)+'\n')
        label = 'GAS partial post-broadcast' if partial else 'GAS post-broadcast'
        print(label + ' limits equal to gated plan' if not changed else
              f'{label} {len(changed)} limit(s) differ from the gated plan, all inside the gated range')
        require(result.returncode == 0 and not partial, 'deployment failed; config existence is not success')
    finally:
        if not production:
            rpc('anvil_stopImpersonatingAccount', deployer)
    if stop:
        print('PREPARED stopped before H; deployment is not successful')
        return
    # The checker only writes readback evidence strictly below <worktree>/cache (deploylive_readback
    # evidence_path); the deploy-day evidence directory lives elsewhere. Give the checker its own fresh
    # cache subdirectory and copy the readback into the evidence directory, byte-identical.
    checker_dir = ROOT/'cache/deploylive-checker'/(env.get('ENV') or 'default')
    checker_dir.mkdir(parents=True, exist_ok=True)
    (checker_dir/'readback.json').unlink(missing_ok=True)
    (evidence/'readback.json').unlink(missing_ok=True)
    cast_pin = env.get('CAST_1_7_1', '')
    require(bool(cast_pin) and Path(cast_pin).is_file() and os.access(cast_pin, os.X_OK),
            'STOP CAST_1_7_1 must name an executable')
    checker_env = dict(env, DEPLOYLIVE_EVIDENCE_DIR=str(checker_dir))
    checker_env['PATH'] = str(Path(cast_pin).absolute().parent) + os.pathsep + env.get('PATH', '')
    result = subprocess.run([sys.executable, str(ROOT/'script/rehearsal/deploylive_postdeploy_check.py'), str(path), deployer, env['GOVERNANCE_OWNER']], cwd=ROOT, env=checker_env, capture_output=True, text=True)
    safe_logs(evidence, 'checker', result, env, after_broadcast=True)
    (evidence/'checker.log').write_text((evidence/'checker.stdout.log').read_text())
    checker_pass(result)
    copy_readback(checker_dir/'readback.json', evidence/'readback.json')
    checker_output = (evidence/'checker.stdout.log').read_text()
    print(checker_output, end='' if checker_output.endswith('\n') else '\n')
    write_success(evidence, env, path, actual_path, plan)
    print('PASS full deployment; post-deploy checker PASS')


def copy_readback(source, destination):
    """Copy the checker's readback into the evidence directory and prove the bytes are unchanged."""
    import hashlib
    require(source.is_file() and not source.is_symlink(), 'checker readback missing')
    data = source.read_bytes()
    destination.write_bytes(data)
    require(hashlib.sha256(destination.read_bytes()).hexdigest() == hashlib.sha256(data).hexdigest(), 'readback copy differs')


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
    if args.action in ('predict', 'deploy'):
        (evidence/'checker.PASS.json').unlink(missing_ok=True)
    if args.action == 'hardfork-check':
        require(env['DEPLOYLIVE_SOURCE_RPC'] != env['DEPLOYLIVE_SECOND_RPC'], 'distinct endpoints required')
        return hardfork_check(ReadOnlyRPC(env['DEPLOYLIVE_SOURCE_RPC']), ReadOnlyRPC(env['DEPLOYLIVE_SECOND_RPC']), evidence)
    if args.action == 'cap-control':
        require(not args.production, 'cap-control refused in production')
        return cap_control(RPC(env['DEPLOYLIVE_RPC']), evidence)
    if args.action == 'archive':
        require(bool(args.to), 'archive requires --to')
        return archive(evidence,args.to,env=env)
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
            from deploylive_controls import verify_conversion
            verify_conversion(env, evidence)
            # GUARDIANS is generated from the approved DVT export after prediction.
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
