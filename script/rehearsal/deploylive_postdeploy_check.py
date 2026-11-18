#!/usr/bin/env python3
"""Read-only post-deploy check of a DeployLive-built system against the rc.8 owner-table expectations.

Usage: postdeploy_check.py <rpc> <config.json> <deployer> <safe>
Prints one PASS/FAIL line per assertion and a summary. Nothing is sent: eth_call only.
"""
import json
import subprocess
import sys
import re

RPC, CFG, DEPLOYER, SAFE = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3].lower(), sys.argv[4].lower()
results = []


LOCAL = {"keccak", "calldata", "sig", "abi-encode"}


def cast(*args):
    cmd = ["cast", *args] + ([] if args[0] in LOCAL else ["--rpc-url", RPC])
    r = subprocess.run(cmd, capture_output=True, text=True)
    # Never expose RPC URLs, including transport errors with credentials or query strings.
    if r.returncode:
        return r.returncode, " ".join(re.findall(r"0x[0-9a-fA-F]+", r.stderr)) or "RPC/local command failed"
    return r.returncode, r.stdout.strip()


def raw_call(frm, to, data):
    q = json.dumps({"from": frm, "to": to, "data": data})
    return cast("rpc", "eth_call", q, "latest")


def call(addr, sig, *args):
    rc, out = cast("call", addr, sig, *map(str, args))
    return out if rc == 0 and out else f"<revert: {out[:120]}>"


def check(name, ok, detail):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name} :: {detail}")


A = {k: v for k, v in CFG.items() if isinstance(v, str) and v.startswith("0x") and len(v) == 42}
agg, dvt, reg, sp, stk = A["blsAggregator"], A["dvtValidator"], A["registry"], A["superPaymaster"], A["staking"]
TL = A["timelockController"]

# 1. Owners: no system-internal contract may be owned by the deployer.
SYSTEM = ["superPaymaster", "registry", "staking", "gToken", "xPNTsFactoryV2", "aoaProtocolRegistry",
          "reputationSystem", "blsAggregator", "dvtValidator"]
LEGACY = ["xPNTsFactory", "paymasterFactory", "paymasterV4Impl", "microPaymentChannel", "x402Facilitator"]
for k in SYSTEM + LEGACY:
    o = call(A[k], "owner()(address)").lower()
    if k in SYSTEM:
        check(f"owner({k}) != deployer", o != DEPLOYER and not o.startswith("<"), o)
    else:
        print(f"INFO  owner({k}) [legacy, exception allowed] :: {o}")
for k in ("superPaymaster", "registry"):
    print(f"INFO  pendingOwner({k}) :: {call(A[k], 'pendingOwner()(address)')}")

