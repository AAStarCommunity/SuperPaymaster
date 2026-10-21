#!/usr/bin/env python3
"""Assert that xPNTs v2 CORE and EXTENSION have byte-identical storage layouts.

xPNTsTokenV2 (core) reaches xPNTsTokenV2Ext through DELEGATECALL, so both MUST agree on
every storage variable's slot, offset and type. They share one inheritance chain
(Initializable, ERC20, ERC20Permit, xPNTsV2Base) which makes this true by construction;
this script checks it on the compiled artifacts instead of trusting the construction.

Usage: python3 scripts/check-xpnts-v2-layout.py            -> exit 0 if identical
       python3 scripts/check-xpnts-v2-layout.py --self-test -> proves a divergence is caught
"""
import json
import os
import subprocess
import sys

FORGE = os.environ.get("FORGE", os.path.expanduser("~/.foundry/bin/forge"))
CORE = "contracts/src/tokens/v2/xPNTsTokenV2.sol:xPNTsTokenV2"
EXT = "contracts/src/tokens/v2/xPNTsTokenV2Ext.sol:xPNTsTokenV2Ext"


def layout(target):
    out = subprocess.run([FORGE, "inspect", target, "storageLayout", "--json"],
                         check=True, capture_output=True, text=True).stdout
    d = json.loads(out)
    types = d["types"]
    return [(s["label"], s["slot"], s["offset"], types[s["type"]]["label"]) for s in d["storage"]]


def compare(a, b):
    if a == b:
        return []
    diffs = [(i, x, y) for i, (x, y) in enumerate(zip(a, b)) if x != y]
    if len(a) != len(b):
        diffs.append(("length", len(a), len(b)))
    return diffs


def main():
    core, ext = layout(CORE), layout(EXT)
    if "--self-test" in sys.argv:
        # Positive control: a one-slot shift must be reported, otherwise the checker is dead.
        mutated = [(l, str(int(s) + 1), o, t) if i == len(ext) - 1 else (l, s, o, t)
                   for i, (l, s, o, t) in enumerate(ext)]
        if not compare(core, mutated):
            print("SELF-TEST FAILED: a shifted slot was not detected")
            sys.exit(2)
        print("self-test ok: a shifted slot is detected")
    diffs = compare(core, ext)
    if diffs:
        print("STORAGE LAYOUT MISMATCH between core and extension:")
        for d in diffs:
            print("  ", d)
        sys.exit(1)
    print(f"OK: core and extension storage layouts identical ({len(core)} entries)")


if __name__ == "__main__":
    main()
