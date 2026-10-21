#!/usr/bin/env python3
"""Guard the UUPS proxies (SuperPaymaster, Registry) against storage-layout drift.

These two contracts are upgraded in place via ERC1967 proxies, so any change that
reorders, inserts, or resizes a storage variable corrupts live proxy state. v5.3.2
already shipped a broken in-place upgrade because an OperatorConfig field shift went
unnoticed (PR #196). This script snapshots {label, slot, offset, type} for each and
fails CI on any drift, forcing an explicit, reviewed snapshot update.

D5b (spec 03 §10.7b GOV-2 D): byte-equality alone cannot express "only these listed
slots were appended", and `update` overwrote the baseline. The snapshot now stays the
last deployed-compatible baseline and `storage-layout/allowed-changes.json` lists the
ONLY permitted differences per contract:
  - `appended`: exact entries (label/slot/offset/type) inserted immediately before the
    trailing `__gap`, starting at the old gap's first slot, contiguous;
  - the `__gap` must shrink by exactly the number of slots those entries occupy, so the
    END slot (gap start + gap length) is unchanged;
  - `struct_scope_aliases`: a struct whose DECLARING contract was renamed (e.g. moved to a
    shared base) — only the "struct X.Name" qualifier is normalised; every member's
    slot/offset/type is still compared.
Every other difference fails.

Usage:
  python3 scripts/check_storage_layout.py                    # check (CI mode; exit 1 on drift)
  python3 scripts/check_storage_layout.py --self-test        # prove the allow-list logic rejects
                                                             # what it must (synthetic mutations)
  python3 scripts/check_storage_layout.py --negative-control # GOV-2 D: build a scratch tree whose
                                                             # base is OZ Ownable2Step; the gate
                                                             # MUST fail on it (exit 0 = it did)
  python3 scripts/check_storage_layout.py update             # regenerate snapshots (after an
                                                             # intentional, layout-reviewed change;
                                                             # then empty the allow-list)
"""
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

CONTRACTS = ["SuperPaymaster", "Registry"]
SNAP_DIR = "storage-layout"
ALLOW_PATH = os.path.join(SNAP_DIR, "allowed-changes.json")
FORGE = os.environ.get("FORGE") or shutil.which("forge") or os.path.expanduser("~/.foundry/bin/forge")


def _resolve_type(type_id, types, seen):
    """Expand a type reference into a structural description so that nested
    struct/array/mapping INTERNAL layout changes are captured — not just the
    top-level type-id string.

    Critical: storing only the type-id (e.g. `t_struct(OperatorConfig)45043`)
    MISSES a struct field reorder, because the id can stay the same while the
    members shift slot/offset — that is exactly the v5.3.2 / PR #196 bug class.
    We key on the human `label` (no compiler-assigned astId) so genuine layout
    drift trips the guard while incidental id churn does not.
    """
    if type_id in seen:
        return type_id  # cycle guard (self-referential mapping/struct)
    seen = seen | {type_id}
    t = types.get(type_id, {})
    label = t.get("label", type_id)
    members = t.get("members")
    if members:
        return {"struct": label, "members": [
            {"label": m["label"], "slot": m["slot"], "offset": m["offset"],
             "type": _resolve_type(m["type"], types, seen)}
            for m in members
        ]}
    if "value" in t:  # mapping
        key_id = t.get("key", "")
        return {"mapping": label,
                "key": types.get(key_id, {}).get("label", key_id),
                "value": _resolve_type(t["value"], types, seen)}
    if "base" in t:  # array
        return {"array": label, "base": _resolve_type(t["base"], types, seen)}
    return label  # primitive / enum


def current_layout(contract, cwd=None):
    out = subprocess.run(
        [FORGE, "inspect", contract, "storageLayout", "--json"],
        capture_output=True, text=True, cwd=cwd,
    )
    if out.returncode != 0:
        print(f"forge inspect {contract} failed:\n{out.stderr}", file=sys.stderr)
        sys.exit(2)
    data = json.loads(out.stdout)
    types = data.get("types") or {}
    return [
        {"label": e["label"], "slot": e["slot"], "offset": e["offset"],
         "type": _resolve_type(e["type"], types, set())}
        for e in data.get("storage", [])
    ]


def _normalise(obj, aliases):
    """Rewrite 'struct <Alias>.<Name>' -> 'struct <Canonical>.<Name>' everywhere in obj."""
    if not aliases:
        return obj
    if isinstance(obj, dict):
        return {k: _normalise(v, aliases) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_normalise(v, aliases) for v in obj]
    if isinstance(obj, str):
        for alias, canon in aliases.items():
            obj = re.sub(r"\bstruct " + re.escape(alias) + r"\.", f"struct {canon}.", obj)
        return obj
    return obj


def _gap_len(entry):
    t = entry["type"]
    label = t["array"] if isinstance(t, dict) and "array" in t else ""
    m = re.fullmatch(r"uint256\[(\d+)\]", label)
    return int(m.group(1)) if m else None