# 2. Registry role owners.
T = "(uint256,uint256,uint32,uint32,uint32,uint32,uint16,bool,uint256,string,address)"
for r in ("COMMUNITY", "ENDUSER", "PAYMASTER_AOA", "PAYMASTER_SUPER", "DVT", "ANODE", "KMS"):
    rid = cast("keccak", r)[1]
    rc, raw = cast("call", reg, "getRoleConfig(bytes32)", rid)  # raw ABI: decode the static owner word
    words = [raw[2 + 64 * i: 2 + 64 * (i + 1)] for i in range((len(raw) - 2) // 64)]
    # word 0 = tuple offset; then minStake..minExitFee (9 words), string offset, owner
    owner = ("0x" + words[11][24:]).lower() if rc == 0 and len(words) > 11 else f"<undecodable {raw[:60]}>"
    check(f"roleConfigs[{r}].owner != deployer", not owner.startswith("<") and owner != DEPLOYER, owner)

# 3. Reputation sources.
check("isReputationSource(repSystem)", call(reg, "isReputationSource(address)(bool)", A["reputationSystem"]) == "true", "expected true")
check("isReputationSource(aggregator)", call(reg, "isReputationSource(address)(bool)", agg) == "true", "expected true")
check("isReputationSource(deployer) == false", call(reg, "isReputationSource(address)(bool)", DEPLOYER) == "false", "")

# 4. Non-owner privileges.
for name, addr, sig in (("SP.treasury", sp, "treasury()(address)"), ("staking.treasury", stk, "treasury()(address)"),
                        ("MySBT.daoMultisig", A["sbt"], "daoMultisig()(address)"),
                        ("aggregator.slashPolicyAdmin", agg, "slashPolicyAdmin()(address)"),
                        ("SP.guardian", sp, "guardian()(address)"),
                        ("PolicyRegistry.guardian", A["policyRegistry"], "guardian()(address)")):
    v = call(addr, sig).lower()
    check(f"{name} != deployer", v != DEPLOYER and not v.startswith("<"), v)
print(f"INFO  PolicyRegistry.timelock :: {call(A['policyRegistry'], 'timelock()(address)')}")
check("DVT.isValidator(deployer) == false", call(dvt, "isValidator(address)(bool)", DEPLOYER) == "false", "")

# 5. Timelock roles: the deployer holds none.
for role in ("PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE", "DEFAULT_ADMIN_ROLE"):
    h = call(TL, f"{role}()(bytes32)")
    check(f"TL.{role}(deployer) == false", call(TL, "hasRole(bytes32,address)(bool)", h, DEPLOYER) == "false", "")
    print(f"INFO  TL.{role}(safe) :: {call(TL, 'hasRole(bytes32,address)(bool)', h, SAFE)}")
print(f"INFO  TL.minDelay :: {call(TL, 'getMinDelay()(uint256)')}")

# 6. Slasher / verifier / aggregator invariants.
check("authorizedSlashers(aggregator) == false", call(stk, "authorizedSlashers(address)(bool)", agg) == "false", "")
check("fraudProofVerifier == 0", call(agg, "fraudProofVerifier()(address)").lower() == "0x" + "0" * 40, "")
for k in SYSTEM + LEGACY:
    o = call(A[k], "owner()(address)").lower()
    check(f"owner({k}) != aggregator", not o.startswith("<") and o != agg.lower(), o)
bal = cast("balance", agg)[1]
check("aggregator ETH balance == 0", bal == "0", bal)
for t in ("gToken", "aPNTs", "pnts"):
    b = "0" if A[t].lower() == "0x" + "0" * 40 else call(A[t], "balanceOf(address)(uint256)", agg).split()[0]
    check(f"aggregator {t} balance == 0", b == "0", b)
print(f"INFO  versions :: agg={call(agg, 'version()(string)')} dvt={call(dvt, 'version()(string)')} sp={call(sp, 'version()(string)')}")
for sig in ("minThreshold()(uint256)", "defaultThreshold()(uint256)"):
    print(f"INFO  agg.{sig.split('(')[0]} :: {call(agg, sig)}")

# 7. Generic-path denylist: the aggregator owner calling executeProposal with each blocked selector.
aggOwner = call(agg, "owner()(address)")
for sig, args in (("batchUpdateGlobalReputation(uint256,address[],uint256[],uint256,bytes)", ["1", "[]", "[]", "1", "0x01"]),
                  ("slash(address,uint256,string)", [DEPLOYER, "1", "x"]),
                  ("slashByDVT(address,bytes32,uint256,string)", [DEPLOYER, "0x" + "00" * 32, "1", "x"])):
    data = cast("calldata", sig, *args)[1]
    outer = cast("calldata", "executeProposal(uint256,address,bytes,uint256,bytes)", "1", reg, data, "3", "0x00")[1]
    rc, out = raw_call(aggOwner, agg, outer)
    sel = cast("sig", sig)[1]
    expect = cast("calldata", "ForbiddenGenericSelector(bytes4)", sel)[1]
    check(f"generic executeProposal({sig.split('(')[0]}) rejected with ForbiddenGenericSelector",
          rc != 0 and (expect[2:] in out or "ForbiddenGenericSelector" in out), out[:160])


# 8. Exact rc.8 end state. Expected input values are recorded by DeployLive in config.
ZERO = "0x" + "0" * 40
H = A.get("handoverBootstrap", ZERO)
EXPECTED_OWNERS = {k: TL for k in SYSTEM + LEGACY + ["aPNTs"]}
EXPECTED_OWNERS["gToken"] = SAFE
for k, expected in EXPECTED_OWNERS.items():
    actual = call(A[k], "owner()(address)").lower()
    check(f"owner({k}) == expected", actual == expected.lower(), f"expected {expected}; actual {actual}")
for k in ("registry", "superPaymaster", "aPNTs"):
    check(f"pendingOwner({k}) == 0", call(A[k], "pendingOwner()(address)").lower() == ZERO, "expected zero")
for r in ("COMMUNITY", "ENDUSER", "PAYMASTER_AOA", "PAYMASTER_SUPER", "DVT", "ANODE", "KMS"):
    rid = cast("keccak", r)[1]
    rc, raw = cast("call", reg, "getRoleConfig(bytes32)", rid)
    word = raw[2 + 64 * 11:2 + 64 * 12]
    check(f"roleConfigs[{r}].owner == timelock", rc == 0 and len(word) == 64 and ("0x" + word[24:]).lower() == TL.lower(), TL)
    check(f"deployer.hasRole({r}) == false", call(reg, "hasRole(bytes32,address)(bool)", rid, DEPLOYER) == "false", "false")
check("deployer Registry role list empty", call(reg, "getUserRoles(address)(bytes32[])", DEPLOYER) == "[]", "[]")
for name, addr, sig, expected in (
    ("SP.treasury", sp, "treasury()(address)", SAFE),
    ("staking.treasury", stk, "treasury()(address)", SAFE),
    ("MySBT.daoMultisig", A["sbt"], "daoMultisig()(address)", SAFE),
    ("aggregator.slashPolicyAdmin", agg, "slashPolicyAdmin()(address)", TL),
    ("SP.guardian", sp, "guardian()(address)", A.get("expectedSPGuardian", ZERO)),
    ("PolicyRegistry.guardian", A["policyRegistry"], "guardian()(address)", A.get("expectedGuardian", ZERO)),
    ("PolicyRegistry.timelock", A["policyRegistry"], "timelock()(address)", TL),
    ("SP.APNTS_TOKEN", sp, "APNTS_TOKEN()(address)", A["aPNTs"]),
    ("APNTsCapped.minter", A["aPNTs"], "minter()(address)", SAFE),
    ("APNTsCapped.capGuardian", A["aPNTs"], "capGuardian()(address)", SAFE),
    ("pmFactory.registry", A["paymasterFactory"], "registry()(address)", reg)):
    check(name + " == expected", expected.lower() not in (ZERO, DEPLOYER) and call(addr, sig).lower() == expected.lower(), expected)
for name, addr, sig, expected in (
    ("TL.minDelay", TL, "getMinDelay()(uint256)", 172800),
    ("APNTsCapped.cap", A["aPNTs"], "cap()(uint256)", CFG.get("expectedCap", 0)),
    ("SP.priceStalenessThreshold", sp, "priceStalenessThreshold()(uint256)", 4200),
    ("agg.minThreshold", agg, "minThreshold()(uint256)", CFG.get("minThreshold", 0)),
    ("agg.defaultThreshold", agg, "defaultThreshold()(uint256)", CFG.get("defaultThreshold", 0))):
    check(name + " == expected", expected > 0 and call(addr, sig).split()[0] == str(expected), str(expected))
for level in range(3):
    expected = CFG.get(f"slashThreshold{level}", 0)
    check(f"agg.slashThresholds[{level}] == input", expected >= 2 and call(agg, "slashThresholds(uint8)(uint8)", level) == str(expected), str(expected))
for key in ("expectedGovernor", "expectedGuardian", "expectedSPGuardian", "genesisOperator"):
    check(key + " nonzero and not deployer", A.get(key, ZERO).lower() not in (ZERO, DEPLOYER), "required address")
check("Safe nonzero and not deployer", SAFE not in (ZERO, DEPLOYER), SAFE)
guardians = CFG.get("guardians", [])
check("guardian N == inputs", 2 <= CFG.get("guardianN", 0) <= 64 and len(guardians) == CFG.get("guardianN") and len(set(g.lower() for g in guardians)) == len(guardians), str(CFG.get("guardianN")))
for i, g in enumerate(guardians, 1):
    check(f"guardian[{i}] registered", g.lower() not in (ZERO, DEPLOYER) and call(agg, "validatorAtSlot(uint8)(address)", i).lower() == g.lower() and call(dvt, "isValidator(address)(bool)", g) == "true", g)
op = A.get("genesisOperator", ZERO)
for role in ("COMMUNITY", "PAYMASTER_SUPER"):
    check(f"genesis operator has {role}", op != ZERO and call(reg, "hasRole(bytes32,address)(bool)", cast("keccak", role)[1], op) == "true", op)
rc, raw = cast("call", sp, "operators(address)", op)
check("genesis minTxInterval == 0", rc == 0 and len(raw) >= 2 + 64 * 6 and int(raw[2 + 64 * 5:2 + 64 * 6], 16) == 0, "0")
rc, code = cast("code", H)
# Solidity constructor-only runtime: PUSH0/PUSH1 DUP1 REVERT (metadata disabled).
check("H runtime non-callable", H != ZERO and rc == 0 and len(code) <= 130 and code.lower().startswith(("0x5f80fd", "0x60806040525f80fd", "0x6080604052600080fd")), "constructor-only revert runtime")
# Rebuild membership from the complete address-filtered history, then confirm every member.
rc, raw = cast("rpc", "eth_getLogs", json.dumps({"address": TL, "fromBlock": "0x0", "toBlock": "latest"}))
try:
    logs = json.loads(raw) if rc == 0 else None
    assert isinstance(logs, list)
    grants = cast("keccak", "RoleGranted(bytes32,address,address)")[1].lower()
    revokes = cast("keccak", "RoleRevoked(bytes32,address,address)")[1].lower()
    members, seen = {}, {}
    for event in sorted(logs, key=lambda e: (int(e["blockNumber"], 16), int(e["logIndex"], 16))):
        topics = event["topics"]
        if topics[0].lower() not in (grants, revokes): continue
        bucket = members.setdefault(topics[1].lower(), set())
        account = "0x" + topics[2][-40:].lower()
        seen.setdefault(topics[1].lower(), set()).add(account)
        if topics[0].lower() == grants: bucket.add(account)
        else: bucket.discard(account)
except (AssertionError, ValueError, KeyError, TypeError):
    members = None
for role in ("DEFAULT_ADMIN_ROLE", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"):
    rid = call(TL, role + "()(bytes32)")
    expected = {TL.lower()} if role == "DEFAULT_ADMIN_ROLE" else {SAFE}
    actual = members.get(rid.lower(), set()) if members is not None else set()
    check(f"TL.{role} exact members", members is not None and actual == expected and all(call(TL, "hasRole(bytes32,address)(bool)", rid, a) == ("true" if a in actual else "false") for a in seen.get(rid.lower(), set())), f"expected {sorted(expected)}; actual {sorted(actual)}")
    check(f"TL.{role}(H) == false", H != ZERO and call(TL, "hasRole(bytes32,address)(bool)", rid, H) == "false", "false")
    check(f"TL.{role}(safe) == expected", call(TL, "hasRole(bytes32,address)(bool)", rid, SAFE) == ("false" if role == "DEFAULT_ADMIN_ROLE" else "true"), "false" if role == "DEFAULT_ADMIN_ROLE" else "true")
check("TL.DEFAULT_ADMIN_ROLE(timelock) == true", call(TL, "hasRole(bytes32,address)(bool)", call(TL, "DEFAULT_ADMIN_ROLE()(bytes32)"), TL) == "true", "true")
print(f"\nSUMMARY {sum(results)} passed, {len(results) - sum(results)} failed, {len(results)} total")
sys.exit(0 if all(results) else 1)
