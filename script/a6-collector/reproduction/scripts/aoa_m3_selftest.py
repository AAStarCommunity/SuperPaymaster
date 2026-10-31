#!/usr/bin/env python3
"""Synthetic acceptance and rejection checks; none of these rows are research evidence."""
import copy
import hashlib
import tempfile
from pathlib import Path
from aoa_m3_check import CONTROLS, check

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    (root / "synthetic.json").write_text('{}')
    package = {"schema": "aoa-m3-receive-v1", "files": {"synthetic.json": hashlib.sha256(b'{}').hexdigest()}, "attempts": []}
    for i, system in enumerate(("SP", "VerifyingPaymaster", "TokenPaymaster")):
        row = {"attemptId": str(i), "pairId": "synthetic-pair", "included": True, "paymasterKind": system,
               "chainId": 31337, "receiptStatus": 1, "userOpSuccess": True, "settlementVerified": True}
        for field in ("txHash", "userOpHash", "blockHash", "runtimeCodeHash"):
            row[field] = '0x' + format(i + 1, '064x')
        for field in ("actualGasUsed", "actualGasCostWei", "txGasUsed", "effectiveGasPriceWei"):
            row[field] = '1'
        for field in ("receiptFile", "uoeFile", "passportFile", "stateFile"):
            row[field] = 'synthetic.json'
        row.update(dict.fromkeys(CONTROLS, 'synthetic'))
        package['attempts'].append(row)
    assert not check(package, root, 1)['errors']
    cases = {
        "tx-success-uoe-failure": lambda p: p['attempts'][0].update(userOpSuccess=False),
        "duplicate-userop": lambda p: p['attempts'][1].update(userOpHash=p['attempts'][0]['userOpHash']),
        "missing-arm": lambda p: p['attempts'].pop(),
        "mixed-calldata": lambda p: p['attempts'][0].update(calldataHash='different'),
        "injected-in-typical": lambda p: p['attempts'][0].update(injectedScenario='no_sbt'),
        "unexplained-exclusion": lambda p: p['attempts'].append({'attemptId': 'failed', 'included': False, 'paymasterKind': 'SP'}),
        "hash-tampering": lambda p: p['files'].update({'synthetic.json': '0' * 64}),
        "path-traversal": lambda p: p['files'].update({'../escape': '0' * 64}),
        "missing-passport": lambda p: p['attempts'][0].update(passportFile='missing'),
        "unverified-settlement": lambda p: p['attempts'][0].update(settlementVerified=False),
    }
    for name, mutate in cases.items():
        candidate = copy.deepcopy(package)
        mutate(candidate)
        assert check(candidate, root, 1)['errors'], name
    assert check(package, root, 50)['errors']
    print('PASS: synthetic positive; 10 negative controls; formal n=50 rejects single group')
