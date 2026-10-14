#!/usr/bin/env bash
# Source this file and call require_revert <log> <description> <command...>.
require_revert() {
  local log="$1" what="$2" rc evidence
  shift 2
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "NEGATIVE CONTROL FAILED: required command missing: $1" >&2
    return 2
  fi
  "$@" >"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || [ "$rc" -ge 126 ]; then
    echo "NEGATIVE CONTROL FAILED: $what (exit $rc)" >&2
    return 2
  fi
  if env -u GREP_OPTIONS grep -Eiq 'connection refused|error sending request' "$log"; then
    echo "NEGATIVE CONTROL FAILED: $what had a transport error" >&2
    return 2
  fi
  evidence=$(env -u GREP_OPTIONS grep -Eio '(^|[^[:alpha:]])(execution reverted|revert(ed|ing)?)([^[:alpha:]]|$)' "$log" | head -1)
  if [ -z "$evidence" ]; then
    echo "NEGATIVE CONTROL FAILED: $what has no revert evidence (exit $rc)" >&2
    return 2
  fi
  echo "  negative ok: $what reverted ($evidence)"
}
