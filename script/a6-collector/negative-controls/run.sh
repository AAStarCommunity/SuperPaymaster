#!/usr/bin/env bash
# Fixture negative controls + positive control + one N=50 mechanism run for the A6 gauge.
# LOCAL ANVIL ONLY. Writes every log / JSONL / validator report into <outDir>.
#
# Preconditions (see docs/design/aoa-balance-mode/data/a6-gauge-local/README.md):
#   anvil on 127.0.0.1:8545, `./deploy-core anvil --force && ./prepare-test anvil` done,
#   baselines deployed: node script/a6-collector/deploy-baselines.mjs http://127.0.0.1:8545 <baselines.json>
#
# Usage: script/a6-collector/negative-controls/run.sh <outDir> <baselines.json>
set -u
OUT=${1:?usage: run.sh <outDir> <baselines.json>}
BASELINES=${2:?usage: run.sh <outDir> <baselines.json>}
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
GAUGE="$ROOT/script/a6-collector"
A=http://127.0.0.1:8545
B=http://127.0.0.1:8546      # pass-through proxy in front of the SAME anvil (A/B topology: see README)
BT=http://127.0.0.1:8547     # tampering proxy in front of the SAME anvil (control d only)
mkdir -p "$OUT"
cd "$ROOT"

EP=$(jq -r .entryPoint deployments/config.anvil.json)
SP=$(jq -r .superPaymaster deployments/config.anvil.json)
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
TOKEN=$(cast call "$SP" "operators(address)(uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)" $DEPLOYER --rpc-url $A | sed -n 4p)
GTOKEN=$(jq -r .gToken deployments/config.anvil.json)

node "$GAUGE/rpc-proxy.mjs" --listen 8546 --upstream $A > "$OUT/proxy-B-passthrough.log" 2>&1 &
P1=$!
node "$GAUGE/rpc-proxy.mjs" --listen 8547 --upstream $A --tamper-to "$TOKEN" --tamper-selector 0x70a08231 --tamper-add 1 > "$OUT/proxy-B-tamper.log" 2>&1 &
P2=$!
trap 'kill $P1 $P2 2>/dev/null' EXIT
sleep 1

RESULTS="$OUT/results.tsv"
printf 'control\tcommand_exit\tvalidator_exit\n' > "$RESULTS"
run() { # name, then collector args
  # A and B are proxies over ONE local anvil: the override is mandatory and disqualifies conformance.
  local name=$1; shift
  node "$GAUGE/collector.mjs" --run-id "$name" --baselines "$BASELINES" --expect-entrypoint "$EP" --out "$OUT/$name.jsonl" --allow-same-endpoint-local "$@" > "$OUT/$name.collector.log" 2>&1
  local ce=$?
  node "$GAUGE/validate.mjs" "$OUT/$name.jsonl" --json "$OUT/$name.validator.json" > "$OUT/$name.validator.log" 2>&1
  local ve=$?
  printf '%s\t%s\t%s\n' "$name" "$ce" "$ve" >> "$RESULTS"
  echo "$name: collector exit $ce, validator exit $ve"
}

# positive control: one real triplet; SP must be USEROP_SUCCESS with every conservation check OK
run positive --rpc-a $A --rpc-b $B --ab-topology "B=pass-through proxy over the same anvil" --count 1 --max-attempts 1 --b-max 1
# (a) tx succeeds, op's execution reverts
run a-exec-revert --rpc-a $A --rpc-b $B --ab-topology "B=pass-through proxy over the same anvil" --count 1 --max-attempts 1 --b-max 1 --fixture exec-revert
# (b) tx succeeds, our op is not in the bundle (a different op of the same sender is)
run b-drop-op --rpc-a $A --rpc-b $B --ab-topology "B=pass-through proxy over the same anvil" --count 1 --max-attempts 1 --b-max 1 --fixture drop-op
# (c) the op lands but the expected userOpHash is wrong
run c-wrong-hash --rpc-a $A --rpc-b $B --ab-topology "B=pass-through proxy over the same anvil" --count 1 --max-attempts 1 --b-max 1 --fixture wrong-hash
# (d) endpoint B returns user xPNTs balance + 1
run d-tamper-b --rpc-a $A --rpc-b $BT --ab-topology "B=TAMPERING proxy over the same anvil (balanceOf on xPNTs +1)" --count 1 --max-attempts 1 --b-max 1 --arms SP

