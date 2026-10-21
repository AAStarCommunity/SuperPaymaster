#!/usr/bin/env python3
"""Selector routing check for SuperPaymaster (core + DELEGATECALL SuperPaymasterAdmin extension),
plus the GOV-2 override placement rule for SuperPaymaster and Registry (D5b-design §2.1, §5).

The core serves every selector it defines; every other selector falls through its fallback to the
extension. On the compiled artifacts:

  R1  EXT-ONLY ∩ CORE = ∅ — a selector the extension adds (beyond the shared SuperPaymasterStorage
      base) must not also exist in the core, otherwise the core would silently shadow it and the
      extension implementation would be unreachable.
  R2  BASE ⊆ CORE — every public selector of the shared base is served by the core. (Selectors that
      both inherit from the base are expected: through the proxy the core always answers them.)
  R3  HOT PATHS IN CORE — validatePaymasterUserOp, postOp, releaseStaleSponsorship, inflightOf, the
      deposit / withdraw / EntryPoint-stake functions and UUPS (upgradeToAndCall, proxiableUUID) are
      core selectors and NOT extension-only.
  R4  GOV-2 (§2.1) — for SuperPaymaster (core) AND Registry: transferOwnership, acceptOwnership,
      renounceOwnership, pendingOwner are selectors of the contract, and the EFFECTIVE definition of
      each (first implementation along the C3 linearization, read from the compiler AST) — and of the
      internal `_transferOwnership` — is the Ownable2StepNamespaced override, never OZ Ownable's
      single-step one. The effective transferOwnership carries `onlyOwner` (an override does not
      inherit modifiers). None of the four may be extension-only.

Usage: python3 scripts/check-sp-selectors.py [--self-test]
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

FORGE = os.environ.get("FORGE") or shutil.which("forge") or os.path.expanduser("~/.foundry/bin/forge")
V3 = "contracts/src/paymasters/superpaymaster/v3/"
SOURCES = [V3 + "SuperPaymaster.sol", V3 + "SuperPaymasterAdmin.sol", V3 + "SuperPaymasterStorage.sol",
           "contracts/src/core/Registry.sol"]
GOV2 = {"transferOwnership(address)": "transferOwnership", "acceptOwnership()": "acceptOwnership",
        "renounceOwnership()": "renounceOwnership", "pendingOwner()": "pendingOwner"}
GOV2_BASE = "Ownable2StepNamespaced"
HOT = ["validatePaymasterUserOp((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),bytes32,uint256)",
       "postOp(uint8,bytes,uint256,uint256)", "releaseStaleSponsorship(bytes32)", "inflightOf(bytes32)",
       "deposit()", "deposit(uint256)", "depositFor(address,uint256)", "withdraw(uint256)",
       "onTransferReceived(address,address,uint256,bytes)", "addStake(uint32)", "unlockStake()",
       "withdrawStake(address)", "withdrawTo(address,uint256)", "upgradeToAndCall(address,bytes)",
       "proxiableUUID()", "version()", "initialize(address,address,address,uint256)", "EXTENSION()"]


def build():
    """Compile the four sources with ASTs into a scratch out dir (the default out/ is untouched)."""
    tmp = tempfile.mkdtemp(prefix="sp-selectors-")
    r = subprocess.run([FORGE, "build", "--ast", "--out", os.path.join(tmp, "out"),
                        "--cache-path", os.path.join(tmp, "cache")] + SOURCES,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-3000:], r.stderr[-3000:])
        sys.exit(2)
    arts = {}
    contracts = {}
    for f in glob.glob(os.path.join(tmp, "out", "**", "*.json"), recursive=True):
        if "build-info" in f:
            continue
        d = json.load(open(f))
        name = os.path.basename(f).split(".")[0]  # X.json / X.default.json / X.registry-size.json
        src = os.path.basename(os.path.dirname(f))
        arts.setdefault(name, []).append((src, d))
        ast = d.get("ast") or {}
        # AST node ids are only unique within ONE solc invocation and forge splits a build into
        # several (the Registry runs=200 restriction, grouping), so contracts are keyed by NAME and
        # the C3 linearization is recomputed from each contract's declared bases (by name).
        for node in ast.get("nodes", []):
            if node.get("nodeType") == "ContractDefinition":
                fns = {}
                for n in node.get("nodes", []):
                    if n.get("nodeType") == "FunctionDefinition" and n.get("kind") == "function":
                        fns.setdefault(n["name"], []).append({
                            "implemented": n.get("implemented", False),
                            "modifiers": [m["modifierName"].get("name") or m["modifierName"].get("namePath")
                                          for m in n.get("modifiers", [])],
                        })
                bases = [b["baseName"].get("name") or b["baseName"].get("namePath")
                         for b in node.get("baseContracts", [])]
                prev = contracts.get(node["name"])
                if prev is not None and (prev["bases"] != bases or prev["fns"] != fns):
                    raise SystemExit(f"two different contracts named {node['name']} in the closure")
                contracts[node["name"]] = {"name": node["name"], "bases": bases, "fns": fns}
    shutil.rmtree(tmp, ignore_errors=True)
    return arts, contracts


def selectors(arts, name, src):
    for s, d in arts[name]:
        if s == src and d.get("methodIdentifiers"):
            return {sel: sig for sig, sel in d["methodIdentifiers"].items()}
    raise SystemExit(f"artifact {src}:{name} not found")


def linearize(contracts, name, memo=None):
    """Solidity C3 linearization, most derived first: L(C) = C + merge(L(Bn), …, L(B1), [Bn … B1])."""
    memo = {} if memo is None else memo
    if name in memo:
        return memo[name]
    bases = list(reversed(contracts[name]["bases"]))  # right-most base = most derived
    seqs = [list(linearize(contracts, b, memo)) for b in bases] + [bases]
    out = [name]
    while any(seqs):
        for seq in seqs:
            if seq and not any(seq[0] in s[1:] for s in seqs):
                head = seq[0]
                break
        else:
            raise SystemExit(f"C3 linearization failed for {name}")
        out.append(head)
        seqs = [[x for x in s if x != head] for s in seqs]
    memo[name] = out
    return out


def effective(contracts, cname, fn):
    """(defining contract, definition) of the first implemented `fn` along cname's linearization."""
    for cid in linearize(contracts, cname):
        c = contracts[cid]
        for d in c["fns"].get(fn, []):
            if d["implemented"]:
                return c["name"], d
    return None, None


