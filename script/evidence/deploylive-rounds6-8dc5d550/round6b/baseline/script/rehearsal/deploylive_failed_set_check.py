#!/usr/bin/env python3
"""Inventory an ABANDONED set. A failed set never becomes deployable by passing this audit."""
import json
from pathlib import Path
import sys
from deploylive_rehearse import RPC, cast, words

CONTRACT_KEYS = '''registry registryImpl superPaymaster spImpl spAdminImpl gToken staking sbt aPNTs
xPNTsFactory xPNTsTokenV1Impl xPNTsFactoryV2 xPNTsTokenV2Impl xPNTsTokenV2Ext globalTierSource
superPaymasterLens aoaProtocolRegistry reputationSystem blsAggregator dvtValidator
microPaymentChannel paymasterFactory paymasterV4Impl x402Facilitator policyRegistry timelockController handoverBootstrap'''.split()


def inventory(rpc, cfg, emit=print):
    if any(k not in cfg for k in CONTRACT_KEYS): raise ValueError("incomplete contract inventory")
    addresses = sorted({cfg[k].lower() for k in CONTRACT_KEYS})
    allowed = {cfg['gToken'].lower(), cfg['aPNTs'].lower()}
    tokens = set(allowed)
    # Start at genesis: pre-funding a predicted address before deployment is still external value.
    logs = rpc('eth_getLogs', {'fromBlock': '0x0', 'toBlock': 'latest',
        'topics': [cast('keccak', 'Transfer(address,address,uint256)'), None, ['0x' + a[2:].zfill(64) for a in addresses]]})
    tokens.update(e['address'].lower() for e in logs)
    ok = True
    for address in addresses:
        balance = int(rpc('eth_getBalance', address, 'latest'), 16)
        emit(f"{'PASS' if balance == 0 else 'FAIL'} ETH {address} {balance}")
        ok &= balance == 0
        for token in sorted(tokens):
            balance = words(rpc.call(token, 'balanceOf(address)', address))[0]
            permitted = balance == 0 or token in allowed
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
