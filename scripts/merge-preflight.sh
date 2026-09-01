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
# The literal is the JOB ID in .github/workflows/merge-preflight.yml. Renaming the
# job there and not here desynchronises them silently: grep -vxF matches whole
# lines, so a stale value excludes nothing and the run counts ITSELF as failing or
# pending. That already happened once — the job became `preflight-report` while
# this still said `preflight`. Under Actions GITHUB_JOB supplies it and the run-id
# lookup overrides it anyway; this literal only bites the STRICT pre-merge run,
# which is the path designated as the actual gate. Raised by pr-daemon.
SELF_NAME="${SELF_NAME:-${GITHUB_JOB:-preflight-report}}"
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
  # Transient in --ci for the same reason "no approval yet" is: at PUSH time no
  # approval can possibly name the new head. Failing here left a RED check run
  # on every head, and a superseded failure keeps GitHub's rollup FAILURE even
  # after a later run succeeds — so a required check would need a manual re-run
  # on every PR. Observed: 2831c1bb had preflight failure@14:20 and success@14:22
  # and stayed BLOCKED with reviewDecision=APPROVED.
  #
  # This leg is NOT dropped, it is MOVED to where it can be enforced without a
  # race: branch protection's dismiss_stale_reviews retracts the approval the
  # moment the branch moves, which is the same property GitHub-side and without a
  # check run to re-run. Strict mode (no --ci) still fails here, so the pre-merge
  # command keeps the belt.
  # This leg was MOVED to branch protection's dismiss_stale_reviews. Verify that
  # where it CAN be verified, and say so plainly where it cannot — rather than
  # inferring it from something that only correlates.
  #
  # Two inferences were tried and both are unsound. "Newest review is DISMISSED"
  # breaks the moment a reviewer submits CHANGES_REQUESTED. "Any DISMISSED review
  # exists" is worse: a human dismissing a review by hand produces an identical
  # row (measured — both DISMISSED rows on this PR carry full ~3.8KB bodies, same
  # as any review), and the row survives the setting being turned off afterwards.
  # A historical event cannot evidence a current setting. Found by Codex.
  if [ "$CI_MODE" -eq 1 ]; then
    # GITHUB_TOKEN has no `administration` scope, so a job cannot read branch
    # protection. Do not manufacture a substitute: report the leg, name what is
    # supposed to enforce it, and state that this run did NOT confirm it.
    echo "      (not enforced by this job. dismiss_stale_reviews is supposed to"
    echo "       enforce it; a GitHub Actions token cannot read branch protection,"
    echo "       so THIS RUN HAS NOT CONFIRMED THAT. The strict pre-merge run does.)"
  else
    fail=1
    # Strict mode runs with a token that can read it, so check the guarantee has
    # a home instead of trusting that someone left it there.
    # The PR's own base, not a hardcoded main — this script is run against PRs
    # targeting release branches too, and reading the wrong branch's protection
    # would report a setting that does not govern this merge.
    base=$(gh pr view "$PR" --repo "$REPO" --json baseRefName -q '.baseRefName' 2>/dev/null | tr -d ' \n')
    if [ -z "$base" ]; then
      # Do NOT fall back to main. Substituting a guess for an unread value is the
      # fail-open this script refuses everywhere else: it would report main's
      # setting for a PR that may target a release branch, and the right value
      # from the wrong branch reads exactly like the right answer. Found by Codex.
      echo "      (could not read this PR's base branch; not reporting a"
      echo "       dismiss_stale_reviews value that might govern a different branch)"
    elif dsr=$(gh api "repos/$REPO/branches/$base/protection" \
               --jq '.required_pull_request_reviews.dismiss_stale_reviews' 2>/dev/null); then
      [ "$dsr" = "true" ] \
        && echo "      (dismiss_stale_reviews=true on $base, so pushes retract approvals)" \
        || echo "      AND dismiss_stale_reviews=$dsr on $base — nothing enforces this at all."
    else
      echo "      (could not read branch protection; not claiming it is configured)"
    fi
  fi
else
  echo "OK    approved SHA == head"
