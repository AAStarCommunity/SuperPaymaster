#!/usr/bin/env bash
# Run a command and save its combined output as an evidence log with a provenance header.
# Usage: script/evidence/run-logged.sh <out.log> <command> [args...]
# Header: the exact command, git HEAD (+ dirty flag), forge version, UTC time. Compiler warnings
# (forge prints several hundred before the test output) are dropped: every line before the first
# "Ran N test" / "Script ran" / "Traces:" / "== Logs ==" marker is omitted, and the log says so.
set -uo pipefail
out="$1"; shift
tmp="$(mktemp)"
"$@" >"$tmp" 2>&1
rc=$?
{
  echo "# command: $*"
  env | grep -E '^(G2_|FOUNDRY_PROFILE=|FORK_|ANVIL_)' | sed 's/^/# env: /' || true
  echo "# git HEAD: $(git rev-parse HEAD)$(git diff --quiet HEAD -- contracts || echo ' (+ uncommitted changes under contracts/)')"
  echo "# forge: $("$HOME/.foundry/bin/forge" --version | head -1)"
  echo "# utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# exit code: $rc"
  if grep -qnE '^(Ran [0-9]+ tests? for|Script ran|== Logs ==|Traces:)' "$tmp"; then
    first="$(grep -nE '^(Ran [0-9]+ tests? for|Script ran|== Logs ==|Traces:)' "$tmp" | head -1 | cut -d: -f1)"
    echo "# (compiler output before line $first omitted)"
    tail -n +"$first" "$tmp"
  else
    cat "$tmp"
  fi
} >"$out"
rm -f "$tmp"
exit $rc