def compare(old, cur, allow):
    """Return a list of problems ([] = cur is old + exactly the allowed changes)."""
    allow = allow or {}
    cur = _normalise(cur, allow.get("struct_scope_aliases", {}))
    appended = allow.get("appended", [])
    if old == cur and not appended:
        return []
    problems = []
    if not old or old[-1]["label"] != "__gap" or _gap_len(old[-1]) is None:
        return ["baseline does not end with a uint256[N] __gap; cannot evaluate an append"]
    old_gap = old[-1]
    old_gap_slot, old_gap_len = int(old_gap["slot"]), _gap_len(old_gap)
    end = old_gap_slot + old_gap_len

    prefix = old[:-1]
    if cur[:len(prefix)] != prefix:
        for i, (o, n) in enumerate(zip(prefix, cur)):
            if o != n:
                problems.append(f"entry {i} changed: {o['label']}@{o['slot']}/{o['offset']} "
                                f"-> {n['label']}@{n['slot']}/{n['offset']}")
                break
        else:
            problems.append("existing entries missing")
        return problems

    tail = cur[len(prefix):]
    if not tail or tail[-1]["label"] != "__gap" or _gap_len(tail[-1]) is None:
        return ["current layout does not end with a uint256[N] __gap"]
    new_gap = tail[-1]
    added = tail[:-1]
    if added != appended:
        problems.append(f"appended entries {[(a['label'], a['slot'], a['offset']) for a in added]} "
                        f"!= allowed {[(a['label'], a['slot'], a['offset']) for a in appended]}")
    used = sorted({int(a["slot"]) for a in added})
    if used and used != list(range(old_gap_slot, old_gap_slot + len(used))):
        problems.append(f"appended slots {used} are not contiguous from the old gap start {old_gap_slot}")
    new_gap_slot, new_gap_len = int(new_gap["slot"]), _gap_len(new_gap)
    if new_gap_slot != old_gap_slot + len(used):
        problems.append(f"__gap starts at {new_gap_slot}, expected {old_gap_slot + len(used)}")
    if new_gap_len != old_gap_len - len(used):
        problems.append(f"__gap length {new_gap_len}, expected {old_gap_len - len(used)}")
    if new_gap_slot + new_gap_len != end:
        problems.append(f"end slot moved: {new_gap_slot + new_gap_len} != {end}")
    return problems


def load_allow():
    if not os.path.exists(ALLOW_PATH):
        return {}
    return json.load(open(ALLOW_PATH))


def check(layouts=None, quiet=False):
    allow_all = load_allow()
    failed = False
    for contract in CONTRACTS:
        cur = layouts[contract] if layouts else current_layout(contract)
        snap_path = os.path.join(SNAP_DIR, f"{contract}.json")
        if not os.path.exists(snap_path):
            print(f"MISSING snapshot {snap_path} — run: python3 scripts/check_storage_layout.py update")
            failed = True
            continue
        # The baseline itself is pinned (Codex D5b review, Medium): `update` rewrites the snapshot, and
        # a rewritten snapshot would make any drift "unchanged". The pin lives in the reviewed
        # allow-list, so replacing a baseline takes a second, explicit edit that shows up in review.
        pin = (allow_all.get(contract) or {}).get("baseline_sha256")
        got = hashlib.sha256(open(snap_path, "rb").read()).hexdigest()
        if pin != got:
            failed = True
            print(f"BASELINE CHANGED  {snap_path}: sha256 {got} != pinned {pin} in {ALLOW_PATH} — a snapshot "
                  f"may only be replaced deliberately (update the pin in the same reviewed change)")
            continue
        old = json.load(open(snap_path))
        problems = compare(old, cur, allow_all.get(contract))
        if not problems:
            n_app = len((allow_all.get(contract) or {}).get("appended", []))
            if not quiet:
                print(f"OK  {contract} storage layout = snapshot"
                      + (f" + {n_app} allowed appended entr{'y' if n_app == 1 else 'ies'}" if n_app else " (unchanged)")
                      + f" ({len(cur)} entries)")
            continue
        failed = True
        print(f"DRIFT  {contract} storage layout differs from snapshot + allowed changes — UUPS-upgrade-UNSAFE:")
        for p in problems:
            print("   ", p)
    return failed


