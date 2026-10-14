#!/usr/bin/env bash
# Exit 0 only when the complete directory scan succeeds and finds no URL.
set -uo pipefail
command -v grep >/dev/null 2>&1 || { echo "required tool missing: grep" >&2; exit 2; }
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then echo "URL scan requires a directory" >&2; exit 2; fi
dir="$1"
if command -v rg >/dev/null 2>&1; then
  rg -l 'https?://' "$dir" >/dev/null
  rc=$?
else
  grep -rEl 'https?://' "$dir" >/dev/null
  rc=$?
fi
case "$rc" in
  0) echo "URL redaction failed in $dir" >&2; exit 1 ;;
  1) exit 0 ;;
  *) echo "URL scan failed in $dir (exit $rc)" >&2; exit 2 ;;
esac
