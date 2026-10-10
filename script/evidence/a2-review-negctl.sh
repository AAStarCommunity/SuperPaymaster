#!/usr/bin/env bash
# Run the same injected read failures against executable old and new script segments.
# Only local shell shims are used; this harness makes no RPC requests or chain writes.
set -uo pipefail
OUT="${1:?output directory}"; OLDREF="${2:-554e956e}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
SCRIPT=script/evidence/a2-full-rehearsal.sh
NEWREF=$(git rev-parse HEAD)
printf 'case\told exit\tnew exit\n' > "$OUT/negctl-table.tsv"
for case_name in prestate-tuple sp-getter-type state-ok-type stage-c-before stage-c-after dummy-jq ledger-list ledger-tx ledger-status ledger-from ledger-count rb-type subshell-rv missing-log endpoint-url redaction-publicnode; do
  old_rc=0; new_rc=0
  for version in old new; do
    ref="$OLDREF"; [ "$version" = new ] && ref="$NEWREF"
    source_path="$SCRIPT"
    [ "$case_name" = redaction-publicnode ] && source_path=script/evidence/a2-read-failclosed-negctl.sh
    if [ "$version" = new ] && [ "${A2_TEST_WORKTREE:-0}" = 1 ]; then cp "$source_path" "$OUT/.source-$version"; else git show "$ref:$source_path" > "$OUT/.source-$version"; fi
    mkdir -p "$OUT/$case_name-$version"
    python3 - "$OUT/.source-$version" "$OUT/.run-$version.sh" "$case_name" "$OUT/$case_name-$version" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text().splitlines()
target, case, out = pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
def between(start, end):
    a = next(i for i, line in enumerate(source) if line.startswith(start))
    b = next(i for i in range(a + 1, len(source)) if source[i].startswith(end))
    return '\n'.join(source[a:b]) + '\n'
def tail(start):
    a = next(i for i, line in enumerate(source) if line.startswith(start))
    return '\n'.join(source[a:]) + '\n'
def verdict():
    return tail('NBANG=$(grep -c') if any(line.startswith('NBANG=$(grep -c') for line in source) else tail('if [ ! -f "$OUT/rehearsal.log" ]')
types = between('rtype() {', '# rv ') if case != 'redaction-publicnode' else ''
prefix = f'''#!/usr/bin/env bash
set -uo pipefail
OUT={out!r}; RPC=http://127.0.0.1:1; FAILURES=0; STAGE=all
fail() {{ rlog "!!! $*"; FAILURES=$((FAILURES+1)); }}
rlog() {{ echo "$*" | tee -a "$OUT/rehearsal.log"; }}
lc() {{ echo "$1" | tr A-F a-f; }}
check() {{ if [ "$2" = "$3" ]; then echo "CHECK [$1] PASS: $2"; else fail "CHECK [$1] FAIL: $2 != $3"; fi; }}
{types}
'''
if case == 'prestate-tuple':
    body = between('xread() {', 'XREAD_N=23')
    body += '''FORK_BLOCK=100; SP=0x0000000000000000000000000000000000000001; REG=$SP; EP=$SP; SAFE=$SP; OLD_TL=$SP; OWNER=$SP; ANNI=$SP; ADMIN_ROLE=0x0; PROPOSER_ROLE=0x0
cast() {
  case "$1" in
    block) printf '0x%064d\\n' 0 ;;
    storage) printf '0x%064d\\n' 0 ;;
    call) case "$3" in
      *operators*) echo malformed-operator-tuple ;;
      *getDepositInfo*) echo '(1, true, 2, 3, 4)' ;;
      *getModulesPaginated*) printf '[]\\n0x%040d\\n' 1 ;;
      *getOwners*) printf '[0x%040d]\\n' 1 ;;
      *\\(address\\)) printf '0x%040d\\n' 1 ;;
      *\\(bool\\)) echo true ;;
      *\\(string\\)) echo '"version"' ;;
      *) echo 1 ;;
    esac ;;
  esac
}
xread local > "$OUT/$CASE-$VERSION-values.txt"
echo "XBAD=$XBAD"
[ "$XBAD" -eq 0 ]
'''
elif case == 'sp-getter-type':
    body = between('sp_getter() {', 'state_ok() {')
    body += '''cast() { echo 0x1234; }
sp_getter "$OUT/$CASE-$VERSION-values.txt" 'owner()(address)' 100 0x0000000000000000000000000000000000000001 'owner()(address)'
'''
elif case == 'state-ok-type':
    body = between('state_ok() {', 'sp_state_checked() {')
    body += '''SP_STATE_N=24
sed 's/^owner()(address) = .*/owner()(address) = 0x1234/' "$SNAPSHOT" > "$OUT/$CASE-$VERSION-values.txt"
result=$(state_ok "$OUT/$CASE-$VERSION-values.txt")
echo "$result"
[ "$result" = valid ]
'''
elif case.startswith('stage-c-'):
    if case == 'stage-c-before': body = between('  SB=$(bn);', '  safe_exec "C $T execute')
    else: body = between('  SA=$(bn);', '  check "C $T op done')
    body = '''T=SP; PROXY=0x0000000000000000000000000000000000000001; NEND=3
bn() { echo 100; }
cast() { if [ "$3" = 1 ]; then echo 'injected storage failure' >&2; return 1; fi; printf '0x%064d\\n' 0; }
''' + body + '''echo "FAILURES=$FAILURES"; [ "$FAILURES" -eq 0 ]
'''
elif case == 'dummy-jq':
    a = 'DUMMY_RUNTIME=$(' if any(line.startswith('DUMMY_RUNTIME=$(') for line in source) else 'check "D0 dummy runtime keccak !='
    body = between(a, 'check "D0 dummy runtime <=')
    body = '''printf '{"rc2SuperPaymaster":{"attestedRuntimeKeccak":"0x%064d"}}\\n' 1 > "$OUT/D-dummy-artifact.json"
''' + body + '''echo "FAILURES=$FAILURES"; [ "$FAILURES" -eq 0 ]
'''
elif case in ('rb-type', 'subshell-rv'):
    body = between('rv() {', '# rbs ' if case == 'rb-type' else '# rb ') if case == 'rb-type' else between('rv() {', '# rb ')
    body += '''cast() { if [ "$1" = block-number ]; then echo 100; else echo 0x1234; fi; }
'''
    if case == 'rb-type':
        body += '''result=$(rb 'owner' 0x0000000000000000000000000000000000000001 'owner()(address)')
'''
    else:
        body += '''result=$(rv address 'injected subshell read' - cast call 0x0000000000000000000000000000000000000001 'owner()(address)')
'''
    body += verdict()
