#!/usr/bin/env bash
# A-3 negative-control liveness: positive run, then two source mutations (in place, restored + sha256-checked)
set -uo pipefail
export PATH="$HOME/.foundry/bin:$HOME/.local/bin:$PATH"
W=/private/tmp/claude-502/-Users-jason-Dev-aastar-SuperPaymaster/13f6212e-b200-423b-852b-995b2d8a30a5/scratchpad/cc125-rc2
O=/private/tmp/claude-502/-Users-jason-Dev-aastar-SuperPaymaster/13f6212e-b200-423b-852b-995b2d8a30a5/scratchpad/cc125-arch/a3-negatives
mkdir -p "$O"; cd "$W"
T=contracts/test/halmos/D5c1A3Negatives.t.sol
C=contracts/src/tokens/v2/xPNTsTokenV2.sol
E=contracts/src/tokens/v2/xPNTsTokenV2Ext.sol
{ echo "# head: $(git rev-parse HEAD)"; echo "# forge: $(forge --version | head -1)"; echo "# test sha256: $(shasum -a 256 $T)"; echo "# git status --porcelain:"; git status --porcelain; echo "# cmd: forge test --match-path $T -vv"; } > "$O/a3-negatives.log"
forge test --match-path $T -vv >> "$O/a3-negatives.log" 2>&1; echo "# exit_code: $?" >> "$O/a3-negatives.log"
c0=$(shasum -a 256 $C | cut -d' ' -f1); e0=$(shasum -a 256 $E | cut -d' ' -f1)
mut() { # id file old new
  local id="$1" f="$2" old="$3" new="$4"; local L="$O/$1.log"
  python3 -c 'import sys;p,o,n=sys.argv[1:];s=open(p).read();assert s.count(o)==1,"anchor";open(p,"w").write(s.replace(o,n))' "$f" "$old" "$new" || { echo "APPLY FAILED $id"; exit 3; }
  { echo "# mutation $id on $f"; git diff -- "$f"; echo "# cmd: forge test --match-path $T -vv"; } > "$L"
  forge test --match-path $T -vv >> "$L" 2>&1; echo "# exit_code: $?" >> "$L"
  git checkout -- "$f"
  echo "# restored sha256: $(shasum -a 256 $f)" >> "$L"
}
mut M-A3G "$C" 'if (c.genesisSpender == c.superPaymaster) revert InvalidAddress(c.genesisSpender);' '// M-A3G: equality check removed'
mut M-A3R "$E" '            autoApprovedSpenders[sp] = false;
            emit AutoApprovedSpenderRemoved(sp);' '            // M-A3R: removal on rotation dropped'
# state write only (the event still fires): isolates the autoApprovedSpenders assertion
mut M-A3S "$E" '            autoApprovedSpenders[sp] = false;
            emit AutoApprovedSpenderRemoved(sp);' '            emit AutoApprovedSpenderRemoved(sp); // M-A3S: state write dropped, event kept'
if [ "$(shasum -a 256 $C | cut -d' ' -f1)" = "$c0" ] && [ "$(shasum -a 256 $E | cut -d' ' -f1)" = "$e0" ]; then echo RESTORED-OK; else echo RESTORE-MISMATCH; fi
git status --porcelain
for f in "$O"/*.log; do echo "== $f"; grep -E "^\[(PASS|FAIL)|^# exit_code|^Suite" "$f"; done