# (e) validator input with a fake operator-balance delta (A and B both, so it is not an A/B mismatch)
node -e '
const fs = require("fs");
const L = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
const i = L.findIndex((r) => r.kind === "attempt" && r.arm === "SP");
for (const s of ["A", "B"]) L[i].readbacks.after[s].operatorBalance = (BigInt(L[i].readbacks.after[s].operatorBalance) + 1000n).toString();
fs.writeFileSync(process.argv[2], L.map((x) => JSON.stringify(x)).join("\n") + "\n");
' "$OUT/positive.jsonl" "$OUT/e-conservation-injected.jsonl"
node "$GAUGE/validate.mjs" "$OUT/e-conservation-injected.jsonl" --json "$OUT/e-conservation-injected.validator.json" > "$OUT/e-conservation-injected.validator.log" 2>&1
VE=$?
printf '%s\t%s\t%s\n' e-conservation-injected "n/a" "$VE" >> "$RESULTS"
echo "e-conservation-injected: validator exit $VE"
# (e') fail closed: a required field removed
node -e '
const fs = require("fs");
const L = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
delete L[1].logs;
fs.writeFileSync(process.argv[2], L.map((x) => JSON.stringify(x)).join("\n") + "\n");
' "$OUT/positive.jsonl" "$OUT/e-missing-field.jsonl"
node "$GAUGE/validate.mjs" "$OUT/e-missing-field.jsonl" --json "$OUT/e-missing-field.validator.json" > "$OUT/e-missing-field.validator.log" 2>&1
VE=$?
printf '%s\t%s\t%s\n' e-missing-field "n/a" "$VE" >> "$RESULTS"
echo "e-missing-field: validator exit $VE"

# OLD collector (origin/feat/aoa-balance-mode-5.5.0) on fixtures (a) and (b)
OLD_REF=${OLD_REF:-origin/feat/aoa-balance-mode-5.5.0}
git show "$OLD_REF:script/a6-collector/collector.mjs" > "$OUT/old-collector.source.mjs"
git rev-parse "$OLD_REF" > "$OUT/old-collector.ref"
node "$GAUGE/negative-controls/patch-old-collector.mjs" "$OUT/old-collector.source.mjs" "$GAUGE/.old-collector-fixture.mjs"
diff -u "$OUT/old-collector.source.mjs" "$GAUGE/.old-collector-fixture.mjs" > "$OUT/old-collector.fixture.diff"
CD=$(cast calldata "execute(address,uint256,bytes)" "$GTOKEN" 0 "$(cast calldata "transfer(address,uint256)" 0x000000000000000000000000000000000000dEaD 1)")
OLD_FIXTURE=exec-revert OLD_FIXTURE_CALLDATA=$CD node "$GAUGE/.old-collector-fixture.mjs" --rpc $A --count 1 --b-max 1 --baselines "$BASELINES" --out "$OUT/old-a-exec-revert.jsonl" > "$OUT/old-a-exec-revert.log" 2>&1
printf '%s\t%s\t%s\n' old-a-exec-revert "$?" "n/a" >> "$RESULTS"
OLD_FIXTURE=drop-op node "$GAUGE/.old-collector-fixture.mjs" --rpc $A --count 1 --b-max 1 --baselines "$BASELINES" --out "$OUT/old-b-drop-op.jsonl" > "$OUT/old-b-drop-op.log" 2>&1
printf '%s\t%s\t%s\n' old-b-drop-op "$?" "n/a" >> "$RESULTS"
rm -f "$GAUGE/.old-collector-fixture.mjs"
node "$GAUGE/negative-controls/recheck-old-rows.mjs" $A "$EP" "$OUT/old-a-exec-revert.jsonl" > "$OUT/old-a-exec-revert.recheck.json"
node "$GAUGE/negative-controls/recheck-old-rows.mjs" $A "$EP" "$OUT/old-b-drop-op.jsonl" > "$OUT/old-b-drop-op.recheck.json"

# Mechanism run at the protocol's N=50 (local Anvil; NOT A6 data)
run n50-mechanism --rpc-a $A --rpc-b $B --ab-topology "B=pass-through proxy over the same anvil" --count 50 --b-max 1

node "$GAUGE/negative-controls/table.mjs" "$OUT" > "$OUT/NEGATIVE-CONTROLS.md"
echo "wrote $OUT/NEGATIVE-CONTROLS.md"
