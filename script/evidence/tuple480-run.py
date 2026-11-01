"""Offline tuple evidence. No source mutations. Output must be empty.

--verify validates the complete inventory, command selectors, outcomes and hashes.
The full suites intentionally retain failing floor/frozen tests; acceptance of the
artifact means complete evidence, not a claim that every property passed.
"""
import hashlib
import importlib.util
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import shutil
import sys
import tempfile

ENGINES = ('amsterdam', 'cancun', 'prague')
ROOT = Path(__file__).resolve().parents[2]

def inventory():
    rows = []
    for e, candidate in itertools.product(ENGINES, (False, True)):
        rows.append(dict(id=f'full-{e}-{int(candidate)}', engine=e, candidate=candidate, kind='full'))
    for candidate in (False, True):
        rows.append(dict(id=f'accounting-{int(candidate)}', engine='amsterdam', candidate=candidate, kind='accounting'))
    for n, pattern, distinct in itertools.product((2,3,5), range(4), (False,True)):
        rows.append(dict(id=f'multi-{n}-{pattern}-{int(distinct)}', engine='amsterdam', candidate=True,
                         kind='multi', n=n, pattern=pattern, distinct=distinct))
    for limit, pattern in itertools.product((440000,470000,480000), (0,1)):
        rows.append(dict(id=f'worst-net-{limit}-{pattern}', engine='amsterdam', candidate=limit==480000, kind='worst-net', limit=limit, pattern=pattern))
    for e, settle, credit, legacy, nonfresh in itertools.product(ENGINES, (420000,450000,480000,500000), (False,True), (False,True), (False,True)):
        low,high=100000,800000
        step=0
        while True:
            budget=low if step==0 else high if step==1 else (low+high)//2
            row=dict(id=f'scan-{e}-{settle}-{int(credit)}-{int(legacy)}-{int(nonfresh)}-{step}', engine=e, candidate=True, kind='scan', settle=settle, credit=credit, legacy=legacy, nonfresh=nonfresh, budget=budget)
            rows.append(row)
            if not (EVIDENCE/(row['id']+'.log')).exists():
                return rows
            log=(EVIDENCE/(row['id']+'.log')).read_text()
            m=re.search(r'admission accepted: (0|1)',log)
            assert m, row['id']+' missing admission measurement'
            accepted=int(m[1])
            if step==0: assert not accepted, 'low endpoint not guard rejection'
            elif step==1: assert accepted, 'high endpoint rejected'
            elif accepted: high=budget
            else: low=budget
            step+=1
            if step>=2 and high-low==1: break
    return rows

def source_hashes():
    paths = list(Path('contracts/src').rglob('*.sol')) + list(Path('contracts/test').rglob('*.sol'))
    paths += [Path('foundry.toml'), Path('script/evidence/tuple480-run.py'), Path('contracts/test/tuple_validation_evidence_test.py'), Path('script/evidence/tuple480-run.sh'), Path('script/evidence/postop-gas-profile-trace.py')]
    paths += [p for p in Path('contracts/test/fixtures').rglob('*') if p.is_file()]
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths) if p.is_file()}

def source_hashes_at(revision):
    """source_hashes() as it would have read the tree at `revision` (tracked files only)."""
    names = subprocess.check_output(['git','ls-tree','-r','--name-only',revision],cwd=ROOT,text=True).splitlines()
    fixed = {'foundry.toml','script/evidence/tuple480-run.py','contracts/test/tuple_validation_evidence_test.py',
             'script/evidence/tuple480-run.sh','script/evidence/postop-gas-profile-trace.py'}
    chosen = [n for n in names if (n.startswith(('contracts/src/','contracts/test/')) and n.endswith('.sol'))
              or n in fixed or n.startswith('contracts/test/fixtures/')]
    return {n: hashlib.sha256(subprocess.check_output(['git','show',f'{revision}:{n}'],cwd=ROOT)).hexdigest()
            for n in sorted(chosen)}

