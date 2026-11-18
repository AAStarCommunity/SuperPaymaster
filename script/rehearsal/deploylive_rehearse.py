#!/usr/bin/env python3
"""Anvil-fork-only exit-hook tools. No keys; impersonated senders only."""
import json
import os
import re
import tomllib
from pathlib import Path
import subprocess
import sys
import time
from deploylive_runtime import clean_source_commit
from deploylive_deploy_day import checker_pass, config_path
from urllib.parse import urlsplit, unquote
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler

ROOT = Path(__file__).resolve().parents[2]
ZERO = '0x' + '00' * 32
ROLES = ('PROPOSER_ROLE', 'EXECUTOR_ROLE', 'CANCELLER_ROLE')


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def guard_bls_verbosity(args, env, default=3):
    verbosity = int(env.get('FOUNDRY_VERBOSITY', default))
    short = sum(len(a) - 1 for a in args if re.fullmatch(r'-v+', a))
    if short:
        verbosity = short
    for i, arg in enumerate(args):
        if arg == '--verbosity':
            verbosity = int(args[i + 1])
        elif arg.startswith('--verbosity='):
            verbosity = int(arg.split('=', 1)[1])
    require(verbosity < 3, 'BLS rehearsal refuses forge verbosity >= 3')


MIN_FRAGMENT = 6


def scan_evidence(directory, rpc_url, scalars):
    directory = Path(directory).resolve()
    require(directory.is_dir(), 'evidence directory must exist')
    url = urlsplit(rpc_url)
    needles = {rpc_url, url.hostname or ''}
    # Path/query fragments count only from MIN_FRAGMENT characters, like the fixed final scan: a
    # short segment such as a provider's API-version prefix ("v2") is not a secret and occurs in
    # ordinary logs, which made every Alchemy-backed run fail. The full URL and host still count.
    needles.update(fragment for fragment in unquote(url.path).split('/') if len(fragment) >= MIN_FRAGMENT)
    needles.update(fragment for fragment in re.split(r'[=&]', unquote(url.query)) if len(fragment) >= MIN_FRAGMENT)
    for scalar in scalars:
        n = int(str(scalar), 16 if str(scalar).startswith('0x') else 10)
        require(n > 0, 'invalid rehearsal scalar')
        needles.update((str(n), f'{n:064x}', hex(n)))
    encoded = [n.encode().lower() for n in needles if n]
    for path in directory.rglob('*'):
        require(not path.is_symlink(), 'evidence symlinks refused')
        if path.is_file():
            content = path.read_bytes().lower()
            require(not any(n in content for n in encoded), 'evidence contains sensitive material (details redacted)')


def local_endpoint(url):
    p = urlsplit(url)
    require(p.scheme == 'http' and p.hostname in ('127.0.0.1', '::1', 'localhost')
            and p.username is None and p.password is None, 'loopback HTTP endpoint required')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('RPC redirect refused')


class RPCRevert(RuntimeError):
    pass


class RPC:
    def __init__(self, url):
        local_endpoint(url)
        self.url = url
        self.opener = build_opener(ProxyHandler({}), NoRedirect())
        require('anvil' in str(self('web3_clientVersion')).lower(), 'Anvil required')
        require(bool(self('anvil_metadata').get('forkedNetwork')), 'Anvil fork required')

    def __call__(self, method, *params):
        payload = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
        try:
            with self.opener.open(Request(self.url, payload, {'Content-Type': 'application/json'}), timeout=30) as r:
                result = json.load(r)
            if 'error' in result:
                data = result['error'].get('data', '')
                if isinstance(data, str) and re.fullmatch(r'0x[0-9a-fA-F]+', data):
                    raise RPCRevert(data)
                raise RuntimeError('RPC failed')
            return result['result']
        except RPCRevert:
            raise
        except Exception:
            raise RuntimeError('RPC failed (details redacted)') from None

    def call(self, target, signature, *args):
        return self('eth_call', {'to': target, 'data': cast('calldata', signature, *args)}, 'latest')

    def send(self, sender, data='0x', to=None, nonce=None, expected_status=1):
        tx = {'from': sender, 'data': data, 'gas': hex(12_000_000)}
        if to is not None:
            tx['to'] = to
        if nonce is not None:
            tx['nonce'] = hex(nonce)
        txhash = self('eth_sendTransaction', tx)
        for _ in range(120):
            receipt = self('eth_getTransactionReceipt', txhash)
            if receipt:
                require(int(receipt['status'], 16) == expected_status, 'unexpected transaction status')
                return receipt
            time.sleep(0.25)
        raise RuntimeError('receipt timeout')


