#!/bin/sh
set -eu
exec python3 "$(dirname "$0")/deploylive_rehearse.py" hook "$@"
