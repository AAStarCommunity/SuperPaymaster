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
if ! headerr=$(git rev-parse --verify HEAD 2>&1); then
  # Report the OBSERVED state, not a guessed cause. `rev-parse --verify HEAD` failing
  # does not mean "no commits" -- it means HEAD does not resolve, and a repo WITH
  # commits whose HEAD points at a missing ref fails identically (measured: one commit,
  # .git/HEAD = `ref: refs/heads/does-not-exist`, git says `Needed a single revision`).
  # The previous version asserted "no commits yet" for both. That is the same defect
  # this script fixes ten lines below for the canary loop -- half of that patch learned
  # not to assert an untested cause and the other half did not.
  echo "FAIL: HEAD does not resolve, so no canary branch can be created and the" >&2
  echo "  install cannot be verified. The hook file itself IS in place." >&2
  # `symbolic-ref` is already being run, so the two causes can be told apart instead of
  # offered as a closed either/or with neither checked. The predicate "which of these two
  # is it" is evaluable here for the price of one variable.
  headref=$(git symbolic-ref -q HEAD || true)
  echo "    HEAD -> ${headref:-(detached)}" >&2
  echo "    git:  ${headerr:-(git printed nothing)}" >&2
  # `|| echo 0` would report "no commits" when the QUERY failed, which is a different
  # thing -- the same conflation this whole file has been unpicking. Capture success
  # separately from the count.
  # The two recovery commands are COMPLEMENTARY, not alternatives, which is why both are
  # printed. Measured on git 2.50.1:
  #   normal repo, branch deleted -> reflog --all names it (2 hits); --lost-found also
  #                                  finds it
  #   BARE repo, branch deleted   -> reflog --all finds NOTHING (bare keeps no reflogs by
  #                                  default); --lost-found finds it
  # The bare-repo row is what makes printing both load-bearing.
  #
  # A reviewer raised that fsck can miss commits held by a reflog. An earlier version of
  # this comment said I could not reproduce that and generalised it to "fsck reports the
  # commit whether or not a reflog names it". THAT GENERALISATION WAS WRONG, and it
  # contradicted git's own documentation, which says reflogs are used as heads unless
  # --no-reflogs. Measuring the reports separately shows both are true of different
  # flags -- with a reflog holding the commit:
  #   git fsck                     -> 0   (reflogs are heads, so not dangling)
  #   git fsck --dangling          -> 0
  #   git fsck --lost-found        -> 1   <- the flag actually printed above
  #   git fsck --lost-found --no-reflogs -> 1
  # So the reviewer is right about `fsck` and the recipe is right about `--lost-found`:
  # --lost-found does not treat reflogs as heads. The earlier reading came from testing
  # only --lost-found and then stating a conclusion about fsck.
  # `rev-list --all --count` counts commits REACHABLE FROM A REF. Zero does not mean the
  # repo has none: delete the only branch and the commit object is still there, just
  # unreferenced (measured -- `git cat-file -t <sha>` still says commit while the count
  # is 0). Saying "no commits at all" there is false AND sends the operator to the wrong
  # fix: the answer is to restore the ref, not to make a commit. So the wording says
  # reachable, which is what was measured, and the zero case offers both readings.
  if ncommits=$(git rev-list --all --count 2>/dev/null); then havecount=1; else havecount=0; ncommits=""; fi
  if [ "$havecount" = "0" ]; then
    echo "  Could not count commits (git rev-list failed), so the causes below cannot be" >&2
    echo "  told apart here. Inspect .git/HEAD and refs by hand." >&2
  elif [ -n "$headref" ] && [ "$ncommits" != "0" ]; then
    echo "  Checked: $ncommits commit(s) are reachable from a ref, and HEAD points at" >&2
    echo "  '$headref', which does not resolve. Repoint HEAD at an existing branch," >&2
    echo "  then re-run:" >&2
  elif [ -n "$headref" ]; then
    echo "  Checked: NO commits are reachable from any ref, and HEAD points at '$headref'." >&2
    echo "  Either nothing has been committed yet -- make a commit -- or commits exist but" >&2
    echo "  their refs were deleted, which this cannot distinguish. To check for the" >&2
    echo "  second, and recover a ref if so -- the two look in DIFFERENT places, so try" >&2
    echo "  both rather than concluding from one:" >&2
    echo "    git reflog --all              # where a deleted branch usually still shows," >&2
    echo "                                  #   with when and what; EMPTY in a bare repo," >&2
    echo "                                  #   which keeps no reflogs by default" >&2
    echo "    git fsck --lost-found         # objects no ref names; the only option once" >&2
    echo "                                  #   reflogs are absent or expired" >&2
    echo "  then: git branch <name> <sha>" >&2
    echo "  Afterwards re-run:" >&2
  else
    # Defensive, and NOT reachable in any state I could construct: a detached HEAD holding
    # a bogus object makes `rev-parse --verify HEAD` succeed here and fails later in the
    # canary loop instead, which catches it with its own hedged wording
    # (`fatal: not a valid branch point: 'HEAD'`). Kept rather than deleted because
    # "I could not construct it" is not "it cannot happen" -- but labelled, so nobody
    # reads its presence as evidence that the case was tested.
    echo "  HEAD is detached and does not resolve. Check it out at a real commit, then" >&2
    echo "  re-run:" >&2
  fi
  echo "    bash scripts/install-git-hooks.sh" >&2
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
# The UNPROTECTED canary needs the same treatment the protected one just got. It did
# not have it: a branch named `__install_check_unprotected__/x` makes this a D/F
# conflict, `set -e` turned that into a bare `exit 128` with no output after
# "verifying...", identical on every re-run. The comment above claimed that failure mode
# had been designed out; it had been designed out for the canary twelve lines up only.
#
# Worse, it exits holding state that needs the mechanism under test to clear: the
# protected canary is still there, and the operator's first instinct
# (`git branch -D deploy/__install_check__`) is refused by this repo's own hook. So the
# message has to name the leftover AND how to remove it.
plain="__install_check_unprotected__"
if ! plainerr=$(git branch -f "$plain" HEAD 2>&1); then
  echo "FAIL: could not create the unprotected canary '$plain'." >&2
  echo "  git's own explanation:" >&2
  echo "    ${plainerr:-(git printed nothing)}" >&2
  # Do NOT assert the cause. The commonest one is a branch named "$plain/..." making
  # this a D/F conflict, but it is not the only one -- measured: with ZERO such branches,
  # a stale .git/refs/heads/$plain.lock produces this same failure, and the earlier text
  # here flatly blamed a D/F conflict and told the operator to "rename it" when there was
  # nothing to rename. That is the defect this script fixes twice elsewhere, committed a
  # third time in the patch that fixed the second one. The line above carries git's own
  # words; that is the part that is actually known.
  echo "  A common cause is a branch named '$plain/...' (D/F conflict), in which case" >&2
  echo "  rename it -- but the line above is what actually applies." >&2
  echo "  This run also leaves '$canary' behind. A plain 'git branch -D $canary' will be" >&2
  echo "  refused IF the hook is working -- which this run exited before verifying, so it" >&2
  echo "  is not known here. If a plain delete is refused, use:" >&2
  echo "    PILOT_ALLOW_PROTECTED_DELETE=$canary git branch -D $canary" >&2
  exit 1
