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

MARKER="PILOT_REF_GUARD_V1"
adopt=0
[ "${1:-}" = "--replace-foreign-hook" ] && adopt=1

# Installing a hook is itself a way to REMOVE a protection: a reference-transaction hook
# may already be enforcing something else entirely (an org policy, a force-push guard),
# and copying over it disables that silently while this script reports success. A backup
# nobody reads is not a mitigation. So: refuse, unless the file carries our marker or the
# operator says otherwise in as many words.
install_one() {
  src="$root/.githooks/$1"; dst="$dir/$1"
  [ -f "$src" ] || { echo "missing $src" >&2; return 1; }

  if [ -e "$dst" ]; then
    if cmp -s "$src" "$dst"; then echo "  $1 already current"; return 0; fi
    if grep -q "$MARKER" "$dst" 2>/dev/null; then
      cp "$dst" "$dst.backup.$(date +%Y%m%d_%H%M%S)"
      echo "  upgrading our own $1 (previous version backed up)"
    elif [ "$adopt" = "1" ]; then
      cp "$dst" "$dst.backup.$(date +%Y%m%d_%H%M%S)"
      echo "  WARNING: replacing a FOREIGN $1 at the operator's explicit request;"
      echo "           whatever it enforced is no longer enforced. Backup kept."
    else
      echo "" >&2
      echo "REFUSING to install: $dst already exists and is NOT ours" >&2
      echo "  (no $MARKER marker). Overwriting it would silently disable whatever it" >&2
      echo "  enforces, while this script printed success." >&2
      echo "" >&2
      echo "  Read it first:  cat $dst" >&2
      echo "  Then either chain it into .githooks/$1 by hand, or, if you are certain" >&2
      echo "  it is disposable:  bash scripts/install-git-hooks.sh --replace-foreign-hook" >&2
      echo "" >&2
      return 2
    fi
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