def cast(*args):
    r = subprocess.run(['cast', *map(str, args)], cwd=ROOT, capture_output=True, text=True)
    require(r.returncode == 0, 'local ABI command failed')
    return r.stdout.strip()


def words(raw):
    require(raw.startswith('0x') and (len(raw) - 2) % 64 == 0, 'invalid ABI result')
    return [int(raw[i:i + 64], 16) for i in range(2, len(raw), 64)]


def array(values):
    return '[' + ','.join(map(str, values)) + ']'


def impersonate(rpc, account, action):
    rpc('anvil_impersonateAccount', account)
    try:
        rpc('anvil_setBalance', account, hex(10**20))
        return action()
    finally:
        rpc('anvil_stopImpersonatingAccount', account)


def hook_receipt(receipt, sp, op, topic, staking):
    return int(receipt['status'], 16) == 1 and any(
        log['address'].lower() == sp.lower() and len(log['topics']) == 3
        and log['topics'][0].lower() == topic.lower()
        and int(log['topics'][1], 16) == int(op, 16)
        and int(log['topics'][2], 16) == int(staking, 16)
        and int(log['data'], 16) == 4  # UNDERSTAKED
        for log in receipt['logs'])


def hook(rpc, cfg, op):
    reg, sp, stk = (cfg[k] for k in ('registry', 'superPaymaster', 'staking'))
    role = cast('keccak', 'PAYMASTER_SUPER')
    require(words(rpc.call(reg, 'hasRole(bytes32,address)', role, op)) == [1], 'operator lacks role')
    before = words(rpc.call(sp, 'operators(address)', op))
    require(len(before) == 9 and before[0] > 0 and before[1:3] == [1, 0],
            'operator must be funded, configured and unpaused')
    require(words(rpc.call(stk, 'getLockedStake(address,bytes32)', op, role))[0] > 0, 'operator needs locked stake')
    config = words(rpc.call(reg, 'getRoleConfig(bytes32)', role))
    require(config[0] == 32 and len(config) >= 13, 'invalid role config')
    rpc('evm_increaseTime', config[12] + 1)
    rpc('evm_mine')
    receipt = impersonate(rpc, op, lambda: rpc.send(op, cast('calldata', 'exitRole(bytes32)', role), reg))
    require(hook_receipt(receipt, sp, op, cast('keccak', 'OperatorPaused(address,address,uint8)'), stk),
            'exit receipt lacks staking-triggered OperatorPaused')
    require(words(rpc.call(sp, 'operators(address)', op))[2] == 1, 'operator not paused after exit')
    require(words(rpc.call(reg, 'hasRole(bytes32,address)', role, op)) == [0], 'operator still holds role')


def prepare_operator(rpc, cfg, safe, op):
    reg, sp, factory, token = (cfg[k] for k in ('registry', 'superPaymaster', 'xPNTsFactoryV2', 'aPNTs'))
    for role in ('COMMUNITY', 'PAYMASTER_SUPER'):
        require(words(rpc.call(reg, 'hasRole(bytes32,address)', cast('keccak', role), op)) == [1], 'genesis roles missing')
    require(words(rpc.call(token, 'minter()')) == [int(safe, 16)], 'unexpected minter')
    def configure():
        issued = words(rpc.call(factory, 'getTokenAddress(address)', op))[0]
        if not issued:
            rpc.send(op, cast('calldata', 'deployxPNTsToken(string,string,string,string,uint256,address)',
                             'Rehearsal', 'RHR', 'Rehearsal', '', 10**18, '0x' + '00' * 20), factory)
            issued = words(rpc.call(factory, 'getTokenAddress(address)', op))[0]
        rpc.send(op, cast('calldata', 'configureOperator(address,address)', '0x' + f'{issued:040x}', op), sp)
    impersonate(rpc, op, configure)
    if words(rpc.call(sp, 'operators(address)', op))[0] == 0:
        # One base unit suffices to exercise the funded operator exit path.
        impersonate(rpc, safe, lambda: rpc.send(safe, cast('calldata', 'mint(address,uint256)', op, 1), token))
        def deposit():
            rpc.send(op, cast('calldata', 'approve(address,uint256)', sp, 1), token)
            rpc.send(op, cast('calldata', 'deposit(uint256)', 1), sp)
        impersonate(rpc, op, deposit)


