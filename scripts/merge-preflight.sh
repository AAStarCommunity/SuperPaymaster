#!/usr/bin/env bash
# =============================================================================
# merge-preflight.sh <pr-number>
#
# Refuses a merge that violates "the final SHA was approved AND every check is
# green". Both halves were violated on this repo in the same week:
#
#   #400 #402 #404 #405   merged with a FAILING check. `mergeStateStatus` said
#                         UNSTABLE, which MEANS "a check failed but merging is
#                         not blocked" — read as "mergeable".
#   #408                  merged a commit nobody reviewed. The approval named
#                         b327086b, a background push moved the branch to
#                         4b5084e7, and `gh pr merge` takes the BRANCH.
#
# EVERY LOOKUP FAILS CLOSED. The first version read `gh api` output into a
# variable and tested it for emptiness — so an auth error, a rate limit or a
# typo'd path produced "" and was indistinguishable from "nothing is failing".
# A gate whose instrument failure looks like success is the defect it exists to
# catch. Each call's exit status is now checked before its output is believed.
#
# Exit 0 = safe to merge. Anything else = do not merge.
# =============================================================================
set -uo pipefail
# --ci downgrades the two conditions that are TRANSIENT during a PR's life:
#   * no approval yet — every PR starts unapproved; review comes after CI
#   * sibling checks still running — this job runs alongside them
# In --ci mode those are reported and do not fail, so the job can reach green.
# What still fails in BOTH modes is what is never transient: an approval that
# names a DIFFERENT sha (the #408 shape) and a check that actually FAILED
# (the #400/#405 shape).
#
# It also stops counting ITSELF. Run as a check-run, it is `in_progress`, so it
# read its own name as a pending check and failed on it — and once red it read
# its own failure as "a failing check" and stayed red. Verified on chain: on
# cb0af21d, `preflight` was the ONLY failure among eleven runs.
CI_MODE=0
if [ "${1:-}" = "--ci" ]; then CI_MODE=1; shift; fi
# Defaults to the job id GitHub exports, so the common case needs no hand-kept
# string at all. Whatever it ends up as, --ci ASSERTS it below against the real
# check-run names: "configured correctly" and "impossible to misconfigure" are
# different properties, and this gate exists to insist on the second. Raised by
# pr-daemon on #412.
SELF_NAME="${SELF_NAME:-${GITHUB_JOB:-preflight}}"
PR="${1:?usage: merge-preflight.sh [--ci] <pr-number>}"
REPO="${REPO:-AAStarCommunity/SuperPaymaster}"
fail=0

# api <varname> <jq> <path...>
#
# Assigns into the CALLER's variable with printf -v and returns non-zero on
# failure. It must not be used as `x=$(api ...)`: command substitution runs in a
# subshell, so an `exit` inside it exits only the subshell and the caller sails on
# with an empty string. The first version did exactly that — a broken lookup
# printed FAIL to stderr and the run continued to PASS on empty values, which is
# the fail-open this gate exists to close, reproduced inside the gate. Caught by
# breaking one lookup and watching the exit code come back 1 for an unrelated
# reason instead of refusing on the lookup.
api() {
  local __var="$1" __jq="$2"; shift 2
  local __out __rc
  __out=$(gh api "$@" --jq "$__jq" 2>/dev/null); __rc=$?
  if [ $__rc -ne 0 ]; then
    echo "FAIL  lookup failed (gh api $*) — refusing on an unread value, not passing"
    fail=1
    return 1
  fi
  printf -v "$__var" '%s' "$__out"
  return 0
}

head=$(gh pr view "$PR" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null | tr -d ' \n')
[ -n "$head" ] || { echo "FAIL  could not read the PR head"; exit 3; }
echo "head at this moment : $head"

# --- 1. the approval must name THIS commit, and nothing may have superseded it -
api revs '[.[]|{s:.state,c:.commit_id,t:.submitted_at}]|tostring' \
    "repos/$REPO/pulls/$PR/reviews" --paginate || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
