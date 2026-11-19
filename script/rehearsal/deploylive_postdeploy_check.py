#!/usr/bin/env python3
"""Read-only post-deploy check of a DeployLive-built system against the rc.8 owner-table expectations.

Usage: deploylive_postdeploy_check.py <rpc> deployments/live/config.<ENV>.json <deployer> <safe>
Local non-production runs may supply their original deployments/config.<ENV>.json path.
Prints one PASS/FAIL line per assertion and a summary. Nothing is sent: eth_call only.
"""
import hashlib
import os
import json
import subprocess
import sys
import re
from pathlib import Path

if len(sys.argv) == 4:
    sys.argv.insert(1, os.environ['ETH_RPC_URL'])
RPC, CFG, DEPLOYER, SAFE = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3].lower(), sys.argv[4].lower()
results = []
BLOCK = None
READBACK = Path(os.environ.get("DEPLOYLIVE_EVIDENCE_DIR", os.environ.get("DEPLOYLIVE_LOCAL_EVIDENCE", str(Path(sys.argv[2]).parent)))) / "readback.json"
READBACK.unlink(missing_ok=True)
principal_addresses = {DEPLOYER, SAFE}
if sys.argv[5:]:
    print("FAIL unknown checker option")
    sys.exit(1)


def integer(value):
    if isinstance(value, bool): raise ValueError("boolean is not an integer")
    if not re.fullmatch(r"(?:[0-9]+|0x[0-9a-fA-F]+)", str(value)):
        raise ValueError("expected unsigned integer or decimal string")
    return int(str(value), 16 if str(value).startswith("0x") else 10)


for key in ("deploymentStartBlock", "handoverBootstrapNonce", "observedBootstrapNonce", "expectedCap", "guardianN", "minThreshold", "defaultThreshold",
            "slashThreshold0", "slashThreshold1", "slashThreshold2", "deployerGTokenBalance", "deployerGTokenAllowance", "deployerSBTBalance",
            "deployerGTokenTransferred", "deployerGTokenRecipientBefore", "gTokenMintCount", "gTokenTotalSupply", "ticketsToTreasury", "treasuryGTokenBefore", "deployerRemainderToRecipient"):
    try:
        CFG[key] = integer(CFG[key])
        assert CFG[key] >= (1 if key == "deploymentStartBlock" else 0)
    except (KeyError, ValueError, TypeError, AssertionError):
        print("FAIL missing/invalid config integer: " + key)
        sys.exit(1)

for key in ("gTokenMintAmounts", "stakeAmounts", "ticketAmounts"):
    try:
        if not isinstance(CFG[key], list): raise ValueError("expected list")
        CFG[key] = [integer(v) for v in CFG[key]]
    except (KeyError, ValueError, TypeError):
        print("FAIL missing/invalid config integer array: " + key)
        sys.exit(1)


LOCAL = {"keccak", "calldata", "sig", "abi-encode"}


def transport(*args, endpoint=None):
    cmd = ["cast", *args]
    if BLOCK is not None and args[0] in ("call", "code", "storage", "balance"):
        # cast 1.7.1 help promises heights/tags only. Use canonical EIP-1898 RPC.
        selector = json.dumps({"blockHash": block['hash'], "requireCanonical": True})
        if args[0] == 'call':
            signature = args[2]
            input_sig = signature[:signature.index(')') + 1]
            # Tuple inputs contain nested parentheses; find the closing input list.
            depth = 0
            for i, c in enumerate(signature[signature.index('('):], signature.index('(')):
                depth += (c == '(') - (c == ')')
                if depth == 0:
                    input_sig = signature[:i+1]; break
            rc, data = cast('calldata', input_sig, *args[3:])
            if rc: return rc, data
            rc, raw = rpc_read('eth_call', json.dumps({'to': args[1].lower(), 'data': data}), selector, endpoint=endpoint)
            if rc: return rc, raw
            if signature == input_sig: return 0, raw
            result = local('decode-abi', signature, raw)
            if not result[0] and ('(address)' in signature or '(address[])' in signature):
                principal_addresses.update(a.lower() for a in re.findall(r'0x[0-9a-fA-F]{40}', result[1]))
            return result
        method = {'code': 'eth_getCode', 'storage': 'eth_getStorageAt', 'balance': 'eth_getBalance'}[args[0]]
        params = list(args[1:])
        if args[0] == 'storage' and re.fullmatch(r'[0-9]+', params[1]): params[1] = hex(int(params[1]))
        rc, raw = rpc_read(method, *params, selector, endpoint=endpoint)
        return (rc, str(int(raw, 16))) if not rc and args[0] == 'balance' else (rc, raw)
    return local(*args, endpoint=endpoint)


