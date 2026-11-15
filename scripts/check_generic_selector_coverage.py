#!/usr/bin/env python3
"""Every privileged selector reachable from BLSAggregator.executeProposal is classified.

The GENERIC executeProposal path calls any target with caller-chosen calldata at a
caller-chosen threshold (>= minThreshold), with no proposalFloor. Whatever the
aggregator is privileged to do somewhere, a generic proposal can do too, unless the
selector is on the H-1 denylist (BLSAggregator.sol, SEL_* constants). The denylist
missed entries three times (markProposalExecuted, then batchUpdateGlobalReputation,
then GTokenStaking.slash / slashByDVT), so this check enumerates instead of trusting.

Contracts enumerated: those where the aggregator holds a privileged identity.
  - SuperPaymaster (+Admin): BLS_AGGREGATOR (initBLSAggregator / queue+applyBLSAggregator)
  - Registry: blsAggregator (setBLSAggregator), and a reputation source
    (DeployLive.s.sol: registry.setReputationSource(aggregator))
  - GTokenStaking: authorizedSlashers. The 5.5.0 deploy paths (DeployLive, DeployAnvil, the Sepolia
    manifest) grant NONE to the aggregator; older/E2E scripts still do (RegistryUpgradeBatchLib,
    DeployBLSAggregatorSepolia, DeployRepCreditSepolia); kept here so any grant is covered.
  - DVTValidator: BLS_AGGREGATOR (setBLSAggregator)
  - ReputationSystem: trusts Registry.isReputationSource callers (setCommunityReputation)

For every external/public non-view function in those ABIs (abis/*.json):
  - if its body, a modifier it uses, or an internal function it calls (transitively, same
    sources) references an aggregator identity, it MUST appear in CLASSIFIED below, as
    "blocked" (and then in the denylist) or "allowed: <reason>";
  - otherwise it is classified automatically as "no aggregator privilege": the aggregator
    calling it is no different from any other caller.
Fails on: an unclassified identity-referencing selector, a CLASSIFIED entry that no longer
exists in the ABI, a "blocked" entry missing from the denylist, or a denylist entry not
classified "blocked".
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
V3 = "contracts/src/paymasters/superpaymaster/v3/"
TARGETS = {
    "SuperPaymaster": ("abis/SuperPaymaster.full.json",
                       [V3 + "SuperPaymaster.sol", V3 + "SuperPaymasterAdmin.sol", V3 + "SuperPaymasterStorage.sol",
                        V3 + "BasePaymasterUpgradeable.sol"]),
    "Registry": ("abis/Registry.json", ["contracts/src/core/Registry.sol"]),
    "GTokenStaking": ("abis/GTokenStaking.json", ["contracts/src/core/GTokenStaking.sol"]),
    "DVTValidator": ("abis/DVTValidator.json", ["contracts/src/modules/monitoring/DVTValidator.sol"]),
    "ReputationSystem": ("abis/ReputationSystem.json", ["contracts/src/modules/reputation/ReputationSystem.sol"]),
}
IDENTITY = re.compile(r"\b(BLS_AGGREGATOR|blsAggregator|authorizedSlashers|isReputationSource)\b")
AGGREGATOR_SRC = "contracts/src/modules/monitoring/BLSAggregator.sol"

# signature -> classification. "blocked" must match the H-1 denylist exactly.
CLASSIFIED = {
    "SuperPaymaster": {
        "queueSlash(address)": "blocked",
        "executeSlashWithBLS(address,uint8,bytes)": "blocked",
        "updatePriceDVT(int256,uint256,bytes,uint8)":
            "allowed: the generic path is the only DVT price route; SP enforces 2 h freshness, strictly "
            "increasing updatedAt and +-20% per update against its cache; the +-20% Chainlink band applies only "
            "while Chainlink is fresh (< 2 h). With a stale feed, cumulative drift is bounded only by "
            "[MIN,MAX]_ETH_USD_PRICE, freshness and increasing updatedAt (disclosed residual)",
        "initBLSAggregator(address)": "allowed: onlyOwner; the aggregator is not the SP owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
        "applyBLSAggregator()": "allowed: onlyOwner; the aggregator is not the SP owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
        "queueBLSAggregator(address)": "allowed: onlyOwner; the aggregator is not the SP owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
        "slashOperator(address,uint8,uint256,string)":
            "allowed: onlyOwner (shares _slash with the BLS path); the aggregator is not the SP owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
        "slashOperatorAfterReleasing(address,uint8,uint256,string,bytes32[])":
            "allowed: onlyOwner (shares _slash with the BLS path); the aggregator is not the SP owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
    },
    "Registry": {
        "batchUpdateGlobalReputation(uint256,address[],uint256[],uint256,bytes)": "blocked",
        "markProposalExecuted(uint256)": "blocked",
        "updateOperatorBlacklist(address,address[],bool[],bytes)":
            "allowed: own BLS proof at defaultThreshold over a monotonic blacklistNonce; disclosed residual: a "
            "pre-rotation proof for the next unused nonce stays valid (blocks/unblocks users, moves no funds)",
        "setBLSAggregator(address)": "allowed: onlyOwner; the aggregator is not the Registry owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
        "setReputationSource(address,bool)": "allowed: onlyOwner; the aggregator is not the Registry owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
        "exitRole(bytes32)": "allowed: outbound call to the aggregator (consumeGuardianExit), keyed to msg.sender",
        "initialize(address,address,address)": "allowed: initializer, already consumed on the live proxy",
    },
    "GTokenStaking": {
        "slash(address,uint256,string)": "blocked",
        "slashByDVT(address,bytes32,uint256,string)": "blocked",
        "setAuthorizedSlasher(address,bool)": "allowed: onlyOwner; the aggregator is not the staking owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
    },
    "ReputationSystem": {
        "setCommunityReputation(address,address,uint256)":
            "allowed: disclosed residual (DSR 2026-11-15): while the aggregator is a reputation source, the "
            "current quorum can write any community score through the generic path at minThreshold with no "
            "proof; communityReputations has no reader in contracts/src (checked at edcbb12e, enforced by "
            "community_reputation_readers()) and the SDK exposes it only as a raw getter",
    },
    "DVTValidator": {
        "markProposalExecuted(uint256)": "blocked",
        "setBLSAggregator(address)": "allowed: onlyOwner; the aggregator is not the DVT owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
        "createProposal(address,uint8,string)":
            "allowed: _requireActiveValidator(msg.sender); the aggregator is never a DVT validator [guaranteed by step-13 readback AGG-NOT-DVT-VALIDATOR: no ROLE_DVT, not a registered validator]",
        "createProposal(address,uint8,string,bytes32)":
            "allowed: _requireActiveValidator(msg.sender); the aggregator is never a DVT validator [guaranteed by step-13 readback AGG-NOT-DVT-VALIDATOR: no ROLE_DVT, not a registered validator]",
        "queueSlashWithProof(address,uint8,uint256,bytes)":
            "allowed: _requireActiveValidator(msg.sender); the aggregator is never a DVT validator [guaranteed by step-13 readback AGG-NOT-DVT-VALIDATOR: no ROLE_DVT, not a registered validator]",
        "executeWithProof(uint256,address[],uint256[],uint256,bytes)":
            "allowed: the aggregator passes onlyAuthorizedExecutor but the call re-enters "
            "BLSAggregator.verifyAndExecute, which is nonReentrant (executeProposal holds the lock)",
        "registerBLSPublicKey(address,(bytes32,bytes32,bytes32,bytes32),uint8,"
        "(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32))":
            "allowed: non-owner path requires msg.sender == validator plus role/stake eligibility and a PoP",
        "removeValidator(address)": "allowed: onlyOwner; the aggregator is not the DVT owner [guaranteed by ownership_violations() on the deploy paths and step-13 readback OWNER-NOT-AGGREGATOR]",
    },
}


def sig(entry):
    def t(p):
        if p["type"].startswith("tuple"):
            return "(" + ",".join(t(c) for c in p["components"]) + ")" + p["type"][5:]
        return p["type"]
    return f"{entry['name']}({','.join(t(i) for i in entry.get('inputs', []))})"


def blocks(text):
    """name -> list of (params text, modifiers text, body text) for functions and modifiers."""
    out = {}
    for m in re.finditer(r"\b(function|modifier)\s+(\w+)\s*\(", text):
        name, i = m.group(2), m.end()
        depth = 1
        while depth:
            depth += {"(": 1, ")": -1}.get(text[i], 0)
            i += 1
        params = text[m.end():i - 1]
        j = i
        while j < len(text) and text[j] not in "{;":
            j += 1
        head = text[i:j]
        body = ""
        if j < len(text) and text[j] == "{":
            depth, k = 1, j + 1
            while depth:
                depth += {"{": 1, "}": -1}.get(text[k], 0)
                k += 1
            body = text[j:k]
        out.setdefault(name, []).append((params, head, body))
    return out


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def privileged_names(sources):
    text = "\n".join(strip_comments((ROOT / s).read_text()) for s in sources)
    defs = blocks(text)
    flagged = {n for n, ds in defs.items() if any(IDENTITY.search(h + b) for _, h, b in ds)}
    changed = True
    while changed:  # a function using a flagged modifier or calling a flagged internal is flagged
        changed = False
        for n, ds in defs.items():
            if n in flagged:
                continue
            if any(re.search(r"\b(" + "|".join(map(re.escape, flagged)) + r")\b", h + b) for _, h, b in ds):
                flagged.add(n)
                changed = True
    return flagged


def denylist():
    src = (ROOT / AGGREGATOR_SRC).read_text()
    return set(re.findall(r'bytes4 private constant SEL_\w+\s*=\s*bytes4\(keccak256\("([^"]+)"\)\)', src))


# Trust root, derived rather than hand-written: every setter a deploy path calls with the
# aggregator's address must map to an identity in IDENTITY and to a contract in TARGETS
# (or EXTERNAL, with a reason). A grant under a new name, or on a new contract, fails here.
GRANT_SOURCES = {
    "contracts/script/v3/DeployLive.s.sol": "sol",
    "contracts/script/v3/DeployAnvil.s.sol": "sol",
    "script/upgrade/manifest_exec.py": "py",
}
SETTERS = {  # setter -> (identity it writes, contract it lives on)
    "setBLSAggregator": ("blsAggregator / BLS_AGGREGATOR", "Registry, DVTValidator"),
    "initBLSAggregator": ("BLS_AGGREGATOR", "SuperPaymaster"),
    "queueBLSAggregator": ("BLS_AGGREGATOR", "SuperPaymaster"),
    "setReputationSource": ("isReputationSource", "Registry"),
    "setAuthorizedSlasher": ("authorizedSlashers", "GTokenStaking"),
    "setBlsAggregator": (None, "committee"),
}
EXTERNAL = {
    "committee": "DVT repo AAStarCommitteeValidator (manifest_exec COMMITTEE); ABI not compiled here. DVT "
                 "8bbac708 review (2026-11-15): no state-changing function gated on msg.sender == aggregator; "
                 "setBlsAggregator is onlyOwner; generic-reachable functions only touch the caller's own entry",
}
# The aggregator must never become an owner/admin: every onlyOwner function of that contract would
# fall into the generic path. Constructor arguments that pass the aggregator are allowed only
# where the parameter is not an ownership role.
OWNER_PARAM = re.compile(r"owner|admin|governor|governance|proposer|executor|guardian", re.I)
EXTERNAL_CTOR_ARGS = {
    "OverIssueFraudProofVerifier": "DVT repo verifier, constructor (aggregator, registry) binds its domain; "
                                   "the aggregator gets no role on it",
}


def ownership_violations():
    bad = []
    for path, kind in GRANT_SOURCES.items():
        text = strip_comments((ROOT / path).read_text()) if kind == "sol" else (ROOT / path).read_text()
        if kind == "sol":
            for m in re.finditer(r"(transferOwnership|grantRole|changeAdmin|setPendingOwner)\([^;]*address\(aggregator\)", text):
                bad.append(f"{path}: {m.group(1)}(... aggregator ...)")
            for m in re.finditer(r'_deployDefault\("(\w+)",\s*abi\.encode\(([^;]*)\)\)', text):
                args = [a.strip() for a in m.group(2).split(",")]
                for i, a in enumerate(args):
                    if "address(aggregator)" in a:
                        bad += ctor_param_check(path, m.group(1), i)
        else:
            for m in re.finditer(r"'(transferOwnership|grantRole|changeAdmin)\([^']*\)'\s*,\s*\(?[^)]*\bagg\b", text):
                bad.append(f"{path}: {m.group(1)}(... agg ...)")
            for m in re.finditer(r"deploy\('[^']+',\s*'(\w+)',\s*'c\([^']*\)',\s*\(([^)]*)\)", text):
                args = [a.strip() for a in m.group(2).split(",")]
                for i, a in enumerate(args):
                    if a == "agg":
                        bad += ctor_param_check(path, m.group(1), i)
    return bad


def ctor_param_check(path, name, index):
    if name in EXTERNAL_CTOR_ARGS:
        return []
    abi_path = ROOT / "abis" / f"{name}.json"
    if not abi_path.exists():
        return [f"{path}: aggregator passed to the constructor of {name}, whose ABI is not in abis/"]
    raw = json.loads(abi_path.read_text())
    abi = raw if isinstance(raw, list) else raw["abi"]
    ctor = next((e for e in abi if e.get("type") == "constructor"), {"inputs": []})
    inputs = ctor.get("inputs", [])
    if index >= len(inputs):
        return [f"{path}: aggregator is constructor arg #{index} of {name}, which has {len(inputs)} inputs"]
    if OWNER_PARAM.search(inputs[index].get("name", "")):
        return [f"{path}: aggregator passed as {name} constructor '{inputs[index]['name']}' (an ownership role)"]
    return []
# Anti-vacuum floor (DSR 2026-11-15): a run that enumerates fewer functions or grants than this
# baseline is a broken scan, not a clean result.
MIN_FUNCTIONS, MIN_GRANTS, MIN_FLAGGED = 111, 13, 26
# Library calls that take the aggregator's address but only CHECK it (fail-closed asserts).
NOT_GRANTS = {"GovernanceOwnerGate"}


def grants():
    found = []
    for path, kind in GRANT_SOURCES.items():
        text = strip_comments((ROOT / path).read_text()) if kind == "sol" else (ROOT / path).read_text()
        if kind == "sol":
            # a statement (not a require/getter) that passes the aggregator's address to a call
            for m in re.finditer(r"^\s*(\w+)\.(\w+)\(\s*address\(aggregator\)", text, re.M):
                if m.group(1) not in NOT_GRANTS:
                    found.append((path, m.group(2)))
        else:
            # call(..., 'setX(address[,..])', (agg|who, ...)) and a.calldata('setX(address)', agg)
            lines = text.splitlines()
            for n, line in enumerate(lines):
                for m in re.finditer(r"'((?:set|init|queue)[A-Z]\w*)\(address[^)]*\)'\s*,\s*\(?\s*(\w+)", line):
                    arg = m.group(2)
                    # `who` counts only when its loop (the line above) iterates over agg (A9)
                    if arg == "agg" or (arg == "who" and n and re.search(r"\bagg\b", lines[n - 1])):
                        found.append((path, m.group(1)))
            # A8 loop: ('suffix', target, 'setter', 'getter') 4-tuples, each called with (agg,)
            for m in re.finditer(r"\('\w+',\s*[\w.]+(?:\['\w+'\])?,\s*'(set[A-Z]\w*)',\s*'\w+'\)", text):
                found.append((path, m.group(1)))
    return found


# Every non-retired deploy/upgrade script, not only the 5.5.0 paths, must not make the aggregator a
# staking slasher (#631 review L2). Retired scripts revert at the top of run().
SLASHER_EXCEPTIONS = {
    "contracts/script/v3/DeployRepCreditSepolia.s.sol":
        "isolated RepCredit paper evidence stack on Sepolia that deploys its OWN Registry, GTokenStaking and "
        "aggregator (not a 5.5.0 deploy path); the grant is require()d to target the staking deployed in the "
        "same run. Its guardian-slash experiments need the role, so on that stack the aggregator holds slash "
        "power and the H-1 denylist is the only defence on the generic path",
}


def slasher_grants_outside_policy():
    bad = []
    for f in sorted(list((ROOT / "contracts/script/v3").glob("*.s.sol")) + list((ROOT / "contracts/script/deployment").glob("*.s.sol"))):
        rel = f.relative_to(ROOT).as_posix()
        text = strip_comments(f.read_text())
        if re.search(r"function run\([^)]*\)[^{]*\{\s*revert\(\s*\"[^\"]*retired", text):
            continue
        for m in re.finditer(r"setAuthorizedSlasher\s*\(\s*([^,]+),\s*true\s*\)", text):
            if not re.search(r"agg|aggregator|bls", m.group(1), re.I):
                continue
            if rel not in SLASHER_EXCEPTIONS:
                bad.append(f"{rel}: setAuthorizedSlasher({m.group(1).strip()}, true) - 5.5.0 grants the aggregator no slasher role")
            elif "slasher grant only on the staking deployed by this run" not in text:
                bad.append(f"{rel}: exception requires the deployed-here require() before the slasher grant")
    return bad


def community_reputation_readers():
    """Reopen condition of the setCommunityReputation allowance: the value must stay unread on-chain."""
    hits = []
    for f in sorted((ROOT / "contracts/src").rglob("*.sol")):
        rel = f.relative_to(ROOT).as_posix()
        for n, line in enumerate(strip_comments(f.read_text()).splitlines(), 1):
            if not re.search(r"\bcommunityReputations\b", line):
                continue
            if rel == "contracts/src/modules/reputation/ReputationSystem.sol" and (
                    "public communityReputations" in line or re.search(r"communityReputations\[\w+\]\[\w+\]\s*=\s*\w+;", line)):
                continue  # the declaration and the single write in setCommunityReputation
            hits.append(f"{rel}:{n}")
    return hits


def main():
    errors = []
    for hit in community_reputation_readers():
        errors.append(f"{hit} reads communityReputations: block setCommunityReputation on the generic path "
                      "or move the gate into ReputationSystem before adding a reader")
    granted = grants()
    if len(granted) < MIN_GRANTS:
        errors.append(f"only {len(granted)} aggregator grants found in deploy paths (baseline {MIN_GRANTS}): scan broken")
    for path, setter in granted:
        if setter not in SETTERS:
            errors.append(f"{path}: {setter}(aggregator) grants an identity this check does not know")
            continue
        ident, where = SETTERS[setter]
        if ident is None and where not in EXTERNAL:
            errors.append(f"{path}: {setter} targets {where}, which is neither in TARGETS nor in EXTERNAL")
        elif ident is not None and not all(IDENTITY.search(i) for i in ident.split(" / ")):
            errors.append(f"{path}: {setter} writes {ident}, which is not in IDENTITY")
        elif ident is not None and not all(w.strip() in TARGETS for w in where.split(",")):
            errors.append(f"{path}: {setter} lives on {where}, not all in TARGETS")
    errors += ownership_violations()
    errors += slasher_grants_outside_policy()
    enumerated = flagged_total = 0
    deny = denylist()
    blocked_all = set()
    for name, (abi_path, sources) in TARGETS.items():
        raw = json.loads((ROOT / abi_path).read_text())
        abi = raw if isinstance(raw, list) else raw["abi"]
        fns = {sig(e) for e in abi if e.get("type") == "function"
               and e.get("stateMutability") not in ("view", "pure")}
        enumerated += len(fns)
        flagged = privileged_names(sources)
        table = CLASSIFIED[name]
        flagged_total += sum(1 for f in fns if f.split("(")[0] in flagged)
        for s in sorted(fns):
            if s.split("(")[0] in flagged and s not in table:
                errors.append(f"{name}: {s} references an aggregator identity but is not classified")
        for s, verdict in table.items():
            if s not in fns:
                errors.append(f"{name}: classified {s} is not in {abi_path}")
            if verdict == "blocked":
                blocked_all.add(s)
            elif not verdict.startswith("allowed: ") or len(verdict) < 20:
                errors.append(f"{name}: {s} needs 'blocked' or 'allowed: <reason>'")
    if flagged_total < MIN_FLAGGED:
        errors.append(f"only {flagged_total} identity-referencing functions flagged (baseline {MIN_FLAGGED}): scan broken")
    if enumerated < MIN_FUNCTIONS:
        errors.append(f"only {enumerated} non-view functions enumerated (baseline {MIN_FUNCTIONS}): scan broken")
    for s in sorted(blocked_all - deny):
        errors.append(f"classified blocked but missing from the H-1 denylist: {s}")
    for s in sorted(deny - blocked_all):
        errors.append(f"in the H-1 denylist but not classified blocked: {s}")
    if errors:
        print("\n".join("FAIL: " + e for e in errors))
        return 1
    print(f"OK: generic-path selector coverage — {enumerated} functions enumerated, {len(deny)} blocked, "
          f"{sum(1 for t in CLASSIFIED.values() for v in t.values() if v != 'blocked')} allowed with reasons, "
          f"{len(granted)} aggregator grants in deploy paths all mapped, {flagged_total} identity-referencing functions flagged")
    return 0


if __name__ == "__main__":
    sys.exit(main())
