#!/usr/bin/env bash
# Source this file and call require_revert <log> <description> <expected> <command...>.
# Forge controls supply the expected script failure reason; cast controls use "execution reverted".
require_revert() {
  local log="$1" what="$2" expected="$3" rc evidence="" line
  shift 3
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
  while IFS= read -r line; do
    if [ "$expected" = "execution reverted" ]; then
      case "$line" in
        "Error: Failed to estimate gas: "*"execution reverted"*|"Error: server returned an error response: "*"execution reverted"*|"Error: execution reverted"*) evidence="execution reverted"; break ;;
      esac
    else
      case "$line" in
        "Error: script failed: $expected"*) evidence="$expected"; break ;;
      esac
    fi
  done < "$log"
  if [ -z "$evidence" ]; then
    echo "NEGATIVE CONTROL FAILED: $what has no revert evidence (exit $rc)" >&2
    return 2
  fi
  echo "  negative ok: $what reverted ($evidence)"
}
