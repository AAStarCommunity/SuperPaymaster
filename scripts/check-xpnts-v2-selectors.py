#!/usr/bin/env python3
"""Selector routing check for xPNTs v2 (core + DELEGATECALL extension).

The core serves any selector it defines; every other selector falls through to the
extension. Two properties must hold on the compiled artifacts:

  1. EXT-ONLY ∩ CORE = ∅ : a selector the extension adds (beyond the shared base) must not
     also exist in the core — otherwise the core would silently shadow it and the extension
     implementation would be unreachable.
  2. BASE ⊆ CORE : every public selector of the shared base (ERC20/Permit/storage getters)
     must be served by the core — otherwise the fallback would route it into the extension.
     (Selectors shared by core and extension because both inherit the base are expected and
     harmless: through a clone they are always answered by the core.)

Usage: python3 scripts/check-xpnts-v2-selectors.py [--self-test]
"""
import json
import os
import subprocess
import sys

FORGE = os.environ.get("FORGE", os.path.expanduser("~/.foundry/bin/forge"))
BASE = "contracts/src/tokens/v2/xPNTsV2Base.sol:xPNTsV2Base"
CORE = "contracts/src/tokens/v2/xPNTsTokenV2.sol:xPNTsTokenV2"
EXT = "contracts/src/tokens/v2/xPNTsTokenV2Ext.sol:xPNTsTokenV2Ext"


def selectors(target):
    out = subprocess.run([FORGE, "inspect", target, "methodIdentifiers", "--json"],
                         check=True, capture_output=True, text=True).stdout
    return {sel: sig for sig, sel in json.loads(out).items()}


def check(base, core, ext):
    problems = []
    ext_only = set(ext) - set(base)
    shadowed = ext_only & set(core)
    for s in sorted(shadowed):
        problems.append(f"shadowed: {ext[s]} ({s}) is in both core and extension")
    missing = set(base) - set(core)
    for s in sorted(missing):
        problems.append(f"base selector not served by core: {base[s]} ({s})")
    return problems, ext_only


def main():
    base, core, ext = selectors(BASE), selectors(CORE), selectors(EXT)
    if "--self-test" in sys.argv:
        # Positive control: inject an extension-only selector into the core → must be caught.
        ext_only = sorted(set(ext) - set(base))
        fake_core = dict(core)
        fake_core[ext_only[0]] = ext[ext_only[0]]
        if not check(base, fake_core, ext)[0]:
            print("SELF-TEST FAILED: a shadowed selector was not detected")
            sys.exit(2)
        print(f"self-test ok: shadowing of {ext[ext_only[0]]} is detected")
    problems, ext_only = check(base, core, ext)
    if problems:
        print("SELECTOR ROUTING PROBLEMS:")
        for p in problems:
            print("  ", p)
        sys.exit(1)
    print(f"OK: base {len(base)} ⊆ core {len(core)}; extension-only {len(ext_only)} selectors, none shadowed")


if __name__ == "__main__":
    main()
