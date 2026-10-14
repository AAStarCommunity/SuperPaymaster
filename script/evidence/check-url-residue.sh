#!/usr/bin/env bash
# Exit 0 only when the complete directory scan succeeds and finds no URL.
# Scan hidden, ignored, binary, and linked content without user search configuration.
set -uo pipefail
command -v grep >/dev/null 2>&1 || { echo "required tool missing: grep" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "required tool missing: python3" >&2; exit 2; }
if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then echo "URL scan requires a directory" >&2; exit 2; fi
dir="$1"
# BSD find silently prunes ancestor links while rg reports a filesystem loop.
python3 - "$dir" <<'PY' || { echo "URL scan failed in $dir (filesystem traversal)" >&2; exit 2; }
import os, pathlib, sys
def fail(error):
    raise error
for parent, dirs, _ in os.walk(sys.argv[1], followlinks=True, onerror=fail):
    ancestor = pathlib.Path(parent).resolve()
    for name in dirs:
        target = pathlib.Path(parent, name).resolve()
        if target == ancestor or target in ancestor.parents:
            raise RuntimeError("filesystem loop")
PY
if command -v rg >/dev/null 2>&1; then
  rg --no-config -uuu -a -L -i -l 'https?:(\\*[/]){2}' "$dir" >/dev/null
  rc=$?
else
  command -v find >/dev/null 2>&1 || { echo "required tool missing: find" >&2; exit 2; }
  files=$(mktemp) || exit 2
  trap 'rm -f "$files"' EXIT
  if ! find -L "$dir" \( -type f -o -type l \) -print0 > "$files"; then
    rc=2
  else
    rc=1
    while IFS= read -r -d '' file; do
      if [ -L "$file" ] && [ ! -e "$file" ]; then rc=2; break; fi
      env -u GREP_OPTIONS grep -Eila 'https?:(\\*[/]){2}' "$file" >/dev/null
      match_rc=$?
      if [ "$match_rc" -eq 0 ]; then rc=0
      elif [ "$match_rc" -ne 1 ]; then rc=2; break
      fi
    done < "$files"
  fi
fi
case "$rc" in
  0) echo "URL redaction failed in $dir" >&2; exit 1 ;;
  1) exit 0 ;;
  *) echo "URL scan failed in $dir (exit $rc)" >&2; exit 2 ;;
esac
