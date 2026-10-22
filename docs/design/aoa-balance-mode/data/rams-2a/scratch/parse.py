import re, sys, json
def parse(path):
    res = {}; suite = None
    for line in open(path, errors='replace'):
        m = re.match(r'^Ran \d+ tests? for (\S+)', line)
        if m: suite = m.group(1); continue
        if line.startswith('Failing tests:'): break
        m = re.match(r'^\[(PASS|FAIL|SKIP)(?:[:\s]\s*(.*?))?\] ([A-Za-z_]\w*)(?:\(.*?\))?(?: \((.*)\))?\s*$', line)
        if m and suite:
            st, reason, name, gas = m.groups()
            res[f'{suite}::{name}'] = (st, (reason or '').strip(), (gas or '').strip())
    return res
if __name__ == '__main__':
    r = parse(sys.argv[1])
    from collections import Counter
    print(len(r), Counter(v[0] for v in r.values()))