fi

# `env -u` so an operator who happens to have the escape hatch exported for this exact
# canary does not make the check vacuous. Without it the delete is ALLOWED by a hook that
# is working perfectly, and the script then reports "the hook is NOT firing" -- sending
# them to debug something that is not broken. Measured.
if env -u PILOT_ALLOW_PROTECTED_DELETE git branch -D "$canary" >/dev/null 2>&1; then
  echo "FAIL: the protected canary '$canary' was deleted when it should have been refused." >&2
  # Report what was CHECKED, then what is merely likely. The old text said "the hook is
  # NOT firing" as a conclusion; that is one explanation among several, and this script
  # tests exactly one of them.
  if [ ! -x "$dir/reference-transaction" ]; then
    echo "  Checked: $dir/reference-transaction is NOT executable -- git ignores it." >&2
  else
    echo "  Checked: $dir/reference-transaction exists and is executable, so the cause is" >&2
    echo "  not that. It may be exiting 0 for this ref, or git may be reading hooks from" >&2
    echo "  somewhere else. To watch it by hand -- note this RE-CREATES the branch first," >&2
    echo "  because the delete above already removed it:" >&2
    echo "    git branch $canary HEAD && git branch -D $canary" >&2
  fi
  echo "  hooks dir git is using: $dir  (core.hooksPath=$(git config --get core.hooksPath || echo unset))" >&2
  git branch -D "$plain" >/dev/null 2>&1 || true
  exit 1
fi
if ! git branch -D "$plain" >/dev/null 2>&1; then
  echo "FAIL: deleting '$plain' was refused, but nothing should protect that name." >&2
  echo "  Checked: the delete was rejected. NOT checked, and both are possible:" >&2
  echo "    - the hook matches more than it should, or" >&2
  echo "    - protect_patterns contains an entry that happens to match this internal" >&2
  echo "      name. That is directly checkable:" >&2
  echo "        grep -n -A20 '^protect_patterns:' .pilot.yml" >&2
  echo "  Left behind deliberately, for you to inspect then remove: $plain and $canary" >&2
  echo "  They are NOT torn down here: the teardown would run through the escape hatch," >&2
  echo "  i.e. through part of the very mechanism whose behaviour is in question." >&2
  exit 1
fi
PILOT_ALLOW_PROTECTED_DELETE="$canary" git branch -D "$canary" >/dev/null 2>&1 || {
  echo "FAIL: the escape hatch did not delete '$canary'." >&2
  # refs/heads/ prefix, not the bare name: `git rev-parse --verify <name>` searches the
  # whole ref namespace, so a TAG called deploy/__install_check__ (or a remote-tracking
  # ref) satisfies it and this reports the branch as still present when it is gone.
  # Measured: with only the tag, the bare check says yes and the qualified one says no.
  # The delete above operates on refs/heads, so the check has to as well.
  if git rev-parse --verify -q "refs/heads/$canary" >/dev/null; then
    echo "  It is still present; remove it by hand once the hatch is fixed." >&2
  else
    echo "  It is NOT present, so the delete partly succeeded and reported failure --" >&2
    echo "  nothing to clean up, but the hatch's exit status is wrong." >&2
  fi
  exit 1; }

echo "OK: protected delete rejected, unprotected delete allowed, escape hatch works."
