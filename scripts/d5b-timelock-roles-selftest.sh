#!/usr/bin/env bash
# =============================================================================
# Self-test of script/governance/check-timelock-roles.mjs (an OPERATOR check, not a security boundary) on LOCAL anvils (no public RPC; anvil's public
# dev accounts via --unlocked / impersonation; no private key is passed or printed). Every FAIL step also
# names the problem line it must produce (so a FAIL for the wrong reason does not count), and every step
# checks the attestation the checker wrote (--attest): result PASS iff the check passed.
#   A  role history      1 correct M1 timelock == manifest                         -> PASS
#                        2 unlisted DEFAULT_ADMIN granted / 3 revoked               -> FAIL / PASS
#                        4 PROPOSER to an unlisted address / 5 revoked              -> FAIL / PASS
#                        6 EXECUTOR to a mustHoldNothing account / 7 revoked         -> FAIL / PASS
#                        8 manifest deploymentBlock wrong (depth probe)             -> FAIL
#   B  chain (M1)        manifest chainId != primary chain                          -> FAIL
#                        --rpc2 is a different chain (second anvil, chain id 31338) -> FAIL
#   C  rpc2 (M2)         --rpc2 = anvil fork of the primary AT the head             -> PASS (control)
#                        --rpc2 = anvil fork one block BEHIND the head (lagging)    -> FAIL
#                        --rpc2 = faithful proxy (control) / drops a log / rewrites -> PASS / FAIL / FAIL
#                                 the indexed sender (payload mismatch)
#   D  ctor control (M2) timelock whose P/C/E grants come AFTER the deployment block -> FAIL (holders,
#                        depth probe and hasRole all agree: only the deploy-block control catches it)
#   E  manifest (M3)     each required field missing, empty role set, empty / duplicate / zero
#                        mustHoldNothing, label count / empty label, the committed example
#                        (placeholder) -> FAIL; the example minus `_placeholder` fails ONLY on its chain
#   E2 integers (M2')    chainId / deploymentBlock as a bare number, > 2^53, hex string, leading zero,
#                        1.0, > uint64, "" -> FAIL each; "0" deploymentBlock -> FAIL
#   E3 structure (L2')   .roles null / number / string / array, a role value that is not an array, the
#                        whole manifest an array / null -> FAIL, never an uncaught crash
#   E4 canonical (48cba3bd) the manifest bytes must equal the checker's canonical serialization: an
#                        escaped key, an escaped value, a duplicate key, an escaped root key + nested
#                        literal decoy, reordered keys, trailing spaces, CRLF, a BOM, no final newline ->
#                        FAIL each; the reordered file after --canonicalize -> PASS (control)
#   From step 2 on, every step's --attest path first holds step 1's genuine PASS: each FAIL step also
#   proves a failing run replaces an earlier PASS.
#   F  exit 2            --chunk 0 / -5 / 1.5 / abc / missing value, unreadable manifest, missing --rpc,
#                        unreachable endpoint -> exit 2, and the PASS already at the --attest path is
#                        replaced by a FAIL naming the reason; --chunk 1 -> PASS (control)
# Usage: scripts/d5b-timelock-roles-selftest.sh <workDir>   (plain `forge build` first)
# =============================================================================
set -euo pipefail
W="$1"; mkdir -p "$W"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
ANVIL="${ANVIL:-$HOME/.foundry/bin/anvil}"; CAST="${CAST:-$HOME/.foundry/bin/cast}"
PORT="${PORT:-18792}"; RPC="http://127.0.0.1:$PORT"
P2=$((PORT + 1)); PP=$((PORT + 3))
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266     # anvil #0: deployer / old owner (mustHoldNothing)
SAFE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8      # anvil #1: the governance Safe
X=0x00000000000000000000000000000000000AD111         # an address the manifest does not name
# CHECK / KEEP_GOING exist for the pre-fix column only: CHECK=<wrapper around an older checker>
# KEEP_GOING=1 records every step that does not behave as required instead of stopping at the first.
CHECK="${CHECK:-node script/governance/check-timelock-roles.mjs}"
KEEP_GOING="${KEEP_GOING:-0}"; BAD=0
bad() { echo "SELF-TEST FAILED at step $n: $*"; BAD=$((BAD+1)); [ "$KEEP_GOING" = 1 ] || exit 1; }

PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
wait_rpc() { for _ in $(seq 1 150); do "$CAST" chain-id --rpc-url "$1" >/dev/null 2>&1 && return 0; sleep 0.2; done; echo "endpoint $1 did not come up"; exit 2; }
start_anvil() { # <port> <log> [args...]  -> records its PID
  local port="$1" log="$2"; shift 2
  "$ANVIL" --port "$port" "$@" >"$log" 2>&1 &
  PIDS+=("$!"); echo "$!" >>"$W/pids"
  wait_rpc "http://127.0.0.1:$port"
}
stop_last() { local p="${PIDS[${#PIDS[@]}-1]}"; kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; unset 'PIDS[${#PIDS[@]}-1]'; }

: >"$W/pids"
start_anvil "$PORT" "$W/anvil.log" --chain-id 31337

art() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['bytecode']['object'])" "$1"; }
TL_CODE=$(art "$(ls out/TimelockController.sol/TimelockController*.json | head -1)")
deploy_tl() { # <proposers> <executors> -> "addr block"
  local R
  R=$("$CAST" send --rpc-url "$RPC" --unlocked --from "$OWNER" --create \
    "$TL_CODE$("$CAST" abi-encode "c(uint256,address[],address[],address)" 172800 "$1" "$2" 0x0000000000000000000000000000000000000000 | sed 's/^0x//')" --json)
  echo "$R" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['contractAddress'], int(d['blockNumber'],16))"
}
read -r TL BLK <<<"$(deploy_tl "[$SAFE]" "[$SAFE]")"
manifest() { # <timelock> <deploymentBlock> <out> [chainId]
  printf '{\n  "network": "anvil-selftest",\n  "chainId": "%s",\n  "timelock": "%s",\n  "deploymentBlock": "%s",\n  "roles": {\n    "DEFAULT_ADMIN_ROLE": ["%s"],\n    "PROPOSER_ROLE": ["%s"],\n    "CANCELLER_ROLE": ["%s"],\n    "EXECUTOR_ROLE": ["%s"]\n  },\n  "mustHoldNothing": ["%s"],\n  "mustHoldNothingLabels": ["deployer/old owner"]\n}\n' \
    "${4:-31337}" "$1" "$2" "$1" "$SAFE" "$SAFE" "$SAFE" "$OWNER" >"$3.draft"
  node script/governance/check-timelock-roles.mjs --canonicalize "$3.draft" >"$3"; rm -f "$3.draft"
}
M="$W/manifest.json"
manifest "$TL" "$BLK" "$M"
impersonate() { "$CAST" rpc anvil_impersonateAccount "$1" --rpc-url "$RPC" >/dev/null; "$CAST" rpc anvil_setBalance "$1" 0xDE0B6B3A7640000 --rpc-url "$RPC" >/dev/null; }
impersonate "$TL"
asTL() { "$CAST" send --rpc-url "$RPC" --unlocked --from "$TL" "$TL" "$@" >/dev/null; }
ADMIN=0x0000000000000000000000000000000000000000000000000000000000000000
PROP=$("$CAST" keccak PROPOSER_ROLE); CANC=$("$CAST" keccak CANCELLER_ROLE); EXEC=$("$CAST" keccak EXECUTOR_ROLE)

