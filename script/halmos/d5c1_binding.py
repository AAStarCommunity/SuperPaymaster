#!/usr/bin/env python3
"""D5c-1 — evidence binding: what a log was produced FROM.

binding(family) -> {family, src_sha, src_files, lib_sha, harness_sha, bytecode_sha, out_stale,
                    dirty_src, git_head}
  src_files    sha256 of every contracts/src file in the tested contracts' source set = the
               hand-listed set below UNION every contracts/src file in the compiler metadata of the
               tested artifacts (their import closure), so an import the list forgot is still bound
  src_sha      sha256 over (path, bytes) of those files
  lib_sha      sha256 over (path, bytes) of the non-contracts/src files of that import closure
               (OpenZeppelin etc.)
  harness_sha  sha256 over the Halmos harness / helper files the checks are compiled from (hand list
               UNION the contracts/test files in the harness artifacts' import closure)
  bytecode_sha sha256 over the default-profile runtime bytecode (out/<X>.sol/<X>.json) of the tested
               contracts — i.e. what the build that ran actually produced (a run writes the binding
               AFTER its halmos/forge build, as a `# binding:` trailer line)
  out_stale    closure files whose current keccak256 differs from the one the compiler recorded in
               the artifact metadata ([] = out/ is the build of the current sources)
  dirty_src    `git status --porcelain contracts/src` line count (-1 when there is no git, e.g. the
               scratch copy used for mutations)
  harness_contract / harness_artifact_sha   (only when a contract is named: `line(fam, contract=C)`)
               sha256 of the CREATION bytecode of the harness contract C in out/ — the code Halmos
               deployed and executed (it embeds the tested contracts' creation code, see
               artifact-parity.py), so a log is bound to the exact harness build that produced it
  harness_artifacts (only with `all_artifacts=True`): the same hash for every harness contract
Families: `xpnts` (xPNTs v2 checks, rate invariant, lemma M) and `apnts` (CAP-1).

PROFILES is the ONE definition of the Halmos argument sets: the runners launch with exactly these
arguments and verify-d5c1.py requires each log's recorded argument list to equal the one expected
for its item (`--early-exit` only on expected-FAIL items).

The partition generator (partition_specs) also lives here: run-partitioned.py launches exactly
these partitions and verify-d5c1.py expects exactly these logs, both from the current build ABI.

CLI: python3 script/halmos/d5c1_binding.py <family> [--line] [--contract C] [--all-artifacts]
     (--line prints `# binding: {json}`)
"""
import hashlib
import json
import os
import subprocess
import sys

FAMILIES = {
    "xpnts": {
        "src": ["contracts/src/tokens/v2", "contracts/src/interfaces/IERC1363.sol",
                "contracts/src/interfaces/IVersioned.sol", "contracts/src/interfaces/v3/IRegistry.sol"],
        "artifacts": [("xPNTsTokenV2.sol", "xPNTsTokenV2"), ("xPNTsTokenV2Ext.sol", "xPNTsTokenV2Ext"),
                      ("AOAProtocolRegistry.sol", "AOAProtocolRegistry"), ("xPNTsFactoryV2.sol", "xPNTsFactoryV2"),
                      ("GlobalTierSource.sol", "GlobalTierSource")],
    },
    "apnts": {
        "src": ["contracts/src/tokens/APNTsCapped.sol", "contracts/src/interfaces/IERC1363.sol",
                "contracts/src/interfaces/IVersioned.sol"],
        "artifacts": [("APNTsCapped.sol", "APNTsCapped")],
    },
}
HARNESS = ["contracts/test/halmos", "contracts/test/helpers/V2TokenDeployer.sol",
           "contracts/test/helpers/V2TestFixtures.sol"]
HARNESS_ARTIFACT_DIRS = ["XPNTsV2Halmos.t.sol", "APNTsCappedHalmos.t.sol", "MintRepayLemma.t.sol",
                         "XPNTsV2HalmosProbe.sol", "D5c1Replay.t.sol", "D5c1BoundedFuzz.t.sol"]

