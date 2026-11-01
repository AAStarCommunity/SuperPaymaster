#!/usr/bin/env bash
# Local Amsterdam only. All signing uses public Anvil development keys.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
: "${A6_FOUNDRY_NIGHTLY_DIR:?Set A6_FOUNDRY_NIGHTLY_DIR to the Foundry nightly binary directory}"
export PATH="$A6_FOUNDRY_NIGHTLY_DIR:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
# Forge's automatic submodule installation must never write this worktree's .git.
export GIT_DIR=/dev/null
unset PRIVATE_KEY PRIVATE_KEY_ANNI DEPLOYER_ACCOUNT
export ENV=anvil LOCAL_DEV_GOVERNANCE_ACK=true
# freeze() rejects symlinked ancestors; macOS $TMPDIR and /tmp both resolve through /private.
D=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/a6-rehearsal.XXXXXX")" && pwd -P)
W="$D/window"
mkdir "$W"
PORT=${A6_REHEARSAL_PORT:-19545}
BPORT=$((PORT+1))
A="http://127.0.0.1:$PORT"
B="http://127.0.0.1:$BPORT"
P1= P2=
if [[ -f deployments/config.anvil.json ]]; then cp deployments/config.anvil.json "$D/original-config.json"; fi
cleanup() {
  [[ -z "$P1" ]] || kill "$P1" 2>/dev/null || true
  [[ -z "$P2" ]] || kill "$P2" 2>/dev/null || true
  if [[ -f "$D/original-config.json" ]]; then cp "$D/original-config.json" deployments/config.anvil.json; else rm -f deployments/config.anvil.json; fi
}
trap cleanup EXIT
printf 'REHEARSAL_WINDOW=%s\n' "$W"
anvil --host 127.0.0.1 --port "$PORT" --hardfork prague --disable-code-size-limit > "$D/anvil.log" 2>&1 & P1=$!
for _ in {1..50}; do if cast chain-id --rpc-url "$A" >/dev/null 2>&1; then break; fi; sleep .2; done
if ! kill -0 "$P1" 2>/dev/null; then cat "$D/anvil.log" >&2; exit 1; fi
# Rehearsal only (format integration, never evidence): Prague, because stable forge underestimates Amsterdam state gas
# and nightly forge fails decoding TimelockController constructor arguments after broadcast. Pilot and formal sampling
# run on Sepolia (Amsterdam). The chain here is the nightly anvil at --hardfork prague; compiling and deploying use stable forge 1.7.1, because nightly forge
# fails decoding TimelockController constructor arguments after broadcast.
FORGE="$HOME/.foundry/bin/forge"
"$FORGE" build --offline > "$D/build.log" 2>&1
"$FORGE" script contracts/script/v3/DeployAnvil.s.sol:DeployAnvil --offline --rpc-url "$A" --broadcast --slow --disable-code-size-limit > "$D/deploy.log" 2>&1
"$FORGE" script contracts/script/v3/TestAccountPrepare.s.sol:TestAccountPrepare --offline --rpc-url "$A" --broadcast --slow --disable-code-size-limit > "$D/prepare.log" 2>&1
cp deployments/config.anvil.json "$D/deployment.json"
node script/a6-collector/deploy-baselines.mjs "$A" "$D/baselines-local.json" "$D/deployment.json" > "$D/baselines.log" 2>&1
node script/a6-collector/rpc-proxy.mjs --listen "$BPORT" --upstream "$A" > "$D/proxy.log" 2>&1 & P2=$!
sleep 1
node script/a6-collector/collector.mjs --rpc-a "$A" --rpc-b "$B" --allow-same-endpoint-local --count 1 --b-max 1 --config "$D/deployment.json" --baselines "$D/baselines-local.json" --out "$D/setup.jsonl" > "$D/setup.log" 2>&1
node script/a6-collector/rehearsal-setup.mjs "$A" "$D" "$D/deployment.json" "$D/baselines-local.json"
printf '%s' "$A" > "$D/rpc-a"
printf '%s' "$B" > "$D/rpc-b"
# Automine plus periodic empty blocks permits the real dual-head gate to advance.
cast rpc anvil_setIntervalMining 1 --rpc-url "$A" >/dev/null
node script/a6-collector/collector.mjs --rehearsal --count 3 --max-attempts 5 --b-max 1 --formal-config "$D/formal-config.json" --config "$D/deployment.json" --baselines "$D/baselines.json" --rpc-a-file "$D/rpc-a" --rpc-b-file "$D/rpc-b" --rpc-registry "$D/rpc-identity.json" --pins "$D/pins.json" --out "$W/run.jsonl" > "$D/collector.log" 2>&1
node --input-type=module - "$W" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
const window=process.argv[2];
const attempts=readFileSync(`${window}/run.jsonl`,'utf8').trim().split('\n').map(JSON.parse).filter(r=>r.kind==='attempt' && r.arm==='TPM' && r.sent);
const rows=attempts.map(r=>({attempt:r.attemptIndex,postOpRefreshed:r.postOpRefreshed,
  oldPolicyWouldRefresh:r.postOpRefreshed || r.traces.some(t=>['pre','post'].some(side=>Object.keys(t.state[side][r.paymaster.toLowerCase()]?.storage ?? {}).length>0))}));
const report={rehearsal:true,cachedPriceSlots:{cachedPrice:3,cachedPriceTimestamp:4},attempts:rows,
  allTPMFlaggedByOldPolicy:rows.length>0 && rows.every(r=>r.oldPolicyWouldRefresh)};
if(rows.filter(r=>r.postOpRefreshed===true).length!==1 || !rows.some(r=>r.attempt===4 && r.postOpRefreshed===true)) throw Error('expected exactly the chosen TPM refresh');
writeFileSync(`${window}/tpm-refresh-report.json`,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));
JS
printf '{"rehearsal":true,"seed":"dummy-not-evidence","samples":[]}' > "$D/sampling.json"
node script/a6-collector/freeze.mjs "$W" --sampling "$D/sampling.json"
set +e
node script/a6-collector/validate.mjs "$W/run.jsonl" --json "$D/validator.json" | tee "$D/validator.log"
V=${PIPESTATUS[0]}
set -e
[[ "$V" = 3 ]]
node -e 'const r=require(process.argv[1]); if(!r.consistent || r.accepted || !r.rehearsal) process.exit(1)' "$D/validator.json"
node -e 'const t=require(process.argv[1]); if(t.triples.length!==5 || t.replacements.length!==2 || t.replacements[0].reason!=="AA32" || t.replacements[1].reason!=="tpm_postop_refresh" || t.replacements.some((r,i)=>r.abandoned.tripleIndex!==i || r.replacement.tripleIndex!==i+1)) process.exit(1)' "$W/trailer.json"
find "$W" -type f | sort
printf 'REHEARSAL_WINDOW=%s\n' "$W"