n=0
expect() { # <0|1> <label> <required log substring or -> [extra checker args...]
  local want_rc="$1" label="$2" needle="$3"; shift 3
  n=$((n+1)); rm -f "$W/att$n.json"
  # from step 2 on, the --attest path first holds step 1's genuine PASS: every FAIL step thereby also
  # shows that a failing run REPLACES an earlier PASS (Codex re-checks of 626b6ea8 / 7ca43549, Low)
  if [ "$n" -gt 1 ] && [ -f "$W/att1.json" ]; then cp "$W/att1.json" "$W/att$n.json"; fi
  set +e; $CHECK --rpc "$RPC" --manifest "$M" --out "$W/step$n.json" --attest "$W/att$n.json" "$@" >"$W/step$n.log" 2>&1; local rc=$?; set -e
  local res; res=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['result'])" "$W/att$n.json" 2>/dev/null || echo none)
  local want; want=$([ "$want_rc" = 0 ] && echo PASS || echo FAIL)
  if [ "$rc" != "$want_rc" ]; then [ "$KEEP_GOING" = 1 ] || cat "$W/step$n.log"; bad "$label (exit $rc, expected $want_rc)"; return 0; fi
  if [ "$res" != "$want" ]; then bad "$label: attestation result $res, expected $want"; return 0; fi
  if [ "$needle" != "-" ] && ! grep -qF -- "$needle" "$W/step$n.log"; then [ "$KEEP_GOING" = 1 ] || cat "$W/step$n.log"; bad "$label — failed, but not with \"$needle\""; return 0; fi
  if [ "$needle" = "-" ]; then echo "  step $n ok: $label (exit $rc)"; else echo "  step $n ok: $label (exit $rc; \"$needle\")"; fi
}

echo "== A: role history (timelock $TL deployed in block $BLK)"
expect 0 "correct M1 timelock == manifest" -
asTL "grantRole(bytes32,address)" "$ADMIN" "$X";    expect 1 "unlisted DEFAULT_ADMIN granted" "DEFAULT_ADMIN_ROLE: history holders"
asTL "revokeRole(bytes32,address)" "$ADMIN" "$X";   expect 0 "unlisted admin revoked" -
asTL "grantRole(bytes32,address)" "$PROP" "$X";     expect 1 "PROPOSER granted to an address not in the manifest" "PROPOSER_ROLE: history holders"
asTL "revokeRole(bytes32,address)" "$PROP" "$X";    expect 0 "that proposer revoked" -
asTL "grantRole(bytes32,address)" "$EXEC" "$OWNER"; expect 1 "EXECUTOR granted to a mustHoldNothing account (old owner)" "mustHoldNothing account"
asTL "revokeRole(bytes32,address)" "$EXEC" "$OWNER"; expect 0 "that executor revoked" -
manifest "$TL" "$((BLK + 3))" "$M";                 expect 1 "manifest deploymentBlock wrong" "depth probe failed"
manifest "$TL" "$BLK" "$M"

echo "== B: chain id (Codex re-check M1)"
manifest "$TL" "$BLK" "$M" 31338;                   expect 1 "manifest chainId 31338 vs primary 31337" "chain mismatch: --rpc chainId 31337 != manifest chainId 31338"
manifest "$TL" "$BLK" "$M"
start_anvil "$P2" "$W/anvil-other-chain.log" --chain-id 31338
expect 1 "--rpc2 on another chain (31338)" "chain mismatch: --rpc2 chainId 31338" --rpc2 "http://127.0.0.1:$P2"
stop_last

echo "== C: second endpoint pinned to the same head (Codex re-check M2)"
HEAD=$("$CAST" block-number --rpc-url "$RPC")
start_anvil "$P2" "$W/anvil-fork-head.log" --fork-url "$RPC" --fork-block-number "$HEAD"
expect 0 "--rpc2 = fork of the primary at the head (control)" "served the same head" --rpc2 "http://127.0.0.1:$P2"
stop_last
start_anvil "$P2" "$W/anvil-fork-lag.log" --fork-url "$RPC" --fork-block-number "$((HEAD - 1))"
expect 1 "--rpc2 lagging one block" "lagging endpoint" --rpc2 "http://127.0.0.1:$P2"
stop_last
proxy() { node scripts/d5b-rpc-tamper-proxy.mjs "$PP" "$RPC" "$1" >"$W/proxy-$1.log" 2>&1 & PIDS+=("$!"); echo "$!" >>"$W/pids"; wait_rpc "http://127.0.0.1:$PP"; }
proxy pass;   expect 0 "--rpc2 = faithful proxy (control)" "served the same head" --rpc2 "http://127.0.0.1:$PP"; stop_last
proxy drop;   expect 1 "--rpc2 drops a role log (payload)" "returned a different role-log list" --rpc2 "http://127.0.0.1:$PP"; stop_last
proxy sender; expect 1 "--rpc2 rewrites the indexed sender (payload; not in the old blockNumber:logIndex:txHash key)" "returned a different role-log list" --rpc2 "http://127.0.0.1:$PP"; stop_last

