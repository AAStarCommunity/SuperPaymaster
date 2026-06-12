#!/usr/bin/env python3
"""Guard the UUPS proxies (SuperPaymaster, Registry) against storage-layout drift.

These two contracts are upgraded in place via ERC1967 proxies, so any change that
reorders, inserts, or resizes a storage variable corrupts live proxy state. v5.3.2
already shipped a broken in-place upgrade because an OperatorConfig field shift went
unnoticed (PR #196). This script snapshots {label, slot, offset, type} for each and
fails CI on any drift, forcing an explicit, reviewed snapshot update.

Usage:
  python3 scripts/check_storage_layout.py            # check (CI mode; exit 1 on drift)
  python3 scripts/check_storage_layout.py update     # regenerate snapshots (after an
                                                      # intentional, layout-reviewed change)
"""
import json
import os
import subprocess
import sys

CONTRACTS = ["SuperPaymaster", "Registry"]
SNAP_DIR = "storage-layout"


def current_layout(contract):
    out = subprocess.run(
        ["forge", "inspect", contract, "storageLayout", "--json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        print(f"forge inspect {contract} failed:\n{out.stderr}", file=sys.stderr)
        sys.exit(2)
    data = json.loads(out.stdout)
    # Keep only the layout-critical fields; drop the verbose `types` table whose
    # internal ids are noisy across compiler runs.
    return [
        {"label": e["label"], "slot": e["slot"], "offset": e["offset"], "type": e["type"]}
        for e in data.get("storage", [])
    ]


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    os.makedirs(SNAP_DIR, exist_ok=True)
    failed = False

    for contract in CONTRACTS:
        cur = current_layout(contract)
        snap_path = os.path.join(SNAP_DIR, f"{contract}.json")

        if mode == "update":
            with open(snap_path, "w") as f:
                json.dump(cur, f, indent=2)
                f.write("\n")
            print(f"updated {snap_path} ({len(cur)} slots)")
            continue

        if not os.path.exists(snap_path):
            print(f"MISSING snapshot {snap_path} — run: python3 scripts/check_storage_layout.py update")
            failed = True
            continue

        old = json.load(open(snap_path))
        if old == cur:
            print(f"OK  {contract} storage layout unchanged ({len(cur)} slots)")
            continue

        failed = True
        print(f"DRIFT  {contract} storage layout changed — UUPS-upgrade-UNSAFE unless intentional:")
        for o, n in zip(old, cur):
            if o != n:
                print(f"   slot {o.get('slot')}/{o.get('offset')}: {o.get('label')}:{o.get('type')}"
                      f"  ->  slot {n.get('slot')}/{n.get('offset')}: {n.get('label')}:{n.get('type')}")
        if len(old) != len(cur):
            print(f"   entry count {len(old)} -> {len(cur)}")
        print(f"   If this change is intentional and you have verified slot compatibility,")
        print(f"   run: python3 scripts/check_storage_layout.py update  and commit the snapshot.")

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
