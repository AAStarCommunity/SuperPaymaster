#!/bin/bash
cd /private/tmp/claude-502/-Users-jason-Dev-aastar-SuperPaymaster/13f6212e-b200-423b-852b-995b2d8a30a5/scratchpad/rc2clean || exit 9
OUT=../i9ae7d/out
CMD='forge test --match-path contracts/test/v2/SuperPaymaster{CtxLengthRc2,I9Fuzz}.t.sol'
echo "$CMD" > $OUT/forge-test.cmd
"$HOME/.foundry/bin/forge" --version > $OUT/forge-version.txt
"$HOME/.foundry/bin/forge" test --match-path 'contracts/test/v2/SuperPaymaster{CtxLengthRc2,I9Fuzz}.t.sol' > $OUT/forge-test.log 2>&1
echo $? > $OUT/forge-test.exit
python3 script/halmos/test_run_i9_witness.py > $OUT/runner-unittests.log 2>&1
echo $? > $OUT/runner-unittests.exit