fi
if [ -n "$last_cr" ]; then
  echo "FAIL  a CHANGES_REQUESTED ($last_cr) is newer than the newest approval"
  # Advisory in --ci, and this one is not a subtlety: requesting changes is NORMAL
  # REVIEW, not a defect in the commit. Failing on it made a required check go red
  # because someone reviewed the PR, and it STAYED red after the author pushed a
  # fix, since re-approval necessarily comes later. A required check that reports
  # "something is wrong with this commit" when what happened is "a human read it"
  # trains people to ignore it. Found by Codex.
  #
  # GitHub already enforces this without a check run, verified rather than assumed:
  # this PR reads reviewDecision=CHANGES_REQUESTED, mergeStateStatus=BLOCKED. So
  # the property holds either way; only the reporting changes.
  #
  # Third leg moved out of --ci for the same reason as the other two: a condition
  # that is TRANSIENT by construction cannot be a required check, because a check
  # run records a moment and a required check demands a steady state.
  # Do not ASSERT which review state is blocking — it varies. At d1fcfbdd this
  # PR read REVIEW_REQUIRED (approval count was the blocker) and minutes later
  # CHANGES_REQUESTED (the CR was). Naming one of them in a comment made the
  # justification wrong half the time even though the behaviour was safe. Ask.
  # Raised by pr-daemon.
  if [ "$CI_MODE" -eq 1 ]; then
    rd=$(gh pr view "$PR" --repo "$REPO" --json reviewDecision -q '.reviewDecision' 2>/dev/null | tr -d ' \n')
    echo "      (transient in --ci; GitHub reports reviewDecision=${rd:-<unreadable>})"
  fi
  [ "$CI_MODE" -eq 1 ] || fail=1
fi

# --- 2. no check-run and no commit STATUS may be failing ----------------------
# These are two different APIs. check-runs covers GitHub Actions; the Status API
# covers everything else, and a red status is invisible to the first one.
api total '.total_count' "repos/$REPO/commits/$head/check-runs" \
    || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
if [ "${total:-0}" -eq 0 ]; then
  echo "FAIL  no check runs for $head — 'all green' and 'never ran' are not the same reading"; fail=1