def self_test():
    """Synthetic mutations on the real snapshot + allow-list; each must be rejected."""
    allow_all = load_allow()
    sp_old = json.load(open(os.path.join(SNAP_DIR, "SuperPaymaster.json")))
    sp_allow = allow_all["SuperPaymaster"]
    good = copy.deepcopy(sp_old[:-1]) + copy.deepcopy(sp_allow["appended"])
    gap = copy.deepcopy(sp_old[-1])
    n = len({a["slot"] for a in sp_allow["appended"]})
    gap["slot"] = str(int(gap["slot"]) + n)
    gap["type"] = {"array": f"uint256[{_gap_len(sp_old[-1]) - n}]", "base": "uint256"}
    good.append(gap)
    assert compare(sp_old, good, sp_allow) == [], "positive control: the allowed append must pass"

    cases = {}
    m = copy.deepcopy(good); m.insert(3, {"label": "x", "slot": "3", "offset": 0, "type": "address"})
    cases["insert in the middle"] = m
    m = copy.deepcopy(good); m[1]["slot"] = str(int(m[1]["slot"]) + 1)
    cases["shift an existing slot"] = m
    m = copy.deepcopy(good); m[-1]["type"] = {"array": f"uint256[{_gap_len(sp_old[-1])}]", "base": "uint256"}
    cases["gap not shrunk (end slot moves)"] = m
    m = copy.deepcopy(good); m.insert(-1, {"label": "extra", "slot": m[-1]["slot"], "offset": 0, "type": "address"})
    cases["an unlisted extra append"] = m
    m = copy.deepcopy(good); m[-2]["offset"] = 0
    cases["listed append with a different offset"] = m
    m = copy.deepcopy(good)
    for e in m:
        if isinstance(e["type"], dict) and e["type"].get("struct", "").endswith(".GasParams"):
            e["type"]["members"][0]["offset"] = 4
    cases["struct member moved (scope alias must not hide it)"] = m
    # OZ Ownable2Step shape: _pendingOwner inserted after _owner, everything below shifts
    m = copy.deepcopy(good)
    m.insert(1, {"label": "_pendingOwner", "slot": "1", "offset": 0, "type": "address"})
    for e in m[2:]:
        e["slot"] = str(int(e["slot"]) + 1)
    cases["OZ Ownable2Step (_pendingOwner after _owner)"] = m
    bad = [k for k, v in cases.items() if not compare(sp_old, v, sp_allow)]
    if bad:
        print("SELF-TEST FAILED: accepted:", bad)
        sys.exit(2)
    reg_old = json.load(open(os.path.join(SNAP_DIR, "Registry.json")))
    m = copy.deepcopy(reg_old)
    m.insert(-1, {"label": "guardian", "slot": m[-1]["slot"], "offset": 0, "type": "address"})
    if not compare(reg_old, m, allow_all.get("Registry")):
        print("SELF-TEST FAILED: Registry accepted an append its allow-list does not list")
        sys.exit(2)
    print(f"self-test ok: allowed append passes; {len(cases) + 1} mutations rejected")


def negative_control():
    """GOV-2 D: a scratch tree whose shared base is OZ Ownable2Step must FAIL the gate."""
    root = os.getcwd()
    tmp = tempfile.mkdtemp(prefix="sp-layout-negctl-")
    try:
        shutil.copy(os.path.join(root, "foundry.toml"), tmp)
        os.makedirs(os.path.join(tmp, "contracts"))
        shutil.copytree(os.path.join(root, "contracts", "src"), os.path.join(tmp, "contracts", "src"))
        os.symlink(os.path.join(root, "contracts", "lib"), os.path.join(tmp, "contracts", "lib"))
        os.symlink(os.path.join(root, "singleton-paymaster"), os.path.join(tmp, "singleton-paymaster"))
        oz = 'import "@openzeppelin-v5.0.2/contracts/access/Ownable2Step.sol";\n'
        for rel, frm in [("contracts/src/paymasters/superpaymaster/v3/BasePaymasterUpgradeable.sol",
                          'import "../../../utils/Ownable2StepNamespaced.sol";\n'),
                         ("contracts/src/core/Registry.sol", 'import "../utils/Ownable2StepNamespaced.sol";\n')]:
            p = os.path.join(tmp, rel)
            s = open(p).read()
            assert frm in s and "Ownable2StepNamespaced," in s, rel
            s = s.replace(frm, oz).replace("Ownable2StepNamespaced,", "Ownable2Step,")
            # OZ Ownable2Step has no namespaced-pending helper; drop the upgrade guard in the scratch
            s = s.replace(" _requireNoPendingOwner(); ", " ")
            open(p, "w").write(s)
        layouts = {c: current_layout(c, cwd=tmp) for c in CONTRACTS}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("negative control: scratch tree with OZ Ownable2Step as the base —")
    if check(layouts):
        print("negative control ok: the gate rejects an OZ Ownable2Step base")
        return
    print("NEGATIVE CONTROL FAILED: the gate accepted an OZ Ownable2Step base")
    sys.exit(2)


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    os.makedirs(SNAP_DIR, exist_ok=True)
    if mode == "--self-test":
        self_test()
        sys.exit(1 if check() else 0)
    if mode == "--negative-control":
        negative_control()
        return
    if mode == "update":
        for contract in CONTRACTS:
            cur = current_layout(contract)
            snap_path = os.path.join(SNAP_DIR, f"{contract}.json")
            with open(snap_path, "w") as f:
                json.dump(cur, f, indent=2)
                f.write("\n")
            print(f"updated {snap_path} ({len(cur)} slots) — now empty {ALLOW_PATH}'s appended lists and "
                  f"re-pin baseline_sha256 = {hashlib.sha256(open(snap_path, 'rb').read()).hexdigest()}")
        return
    sys.exit(1 if check() else 0)


if __name__ == "__main__":
    main()
