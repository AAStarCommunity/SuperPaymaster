#!/usr/bin/env python3
"""One named tamper on a copy of an exported aoa-m3-receive-v1 package (used by aoa-m3-receive-controls.sh).

Each edit violates exactly one checker rule, so the control can require that rule's diagnostic.
"""
import json, sys
from pathlib import Path

root, name = Path(sys.argv[1]), sys.argv[2]
p = root / 'receive.json'
pkg = json.loads(p.read_text())
inc = [a for a in pkg['attempts'] if a['included']]
first = inc[0]

if name == 'raw-file-edited':
    f = root / first['uoeFile']
    f.write_text(f.read_text().replace('true', 'false'))
elif name == 'uoe-deleted':
    (root / first['uoeFile']).unlink()
elif name == 'duplicate-userop':
    # Another group's same-arm row reuses first's userOpHash: every group still has exactly one SP/VPM/TPM,
    # so the duplicate identity is the only violation.
    other = next(a for a in inc if a['pairId'] != first['pairId'] and a['paymasterKind'] == first['paymasterKind'])
    other['userOpHash'] = first['userOpHash']
elif name == 'chain-changed':
    first['chainId'] = 1
elif name == 'arm-missing':
    pkg['attempts'].remove(first)
elif name == 'injected-in-typical':
    first['injectedScenario'] = 'postop-revert'
elif name == 'settlement-unverified':
    first['settlementVerified'] = False
elif name == 'bundler-config-differs':
    first['bundlerConfigHash'] = '0x' + '77' * 32
else:
    sys.exit(f'unknown tamper {name}')
p.write_text(json.dumps(pkg, indent=1) + '\n')
