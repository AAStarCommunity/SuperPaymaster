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
Limits (stated, #633 review): this is a source-text scan. It recognizes the spellings used today
(the aggregator variable and local aliases of it, encodeCall payloads, multi-line calls, internal
helper parameters, receivers mapped in RECEIVERS) - it is NOT a general guarantee. A grant written
some other way, gates in base classes or external callbacks, and contracts outside TARGETS can
escape it. The general guarantee is the state-based step-13 readback (OWNER-NOT-AGGREGATOR,
authorizedSlashers(aggregator) == false, the reputation-source set, AGG-ZERO-BALANCES), which does
not depend on how a deploy script is written. The ABIs come from abis/, which PR-B's ABI gate keeps
equal to a fresh build.

Fails on: an unclassified identity-referencing selector, a CLASSIFIED entry that no longer
exists in the ABI, a "blocked" entry missing from the denylist, or a denylist entry not
classified "blocked".
"""
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("COVERAGE_CHECK_ROOT") or Path(__file__).resolve().parent.parent)
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
        "queueSlashWithProof(address,uint8,uint256,bytes,bytes)":
            "allowed: _requireActiveValidator(msg.sender); the aggregator is never a DVT validator [guaranteed by step-13 readback AGG-NOT-DVT-VALIDATOR: no ROLE_DVT, not a registered validator]",
        "executeWithProof(uint256,address[],uint256[],uint256,bytes,bytes)":
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


# Trust root, derived rather than hand-written: every call a deploy path makes with the
# aggregator's address must be a known setter, on a receiver known to be the contract that setter
# lives on, writing an identity in IDENTITY (or an EXTERNAL target with a reason).
GRANT_SOURCES = {
    "contracts/script/v3/DeployLive.s.sol": "sol",
    "contracts/script/v3/DeployAnvil.s.sol": "sol",
    "contracts/script/v3/V54Bootstrap.sol": "sol",
    "contracts/script/v3/V55Bootstrap.sol": "sol",
    "script/upgrade/manifest_exec.py": "py",
}
SETTERS = {  # setter -> (identity it writes, contract(s) it lives on)
    "setBLSAggregator": ("blsAggregator / BLS_AGGREGATOR", "Registry, DVTValidator"),
    "initBLSAggregator": ("BLS_AGGREGATOR", "SuperPaymaster"),
    "queueBLSAggregator": ("BLS_AGGREGATOR", "SuperPaymaster"),
    "setReputationSource": ("isReputationSource", "Registry"),
    "setAuthorizedSlasher": ("authorizedSlashers", "GTokenStaking"),
    "setBlsAggregator": (None, "committee"),
}
# Receiver expressions (as written in the deploy paths) -> the contract they hold. A known setter
# called on any other receiver fails: the grant's destination is checked, not just its name.
RECEIVERS = {
    "registry": "Registry", "u.REG": "Registry",
    "dvt": "DVTValidator", "d['dvt']": "DVTValidator",
    "superPaymaster": "SuperPaymaster", "u.SP": "SuperPaymaster",
    "staking": "GTokenStaking",
    "d['committee']": "committee",
}
EXTERNAL = {
    "committee": "DVT repo AAStarCommitteeValidator (manifest_exec COMMITTEE); ABI not compiled here. DVT "
                 "8bbac708 review (2026-11-15): no state-changing function gated on msg.sender == aggregator; "
                 "setBlsAggregator is onlyOwner; generic-reachable functions only touch the caller's own entry",
}
# The aggregator must never become an owner/admin: every onlyOwner function of that contract would
# fall into the generic path. Arguments that pass the aggregator are allowed only where the
# parameter (constructor or internal helper) is not an ownership role.
OWNER_PARAM = re.compile(r"owner|admin|governor|governance|proposer|executor|guardian", re.I)
OWNERSHIP_CALLS = r"transferOwnership|grantRole|changeAdmin|setPendingOwner|_transferOwnership|_grantRole"
EXTERNAL_CTOR_ARGS = {
    "OverIssueFraudProofVerifier": "DVT repo verifier, constructor (aggregator, registry) binds its domain; "
                                   "the aggregator gets no role on it",
}
# Anti-vacuum floor (DSR 2026-11-15): a run that enumerates fewer functions or grants than this
# baseline is a broken scan, not a clean result.
MIN_FUNCTIONS, MIN_GRANTS, MIN_FLAGGED = 111, 13, 26
# Library calls that take the aggregator's address but only CHECK it (fail-closed asserts).
NOT_GRANTS = {"GovernanceOwnerGate"}
SOL_AGG = ("aggregator", "agg", "blsAggregator")


def split_args(text):
    """Top-level comma split of an argument list (nested parens/brackets kept together)."""
    out, depth, cur = [], 0, ""
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def call_args(text, open_paren):
    """Argument text of the call whose '(' is at text[open_paren]."""
    depth, k = 0, open_paren
    while k < len(text):
        depth += {"(": 1, ")": -1}.get(text[k], 0)
        if depth == 0:
            return text[open_paren + 1:k]
        k += 1
    return ""


def agg_names(text, kind):
    """The aggregator's own names plus every local alias assigned from it."""
    names = set(SOL_AGG) if kind == "sol" else {"agg"}
    changed = True
    while changed:
        changed = False
        pat = "|".join(map(re.escape, names))
        rx = (rf"\baddress\s+(\w+)\s*=\s*(?:address\(\s*)?(?:{pat})\b" if kind == "sol"
              else rf"^\s*(\w+)\s*=\s*(?:{pat})\s*$")
        for m in re.finditer(rx, text, re.M):
            if m.group(1) not in names:
                names.add(m.group(1))
                changed = True
    return names


def is_agg(arg, names):
    a = re.sub(r"\s+", "", arg)
    for n in names:
        if a == n or a == f"address({n})" or re.fullmatch(rf"I?\w*\(address\({re.escape(n)}\)\)", a) \
                or re.fullmatch(rf"address\(I?\w*\({re.escape(n)}\)\)", a):
            return True
    return False


def sol_calls(text):
    """(receiver or None, function name, [args]) for every call in a comments-stripped Solidity text,
    including abi.encodeCall(X.f, (args)) payloads."""
    out = []
    # String literals are not code: keep bare identifiers ("SuperPaymaster" for _deployDefault), blank the rest.
    text = re.sub(r'"([^"\\\n]*)"', lambda m: m.group(0) if re.fullmatch(r"\w*", m.group(1)) else '""', text)
    for m in re.finditer(r"(?:\b([\w.\[\]()]+?)\s*\.\s*)?\b(\w+)\s*\(", text):
        name = m.group(2)
        if name in ("if", "for", "while", "require", "revert", "return", "emit", "function", "modifier",
                    "keccak256", "abi", "encode", "encodePacked", "encodeWithSignature", "encodeWithSelector"):
            continue
        args = split_args(call_args(text, m.end() - 1))
        if name == "encodeCall" and len(args) == 2:
            tgt = re.sub(r"\s+", "", args[0])
            inner = args[1].strip()
            inner = inner[1:-1] if inner.startswith("(") and inner.endswith(")") else inner
            rcv, _, fn = tgt.rpartition(".")
            out.append((None, fn, split_args(inner)))  # receiver of an encoded call is not provable
            continue
        recv = m.group(1)
        if recv:
            recv = re.sub(r"^(?:I\w+|\w+)\((?:address\()?(\w+)\)?\)$", r"\1", recv)
        out.append((recv, name, args))
    return out


def internal_params(texts):
    """name -> parameter names, for internal/private functions defined in the scanned sources."""
    params = {}
    for text in texts:
        for m in re.finditer(r"function\s+(\w+)\s*\(([^)]*)\)\s*(?:internal|private)", text):
            names = [p.split()[-1] for p in split_args(m.group(2)) if p.split()]
            params[m.group(1)] = names
    return params


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


def _sources():
    out = []
    for path, kind in GRANT_SOURCES.items():
        raw = (ROOT / path).read_text()
        out.append((path, kind, strip_comments(raw) if kind == "sol" else raw))
    return out


def ownership_violations():
    bad = []
    srcs = _sources()
    helpers = internal_params([t for _, k, t in srcs if k == "sol"])
    for path, kind, text in srcs:
        names = agg_names(text, kind)
        if kind == "sol":
            for recv, fn, args in sol_calls(text):
                if fn == "_deployDefault" and len(args) == 2:
                    # constructor args sit inside abi.encode(...), one level down
                    cname = args[0].strip().strip('"')
                    inner = re.match(r"abi\.encode\((.*)\)$", args[1].strip(), re.S)
                    for i, a in enumerate(split_args(inner.group(1)) if inner else []):
                        if is_agg(a, names):
                            bad += ctor_param_check(path, cname, i)
                    continue
                if not any(is_agg(a, names) for a in args):
                    continue
                if re.fullmatch(OWNERSHIP_CALLS, fn):
                    bad.append(f"{path}: {fn}(... aggregator ...)")
                elif fn in helpers:
                    for i, a in enumerate(args):
                        if is_agg(a, names) and i < len(helpers[fn]) and OWNER_PARAM.search(helpers[fn][i]):
                            bad.append(f"{path}: aggregator passed to {fn}() as '{helpers[fn][i]}' (an ownership role)")
        else:
            for m in re.finditer(rf"'({OWNERSHIP_CALLS})\([^']*\)'\s*,\s*\(?([^)]*)\)?", text, re.S):
                if any(is_agg(a, names) for a in split_args(m.group(2))):
                    bad.append(f"{path}: {m.group(1)}(... agg ...)")
            for m in re.finditer(r"deploy\(\s*'[^']+',\s*'(\w+)',\s*'c\([^']*\)',\s*\(([^)]*)\)", text, re.S):
                for i, a in enumerate(split_args(m.group(2))):
                    if is_agg(a, names):
                        bad += ctor_param_check(path, m.group(1), i)
    return bad


def grants():
    """(path, receiver or None, setter) for every call that passes the aggregator in a deploy path."""
    found = []
    for path, kind, text in _sources():
        names = agg_names(text, kind)
        if kind == "sol":
            for recv, fn, args in sol_calls(text):
                if recv in NOT_GRANTS or fn in ("_deployDefault", "require") or not args:
                    continue
                if any(is_agg(a, names) for a in args) and re.match(r"(set|init|queue|add|grant|approve|transfer)[A-Z]", fn):
                    found.append((path, recv, fn))
        else:
            # call(sid, target, 'setX(address[,..])', (agg|who, ...)) and a.calldata('setX(address)', agg)
            for m in re.finditer(r"call\(\s*[^,]+,\s*([^,]+),\s*'((?:set|init|queue|add|grant)[A-Z]\w*)\([^']*\)'\s*,\s*\(([^)]*)\)", text, re.S):
                args = split_args(m.group(3))
                # `who` is the aggregator only when the enclosing loop header (the nearest preceding
                # `for` line) iterates over agg, as in A9.
                head = text.rfind("\n    for ", 0, m.start())
                loop_line = text[head:text.find("\n", head + 1)] if head >= 0 else ""
                loop_agg = "who" in args and re.search(r"\bwho\b", loop_line) and re.search(r"\bagg\b", loop_line)
                if any(is_agg(a, names) for a in args) or loop_agg:
                    found.append((path, m.group(1).strip(), m.group(2)))
            for m in re.finditer(r"calldata\(\s*'((?:set|init|queue|add|grant)[A-Z]\w*)\([^']*\)'\s*,\s*([^)]*)\)", text, re.S):
                if any(is_agg(a, names) for a in split_args(m.group(2))):
                    found.append((path, "u.SP" if "BLSAggregator" in m.group(1) else None, m.group(1)))
            # A8 loop: ('suffix', target, 'setter', 'getter') 4-tuples, each called with (agg,)
            for m in re.finditer(r"\('\w+',\s*([\w.]+(?:\['\w+'\])?),\s*'(set[A-Z]\w*)',\s*'\w+'\)", text):
                found.append((path, m.group(1), m.group(2)))
    return found


# Every non-retired script under contracts/script (helpers included), not only the 5.5.0 paths,
# must not make the aggregator a staking slasher (#631 review L2). Retired scripts revert at the
# top of run().
SLASHER_EXCEPTIONS = {
    "contracts/script/v3/DeployRepCreditSepolia.s.sol":
        "isolated RepCredit paper evidence stack on Sepolia that deploys its OWN Registry, GTokenStaking and "
        "aggregator (not a 5.5.0 deploy path). No mechanical guarantee that the grant hits that stack's own "
        "staking: it holds because the script reads no staking address from env or config. On that stack the "
        "aggregator holds slash power and the H-1 denylist is the only defence on the generic path",
}


def slasher_grants_outside_policy():
    bad = []
    for f in sorted((ROOT / "contracts/script").rglob("*.sol")):
        rel = f.relative_to(ROOT).as_posix()
        if "/archive/" in rel:
            continue
        text = strip_comments(f.read_text())
        if re.search(r"function run\([^)]*\)[^{]*\{\s*revert\(\s*\"[^\"]*retired", text):
            continue
        names = agg_names(text, "sol") | {"blsAggregator", "bls"}
        for recv, fn, args in sol_calls(text):
            if fn != "setAuthorizedSlasher" or len(args) != 2 or re.sub(r"\s", "", args[1]) != "true":
                continue
            if not is_agg(args[0], names):
                continue
            if rel not in SLASHER_EXCEPTIONS:
                bad.append(f"{rel}: setAuthorizedSlasher({args[0]}, true) - 5.5.0 grants the aggregator no slasher role")
    return bad


def community_reputation_readers():
    """Reopen condition of the setCommunityReputation allowance: the value must stay unread on-chain."""
    hits = []
    decl = re.compile(r"mapping\(address\s*=>\s*mapping\(address\s*=>\s*uint256\)\)\s*public\s+communityReputations\s*;")
    write = re.compile(r"communityReputations\[community\]\[user\]\s*=\s*score\s*;")
    for f in sorted((ROOT / "contracts/src").rglob("*.sol")):
        rel = f.relative_to(ROOT).as_posix()
        text = strip_comments(f.read_text())
        if rel == "contracts/src/modules/reputation/ReputationSystem.sol":
            text = decl.sub(" ", text, count=1)
            text = write.sub(" ", text, count=1)  # only the exact statement, not its whole line
        for n, line in enumerate(text.splitlines(), 1):
            if re.search(r"\bcommunityReputations\b", line):
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
    for path, recv, setter in granted:
        if setter not in SETTERS:
            errors.append(f"{path}: {setter}(aggregator) grants an identity this check does not know")
            continue
        ident, where = SETTERS[setter]
        holder = RECEIVERS.get(recv) if recv else None
        if holder is None:
            errors.append(f"{path}: {setter}(aggregator) on receiver {recv!r}, which is not a known contract")
            continue
        if holder not in [w.strip() for w in where.split(",")]:
            errors.append(f"{path}: {setter}(aggregator) called on {recv} ({holder}), but {setter} lives on {where}")
            continue
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
