#!/usr/bin/env python3
"""Write abis/SuperPaymaster.full.json and abis/xPNTsTokenV2.full.json — the merged ABI of each core
contract and its extension (SuperPaymaster + SuperPaymasterAdmin, D5b-design §2 item 5;
xPNTsTokenV2 + xPNTsTokenV2Ext).

Both halves answer at the ONE proxy address: the core serves its own selectors, everything else
falls through the core's fallback to the extension. The merged ABI is the core ABI plus every
extension function whose selector the core does not have, plus extension events/errors the core
does not already declare (by full signature). Reads the core and extension bundles in abis/
(run scripts/extract_v3_abis.sh first).

Usage: python3 scripts/gen-sp-full-abi.py [--check]
"""
import json
import sys

# (core, extension, merged output, note). Both pairs share the same proxy-fallback shape.
PAIRS = [
    ("abis/SuperPaymaster.json", "abis/SuperPaymasterAdmin.json", "abis/SuperPaymaster.full.json",
     "SuperPaymaster 5.5.0 (D5b) = core (SuperPaymaster) + extension (SuperPaymasterAdmin, reached via "
     "the core's fallback DELEGATECALL). Both live at the proxy address; call everything through this "
     "combined ABI."),
    ("abis/xPNTsTokenV2.json", "abis/xPNTsTokenV2Ext.json", "abis/xPNTsTokenV2.full.json",
     "xPNTs v2 = core (xPNTsTokenV2) + extension (xPNTsTokenV2Ext, reached via fallback). Both live at the "
     "token address; call everything through this combined ABI."),
]


def sig(e):
    def t(x):
        if x["type"].startswith("tuple"):
            return "(" + ",".join(t(c) for c in x["components"]) + ")" + x["type"][5:]
        return x["type"]
    return f'{e["type"]}:{e.get("name", "")}(' + ",".join(t(i) for i in e.get("inputs", [])) + ")"


def merged(core_path, ext_path, note):
    core = json.load(open(core_path))["abi"]
    ext = json.load(open(ext_path))["abi"]
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
    return {"abi": out, "note": note}, added


def main():
    args = sys.argv[1:]
    if args not in ([], ["--check"]):
        sys.exit(f"usage: {sys.argv[0]} [--check]")  # never write on an unknown flag
    stale = False
    for core, ext, out, note in PAIRS:
        doc, added = merged(core, ext, note)
        text = json.dumps(doc, indent=2) + "\n"
        if args:
            if open(out).read() != text:
                print(f"STALE: {out} differs from core + extension ABIs; run python3 scripts/gen-sp-full-abi.py")
                stale = True
            else:
                print(f"OK: {out} up to date ({len(doc['abi'])} entries, {added} extension-only)")
            continue
        open(out, "w").write(text)
        print(f"wrote {out}: {len(doc['abi'])} entries ({added} extension-only)")
    if stale:
        sys.exit(1)


if __name__ == "__main__":
    main()
