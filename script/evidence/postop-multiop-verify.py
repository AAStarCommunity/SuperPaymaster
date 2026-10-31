"""Fail closed: fixed complete inventory, successful tests, trajectories, frozen numbers, hashes."""
import hashlib, importlib.util, json, pathlib, re, sys

def module(name, path):
    spec = importlib.util.spec_from_file_location(name,path)
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

runner = module('runner','script/evidence/postop-multiop-run.py')
FROZEN = pathlib.Path('contracts/test/fixtures/postop-multiop-expected.json')

def verify(out):
    expected = json.loads(FROZEN.read_text())
    records = [json.loads(line) for line in (out/'commands.jsonl').read_text().splitlines()]
    wanted = {runner.case_id(*args): args for args in runner.inventory()}
    worst = max((f['peak'],name,i) for name,fs in expected.items() for i,f in enumerate(fs))
    floor_id = worst[1] + '-floor-439999'
    assert len(records) == 73, 'requires 72 matrix cases plus admission-floor control'
    ids = [r['id'] for r in records]
    assert len(set(ids)) == len(ids) and set(ids) == set(wanted) | {floor_id}, 'missing/duplicate/unexpected case'
    sums = {}
    for line in (out/'SHA256SUMS').read_text().splitlines():
        digest,name = line.split('  ',1)
        assert pathlib.Path(name).name == name and name not in sums
        sums[name] = digest
    assert set(sums) == {p.name for p in out.iterdir() if p.is_file() and p.name != 'SHA256SUMS'}, 'manifest inventory'
    for name,digest in sums.items(): assert hashlib.sha256((out/name).read_bytes()).hexdigest() == digest, name
    assert json.loads((out/'source-hashes.json').read_text()) == runner.hashes(), 'source drift'
    numbers = json.loads((out/'numbers.json').read_text())
    assert numbers == expected, 'frozen per-op gas measurements changed'
    assert set(numbers) == {k for k in wanted if k.startswith('amsterdam-')}
    for r in records:
        name = r['id']; floor = name == floor_id
        engine,n,mode,distinct = wanted[worst[1] if floor else name]
        budget = 439999 if floor else 440000
        assert (r['engine'],r['n'],r['mode'],r['distinct'],r['budget']) == (engine,n,mode,distinct,budget)
        assert r['exit'] == 0
        assert r['env'] == dict(MULTI_N=str(n),MULTI_PATTERN=str(runner.MODES.index(mode)),MULTI_DISTINCT=str(distinct).lower(),PROFILE_BUDGET=str(budget))
        cmd = r['argv']
        assert cmd[0] == str(pathlib.Path('~/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge' if engine == 'amsterdam' else '~/.foundry/bin/forge').expanduser())
        for flag,value in [('--match-path','contracts/test/v2/SuperPaymasterPostOpMultiOp.t.sol'),('--match-contract','^PostOpMultiOpTest$'),('--match-test','test_bundle'),('--evm-version','cancun' if engine == 'cancun' else 'prague')]:
            assert cmd.count(flag) == 1 and cmd[cmd.index(flag)+1] == value
        assert '--offline' in cmd
        if engine == 'amsterdam': assert '--no-isolate' in cmd and cmd[cmd.index('--hardfork')+1] == 'amsterdam'
        log = (out/f'{name}.log').read_text()
        assert re.search(r'^Suite result: ok\. 1 passed; 0 failed; 0 skipped;', log, re.M), name
        assert re.search(r'^Ran 1 test suite .*: 1 tests passed, 0 failed, 0 skipped \(1 total tests\)$', log, re.M), name
        assert (f'admission rejected: {budget}' if floor else f'completed operations: {n}') in log, name
        if engine != 'amsterdam' or floor: continue
        assert '--debug' in cmd and '--dump' in cmd
        frames = json.loads((out/f'{name}-steps.json').read_text())
        assert len(frames) == n
        for i,f in enumerate(frames):
            assert {k:v for k,v in f.items() if k not in ['chunks','columns']} == expected[name][i]
            assert f['initial'] == 440000 and f['chunks']
            assert f['chunks'][0]['selector'] == '0x7c627b21'
            low = f['initial']; terminal = None
            for c in f['chunks']:
                assert c['steps']
                for pc,op,remaining,cost,reservoir,total in c['steps']:
                    assert total == remaining + c['held_by_ancestors']
                    low = min(low,total)
            last = f['chunks'][-1]
            assert last['node'] == f['chunks'][0]['node'] and last['steps'][-1][1] in [0,243]
            terminal = last['steps'][-1][2] - last['steps'][-1][3]
            low = min(low,terminal)
            assert f['terminal'] == terminal and f['minimum_remaining'] == low
            assert f['peak'] == 440000-low and f['net'] == 440000-terminal
    return worst

if __name__ == '__main__':
    print('VERDICT PASS:', verify(pathlib.Path(sys.argv[1])), '; 73/73 commands, 24 trajectories, frozen per-op numbers')
