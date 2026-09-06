#!/usr/bin/env bash
# Install this repo's tracked hooks into the hooks directory git is ACTUALLY using.
#
# It does not touch core.hooksPath. This repo's hooksPath points at .git/hooks and the
# pre-commit secret scanner living there is known-good; rewiring it to .githooks has
# historically re-armed false positives that wedge every commit. So instead of moving the
# pointer, this copies into wherever the pointer already points -- verified, not assumed.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
dir=$(git rev-parse --git-path hooks)          # resolves core.hooksPath if set
[ -d "$dir" ] || mkdir -p "$dir"

install_one() {
  src="$root/.githooks/$1"; dst="$dir/$1"
  [ -f "$src" ] || { echo "missing $src" >&2; return 1; }
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp "$dst" "$dst.backup.$(date +%Y%m%d_%H%M%S)"
    echo "  backed up existing $1"
  fi
  cp "$src" "$dst"; chmod +x "$dst"
  echo "  installed $1 -> $dst"
}

echo "hooks dir: $dir"
install_one reference-transaction

# Prove it, rather than announcing it. A hook that is present but not firing is the exact
# failure this was written to remove, so the installer refuses to report success on a
# claim it has not tested. The canary is created and deleted inside this check.
echo "verifying (canary delete must be REJECTED, unprotected delete must SUCCEED)..."
canary="deploy/__install_check__"
plain="__install_check_unprotected__"
git branch -f "$canary" HEAD >/dev/null 2>&1
git branch -f "$plain"  HEAD >/dev/null 2>&1

if git branch -D "$canary" >/dev/null 2>&1; then
  echo "FAIL: protected canary was deleted -- the hook is NOT firing" >&2
  git branch -D "$plain" >/dev/null 2>&1 || true
  exit 1
fi
if ! git branch -D "$plain" >/dev/null 2>&1; then
  echo "FAIL: an UNPROTECTED branch was also blocked -- the hook is too broad" >&2
  PILOT_ALLOW_PROTECTED_DELETE=1 git branch -D "$canary" >/dev/null 2>&1 || true
  exit 1
fi
PILOT_ALLOW_PROTECTED_DELETE=1 git branch -D "$canary" >/dev/null 2>&1 || {
  echo "FAIL: the escape hatch did not work; '$canary' is left behind" >&2; exit 1; }

echo "OK: protected delete rejected, unprotected delete allowed, escape hatch works."
