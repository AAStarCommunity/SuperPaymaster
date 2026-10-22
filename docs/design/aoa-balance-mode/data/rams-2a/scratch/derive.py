# Derive bare-EntryPoint-cost vs fee-inclusive columns from scratch R2A logs.
# Fixture: ETH/USD 2000 (8 dec), aPNTs 0.02 USD, protocolFeeBPS 1000, 1 gwei.
# bare (aPNTs wei) = ceil(costWei * 2000e8 * 1e18 / (1e8 * 0.02e18)) = costWei * 1e5 ; fee-incl = ceil(bare * 11000 / 10000)
import re, sys
def load(p):
    d = {}
    for i, line in enumerate(open(p, errors='replace'), 1):
        m = re.search(r'R2A\|([^|]+)\|(\S+)', line)
        if m: d[m.group(1)] = (m.group(2), i)
    return d
def a(x): return f"{x/1e18:+.5f}" if x < 0 else f"{x/1e18:.5f}"
def row(d, pre, costkey, f):
    cost = int(d[pre + costkey][0]) * (1 if costkey.endswith('_wei') else 10**9)
    bare = cost * 10**5
    fee = -(-bare * 11000 // 10000)
    if pre + 'charge_aPNTs' in d:
        charge = int(d[pre + 'charge_aPNTs'][0]); need = int(d[pre + 'need_aPNTs(full cost at snapshot)'][0])
        assert need == fee, (pre, need, fee)
    else:
        cmn = int(d[pre + 'charge_minus_need_aPNTs'][0]); charge = cmn + fee
    print(f"{f} | {pre} | cost_wei {cost} | bare {a(bare)} | charge {a(charge)} | fee-incl {a(fee)} | charge-bare {a(charge-bare)} | charge-feeincl {a(charge-fee)} | line {d[pre+costkey][1]}")
for f in sys.argv[1:]:
    d = load(f)
    for k in d:
        if k.endswith('.actualGasCost_wei'): row(d, k[:-len('actualGasCost_wei')], 'actualGasCost_wei', f.split('/')[-1])
        elif k.startswith('B8.') and k.endswith('.actualGasUsed'): row(d, k[:-len('actualGasUsed')], 'actualGasUsed', f.split('/')[-1])
