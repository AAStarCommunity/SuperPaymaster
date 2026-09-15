#!/usr/bin/env python3
"""D5c-1 — prove that the bytecode Halmos executed is the [profile.default] build.

Halmos deploys the contracts under test from the creation code EMBEDDED in the harness artifact
(`new X(...)` in setUp). So the question "which compiler settings did Halmos use for X" is
answered by: is X's default-profile creation code (out/X.sol/X.json) a byte-exact substring of the
harness artifact's creation code, and what settings do both artifacts' metadata record?

Negative control: the same search with X's `registry-size` artifact (optimizer_runs 200, the
other compiler profile that shares out/) must NOT match — otherwise the check cannot tell the two
profiles apart.

usage: python3 script/halmos/artifact-parity.py [out_dir]   (run from the repo root)
exit 1 on any mismatch.
"""
import hashlib
import json
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"

# (harness file, harness contract) -> [(source file, contract)]
_TOKEN = [
    ("xPNTsTokenV2.sol", "xPNTsTokenV2"),
    ("xPNTsTokenV2Ext.sol", "xPNTsTokenV2Ext"),
    ("AOAProtocolRegistry.sol", "AOAProtocolRegistry"),
]
PAIRS = {
    ("APNTsCappedHalmos.t.sol", "APNTsCappedHalmosTest"): [("APNTsCapped.sol", "APNTsCapped")],
    ("APNTsCappedHalmos.t.sol", "APNTsCappedWitnessHalmosTest"): [("APNTsCapped.sol", "APNTsCapped")],
    ("XPNTsV2Halmos.t.sol", "XPNTsV2A3HalmosTest"): _TOKEN,
    ("XPNTsV2Halmos.t.sol", "XPNTsV2A3xHalmosTest"): _TOKEN,
    ("XPNTsV2Halmos.t.sol", "XPNTsV2I2HalmosTest"): _TOKEN,
    ("XPNTsV2Halmos.t.sol", "XPNTsV2I2NoRHalmosTest"): _TOKEN,
    ("XPNTsV2Halmos.t.sol", "XPNTsV2I6HalmosTest"): _TOKEN,
    ("XPNTsV2Halmos.t.sol", "XPNTsV2WitnessHalmosTest"): _TOKEN,
    ("XPNTsV2Halmos.t.sol", "XPNTsV2WitnessPinnedHalmosTest"): _TOKEN,
    ("XPNTsV2Halmos.t.sol", "XPNTsV2RateHalmosTest"): _TOKEN + [
        ("xPNTsFactoryV2.sol", "xPNTsFactoryV2"),
        ("GlobalTierSource.sol", "GlobalTierSource"),
    ],
}


def load(path):
    with open(path) as f:
        return json.load(f)


def settings(art):
    md = art.get("metadata")
    if isinstance(md, str):
        md = json.loads(md)
    if not md:
        raw = art.get("rawMetadata")
        md = json.loads(raw) if raw else {}
    s = md.get("settings", {})
    opt = s.get("optimizer", {})
    return {
        "solc": md.get("compiler", {}).get("version"),
        "optimizer": opt.get("enabled"),
        "runs": opt.get("runs"),
        "viaIR": s.get("viaIR"),
        "evmVersion": s.get("evmVersion"),
        "bytecodeHash": s.get("metadata", {}).get("bytecodeHash"),
    }


def code(art, key):
    return art[key]["object"].removeprefix("0x").lower()


def sha(hexstr):
    return hashlib.sha256(bytes.fromhex(hexstr)).hexdigest()


ok = True
for (hfile, hname), targets in PAIRS.items():
    hpath = os.path.join(OUT, hfile, f"{hname}.json")
    h = load(hpath)
    hcode = code(h, "bytecode")
    print(f"harness {hfile}:{hname}  settings={settings(h)}")
    for sfile, cname in targets:
        dpath = os.path.join(OUT, sfile, f"{cname}.json")
        rpath = os.path.join(OUT, sfile, f"{cname}.registry-size.json")
        d = load(dpath)
        dinit = code(d, "bytecode")
        match_default = dinit in hcode
        line = (f"  {cname}: default-artifact settings={settings(d)} "
                f"creation sha256={sha(dinit)} runtime sha256={sha(code(d, 'deployedBytecode'))} "
                f"embedded-in-harness={match_default}")
        if os.path.exists(rpath):
            r = load(rpath)
            rinit = code(r, "bytecode")
            line += (f" | registry-size artifact runs={settings(r)['runs']} "
                     f"identical-to-default={rinit == dinit} embedded-in-harness={rinit in hcode}")
            if rinit != dinit and rinit in hcode:
                ok = False
        s = settings(d)
        if not (match_default and s["runs"] == 500 and s["viaIR"] is True and s["evmVersion"] == "cancun"):
            ok = False
        print(line)

print("RESULT:", "OK" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
