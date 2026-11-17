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
  - GTokenStaking: authorizedSlashers. 5.5.0 grants NONE to the aggregator
    (DeployLive.s.sol, "Slasher authorization"); kept here so a future grant is covered.
  - DVTValidator: BLS_AGGREGATOR (setBLSAggregator)

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
            "increasing updatedAt and +-20% bands against the cache and Chainlink",
        "initBLSAggregator(address)": "allowed: onlyOwner; the aggregator is not the SP owner",
        "applyBLSAggregator()": "allowed: onlyOwner; the aggregator is not the SP owner",
        "queueBLSAggregator(address)": "allowed: onlyOwner; the aggregator is not the SP owner",
        "slashOperator(address,uint8,uint256,string)":
            "allowed: onlyOwner (shares _slash with the BLS path); the aggregator is not the SP owner",
        "slashOperatorAfterReleasing(address,uint8,uint256,string,bytes32[])":
            "allowed: onlyOwner (shares _slash with the BLS path); the aggregator is not the SP owner",
    },
    "Registry": {
        "batchUpdateGlobalReputation(uint256,address[],uint256[],uint256,bytes)": "blocked",
        "markProposalExecuted(uint256)": "blocked",
        "updateOperatorBlacklist(address,address[],bool[],bytes)":
            "allowed: own BLS proof at defaultThreshold over a monotonic blacklistNonce; disclosed residual: a "
            "pre-rotation proof for the next unused nonce stays valid (blocks/unblocks users, moves no funds)",
        "setBLSAggregator(address)": "allowed: onlyOwner; the aggregator is not the Registry owner",
        "setReputationSource(address,bool)": "allowed: onlyOwner; the aggregator is not the Registry owner",
        "exitRole(bytes32)": "allowed: outbound call to the aggregator (consumeGuardianExit), keyed to msg.sender",
        "initialize(address,address,address)": "allowed: initializer, already consumed on the live proxy",
    },
    "GTokenStaking": {
        "slash(address,uint256,string)": "blocked",
        "slashByDVT(address,bytes32,uint256,string)": "blocked",
        "setAuthorizedSlasher(address,bool)": "allowed: onlyOwner; the aggregator is not the staking owner",
    },
    "DVTValidator": {
        "markProposalExecuted(uint256)": "blocked",
        "setBLSAggregator(address)": "allowed: onlyOwner; the aggregator is not the DVT owner",
        "createProposal(address,uint8,string)":
            "allowed: _requireActiveValidator(msg.sender); the aggregator is never a DVT validator",
        "createProposal(address,uint8,string,bytes32)":
            "allowed: _requireActiveValidator(msg.sender); the aggregator is never a DVT validator",
        "queueSlashWithProof(address,uint8,uint256,bytes)":
            "allowed: _requireActiveValidator(msg.sender); the aggregator is never a DVT validator",
        "executeWithProof(uint256,address[],uint256[],uint256,bytes)":
            "allowed: the aggregator passes onlyAuthorizedExecutor but the call re-enters "
            "BLSAggregator.verifyAndExecute, which is nonReentrant (executeProposal holds the lock)",
        "registerBLSPublicKey(address,(bytes32,bytes32,bytes32,bytes32),uint8,"
        "(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32))":
            "allowed: non-owner path requires msg.sender == validator plus role/stake eligibility and a PoP",
        "removeValidator(address)": "allowed: onlyOwner; the aggregator is not the DVT owner",
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


def main():
    errors = []
    deny = denylist()
    blocked_all = set()
    for name, (abi_path, sources) in TARGETS.items():
        raw = json.loads((ROOT / abi_path).read_text())
        abi = raw if isinstance(raw, list) else raw["abi"]
        fns = {sig(e) for e in abi if e.get("type") == "function"
               and e.get("stateMutability") not in ("view", "pure")}
        flagged = privileged_names(sources)
        table = CLASSIFIED[name]
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
    for s in sorted(blocked_all - deny):
        errors.append(f"classified blocked but missing from the H-1 denylist: {s}")
    for s in sorted(deny - blocked_all):
        errors.append(f"in the H-1 denylist but not classified blocked: {s}")
    if errors:
        print("\n".join("FAIL: " + e for e in errors))
        return 1
    print(f"OK: generic-path selector coverage — {len(deny)} blocked, "
          f"{sum(1 for t in CLASSIFIED.values() for v in t.values() if v != 'blocked')} allowed with reasons")
    return 0


if __name__ == "__main__":
    sys.exit(main())