elif case == 'missing-log':
    body = '''rm -f "$OUT/rehearsal.log"
''' + verdict()
elif case == 'endpoint-url':
    body = '''RPC_URL_X=RPC-ENDPOINT-SENTINEL
printf 'x=y\\n' > "$OUT/0-prestate-endpointA.txt"
cp "$OUT/0-prestate-endpointA.txt" "$OUT/0-prestate-endpointB.txt"
FORK_BLOCK=100
''' + between('{ echo "# endpoint A', '# Fail-closed: EACH') + '''grep -q 'RPC-ENDPOINT-SENTINEL' "$OUT/0-prestate-crosscheck.log"
'''
elif case == 'redaction-publicnode':
    start = '    sed -i' if any(line.startswith('    sed -i') for line in source) else '    python3 - "$D"'
    body = '''D="$OUT/redaction"; mkdir -p "$D"
printf 'endpoint https://publicnode.example/rpc\\n' > "$D/console.log"
''' + between(start, '    echo "$inj') + '''grep -q 'https://publicnode.example/rpc' "$D/console.log"
result=$?
rm -f "$D/console.log"
exit "$result"
'''
else:
    body = between('LEDGER_BLOCKS=0', 'check "ledger walked')
    fault = '[]' if case == 'ledger-list' else '["0x' + '1'*64 + '"]'
    count = '0x2' if case == 'ledger-count' else '0x1'
    status = '"unknown"' if case == 'ledger-status' else '"0x1"'
    tx = '{"hash":"0x' + '1'*64 + '","from":"' + ('0x1234' if case == 'ledger-from' else '0x' + '2'*40) + '","to":null,"input":"0x","blockNumber":"0x65"}'
    body = f'''FORK_BLOCK=100; HEADB=101
cast() {{
  case "$1" in
    block) echo '{{"transactions":{fault}}}' ;;
    rpc) echo {count} ;;
    receipt) echo '{{"status":{status},"contractAddress":null}}' ;;
    tx) ''' + ("echo 'injected tx failure' >&2; return 1" if case == 'ledger-tx' else f"echo '{tx}'") + ''' ;;
  esac
}
''' + body + '''echo "FAILURES=$FAILURES"; [ "$FAILURES" -eq 0 ]
'''
target.write_text(prefix + f'CASE={case!r}; VERSION={sys.argv[1].split("-")[-1]!r}\n' + body)
PY
    SNAPSHOT="docs/design/aoa-balance-mode/data/d5b/a2-failclosed-reads-11884320-045a8962/D5-state-before.txt" bash "$OUT/.run-$version.sh" > "$OUT/$case_name-$version.log" 2>&1
    rc=$?
    if [ "$version" = old ]; then old_rc=$rc; else new_rc=$rc; fi
  done
  printf '%s\t%s\t%s\n' "$case_name" "$old_rc" "$new_rc" >> "$OUT/negctl-table.tsv"
done
rm -f "$OUT/.source-old" "$OUT/.source-new" "$OUT/.run-old.sh" "$OUT/.run-new.sh"
awk -F '\t' 'NR>1 { if ($1=="rb-type" || $1=="subshell-rv") expected=($2!=0 && $3!=0); else expected=($2==0 && $3!=0); if (!expected) {bad=1; print "UNEXPECTED: "$0} } END {exit bad}' "$OUT/negctl-table.tsv"