echo "== D: constructor control restricted to the deployment block (Codex re-check M2)"
read -r TL2 BLK2 <<<"$(deploy_tl "[]" "[]")"
impersonate "$TL2"
for R in "$PROP" "$CANC" "$EXEC"; do "$CAST" send --rpc-url "$RPC" --unlocked --from "$TL2" "$TL2" "grantRole(bytes32,address)" "$R" "$SAFE" >/dev/null; done
M_SAVE="$M"; M="$W/manifest-late.json"; manifest "$TL2" "$BLK2" "$M"
expect 1 "P/C/E granted after the deployment block (holders == manifest, hasRole agrees)" "positive control failed: constructor grant PROPOSER_ROLE"
python3 -c "import json,sys;d=json.load(open(sys.argv[1]));assert d['holders']['PROPOSER_ROLE']==[sys.argv[2]] and not [p for p in d['problems'] if 'history holders' in p or 'depth' in p or 'cross-check' in p], d['problems']" "$W/step$n.json" "$SAFE" \
  || bad "the late-grant timelock tripped a check other than the deploy-block control"
echo "    (only the deploy-block control fired: holders == manifest, depth probe and hasRole clean)"
M="$M_SAVE"

echo "== E: vacuous / incomplete manifest (Codex re-check M3)"
mut() { # <op> -> writes $W/manifest-mut.json from the good manifest
  python3 - "$M_SAVE" "$W/manifest-mut.json" "$1" <<'PY'
import json, sys
src, dst, op = sys.argv[1:4]
d = json.load(open(src))
kind, _, arg = op.partition(":")
if kind == "del":
    if arg.startswith("roles."): del d["roles"][arg[6:]]
    else: del d[arg]
elif kind == "emptyrole": d["roles"][arg] = []
elif kind == "mhn-empty": d["mustHoldNothing"] = []; d["mustHoldNothingLabels"] = []
elif kind == "mhn-dup": d["mustHoldNothing"] = [d["mustHoldNothing"][0]] * 2; d["mustHoldNothingLabels"] = ["a", "b"]
elif kind == "mhn-zero": d["mustHoldNothing"] = ["0x" + "0" * 40]
elif kind == "labels-count": d["mustHoldNothingLabels"] = []
elif kind == "label-empty": d["mustHoldNothingLabels"] = [" "]
elif kind == "set":  # set:<key or roles.KEY>=<raw JSON value>
    path, _, raw = arg.partition("=")
    val = json.loads(raw)
    if path.startswith("roles."): d["roles"][path[6:]] = val
    else: d[path] = val
elif kind == "whole":  # the whole manifest replaced by a raw JSON value
    d = json.loads(arg)
else: raise SystemExit("unknown op " + op)
json.dump(d, open(dst, "w"), indent=2)
PY
}
M="$W/manifest-mut.json"
for f in network chainId timelock deploymentBlock roles.DEFAULT_ADMIN_ROLE roles.PROPOSER_ROLE roles.CANCELLER_ROLE roles.EXECUTOR_ROLE mustHoldNothing mustHoldNothingLabels; do
  mut "del:$f"; expect 1 "manifest without .$f" "manifest: missing field .$f"
