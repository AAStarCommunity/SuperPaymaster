#!/bin/bash
# Calls ONLY the driver's own build() + verify_build() (deploylive_deploy_day.py); the driver has no build-only entry.
cd /Users/jason/Dev/aastar/sp-wt/rc8-e2e || exit 1
[ -z "$(git status --porcelain)" ] || { echo 'STOP dirty worktree'; exit 1; }
source /Users/jason/Dev/aastar/manifest-live/tmp-evidence/e2e-sepolia-ddf-e6f5c7a8/inputs.env.sh
[ "$SP_COMMIT" = "$(git rev-parse HEAD)" ] || { echo 'STOP SP_COMMIT != HEAD'; exit 1; }
nice -n 10 python3 -c "
import os, sys; sys.path.insert(0, 'script/rehearsal')
from deploylive_deploy_day import build, verify_build
env = dict(os.environ)
build(env, True)          # production=True: enforce deployments/forge-deploy-pin.json
print('VERIFY', verify_build(env, True))
"
echo "exit=$?"
