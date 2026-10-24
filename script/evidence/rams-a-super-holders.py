#!/usr/bin/env python3
"""H1b residual: enumerate every live ROLE_PAYMASTER_SUPER holder and its SuperPaymaster state at the pinned block.

The Registry freeze (configureRole isActive=false) blocks NEW grants only. A holder that already has the role but
is not yet a configured, paused SP operator could still configureOperator during the pre-upgrade gap. This scan
answers whether any such holder exists at FORK_BLOCK.

Method (read-only):
  1. eth_getLogs RoleRegistered(bytes32 indexed roleId, address indexed user, uint256, uint256) on the Registry,
     topic1 = keccak256("PAYMASTER_SUPER"), from the Registry creation block to FORK_BLOCK (binary-searched via
     eth_getCode, with a creation positive control).
  2. Completeness: the number of scanned users with hasRole == true must equal getRoleUserCount(SUPER). In
     Registry-5.8.0 `roleMembers` is pushed only in _firstTimeRegister (which also sets hasRole and emits
     RoleRegistered) and popped only on exit, so equality means no holder is missing.
  3. Positive control: the two known configured operators (OWNER, ANNI) must be among the holders.
  4. For each holder: SP operators(holder) words 1..2 = isConfigured, isPaused; plus the other two configureOperator
     preconditions (COMMUNITY role, factory getTokenAddress(holder) != 0). Positive control for those: the known
     configured operators must show both.
Usage: RPC_FILE=<file holding the archive URL> FORK_BLOCK=11974561 python3 rams-a-super-holders.py <out.json>
"""
import json, os, sys, urllib.request

if not os.environ.get("RPC_FILE"):
    print("RPC_FILE is not set: point it at a file holding the archive RPC URL (the URL is never printed)", file=sys.stderr); sys.exit(2)
try:
    url = open(os.environ["RPC_FILE"]).read().strip()
except OSError as e:
    print(f"cannot read RPC_FILE ({type(e).__name__}); the URL is never printed", file=sys.stderr); sys.exit(2)
if not url:
    print("RPC_FILE is empty", file=sys.stderr); sys.exit(2)
fork = int(os.environ.get("FORK_BLOCK", "11974561"))
REG = "0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71"
SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9"
SUPER = "0x2024516755f401845808190bb830b0e4523d0df0845503cab52130a794699a0f"  # keccak256("PAYMASTER_SUPER")
KNOWN = {"0xb5600060e6de5e11d3636731964218e53caadf0e", "0xecaacb915f7d92e9916f449f7ad42bd0408733c9"}


def rpc(m, p):
    q = json.dumps({"jsonrpc": "2.0", "id": 1, "method": m, "params": p}).encode()
    r = json.loads(urllib.request.urlopen(urllib.request.Request(url, q, {"Content-Type": "application/json"}), timeout=90).read())
    if "error" in r:
        raise RuntimeError(f"{m}: {r['error'].get('code')}")
    return r["result"]


def keccak_sig(sig):  # selector/topic via the node, so no local keccak dependency
    return rpc("web3_sha3", ["0x" + sig.encode().hex()])


def call(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, hex(fork)])


def word(addr):
    return addr.lower().removeprefix("0x").rjust(64, "0")


topic0 = keccak_sig("RoleRegistered(bytes32,address,uint256,uint256)")
assert keccak_sig("PAYMASTER_SUPER") == SUPER, "role id mismatch"
lo, hi = 0, fork
while lo < hi:  # first block where the Registry has code
    mid = (lo + hi) // 2
    if rpc("eth_getCode", [REG, hex(mid)]) == "0x":
        lo = mid + 1
    else:
        hi = mid
created = lo
assert rpc("eth_getCode", [REG, hex(created - 1)]) == "0x" and rpc("eth_getCode", [REG, hex(created)]) != "0x"
logs = []
for a in range(created, fork + 1, 2000):
    logs += rpc("eth_getLogs", [{"address": REG, "topics": [topic0, SUPER], "fromBlock": hex(a), "toBlock": hex(min(a + 1999, fork))}])
users = sorted({"0x" + l["topics"][2][-40:] for l in logs})
has_sel = keccak_sig("hasRole(bytes32,address)")[:10]
cnt_sel = keccak_sig("getRoleUserCount(bytes32)")[:10]
op_sel = keccak_sig("operators(address)")[:10]
count = int(call(REG, cnt_sel + SUPER[2:]), 16)
COMMUNITY = keccak_sig("COMMUNITY")
factory = "0x" + call(SP, keccak_sig("xpntsFactory()")[:10])[-40:]
tok_sel = keccak_sig("getTokenAddress(address)")[:10]
assert int(factory, 16) != 0, "SP xpntsFactory unset"
holders = []
for u in users:
    if int(call(REG, has_sel + SUPER[2:] + word(u)), 16) != 1:
        continue
    raw = call(SP, op_sel + word(u))[2:]
    w = [int(raw[i:i + 64], 16) for i in range(0, 192, 64)]
    # configureOperator (5.4.2) also needs COMMUNITY and a factory-issued xPNTs token for msg.sender.
    community = int(call(REG, has_sel + COMMUNITY[2:] + word(u)), 16) == 1
    token = "0x" + call(factory, tok_sel + word(u))[-40:]
    holders.append({"holder": u, "isConfigured": bool(w[1]), "isPaused": bool(w[2]), "hasCommunity": community,
                    "factoryToken": token, "configurableWithoutNewToken": (not w[1]) and community and int(token, 16) != 0})
res = {"registry": REG, "sp": SP, "forkBlock": fork, "registryCreationBlock": created, "roleId": SUPER, "topic0": topic0,
       "roleRegisteredLogs": len(logs), "distinctUsers": len(users), "getRoleUserCount": count,
       "holdersAtFork": len(holders), "complete": len(holders) == count,
       "knownOperatorsPresent": KNOWN <= {h["holder"] for h in holders},
       "xpntsFactory": factory, "unconfigured": [h["holder"] for h in holders if not h["isConfigured"]],
       "configurableWithoutNewToken": [h["holder"] for h in holders if h["configurableWithoutNewToken"]],
       "note": "deployxPNTsToken (factory 2.3.0) only requires COMMUNITY, so an unconfigured holder with COMMUNITY "
               "can self-activate (deploy token, then configureOperator) without any permission; an empty "
               "configurableWithoutNewToken does NOT mean the holder is inert.",
       "holders": holders}
json.dump(res, open(sys.argv[1], "w"), indent=1)
print(json.dumps({k: res[k] for k in ("roleRegisteredLogs", "distinctUsers", "getRoleUserCount", "holdersAtFork", "complete", "knownOperatorsPresent", "unconfigured", "configurableWithoutNewToken")}))
known_ok = all(h["hasCommunity"] and int(h["factoryToken"], 16) != 0 for h in holders if h["holder"] in KNOWN)
res["knownOperatorsPreconditionsControl"] = known_ok
json.dump(res, open(sys.argv[1], "w"), indent=1)
print("known-operator precondition control:", known_ok)
sys.exit(0 if res["complete"] and res["knownOperatorsPresent"] and known_ok else 1)