def selectors(row):
    e = row['engine']
    env = {'TUPLE_480':str(row['candidate']).lower(), 'PROFILE_AMSTERDAM':str(e=='amsterdam').lower()}
    args = []
    if row['kind'] == 'accounting':
        args = ['--match-contract','SuperPaymasterV55FuzzTest', '--match-test','test_G2_coverage_replay_fixed_seeds']
        env['TUPLE_ACCOUNTING']='true'
    elif row['kind']=='worst-net':
        args = ['--match-contract','PostOpMultiOpTest', '--match-test','test_bundle', '-vvvv']
        env |= {'MULTI_N':'5', 'MULTI_PATTERN':str(row['pattern']), 'MULTI_DISTINCT':'false', 'PROFILE_BUDGET':str(row['limit']), 'TUPLE_CANDIDATE':str(row['limit']==470000).lower()}
    elif row['kind']=='multi':
        args = ['--match-contract','PostOpMultiOpTest', '--match-test','test_bundle']
        env |= {'MULTI_N':str(row['n']), 'MULTI_PATTERN':str(row['pattern']), 'MULTI_DISTINCT':str(row['distinct']).lower(),'PROFILE_BUDGET':'480000'}
    elif row['kind']=='scan':
        args=['--match-contract','Tuple480AdmissionTest','--match-test','test_tuple480_sample']
        env |= {'T480_SETTLE':str(row['settle']), 'T480_BUDGET':str(row['budget']), 'T480_CREDIT':str(row['credit']).lower(), 'T480_LEGACY':str(row['legacy']).lower(), 'T480_NONFRESH':str(row['nonfresh']).lower()}
    return args, env

def statuses(log):
    result={}
    suite=None
    for line in log.splitlines():
        m=re.match(r'Ran \d+ tests? for (.*)',line)
        if m: suite=m[1]
        if line.startswith('Failing tests:'): break
        if line in ('[PASS]', '[FAIL]', '[SKIP]') and suite:
            result[suite+'::<invariant-group>']=line[1:-1]
        m=re.match(r'\[(PASS|FAIL.*|SKIP.*?)\] (\w+\([^)]*\))',line)
        if m and suite: result[suite+'::'+m[2]]=m[1].split(':')[0]
    return result

def seal(out):
    (out/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(out.iterdir()) if p.is_file() and p.name!='SHA256SUMS'))

def scan_sample(log, budget):
    def field(label):
        values = re.findall(r'^\s*' + re.escape(label) + r': (\d+)\s*$', log, re.M)
        assert len(values) == 1, 'missing or duplicate ' + label
        return int(values[0])
    raw_budget = field('sample gas')
    assert raw_budget == budget, 'sample gas contradicts command budget'
    accepted, complete = field('admission accepted'), field('settlement completed')
    assert accepted in (0, 1) and complete in (0, 1)
    assert not complete or accepted, 'completion contradicts rejection'
    return raw_budget, accepted, complete


def verify_engines(out):
    stable = ('forge Version: 1.7.1\n'
              'Commit SHA: 4072e48705af9d93e3c0f6e29e93b5e9a40caed8\n'
              'Build Timestamp: 2026-05-08T07:54:31.470926000Z (1778226871)\n'
              'Build Profile: dist\n')
    nightly = ('forge Version: 1.8.7-nightly\n'
               'Commit SHA: 4e8874b2bdc840929585ca73e170993c50a4a531\n'
               'Build Timestamp: 2026-10-23T06:12:21.643861000Z (1792735941)\n'
               'Build Profile: dist\n')
    for engine in ENGINES:
        assert (out/f'{engine}-version.txt').read_bytes() == (
            nightly if engine == 'amsterdam' else stable).encode(), 'wrong engine version'


def verify_engine_command(row):
    engine, argv = row['engine'], row['argv']
    executable = ('/Users/jason/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge'
                  if engine == 'amsterdam' else '/Users/jason/.foundry/bin/forge')
    assert argv[0] == executable, 'wrong engine executable'
    for flag, expected in (
        ('--evm-version', [] if engine == 'cancun' else ['prague']),
        ('--hardfork', ['amsterdam'] if engine == 'amsterdam' else []),
    ):
        values = []
        for i, arg in enumerate(argv):
            if arg == flag:
                assert i + 1 < len(argv), 'missing engine flag value'
                values.append(argv[i + 1])
            elif arg.startswith(flag + '='):
                values.append(arg.split('=', 1)[1])
        assert values == expected, 'wrong engine flags: ' + flag