def local(*args, endpoint=None):
    r = subprocess.run(['cast', *args], env=dict(os.environ, ETH_RPC_URL=endpoint or RPC), capture_output=True, text=True)
    if r.returncode:
        return r.returncode, " ".join(re.findall(r"0x[0-9a-fA-F]+", r.stderr)) or "RPC/local command failed"
    return 0, r.stdout.strip()


from deploylive_readback import Snapshot
rpc_snapshot = Snapshot(lambda *args: local('rpc', *args))


def rpc_read(*args, endpoint=None):
    rc, raw = local('rpc', *args, endpoint=endpoint) if endpoint else rpc_snapshot(*args)
    if rc: return rc, raw
    try: return 0, json.loads(raw)
    except ValueError: return 1, 'invalid RPC result'


cast = Snapshot(transport)

def raw_call(frm, to, data):
    q = json.dumps({"from": frm, "to": to, "data": data})
    return cast("rpc", "eth_call", q, json.dumps({"blockHash": block["hash"], "requireCanonical": True}))


def call(addr, sig, *args):
    rc, out = cast("call", addr, sig, *map(str, args))
    return out if rc == 0 and out else f"<revert: {out[:120]}>"


def check(name, ok, detail):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name} :: {detail}")


A = {k: v for k, v in CFG.items() if isinstance(v, str) and v.startswith("0x") and len(v) == 42}
required_addresses = set(json.loads((Path(__file__).resolve().parents[2]/'deployments/readback-artifacts.json').read_text()))
required_addresses.update(json.loads((Path(__file__).resolve().parents[2]/'deployments/readback-noncontracts.json').read_text())['production'])
if required_addresses - A.keys():
    print('FAIL config address coverage: missing/invalid ' + ','.join(sorted(required_addresses - A.keys())))
    sys.exit(1)
agg, dvt, reg, sp, stk = A["blsAggregator"], A["dvtValidator"], A["registry"], A["superPaymaster"], A["staking"]
TL = A["timelockController"]

# Chain expectations come from reviewed files, never deployment inputs.
if type(CFG.get("enableAgentRegistries")) is not bool:
    print("FAIL missing/invalid config boolean: enableAgentRegistries")
    sys.exit(1)
agents_enabled = CFG["enableAgentRegistries"]
ROOT = Path(__file__).resolve().parents[2]
rc, chain_raw = cast("rpc", "eth_chainId")
try:
    if rc != 0: raise ValueError("chain unreadable")
    chain = integer(json.loads(chain_raw))
    deps_path = ROOT / f"deployments/external-deps.{chain}.json"
    if chain == 31337 and agents_enabled:
        deps_path = ROOT / "contracts/test/fixtures/deploylive/external-deps.31337.agents.json"
    deps = json.loads(deps_path.read_text())
except (ValueError, TypeError, OSError):
    print("FAIL external dependencies: missing chain group / unreadable chain")
    sys.exit(1)
try:
    rc, raw = cast("rpc", "eth_getBlockByNumber", "latest", "false")
    block = json.loads(raw)
    if rc or not isinstance(block, dict) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", block['hash']): raise ValueError('block unreadable')
    BLOCK = hex(integer(block['number']))
    integer(block['timestamp'])
except (KeyError, ValueError, TypeError):
    print("FAIL pinned block unreadable")
    sys.exit(1)
