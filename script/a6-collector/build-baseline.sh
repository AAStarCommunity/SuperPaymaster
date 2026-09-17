#!/usr/bin/env bash
# Compile an UNMODIFIED eth-infinitism v0.7 sample paymaster (VerifyingPaymaster or
# TokenPaymaster) in a throw-away foundry project, because TokenPaymaster imports
# @uniswap/v3-periphery which this repo does not vendor (and this repo's own foundry.toml /
# remappings must not change to accommodate it). Same technique as
# script/b-layer/f1-build-tpm.sh (kept there unmodified since existing F1 evidence
# reproduction depends on its exact invocation) — generalized here to also build
# VerifyingPaymaster, which needs no Uniswap remapping at all.
#
# Usage: script/a6-collector/build-baseline.sh <workDir> <VerifyingPaymaster|TokenPaymaster> <outJson> [<@uniswap node_modules dir>]
set -euo pipefail
W="$1"; NAME="$2"; OUT="$3"; UNI="${4:-}"
if [[ "$NAME" != "VerifyingPaymaster" && "$NAME" != "TokenPaymaster" ]]; then
  echo "usage: build-baseline.sh <workDir> <VerifyingPaymaster|TokenPaymaster> <outJson> [<uniswap dir>]" >&2
  exit 2
fi
if [[ "$NAME" == "TokenPaymaster" && -z "$UNI" ]]; then
  echo "TokenPaymaster needs a <@uniswap node_modules dir> (containing v3-core/ and v3-periphery/)" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FORGE="${FORGE:-$HOME/.foundry/bin/forge}"
AA="$ROOT/singleton-paymaster/lib/account-abstraction-v7/contracts"
OZ="$ROOT/singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts"
mkdir -p "$W/src"

{
  echo '[profile.default]'
  echo 'src = "src"'
  echo 'out = "out"'
  echo 'solc_version = "0.8.33"'
  echo 'evm_version = "cancun"'
  echo 'optimizer = true'
  echo 'optimizer_runs = 1000000'
  echo 'via_ir = false'
  if [[ -n "$UNI" ]]; then
    echo "allow_paths = [\"$AA\", \"$OZ\", \"$UNI\"]"
  else
    echo "allow_paths = [\"$AA\", \"$OZ\"]"
  fi
} > "$W/foundry.toml"

{
  echo "aa/=$AA/"
  echo "@openzeppelin/contracts/=$OZ/"
  if [[ -n "$UNI" ]]; then
    echo "@uniswap/v3-periphery/=$UNI/v3-periphery/"
    echo "@uniswap/v3-core/=$UNI/v3-core/"
  fi
} > "$W/remappings.txt"

echo "import \"aa/samples/${NAME}.sol\";" > "$W/src/${NAME}Wrap.sol"
( cd "$W" && "$FORGE" build --quiet )

node -e '
const fs = require("fs");
const [w, name, out, aa] = process.argv.slice(1);
const j = JSON.parse(fs.readFileSync(`${w}/out/${name}.sol/${name}.json`));
const src = fs.readFileSync(`${aa}/samples/${name}.sol`);
const sha = require("crypto").createHash("sha256").update(src).digest("hex");
fs.mkdirSync(require("path").dirname(out), { recursive: true });
fs.writeFileSync(out, JSON.stringify({
  source: `singleton-paymaster/lib/account-abstraction-v7/contracts/samples/${name}.sol`,
  sourceSha256: sha,
  compiler: "solc 0.8.33, optimizer 1e6 runs, cancun",
  abi: j.abi,
  bytecode: j.bytecode.object,
}, null, 1));
console.log(`${name} artifact -> ${out}  source sha256 ${sha}  bytecode bytes ${(j.bytecode.object.length - 2) / 2}`);
' "$W" "$NAME" "$OUT" "$AA"
