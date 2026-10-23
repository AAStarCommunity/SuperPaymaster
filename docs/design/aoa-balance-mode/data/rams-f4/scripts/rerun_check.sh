#!/bin/bash
# R2-F4: compare the R2A rows of a re-run log dir with the original log dir, file by file.
# Usage: scripts/rerun_check.sh <original dir> <re-run dir>
for f in "$2"/*.log; do b=$(basename "$f"); o="$1/$b"
  if [ -f "$o" ]; then a=$(grep -o 'R2A|.*' "$o" | sha256sum | cut -c1-64); c=$(grep -o 'R2A|.*' "$f" | sha256sum | cut -c1-64)
    echo "$b rows $(grep -c 'R2A|' "$o")/$(grep -c 'R2A|' "$f") $([ "$a" = "$c" ] && echo IDENTICAL || echo DIFFERENT) $c"
  else echo "$b (no original)"; fi
done