done
mut "emptyrole:EXECUTOR_ROLE"; expect 1 "empty EXECUTOR_ROLE set" "manifest: .roles.EXECUTOR_ROLE must be a non-empty array"
mut "mhn-empty";    expect 1 "empty mustHoldNothing" "manifest: .mustHoldNothing must be a non-empty array"
mut "mhn-dup";      expect 1 "duplicate mustHoldNothing" "manifest: duplicate address in .mustHoldNothing"
mut "mhn-zero";     expect 1 "zero address in mustHoldNothing" "manifest .mustHoldNothing[0]: zero address"
mut "labels-count"; expect 1 "no label for a mustHoldNothing account" "manifest: .mustHoldNothingLabels must have exactly one label"
mut "label-empty";  expect 1 "blank label" "manifest: .mustHoldNothingLabels[0] must be a non-empty string"
echo "== E2: ONE canonical integer form for chainId / deploymentBlock (Codex re-check of 7ca43549, M2)"
# canonical = a JSON string of decimal digits, no leading zeros, <= uint64; every step above used it (control)
for k in chainId deploymentBlock; do
  for raw in '31337' '9007199254740993' '"0x7a69"' '"031337"' '1.0' '"18446744073709551616"' '""'; do
    mut "set:$k=$raw"; expect 1 ".$k = $raw" "manifest: .$k must be a decimal string (no leading zeros, <= uint64)"
  done
done
mut 'set:deploymentBlock="0"'; expect 1 '.deploymentBlock = "0" (canonical but not positive)' "manifest: .deploymentBlock must be > 0"
echo "== E3: malformed structure never crashes past the attestation (Codex re-check of 7ca43549, L2)"
for raw in 'null' '5' '"x"' '[]'; do
  mut "set:roles=$raw"; expect 1 ".roles = $raw (replaces the earlier PASS)" "manifest: .roles must be an object"
done
mut 'set:roles.PROPOSER_ROLE="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"'; expect 1 "a role value that is a string, not an array" "manifest: .roles.PROPOSER_ROLE must be a non-empty array"
mut 'set:roles.EXECUTOR_ROLE={}'; expect 1 "a role value that is an object, not an array" "manifest: .roles.EXECUTOR_ROLE must be a non-empty array"
mut 'whole:[1,2]'; expect 1 "the manifest is a JSON array" "manifest: must be a JSON object"
mut 'whole:null'; expect 1 "the manifest is JSON null" "manifest: must be a JSON object"
echo "== E4: canonical byte form, enforced by the checker only (Codex re-check of 48cba3bd)"
rawmut() { # <op> -> $W/manifest-raw.json from the canonical base manifest's TEXT
  python3 - "$M_SAVE" "$W/manifest-raw.json" "$1" <<'PY'
import sys
src, dst, op = sys.argv[1:4]
t = open(src, "rb").read().decode("utf-8")
assert t.endswith("}\n")
if op == "esc-key": t = t.replace('"chainId"', '"\\u0063hainId"', 1)
elif op == "esc-value": t = t.replace('"anvil-selftest"', '"\\u0061nvil-selftest"', 1)
elif op == "dup-key": t = t.replace('{\n', '{\n  "network": "decoy",\n', 1)
elif op == "nested-decoy":  # the 48cba3bd attack: escaped ROOT key with a non-canonical value + a nested literal key
    i = t.index('  "chainId": ')
    j = t.index("\n", i)
    t = t[:i] + '  "\\u0063hainId": "0x7a69",\n  "_x": {"chainId": "31337"},' + t[j:]
elif op == "reorder":
    lines = t.split("\n")
    a = next(k for k, l in enumerate(lines) if l.startswith('  "network"'))
    b = next(k for k, l in enumerate(lines) if l.startswith('  "chainId"'))
    lines[a], lines[b] = lines[b], lines[a]
    t = "\n".join(lines)
elif op == "trailing-space": t = t.replace(",\n", ",  \n", 1)
elif op == "crlf": t = t.replace("\n", "\r\n")
elif op == "bom": t = "﻿" + t
elif op == "no-final-newline": t = t[:-1]
else: raise SystemExit("unknown op " + op)
open(dst, "wb").write(t.encode("utf-8"))
PY
}
M="$W/manifest-raw.json"
for op in esc-key esc-value dup-key nested-decoy reorder trailing-space crlf bom no-final-newline; do
  rawmut "$op"; expect 1 "non-canonical bytes: $op" "manifest: bytes are not the canonical serialization"
