#!/usr/bin/env bash
# LOCAL ANVIL ONLY. Run after deploying and queueing/executing policy 2 as described in
# docs/design/aoa-balance-mode/data/a6-gauge-credit/credit-run.sh.txt.
# This script only reads. The caller supplies the token and a finalized pinned range
# beginning at or before deployment. No keys, signing, time travel, or mining here.
# B proxies A: this tests instrumentation, NOT independent-provider completeness.
# Usage: bash script/evidence/a4-credit-logscan-anvil-control.sh TOKEN FROM TO OUT.json
# Optional local ports: ANVIL_PORT=8545 PROXY_PORT=18546 (proxy port must be free).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TOKEN=${1:?token}
FROM=${2:?from-block}
TO=${3:?to-block}
OUT=${4:?output JSON path}
ANVIL_PORT=${ANVIL_PORT:-8545}
PROXY_PORT=${PROXY_PORT:-18546}
[[ $ANVIL_PORT =~ ^[0-9]+$ && $PROXY_PORT =~ ^[0-9]+$ && $ANVIL_PORT != "$PROXY_PORT" ]] || exit 2
umask 077
TMP=$(mktemp -d)
PP=
cleanup() {
  if [[ -n $PP ]]; then kill "$PP" 2>/dev/null || true; wait "$PP" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
printf 'http://127.0.0.1:%s\n' "$ANVIL_PORT" > "$TMP/a.rpc"
printf 'http://127.0.0.1:%s\n' "$PROXY_PORT" > "$TMP/b.rpc"
node "$ROOT/script/a6-collector/rpc-proxy.mjs" --listen "$PROXY_PORT" \
  --upstream "http://127.0.0.1:$ANVIL_PORT" > "$TMP/proxy.log" 2>&1 &
PP=$!
# Wait for this proxy to start; do not silently use a process already on the port.
python3 - "$TMP/b.rpc" <<'PY'
import json, pathlib, sys, time, urllib.request
url = pathlib.Path(sys.argv[1]).read_text().strip()
body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_chainId", "params": []}).encode()
for _ in range(30):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, body, {"Content-Type": "application/json"}), timeout=1) as r:
            d = json.load(r)
        if d.get("result") != "0x7a69":
            sys.exit("control requires Anvil chain 31337")
        break
    except Exception:
        time.sleep(0.1)
else:
    sys.exit("local proxy not ready")
PY
sleep 0.2
kill -0 "$PP" 2>/dev/null || { echo 'proxy failed to start' >&2; exit 1; }
STATUS=0
python3 "$ROOT/script/evidence/a4-credit-logscan.py" \
  --rpc-a-file "$TMP/a.rpc" --rpc-b-file "$TMP/b.rpc" --token "$TOKEN" \
  --from-block "$FROM" --to-block "$TO" --out "$OUT" || STATUS=$?
[[ $STATUS == 1 ]] || { echo 'expected scanner exit 1 for executed policy' >&2; exit 1; }
python3 - "$OUT" "$TOKEN" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d["chainId"] == 31337 and d["complete"] is True, "scan incomplete"
assert d["C4"]["verdict"] == "fail", "known policy execution was not detected"
assert any(e["policy"] == 2 and e["address"] == sys.argv[2].lower()
           for e in d["C4"]["events"]), "executed policy 2 missing"
print("PASS: known policy 2 execution found; C4=fail (local proxy control only)")
PY
