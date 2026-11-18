#!/usr/bin/env python3
"""Fixed final scan: count files and hits for RPC URL/host/path fragments (>=6 chars) and BLS scalar forms. Never prints needles."""
import json, re, sys
from pathlib import Path
from urllib.parse import urlsplit, unquote
rpc_file, scalars_file, *roots = sys.argv[1:]
url = Path(rpc_file).read_text().strip(); u = urlsplit(url)
rpc_needles = {url, u.hostname or ''}
rpc_needles |= {f for f in unquote(u.path).split('/') if len(f) >= 6}
rpc_needles |= {f for f in re.split(r'[=&]', unquote(u.query)) if len(f) >= 6}
rpc_needles = [n.lower().encode() for n in rpc_needles if n]
sc = []
for s in json.loads(Path(scalars_file).read_text()):
    n = int(s, 16)
    sc += [str(n), f'{n:064x}', hex(n), f'{n:x}']
sc = [x.lower().encode() for x in sc]
print(f'needle classes: rpc={len(rpc_needles)} (url, host, {len(rpc_needles)-2} path/query fragments >=6 chars); scalar forms={len(sc)} (3 scalars x dec/hex64/0xhex/hex)')
total_files = total_rpc = total_sc = 0
for root in roots:
    files = rpc_hits = sc_hits = 0
    for p in Path(root).rglob('*'):
        if p.is_symlink() or not p.is_file(): continue
        files += 1
        c = p.read_bytes().lower()
        rpc_hits += sum(c.count(n) for n in rpc_needles)
        sc_hits += sum(c.count(n) for n in sc)
    print(f'{root}: files={files} rpc_hits={rpc_hits} bls_scalar_hits={sc_hits}')
    total_files += files; total_rpc += rpc_hits; total_sc += sc_hits
print(f'TOTAL files={total_files} rpc_hits={total_rpc} bls_scalar_hits={total_sc} -> {"PASS" if total_rpc == total_sc == 0 else "FAIL"}')
