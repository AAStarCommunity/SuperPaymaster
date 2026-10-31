"""Fresh Forge process/deployment per case; requires an empty output directory."""
import hashlib, importlib.util, json, os, pathlib, re, subprocess, sys, tempfile

MODES = ['balance', 'credit', 'mixed-bc', 'mixed-cb']
def inventory():
    return [(engine, n, mode, distinct) for engine in ['amsterdam', 'cancun', 'prague']
            for n in [2, 3, 5] for mode in MODES for distinct in [False, True]]
def case_id(engine, n, mode, distinct):
    return f'{engine}-{n}-{mode}-{"distinct" if distinct else "same"}'
def hashes():
    paths = list(pathlib.Path('contracts/src').rglob('*.sol')) + [pathlib.Path(p) for p in [
        'contracts/test/v2/SuperPaymasterPostOpMultiOp.t.sol', 'contracts/test/v2/SuperPaymasterPostOpGasProfile.t.sol',
        'script/evidence/postop-gas-profile-trace.py', 'script/evidence/postop-multiop-run.py',
        'script/evidence/postop-multiop-verify.py', 'script/evidence/postop-multiop-run.sh',
        'contracts/test/postop_multiop_evidence_test.py', 'contracts/test/fixtures/postop-multiop-expected.json',
        'contracts/test/fixtures/entrypoint-v0.7.runtime.hex', 'contracts/test/helpers/DeploymentGasFixtures.sol',
        'contracts/test/helpers/V55TestFixtures.sol', 'contracts/test/helpers/V55FuzzFixtures.sol',
        'contracts/test/helpers/UUPSDeployHelper.sol', 'foundry.toml']]
    return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}

def main():
    out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    if list(out.iterdir()): raise SystemExit('Output directory must be empty')
    before = hashes()
    (out/'source-hashes.json').write_text(json.dumps(before, indent=2)+'\n')
    (out/'head.txt').write_text(subprocess.check_output(['git','rev-parse','HEAD'], text=True))
    spec = importlib.util.spec_from_file_location('trace', 'script/evidence/postop-gas-profile-trace.py')
    trace = importlib.util.module_from_spec(spec); spec.loader.exec_module(trace)
    build = pathlib.Path(os.environ.get('PROFILE_BUILD_ROOT') or tempfile.mkdtemp(prefix='multiop-', dir='/tmp'))
    engines = {e: os.path.expanduser('~/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge' if e == 'amsterdam' else '~/.foundry/bin/forge') for e in ['amsterdam','cancun','prague']}
    for e, exe in engines.items():
        (out/f'{e}-version.txt').write_text(subprocess.check_output([exe,'--version'], text=True))
    results = {}
    def run(e,n,mode,distinct,budget=440000):
        name = case_id(e,n,mode,distinct) + (f'-floor-{budget}' if budget != 440000 else '')
        dump = build/f'{name}.json'
        cmd = [engines[e], 'test','--offline','--match-path','contracts/test/v2/SuperPaymasterPostOpMultiOp.t.sol', '--match-contract','^PostOpMultiOpTest$', '--match-test','test_bundle', '-vv', '--evm-version', 'prague' if e != 'cancun' else 'cancun']
        if e == 'amsterdam': cmd += ['--no-isolate','--hardfork','amsterdam']
        deps = os.environ.get('PROFILE_DEPS_ROOT')
        if deps:
            cmd += ['-R',f'@chainlink/contracts/={deps}/contracts/lib/chainlink-brownie-contracts/contracts/', '-R',f'solady/={deps}/contracts/lib/solady/src/']
        if e == 'amsterdam' and budget == 440000: cmd += ['--debug','--dump',str(dump)]
        profile = {'MULTI_N':str(n),'MULTI_PATTERN':str(MODES.index(mode)), 'MULTI_DISTINCT':str(distinct).lower(), 'PROFILE_BUDGET':str(budget)}
        env = os.environ | profile | {'FOUNDRY_OUT':str(build/e/'out'),'FOUNDRY_CACHE_PATH':str(build/e/'cache')}
        p = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (out/f'{name}.log').write_text(p.stdout)
        row = dict(id=name,engine=e,n=n,mode=mode,distinct=distinct,budget=budget,argv=cmd,env=profile,exit=p.returncode)
        with (out/'commands.jsonl').open('a') as f: f.write(json.dumps(row)+'\n')
        assert p.returncode == 0 and re.search(r'^Suite result: ok\. 1 passed; 0 failed; 0 skipped;', p.stdout, re.M), name
        assert f'completed operations: {n}' in p.stdout if budget == 440000 else f'admission rejected: {budget}' in p.stdout
        if dump.exists():
            frames = trace.reduce_arena(json.loads(dump.read_text())['debug_arena'])
            assert len(frames) == n
            (out/f'{name}-steps.json').write_text(json.dumps(frames,separators=(',',':'))+'\n')
            results[name] = [{k:v for k,v in f.items() if k not in ['chunks','columns']} for f in frames]
            dump.unlink()
        print(name, 'exit', p.returncode, results.get(name,''), flush=True)
    for args in inventory(): run(*args)
    worst = max(((f['peak'], name, i) for name, fs in results.items() for i,f in enumerate(fs)))
    _,name,_ = worst
    args = next(args for args in inventory() if case_id(*args) == name)
    run(*args,budget=439999)
    (out/'numbers.json').write_text(json.dumps(results,indent=2)+'\n')
    assert before == hashes(), 'sources changed during run'
    (out/'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(out.iterdir()) if p.is_file()))
    print('Worst:',worst)
    subprocess.run([sys.executable, 'script/evidence/postop-multiop-verify.py', str(out)], check=True)

if __name__ == '__main__': main()
