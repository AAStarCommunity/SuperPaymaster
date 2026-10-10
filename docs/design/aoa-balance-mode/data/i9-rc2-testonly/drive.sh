#!/bin/bash
# Runs each I9 Halmos target ONCE, sequentially, on the clean rc.2 tree, wall cap 600 s each.
set -u
CLEAN=/private/tmp/claude-502/-Users-jason-Dev-aastar-SuperPaymaster/13f6212e-b200-423b-852b-995b2d8a30a5/scratchpad/rc2clean
OUT=/private/tmp/claude-502/-Users-jason-Dev-aastar-SuperPaymaster/13f6212e-b200-423b-852b-995b2d8a30a5/scratchpad/i9ae7d/out
mkdir -p "$OUT"
cd "$CLEAN"
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
# One fresh build of the clean tree with halmos' OWN build command (halmos/__main__.py:1766),
# outside every wall cap; each target then runs with --keep-cache so its wall cap measures
# symbolic execution, not a via_ir rebuild of the whole repo.
rm -rf cache out
date -u +%FT%TZ > "$OUT/00-prebuild.start"
( time forge build --ast --root . --extra-output storageLayout metadata ) > "$OUT/00-prebuild.log" 2>&1
echo $? > "$OUT/00-prebuild.exit"
date -u +%FT%TZ > "$OUT/00-prebuild.end"
ps -A -o pid=,ppid=,pgid=,stat=,command= | grep -E "yices|z3|bitwuzla|halmos" | grep -v grep > "$OUT/00-ps-before" || true
i=0
while read -r contract check; do
  i=$((i+1)); tag=$(printf "%02d-%s" "$i" "$check")
  cmd=(python3 script/halmos/run-i9-witness.py --wall-cap 600 --solver-timeout-assertion 300s --keep-cache
       --log "$OUT/$tag.log" --contract "$contract" --check "$check")
  echo "${cmd[*]}" > "$OUT/$tag.cmd"
  date -u +%FT%TZ > "$OUT/$tag.start"
  uptime > "$OUT/$tag.load"
  "${cmd[@]}" > "$OUT/$tag.stdout" 2>&1
  echo $? > "$OUT/$tag.exit"
  date -u +%FT%TZ > "$OUT/$tag.end"
  # leftover solver processes whose cwd-independent ancestry we cannot see: record every
  # yices/z3/bitwuzla/halmos process on the box with its pgid, for the cleanup check
  ps -A -o pid=,ppid=,pgid=,stat=,command= | grep -E "yices|z3|bitwuzla|halmos" | grep -v grep > "$OUT/$tag.ps-after" || true
done <<'T'
SuperPaymasterI9HalmosTest check_I9_CF3_settleCannotSilentlyFail
SuperPaymasterI9HalmosTest check_witness_I9_freshBalanceSettlementReachable
SuperPaymasterI9Rc2HalmosTest check_I9_CF3ctx384_settleCannotSilentlyFail
SuperPaymasterI9Rc2HalmosTest check_witness_I9_posCharge352Reachable
SuperPaymasterI9Rc2HalmosTest check_witness_I9_posCharge384Reachable
T
echo ALLDONE > "$OUT/ALLDONE"
