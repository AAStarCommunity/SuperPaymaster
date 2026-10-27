#!/usr/bin/env python3
"""Offline control: a run relabelled as a6-gauge/1 cannot pass as protocol-conformant.

Builds two synthetic variants of the archived n50 mechanism run with conformant-looking endpoints
(two non-loopback hosts, no local override, protocolConformant=true):
  v1  schema a6-gauge/1, no credit fields   -> must fail with exactly the /2-required error
  v2  schema a6-gauge/2, credit OFF fields  -> must be accepted (shows the v1 failure is that check alone)
These files are synthetic: they prove a validator rule, not anything about a chain.
Usage: python3 script/a6-collector/negative-controls/credit-schema-downgrade.py
"""
import json, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / "docs/design/aoa-balance-mode/data/a6-gauge-local/n50-mechanism.jsonl"
HOSTS = {"http://127.0.0.1:8545": "http://10.0.0.1:8545", "http://127.0.0.1:8546": "http://10.0.0.2:8546"}
CREDIT_OFF = {"policy": 0, "hasPendingPolicy": False, "pendingPolicy": 0, "pendingPolicyEta": "0", "policyEpoch": 0}


def patch(o):
    if isinstance(o, dict):
        for k, v in list(o.items()):
            if k == "allowSameEndpointLocal":
                o[k] = False
            elif isinstance(v, str) and any(v.startswith(h) for h in HOSTS):
                o[k] = next(HOSTS[h] + v[len(h):] for h in HOSTS if v.startswith(h))
            else:
                patch(v)
    elif isinstance(o, list):
        for x in o:
            patch(x)


def validate(rows, d, name):
    f = Path(d) / f"{name}.jsonl"
    f.write_text("".join(json.dumps(r) + "\n" for r in rows))
    p = subprocess.run(["node", str(ROOT / "script/a6-collector/validate.mjs"), str(f)], capture_output=True, text=True)
    out = p.stdout
    return p.returncode, json.loads(out[out.index("{"):])


def main():
    rows = [json.loads(l) for l in SRC.read_text().splitlines() if l.strip()]
    for r in rows:
        patch(r)
    rows[0]["protocolConformant"] = True
    with tempfile.TemporaryDirectory() as d:
        c1, r1 = validate(rows, d, "v1")
        for r in rows:
            r["schema"] = "a6-gauge/2"
        for r in (rows[0], rows[-1]):
            r["passport"]["invariant"]["credit"] = dict(CREDIT_OFF)
        c2, r2 = validate(rows, d, "v2")
    ok = (c1 == 1 and r1["errors"] == ["conformant run requires a6-gauge/2 (credit OFF recorded)"]
          and c2 == 0 and r2["accepted"] is True and r2["errors"] == [])
    print(json.dumps({"v1": {"exit": c1, "errors": r1["errors"]}, "v2": {"exit": c2, "accepted": r2["accepted"]}, "ok": ok}))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