for key in ("ethUsdFeed", "entryPoint", "accountFactory", "agentIdentityRegistry", "agentReputationRegistry", "agentValidationRegistry"):
    if not isinstance(deps, dict) or not isinstance(deps.get(key), str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", deps[key]):
        print("FAIL external dependencies: missing/invalid " + key)
        sys.exit(1)
    if key.startswith("agent") and not agents_enabled:
        deps[key] = "0x" + "0" * 40
from deploylive_readback import collect, write, validate_record, validate_config, recheck_block, corroborate
runtime_path = ROOT / f"deployments/runtime-pins.{chain}.json"
mapping = json.loads((ROOT/'deployments/readback-artifacts.json').read_text())
policy = json.loads((ROOT/'deployments/readback-policy.json').read_text())
noncontracts = json.loads((ROOT/'deployments/readback-noncontracts.json').read_text())
expected_noncontracts = dict(noncontracts['production'])
if chain == 31337 and 'expectedGovernor' in CFG:
    expected_noncontracts.update(noncontracts['localOnly'])
record, collection_ok, coverage_ok = None, False, False
try:
    validate_config(CFG, mapping, expected_noncontracts, policy['zeroAllowedConfigKeys'])
    coverage_ok = True
    record = collect(sys.argv[2], CFG, chain, block, os.environ.get('DEPLOYLIVE_ENDPOINT_PROVIDER', ''), json.loads(deps_path.read_text()), runtime_path, cast)
    validate_record(record, CFG, policy)
    collection_ok = True
    principal_addresses.update(a.lower() for a in re.findall(r'0x[0-9a-fA-F]{40}(?![0-9a-fA-F])', json.dumps(record['contracts'])))
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
    pass


def assertions():
    from deploylive_runtime import check_source_commit
    check("source commit", check_source_commit(CFG, chain, ROOT), "config.commit must match HEAD in a clean worktree; empty local commit exempt")

    for key, getter in (("ethUsdFeed", "ETH_USD_PRICE_FEED"), ("entryPoint", "entryPoint"),
                        ("agentIdentityRegistry", "agentIdentityRegistry"), ("agentReputationRegistry", "agentReputationRegistry")):
        check("external " + key, call(sp, getter + "()(address)").lower() == deps[key].lower(), deps[key])
    check("external accountFactory", A.get("simpleAccountFactory", "").lower() == deps["accountFactory"].lower(), deps["accountFactory"])
    check("external validation registry recorded", A.get("agentValidationRegistry", "").lower() == deps["agentValidationRegistry"].lower(), deps["agentValidationRegistry"])

    from deploylive_runtime import artifact, artifact_directory, compile_settings, release_artifact
    try:
        directory_ok = CFG.get("artifactDirectory") == artifact_directory()
    except ValueError:
        directory_ok = False
    check("artifact directory", directory_ok, "DEFAULT_ARTIFACTS_OUT equals config")
    try:
        settings_ok = CFG.get("artifactCompileSettings") == compile_settings()
    except (OSError, ValueError, TypeError, KeyError):
        settings_ok = False
    check("artifact compile settings", settings_ok, "Cancun, viaIR, Registry/H=200; all other pins=500")
    rc, deployer_code = cast("code", DEPLOYER)
    try:
        recorded_empty = integer(CFG.get("deployerCodeLength")) == 0
    except (ValueError, TypeError):
        recorded_empty = False
    check("deployer has no code", rc == 0 and deployer_code == "0x" and recorded_empty, "live and recorded code length zero")
    try:
        pins_bytes = (ROOT / f"deployments/creation-pins.{chain}.json").read_bytes()
        pins = json.loads(pins_bytes)
        pins_digest_ok = CFG.get("creationPinsSha256", "").lower() == "0x" + hashlib.sha256(pins_bytes).hexdigest()
    except (OSError, ValueError, TypeError, AttributeError):
        pins, pins_digest_ok = {}, False
    check("creationPinsSha256", pins_digest_ok, "sha256 of committed chain pin file")
    from creation_pins import release_names
    try:
        for name in release_names():
            artifact(name, pins[name], cast)
        release_pins_ok = set(pins) == set(release_names())
    except (OSError, KeyError, ValueError, TypeError, AttributeError):
        release_pins_ok = False
    check("release creation pins", release_pins_ok, "all 25 metadata artifacts match committed pins")
    from deploylive_readback import runtime_rows, PROXY_ABI
    from runtime_pins import artifact_pins
    runtime_path = ROOT / f"deployments/runtime-pins.{chain}.json"
    mapping = json.loads((ROOT/'deployments/readback-artifacts.json').read_text())
    try:
        runtime_pins = json.loads(runtime_path.read_text())
        runtime_pins_ok = runtime_pins == artifact_pins(ROOT/artifact_directory(), ROOT/f"deployments/creation-pins.{chain}.json")
    except (OSError, ValueError, KeyError, TypeError):
        runtime_pins, runtime_pins_ok = {}, False
    check("release runtime pins", runtime_pins_ok, "committed runtime pins match release build")
    def read_code(address):
        rc, code = cast("code", address)
        if rc: raise ValueError('code unreadable')
        return code
    for key, ok in runtime_rows(CFG, mapping, runtime_pins.get('artifacts', {}), read_code):
        check("runtime " + key, ok and runtime_pins_ok, "exact EIP-1167 clone of config.xPNTsTokenV2Impl" if key == "pnts" else "release runtime pin; compiler immutable references masked")
    versions = json.loads((ROOT/'deployments/release-versions.rc8.json').read_text())
    for key, name in mapping.items():
        name = PROXY_ABI.get(key, name)
        if name is None: continue
        try:
            has_version = any(f.get('type') == 'function' and f.get('name') == 'version' and not f['inputs'] for f in release_artifact(name)['abi'])
        except (OSError, ValueError, KeyError, TypeError):
            check("version " + key, False, "release ABI unavailable")
            continue
        if has_version:
            absent = A.get(key) == "0x" + "0" * 40
            value = None if absent else call(A.get(key, "0x" + "0" * 40), "version()(string)")
            check("version " + key, isinstance(versions.get(name), str) and ((absent and key in policy['zeroAllowedConfigKeys']) or (not absent and value.strip('"') == versions[name])), "zero address; not deployed" if absent else str(versions.get(name)))

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
    for k in ("gToken", "blsAggregator", "dvtValidator", "xPNTsFactory", "xPNTsFactoryV2", "aoaProtocolRegistry"):
        EXPECTED_OWNERS[k] = SAFE
    for k, choice in (("x402Facilitator", "X402_OWNER"), ("reputationSystem", "REPUTATION_OWNER"),
                      ("microPaymentChannel", "MPC_OWNER"), ("paymasterFactory", "PAYMASTER_FACTORY_OWNER"),
                      ("paymasterV4Impl", "PAYMASTER_FACTORY_OWNER")):
        EXPECTED_OWNERS[k] = A.get(choice, ZERO)
    check("AOA Paymaster absent", A.get("aPNTsPaymasterV4", "").lower() == ZERO and call(A["paymasterFactory"], "getPaymasterByOperator(address)(address)", DEPLOYER).lower() == ZERO, "no AOA deployment")
    check("config legacy pnts == zero", A.get("pnts", ZERO).lower() == ZERO, "config only; no on-chain absence claim")
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
        ("aggregator.slashPolicyAdmin", agg, "slashPolicyAdmin()(address)", A.get("SLASH_POLICY_ADMIN", ZERO)),
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
    for key in ("expectedGuardian", "expectedSPGuardian", "genesisOperator"):
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
    check("genesis isConfigured == false", CFG.get("genesisIsConfigured") is False and rc == 0 and len(raw) == 2 + 64 * 9 and int(raw[66:130], 16) == 0, "registered; operator configuration deferred")
    rc, code = cast("code", H)
    # Solidity constructor-only runtime: PUSH0/PUSH1 DUP1 REVERT (metadata disabled).
    check("H runtime non-callable", H != ZERO and rc == 0 and len(code) <= 130 and code.lower().startswith(("0x5f80fd", "0x60806040525f80fd", "0x6080604052600080fd")), "constructor-only revert runtime")
    # Rebuild membership from the complete address-filtered history, then confirm every member.
    rc, raw = cast("rpc", "eth_getLogs", json.dumps({"address": TL, "fromBlock": hex(CFG["deploymentStartBlock"]), "toBlock": BLOCK}))
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
    # Input identity and deployment residue are bound to the ceremony's recorded config.
    check("config deployer == CLI", A.get("deployer", ZERO).lower() == DEPLOYER, DEPLOYER)
    check("config governanceOwner == CLI", A.get("governanceOwner", ZERO).lower() == SAFE, SAFE)
    rc, safe_code = cast("code", SAFE)
    check("Safe code excludes delegation", rc == 0 and safe_code != "0x" and not safe_code.lower().startswith("0xef0100"), "contract, not EIP-7702")
    owners = []
    try:
        threshold = integer(call(SAFE, "getThreshold()(uint256)").split()[0])
        owners_rc, owners_raw = cast("call", SAFE, "getOwners()(address[])")
        if owners_rc != 0: raise ValueError("Safe owners unreadable")
        owners = re.findall(r"0x[0-9a-fA-F]{40}", owners_raw)
        valid_safe = threshold >= 2 and len(owners) >= threshold and len(set(x.lower() for x in owners)) == len(owners) and ZERO not in owners
    except (ValueError, IndexError):
        valid_safe = False
    check("Safe threshold/owners", valid_safe, "threshold >= 2, distinct nonzero owners >= threshold")
    check("Safe owners exclude deployer", valid_safe and DEPLOYER not in [a.lower() for a in owners], "getOwners() readback")
    OFFICIAL_SAFE = json.loads((Path(__file__).resolve().parents[2] / "deployments/safe-official.json").read_text())


    def safe_security(candidate):
        def storage(slot):
            rc, raw = cast("storage", candidate, slot)
            if rc != 0 or not re.fullmatch(r"0x[0-9a-fA-F]{64}", raw): return None
            return raw.lower()
        code_rc, code = cast("code", candidate)
        hash_rc, codehash = cast("keccak", code) if code_rc == 0 else (1, "")
        proxy_ok = hash_rc == 0 and codehash.lower() in [h.lower() for h in OFFICIAL_SAFE["proxyCodehashes"]]
        master = storage("0")
        guard_rc, guard_slot = cast("keccak", "guard_manager.guard.address")
        handler_rc, handler_slot = cast("keccak", "fallback_manager.handler.address")
        guard = storage(guard_slot) if guard_rc == 0 else None
        handler = storage(handler_slot) if handler_rc == 0 else None
        rc, raw = cast("call", candidate, "getModulesPaginated(address,uint256)(address[],address)", "0x" + "0" * 39 + "1", "10")
        modules = rc == 0 and re.fullmatch(r"\[\]\s+0x0{39}1", raw) is not None
        return (proxy_ok, master is not None and "0x" + master[-40:] in [a.lower() for a in OFFICIAL_SAFE["singletons"]],
                modules, guard == "0x" + "0" * 64,
                handler is not None and "0x" + handler[-40:] in [a.lower() for a in OFFICIAL_SAFE["fallbackHandlers"]])


    for label, ok in zip(("official proxy codehash", "official singleton", "modules empty", "guard zero", "official fallback handler"), safe_security(SAFE)):
        check("Safe " + label, ok, "independent storage / module read")
    role_addresses = [(f"Safe owner[{i}]", a) for i, a in enumerate(owners)]
    role_addresses += [(f"guardian[{i}]", a) for i, a in enumerate(guardians)]
    role_addresses += [("SP_GUARDIAN", A["expectedSPGuardian"]), ("GUARDIAN_ADDRESS", A["expectedGuardian"]),
                       ("GENESIS_AASTAR_OPERATOR", op), ("deployer", DEPLOYER),
                       ("DEPLOYER_GTOKEN_RECIPIENT", A.get("deployerGTokenRecipient", ZERO)), ("GOVERNANCE_OWNER", SAFE)]
    role_addresses += [(key, A.get(key, ZERO)) for key in ("SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER")]
    roles_by_address = {}
    for role, address in role_addresses:
        roles_by_address.setdefault(address.lower(), []).append(role)
    print("INFO  role overlap table :: address :: roles")
    for address, names in sorted(roles_by_address.items()):
        if len(names) > 1:
            print(f"INFO  role overlap :: {address} :: {', '.join(names)}")
    principals = [SAFE, DEPLOYER, A["expectedSPGuardian"].lower(), A["expectedGuardian"].lower(), op.lower()] + [g.lower() for g in guardians]
    check("required principals pairwise distinct", len(set(principals)) == len(principals) and ZERO not in principals, "Safe, guardians, genesis, deployer")
    for label, token, sig, args, key in (
        ("GToken balance", A["gToken"], "balanceOf(address)(uint256)", [DEPLOYER], "deployerGTokenBalance"),
        ("GToken allowance", A["gToken"], "allowance(address,address)(uint256)", [DEPLOYER, stk], "deployerGTokenAllowance"),
        ("SBT balance", A["sbt"], "balanceOf(address)(uint256)", [DEPLOYER], "deployerSBTBalance")):
        actual = call(token, sig, *args).split()[0]
        expected = CFG[key]
        check("deployer " + label + " == recorded", actual == str(expected) and expected == 0, f"recorded {expected}; actual {actual}")

    check("deployer pending SBT burn == false", call(reg, "pendingSBTBurn(address)(bool)", DEPLOYER) == "false", "no deferred burn")

    # Every independent authority is the final timelock, checked governance Safe,
    # or another Safe subject to the same independent checks.
    def authority(candidate):
        candidate = candidate.lower()
        if candidate in (ZERO, DEPLOYER): return False
        if candidate == TL.lower(): return True
        if candidate == SAFE: return valid_safe and all(safe_security(candidate))
        rc, code = cast("code", candidate)
        if rc != 0 or code == "0x" or code.lower().startswith("0xef0100"): return False
        try:
            rc, raw = cast("call", candidate, "getOwners()(address[])")
            if rc != 0: return False
            owners = [a.lower() for a in re.findall(r"0x[0-9a-fA-F]{40}", raw)]
            threshold = integer(call(candidate, "getThreshold()(uint256)").split()[0])
            return (2 <= threshold <= len(owners) and len(set(owners)) == len(owners)
                    and not {ZERO, DEPLOYER}.intersection(owners) and all(safe_security(candidate)))
        except (ValueError, IndexError): return False


    for key in ("SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER", "deployerGTokenRecipient"):
        owner = A.get(key, ZERO)
        check(key + " resolved contract", authority(owner), owner)
    recipient = A.get("deployerGTokenRecipient", ZERO)
    actual = call(A["gToken"], "balanceOf(address)(uint256)", recipient).split()[0]
    check("GToken recipient exact delta", recipient.lower() not in (ZERO, DEPLOYER) and actual == str(CFG["deployerGTokenRecipientBefore"] + CFG["deployerGTokenTransferred"]), actual)
    amounts = CFG["gTokenMintAmounts"]
    recipients = CFG.get("gTokenMintRecipients", [])
    check("GToken mint ledger", len(amounts) == len(recipients) == CFG["gTokenMintCount"] == 2 and all(a.lower() == DEPLOYER for a in recipients) and sum(amounts) == CFG["gTokenTotalSupply"], str(amounts))
    rc, raw = cast("rpc", "eth_getLogs", json.dumps({"address": A["gToken"], "fromBlock": hex(CFG["deploymentStartBlock"]), "toBlock": BLOCK,
        "topics": [cast("keccak", "Transfer(address,address,uint256)")[1], "0x" + "00" * 32]}))
    try:
        mint_events = json.loads(raw)
        actual_mints = [("0x" + e["topics"][2][-40:].lower(), integer(e["data"])) for e in mint_events]
        mint_history_ok = rc == 0 and actual_mints == [(a.lower(), n) for a, n in zip(recipients, amounts)]
    except (ValueError, KeyError, TypeError, IndexError):
        mint_history_ok = False
    check("GToken mint events == ledger", mint_history_ok, "all zero-source Transfer events since deployment")
    check("GToken totalSupply == mints", call(A["gToken"], "totalSupply()(uint256)").split()[0] == str(sum(amounts)), str(sum(amounts)))
    accounts, roles, stakes, tickets, treasuries = (CFG.get(k, []) for k in ("stakeAccounts", "stakeRoles", "stakeAmounts", "ticketAmounts", "ticketTreasuries"))
    check("GToken ticket ledger", len(accounts) == len(roles) == len(stakes) == len(tickets) == len(treasuries) and len(accounts) == len(guardians) + 3 and [a.lower() for a in accounts] == [a.lower() for a in [DEPLOYER, op, op] + guardians] and all(t.lower() == SAFE for t in treasuries), "tickets paid to Safe treasury")
    for i, (account, role, amount) in enumerate(zip(accounts, roles, stakes)):
        check(f"GToken stake[{i}]", call(stk, "getLockedStake(address,bytes32)(uint256)", account, role).split()[0] == str(amount), f"{account} {role}: {amount}")
    check("GToken conservation", sum(stakes) + CFG["ticketsToTreasury"] + CFG["deployerRemainderToRecipient"] == sum(amounts) and CFG["deployerRemainderToRecipient"] == CFG["deployerGTokenTransferred"] and call(A["gToken"], "balanceOf(address)(uint256)", stk).split()[0] == str(sum(stakes)), "minted = locked + tickets to treasury + remainder to recipient")
    check("GToken treasury tickets", CFG["ticketsToTreasury"] == sum(tickets) and call(A["gToken"], "balanceOf(address)(uint256)", SAFE).split()[0] == str(CFG["treasuryGTokenBefore"] + CFG["ticketsToTreasury"] + (CFG["deployerGTokenTransferred"] if recipient.lower() == SAFE else 0)), "measured treasury delta excluding recipient remainder")
    rc, error = raw_call(DEPLOYER, A["gToken"], cast("calldata", "mint(address,uint256)", DEPLOYER, "1")[1])
    check("deployer GToken mint rejected", rc != 0 and cast("sig", "OwnableUnauthorizedAccount(address)")[1][2:] in error, "OwnableUnauthorizedAccount")

    # Only the constructor's ten-call batch may ever have been scheduled/executed.
    try:
        assert members is not None
        scheduled_topic = cast("keccak", "CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)")[1].lower()
        executed_topic = cast("keccak", "CallExecuted(bytes32,uint256,address,uint256,bytes)")[1].lower()
        role_ids = [call(TL, r + "()(bytes32)") for r in ("PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE")]
        targets = [reg, sp, A["aPNTs"]] + [TL] * 7
        data = [cast("calldata", "acceptOwnership()")[1]] * 3
        data += [cast("calldata", "grantRole(bytes32,address)", r, SAFE)[1] for r in role_ids]
        data += [cast("calldata", "revokeRole(bytes32,address)", r, H)[1] for r in role_ids]
        data += [cast("calldata", "updateDelay(uint256)", "172800")[1]]
        arr = lambda xs: "[" + ",".join(xs) + "]"
        salt = cast("keccak", cast("abi-encode", "f(address,address[])", H, arr(targets[:3]))[1])[1]
        zero32 = "0x" + "00" * 32
        operation = call(TL, "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)", arr(targets), arr(["0"] * 10), arr(data), zero32, salt).lower()
        for topic, scheduled in ((scheduled_topic, True), (executed_topic, False)):
            events = [e for e in logs if e["topics"][0].lower() == topic]
            assert len(events) == 10
            indices = set()
            for e in events:
                assert len(e["topics"]) == 3 and e["topics"][1].lower() == operation
                i = integer(e["topics"][2]); assert 0 <= i < 10 and i not in indices
                indices.add(i)
                signature = "f(address,uint256,bytes,bytes32,uint256)" if scheduled else "f(address,uint256,bytes)"
                args = [targets[i], "0", data[i]] + ([zero32, "0"] if scheduled else [])
                rc, expected_data = cast("abi-encode", signature, *args)
                assert rc == 0 and e["data"].lower() == expected_data.lower()
        assert call(TL, "isOperationDone(bytes32)(bool)", operation) == "true"
        operations_ok = True
    except (AssertionError, KeyError, ValueError, TypeError, IndexError):
        operations_ok = False
    check("TL history exactly H batch executed", operations_ok, "one operation; ten scheduled and ten executed calls; exact payloads")

    # Direct implementation calls must reject initialization and UUPS upgrades even from their owner.
    for key, signature, args in (
        ("registryImpl", "initialize(address,address,address)", [DEPLOYER, stk, A["sbt"]]),
        ("spImpl", "initialize(address,address,address,uint256)", [DEPLOYER, A["aPNTs"], SAFE, "4200"])):
        impl = A.get(key, ZERO)
        owner = call(impl, "owner()(address)")
        print(f"INFO  {key}.owner :: {owner}")
        proxy = reg if key == "registryImpl" else sp
        rc_slot, slot = cast("storage", proxy, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")
        init = cast("calldata", signature, *args)[1]
        upgrade = cast("calldata", "upgradeToAndCall(address,bytes)", impl, "0x")[1]
        rc_init, err_init = raw_call(owner, impl, init)
        rc_upgrade, err_upgrade = raw_call(owner, impl, upgrade)
        rc_proxy, err_proxy = raw_call(owner, proxy, upgrade)
        owner_error = cast("sig", "OwnableUnauthorizedAccount(address)")[1][2:]
        init_error = cast("sig", "InvalidInitialization()")[1][2:]
        upgrade_error = cast("sig", "UUPSUnauthorizedCallContext()")[1][2:]
        ok = owner.lower() == A.get(key + "Owner", ZERO).lower() and rc_slot == 0 and len(slot) == 66 and ("0x" + slot[-40:]).lower() == impl.lower() and owner.lower() != call(proxy, "owner()(address)").lower() and rc_proxy != 0 and owner_error in err_proxy and impl != ZERO and not owner.startswith("<") and rc_init != 0 and init_error in err_init and rc_upgrade != 0 and upgrade_error in err_upgrade
        results.append(ok)
        print(f"{'INFO-PASS' if ok else 'FAIL'}  {key} isolated :: owner {owner}; initializers disabled; upgrades require proxy context")

    for key in ("paymasterV4Impl", "spAdminImpl", "xPNTsTokenV1Impl", "xPNTsTokenV2Impl", "xPNTsTokenV2Ext"):
        if key in A:
            actual = call(A[key], "owner()(address)")
            print(f"INFO  {key}.owner :: {actual}; recorded {CFG.get(key + 'Owner', 'missing')}")

    # Include configured beneficiaries and ledger principals as well as live getter results.
    for key in ("deployer", "governanceOwner", "expectedGuardian", "expectedSPGuardian", "genesisOperator",
                "deployerGTokenRecipient", "SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER"):
        principal_addresses.add(A.get(key, ZERO).lower())
    for key in ("guardians", "stakeAccounts", "ticketTreasuries", "gTokenMintRecipients"):
        principal_addresses.update(str(a).lower() for a in CFG.get(key, []))
    principal_failures = []
    for principal in sorted(principal_addresses - {ZERO}):
        rc, code = cast("code", principal)
        if rc != 0 or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", code) or code.lower().startswith("0xef0100"):
            principal_failures.append(principal)
    check("principals exclude EIP-7702", not principal_failures,
          "code read failed or delegation: " + ", ".join(principal_failures) if principal_failures else "all configured and live principals; ordinary contracts allowed")

# First traversal discovers all auxiliary reads (roles, Safe state, ledgers, revert
# probes). Its rows are discarded. The assertion traversal can only replay data.
import contextlib
import io
with contextlib.redirect_stdout(io.StringIO()):
    assertions()
results.clear()
cast.freeze()
rpc_snapshot.freeze()
check('config address coverage', coverage_ok, 'exact DeployLive address schema')
check('readback snapshot policy', collection_ok, 'all getters, runtime pins, zero addresses and implementation slots')
assertions()
second = None
second_ok = chain == 31337
if chain in (10, 11155111):
    # Forks must identify themselves through node metadata, not an env bypass.
    rc, raw = local('rpc', 'anvil_nodeInfo')
    try:
        info = json.loads(raw) if rc == 0 else {}
        fork = os.environ.get('DEPLOYLIVE_REHEARSAL') == '1' and bool(info.get('forkConfig', {}).get('forkUrl'))
    except (ValueError, TypeError, AttributeError):
        fork = False
    second_ok = fork
    if not fork:
        try:
            second_url = Path(os.environ['DEPLOYLIVE_SECOND_RPC_FILE']).read_text().strip()
            from urllib.parse import urlsplit
            if urlsplit(second_url).scheme not in ('http', 'https') or not urlsplit(second_url).hostname or any(c.isspace() for c in second_url): raise ValueError('invalid second endpoint')
            if urlsplit(second_url).hostname == urlsplit(RPC).hostname: raise ValueError('independent provider required')
            if not second_url or record is None: raise ValueError('missing second provider')
            rc, second_chain = local('rpc', 'eth_chainId', endpoint=second_url)
            if rc or integer(json.loads(second_chain)) != chain: raise ValueError('second chain mismatch')
            second = corroborate(record, lambda *args: transport(*args, endpoint=second_url), os.environ.get('DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER', 'Independent provider'))
            second_ok = all(second[k] is True for k in ('blockHashMatches', 'runtimeKeccakMatches', 'implSlotsMatch'))
        except (OSError, ValueError, KeyError, TypeError):
            second_ok = False
check('second provider', second_ok, 'independent corroboration or explicit local/fork evidence')
try:
    recheck_block(block, transport)
    hash_ok = True
except (ValueError, KeyError, TypeError):
    hash_ok = False
check('block hash rechecked', hash_ok, 'canonical header unchanged')
if all(results):
    record['block']['hashRechecked'] = True
    record['secondProvider'] = second
    record['singleProvider'] = second is None
    record['singleProviderNote'] = 'single provider: not evidence of on-chain state' if second is None else None
    if second is None:
        print('INFO  single provider: not evidence of on-chain state')
    try:
        write(READBACK, record)
    except (OSError, ValueError):
        check('readback', False, 'write failed')

print(f"\nSUMMARY {sum(results)} passed, {len(results) - sum(results)} failed, {len(results)} total")
sys.exit(0 if all(results) else 1)
