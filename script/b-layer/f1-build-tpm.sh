#!/usr/bin/env bash
# F1 control experiment: compile the UNMODIFIED eth-infinitism v0.7 sample TokenPaymaster
# (singleton-paymaster/lib/account-abstraction-v7/contracts/samples/TokenPaymaster.sol) in a
# throw-away foundry project, because it imports @uniswap/v3-periphery, which this repo does not
# vendor (and foundry.toml / remappings of this repo must not change). The resulting artifact
# (abi + creation bytecode + the exact remappings/compiler) is written to
# docs/design/aoa-balance-mode/b-layer/cases/f1/TokenPaymaster.json.
# Usage: script/b-layer/f1-build-tpm.sh <workDir> <@uniswap node_modules dir (has v3-core, v3-periphery)>
set -euo pipefail
W="$1"; UNI="$2"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FORGE="${FORGE:-$HOME/.foundry/bin/forge}"
AA="$ROOT/singleton-paymaster/lib/account-abstraction-v7/contracts"
OZ="$ROOT/singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts"
mkdir -p "$W/src"
cat >"$W/foundry.toml" <<EOF
[profile.default]
src = "src"
out = "out"
solc_version = "0.8.33"
evm_version = "cancun"
optimizer = true
optimizer_runs = 1000000
via_ir = false
allow_paths = ["$AA", "$OZ", "$UNI"]
EOF
cat >"$W/remappings.txt" <<EOF
aa/=$AA/
@openzeppelin/contracts/=$OZ/
@uniswap/v3-periphery/=$UNI/v3-periphery/
@uniswap/v3-core/=$UNI/v3-core/
EOF
echo 'import "aa/samples/TokenPaymaster.sol";' >"$W/src/TPM.sol"
( cd "$W" && "$FORGE" build --quiet )
node -e '
const fs=require("fs"); const [w,out,aa]=process.argv.slice(1);
const j=JSON.parse(fs.readFileSync(w+"/out/TokenPaymaster.sol/TokenPaymaster.json"));
const src=fs.readFileSync(aa+"/samples/TokenPaymaster.sol");
const sha=require("crypto").createHash("sha256").update(src).digest("hex");
fs.mkdirSync(require("path").dirname(out),{recursive:true});
fs.writeFileSync(out, JSON.stringify({ source: "singleton-paymaster/lib/account-abstraction-v7/contracts/samples/TokenPaymaster.sol",
  sourceSha256: sha, compiler: "solc 0.8.33, optimizer 1e6 runs (upstream hardhat config), cancun",
  abi: j.abi, bytecode: j.bytecode.object }, null, 1));
console.log("TokenPaymaster artifact", out, "source sha256", sha, "bytecode bytes", (j.bytecode.object.length-2)/2);
' "$W" "$ROOT/docs/design/aoa-balance-mode/b-layer/cases/f1/TokenPaymaster.json" "$AA"
