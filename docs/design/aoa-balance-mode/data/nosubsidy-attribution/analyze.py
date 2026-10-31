#!/usr/bin/env python3
"""Extract real postOp frames and opcode histograms from Forge -vvvvv --opcodes logs."""
import collections
import json
import pathlib
import re
import sys

OP = re.compile(r'\[(\d+)\] (SLOAD|SSTORE|TLOAD|TSTORE|LOG[0-4])\b')
GAS = re.compile(r'\[(\d+)\]')

def frames(path):
    lines = pathlib.Path(path).read_text().splitlines()
    test = ''
    rows = []
    for i, line in enumerate(lines):
        if line.startswith(('[PASS]', '[FAIL')):
            test = line.split(' (gas:')[0]
        if '::postOp(' not in line or 'SuperPaymaster' not in line:
            continue
        pos = line.index('├─')
        end = i + 1
        while end < len(lines):
            if '└─ ←' in lines[end] and lines[end].index('└─') == pos + 4:
                break
            end += 1
        # Parent proxy has one SLOAD between its frame heading and implementation call.
        parent = i - 1
        while parent >= 0 and '::fallback(' not in lines[parent]:
            parent -= 1
        hist = collections.Counter()
        stores = []
        subcalls = []
        for l in lines[i+1:end]:
            m = OP.search(l)
            if m:
                section = 'SP' if l.index('├─') == pos + 4 else 'token'
                hist[(section, m[2], int(m[1]))] += 1
                if m[2] == 'SSTORE':
                    stores.append({'section': section, 'gas_displayed': int(m[1]), 'operation': l.split('SSTORE',1)[1].strip()})
            elif '::settle' in l:
                subcalls.append(l.strip())
        row = dict(test=test, line=i+1, proxy_gas=int(GAS.search(lines[parent])[1]),
            implementation_gas=int(GAS.search(line)[1]), subcalls=subcalls,
            opcodes=[dict(section=s, opcode=o, cost=c, count=n) for (s,o,c),n in sorted(hist.items())], stores=stores)
        rows.append(row)
    return rows

if __name__ == '__main__':
    result = {str(p): frames(p) for p in sys.argv[1:]}
    print(json.dumps(result, indent=2))