def verify_boundaries(groups):
    assert len(groups) == 96, 'missing scan paths'
    boundaries = {}
    for key, samples in groups.items():
        low = max(b for b, a, c in samples if not a)
        high = min(b for b, a, c in samples if a)
        assert high == low + 1, 'non-adjacent boundary'
        boundaries[key] = (high, all(c for b, a, c in samples if b == high))
    for engine in ENGINES:
        paths = {k: v for k, v in boundaries.items() if k[0] == engine and k[1] == 450000}
        assert len(paths) == 8, 'missing R1 paths'
        maximum = max(b for b, c in paths.values())
        assert 480000 - maximum >= 10000, 'R1 margin below 10000'
        assert all(c for b, c in paths.values() if b == maximum), 'R1 maximum did not complete'


def verify_penalty_evidence(out, penalties):
    # Original extraction is pinned because the debug arenas (including DIV stacks)
    # were discarded. This is archival integrity, not independent execution proof.
    assert hashlib.sha256((out/'penalties.json').read_bytes()).hexdigest() == (
        'c31eb4f72d25431ab9221e3a34f22d740d52f1ce8d500f190d41217031e22f64'
    ), 'penalty extraction differs from pinned archive'
    # Retained verbose replays corroborate the ten N=5 single-mode operands.
    for pattern in (0, 1):
        log = (out/f'worst-net-480000-{pattern}.log').read_text()
        operations = re.findall(
            r'::innerHandleOp\(.*?callGasLimit: (\d+).*?paymasterPostOpGasLimit: (\d+)'
            r'.*?userOpHash: (0x[0-9a-f]+).*?preOpGas: (\d+)', log)
        events = re.findall(
            r'emit UserOperationEvent\(userOpHash: (0x[0-9a-f]+).*?actualGasUsed: (\d+)', log)
        assert len(operations) == len(events) == 5, 'missing penalty execution evidence'
        for (call, post, op_hash, pre), (event_hash, gas), p in zip(
                operations, events, penalties[f'multi-5-{pattern}-0']):
            assert op_hash == event_hash, 'penalty operation mismatch'
            execution = int(gas) - p['penalty'] - int(pre)
            assert p['unused'] == max(0, int(call) + int(post) - execution), 'penalty contradicts execution gas'


