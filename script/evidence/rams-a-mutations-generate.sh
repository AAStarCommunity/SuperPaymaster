#!/usr/bin/env bash
# Regenerate the reviewable mutation patches without Forge or RPC.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/../.."
python3 - <<'PYTHON'
"""Regenerate procedure diffs from the current rehearsal; every anchor must be unique."""
from pathlib import Path
import difflib

source = Path('contracts/test/rams/RamsARouteRehearsal.t.sol')
base = source.read_text()
out = Path('docs/design/aoa-balance-mode/data/rams-a/mutations-run2')

def replace(s, old, new):
    assert s.count(old) == 1, (old, s.count(old))
    return s.replace(old, new)

def scoped(s, name, old, new):
    start = s.index('    function ' + name + '(')
    end = s.find('\n    function ', start + 1)
    if end < 0:
        end = len(s)
    return s[:start] + replace(s[start:end], old, new) + s[end:]

mutants = {}
mutants[1] = replace(base, 'atomicPause ? abi.encodeWithSignature("setGlobalPaused(bool)", true) : bytes("")', 'atomicPause ? bytes("") : bytes("")')
mutants[2] = replace(base, 'sp.setOperatorPaused(operators[i], stopped);', 'if (i != 0) sp.setOperatorPaused(operators[i], stopped);')
a5 = 'test_A5_governanceTimeline_EOAowner'
mutants[3] = scoped(base, a5, 'vm.warp(eta);', 'vm.warp(eta - 1);')
setup = '        _freshPrice();\n        xPNTsTokenV2 token = _v2Ready();\n        _pauseAll(false);\n'
probe = '        _probe(_op(OWNER, 300_000, true), false, 0);\n'
s = scoped(base, a5, setup, '')
s = scoped(s, a5, probe, '')
mutants[4] = scoped(s, a5, '        vm.warp(eta);', setup + '        vm.prank(OWNER);\n        sp.setGlobalPaused(false);\n' + probe + '        vm.warp(eta);')
s = scoped(base, a5, 'uint256 eta = _queue();', 'vm.prank(OWNER);\n        sp.queueGasParams(440_000, 160_000, 5000, 340_000);\n        (, SuperPaymasterStorage.PendingGasParams memory queued) = sp.gasParams();\n        uint256 eta = queued.eta;')
s = scoped(s, a5, '        _assertGas(true);\n', '')
settle = '        _settleOne(op); // The orchestrator must run under nightly --hardfork amsterdam.'
mutants[5] = scoped(s, a5, settle, settle + '\n        _assertGas(true);')
mutants[6] = replace(base, 'tl = new TimelockController(DELAY, safeOnly, safeOnly, address(0));', 'address[] memory executors = new address[](2);\n        executors[0] = SAFE;\n        executors[1] = ownerAccount;\n        tl = new TimelockController(DELAY, safeOnly, executors, address(0));')
a6 = 'test_A6_governanceTimeline_SafeTimelock'
s = scoped(base, a6, '        assertEq(tl.getTimestamp(batchId)', '        bytes memory earlyData = abi.encodeWithSignature("executeGasParams()");\n        bytes32 earlySalt = keccak256("RAMS M7 no predecessor");\n        vm.prank(SAFE);\n        tl.schedule(SP, 0, earlyData, bytes32(0), earlySalt, DELAY);\n        assertEq(tl.getTimestamp(batchId)')
mutants[7] = scoped(s, a6, '        vm.warp(scheduled + DELAY);', '        vm.warp(scheduled + DELAY);\n        vm.prank(SAFE);\n        tl.execute(SP, 0, earlyData, bytes32(0), earlySalt);')
mutants[8] = replace(base, '        require(sp.guardian() == g.guardian, "RAMS gate: guardian");', '        // M8: guardian read-back omitted.')
mutants[9] = scoped(base, 'test_A2_newOperatorRisk_window', '_upgrade(true);', '_upgrade(false);')
a4 = 'test_A4_legacyContexts'
s = scoped(base, a4, '        _pauseAll(true);\n        _probe(signedBeforePause, false, 0);\n', '')
call = '        ep.handleOps(rejected, payable(address(0xBEEF)));'
mutants[10] = scoped(s, a4, call, call + '\n        _pauseAll(true);\n        _probe(signedBeforePause, false, 0);')
mutants[11] = replace(base, 'bytes32 requiredPredecessor = requiredBatch;', 'bytes32 requiredPredecessor = bytes32(0);')
mutants[12] = scoped(base, 'test_A3_atomicUpgradeWithGlobalPause', '            for (uint256 j; j < limits.length; ++j) {', '            if (operators[i] == ANNI) continue; // M12: skip one mandatory class.\n            for (uint256 j; j < limits.length; ++j) {')
mutants[13] = scoped(base, a6, '        vm.prank(ownerAccount);', '        vm.prank(address(tl));\n        tl.grantRole(keccak256("EXECUTOR_ROLE"), ownerAccount); // M13: bypass the earlier role audit.\n        vm.prank(ownerAccount);')
for n, mutated in mutants.items():
    diff = ''.join(difflib.unified_diff(base.splitlines(True), mutated.splitlines(True), fromfile='a/' + str(source), tofile='b/' + str(source)))
    (out / f'M{n}.diff').write_text(diff)
print(f'Generated {len(mutants)} unique-anchor patches')
PYTHON
