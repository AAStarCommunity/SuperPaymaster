#!/usr/bin/env python3
"""Assert that the SuperPaymaster CORE and its SuperPaymasterAdmin EXTENSION have identical
storage layouts (D5b-design §2 item 1 / §5).

The core reaches the extension through DELEGATECALL from its fallback, so both MUST agree on
every storage variable's slot, offset and (recursively expanded) type. They share one inheritance
chain (SuperPaymasterStorage) which makes this true by construction; this script checks it on the
compiled artifacts instead of trusting the construction. Types are expanded structurally (struct
members, mapping values, array bases — same resolver as check_storage_layout.py), so a struct
member shift inside a shared type is caught too.

Usage: python3 scripts/check-sp-layout.py            -> exit 0 if identical
       python3 scripts/check-sp-layout.py --self-test -> also proves a divergence is caught
"""
import copy
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("csl", os.path.join(HERE, "check_storage_layout.py"))
csl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(csl)

CORE = "contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:SuperPaymaster"
EXT = "contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol:SuperPaymasterAdmin"


def compare(a, b):
    if a == b:
        return []
    diffs = [(i, x["label"], x["slot"], x["offset"], y["label"], y["slot"], y["offset"])
             for i, (x, y) in enumerate(zip(a, b)) if x != y]
    if len(a) != len(b):
        diffs.append(("length", len(a), len(b)))
    return diffs or [("type-level difference",)]


def main():
    core, ext = csl.current_layout(CORE), csl.current_layout(EXT)
    if "--self-test" in sys.argv:
        # Positive controls, each must be reported, otherwise the checker is dead:
        #   (1) the last entry shifted by one slot; (2) a struct member offset changed.
        m1 = copy.deepcopy(ext)
        m1[-1]["slot"] = str(int(m1[-1]["slot"]) + 1)
        m2 = copy.deepcopy(ext)
        hit = False
        for e in m2:
            t = e["type"]
            if isinstance(t, dict) and "value" in t and isinstance(t["value"], dict) and "members" in t["value"]:
                t["value"]["members"][-1]["offset"] += 1
                hit = True
                break
        if not compare(core, m1) or not hit or not compare(core, m2):
            print("SELF-TEST FAILED: a shifted slot / struct member was not detected")
            sys.exit(2)
        print("self-test ok: a shifted slot and a shifted struct member are detected")
    diffs = compare(core, ext)
    if diffs:
        print("STORAGE LAYOUT MISMATCH between SuperPaymaster core and SuperPaymasterAdmin:")
        for d in diffs:
            print("  ", d)
        sys.exit(1)
    print(f"OK: SuperPaymaster core and SuperPaymasterAdmin storage layouts identical ({len(core)} entries, "
          f"last = {core[-1]['label']}@{core[-1]['slot']})")


if __name__ == "__main__":
    main()