appr=$(printf '%s' "$revs" | python3 -c '
import json,sys
r=json.loads(sys.stdin.read().replace("][",","))
a=[x for x in r if x["s"]=="APPROVED"]
print(a[-1]["c"] if a else "")')
last_cr=$(printf '%s' "$revs" | python3 -c '
import json,sys
r=json.loads(sys.stdin.read().replace("][",","))
a=[x for x in r if x["s"]=="APPROVED"]
c=[x for x in r if x["s"]=="CHANGES_REQUESTED"]
# A change request submitted AFTER the newest approval still stands.
print(c[-1]["t"] if c and (not a or c[-1]["t"] > a[-1]["t"]) else "")')

if [ -z "$appr" ]; then
  if [ "$CI_MODE" -eq 1 ]; then
    echo "INFO  no approval yet — transient, not failed in --ci"
  else
    echo "FAIL  no APPROVED review found"; fail=1
  fi
elif [ "$appr" != "$head" ]; then
  echo "FAIL  the approval names $appr, the branch is at $head"
  echo "      An approval is a statement about a SHA. Merging takes a branch."
  fail=1
else
  echo "OK    approved SHA == head"
fi
if [ -n "$last_cr" ]; then
  echo "FAIL  a CHANGES_REQUESTED ($last_cr) is newer than the newest approval"; fail=1
fi

# --- 2. no check-run and no commit STATUS may be failing ----------------------
# These are two different APIs. check-runs covers GitHub Actions; the Status API
# covers everything else, and a red status is invisible to the first one.
api total '.total_count' "repos/$REPO/commits/$head/check-runs" \
    || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
if [ "${total:-0}" -eq 0 ]; then
  echo "FAIL  no check runs for $head — 'all green' and 'never ran' are not the same reading"; fail=1
else
  api bad '[.check_runs[]|select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled" or .conclusion=="action_required")|.name]|join("\n")' \
      "repos/$REPO/commits/$head/check-runs" --paginate \
      || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
  api pend '[.check_runs[]|select(.status!="completed")|.name]|join("\n")' \
      "repos/$REPO/commits/$head/check-runs" --paginate \
      || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
  # Identify THIS run, do not merely look for its name. The previous version
  # asserted that SELF_NAME appeared among the head's check-run names — which
  # proves a run with that name exists, not that it is mine. This head carried
  # TWO check runs named `preflight` from two pushes, so presence was already
  # satisfiable by something other than the current job. Found by Codex.
  #
  # A check run's `details_url` is .../actions/runs/<GITHUB_RUN_ID>/job/<id>, so
  # in Actions the name can be DERIVED from the run id rather than configured.
  # Deriving it removes the misconfiguration instead of shouting about it: rename
  # the job, add a `name:`, and this still resolves to whatever GitHub actually
  # called it.
  if [ "$CI_MODE" -eq 1 ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    api mine "[.check_runs[]|select(.details_url|test(\"/runs/${GITHUB_RUN_ID}/\"))|.name]|join(\"\\n\")" \
        "repos/$REPO/commits/$head/check-runs" --paginate \
        || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
    if [ -z "$mine" ]; then
      echo "FAIL  no check run on $head belongs to GITHUB_RUN_ID=$GITHUB_RUN_ID."
      echo "      Cannot identify this job's own check run, so it cannot exclude"
      echo "      itself, so every judgement below would be self-poisoned."
      fail=1
    else
      SELF_NAME="$mine"
      echo "OK    self identified from GITHUB_RUN_ID=$GITHUB_RUN_ID -> '$SELF_NAME'"
    fi
  elif [ "$CI_MODE" -eq 1 ]; then
    # Outside Actions there is no run id to key on. Fall back to the name, and
    # say plainly that this is the weaker check — it establishes that A run by
    # that name exists, not that it is this one.
    api names '[.check_runs[].name]|join("\n")' \
        "repos/$REPO/commits/$head/check-runs" --paginate \
        || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
    if ! printf '%s\n' "$names" | grep -qxF "$SELF_NAME"; then
      echo "FAIL  SELF_NAME='$SELF_NAME' is not among this commit's check runs."
      echo "      check runs here: $(printf '%s' "$names" | paste -sd, -)"
      fail=1
    else
      echo "INFO  no GITHUB_RUN_ID; matched SELF_NAME='$SELF_NAME' by NAME only"
      echo "      (weaker: proves a run by that name exists, not that it is this one)"
    fi
  fi

  # Drop our own run from both lists before judging them.
  bad=$(printf '%s\n' "$bad" | grep -vxF "$SELF_NAME" | grep -v '^$' | paste -sd, -)
  pend=$(printf '%s\n' "$pend" | grep -vxF "$SELF_NAME" | grep -v '^$' | paste -sd, -)
  [ -n "$bad" ] && { echo "FAIL  failing checks: $bad"; fail=1; }
  if [ -n "$pend" ]; then
    if [ "$CI_MODE" -eq 1 ]; then
      echo "INFO  still running (transient, not failed in --ci): $pend"
    else
      echo "FAIL  still running: $pend"; fail=1
    fi
  fi
  [ -z "$bad" ] && [ -z "$pend" ] && echo "OK    $total check runs, none failing or pending (excluding $SELF_NAME)"
fi

api st '.state' "repos/$REPO/commits/$head/status" \
    || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
api nst '.statuses|length' "repos/$REPO/commits/$head/status" \
    || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
if [ "$nst" -gt 0 ] && [ "$st" != "success" ]; then
  echo "FAIL  commit status is '$st' across $nst status(es) — a different API from check-runs"; fail=1
else
  echo "OK    commit statuses: $nst reported, state=$st"
fi

[ "$fail" -eq 0 ] && echo "PREFLIGHT PASS — safe to merge $PR at $head" || echo "PREFLIGHT FAIL — do not merge $PR"
exit "$fail"