def check(core, ext, base, reg, contracts):
    problems = []
    ext_only = set(ext) - set(base)
    for s in sorted(ext_only & set(core)):
        problems.append(f"R1 shadowed: {ext[s]} ({s}) is in both core and extension")
    for s in sorted(set(base) - set(core)):
        problems.append(f"R2 base selector not served by core: {base[s]} ({s})")
    core_sigs = {v: k for k, v in core.items()}
    ext_only_sigs = {ext[s] for s in ext_only}
    for sig in HOT:
        if sig not in core_sigs:
            problems.append(f"R3 hot-path selector missing from core: {sig}")
        if sig in ext_only_sigs:
            problems.append(f"R3 hot-path selector is extension-only: {sig}")
    for cname, sels in (("SuperPaymaster", core), ("Registry", reg)):
        sigs = set(sels.values())
        for sig, fn in GOV2.items():
            if sig not in sigs:
                problems.append(f"R4 {cname}: GOV-2 selector {sig} missing")
            if cname == "SuperPaymaster" and sig in ext_only_sigs:
                problems.append(f"R4 {cname}: GOV-2 selector {sig} is extension-only (§2.1: dead code)")
            who, d = effective(contracts, cname, fn)
            # EXACTLY the shared base: a local override in the core / Registry is not accepted even with
            # onlyOwner, because a name-level check cannot see its body (Codex D5b review, Low).
            if who != GOV2_BASE:
                problems.append(f"R4 {cname}: effective {fn} is {who}'s, not the {GOV2_BASE} override")
            if fn == "transferOwnership" and d is not None and "onlyOwner" not in d["modifiers"]:
                problems.append(f"R4 {cname}: effective transferOwnership ({who}) lacks onlyOwner")
        who, _ = effective(contracts, cname, "_transferOwnership")
        if who != GOV2_BASE:
            problems.append(f"R4 {cname}: effective _transferOwnership is {who}'s (pending not cleared)")
    return problems, ext_only