def fail_bootstrap(rpc, cfg, deployer):
    nonce = int(cfg['handoverBootstrapNonce'])
    require(int(rpc('eth_getTransactionCount', deployer, 'latest'), 16) == nonce, 'bootstrap nonce drift')
    slot = '0xdb5a3168abaa6147a9f3a4cb66016161119d4d50b6393344d27120286f742a00'
    rpc('anvil_setStorageAt', cfg['registry'], slot, ZERO)
    require(int(rpc('eth_getTransactionCount', deployer, 'latest'), 16) == nonce, 'storage write consumed nonce')
    impersonate(rpc, deployer, lambda: rpc.send(deployer, cfg['handoverCreationCode'], nonce=nonce, expected_status=0))
    require(rpc('eth_getCode', cfg['handoverBootstrap'], 'latest') == '0x', 'failed H has code')
    tl, h = cfg['timelockController'], cfg['handoverBootstrap'].lower()
    grants = cast('keccak', 'RoleGranted(bytes32,address,address)')
    revokes = cast('keccak', 'RoleRevoked(bytes32,address,address)')
    history = rpc('eth_getLogs', {'address': tl, 'fromBlock': hex(int(cfg['deploymentStartBlock'])), 'toBlock': 'latest'})
    members = {}
    for event in sorted(history, key=lambda e: (int(e['blockNumber'], 16), int(e['logIndex'], 16))):
        topics = event['topics']
        if topics[0] not in (grants, revokes): continue
        bucket = members.setdefault(topics[1], set())
        account = '0x' + topics[2][-40:].lower()
        if topics[0] == grants: bucket.add(account)
        else: bucket.discard(account)
    for role in ('DEFAULT_ADMIN_ROLE', *ROLES):
        rid = rpc.call(tl, role + '()')
        expected = {tl.lower()} if role == 'DEFAULT_ADMIN_ROLE' else {h}
        require(members.get(rid, set()) == expected, 'failed TL role membership mismatch')
        for member in expected:
            require(words(rpc.call(tl, 'hasRole(bytes32,address)', rid, member)) == [1], 'failed TL role readback mismatch')



def governance(rpc, cfg, safe):
    tl = cfg['timelockController']
    delay = words(rpc.call(tl, 'getMinDelay()'))[0]
    require(delay == 172800, 'unexpected initial delay')
    data = cast('calldata', 'updateDelay(uint256)', delay + 1)
    salt = cast('keccak', 'round6 governance rehearsal')
    schedule = cast('calldata', 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)', tl, 0, data, ZERO, salt, delay)
    execute = cast('calldata', 'execute(address,uint256,bytes,bytes32,bytes32)', tl, 0, data, ZERO, salt)
    def action():
        rpc.send(safe, schedule, tl)
        try:
            rpc('eth_call', {'from': safe, 'to': tl, 'data': execute}, 'latest')
        except RPCRevert as error:
            require(str(error).startswith(cast('sig', 'TimelockUnexpectedOperationState(bytes32,bytes32)')), 'wrong early-execution revert')
        else:
            raise RuntimeError('execution before delay succeeded')
        rpc('evm_increaseTime', delay); rpc('evm_mine')
        rpc.send(safe, execute, tl)
        require(words(rpc.call(tl, 'getMinDelay()')) == [delay + 1], 'governance readback failed')
    impersonate(rpc, safe, action)


