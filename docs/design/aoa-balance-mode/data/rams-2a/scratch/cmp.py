import re, sys
def load(p):
    d = {}; order = []
    for line in open(p, errors='replace'):
        m = re.search(r'R2A\|([^|]+)\|(\S+)', line)
        if m:
            k = m.group(1)
            if k not in d: order.append(k)
            d[k] = m.group(2)
    return d, order
files = sys.argv[1:]
data = [load(f) for f in files]
keys = []
for _, o in data:
    for k in o:
        if k not in keys: keys.append(k)
w = max(len(k) for k in keys)
print(f"{'key':{w}} | " + " | ".join(f.split('/')[-1] for f in files))
for k in keys:
    print(f"{k:{w}} | " + " | ".join(d.get(k, '—') for d, _ in data))
