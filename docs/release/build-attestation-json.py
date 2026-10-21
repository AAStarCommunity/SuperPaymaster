#!/usr/bin/env python3
# Assemble docs/release/v5.5.0-rc.2-attestation.json from the clean-build hash table
# (output of docs/release/attest-hashes.mjs) plus the recorded test/gate/PR results.
# Usage: python3 docs/release/build-attestation-json.py <clean-hashes.json>
import json
import sys

rows = json.load(open(sys.argv[1]))
VERSION = {
    'SuperPaymaster': 'SuperPaymaster-5.5.0',
    'SuperPaymasterAdmin': None,  # extension, reached via SP fallback; SP.version() covers it
    'SuperPaymasterLens': 'SuperPaymasterLens-1.2.0',
    'Registry': 'Registry-5.9.0',
    'xPNTsTokenV2': 'XPNTs-4.0.0',
    'xPNTsTokenV2Ext': None,  # extension of xPNTsTokenV2; token.version() covers it
    'xPNTsFactoryV2': 'xPNTsFactory-3.0.0-v2',
    'AOAProtocolRegistry': 'AOAProtocolRegistry-1.0.0',
    'GlobalTierSource': 'GlobalTierSource-1.0.0',
    'APNTsCapped': 'APNTsCapped-1.0.0',
}
for r in rows:
    r['versionLiteral'] = VERSION[r['contract']]

doc = {
    'intendedTag': 'v5.5.0-rc.2',
    'attestedCommit': '1ac0e1c595dc84e684b540ca6a936168e922194f',
    'attestedBranch': 'feat/aoa-balance-mode-5.5.0',
    'voided': {'v5.5.0-rc.1': '7ae5b3400308082928da4c180b8e3108ed00b288'},
    'toolchain': {
        'forge': '1.7.1 (4072e48705af9d93e3c0f6e29e93b5e9a40caed8)',
        'solc': '0.8.33+commit.64118f21',
        'profile': 'default',
        'optimizerRuns': 500,
        'registryRuns': 200,
        'viaIR': True,
        'evmVersion': 'cancun',
        'bytecodeHash': 'none',
    },
    'hashNote': 'runtimeKeccak / creationKeccak are keccak256 of forge artifacts (immutables zeroed); NOT on-chain codehashes',
    'reproducibility': {
        'cleanCheckoutBuild': 'fresh clone of attestedCommit; submodules chainlink-brownie-contracts + solady only; rm -rf cache out; forge build',
        'secondBuild': 'independent git worktree at the same commit, forge build (and again after a prague test run)',
        'result': '10/10 contracts identical (runtime and creation keccak)',
    },
    'contracts': rows,
    'tests': {
        'cancun': {'suites': 142, 'passed': 1731, 'failed': 0, 'skipped': 49},
        'prague': {'suites': 142, 'passed': 1640, 'failed': 0, 'skipped': 21},
    },
    'gates': {
        'check_storage_layout.py': 'OK (Registry = snapshot, 32 entries)',
        'check_storage_layout.py --negative-control': 'ok (rejects an OZ Ownable2Step base)',
        'check-sp-size.py': 'OK (core headroom 10832 >= 1024; 7 deployables <= EIP-170)',
        'check-sp-layout.py': 'OK (core == Admin, 42 entries)',
        'check-sp-selectors.py': 'OK (none shadowed; 18 hot-path selectors in core)',
        'check-xpnts-v2-layout.py': 'OK (57 entries)',
        'check-xpnts-v2-selectors.py': 'OK (none shadowed)',
        'pnpm gen:abi-docs:check': 'up to date',
        'node scripts/check-abi-bundle.mjs': 'abis/ matches compiled (full shape)',
    },
    'prs': [
        {'pr': 440, 'approvedHead': '3039ff6f', 'approver': 'clestons', 'approvedAt': '2026-09-27T04:28:48Z', 'merge': '4ba1e7b7'},
        {'pr': 442, 'approvedHead': '4d57a1c6', 'approver': 'clestons', 'approvedAt': '2026-09-27T05:15:23Z', 'merge': '898748c5'},
        {'pr': 443, 'approvedHead': '4ddf82a5', 'approver': 'clestons', 'approvedAt': '2026-09-27T06:14:19Z', 'merge': '53c303d5'},
        {'pr': 444, 'approvedHead': '4341b610', 'approver': 'clestons', 'approvedAt': '2026-09-27T06:35:52Z', 'merge': '1ac0e1c5'},
    ],
    'forkRehearsal': {
        'dir': 'docs/design/aoa-balance-mode/data/d5b/fork-rehearsal-full-11729160-b3e2d3eb/',
        'testedCommit': 'b3e2d3eb',
        'contractsSrcEqualToAttested': True,
        'manifestCheck': '61/61 OK (EVIDENCE.sha256 does not list itself)',
        'rehearsalLogSha256': '1832f9c9507fdc487ced5aa133c92c3795dee19c2baab78755d4a077a8c03594',
        'verdict': 'REHEARSAL OK (all), 0 "!!!" lines, 11/11 negative controls reverted',
        'archivedRuns': 1,
    },
    'status': {'implemented': True, 'reviewedPrDaemon': True, 'dsrAccepted': False, 'tagged': False},
}
open('docs/release/v5.5.0-rc.2-attestation.json', 'w').write(json.dumps(doc, indent=1) + '\n')
print('wrote docs/release/v5.5.0-rc.2-attestation.json')