def main():
    arts, contracts = build()
    core = selectors(arts, "SuperPaymaster", "SuperPaymaster.sol")
    ext = selectors(arts, "SuperPaymasterAdmin", "SuperPaymasterAdmin.sol")
    base = selectors(arts, "SuperPaymasterStorage", "SuperPaymasterStorage.sol")
    reg = selectors(arts, "Registry", "Registry.sol")
    if "--self-test" in sys.argv:
        import copy
        ext_only = sorted(set(ext) - set(base))
        fake_core = dict(core)
        fake_core[ext_only[0]] = ext[ext_only[0]]
        ok1 = bool(check(base=base, core=fake_core, ext=ext, reg=reg, contracts=contracts)[0])
        # "override only in the extension": the shared base loses its transferOwnership override,
        # so OZ Ownable's single-step one becomes effective in the core (and in Registry).
        c2 = copy.deepcopy(contracts)
        for c in c2.values():
            if c["name"] == GOV2_BASE:
                c["fns"].pop("transferOwnership", None)
        ok2 = bool(check(core, ext, base, reg, c2)[0])
        # override present but without onlyOwner
        c3 = copy.deepcopy(contracts)
        for c in c3.values():
            if c["name"] == GOV2_BASE:
                for d in c["fns"]["transferOwnership"]:
                    d["modifiers"] = []
        ok3 = bool(check(core, ext, base, reg, c3)[0])
        # _transferOwnership not overridden (pending never cleared)
        c4 = copy.deepcopy(contracts)
        for c in c4.values():
            if c["name"] == GOV2_BASE:
                c["fns"].pop("_transferOwnership", None)
        ok4 = bool(check(core, ext, base, reg, c4)[0])
        # a GOV-2 selector served only by the extension
        fake_ext = dict(ext)
        fake_core2 = {k: v for k, v in core.items() if v != "acceptOwnership()"}
        sel = next(k for k, v in core.items() if v == "acceptOwnership()")
        fake_ext[sel] = "acceptOwnership()"
        fake_base = {k: v for k, v in base.items() if k != sel}
        ok5 = bool(check(fake_core2, fake_ext, fake_base, reg, contracts)[0])
        if not (ok1 and ok2 and ok3 and ok4 and ok5):
            print(f"SELF-TEST FAILED: shadow={ok1} ext-only-override={ok2} no-onlyOwner={ok3} "
                  f"no-_transferOwnership={ok4} gov2-in-ext={ok5}")
            sys.exit(2)
        print("self-test ok: shadowing, an override only in the extension, a missing onlyOwner, a missing "
              "_transferOwnership override and a GOV-2 selector served by the extension are all detected")
    problems, ext_only = check(core, ext, base, reg, contracts)
    if problems:
        print("SELECTOR ROUTING / GOV-2 PROBLEMS:")
        for p in problems:
            print("  ", p)
        sys.exit(1)
    who = {fn: effective(contracts, "SuperPaymaster", fn)[0] for fn in list(GOV2.values()) + ["_transferOwnership"]}
    print(f"OK: base {len(base)} ⊆ core {len(core)}; extension-only {len(ext_only)} selectors, none shadowed; "
          f"{len(HOT)} hot-path selectors in core; GOV-2 effective definitions (SP and Registry): {who}")
    print("   C3(SuperPaymaster) =", " > ".join(linearize(contracts, "SuperPaymaster")))
    print("   C3(Registry)       =", " > ".join(linearize(contracts, "Registry")))
    print("   extension-only:", ", ".join(sorted(ext[s] for s in ext_only)))


if __name__ == "__main__":
    main()
