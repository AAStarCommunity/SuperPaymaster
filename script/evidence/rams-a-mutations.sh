#!/usr/bin/env bash
# --check-patches is local-only: no worktree, Forge, or RPC access.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source_file=contracts/test/rams/RamsARouteRehearsal.t.sol
scratch="$(mktemp -d "${TMPDIR:-/tmp}/rams-a-mutations.XXXXXXXX")"
worktree="$scratch/worktree"
cleanup() {
    if [[ -e "$worktree/.git" ]]; then
        git -C "$repo_root" worktree remove --force "$worktree" >&2 || return
    fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT
cat > "$scratch/mutate.py" <<'PY'
import pathlib
import sys

source, mutation, destination = sys.argv[1:]
s = pathlib.Path(source).read_text()


def replace(old, new):
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f'{mutation}: anchor must occur once; found {count}: {old!r}')
    s = s.replace(old, new, 1)


def scoped(function, old, new):
    global s
    start = s.index('    function ' + function + '(')
    end = s.find('\n    function ', start + 1)
    if end == -1:
        end = len(s)
    body = s[start:end]
    if body.count(old) != 1:
        raise SystemExit(f'{mutation}: scoped anchor not unique in {function}: {old!r}')
    s = s[:start] + body.replace(old, new, 1) + s[end:]


if mutation == 'M1':
    # Keep _assertUpgrade(true): mutate calldata, not the expected pause state.
    replace('atomicPause ? abi.encodeWithSignature("setGlobalPaused(bool)", true) : bytes("")',
            'atomicPause ? bytes("") : bytes("")')
elif mutation == 'M2':
    scoped('_pauseAll', 'sp.setOperatorPaused(operators[i], stopped);',
           'if (i != 0) sp.setOperatorPaused(operators[i], stopped);')
elif mutation == 'M3':
    scoped('test_A5_governanceTimeline_EOAowner', 'vm.warp(eta);', 'vm.warp(eta - 1);')
elif mutation == 'M4':
    # Move V2 setup/unpause and the existing 300k rejection probe BEFORE activation.
    setup = '''        _freshPrice();
        xPNTsTokenV2 token = _v2Ready();
        _pauseAll(false);
'''
    probe = '        _probe(_op(OWNER, 300_000, true), false, 0);\n'
    scoped('test_A5_governanceTimeline_EOAowner', setup, '')
    scoped('test_A5_governanceTimeline_EOAowner', probe, '')
    scoped('test_A5_governanceTimeline_EOAowner', '        vm.warp(eta);',
           setup + '        vm.prank(OWNER);\n        sp.setGlobalPaused(false);\n' + probe + '        vm.warp(eta);')
elif mutation == 'M5':
    # Queue the old SETTLE through the real API. Defer unchanged value read-backs
    # until after settlement so they cannot mask the Amsterdam positive control.
    scoped('test_A5_governanceTimeline_EOAowner', '        uint256 eta = _queue();',
           '''        vm.prank(OWNER);
        sp.queueGasParams(440_000, 160_000, 5000, 340_000);
        (, SuperPaymasterStorage.PendingGasParams memory queued) = sp.gasParams();
        uint256 eta = queued.eta;''')
    scoped('test_A5_governanceTimeline_EOAowner', '        _assertGas(true);\n', '')
    scoped('test_A5_governanceTimeline_EOAowner',
           '        _settleOne(op); // The orchestrator must run under nightly --hardfork amsterdam.',
           '        _settleOne(op); // The orchestrator must run under nightly --hardfork amsterdam.\n        _assertGas(true);')
elif mutation == 'M6':
    scoped('_timelock', '        tl = new TimelockController(DELAY, safeOnly, safeOnly, address(0));',
           '''        address[] memory executors = new address[](2);
        executors[0] = SAFE;
        executors[1] = ownerAccount;
        tl = new TimelockController(DELAY, safeOnly, executors, address(0));''')