done
python3 -c "import json,sys;assert json.load(open(sys.argv[1], encoding='utf-8-sig'))" "$W/manifest-raw.json" || bad "the BOM variant is not otherwise valid JSON"
rawmut reorder; $CHECK --canonicalize "$W/manifest-raw.json" >"$W/manifest-fixed.json" || bad "--canonicalize failed"
cmp -s "$W/manifest-fixed.json" "$M_SAVE" || bad "--canonicalize of the reordered file != the canonical manifest"
M="$W/manifest-fixed.json"; expect 0 "the reordered file after --canonicalize (control: the helper produces an accepted file)" -
M="$M_SAVE"
M="deployments/timelock-roles.example.json"; expect 1 "the committed example (FAKE placeholders)" "manifest: \`_placeholder\` is set"
python3 -c "import json,sys;d=json.load(open(sys.argv[1]));d.pop('_placeholder');json.dump(d,open(sys.argv[2],'w'))" deployments/timelock-roles.example.json "$W/example-unflagged.draft.json"
node script/governance/check-timelock-roles.mjs --canonicalize "$W/example-unflagged.draft.json" >"$W/example-unflagged.json"
M="$W/example-unflagged.json"; expect 1 "the example minus _placeholder: complete schema, fails only on its chain" "chain mismatch: --rpc chainId 31337 != manifest chainId 11155111"
if grep -q "manifest:" "$W/step$n.log"; then bad "the example has a schema problem"; fi
M="$M_SAVE"

echo "== F: exit-2 paths replace an earlier PASS (--chunk: Codex re-check L2 of ed2a4762; overwrite: Low of 626b6ea8)"
# every exit-2 run below targets an --attest path that already holds a genuine PASS (step 1's attestation)
python3 -c "import json,sys;assert json.load(open(sys.argv[1]))['result']=='PASS'" "$W/att1.json" || bad "precondition: step 1 attestation is not a PASS"
exit2() { # <label> <checker args...>: seeded PASS at $W/att$n.json must become FAIL with the reason, exit 2
  local label="$1"; shift
  n=$((n+1)); cp "$W/att1.json" "$W/att$n.json"
  set +e; $CHECK "$@" >"$W/step$n.log" 2>&1; local rc=$?; set -e
  local res; res=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['result'], '|'.join(d['problems']))" "$W/att$n.json" 2>/dev/null || echo "none")
  if [ "$rc" != 2 ] || [ "${res%% *}" != FAIL ]; then bad "$label (exit $rc, attestation now: $res)"; return 0; fi
  echo "  step $n ok: $label -> exit 2, the earlier PASS at that path is now FAIL (${res#* })"
}
for c in 0 -5 1.5 abc; do
  exit2 "--chunk '$c'" --rpc "$RPC" --manifest "$M" --attest "$W/att$((n+1)).json" --chunk "$c"
done
exit2 "--chunk without a value" --rpc "$RPC" --manifest "$M" --attest "$W/att$((n+1)).json" --chunk
exit2 "manifest file unreadable" --rpc "$RPC" --manifest "$W/no-such-manifest.json" --attest "$W/att$((n+1)).json"
exit2 "--rpc missing" --manifest "$M" --attest "$W/att$((n+1)).json"
exit2 "endpoint unreachable (infrastructure error)" --rpc "http://127.0.0.1:1" --manifest "$M" --attest "$W/att$((n+1)).json"
expect 0 "--chunk 1 (smallest valid; control)" - --chunk 1

if [ "$BAD" != 0 ]; then echo "TIMELOCK ROLE CHECKER SELF-TEST FAILED: $BAD of $n steps"; exit 1; fi
echo "TIMELOCK ROLE CHECKER SELF-TEST OK ($n steps)"
