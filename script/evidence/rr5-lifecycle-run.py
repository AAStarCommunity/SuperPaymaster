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

def guard_selector():
    """Keccak-256 (Ethereum padding), restricted to this one-block signature."""
    data = bytearray(b'PostOpGasTooLow()')
    data.append(1)
    data.extend(bytes(136 - len(data)))
    data[-1] |= 128
    a = [int.from_bytes(data[i:i+8], 'little') for i in range(0, 136, 8)] + [0]*8
    rotations = [[0,36,3,41,18], [1,44,10,45,2], [62,6,43,15,61],
                 [28,55,25,21,56], [27,20,39,8,14]]
    constants = [0x1,0x8082,0x800000000000808a,0x8000000080008000,
                 0x808b,0x80000001,0x8000000080008081,0x8000000000008009,
                 0x8a,0x88,0x80008009,0x8000000a,0x8000808b,
                 0x800000000000008b,0x8000000000008089,0x8000000000008003,
                 0x8000000000008002,0x8000000000000080,0x800a,
                 0x800000008000000a,0x8000000080008081,0x8000000000008080,
                 0x80000001,0x8000000080008008]
    mask = (1 << 64)-1
    def rol(x, n):
        return ((x << n) | (x >> ((64-n) % 64))) & mask
    for rc in constants:
        c = [a[x]^a[x+5]^a[x+10]^a[x+15]^a[x+20] for x in range(5)]
        d = [c[(x-1)%5]^rol(c[(x+1)%5],1) for x in range(5)]
        b = [0]*25
        for x in range(5):
            for y in range(5):
                b[y+5*((2*x+3*y)%5)] = rol(a[x+5*y]^d[x],rotations[x][y])
        for x in range(5):
            for y in range(5):
                a[x+5*y] = b[x+5*y]^((~b[(x+1)%5+5*y]) & b[(x+2)%5+5*y])
        a[0] ^= rc
    return '0x' + a[0].to_bytes(8,'little')[:4].hex()


def verify_sources(out):
    import ast
    sums = {}
    for line in (out/'SHA256SUMS').read_text().splitlines():
        digest, name = line.split('  ', 1)
        assert re.fullmatch('[0-9a-f]{64}', digest) and Path(name).name == name
        assert name not in sums, ('duplicate checksum', name)
        sums[name] = digest
    assert set(sums) == {p.name for p in out.iterdir() if p.name != 'SHA256SUMS'}, 'checksum inventory'
    for name, digest in sums.items():
        assert hashlib.sha256((out/name).read_bytes()).hexdigest() == digest, ('checksum', name)
    head = (out/'head.txt').read_text().strip()
    assert re.fullmatch('[0-9a-f]{40}', head), 'head format'
    def recorded(path):
        return subprocess.check_output(['git','show',f'{head}:{path}'])
    assert subprocess.check_output(['git','rev-parse',f'{head}^{{commit}}'],text=True).strip() == head
    # The original record has no tracked changes, only the then-untracked evidence folder.
    assert (out/'working-tree.txt').read_text() in ('', '?? docs/design/aoa-balance-mode/data/rr5-lifecycle-isolation/\n'), 'dirty measurement sources'
    for engine in ENGINES:
        version = (out/f'{engine}-version.txt').read_text()
        assert re.fullmatch(r'forge Version: [^\n]+\nCommit SHA: [0-9a-f]{40}\nBuild Timestamp: [^\n]+\nBuild Profile: dist\n', version)
        release, commit = (('1.8.7-nightly', '4e8874b2bdc840929585ca73e170993c50a4a531')
                           if engine == 'amsterdam' else
                           ('1.7.1', '4072e48705af9d93e3c0f6e29e93b5e9a40caed8'))
        assert version.startswith(f'forge Version: {release}\nCommit SHA: {commit}\n')
    assert (out/'cancun-version.txt').read_bytes() == (out/'prague-version.txt').read_bytes()
    before = json.loads((out/'source-before.json').read_text())
    assert before == json.loads((out/'source-after.json').read_text())
    assert all(before.get(p) == h for p,h in hashes().items()), 'production source hashes'
    paths = {TEST, 'contracts/test/fixtures/entrypoint-v0.7.runtime.hex', 'foundry.toml'}
    pending = [TEST]
    while pending:
        path = pending.pop()
        for imp in re.findall(r'import\s+(?:[^;]*?from\s+)?["\']([^"\']+)["\']\s*;', recorded(path).decode()):
            if imp.startswith('.'):
                child = os.path.normpath(str(Path(path).parent/imp))
                if child.startswith('contracts/test/') and child not in paths:
                    paths.add(child)
                    pending.append(child)
    for path in sorted(paths):
        expected = before.get(path, hashlib.sha256(recorded(path)).hexdigest())
        if path == TEST:
            skip_patch = (b'        variant = vm.envString("LIFECYCLE_VARIANT");\n',
                          b'        variant = vm.envOr("LIFECYCLE_VARIANT", string(""));\n'
                          b'        if (bytes(variant).length == 0) vm.skip(true); // runner-only suite: skipped in a plain `forge test`\n')
            # The only post-run edit to the measured test: skip the suite when LIFECYCLE_VARIANT is unset, so
            # a plain `forge test` does not fail in setUp. With the variable set (every recorded command) the
            # behaviour is identical. Anything else differing from the measured revision is rejected.
            measured = recorded(path)
            assert measured.count(skip_patch[0]) == 1, 'skip patch anchor'
            assert hashlib.sha256(measured).hexdigest() == expected, ('harness source', path)
            assert Path(path).read_bytes() == measured.replace(*skip_patch), ('harness source', path)
            continue
        assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == expected, ('harness source', path)
    runner = 'script/evidence/rr5-lifecycle-run.py'
    original = recorded(runner)
    if runner in before:
        assert hashlib.sha256(original).hexdigest() == before[runner], 'recorded runner hash'
    # Verifier-only repairs necessarily change this file's byte hash. Bind all original
    # measurement definitions verbatim, permitting only the verification implementation to change.
    old = ast.parse(original)
    current = ast.parse(Path(runner).read_bytes())
    def measurement_digest(tree):
        tree.body = [n for n in tree.body if not (
            isinstance(n, ast.FunctionDef) and n.name in
            {'verify', 'verify_sources', 'guard_selector'})]
        return hashlib.sha256(ast.dump(tree).encode()).hexdigest()
    assert measurement_digest(old) == measurement_digest(current), 'measurement runner changed'



