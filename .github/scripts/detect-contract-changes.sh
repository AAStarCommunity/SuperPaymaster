#!/usr/bin/env bash
#
# Decide whether the contract gate applies to the current event and write the answer to
# $GITHUB_OUTPUT as `contract=true|false`.
#
#   usage: detect-contract-changes.sh <gate-label> <extended-regex>
#
# Reads EVENT / BASE_SHA / HEAD_SHA from the environment (the workflow passes GitHub's
# event context in). The path pattern stays at the CALL SITE so each workflow's notion of
# "contract input" is readable where it is used; only the control flow lives here.
#
# WHY THIS IS ONE SCRIPT AND NOT FOUR INLINE COPIES (CC-48 round-11, B1)
# ---------------------------------------------------------------------
# Round-10 inlined this decision at four job sites (security.yml x3, test.yml x1). All
# four were byte-identical in shape and carried the same two defects, so a fix applied to
# the reported site would have left three open. Both defects point the same way -- the
# gate reports "nothing to check" and exits 0 -- which is the one direction a security
# gate must never fail in, because the required check then goes GREEN having verified
# nothing.
#
#   if git diff --name-only "$BASE...$HEAD" | grep -qE '<paths>'; then ... else ... fi
#
# Defect 1 -- `set -e` does not apply to a command in an `if` condition (POSIX: errexit is
# suspended for the condition list). When `git diff` FAILED -- base SHA unreachable
# because the base branch was force-pushed or GC'd between event creation and checkout,
# or a partial fetch -- its non-zero status merely selected the `else` branch.
#
# Defect 2 -- `printf ... | grep -q` under `pipefail` is not safe for a large diff.
# `grep -q` exits at the FIRST match and closes the pipe; once the path list exceeds the
# 64 KiB pipe buffer, `printf` has not finished writing, takes EPIPE/SIGPIPE, and
# `pipefail` promotes that to the pipeline's status -- so a matching diff takes the `else`
# branch. Measured on this tree: 2000 changed contract paths -> `contract=true`;
# 3000 -> `contract=false` WITH the contract changes present. This defect is the sharper
# of the two, because it fires on the SUCCESS path with no error anywhere, and it fires
# precisely on the large PR these workflows were rewritten to handle (the stated reason
# for computing the diff by hand is that GitHub's `paths:` filter only inspects the first
# 300 changed files).
#
# The rule below: the diff decides the gate only when the diff is fully computed AND fully
# scanned. Anything else APPLIES the gate (`contract=true`), never skips it. Applying it
# spends CI minutes and then answers on the merits of the real build/test; skipping it
# produces a green required check that ran nothing.
#
# Exercised by test-detect-contract-changes.sh, which runs on every PR (gate-self-test).
set -euo pipefail

GATE_LABEL="${1:?usage: detect-contract-changes.sh <gate-label> <extended-regex>}"
PATH_REGEX="${2:?usage: detect-contract-changes.sh <gate-label> <extended-regex>}"

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must be set}"

# Every exit from this script goes through here, so there is no path that forgets to
# answer. `apply` is the fail-closed answer.
apply()  { echo "contract=true"  >> "$GITHUB_OUTPUT"; echo "$1"; exit 0; }
skip()   { echo "contract=false" >> "$GITHUB_OUTPUT"; echo "$1"; exit 0; }

if [ "${EVENT:-}" != "pull_request" ]; then
  apply "Not a pull_request event (${EVENT:-unset}) — running the full ${GATE_LABEL} gate."
fi

if [ -z "${BASE_SHA:-}" ] || [ -z "${HEAD_SHA:-}" ]; then
  echo "::error::BASE_SHA/HEAD_SHA empty on a pull_request event — cannot determine what changed."
  apply "Applying the full ${GATE_LABEL} gate: an undecidable diff must never skip it."
fi

# Capture the diff in its own assignment rather than in the `if` condition: as a standalone
# assignment the exit status IS the command substitution's, so `if !` sees the failure that
# an `if git diff ... | ...` condition would have swallowed (defect 1).
#
# `core.quotePath=false` is load-bearing, not tidiness (defect 3, found reviewing this
# script). With git's default quoting, a path containing any non-ASCII byte comes back
# C-quoted AND wrapped in double quotes -- `"contracts/src/\346\227\245.sol"` -- so the
# `^contracts/` anchor does not match it and the gate answers "skip" for a PR that changed a
# contract. Same failure direction as the other two, reached by simply naming a file in a
# non-Latin script.
if ! CHANGED="$(git -c core.quotePath=false diff --name-only "${BASE_SHA}...${HEAD_SHA}")"; then
  echo "::error::git diff --name-only ${BASE_SHA}...${HEAD_SHA} failed — cannot determine what this PR changed."
  apply "Applying the full ${GATE_LABEL} gate: an undecidable diff must never skip it."
fi

# Herestring, NOT a pipe: `grep -q` closing a pipe early makes the writer's SIGPIPE the
# pipeline's status under `pipefail`, which silently inverts the answer on a large diff
# (defect 2). A herestring is not a pipeline, so there is nothing for pipefail to promote.
if grep -qE "$PATH_REGEX" <<< "$CHANGED"; then
  apply "Contract-path changes detected — running the full ${GATE_LABEL} gate."
fi

skip "No contract-path changes — ${GATE_LABEL} cannot be affected by this PR."
