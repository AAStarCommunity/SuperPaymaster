#!/usr/bin/env python3
"""Anvil-fork-only exit-hook tools. No keys; impersonated senders only."""
import json
from pathlib import Path
import subprocess
import sys
import time
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler

ROOT = Path(__file__).resolve().parents[2]
ZERO = '0x' + '00' * 32
ROLES = ('PROPOSER_ROLE', 'EXECUTOR_ROLE', 'CANCELLER_ROLE')


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def local_endpoint(url):
    p = urlsplit(url)
    require(p.scheme == 'http' and p.hostname in ('127.0.0.1', '::1', 'localhost')
            and p.username is None and p.password is None, 'loopback HTTP endpoint required')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('RPC redirect refused')


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
            require('error' not in result, 'RPC failed')
            return result['result']
        except Exception:
            raise RuntimeError('RPC failed (details redacted)') from None

    def call(self, target, signature, *args):
        return self('eth_call', {'to': target, 'data': cast('calldata', signature, *args)}, 'latest')

    def send(self, sender, data='0x', to=None, nonce=None):
        tx = {'from': sender, 'data': data, 'gas': hex(12_000_000)}
        if to is not None:
            tx['to'] = to
        if nonce is not None:
            tx['nonce'] = hex(nonce)
        txhash = self('eth_sendTransaction', tx)
        for _ in range(120):
            receipt = self('eth_getTransactionReceipt', txhash)
            if receipt:
                require(int(receipt['status'], 16) == 1, 'transaction reverted')
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


def main():
    require(len(sys.argv) in (6, 7), 'usage: MODE RPC CONFIG DEPLOYER SAFE [OPERATOR]')
    mode, url, config, deployer, safe = sys.argv[1:6]
    require(mode in ('hook', 'guard', 'prepare'), 'unknown mode')
    path = Path(config).resolve()
    require(path.is_relative_to(ROOT), 'config must be inside worktree')
    rpc = RPC(url)  # All mutation paths share this mandatory guard.
    cfg = json.loads(path.read_text())
    if mode == 'prepare':
        prepare_operator(rpc, cfg, safe, sys.argv[6] if len(sys.argv) == 7 else cfg['genesisOperator'])
    elif mode == 'hook':
        hook(rpc, cfg, sys.argv[6] if len(sys.argv) == 7 else cfg['genesisOperator'])
    print('PASS ' + mode)


if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('FAIL rehearsal (endpoint/inputs/preconditions/transaction/check failed; details redacted)')
        sys.exit(1)