elif mutation == 'M7':
    scoped('test_A6_governanceTimeline_SafeTimelock',
           '        tl.scheduleBatch(targets, values, data, bytes32(0), salt, DELAY);',
           '''        tl.scheduleBatch(targets, values, data, bytes32(0), salt, DELAY);
        bytes memory earlyData = abi.encodeWithSignature("executeGasParams()");
        bytes32 earlySalt = keccak256("RAMS M7 no predecessor");
        vm.prank(SAFE);
        tl.schedule(SP, 0, earlyData, bytes32(0), earlySalt, DELAY);''')
    scoped('test_A6_governanceTimeline_SafeTimelock',
           '        vm.warp(scheduled + DELAY);',
           '''        vm.warp(scheduled + DELAY);
        vm.prank(SAFE);
        tl.execute(SP, 0, earlyData, bytes32(0), earlySalt); // M7: before upgrade/queue batch.''')
elif mutation == 'M8':
    # The gate is the read-back procedure. Keep its guardian tamper control intact.
    scoped('readbackGate', '        require(sp.guardian() == g.guardian, "RAMS gate: guardian");',
           '        // M8: guardian read-back omitted.')
elif mutation == 'M9':
    scoped('test_A2_newOperatorRisk_window', '        _upgrade(true);', '        _upgrade(false);')
elif mutation == 'M10':
    scoped('test_A4_legacyContexts',
           '        _pauseAll(true);\n        _probe(signedBeforePause, false, 0);',
           '')
    scoped('test_A4_legacyContexts',
           '        ep.handleOps(rejected, payable(address(0xBEEF)));',
           '        ep.handleOps(rejected, payable(address(0xBEEF)));\n        _probe(signedBeforePause, false, 0);\n        _pauseAll(true);')
else:
    raise SystemExit(f'unknown mutation: {mutation}')
if s == pathlib.Path(source).read_text():
    raise SystemExit(f'{mutation}: no change')
