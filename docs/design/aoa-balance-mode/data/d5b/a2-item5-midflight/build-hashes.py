#!/usr/bin/env python3
"""Read-only: collect size + keccak256 of SuperPaymaster / SuperPaymasterAdmin from forge out/ dirs, compare
with the fixtures and with docs/release/v5.5.0-rc.2-attestation.json, and print JSON.

Usage (repo root): python3 build-hashes.py <label>=<outDir> [...]
Needs pycryptodome (Crypto.Hash.keccak). Artifacts have immutables zeroed (runtimeKeccak is an artifact hash).
"""
import json, os, sys
from Crypto.Hash import keccak

FIX = "contracts/test/fixtures"
FIXTURES = {
    "rc.1": f"{FIX}/superpaymaster-5.5.0-rc.1-7ae5b340-impl.creation.hex",
    "rc.2": f"{FIX}/superpaymaster-5.5.0-rc.2-1ac0e1c5-impl.creation.hex",
    "1cb21fe8": f"{FIX}/superpaymaster-5.5.0-impl.creation.hex",
    "c30854f9": f"{FIX}/superpaymaster-5.5.0-c30854f9-impl.creation.hex",
    "rc.1-second": f"{FIX}/superpaymaster-5.5.0-rc.1-7ae5b340-impl.creation.hex",
}


def k(b):
    h = keccak.new(digest_bits=256)
    h.update(b)
    return "0x" + h.hexdigest()


def art(out, n):
    p = f"{out}/{n}.sol/{n}.json"
    if not os.path.exists(p):
        return None
    d = json.load(open(p))
    rt = bytes.fromhex(d["deployedBytecode"]["object"][2:])
    cr = bytes.fromhex(d["bytecode"]["object"][2:])
    st = d.get("metadata", {}).get("settings", {})
    return {
        "runtimeBytes": len(rt), "runtimeKeccak": k(rt), "creationBytes": len(cr), "creationKeccak": k(cr),
        "immutableRefs": len(d["deployedBytecode"].get("immutableReferences") or {}),
        "compiler": d.get("metadata", {}).get("compiler", {}).get("version"),
        "runs": st.get("optimizer", {}).get("runs"), "viaIR": st.get("viaIR"), "evm": st.get("evmVersion"),
    }


att = {c["contract"]: c for c in json.load(open("docs/release/v5.5.0-rc.2-attestation.json"))["contracts"]}
res = {}
for arg in sys.argv[1:]:
    label, out = arg.split("=", 1)
    row = {"SuperPaymaster": art(out, "SuperPaymaster"), "SuperPaymasterAdmin": art(out, "SuperPaymasterAdmin")}
    fx = FIXTURES.get(label)
    if fx:
        fb = bytes.fromhex(open(fx).read().strip().removeprefix("0x"))
        row["fixture"] = {"path": fx, "bytes": len(fb), "keccak": k(fb),
                          "equalsBuildCreation": k(fb) == row["SuperPaymaster"]["creationKeccak"]}
    if label == "rc.2":
        row["equalsAttestation"] = {
            n: {f: row[n][f] == att[n][f] for f in ("runtimeBytes", "runtimeKeccak", "creationKeccak")}
            for n in ("SuperPaymaster", "SuperPaymasterAdmin")
        }
    res[label] = row
print(json.dumps(res, indent=1))