# Halmos argument profiles (everything after `halmos --contract C [--function F] [--match-test M]
# --panic-error-codes '*'`). `<name>-fail` = the same + --early-exit (expected-FAIL items only:
# witnesses, negative controls, spec-vs-code discrepancies, mutations).
_XP = ["--loop", "2", "--default-bytes-lengths", "0,65", "--statistics", "--solver-timeout-assertion", "300000"]
PROFILES = {
    "xp": _XP,
    "lemma": ["--loop", "2", "--statistics", "--solver-timeout-assertion", "540000"],
    "cap1": ["--loop", "2", "--default-bytes-lengths", "0,65,1024", "--statistics", "--solver-timeout-assertion", "300000"],
}
for _k in list(PROFILES):
    PROFILES[_k + "-fail"] = PROFILES[_k] + ["--early-exit"]
WALL_CAP_S = 600   # hard wall-clock cap per partition / per unpartitioned run


def halmos_argv(contract, profile, function=None, match_test=None):
    """The canonical argument list (after the `halmos` executable) for one run."""
    return (["--contract", contract] + (["--function", function] if function else [])
            + (["--match-test", match_test] if match_test else []) + ["--panic-error-codes", "*"]
            + PROFILES[profile])


def family_of(contract_or_name):
    return "apnts" if contract_or_name.startswith("APNTsCapped") else "xpnts"


def _files(paths, root):
    out = []
    for p in paths:
        ap = os.path.join(root, p)
        if os.path.isdir(ap):
            for d, _, fs in os.walk(ap):
                out += [os.path.relpath(os.path.join(d, f), root) for f in fs if f.endswith(".sol")]
        elif os.path.exists(ap):
            out.append(p)
    return sorted(set(out))


def _sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def tree_sha(files, root="."):
    """files: a list of repo-relative paths (a directory entry is expanded to its .sol files)."""
    h = hashlib.sha256()
    for f in _files(files, root):
        h.update(f.encode() + b"\0")
        h.update(open(os.path.join(root, f), "rb").read())
        h.update(b"\0")
    return h.hexdigest()


def _meta_sources(path):
    try:
        d = json.load(open(path))
    except Exception:
        return {}
    m = d.get("metadata")
    if not isinstance(m, dict):
        try:
            m = json.loads(d.get("rawMetadata") or "{}")
        except Exception:
            m = {}
    return {k: v.get("keccak256") for k, v in (m.get("sources") or {}).items()}


def closure(family, root="."):
    """path -> keccak256 recorded by the compiler, over the tested artifacts of `family`."""
    out = {}
    for fn, name in FAMILIES[family]["artifacts"]:
        out.update(_meta_sources(os.path.join(root, "out", fn, f"{name}.json")))
    return out


def harness_closure(root="."):
    out = {}
    for dn in HARNESS_ARTIFACT_DIRS:
        d = os.path.join(root, "out", dn)
        if os.path.isdir(d):
            for fn in sorted(os.listdir(d)):
                if fn.endswith(".json"):
                    out.update(_meta_sources(os.path.join(d, fn)))
    return out


def src_list(family, root="."):
    c = closure(family, root)
    return sorted(set(_files(FAMILIES[family]["src"], root)) |
                  {p for p in c if p.startswith("contracts/src/") and os.path.exists(os.path.join(root, p))})


def lib_list(family, root="."):
    return sorted(p for p in closure(family, root) if not p.startswith("contracts/"))


def harness_list(root="."):
    return sorted(set(_files(HARNESS, root)) |
                  {p for p in harness_closure(root) if p.startswith("contracts/test/")
                   and os.path.exists(os.path.join(root, p))})


def _keccak(b):
    try:
        from Crypto.Hash import keccak  # pycryptodome
        k = keccak.new(digest_bits=256)
        k.update(b)
        return k.hexdigest()
    except ImportError:
        from eth_hash.auto import keccak as ek  # noqa: PLC0415
        return ek(b).hex()


def out_stale(family, root="."):
    """closure files whose content no longer matches the keccak256 in the artifact metadata."""
    c = closure(family, root)
    if not c:
        return ["<no artifact metadata in out/>"]
    bad = []
    for p, k in sorted(c.items()):
        ap = os.path.join(root, p)
        if not os.path.exists(ap):
            bad.append(p + " (missing)")
        elif k and "0x" + _keccak(open(ap, "rb").read()) != k:
            bad.append(p)
    return bad


