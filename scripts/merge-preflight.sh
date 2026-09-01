#!/usr/bin/env bash
# =============================================================================
# merge-preflight.sh <pr-number>
#
# Refuses a merge that would violate either half of "the final SHA was approved
# AND every check is green". Both halves were violated on this repo in the same
# week, in opposite ways, and neither was visible in the fields I was reading:
#
#   #400 #402 #404 #405   merged with a FAILING check. `mergeStateStatus` said
#                         UNSTABLE, which means "a check failed but merging is
#                         not blocked" — I read it as "mergeable".
#   #408                  merged a commit nobody reviewed. The approval named
#                         b327086b, a background push moved the branch to
#                         4b5084e7, and `gh pr merge` takes the BRANCH, not the
#                         SHA. I had read the head several steps earlier.
#
# Neither `reviewDecision` nor `mergeStateStatus` answers either question, which
# is why checking them felt like checking.
#
# Exit 0 = safe to merge. Any other exit = do not merge.
# =============================================================================
set -uo pipefail
PR="${1:?usage: merge-preflight.sh <pr-number>}"
REPO="${REPO:-AAStarCommunity/SuperPaymaster}"
fail=0

head=$(gh pr view "$PR" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null | tr -d ' \n')
[ -n "$head" ] || { echo "FAIL  could not read the PR head — refusing on an unread value"; exit 3; }
echo "head at this moment : $head"

# --- 1. the approval must name THIS commit ------------------------------------
appr=$(gh api "repos/$REPO/pulls/$PR/reviews" \
        --jq '[.[]|select(.state=="APPROVED")|.commit_id]|last' 2>/dev/null | tr -d '" \n')
if [ -z "$appr" ] || [ "$appr" = "null" ]; then
  echo "FAIL  no APPROVED review found"; fail=1
elif [ "$appr" != "$head" ]; then
  echo "FAIL  the approval names $appr, the branch is at $head"
  echo "      An approval is a statement about a SHA. Merging takes a branch."
  fail=1
else
  echo "OK    approved SHA == head"
fi

# --- 2. no check may be failing -----------------------------------------------
runs=$(gh api "repos/$REPO/commits/$head/check-runs" --jq '.check_runs|length' 2>/dev/null | tr -d ' \n')
if [ -z "$runs" ] || [ "$runs" = "0" ]; then
  # An empty check list is not a green one. Refuse rather than read silence as success.
  echo "FAIL  no check runs reported for $head — cannot distinguish 'all green' from 'never ran'"
  fail=1
else
  bad=$(gh api "repos/$REPO/commits/$head/check-runs" \
         --jq '[.check_runs[]|select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled")|.name]|join(", ")' 2>/dev/null | tr -d '"')
  pend=$(gh api "repos/$REPO/commits/$head/check-runs" \
         --jq '[.check_runs[]|select(.status!="completed")|.name]|join(", ")' 2>/dev/null | tr -d '"')
  if [ -n "$bad" ]; then echo "FAIL  failing checks: $bad"; fail=1; fi
  if [ -n "$pend" ]; then echo "FAIL  still running: $pend"; fail=1; fi
  [ -z "$bad" ] && [ -z "$pend" ] && echo "OK    $runs check runs, none failing or pending"
fi

[ "$fail" -eq 0 ] && echo "PREFLIGHT PASS — safe to merge $PR at $head" || echo "PREFLIGHT FAIL — do not merge $PR"
exit "$fail"
