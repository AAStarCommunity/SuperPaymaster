#!/usr/bin/env bash
# Regenerate the reviewable mutation patches without Forge or RPC.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/../.."
python3 - "${1:?Usage: $0 OUTPUT_DIRECTORY}" <<'PYTHON'
"""Regenerate procedure diffs against HEAD, carrying revised assertion bodies only where required; every anchor must be unique."""
from pathlib import Path
import difflib
import sys
import subprocess

source = Path('contracts/test/rams/RamsARouteRehearsal.t.sol')
base = subprocess.check_output(['git', 'show', 'HEAD:' + str(source)], text=True)
reviewed = source.read_text()
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

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
mutants[7] = scoped(base, a6, 'vm.warp(scheduled + DELAY - 1);', 'vm.warp(scheduled + DELAY);')
mutants[8] = replace(base, '        require(sp.guardian() == g.guardian, "RAMS gate: guardian");', '        // M8: guardian read-back omitted.')
mutants[9] = scoped(base, 'test_A2_newOperatorRisk_window', '_upgrade(true);', '_upgrade(false);')
a4 = 'test_A4_legacyContexts'
s = scoped(base, a4, '        _pauseAll(true);\n        _probe(signedBeforePause, false, 0);\n', '')
call = '            "RAMS A4: pre-signed operation escaped pause"\n        );'
mutants[10] = scoped(s, a4, call, call + '\n        _pauseAll(true);\n        _probe(signedBeforePause, false, 0);')
mutants[11] = replace(base, 'bytes32 requiredPredecessor = requiredBatch;', 'bytes32 requiredPredecessor = bytes32(0);')
mutants[12] = scoped(base, 'test_A3_atomicUpgradeWithGlobalPause', '            for (uint256 j; j < limits.length; ++j) {', '            if (operators[i] == ANNI) continue; // M12: skip one mandatory class.\n            for (uint256 j; j < limits.length; ++j) {')
mutants[13] = scoped(base, a6, '        vm.prank(ownerAccount);', '        vm.prank(address(tl));\n        tl.grantRole(keccak256("EXECUTOR_ROLE"), ownerAccount); // M13: bypass the earlier role audit.\n        vm.prank(ownerAccount);')
s = scoped(base, 'test_A3b_probeOnly_globalPause', '_upgrade(true);', '_upgrade(false);')
mutants[14] = replace(s, '        _assertUpgrade(atomicPause);', '        // M14: omit upgrade read-backs so only the probe discriminates.')
# M15: the prank must sit inside the condition, or an unconsumed prank at i == 0 breaks the next iteration
# (first version did exactly that: WRONG-ASSERTION in mutations-run4).
mutants[15] = replace(base, '            vm.prank(authority);\n            sp.setOperatorPaused(operators[i], stopped);\n            _assertOperatorPause(operators[i], stopped);\n', '            // M15: skip operator 0 and omit the pause read-back; the retained A1 probe must reject.\n            if (i != 0) {\n                vm.prank(authority);\n                sp.setOperatorPaused(operators[i], stopped);\n            }\n')
# M1-M15 remain byte-identical against HEAD. New controls travel with M16-M18
# until the owner commits the reviewed baseline; every patch still applies to HEAD.
def body(s, name):
    start = s.index('    function ' + name + '(')
    end = s.find('\n    function ', start + 1)
    return s[start:end if end >= 0 else len(s)]

def with_reviewed(*names):
    s = base
    for name in names:
        s = replace(s, body(s, name), body(reviewed, name))
    return s

s = with_reviewed('readbackGate', 'test_A7_readbackGate')
mutants[16] = scoped(s, 'test_A7_readbackGate', '        g.operatorPauses = new bool[](operators.length);', '        g.inventory[0] = g.inventory[0] == OWNER ? ANNI : OWNER; // M16: same length, configured and paused, different commitment.\n        g.operatorPauses = new bool[](operators.length);')
s = with_reviewed('test_A6c_registryRegistrationStop')
mutants[17] = scoped(s, 'test_A6c_registryRegistrationStop', '        config.isActive = false;', '        config.isActive = true; // M17: retain active role.')
# Remove the freeze read-back so the post-freeze exact-payload assertion discriminates.
mutants[17] = scoped(mutants[17], 'test_A6c_registryRegistrationStop', '        assertFalse(reg.getRoleConfig(SUPER).isActive, "RAMS: role stop read-back");\n', '')
a6b = 'test_A6b_safeRoute_preUpgradeGap'
s = with_reviewed(a6b)
s = scoped(s, a6b, '        bytes32 upgradeSalt =', '''        address[] memory gapTargets = new address[](2);
        gapTargets[0] = SP;
        gapTargets[1] = SP;
        uint256[] memory gapValues = new uint256[](2);
        bytes[] memory gapData = new bytes[](2);
        gapData[0] = upgrade;
        gapData[1] = abi.encodeWithSignature("setOperatorPaused(address,bool)", NEW_OPERATOR, true);
        bytes32 upgradeSalt =''')
s = scoped(s, a6b, 'tl.schedule(SP, 0, upgrade, bytes32(0), upgradeSalt, DELAY);', 'tl.scheduleBatch(gapTargets, gapValues, gapData, bytes32(0), upgradeSalt, DELAY);')
s = scoped(s, a6b, '        uint256 gapSnapshot =', '''        vm.prank(SAFE);
        tl.executeBatch(gapTargets, gapValues, gapData, bytes32(0), upgradeSalt);
        uint256 gapSnapshot =''')
mutants[18] = scoped(s, a6b, '        vm.prank(SAFE);\n        tl.execute(SP, 0, upgrade, bytes32(0), upgradeSalt);', '')
a6e = 'test_A6e_safeRoute_gapClosedByHolderPauseAndFreeze'
# M19: leave one residual holder unpaused; skip the whole loop body so no prank is left unconsumed (M15 lesson).
mutants[19] = scoped(base, a6e, '        for (uint256 i; i < residual.length; ++i) {\n            vm.prank(spOwner);', '        for (uint256 i; i < residual.length; ++i) {\n            if (i == 0) continue; // M19: one residual holder not pre-paused.\n            vm.prank(spOwner);')
# M20: no Registry freeze (keep the role active, drop its read-back).
s = scoped(base, a6e, '        config.isActive = false;\n        vm.prank(reg.owner());', '        config.isActive = true; // M20: no freeze.\n        vm.prank(reg.owner());')
mutants[20] = scoped(s, a6e, '        assertFalse(reg.getRoleConfig(SUPER).isActive, "RAMS A6e: role stop read-back");\n', '')
for n, mutated in mutants.items():
    diff = ''.join(difflib.unified_diff(base.splitlines(True), mutated.splitlines(True), fromfile='a/' + str(source), tofile='b/' + str(source)))
    (out / f'M{n}.diff').write_text(diff)
print(f'Generated {len(mutants)} unique-anchor patches')
PYTHON
