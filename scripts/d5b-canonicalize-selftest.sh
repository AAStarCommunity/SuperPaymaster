#!/usr/bin/env bash
# Offline self-test: --canonicalize is a formatting helper, never a check. Combined with any check
# option it must exit 2 AND overwrite an --attest path with FAIL (no earlier PASS may survive).
set -uo pipefail
C=script/governance/check-timelock-roles.mjs; EX=deployments/timelock-roles.example.json
T=$(mktemp -d "${TMPDIR:-/tmp}/canon.XXXX"); trap 'rm -rf "$T"' EXIT
bad=0; ok() { echo "ok    $1"; }; no() { echo "FAIL  $1"; bad=1; }
pass() { printf '{"schema":"d5b-timelock-roles-attestation/2","result":"PASS"}\n' > "$T/att.json"; }
res() { python3 -c "import json;print(json.load(open('$T/att.json'))['result'])"; }
for extra in "--attest $T/att.json" "--attest $T/att.json --rpc http://127.0.0.1:1" "--attest $T/att.json --manifest $EX"; do
  pass; node $C --canonicalize $EX $extra >/dev/null 2>&1; rc=$?
  [ $rc -eq 2 ] && [ "$(res)" = FAIL ] && ok "combined ($extra) -> exit 2, PASS replaced by FAIL" || no "combined ($extra): rc=$rc result=$(res)"
done
node $C --canonicalize $EX > "$T/out.json" 2>/dev/null; rc=$?
[ $rc -eq 0 ] && cmp -s "$T/out.json" $EX && ok "plain --canonicalize prints the canonical example (positive control)" || no "plain rc=$rc"
printf 'not json' > "$T/bad.json"; pass
node $C --canonicalize "$T/bad.json" --attest "$T/att.json" >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && [ "$(res)" = FAIL ] && ok "unparsable input -> exit 2, FAIL written" || no "unparsable rc=$rc result=$(res)"
[ $bad -eq 0 ] && echo "SELFTEST: canonicalize controls behave" || { echo "SELFTEST: FAILED"; exit 1; }
