#!/usr/bin/env python3
"""Inventory an ABANDONED set. A failed set never becomes deployable by passing this audit."""
import json
import os
import re
from pathlib import Path
import sys
from deploylive_rehearse import RPC, cast

CONTRACT_KEYS = '''registry registryImpl superPaymaster spImpl spAdminImpl gToken staking sbt aPNTs
xPNTsFactory xPNTsTokenV1Impl xPNTsFactoryV2 xPNTsTokenV2Impl xPNTsTokenV2Ext globalTierSource
superPaymasterLens aoaProtocolRegistry reputationSystem blsAggregator dvtValidator
microPaymentChannel paymasterFactory paymasterV4Impl x402Facilitator policyRegistry timelockController handoverBootstrap'''.split()


def inventory(rpc, cfg, emit=print):
    if any(k not in cfg for k in CONTRACT_KEYS): raise ValueError("incomplete contract inventory")
    addresses = sorted({cfg[k].lower() for k in CONTRACT_KEYS})
    try:
        groups = cfg.get('externalTokens')
        if groups is None:
            path = os.environ.get('EXTERNAL_TOKENS_FILE', str(Path(__file__).with_name('inputs') / 'external-tokens.json'))
            groups = json.loads(Path(path).read_text())
        chain = str(int(rpc('eth_chainId'), 16))
        listed = groups.get(chain)
        if not isinstance(listed, list) or not listed:
            raise ValueError('missing chain group')
        for token in listed:
            if not isinstance(token['label'], str) or not token['label'].strip() or not re.fullmatch(r'0x[0-9a-fA-F]{40}', token['address']):
                raise ValueError('invalid token entry')
            if type(token['decimals']) is not int or not 0 <= token['decimals'] <= 255:
                raise ValueError('invalid decimals')
    except (KeyError, ValueError, TypeError, OSError):
        emit('FAIL external token chain group / inputs unreadable or invalid')
        return False
    ok = True
    readable = {}
    for token in listed:
        address = token['address'].lower()
        try:
            code = rpc('eth_getCode', address, 'latest')
            valid = isinstance(code, str) and re.fullmatch(r'0x(?:[0-9a-fA-F]{2})+', code) is not None
        except Exception:
            valid = False
        emit(f"{'PASS' if valid else 'FAIL'} TOKEN CODE {token['label']} {address}")
        ok &= valid
        readable[address] = valid
    allowed = {cfg['gToken'].lower(), cfg['aPNTs'].lower()}
    tokens = set(allowed) | set(readable)
    # Start at genesis: pre-funding a predicted address before deployment is still external value.
    logs = rpc('eth_getLogs', {'fromBlock': '0x0', 'toBlock': 'latest',
        'topics': [cast('keccak', 'Transfer(address,address,uint256)'), None, ['0x' + a[2:].zfill(64) for a in addresses]]})
    tokens.update(e['address'].lower() for e in logs)
    for address in addresses:
        balance = int(rpc('eth_getBalance', address, 'latest'), 16)
        emit(f"{'PASS' if balance == 0 else 'FAIL'} ETH {address} {balance}")
        ok &= balance == 0
        for token in sorted(tokens):
            if token in readable and not readable[token]: continue
            try:
                raw = rpc.call(token, 'balanceOf(address)', address)
                if not isinstance(raw, str) or not re.fullmatch(r'0x[0-9a-fA-F]{64}', raw):
                    raise ValueError('invalid balance return')
                balance = int(raw, 16)
            except Exception:
                emit(f'FAIL TOKEN {token} holder {address} unreadable balance')
                ok = False
                continue
            permitted = balance == 0 or (token in allowed and token not in readable)
            emit(f"{'PASS' if permitted else 'FAIL'} TOKEN {token} holder {address} balance {balance}")
            ok &= permitted
    # Inventory all registrations, including registrations subsequently exited.
    logs = rpc('eth_getLogs', {'address': cfg['registry'], 'fromBlock': hex(int(cfg['deploymentStartBlock'])), 'toBlock': 'latest',
        'topics': [cast('keccak', 'RoleRegistered(bytes32,address,uint256,uint256)')]})
    accounts = set(cfg.get('guardians', []) + [cfg['genesisOperator']])
    if cfg.get('deployer'): accounts.add(cfg['deployer'])
    for event in logs:
        accounts.add('0x' + event['topics'][2][-40:])
        emit('REGISTRATION EVENT ' + json.dumps(event, sort_keys=True))
    for account in sorted(accounts):
        emit(f"REGISTRATIONS {account} {rpc.call(cfg['registry'], 'getUserRoles(address)', account)}")
    emit('ABANDONED addresses ' + ','.join(addresses))
    return ok


def main():
    rpc = RPC(sys.argv[1])
    cfg = json.loads(Path(sys.argv[2]).read_text())
    ok = inventory(rpc, cfg)
    print('FAILED-SET INVENTORY ' + ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    try: sys.exit(main())
    except Exception:
        print('FAILED-SET INVENTORY FAIL (incomplete reads; details redacted)')
        sys.exit(1)
