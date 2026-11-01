"""Reduce retained tuple480 logs, without substituting expected measurements."""
import importlib.util
import json
import re
import sys
import math
from pathlib import Path
from fractions import Fraction

spec = importlib.util.spec_from_file_location('tuple480_verifier', Path(__file__).with_name('tuple480-run.py'))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
out = Path(sys.argv[1])
rows = [json.loads(x) for x in (out/'commands.jsonl').read_text().splitlines()]
groups = {}
for row in rows:
    if row['kind'] != 'scan': continue
    key = tuple(row[k] for k in ('engine','settle','credit','legacy','nonfresh'))
    log = (out/(row['id']+'.log')).read_text()
    groups.setdefault(key,[]).append(verifier.scan_sample(log, row['budget']))
verifier.verify_boundaries(groups)
boundaries=[]
for key,samples in groups.items():
    lo=max(b for b,a,c in samples if not a)
    hi=min(b for b,a,c in samples if a)
    assert hi==lo+1
    boundaries.append(dict(zip(('engine','settle','credit','legacy','nonfresh'),key)) | {'boundary':hi,'complete_at_boundary':next(c for b,a,c in samples if b==hi),'margin480':480000-hi})
fits=[]
for engine in ('amsterdam','cancun','prague'):
    for credit in (False,True):
        for nonfresh in (False,True):
            points=[(b['settle'],b['boundary']) for b in boundaries if b['engine']==engine and b['credit']==credit and b['nonfresh']==nonfresh and not b['legacy']]
            mx=Fraction(sum(x for x,y in points),len(points));my=Fraction(sum(y for x,y in points),len(points))
            slope=sum((x-mx)*(y-my) for x,y in points)/sum((x-mx)**2 for x,y in points)
            intercept=my-slope*mx
            residual=max(abs(y-(slope*x+intercept)) for x,y in points)
            offsets=[Fraction(y)-Fraction(x*64,63) for x,y in points]
            fits.append(dict(engine=engine,credit=credit,nonfresh=nonfresh,slope=float(slope),intercept=float(intercept),max_residual=float(residual),offset_min=float(min(offsets)),offset_max=float(max(offsets)),admin_crossing_from_mean_c=float(63*(20000-sum(offsets)/len(offsets))),ceiling_fit_consistent=max(offsets)-min(offsets)<1,ceiling_offset_lower_exclusive=float(max(offsets)-1),ceiling_offset_upper_inclusive=float(min(offsets)),first_reject_settle_min=math.floor(63*(20000-min(offsets)))+1,first_reject_settle_max=math.ceil(63*(20000-(max(offsets)-1)))))
accounting=[]
for pattern in (0,1):
    penalty480=json.loads((out/'penalties.json').read_text())[f'multi-5-{pattern}-0'][0]['penalty']
    entries=[]
    for limit in (440000,470000,480000):
        log=(out/f'worst-net-{limit}-{pattern}.log').read_text()
        contexts=re.findall(r'::postOp\(0, (0x[0-9a-f]+), (\d+).*?, 1000000000',log)
        assert len(contexts)==5
        context,P=contexts[0]; P=int(P)
        words=[int(context[i:i+64],16) for i in range(2,len(context),64)]
        events=re.findall(r'emit UserOperationEvent\(.*?actualGasCost: (\d+).*?actualGasUsed: (\d+)',log)
        F,gas=map(int,events[0]);assert F==gas*10**9
        proxy_nets=re.findall(r'\[(\d+)\] ERC1967Proxy[^:]*::fallback\(0, 0x',log)
        assert len(proxy_nets)==5
        preops=re.findall(r'::innerHandleOp\(.*?preOpGas: (\d+)',log)
        assert len(preops)==5
        fee=(words[11]>>128)-1
        cap=words[2]; price=words[8]; decimals=words[9]; aprice=words[10]
        cpost=(words[11]>>96)&(2**32-1); cwrap=(words[11]>>64)&(2**32-1)
        budget=cpost+cwrap+(words[6]+words[7]+9)//10
        def ceil(n,d): return (n+d-1)//d
        agas=ceil((P+budget*10**9)*price*10**18,10**decimals*aprice)
        charge=min(cap,ceil(agas*(10000+fee),10000))
        emitted=re.findall(r'emit '+('CreditSettled' if pattern else 'LockSettled')+r'\(.*?'+('debtAdded' if pattern else 'aCharged')+r': (\d+)',log)
        assert len(emitted)==5 and int(emitted[0])==charge, 'charge formula differs from settled event'
        net=(charge*10000//(10000+fee))*10**decimals*aprice//(price*10**18)
        # Required prefund is the sum of five operation limits, independent of settlement mode.
        prefund=400000+300000+1150000+limit+50000
        costs=re.findall(r'::validatePaymasterUserOp\(.*?\}\), 0x[0-9a-f]+, (\d+)',log)
        assert len(costs)==5 and all(int(c)==prefund*10**9 for c in costs), 'prefund differs from validation maxCost'
        entries.append(dict(mode='CREDIT' if pattern else 'BALANCE',limit=limit,P=P,F=F,gas=gas,net_charge=net,margin_gas=(net-F)/10**9,proxy_net=int(proxy_nets[0]),preop=int(preops[0]),prefund_gas=prefund,reservation_tokens=cap,charge_tokens=charge,context=context))
    latest=entries[-1]
    for entry in entries:
        # Same first-op P and whole-proxy cost across limits are independently visible in traces.
        assert (entry['P'],entry['proxy_net'],entry['preop'])==(latest['P'],latest['proxy_net'],latest['preop'])
        assert latest['gas']-entry['gas']==(480000-entry['limit'])//10
        entry['penalty']=penalty480-(latest['gas']-entry['gas'])
        entry['prepenalty_gas']=entry['gas']-entry['penalty']
        entry['wrapper_gas']=entry['prepenalty_gas']-entry['P']//10**9-entry['proxy_net']
        entry['execution_gas_used']=entry['prepenalty_gas']-entry['preop']
        assert entry['penalty']==max(0,300000+entry['limit']-entry['execution_gas_used'])//10
        entry['penalty_increase_to480']=penalty480-entry['penalty']
        entry['penalty_increase_percent']=100*entry['penalty_increase_to480']/entry['penalty']
        entry['prefund_increase_to480']=480000-entry['limit']
        entry['prefund_increase_percent']=100*entry['prefund_increase_to480']/entry['prefund_gas']
    accounting+=entries
result={'boundaries':boundaries,'fits':fits,'accounting':accounting}
print(json.dumps(result,indent=2))
