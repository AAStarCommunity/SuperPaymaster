#!/usr/bin/env python3
# usage: final_scan.py DIR...   Scans for RPC URL / hostname / path+query fragments of rpca, rpcb. Never echoes a hit.
import os, sys, urllib.parse
needles = []
for p in ("rpca", "rpcb"):
    u = open(os.path.expanduser(f"~/Dev/aastar/manifest-live/.rpc/{p}")).read().strip()
    pr = urllib.parse.urlparse(u)
    for n in (u, pr.hostname, pr.path.strip("/"), pr.query):
        if n and len(n) >= 8: needles.append(n.encode())
    for part in pr.path.split("/"):
        if len(part) >= 12: needles.append(part.encode())
hits = 0; files = 0
for root in sys.argv[1:]:
    for dp, _, fs in os.walk(root):
        for f in fs:
            fp = os.path.join(dp, f); files += 1
            try: data = open(fp, "rb").read()
            except OSError: continue
            if any(n in data for n in needles):
                hits += 1; print("HIT", fp)
print(f"scanned {files} files, {len(needles)} needles, hits {hits}")
sys.exit(1 if hits else 0)
