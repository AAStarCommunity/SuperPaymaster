#!/usr/bin/env bash
# =============================================================================
# Probe matrix for the invocation detector in ../check-live-scripts-compile.sh.
#
# That detector answers "does this entry point still INVOKE forge script", and it
# was wrong five times in a row, each time in a way its own probes called green.
# The rule that finally held is not a better pattern — it is a different question
# (is the occurrence at a command position?) — and what forced it was measuring
# fifteen real invocation forms instead of the four someone thought of.
#
# RUN THIS BEFORE CHANGING THE DETECTOR, not after. A stricter detector passes
# every negative row while rejecting real invocations; only the positive rows can
# see that. Add the row first, watch it go red, then change the implementation.
#
#   ./scripts/probes/check-live-scripts-invocation-matrix.sh
#
# Every row must print "ok". The script restores deploy-core and asserts it is
# byte-identical afterwards.
# =============================================================================
# Test the tree this script lives in, not one particular checkout. The path was
# hardcoded, so the probe measured the main checkout no matter where it ran: in a
# worktree holding a gate with twelve holes it still reported every row ok. Its own
# header says "run this BEFORE changing the detector" and "watch it go red" — and
# that use happens in the tree being edited, the one place it could not see. Found
# by pr-daemon; the seventh instance today of a check examining something adjacent
# to what its green tick claimed, this time inside the probe built to end that.
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
ORIG=$(mktemp -t dc.orig.XXXXXX)   # not a fixed /tmp path: two runs would collide
# RESTORE, then delete. `trap rm EXIT` deleted the only copy of the original while
# leaving deploy-core rewritten: measured, TERM at t=5s left 7/32 rows done, the file
# mutated and zero backups on disk. The old hardcoded /tmp/dc.orig at least survived
# to be copied back by hand. Found by Codex at stop-time.
# A trapped INT/TERM does NOT terminate the script - the handler runs and execution
# continues. The first cut of this fix therefore restored deploy-core mid-run, deleted
# the backup, then carried on rewriting the file with no copy left to restore from:
# measured, TERM at t=5s produced a run that completed all 32 rows and STILL left the
# file dirty. So the handler exits explicitly, and cleanup is idempotent because the
# EXIT trap fires again on the way out.
cleanup() {
  [ -n "${CLEANED:-}" ] && return
  CLEANED=1
  cp "$ORIG" deploy-core 2>/dev/null
  rm -f "$ORIG"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
cp deploy-core "$ORIG"
kill_real(){ cp "$ORIG" deploy-core; python3 -c "
p='deploy-core';L=open(p).read().split('\n')
for i,l in enumerate(L):
    if 'forge script' in l and not l.lstrip().startswith('#') and 'echo' not in l: L[i]='#'+l
open(p,'w').write('\n'.join(L))"; }
probe(){ # name expect snippet
  kill_real; printf '%s\n' "$3" >> deploy-core
  ./scripts/check-live-scripts-compile.sh >/dev/null 2>&1; local rc=$?
  local mark="ok "; [ "$rc" != "$2" ] && mark="RED"
  printf '  %s  %-46s want=%s got=%s\n' "$mark" "$1" "$2" "$rc"
}
S='contracts/script/v3/DeployLive.s.sol:DeployLive'
echo "--- POSITIVE controls (real invocations, want 0) ---"
probe "plain indented"            0 "go(){
    forge script \"$S\"
}"
probe "one-line function body"    0 "go(){ forge script \"$S\"; }"
probe "bash -c"                   0 "go(){ bash -c \"CONFIG_FILE=x forge script $S\"; }"
probe "eval"                      0 "go(){ eval \"forge script $S\"; }"
probe "[ cond ] && cmd"           0 "[ -n \"\$X\" ] && forge script \"$S\""
probe "[[ cond ]] && cmd"         0 "[[ -n \"\$X\" ]] && forge script \"$S\""
probe "test cond && cmd"          0 "test -n \"\$X\" && forge script \"$S\""
probe "command substitution"      0 "OUT=\$(forge script \"$S\")"
probe "pipe into tee"             0 "forge script \"$S\" | tee /dev/null"
probe "time prefix"               0 "time forge script \"$S\""
probe "sudo prefix"               0 "sudo forge script \"$S\""
probe "case arm"                  0 "case \$1 in
  live) forge script \"$S\" ;;
esac"
probe "for/do body"               0 "for i in 1; do forge script \"$S\"; done"
probe "subshell"                  0 "( forge script \"$S\" )"
probe "|| fallback"               0 "false || forge script \"$S\""
probe "sh -c with cd &&"          0 "go(){ sh -c \"cd . && forge script $S\"; }"
probe "bash -c with env assign"   0 "go(){ bash -c \"CONFIG_FILE=x forge script $S\"; }"
probe "genuinely nested sh -c"    0 "go(){ bash -c \"sh -c 'forge script $S'\"; }"
probe "eval wrapping bash -c"     0 "go(){ eval \"bash -c 'forge script $S'\"; }"
echo "--- NEGATIVE controls (printed text, want 2) ---"
probe "echo hint"                 2 "hint(){ echo \"  Run: forge script $S\"; }"
probe "heredoc body"              2 "u(){ cat <<EOF
    forge script $S
EOF
}"
probe "string assignment"         2 "USAGE=\"  forge script $S\""
probe "echo printing bash -c"     2 "hint(){ echo \"  bash -c 'forge script $S'\"; }"
probe "assignment storing bash-c" 2 "CMD=\"bash -c 'forge script $S'\""
probe "printf printing eval"      2 "hint(){ printf '%s\n' \"  eval forge script $S\"; }"
probe "inline : # comment"        2 "    : # forge script \"$S\""
probe "echo printing [ ] && cmd"  2 "hint(){ echo \"  [ -n \\\$X ] && forge script $S\"; }"
probe "bash -c that only echoes"  2 "go(){ bash -c \"echo forge script $S\"; }"
probe "eval that only echoes"     2 "go(){ eval \"echo forge script $S\"; }"
probe "bash -c printf"            2 "go(){ bash -c \"printf '%s' 'forge script $S'\"; }"
probe "echo naming a nested -c"   2 "go(){ bash -c \"echo bash -c forge script $S\"; }"
probe "echo naming nested sh -c"  2 "go(){ bash -c \"echo sh -c 'forge script $S'\"; }"
cp "$ORIG" deploy-core
echo "--- restored ---"; ./scripts/check-live-scripts-compile.sh >/dev/null 2>&1; echo "  intact exit=$?"
git diff --stat -- deploy-core|tail -1
