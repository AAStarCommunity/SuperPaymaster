#!/usr/bin/env bash
# Source this file and call require_revert <log> <description> <expected> <command...>.
# Forge controls supply a script failure reason; cast controls supply the full revert reason.
require_revert() {
  local log="$1" what="$2" expected="$3" rc evidence="" line
  shift 3
  : >"$log" || { echo "NEGATIVE CONTROL FAILED: cannot write $log" >&2; return 2; }
  if [[ "$expected" == "execution reverted: custom error "* ]] &&
     ! [[ "$expected" =~ ^execution\ reverted:\ custom\ error\ 0x[[:xdigit:]]{8}$ ]]; then
    echo "NEGATIVE CONTROL FAILED: invalid expected selector: $expected" >&2
    return 2
  fi
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
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$expected" == "execution reverted: "* ]]; then
      case "$line" in
        "Error: Failed to estimate gas: "*"$expected"*|"Error: server returned an error response: "*"$expected"*|"Error: $expected"*) evidence="$expected"; break ;;
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