def verify(out):
    verify_sources(out)
    manifest = json.loads((out/'manifest.json').read_text())
    keys = [f'{e}/{m}/{v}' for e in ENGINES for m in MODES for v in VARIANTS]
    assert set(manifest) == set(keys), 'incomplete variant inventory'
    commands = [json.loads(x) for x in (out/'commands.jsonl').read_text().splitlines()]
    cursor = 0
    selector = guard_selector()
    build_root = None
    deps_root = None
    def consume(key, label, budget=0, scan=False, trace=False):
        nonlocal cursor, build_root, deps_root
        assert cursor < len(commands), ('missing command', key, label)
        c = commands[cursor]
        cursor += 1
        e,m,v = key.split('/')
        ident = f'{cursor:05d}-{e}-{m}-{v}-{label}'
        assert c['id'] == ident and c['log'] == ident+'.log', ('command order/identity', ident)
        assert (c['engine'], c['mode'], c['variant']) == (e,m,v), ('command tuple', ident)
        env = c['env']
        root = str(Path(env['FOUNDRY_OUT']).parent.parent)
        if build_root is None: build_root = root
        assert root == build_root
        assert env == dict(TUPLE_CANDIDATE='false', LIFECYCLE_VARIANT=v, LIFECYCLE_BUDGET=str(budget),
                           FOUNDRY_OUT=f'{root}/{e}/out', FOUNDRY_CACHE_PATH=f'{root}/{e}/cache'), ('command env', ident)
        argv = c['argv']
        binary = argv[0]
        assert binary.endswith('/nightly-4e8874b/forge' if e == 'amsterdam' else '/.foundry/bin/forge')
        expected = [binary,'test','--offline','--match-path',TEST,'--match-contract',f'Lifecycle{m.title()}Test',
                    '--match-test','test_scan_' if scan else 'test_lifecycle','-vvvv' if trace else '-vv']
        if e != 'cancun': expected += ['--evm-version','prague']
        if e == 'amsterdam': expected += ['--no-isolate','--hardfork','amsterdam']
        tail = argv[len(expected):]
        if tail[:1] == ['-R']:
            remap = tail[1]
            prefix = '@chainlink/contracts/='
            suffix = '/contracts/lib/chainlink-brownie-contracts/contracts/'
            assert remap.startswith(prefix) and remap.endswith(suffix)
            deps = remap[len(prefix):-len(suffix)]
            if deps_root is None: deps_root = deps
            assert deps == deps_root
            expected += ['-R',remap,'-R',f'solady/={deps}/contracts/lib/solady/src/']
        if trace and e == 'amsterdam': expected += ['--debug','--dump',f'{root}/debug.json']
        assert argv == expected, ('command argv', ident)
        log = (out/c['log']).read_text()
        count = 241 if scan else 1
        assert c['count'] == count and c['exit'] == 0
        assert hashlib.sha256(log.encode()).hexdigest() == c['sha256']
        assert re.search(rf'{count} tests? passed, 0 failed, 0 skipped', log)
        assert f'{TEST}:Lifecycle{m.title()}Test' in log, ('log mode', ident)
        ps = points(log)
        assert ps and all(k in (0,1,2,3) and (k != 0 or r == selector) and
                          (k not in (1,3) or r == '0x') for g,k,r in ps), ('point classification', ident)
        if budget: assert ps[-1][0] == budget, ('sample budget', ident)
        return ident, ps, log
    for key in keys:
        row = manifest[key]
        e,m,v = key.split('/')
        snap = (v.startswith('rr_') and v != 'rr_no_snapshot') or v == 'fresh_snapshot'
        sid, ps, _ = consume(key,'scan',scan=not snap)
        assert row['scan'] == sid
        scan = ps[:241]
        assert len(scan) == 241 and sorted(g for g,k,r in scan) == list(range(420000,900001,2000)), key
        guards = [g for g,k,r in scan if k == 0]
        completed = [g for g,k,r in scan if k == 3]
        failures = [g for g,k,r in scan if k in (1,2)]
        split = not completed and bool(failures) and all(k == 0 or (k == 2 and r == NOT_LIVE) for g,k,r in scan)
        assert split == (v in SPLIT) and row.get('split',False) == split, ('split classification',key)
        expected = dict(last_guard_scan=max(guards), first_complete_scan=min(completed) if completed else None,
                        non_guard_scan=[min(failures),max(failures)] if failures else None,
                        failure_selectors=sorted({r for g,k,r in scan if k in (1,2)}))
        for field,value in expected.items():
            if field in row or field in ('last_guard_scan','non_guard_scan') or (field == 'first_complete_scan' and not split) or (field == 'failure_selectors' and split):
                assert row[field] == value, ('scan summary',key,field)
        assert row['guard_selector'] == selector, ('guard selector',key)
        if split: continue
        kinds = [k for g,k,r in sorted(scan)]
        assert kinds[0] == 0 and kinds[-1] == 3 and kinds == sorted(kinds), ('nonmonotone scan',key)
        for edge in ('guard','complete'):
            lo = max(guards) if edge == 'guard' else min(completed)-2000
            hi = lo+2000
            def lower(k): return k == 0 if edge == 'guard' else k != 3
            while hi-lo > 1:
                mid = (hi+lo)//2
                _, ps, _ = consume(key,f'bisect-{mid}',mid)
                if lower(ps[-1][1]): lo = mid
                else: hi = mid
            assert row['last_guard' if edge == 'guard' else 'first_complete'] == (lo if edge == 'guard' else hi), ('bisected boundary',key,edge)
            for side,g in [('lo',lo),('hi',hi)]:
                name = edge+'_'+side
                ident, ps, _ = consume(key,f'{name}-{g}',g)
                assert row[name] == ident and lower(ps[-1][1]) == (side == 'lo'), ('boundary',key,name)
        assert row['first_complete'] >= row['last_guard']+1
        budget = (row['last_guard']+row['first_complete'])//2 if failures else row['last_guard']
        tid, ps, trace = consume(key,'trace',budget,trace=True)
        assert row['trace'] == tid and row['trace_budget'] == budget
        assert 'postOp(' in trace
        if row['first_complete'] > row['last_guard']+1: assert '[OutOfGas]' in trace
        if e == 'amsterdam':
            assert row['entry_steps'] == tid+'-entry.json'
            entry = json.loads((out/row['entry_steps']).read_text())
            assert entry and all('state_gas_reservoir' in x['step'] for x in entry)
    assert cursor == len(commands), 'extra commands'
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
