#!/bin/bash
# Provenance for the clean rc.2 tree the runs used.
cd /private/tmp/claude-502/-Users-jason-Dev-aastar-SuperPaymaster/13f6212e-b200-423b-852b-995b2d8a30a5/scratchpad/rc2clean || exit 9
OUT=../i9ae7d/out
{
  echo "## clean tree"
  echo "git rev-parse HEAD: $(git rev-parse HEAD)"
  echo "git describe: $(git describe --tags --exact-match HEAD 2>/dev/null || echo -)"
  echo "v5.5.0-rc.2 peeled: $(git rev-parse 'v5.5.0-rc.2^{}' 2>/dev/null)"
  echo "git status --short (only the overlaid TEST/RUNNER files may appear):"
  git status --short --untracked-files=no
  echo "git diff --stat HEAD -- contracts/src (must be empty):"
  git diff --stat HEAD -- contracts/src
  echo "contracts/lib/solady copied from submodule checkout at 90db92ce (rc.2 gitlink 90db92ce)"
  echo "contracts/lib/chainlink-brownie-contracts copied from submodule checkout at 6e324d8a (rc.2 gitlink 6e324d8a)"
  echo
  echo "## tool versions"
  echo "halmos: $($HOME/.local/bin/halmos --version 2>&1 | tail -1)"
  echo "yices-smt2: $($HOME/.local/share/uv/tools/halmos/bin/yices-smt2 --version 2>&1 | head -1)"
  echo "forge: $($HOME/.foundry/bin/forge --version 2>&1 | head -1)"
  echo "solc (foundry.toml): $(grep -m1 solc_version foundry.toml)"
  echo "python3: $(python3 --version 2>&1)"
  echo "uname: $(uname -sr)"
  echo
  echo "## sha256 (paths relative to repo root)"
  shasum -a 256 contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol \
    contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol \
    contracts/test/halmos/SuperPaymasterI9Halmos.t.sol contracts/test/halmos/HalmosSVM.sol \
    contracts/test/halmos/SuperPaymasterI9Rc2Halmos.t.sol contracts/test/v2/SuperPaymasterCtxLengthRc2.t.sol \
    contracts/test/v2/SuperPaymasterI9Fuzz.t.sol \
    script/halmos/run-i9-witness.py script/halmos/test_run_i9_witness.py foundry.toml
  echo "contracts/src tree (sha256 of 'shasum -a 256' over every file, sorted):"
  find contracts/src -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256
  echo "git ls-tree HEAD contracts/src: $(git rev-parse HEAD:contracts/src)"
} > $OUT/PROVENANCE.txt 2>&1