def bytecode_sha(family, root="."):
    h = hashlib.sha256()
    for fn, name in FAMILIES[family]["artifacts"]:
        p = os.path.join(root, "out", fn, f"{name}.json")
        code = json.load(open(p))["deployedBytecode"]["object"] if os.path.exists(p) else "MISSING"
        h.update(f"{fn}:{name}:{code}".encode())
    return h.hexdigest()


def dirty_src(root="."):
    try:
        o = subprocess.check_output(["git", "status", "--porcelain", "contracts/src"], cwd=root,
                                    stderr=subprocess.DEVNULL).decode()
        return len([l for l in o.splitlines() if l.strip()])
    except Exception:
        return -1


def git_head(root="."):
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return "<no git>"


def _t(inp):
    t = inp["type"]
    if t.startswith("tuple"):
        return "(" + ",".join(_t(c) for c in inp["components"]) + ")" + t[len("tuple"):]
    return t


def partition_specs(abi_name, out_dir="out"):
    """[(D5C1_PART, label)]: OTHER (part 1) + one partition per non-view function of `abi_name`
    (label `<name>-<selector>`, part = the selector as an int), read from the current build artifact.
    The single generator of the partition set: the runner launches these, verify expects these."""
    d = json.load(open(os.path.join(out_dir, f"{abi_name}.sol", f"{abi_name}.json")))
    out = []
    for sig, sel in d["methodIdentifiers"].items():
        name = sig.split("(")[0]
        f = next(f for f in d["abi"] if f["type"] == "function" and f["name"] == name
                 and "(" + ",".join(_t(i) for i in f["inputs"]) + ")" == sig[len(name):])
        if f["stateMutability"] not in ("view", "pure"):
            out.append((int(sel, 16), f"{name}-{sel}"))
    return [(1, "OTHER")] + sorted(out, key=lambda x: x[1])


def partition_labels(abi_name, out_dir="out"):
    return sorted(l for _, l in partition_specs(abi_name, out_dir))


def harness_artifacts(root="."):
    """contract -> sha256 of its creation bytecode, over every harness artifact in out/. A contract
    name that occurs in two harness artifact dirs maps to None (ambiguous; never matches)."""
    out = {}
    for dn in HARNESS_ARTIFACT_DIRS:
        d = os.path.join(root, "out", dn)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".json") or fn.count(".") != 1:
                continue   # skip profile-suffixed duplicates such as X.registry-size.json
            try:
                code = json.load(open(os.path.join(d, fn)))["bytecode"]["object"]
            except Exception:
                continue
            c = fn[:-5]
            h = hashlib.sha256(code.encode()).hexdigest()
            out[c] = None if c in out and out[c] != h else h
    return out


def binding(family, root=".", contract=None, all_artifacts=False):
    srcs = src_list(family, root)
    b = {"family": family, "src_sha": tree_sha(srcs, root),
         "src_files": {p: _sha(os.path.join(root, p)) for p in srcs},
         "lib_sha": tree_sha(lib_list(family, root), root),
         "harness_sha": tree_sha(harness_list(root), root), "bytecode_sha": bytecode_sha(family, root),
         "out_stale": out_stale(family, root), "dirty_src": dirty_src(root), "git_head": git_head(root)}
    if contract or all_artifacts:
        arts = harness_artifacts(root)
        if contract:
            b["harness_contract"] = contract
            b["harness_artifact_sha"] = arts.get(contract)
        if all_artifacts:
            b["harness_artifacts"] = arts
    return b


def line(family, root=".", contract=None, all_artifacts=False):
    return "# binding: " + json.dumps(binding(family, root, contract, all_artifacts), sort_keys=True)


def meta_line(**kw):
    """`# meta: {json}` — what a run WAS (runner, contract, check, abi, partition, argv, cap), written
    by the runner before it starts Halmos, from the same values it launches with."""
    return "# meta: " + json.dumps(kw, sort_keys=True)


if __name__ == "__main__":
    fam = sys.argv[1]
    c = sys.argv[sys.argv.index("--contract") + 1] if "--contract" in sys.argv else None
    alla = "--all-artifacts" in sys.argv
    print(line(fam, ".", c, alla) if "--line" in sys.argv else json.dumps(binding(fam, ".", c, alla), indent=1, sort_keys=True))