def verify(out):
    verify_engines(out)
    rows=[json.loads(x) for x in (out/'commands.jsonl').read_text().splitlines()]
    # inventory() is measurement code: redirect its input only during verification.
    global EVIDENCE
    previous = globals().get('EVIDENCE')
    EVIDENCE = out
    try:
        wanted = inventory()
    finally:
        EVIDENCE = previous
    groups = {}
    assert wanted[-1]['id'].startswith('scan-prague-500000-1-1-1-'), 'incomplete scans'
    assert (out/(wanted[-1]['id']+'.log')).exists(), 'missing last sample'
    assert len(rows)==len(wanted), 'missing command inventory'
    assert len({r['id'] for r in rows})==len(rows), 'duplicate command'
    for row, spec in zip(rows,wanted):
        assert all(row[k]==v for k,v in spec.items()), 'wrong inventory/order'
        args,env=selectors(spec)
        assert row['env']==env, 'wrong environment selectors'
        verify_engine_command(row)
        argv=row['argv']
        assert argv[1:]==row['base_args']+args+row.get('debug_args',[])
        base=row['base_args']
        assert base[:5]==['test','--offline','--fuzz-seed','0x5eed','-vv']
        assert not any(a.startswith('--match') or a.startswith('--no-match') for a in base)
        assert '--no-isolate' in base if spec['engine']=='amsterdam' else '--no-isolate' not in base
        if spec['engine']=='amsterdam': assert base[base.index('--hardfork')+1]=='amsterdam'
        log=(out/(row['id']+'.log')).read_text()
        if spec['kind'] == 'scan':
            key = tuple(spec[k] for k in ('engine', 'settle', 'credit', 'legacy', 'nonfresh'))
            groups.setdefault(key, []).append(scan_sample(log, row['budget']))
        else:
            # Full suites also log their default admission probe.
            for budget in re.findall(r'^\s*sample gas: (\d+)\s*$', log, re.M):
                assert int(budget) == int(row['env'].get('T480_BUDGET', 600000)), 'sample gas contradicts command budget'
        st=statuses(log)
        assert st, 'missing completed tests'
        summary=re.search(r': (\d+) tests? passed, (\d+) failed, (\d+) skipped',log)
        assert summary, 'incomplete suite'
        assert tuple(sum(v==k for v in st.values()) for k in ('PASS','FAIL','SKIP'))==tuple(map(int,summary.groups())), 'test inventory does not match summary'
        assert row['exit']==(1 if 'FAIL' in st.values() else 0), 'inconsistent exit'
        if spec['kind']=='full': assert len(st)>1500, 'truncated full suite'
        elif spec['kind']=='accounting':
            assert len(st)==1
            assert row['exit']==(0 if spec['candidate'] else 1), 'reimbursement control'
            if not spec['candidate']: assert 'DSR no-subsidy' in log and 'tuple net charge:' in log
        else: assert len(st)==1 and row['exit']==0, 'measurement failed'
    verify_boundaries(groups)
    numbers=json.loads((out/'numbers.json').read_text())
    required={r['id']:r for r in wanted if r['kind']=='multi'}
    assert set(numbers)==set(required)
    for name,frames in numbers.items():
        assert len(frames)==required[name]['n']
        retained=json.loads((out/(name+'-steps.json')).read_text())
        assert len(retained)==len(frames)
        for summary, trajectory in zip(frames,retained):
            assert summary=={k:v for k,v in trajectory.items() if k not in ('chunks','columns')}
            steps=[s for c in trajectory['chunks'] for s in c['steps']]
            assert trajectory['initial']==steps[0][2]
            assert trajectory['terminal']==steps[-1][2]-steps[-1][3]
            assert trajectory['minimum_remaining']==min([s[5] for s in steps]+[trajectory['terminal']])
        for f in frames:
            assert f['initial']==480000 and f['peak']==480000-f['minimum_remaining']
            assert f['net']==480000-f['terminal'] and f['minimum_remaining']>0
    penalties=json.loads((out/'penalties.json').read_text())
    assert set(penalties)==set(required)
    for name,ps in penalties.items():
        assert len(ps)==required[name]['n']
        for p in ps:
            assert p['pc']==7838 and p['denominator']==100
            assert p['numerator']==p['unused']*10 and p['penalty']==p['numerator']//100
    verify_penalty_evidence(out, penalties)
    assert sum(len(fs) for fs in numbers.values())==80
    assert max(f['peak'] for fs in numbers.values() for f in fs)*115 <= 450000*100
    assert max(f['net'] for fs in numbers.values() for f in fs)*115 <= 450000*100
    manifest={line.split('  ',1)[1]:line.split('  ',1)[0] for line in (out/'SHA256SUMS').read_text().splitlines()}
    assert set(manifest)=={p.name for p in out.iterdir() if p.is_file() and p.name!='SHA256SUMS'}
    for name,digest in manifest.items(): assert hashlib.sha256((out/name).read_bytes()).hexdigest()==digest, name
    # Bind the recorded source hashes to the recorded revision, not to the current tree: later commits may add or
    # change tests (or repair this verifier) without invalidating a measurement made at that revision.
    revision = (out/'head.txt').read_text().strip()
    assert re.fullmatch(r'[0-9a-f]{40}', revision), 'invalid recorded revision'
    assert json.loads((out/'source-hashes.json').read_text())==source_hashes_at(revision), 'sources differ from the recorded revision'
    return rows


