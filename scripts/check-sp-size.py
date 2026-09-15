#!/usr/bin/env python3
"""Release size gate (D5b-design §1 / §2 item 7; spec 03 §5 and §10.7b GOV-2/GOV-5).

`forge build --sizes` only enforces the hard EIP-170 limit (24,576 B), so "all tests green but the
next fix no longer fits" went unnoticed. This gate reads the profile.default artifacts in out/ and
fails unless:
  1. the SuperPaymaster CORE runtime leaves >= 1,024 B of EIP-170 headroom (release gate, spec §5:
     "runtime <= 24,576 - 1,024");
  2. every listed deployable (SP core, SuperPaymasterAdmin extension, Registry, lens, BLSAggregator,
     xPNTs v2 core/extension) is <= 24,576 B.
It only accepts an artifact whose OWN metadata is the [profile.default] build of the CURRENT source
(solc 0.8.33, optimizer on, runs 500 — Registry 200 via compilation_restrictions — viaIR, evm cancun,
source keccak256 == the file on disk); a stale or Prague artifact is refused, never measured.

Usage: forge build && python3 scripts/check-sp-size.py [--self-test]
"""
import glob
import json
import os
import sys

try:
    from Crypto.Hash import keccak as _k  # pycryptodome

    def keccak(b):
        h = _k.new(digest_bits=256)
        h.update(b)
        return "0x" + h.hexdigest()
except ImportError:  # pragma: no cover - CI fallback
    try:
        import sha3  # pysha3

        def keccak(b):
            return "0x" + sha3.keccak_256(b).hexdigest()
    except ImportError:
        keccak = None

EIP170 = 24_576
SP_HEADROOM_MIN = 1_024
V3 = "contracts/src/paymasters/superpaymaster/v3/"
TARGETS = [  # (contract, source, optimizer runs)
    ("SuperPaymaster", V3 + "SuperPaymaster.sol", 500),
    ("SuperPaymasterAdmin", V3 + "SuperPaymasterAdmin.sol", 500),
    ("SuperPaymasterLens", V3 + "SuperPaymasterLens.sol", 500),
    ("Registry", "contracts/src/core/Registry.sol", 200),
    ("BLSAggregator", "contracts/src/modules/monitoring/BLSAggregator.sol", 500),
    ("xPNTsTokenV2", "contracts/src/tokens/v2/xPNTsTokenV2.sol", 500),
    ("xPNTsTokenV2Ext", "contracts/src/tokens/v2/xPNTsTokenV2Ext.sol", 500),
]


def default_artifact(name, src, runs):
    """The unique out/ artifact of `name` that is the profile.default build of `src` as it is now."""
    base = os.path.basename(src)
    cands = sorted(set(glob.glob(f"out/**/{base}/{name}.json", recursive=True)
                       + glob.glob(f"out/**/{base}/{name}.default.json", recursive=True)))
    want_src = None
    if keccak is not None:
        want_src = keccak(open(src, "rb").read())
    found = {}
    for p in cands:
        d = json.load(open(p))
        m = d.get("metadata") or {}
        s = m.get("settings", {})
        if src not in s.get("compilationTarget", {}):
            continue
        if (s.get("optimizer", {}).get("enabled") is not True or s.get("optimizer", {}).get("runs") != runs
                or s.get("viaIR") is not True or s.get("evmVersion") != "cancun"
                or not m.get("compiler", {}).get("version", "").startswith("0.8.33+")):
            continue
        if want_src is not None and m.get("sources", {}).get(src, {}).get("keccak256") != want_src:
            continue
        rt = d["deployedBytecode"]["object"].removeprefix("0x")
        found[rt] = p
    if len(found) != 1:
        raise SystemExit(f"FAIL: {len(found)} distinct profile.default builds of {name} from {src} "
                         f"(run a plain `forge build`; candidates: {cands})")
    rt, p = next(iter(found.items()))
    return p, len(rt) // 2


def evaluate(sizes):
    problems = []
    for name, size in sizes.items():
        if size > EIP170:
            problems.append(f"{name}: {size} B > EIP-170 {EIP170}")
    sp = sizes["SuperPaymaster"]
    if EIP170 - sp < SP_HEADROOM_MIN:
        problems.append(f"SuperPaymaster core headroom {EIP170 - sp} B < {SP_HEADROOM_MIN} B (release gate)")
    return problems


def main():
    if keccak is None:
        print("WARN: no keccak implementation (pip install pycryptodome); source-hash match NOT checked")
    sizes = {}
    for name, src, runs in TARGETS:
        p, n = default_artifact(name, src, runs)
        sizes[name] = n
        print(f"  {name:22s} {n:6d} B  headroom {EIP170 - n:6d}  ({p})")
    if "--self-test" in sys.argv:
        for bad, why in [({**sizes, "SuperPaymaster": EIP170 - SP_HEADROOM_MIN + 1}, "headroom 1,023"),
                         ({**sizes, "SuperPaymasterAdmin": EIP170 + 1}, "extension over EIP-170")]:
            if not evaluate(bad):
                print(f"SELF-TEST FAILED: {why} was accepted")
                sys.exit(2)
        if evaluate({**sizes, "SuperPaymaster": EIP170 - SP_HEADROOM_MIN}):
            print("SELF-TEST FAILED: exactly 1,024 B of headroom was rejected")
            sys.exit(2)
        print("self-test ok: headroom 1,023 and an over-limit extension are rejected; exactly 1,024 passes")
    problems = evaluate(sizes)
    if problems:
        print("SIZE GATE FAILED:")
        for pr in problems:
            print("  ", pr)
        sys.exit(1)
    print(f"OK: SuperPaymaster core headroom {EIP170 - sizes['SuperPaymaster']} B >= {SP_HEADROOM_MIN}; "
          f"all {len(sizes)} deployables <= EIP-170")


if __name__ == "__main__":
    main()
