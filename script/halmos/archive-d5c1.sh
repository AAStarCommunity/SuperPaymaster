#!/usr/bin/env bash
# D5c-1 — the archive items of the mandatory suite (verify-d5c1.py REQUIRED["archives"]):
#   artifact-parity.log      artifact-parity.py twice: after the Halmos-style build (--ast) and after a
#                            plain `forge build`; each pass followed by the binding of both families,
#                            including every harness contract's creation-bytecode hash
#   forge-halmos-suite.log   the forge suite of contracts/test/halmos (replay / layout / priming /
#                            boundary / fuzz substitutes), bound to the tree
#   verify-selftest.log      the verdict authority's own controls (first line: sha256 of the scripts)
# usage (repo root, clean tree, no Halmos run in progress): script/halmos/archive-d5c1.sh [parity|suite|selftest|all]
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
D=docs/design/aoa-balance-mode/data/halmos
W="${1:-all}"
RC=0
if [ "$W" = all ] || [ "$W" = parity ]; then
  {
    echo "# pass 1: after the Halmos-style build (forge build --ast --extra-output storageLayout metadata)"
    forge build --ast --extra-output storageLayout metadata > /dev/null 2>&1
    python3 script/halmos/artifact-parity.py || RC=1
    python3 script/halmos/d5c1_binding.py xpnts --line --all-artifacts
    python3 script/halmos/d5c1_binding.py apnts --line --all-artifacts
    echo "# pass 2: after a plain forge build (the deployment build)"
    forge build > /dev/null 2>&1
    python3 script/halmos/artifact-parity.py || RC=1
    python3 script/halmos/d5c1_binding.py xpnts --line --all-artifacts
    python3 script/halmos/d5c1_binding.py apnts --line --all-artifacts
  } > "$D/artifact-parity.log" 2>&1
  grep -E "^(# pass|RESULT)" "$D/artifact-parity.log"
fi
if [ "$W" = all ] || [ "$W" = suite ]; then
  forge test --match-path "contracts/test/halmos/*.t.sol" > "$D/forge-halmos-suite.log" 2>&1 || RC=1
  python3 script/halmos/d5c1_binding.py xpnts --line >> "$D/forge-halmos-suite.log"
  grep -E "^Ran [0-9]+ test suites" "$D/forge-halmos-suite.log"
fi
if [ "$W" = all ] || [ "$W" = selftest ]; then
  python3 script/halmos/verify-selftest.py > "$D/verify-selftest.log" 2>&1 || RC=1
  tail -1 "$D/verify-selftest.log"
fi
exit $RC
