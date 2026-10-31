#!/usr/bin/env python3
"""Complete paired lifecycle inventory. No production writes; fresh test per independent point."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

VARIANTS = ['rr_base', 'fresh_base', 'rr_no_snapshot', 'fresh_snapshot',
            'rr_single_validation', 'fresh_release', 'rr_storage', 'fresh_storage',
            'rr_rate', 'fresh_rate', 'rr_callgas', 'fresh_callgas',
            'rr_calldata', 'fresh_calldata', 'rr_hash', 'fresh_hash',
            'rr_no_guard_probe', 'fresh_guard_probe', 'rr_roll', 'fresh_roll',
            'rr_split', 'fresh_split', 'rr_new_op', 'fresh_new_op',
            'rr_settled_prior', 'fresh_settled_prior']
# Validation and postOp in different transactions: the token's liveness flag is transient
# storage, so every admitted settlement must revert NotLive(). Scanned and classified only.
SPLIT = {'rr_split', 'fresh_split'}
NOT_LIVE = '0xbaf13b3f'
ENGINES = ['amsterdam', 'cancun', 'prague']
MODES = ['balance', 'credit']
TEST = 'contracts/test/v2/SuperPaymasterRR5LifecycleIsolation.t.sol'

def hashes():
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path('contracts/src').rglob('*.sol'))}

def points(log):
    return [(int(g), int(k), r) for g, k, r in re.findall(r'gas: (\d+)\s+kind: (\d+)\s+ret: (0x[0-9a-fA-F]*)', log)]

def verify(out):
    manifest = json.loads((out/'manifest.json').read_text())
    assert set(manifest) == {f'{e}/{m}/{v}' for e in ENGINES for m in MODES for v in VARIANTS}, 'incomplete variant inventory'
    commands = [json.loads(x) for x in (out/'commands.jsonl').read_text().splitlines()]
    by_id = {c['id']: c for c in commands}
    assert len(by_id) == len(commands)
    for c in commands:
        log = (out/c['log']).read_text()
        assert c['exit'] == 0 and log.strip(), c['id']
        assert hashlib.sha256(log.encode()).hexdigest() == c['sha256']
        assert re.search(rf"{c['count']} tests? passed, 0 failed, 0 skipped", log), c['id']
    for key, row in manifest.items():
        scan = points((out/by_id[row['scan']]['log']).read_text())[:241]
        assert len(scan) == 241 and sorted(g for g,k,r in scan) == list(range(420000,900001,2000)), key
        assert all(k in (0,1,2,3) and (k != 1 or r == '0x') and (k != 3 or r == '0x') for g,k,r in scan)
        # Require the full bytes for exact guard classification (selector derived by cast below).
        assert all(r == row['guard_selector'] for g,k,r in scan if k == 0)
        if key.split('/')[2] in SPLIT:
            assert row['split'] is True
            assert any(k == 0 for g,k,r in scan), ('split scan has no guard rejection', key)
            assert not any(k == 3 for g,k,r in scan), ('split variant settled across transactions', key)
            assert all(k == 2 and r == NOT_LIVE for g,k,r in scan if k != 0), ('split failure is not NotLive', key)
            continue
        ordered = sorted(scan)
        kinds = [k for g,k,r in ordered]
        assert kinds[0] == 0 and kinds[-1] == 3
        assert kinds == sorted(kinds), ('nonmonotone scan',key)
        assert row['last_guard_scan'] == max(g for g,k,r in scan if k == 0)
        assert row['first_complete_scan'] == min(g for g,k,r in scan if k == 3)
        for name, g, want in [('guard_lo',row['last_guard'],0),('guard_hi',row['last_guard']+1,None),
                              ('complete_lo',row['first_complete']-1,None),('complete_hi',row['first_complete'],3)]:
            c = by_id[row[name]]
            assert (c['engine'],c['mode'],c['variant']) == tuple(key.split('/'))
            p = points((out/c['log']).read_text())[-1]
            assert p[0] == g
            if want is not None: assert p[1] == want
            elif name == 'guard_hi': assert p[1] != 0
            else: assert p[1] != 3
        t = by_id[row['trace']]
        trace = (out/t['log']).read_text()
        assert 'postOp(' in trace
        if row['first_complete'] > row['last_guard']+1:
            assert '[OutOfGas]' in trace, ('missing OOG trace', key)
        if key.startswith('amsterdam/'):
            entry = json.loads((out/row['entry_steps']).read_text())
            assert entry and all('state_gas_reservoir' in x['step'] for x in entry)
        assert row['first_complete'] >= row['last_guard']+1
    assert json.loads((out/'source-before.json').read_text()) == json.loads((out/'source-after.json').read_text()) == hashes()
    return len(manifest), len(commands)

def main(out):
    if out.exists() and any(out.iterdir()):
        raise SystemExit('output directory must be EMPTY')
    out.mkdir(parents=True, exist_ok=True)
    build = Path(tempfile.mkdtemp(prefix='rr5-lifecycle-',dir='/tmp'))
    (out/'source-before.json').write_text(json.dumps(hashes(),indent=2))
    (out/'head.txt').write_text(subprocess.check_output(['git','rev-parse','HEAD'],text=True))
    (out/'working-tree.txt').write_text(subprocess.check_output(['git','status','--short'],text=True))
    engines = {'amsterdam':str(Path.home()/'Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge'),
               'cancun':str(Path.home()/'.foundry/bin/forge'),'prague':str(Path.home()/'.foundry/bin/forge')}
    manifest = {}
    serial = 0
    for engine in ENGINES:
        (out/f'{engine}-version.txt').write_text(subprocess.check_output([engines[engine],'--version'],text=True))
        for mode in MODES:
            for variant in VARIANTS:
                key = f'{engine}/{mode}/{variant}'
                def run(label, budget=None, trace=False, scan=False):
                    nonlocal serial
                    serial += 1
                    ident = f'{serial:05d}-{engine}-{mode}-{variant}-{label}'
                    env = os.environ.copy()
                    # Pin tuple and remove inherited sampling switches.
                    env.update(TUPLE_CANDIDATE='false', LIFECYCLE_VARIANT=variant,
                               LIFECYCLE_BUDGET=str(budget or 0),
                               FOUNDRY_OUT=str(build/engine/'out'),FOUNDRY_CACHE_PATH=str(build/engine/'cache'))
                    cmd = [engines[engine],'test','--offline','--match-path',TEST,'--match-contract',f'Lifecycle{mode.title()}Test',
                           '--match-test','test_scan_' if scan else 'test_lifecycle', '-vvvv' if trace else '-vv']
                    if engine != 'cancun': cmd += ['--evm-version','prague']
                    if engine == 'amsterdam': cmd += ['--no-isolate','--hardfork','amsterdam']
                    deps = env.get('PROFILE_DEPS_ROOT')
                    if deps: cmd += ['-R',f'@chainlink/contracts/={deps}/contracts/lib/chainlink-brownie-contracts/contracts/',
                                     '-R',f'solady/={deps}/contracts/lib/solady/src/']
                    dump = build/'debug.json'
                    if trace and engine == 'amsterdam': cmd += ['--debug','--dump',str(dump)]
                    p = subprocess.run(cmd,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
                    filename = ident+'.log'
                    (out/filename).write_text(p.stdout)
                    c = dict(id=ident,engine=engine,mode=mode,variant=variant,argv=cmd,
                             env={k:env[k] for k in ('TUPLE_CANDIDATE','LIFECYCLE_VARIANT','LIFECYCLE_BUDGET','FOUNDRY_OUT','FOUNDRY_CACHE_PATH')},
                             log=filename,exit=p.returncode,count=241 if scan else 1,sha256=hashlib.sha256(p.stdout.encode()).hexdigest())
                    with (out/'commands.jsonl').open('a') as f: f.write(json.dumps(c)+'\n')
                    assert p.returncode == 0 and re.search(rf"{c['count']} tests? passed, 0 failed, 0 skipped",p.stdout), ident
                    if trace and engine == 'amsterdam':
                        arena = json.loads(dump.read_text())['debug_arena']
                        entries = [dict(node=n['trace_node_idx'],kind=n['kind'],step=n['steps'][0]) for n in arena
                                   if n['calldata'].startswith('0x7c627b21') and n['step_offset']==0 and n['kind']=='CALL']
                        # Retain the exact first step of every direct postOp, including guard probes.
                        (out/(ident+'-entry.json')).write_text(json.dumps(entries,indent=2))
                        dump.unlink()
                    return ident,p.stdout
                snap = (variant.startswith('rr_') and variant != 'rr_no_snapshot') or variant == 'fresh_snapshot'
                sid,log = run('scan',scan=not snap)
                scan = points(log)[:241]
                assert len(scan)==241, (key,len(scan))
                guards=[g for g,k,r in scan if k==0]
                completed=[g for g,k,r in scan if k==3]
                failures=[g for g,k,r in scan if k in (1,2)]
                if variant in SPLIT:
                    row = dict(scan=sid, split=True, last_guard_scan=max(guards),
                               non_guard_scan=[min(failures),max(failures)] if failures else None,
                               failure_selectors=sorted({r for g,k,r in scan if k in (1,2)}),
                               guard_selector=next(r for g,k,r in scan if k==0))
                    manifest[key]=row
                    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
                    print(key,'split',row['last_guard_scan'],row['non_guard_scan'],row['failure_selectors'],flush=True)
                    continue
                row = dict(scan=sid,last_guard_scan=max(guards),first_complete_scan=min(completed),
                           non_guard_scan=[min(failures),max(failures)] if failures else None,
                           guard_selector=next(r for g,k,r in scan if k==0))
                def sample(g,label='bisect'):
                    ident,log=run(f'{label}-{g}',g)
                    p=points(log)[-1]
                    assert p[0]==g
                    return ident,p[1]
                for edge in ('guard','complete'):
                    lo = max(guards) if edge=='guard' else min(completed)-2000
                    hi = lo+2000
                    while hi-lo>1:
                        mid=(hi+lo)//2
                        _,k=sample(mid)
                        lower=k==0 if edge=='guard' else k!=3
                        if lower: lo=mid
                        else: hi=mid
                    row['last_guard' if edge=='guard' else 'first_complete']=lo if edge=='guard' else hi
                    row[edge+'_lo'],_=sample(lo,edge+'_lo')
                    row[edge+'_hi'],_=sample(hi,edge+'_hi')
                budget = (row['last_guard']+row['first_complete'])//2 if failures else row['last_guard']
                tid,trace = run('trace',budget,trace=True)
                row['trace']=tid
                row['trace_budget']=budget
                if engine=='amsterdam': row['entry_steps']=tid+'-entry.json'
                manifest[key]=row
                (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
                print(key,row['last_guard'],row['non_guard_scan'],row['first_complete'],flush=True)
    (out/'source-after.json').write_text(json.dumps(hashes(),indent=2))
    n,c=verify(out)
    (out/'verdict.txt').write_text(f'PASS {n} complete variants; {c} commands exit 0\n')
    # Negative control: remove one variant, keep logs and commands intact.
    saved=(out/'manifest.json').read_text()
    bad=dict(manifest); bad.pop(next(iter(bad)))
    (out/'manifest.json').write_text(json.dumps(bad))
    try:
        p=subprocess.run([sys.executable,__file__,'--verify',str(out)],capture_output=True,text=True)
        (out/'negative-missing-variant.log').write_text(f'exit {p.returncode}\n'+p.stdout+p.stderr)
        assert p.returncode!=0
    finally: (out/'manifest.json').write_text(saved)
    n,c=verify(out)
    (out/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(out.iterdir()) if p.name!='SHA256SUMS'))
    print(f'PASS {n} variants, {c} commands; negative control rejected',flush=True)

if __name__=='__main__':
    if len(sys.argv)==3 and sys.argv[1]=='--verify':
        print('PASS',verify(Path(sys.argv[2])))
    elif len(sys.argv)==2: main(Path(sys.argv[1]))
    else: raise SystemExit('usage: rr5-lifecycle-run.py [--verify] EMPTY_OUT')
