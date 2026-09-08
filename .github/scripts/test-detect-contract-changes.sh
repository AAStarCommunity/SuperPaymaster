#!/usr/bin/env bash
#
# Self-test for detect-contract-changes.sh (CC-48 round-11, B1).
#
# The gate this exercises decides whether the branch-protection required checks actually
# run. Its two historical defects (see the header of the script under test) both made it
# answer "skip" -- a green required check that verified nothing -- so this suite asserts
# the ANSWER, and every fail-closed case is paired with a control that must still answer
# "skip", so a script that hardcoded `contract=true` would fail here rather than pass.
#
# Runs in a throwaway git repo under $TMPDIR. No network, no forge, no submodules.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNDER_TEST="$HERE/detect-contract-changes.sh"
REGEX='^(contracts/|singleton-paymaster/|foundry\.toml$|remappings\.txt$|\.github/workflows/test\.yml$)'

# The x402 gate's regex is READ OUT OF THE WORKFLOW, not copied here. A copy is a second
# source of truth that drifts: a typo in the workflow would leave this file still holding
# the correct pattern, and every row below would pass while the real gate answered
# contract=false -- a green check that ran nothing, which is the exact failure this suite
# exists to make impossible.
#
# Proven by mutation: changing the pattern in the WORKFLOW turns the rows below red;
# an earlier version kept a copy here and a one-letter mutation changed the copy and the
# fixture path together, so the suite stayed green and the coverage was worth nothing.
X402_WF="$HERE/../workflows/x402-facilitator-node.yml"
X402_MATCHES="$(sed -n "s/^ *'\(\^(packages\/x402-facilitator-node\/.*\)'$/\1/p" "$X402_WF")"
X402_HITS="$(printf '%s\n' "$X402_MATCHES" | grep -c . || true)"
# Exactly one, not `head -1`. With head -1 a SECOND matching line -- a stale or wrong
# pattern left in the workflow -- would sit there unread while this suite reported all
# green off the first one. That is the same second-source-of-truth defect the extraction
# was written to remove, moved rather than removed. Verified with a probe: adding a
# `.../ZZZWRONG)` line after the real one takes hits to 2, and this now aborts.
if [ "$X402_HITS" != "1" ]; then
  echo "  FAIL  expected exactly ONE x402 gate regex in $X402_WF, found $X402_HITS:" >&2
  printf '%s\n' "$X402_MATCHES" | sed 's/^/        /' >&2
  echo "        Refusing to guess which one the gate uses." >&2
  exit 1
fi
# No separate empty check: hits==1 already implies a non-empty capture (the pattern the
# sed matches cannot produce one), so an `if [ -z ... ]` here would be unreachable. The
# count check above carries both cases, and prints which one applied -- "found 0" is the
# extraction being broken, "found 2" is the workflow having two.
X402_REGEX="$X402_MATCHES"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

# Run the gate and compare the value it wrote to $GITHUB_OUTPUT.
# expect_gate <description> <expected true|false> [env assignments...]
expect_gate() {
  local desc="$1" want="$2"; shift 2
  local out="$WORK/gh_output"
  : > "$out"
  local log rc=0
  log="$(env "$@" GITHUB_OUTPUT="$out" bash "$UNDER_TEST" "self-test" "${GATE_REGEX:-$REGEX}" 2>&1)" || rc=$?
  local got
  got="$(sed -n 's/^contract=//p' "$out")"
  if [ "$rc" -ne 0 ]; then
    echo "  FAIL  $desc — script exited $rc"
    echo "        $log"
    fail=$((fail + 1)); return
  fi
  if [ "$(grep -c . "$out")" -ne 1 ]; then
    echo "  FAIL  $desc — expected exactly one output line, got: $(cat "$out")"
    fail=$((fail + 1)); return
  fi
  if [ "$got" != "$want" ]; then
    echo "  FAIL  $desc — expected contract=$want, got contract=${got:-<none>}"
    echo "        $log"
    fail=$((fail + 1)); return
  fi
  echo "  ok    $desc → contract=$got"
  pass=$((pass + 1))
}

# --- fixture: a repo with a base commit and three candidate heads --------------------
REPO="$WORK/repo"
mkdir -p "$REPO"
cd "$REPO"
git init -q .
git config user.email t@t.t
git config user.name t
git config commit.gpgsign false
mkdir -p contracts/src docs
echo base > docs/README.md
git add -A && git commit -qm base
BASE="$(git rev-parse HEAD)"

echo "contract" > contracts/src/A.sol
git add -A && git commit -qm contract-change
HEAD_CONTRACT="$(git rev-parse HEAD)"

git checkout -q "$BASE"
echo more > docs/GUIDE.md
git add -A && git commit -qm docs-change
HEAD_DOCS="$(git rev-parse HEAD)"