def main():
    args = sys.argv[1:]
    inputs = None
    if '--inputs' in args:
        from deploylive_controls import load_inputs
        index = args.index('--inputs')
        require(index + 1 < len(args), '--inputs requires a file')
        inputs = args[index + 1]
        approved = load_inputs(inputs)
        os.environ.clear()
        os.environ.update(approved)
        del args[index:index + 2]
    external_tokens = None
    if '--external-tokens' in args:
        index = args.index('--external-tokens')
        require(index + 1 < len(args), '--external-tokens requires a file')
        token_path = Path(args[index + 1]).resolve()
        require(token_path.is_relative_to(ROOT), 'external tokens must be inside worktree')
        external_tokens = json.loads(token_path.read_text())
        del args[index:index + 2]
    argv = [sys.argv[0], *args]
    require(len(argv) in (6, 7), 'usage: MODE RPC CONFIG DEPLOYER SAFE [OPERATOR]')
    mode, url, config, deployer, safe = argv[1:6]
    require(mode in ('hook', 'guard', 'prepare', 'happy', 'failure', 'governance'), 'unknown mode')
    guard_bls_verbosity([], os.environ, tomllib.loads((ROOT/'foundry.toml').read_text())['profile']['default'].get('verbosity', 0))
    path = Path(config).resolve()
    require(path.is_relative_to(ROOT), 'config must be inside worktree')
    deploy_env = dict(os.environ, SP_COMMIT=clean_source_commit()) if mode in ("happy", "failure") else None
    rpc = RPC(url)  # All mutation paths share this mandatory guard.
    if mode == 'failure':
        require(int(rpc('eth_chainId'), 16) == 31337, 'failure requires chain 31337')
    cfg = {} if mode in ('happy', 'failure') else json.loads(path.read_text())
    evidence = Path(os.environ['DEPLOYLIVE_EVIDENCE_DIR'])
    require(evidence.is_dir(), 'evidence directory required')
    scalars = json.loads(os.environ['REHEARSAL_BLS_SCALARS'])
    source_rpc = os.environ['REHEARSAL_SOURCE_RPC']
    try:
        if mode in ('happy', 'failure'):
            command = [sys.executable, str(ROOT/'script/rehearsal/deploylive_fork_deploy.py'), url, deployer]
            if inputs is not None:
                command = [sys.executable, str(ROOT/'script/rehearsal/deploylive_fork_deploy.py'), 'deploy', '--inputs', inputs]
            if mode == 'failure': command.append('--stop')
            result = subprocess.run(command, env=deploy_env, capture_output=True, text=True)
            for line in getattr(result, 'stdout', '').splitlines():
                if line.startswith('STOP '): print(line)
            require(result.returncode == 0, 'deployment failed')
            if mode == 'happy':
                require(path == config_path(deploy_env), 'production config must use deployments/live/config.<ENV>.json')
            cfg = json.loads(path.read_text())
            if mode == 'failure':
                fail_bootstrap(rpc, cfg, deployer)
                cfg['deploymentStatus'] = 'ABANDONED'
                if external_tokens is not None: cfg['externalTokens'] = external_tokens
                path.write_text(json.dumps(cfg, indent=2) + '\n')
                from deploylive_failed_set_check import inventory
                lines = []
                inventory_ok = inventory(rpc, cfg, lines.append)
                (evidence/'failed-set.log').write_text('\n'.join(lines) + '\n')
                require(inventory_ok, 'failed set holds external value or inventory is incomplete')
            result = subprocess.run([sys.executable, str(ROOT/'script/rehearsal/deploylive_postdeploy_check.py'), url, str(path), deployer, safe], capture_output=True, text=True)
            (evidence/'checker.log').write_text(result.stdout)
            if mode == 'happy':
                checker_pass(result)
            else:
                require(result.returncode == 1, 'unexpected checker result')
        elif mode == 'governance':
            governance(rpc, cfg, safe)
        elif mode == 'prepare':
            prepare_operator(rpc, cfg, safe, argv[6] if len(argv) == 7 else cfg['genesisOperator'])
        elif mode == 'hook':
            hook(rpc, cfg, argv[6] if len(argv) == 7 else cfg['genesisOperator'])
    finally:
        scan_evidence(evidence, source_rpc, scalars)
    print('PASS ' + mode)


if __name__ == '__main__':
    try:
        require('--inputs' in sys.argv, 'every rehearsal mode requires --inputs')
        main()
    except Exception:
        print('FAIL rehearsal (endpoint/inputs/preconditions/transaction/check failed; details redacted)')
        sys.exit(1)