def cancun_mirror(build, hashes):
    """Preserve hard-coded out/ artifact checks without writing outside allowed repo paths."""
    mirror=Path(os.environ.get('TUPLE_CANCUN_ROOT') or tempfile.mkdtemp(prefix='tuple-cancun-',dir='/tmp')).resolve()
    assert str(mirror).startswith('/private/tmp/') or str(mirror).startswith('/tmp/')
    if not (mirror/'contracts').exists():
        for name in ('contracts','singleton-paymaster','script','abis','deployments'):
            shutil.copytree(ROOT/name,mirror/name,ignore=lambda p,n:[x for x in n if x.startswith('.tuple-build-') or x in ('.git','node_modules','__pycache__','out','cache')])
        shutil.copy2(ROOT/'foundry.toml',mirror/'foundry.toml')
        for name in ('out','cache'):
            if (build/'cancun'/name).exists(): shutil.copytree(build/'cancun'/name,mirror/name)
        cache=mirror/'cache/solidity-files-cache.json'
        if cache.exists():
            data=json.loads(cache.read_text())
            data['paths']['artifacts']=str(mirror/'out')
            data['paths']['build_infos']=str(mirror/'out/build-info')
            cache.write_text(json.dumps(data))
    copied={k:hashlib.sha256((mirror/k).read_bytes()).hexdigest() for k in hashes if k.startswith(('contracts/src/','contracts/test/'))}
    assert all(copied[k]==hashes[k] for k in copied), 'mirror sources differ'
    return mirror,copied