pathlib.Path(destination).write_text(s)
print(f'{mutation}: unique anchors matched; patch applied')
PY
ids=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10)
tests=(
    test_A3_atomicUpgradeWithGlobalPause
    test_A1_oldPausePath_blocksAllOperators
    test_A5_governanceTimeline_EOAowner
    test_A5_governanceTimeline_EOAowner
    test_A5_governanceTimeline_EOAowner
    test_A6_governanceTimeline_SafeTimelock
    test_A6_governanceTimeline_SafeTimelock
    test_A7_readbackGate
    test_A2_newOperatorRisk_window
    test_A4_legacyContexts
)
reasons=(
    'RAMS: atomic global pause'
    'RAMS: operator pause read-back'
    'GasParamsTimelock'
    'RAMS: exact SIG_FAILURE required'
    'RAMS: exact legacy postOp failure|RAMS: bundle success mismatch|RAMS: missing settlement|RAMS: settlement reverted'
    'RAMS: extra executor'
    'FailedInnerCall|EvmError: Revert|unrecognized function selector'
    'next call did not revert as expected'
    'RAMS: exact SIG_FAILURE required'
    'next call did not revert as expected'
)
if [[ "${1:-}" == --check-patches ]]; then
    [[ $# -eq 1 ]] || exit 2
    for id in "${ids[@]}"; do
        python3 "$scratch/mutate.py" "$repo_root/$source_file" "$id" "$scratch/$id.sol"
    done
    exit 0
fi
[[ $# -eq 0 ]] || { printf 'Usage: %s [--check-patches]\n' "$0" >&2; exit 2; }
: "${SEPOLIA_FORK_RPC:?Set the archive RPC (never printed)}"
: "${FORK_BLOCK:?Set the pinned fork block (rehearsal: 11974561)}"
: "${OPERATORS:?Supply the complete deduplicated archive operator inventory}"
forge_bin="${FORGE:-forge}"
forge_bin="$(command -v "$forge_bin")"
# Resolve a relative FORGE before changing cwd.
[[ "$forge_bin" == /* ]] || forge_bin="$PWD/$forge_bin"
command -v rsync >/dev/null
export FOUNDRY_ISOLATE=false FOUNDRY_OFFLINE=true NO_COLOR=1 TERM=dumb
# A real detached worktree; overlay the current checkout, including untracked RAMS
# files and local changes. Dependencies are copied, never patched or initialized
# over the network. Build/cache outputs are private to this temporary worktree.
git -C "$repo_root" worktree add --detach "$worktree" HEAD >&2
rsync -a --exclude=.git --exclude=out --exclude=cache --exclude=node_modules \
    "$repo_root/" "$worktree/"
cp "$worktree/$source_file" "$scratch/control.sol"
run_dir="$repo_root/docs/design/aoa-balance-mode/data/rams-a/mutations-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$run_dir"
cp "$scratch/control.sol" "$run_dir/control.sol"
git -C "$repo_root" rev-parse HEAD > "$run_dir/commit.txt"
# Redact RPC URL from all Forge output before persisting or printing it.
cat > "$scratch/redact.py" <<'PY'
import os
import sys
secret = os.environ['SEPOLIA_FORK_RPC']
for line in sys.stdin:
    sys.stdout.write(line.replace(secret, '<SEPOLIA_FORK_RPC>'))
PY
run_forge() {
    local name="$1"
    shift
    (
        cd "$worktree"
        printf 'FORK_BLOCK=%s\nOPERATORS=%s\nFOUNDRY_ISOLATE=false\nFOUNDRY_OFFLINE=true\n' "$FORK_BLOCK" "$OPERATORS"
        "$forge_bin" --version
        printf 'forge test --match-path %s --no-isolate -vvv --hardfork amsterdam' "$source_file"
        printf ' %q' "$@"
        printf '\n'
        "$forge_bin" test --match-path "$source_file" --no-isolate -vvv --hardfork amsterdam "$@"
    ) 2>&1 | python3 "$scratch/redact.py" > "$run_dir/$name.log"
}
# Parse actual named test result lines, never count compilation/RPC failures or
# skipped tests as kills. A nonzero exit is insufficient evidence on its own.
cat > "$scratch/result.py" <<'PY'
import pathlib
import re
import sys
name, test, pattern, rc, log = sys.argv[1:]
s = pathlib.Path(log).read_text()
s = re.sub(r'\x1b\[[0-9;]*m', '', s)
if name == 'CONTROL':
    passes = re.findall(r'^\[PASS\] (test_\w+)\(', s, re.M)
    expected = set(re.findall(r'function (test_\w+)\(', pathlib.Path(__file__).with_name('control.sol').read_text()))
    ok = int(rc) == 0 and set(passes) == expected and bool(expected) and not re.search(r'^\[(?:FAIL|SKIP)', s, re.M)
    print(f'CONTROL\t{"GREEN" if ok else "INVALID"}\t{len(set(passes))}/{len(expected)} named route passes\t{log}')
else:
    failures = re.findall(r'^\[FAIL: (.*?)\] ' + re.escape(test) + r'\(', s, re.M)
    reason = failures[0] if failures else 'No named target failure (infrastructure/compile/skip/survivor)'
    ok = int(rc) != 0 and bool(failures) and bool(re.search(pattern, reason, re.I))
    print(f'{name}\t{"KILLED" if ok else "INVALID/SURVIVED"}\t{test}: {reason}\t{log}')
sys.exit(0 if ok else 1)
PY
printf 'ID\tRESULT\tOBSERVED TEST / MESSAGE\tLOG\n' > "$run_dir/summary.tsv"
overall=0
rc=0
run_forge CONTROL || rc=$?
python3 "$scratch/result.py" CONTROL '' '' "$rc" "$run_dir/CONTROL.log" >> "$run_dir/summary.tsv" || overall=1
# Each mutant starts from the very same unmutated file, never the previous mutant.
for i in "${!ids[@]}"; do
    id="${ids[$i]}"
    python3 "$scratch/mutate.py" "$scratch/control.sol" "$id" "$worktree/$source_file" > "$run_dir/$id.patch-check.txt"
    diff -u "$scratch/control.sol" "$worktree/$source_file" > "$run_dir/$id.diff" || [[ $? -eq 1 ]]
    rc=0
    run_forge "$id" --match-test "^${tests[$i]}$" || rc=$?
    python3 "$scratch/result.py" "$id" "${tests[$i]}" "${reasons[$i]}" "$rc" "$run_dir/$id.log" >> "$run_dir/summary.tsv" || overall=1
done
cat "$run_dir/summary.tsv"
printf 'Evidence: %s\n' "$run_dir"
exit "$overall"
