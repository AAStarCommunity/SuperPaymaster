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

  # A hook that is present and byte-correct still does nothing if git will not run it:
  # git ignores a hook without the executable bit. It is not silent about it -- it prints
  # `hint: The '...' hook was ignored because it's not set as executable` (measured). What
  # WAS silent is this installer: it reported "already current" and returned. Content identity is not the property that matters here --
  # executability is. Comparing only content made this state UNREPAIRABLE: the installer
  # reported "already current" and returned before any chmod, so re-running it could never
  # fix the one thing that was wrong. An exec bit is easy to lose (a copy through a tool
  # that drops modes, a restore from an archive, a checkout on a filesystem without them).
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then
    echo "REFUSING: $dst exists but is not a regular file" >&2; return 2
  fi
  if [ -f "$dst" ]; then
    if cmp -s "$src" "$dst"; then
      if [ -x "$dst" ]; then echo "  $1 already current"; return 0; fi
      chmod +x "$dst"
      echo "  $1 content was current but NOT EXECUTABLE (git was ignoring it) - exec bit restored"
      return 0
    fi
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
# The canary needs a protected name, but `deploy/__install_check__` cannot be created
# when a branch named exactly `deploy` exists -- git refuses the directory/file conflict.
# Under `set -e` that surfaced as a bare `exit 128` with no message, and it was
# SELF-LOCKING: every subsequent run failed the same way, so a repo with a `deploy`
# branch (precisely the repo this hook is for) could never verify its own install.
# Try each baseline pattern and use the first name git will actually create.
# A repo with no commits has an unborn HEAD, so `git branch <name> HEAD` fails for a
# reason unrelated to the D/F conflict this loop works around. Checking it FIRST matters:
# the earlier version reported "deploy, release AND hotfix are all taken" in a repo with
# ZERO branches, and the manual recipe it offered failed the same way. A diagnostic that
# names a cause it never tested is worse than none -- and since this protection is
# installed by hand, once per clone, diagnosing this script IS part of what it is worth.
if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  echo "FAIL: this repo has no commits yet (unborn HEAD), so no canary branch can be" >&2
  echo "  created and the install cannot be verified. The hook file itself IS in place." >&2
  echo "  Make a commit, then re-run: bash scripts/install-git-hooks.sh" >&2
  exit 1
fi

canary=""; lasterr=""
for pref in deploy release hotfix; do
  # Keep stderr rather than discarding it: it is the only thing that can explain a
  # failure this script did not anticipate.
  if lasterr=$(git branch -f "$pref/__install_check__" HEAD 2>&1); then
    canary="$pref/__install_check__"; break
  fi
done
if [ -z "$canary" ]; then
  echo "FAIL: could not create a protected canary under deploy/, release/ or hotfix/." >&2
  echo "  git's own explanation for the last attempt:" >&2
  echo "    ${lasterr:-(git printed nothing)}" >&2
  echo "  A branch named exactly 'deploy', 'release' or 'hotfix' blocks the nested name" >&2
  echo "  git needs (D/F conflict). Other causes are possible; the line above says which" >&2
  echo "  one applies. Once resolved, verify by hand:" >&2
  echo "    git branch deploy/x HEAD && git branch -D deploy/x   # must print BLOCKED" >&2
  exit 1
fi
plain="__install_check_unprotected__"
git branch -f "$plain"  HEAD >/dev/null 2>&1

if git branch -D "$canary" >/dev/null 2>&1; then
  echo "FAIL: protected canary was deleted -- the hook is NOT firing" >&2
  # Say WHY, or the operator is left re-running a script that reports the same failure
  # forever. These are the two states git fails on silently.
  [ -x "$dir/reference-transaction" ] || echo "  cause: $dir/reference-transaction is not executable" >&2
  echo "  hooks dir git is using: $dir  (core.hooksPath=$(git config --get core.hooksPath || echo unset))" >&2
  git branch -D "$plain" >/dev/null 2>&1 || true
  exit 1
fi
if ! git branch -D "$plain" >/dev/null 2>&1; then
  echo "FAIL: an UNPROTECTED branch was also blocked -- the hook is too broad" >&2
  echo "  Left behind deliberately, for you to inspect then remove: $plain and $canary" >&2
  echo "  They are NOT torn down here. Reaching this line means the hook is currently" >&2
  echo "  misbehaving, and the teardown would have to run through the escape hatch --" >&2
  echo "  i.e. through the very mechanism whose behaviour is in question." >&2
  exit 1
fi
PILOT_ALLOW_PROTECTED_DELETE="$canary" git branch -D "$canary" >/dev/null 2>&1 || {
  echo "FAIL: the escape hatch did not work; '$canary' is left behind" >&2; exit 1; }

echo "OK: protected delete rejected, unprotected delete allowed, escape hatch works."
