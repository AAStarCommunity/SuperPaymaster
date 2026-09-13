#!/usr/bin/env python3
"""Write abis/SuperPaymaster.full.json — the merged ABI of the SuperPaymaster core and its
SuperPaymasterAdmin extension (D5b-design §2 item 5), same shape as abis/xPNTsTokenV2.full.json.

Both halves answer at the ONE proxy address: the core serves its own selectors, everything else
falls through the core's fallback to the extension. The merged ABI is the core ABI plus every
extension function whose selector the core does not have, plus extension events/errors the core
does not already declare (by full signature). Reads abis/SuperPaymaster.json and
abis/SuperPaymasterAdmin.json (run scripts/extract_v3_abis.sh SuperPaymaster SuperPaymasterAdmin first).

Usage: python3 scripts/gen-sp-full-abi.py [--check]
"""
import json
import sys

CORE = "abis/SuperPaymaster.json"
EXT = "abis/SuperPaymasterAdmin.json"
OUT = "abis/SuperPaymaster.full.json"


def sig(e):
    def t(x):
        if x["type"].startswith("tuple"):
            return "(" + ",".join(t(c) for c in x["components"]) + ")" + x["type"][5:]
        return x["type"]
    return f'{e["type"]}:{e.get("name", "")}(' + ",".join(t(i) for i in e.get("inputs", [])) + ")"


def merged():
    core = json.load(open(CORE))["abi"]
    ext = json.load(open(EXT))["abi"]
    seen = {sig(e) for e in core if e["type"] in ("function", "event", "error")}
    out = list(core)
    added = 0
    for e in ext:
        if e["type"] not in ("function", "event", "error"):
            continue  # constructor / fallback / receive of the extension are not reachable via the proxy
        if sig(e) in seen:
            continue
        out.append(e)
        seen.add(sig(e))
        added += 1
    note = ("SuperPaymaster 5.5.0 (D5b) = core (SuperPaymaster) + extension (SuperPaymasterAdmin, reached via "
            "the core's fallback DELEGATECALL). Both live at the proxy address; call everything through this "
            "combined ABI.")
    return {"abi": out, "note": note}, added


def main():
    doc, added = merged()
    text = json.dumps(doc, indent=2) + "\n"
    if "--check" in sys.argv:
        cur = open(OUT).read()
        if cur != text:
            print(f"STALE: {OUT} differs from core + extension ABIs; run python3 scripts/gen-sp-full-abi.py")
            sys.exit(1)
        print(f"OK: {OUT} up to date ({len(doc['abi'])} entries, {added} extension-only)")
        return
    open(OUT, "w").write(text)
    print(f"wrote {OUT}: {len(doc['abi'])} entries ({added} extension-only)")


if __name__ == "__main__":
    main()