# A diff far larger than the 64 KiB pipe buffer, which is what defect 2 needed. These
# workflows compute the diff by hand precisely BECAUSE GitHub's `paths:` filter stops at
# 300 files, so the many-thousand-file PR is in scope by construction.
git checkout -q "$BASE"
mkdir -p contracts/src/bulk
for i in $(seq 1 3000); do echo x > "contracts/src/bulk/F$i.sol"; done
git add -A && git commit -qm bulk-contract-change
HEAD_BULK="$(git rev-parse HEAD)"

# Defect 3: a contract path whose name is not ASCII. git C-quotes such paths by default,
# which breaks the `^contracts/` anchor.
git checkout -q "$BASE"
mkdir -p contracts/src
printf 'x\n' > "contracts/src/日本語.sol"
git add -A && git commit -qm unicode-contract-change
HEAD_UNICODE="$(git rev-parse HEAD)"

# Control for the case above: equally large, but nothing the gate should match.
git checkout -q "$BASE"
mkdir -p docs/bulk
for i in $(seq 1 3000); do echo x > "docs/bulk/F$i.md"; done
git add -A && git commit -qm bulk-docs-change
HEAD_BULK_DOCS="$(git rev-parse HEAD)"

# An unreachable base: a real 40-hex object id that is not in this repo.
GONE="$(printf 'deadbeef%.0s' 1 2 3 4 5)"

echo "detect-contract-changes.sh"

echo "— the diff decides when it can be computed and scanned"
expect_gate "contract change → apply"        true  EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_CONTRACT"
expect_gate "docs-only change → skip"        false EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_DOCS"
expect_gate "no change at all → skip"        false EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$BASE"

echo "— defect 2: a diff larger than the pipe buffer (round-10 answered 'skip' here)"
expect_gate "3000 contract paths → apply"    true  EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_BULK"
expect_gate "3000 docs paths → skip"         false EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_BULK_DOCS"

echo "— defect 3: a non-ASCII contract path (git C-quotes it, breaking the anchor)"
expect_gate "unicode contract path → apply"  true  EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_UNICODE"

echo "— caller patterns: x402-facilitator-node (its own regex, not just the control flow)"
git checkout -q -B x402branch "$BASE"
mkdir -p packages/x402-facilitator-node/src
echo "x" > packages/x402-facilitator-node/src/index.ts
git add -A >/dev/null; git commit -qm "x402 change"
HEAD_X402="$(git rev-parse HEAD)"
GATE_REGEX="$X402_REGEX" \
  expect_gate "x402 src change → apply"        true  EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_X402"
# The paired control: without it, a pattern that matched EVERYTHING would pass the row above.
GATE_REGEX="$X402_REGEX" \
  expect_gate "contract change → skip for x402" false EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_CONTRACT"
GATE_REGEX="$X402_REGEX" \
  expect_gate "docs-only change → skip for x402" false EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_DOCS"
# And the reverse pairing: the contract pattern must NOT fire on an x402-only change.
expect_gate "x402 change → skip for contracts"  false EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_X402"
# The pattern's OTHER alternatives need rows too, or a typo in them is invisible: the
# extraction below anchors on the package name, so a mistyped package name breaks
# extraction loudly, while a mistyped `.github/scripts/` would extract fine and silently
# stop the gate firing when the detector itself changes.
git checkout -q -B x402scripts "$BASE"
mkdir -p .github/scripts
echo "x" > .github/scripts/detect-contract-changes.sh
git add -A >/dev/null; git commit -qm "detector change"
HEAD_DETECTOR="$(git rev-parse HEAD)"
GATE_REGEX="$X402_REGEX" \
  expect_gate "detector change → apply for x402"  true  EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_DETECTOR"
git checkout -q -B x402wf "$BASE"
mkdir -p .github/workflows
echo "x" > .github/workflows/x402-facilitator-node.yml
git add -A >/dev/null; git commit -qm "workflow change"
HEAD_WF="$(git rev-parse HEAD)"
GATE_REGEX="$X402_REGEX" \
  expect_gate "workflow change → apply for x402"  true  EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_WF"

echo "— defect 1: the diff cannot be computed (round-10 answered 'skip' here)"
expect_gate "base unreachable → apply"       true  EVENT=pull_request BASE_SHA="$GONE" HEAD_SHA="$HEAD_DOCS"
expect_gate "head unreachable → apply"       true  EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$GONE"
expect_gate "BASE_SHA empty → apply"         true  EVENT=pull_request BASE_SHA=""      HEAD_SHA="$HEAD_DOCS"
expect_gate "HEAD_SHA empty → apply"         true  EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA=""
expect_gate "not a git repo → apply"         true  EVENT=pull_request BASE_SHA="$BASE" HEAD_SHA="$HEAD_DOCS" GIT_DIR=/nonexistent

echo "— non-PR events never consult a diff"
expect_gate "push event → apply"             true  EVENT=push        BASE_SHA=""       HEAD_SHA=""
expect_gate "EVENT unset → apply"            true  BASE_SHA=""       HEAD_SHA=""

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