else
  api allcheck '[.check_runs[].name]|join("\n")' \
      "repos/$REPO/commits/$head/check-runs" --paginate \
      || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
  base_for_req=$(gh pr view "$PR" --repo "$REPO" --json baseRefName -q '.baseRefName' 2>/dev/null | tr -d ' \n')

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
    n_mine=$(printf '%s\n' "$mine" | grep -c '^..*$')
    if [ -z "$mine" ]; then
      echo "FAIL  no check run on $head belongs to GITHUB_RUN_ID=$GITHUB_RUN_ID."
      echo "      Cannot identify this job's own check run, so it cannot exclude"
      echo "      itself, so every judgement below would be self-poisoned."
      fail=1
    elif [ "$n_mine" -ne 1 ]; then
      # GITHUB_RUN_ID names the WORKFLOW RUN, and every job in it shares that id
      # in its details_url. With one job the match is unique by accident, not by
      # construction — add a second job here and this silently becomes a
      # multi-line SELF_NAME that excludes nothing. Refuse rather than guess
      # which of them is me. Found by Codex.
      echo "FAIL  GITHUB_RUN_ID=$GITHUB_RUN_ID owns $n_mine check runs on this head:"
      # Quoted and line-oriented: check-run names contain spaces ("Stage 2 —
      # forge test + fuzz"), and an unquoted expansion word-splits them into
      # nonsense exactly when the operator most needs to read the list.
      printf '%s\n' "$mine" | sed 's/^/        /' 
      echo "      That id identifies the workflow RUN, not this JOB. Make the"
      echo "      exclusion job-precise before this workflow grows a second job."
      fail=1
    else
      SELF_NAME="$mine"
      echo "OK    self identified from GITHUB_RUN_ID=$GITHUB_RUN_ID -> '$SELF_NAME' (sole job in the run)"
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

  # Strict mode has no GITHUB_RUN_ID, so SELF_NAME is a literal here. Check it
  # names something real before relying on it: a stale literal silently excludes
  # nothing, which is how a rename turns this gate against itself.
  if [ "$CI_MODE" -ne 1 ]; then
    api allnames '[.check_runs[].name]|join("\n")' \
        "repos/$REPO/commits/$head/check-runs" --paginate \
        || { echo "PREFLIGHT FAIL — do not merge $PR"; exit 4; }
    if ! printf '%s\n' "$allnames" | grep -qxF "$SELF_NAME"; then
      echo "FAIL  SELF_NAME='$SELF_NAME' matches no check run on this head."
      echo "      It must equal the job id in merge-preflight.yml. A stale value"
      echo "      excludes nothing and this run then counts itself."
      fail=1
    fi
  fi

  # Drop our own run by NAME, deliberately, even though the identification just
  # above is by run id. Excluding by run id would keep a SUPERSEDED failing run
  # of this same job in `bad` for ever — which is the self-holding trap from two
  # rounds ago wearing different clothes: red once, red always. Name-exclusion
  # drops every run of this job, including the stale failures a re-push replaces.
  # This is a deliberate widening immediately after a deliberate narrowing, so it
  # is written down: the identification must be precise, the exclusion must not.
  # Raised by pr-daemon.
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

  # "Nothing failed" is not "everything required reported". A required context
  # that never RAN is absent, not green — and absence read as consent is the
  # defect this whole script argues against, sitting in the script. #413 had every
  # run green with abi-docs never triggered; this said "safe to merge" and GitHub
  # said BLOCKED, and GitHub was right.
  #
  # STRICT ONLY. Reading required_status_checks needs branch-protection access,
  # which a GITHUB_TOKEN does not have — the same limit already documented for
  # two other legs in this file. Without this gate the lookup fails in Actions and
  # takes the whole job red, which is how it shipped and how pr-daemon caught it.
  # In --ci, GitHub enforces required contexts itself; there is nothing to add.
  if [ "$CI_MODE" -ne 1 ]; then
    # Deliberately NOT api(): that helper sets fail=1 as a side effect, which is
    # right when a lookup is mandatory and wrong here — `|| reqctx=""` catches the
    # return value and not the side effect, so an unreadable base still failed the
    # run while printing "not claiming". Same shape as every other mismatch today:
    # the verdict arriving by a path other than the one being read.
    if [ -z "$base_for_req" ]; then
      # No `:-main` fallback. That silent substitution was removed three commits
      # ago and the reasoning is still on line ~143 of this file; reinstating it
      # here would report a different branch's configuration as this PR's.
      # Strict mode is the designated gate, so an unread value is a refusal, not
      # a note. Printing INFO and continuing was the fail-open this script removes
      # everywhere else, reintroduced on the one path that is supposed to be
      # strictest. Found by Codex.
      echo "FAIL  base branch unreadable; cannot check required contexts"
      fail=1
    elif reqctx=$(gh api "repos/$REPO/branches/$base_for_req/protection" \
                    --jq '(.required_status_checks.contexts // [])|join("\n")' 2>/dev/null); then
      # `// []` above matters. Without it, a branch WITH protection but NO required
      # status checks makes jq error on null ("Cannot iterate over null", rc 5), gh
      # returns 1, and this lands in the unreadable branch — reporting "could not
      # read" for a branch that simply requires nothing, so strict could never pass
      # there. Verified with jq directly, both ways. Raised by pr-daemon.
      if [ -z "$reqctx" ]; then
        echo "INFO  $base_for_req requires no status checks; nothing to verify reported"
      else
      missing=""
      while IFS= read -r c; do
        [ -z "$c" ] && continue
        printf '%s\n' "$allcheck" | grep -qxF "$c" || missing="${missing:+$missing, }$c"
      done <<< "$reqctx"
      if [ -n "$missing" ]; then
        echo "FAIL  required context(s) never reported on this head: $missing"
        echo "      A required check that did not run is ABSENT, not passing."
        echo "      Usually a paths filter: the workflow was not triggered by these"
        echo "      files. GitHub blocks on it; re-push or widen the filter."
        fail=1
      else
        echo "OK    all $(printf '%s\n' "$reqctx" | grep -c .) required contexts reported"
      fi
      fi
    else
      echo "FAIL  could not read $base_for_req's required contexts."
      echo "      Not proceeding on an unread value: whether every required check"
      echo "      reported is exactly what this leg exists to establish."
      fail=1
    fi
  fi
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

# "Passed" and "safe to merge" are different claims. With sibling checks still
# running, this run establishes only that nothing has failed YET — saying safe is
# the same over-claim this whole gate argues against. Raised by pr-daemon.
if [ "$fail" -ne 0 ]; then
  echo "PREFLIGHT FAIL — do not merge $PR"
elif [ -n "${pend:-}" ]; then
  echo "PREFLIGHT PASS (checks still running: ${pend}) — nothing has failed yet;"
  echo "                merge is gated by the required contexts, not by this line"
else
  if [ "$CI_MODE" -eq 1 ]; then
    # In --ci this run has DOWNGRADED legs that GitHub enforces instead, so it
    # cannot speak for mergeability — reviewDecision and the required contexts
    # do. Saying "safe to merge" here would be the same over-claim the whole
    # gate argues against, one line from the end.
    echo "REPORT ONLY — nothing this job can see has failed at $head."
    echo "              This is NOT a merge gate: the approval legs above are"
    echo "              enforced by dismiss_stale_reviews and reviewDecision and"
    echo "              are NOT verified here. Run without --ci before merging."
  else
    echo "PREFLIGHT PASS — safe to merge $PR at $head"
  fi
fi
exit "$fail"