def main(out):
    out.mkdir(parents=True,exist_ok=True)
    if any(out.iterdir()): raise SystemExit('Output directory must be empty')
    before=source_hashes()
    (out/'source-hashes.json').write_text(json.dumps(before,indent=2)+'\n')
    (out/'head.txt').write_text(subprocess.check_output(['git','rev-parse','HEAD'],text=True))
    build=Path(os.environ.get('TUPLE_BUILD_ROOT') or tempfile.mkdtemp(prefix='.tuple-build-',dir='contracts/test')).resolve()
    assert build.is_relative_to((ROOT/'contracts/test').resolve()), 'build must remain in contracts/test'
    build.mkdir(parents=True,exist_ok=True)
    (build/'.gitignore').write_text('*\n')
    mirror,copied=cancun_mirror(build,before)
    (out/'cancun-mirror-sources.json').write_text(json.dumps(copied,indent=2)+'\n')
    engines={e:os.path.expanduser('~/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge' if e=='amsterdam' else '~/.foundry/bin/forge') for e in ENGINES}
    for e,exe in engines.items(): (out/f'{e}-version.txt').write_text(subprocess.check_output([exe,'--version'],text=True))
    spec=importlib.util.spec_from_file_location('trace',ROOT/'script/evidence/postop-gas-profile-trace.py')
    trace=importlib.util.module_from_spec(spec);spec.loader.exec_module(trace)
    numbers={}; states={}; penalties={}
    failures=Path(tempfile.mkdtemp(prefix='tuple-fuzz-',dir='/tmp'))
    # Ignore ambient experiment overrides. Cache/fuzz failures are private to this run.
    clean={k:v for k,v in os.environ.items() if not k.startswith(('FOUNDRY_','G2_','PROFILE_','MULTI_','TUPLE_','T480_'))}
    deps=os.environ.get('PROFILE_DEPS_ROOT') or sys.exit('PROFILE_DEPS_ROOT must name a checkout with initialized submodules')
    index=0
    while index < len(inventory()):
        row=inventory()[index]
        index+=1
        e=row['engine'];args,env=selectors(row)
        base=['test','--offline','--fuzz-seed','0x5eed','-vv']
        if e=='cancun': base += ['--root',str(mirror),'-R',f'forge-std/={ROOT}/contracts/lib/forge-std/src/']
        if e!='cancun': base += ['--evm-version','prague']
        if e=='amsterdam': base += ['--no-isolate','--hardfork','amsterdam']
        base += ['-R',f'@chainlink/contracts/={deps}/contracts/lib/chainlink-brownie-contracts/contracts/','-R',f'solady/={deps}/contracts/lib/solady/src/']
        debug=[];dump=build/(row['id']+'.json')
        if row['kind']=='multi': debug=['--debug','--dump',str(dump)]
        cmd=[engines[e]]+base+args+debug
        runenv=clean|env|{'FOUNDRY_OUT':str(build/e/'out'),'FOUNDRY_CACHE_PATH':str(build/e/'cache'),'FOUNDRY_FUZZ_FAILURE_PERSIST_DIR':str(failures/row['id'])}
        if e=='cancun': runenv |= {'FOUNDRY_OUT':str(mirror/'out'),'FOUNDRY_CACHE_PATH':str(mirror/'cache')}
        print('START',row['id'],flush=True)
        with (out/(row['id']+'.log')).open('w') as f:
            p=subprocess.run(cmd,env=runenv,stdout=f,stderr=subprocess.STDOUT)
        row |= dict(argv=cmd,base_args=base,debug_args=debug,env=env,build_env={k:v for k,v in runenv.items() if k.startswith('FOUNDRY_')},exit=p.returncode)
        with (out/'commands.jsonl').open('a') as f: f.write(json.dumps(row)+'\n')
        print('END',row['id'],p.returncode,flush=True)
        log=(out/(row['id']+'.log')).read_text()
        states[row['id']]=statuses(log)
        if dump.exists():
            arena=json.loads(dump.read_text())['debug_arena']
            frames=trace.reduce_arena(arena)
            # PC 7838 is DIV at the v0.7 unused-gas penalty, checked against the pinned runtime.
            runtime=bytes.fromhex(Path('contracts/test/fixtures/entrypoint-v0.7.runtime.hex').read_text().strip().removeprefix('0x'))
            assert runtime[7838]==4
            penalty=[]
            for node in arena:
                if node['address'].lower()!='0x0000000071727de22e5e9d8baf0edac6f37da032': continue
                for step in node['steps']:
                    if step['pc']==7838 and step['op']==4:
                        numerator,denominator=[int(x,16) for x in step['stack'][-2:]][::-1]
                        assert denominator==100 and numerator%10==0
                        penalty.append(dict(pc=7838,numerator=numerator,denominator=denominator,unused=numerator//10,penalty=numerator//denominator))
            penalties[row['id']]=penalty
            (out/(row['id']+'-steps.json')).write_text(json.dumps(frames,separators=(',',':'))+'\n')
            numbers[row['id']]=[{k:v for k,v in f.items() if k not in ('chunks','columns')} for f in frames]
            dump.unlink()
    (out/'penalties.json').write_text(json.dumps(penalties,indent=2)+'\n')
    (out/'numbers.json').write_text(json.dumps(numbers,indent=2)+'\n')
    (out/'statuses.json').write_text(json.dumps(states,indent=2)+'\n')
    assert before==source_hashes(), 'sources changed during execution'
    seal(out)
    verify(out)
    # Resealed missing-case negative control must still be rejected.
    with tempfile.TemporaryDirectory(prefix='tuple-negative-',dir='/tmp') as tmp:
        neg=Path(tmp)/'run';shutil.copytree(out,neg)
        lines=(neg/'commands.jsonl').read_text().splitlines()
        (neg/'commands.jsonl').write_text('\n'.join(lines[:-1])+'\n');seal(neg)
        try: verify(neg)
        except AssertionError as exc: (out/'negative-control.txt').write_text(f'Resealed missing command rejected: {exc}\nexit 1\n')
        else: raise AssertionError('negative control accepted')
    (out/'verdict.txt').write_text(f'PASS: complete evidence inventory ({len(inventory())} commands); candidate accounting and measurements pass. Full-suite failures retained in statuses.json.\n')
    seal(out);verify(out)

if __name__=='__main__':
    os.chdir(ROOT)
    EVIDENCE=Path(sys.argv[2] if sys.argv[1]=='--verify' else sys.argv[1]).resolve()
    if sys.argv[1]=='--verify': verify(Path(sys.argv[2]));print('Evidence verified')
    else: main(Path(sys.argv[1]))
