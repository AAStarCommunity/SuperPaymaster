"""Each search sample is a new Forge process: setUp and test are separate transactions."""
import hashlib, importlib.util, json, os, pathlib, re, subprocess, sys, tempfile
from types import SimpleNamespace
out = pathlib.Path(sys.argv[1])
root = pathlib.Path.cwd()
env = os.environ.copy()
build = (SimpleNamespace(name=os.environ['PROFILE_BUILD_ROOT']) if 'PROFILE_BUILD_ROOT' in os.environ
         else tempfile.TemporaryDirectory(prefix='postop-profile-', dir='/tmp'))
subprocess.run([sys.executable, 'script/evidence/postop-gas-profile-probe-check.py'], check=True)
source_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(pathlib.Path('contracts/src').rglob('*.sol'))}
(out / 'source-hashes.json').write_text(json.dumps(source_hashes, indent=2)+'\n')
(out / 'head.txt').write_text(subprocess.check_output(['git','rev-parse','HEAD'],text=True))
(out / 'working-tree.txt').write_text(subprocess.check_output(['git','status','--short'],text=True))
common = ['test', '--offline', '--match-path', 'contracts/test/v2/SuperPaymasterPostOpGasProfile.t.sol', '-vv']
# Optional read-only dependency root for worktrees with unpopulated submodules.
deps = os.environ.get('PROFILE_DEPS_ROOT')
if deps:
    common += ['-R', f'@chainlink/contracts/={deps}/contracts/lib/chainlink-brownie-contracts/contracts/', '-R', f'solady/={deps}/contracts/lib/solady/src/']
engines = {
    'cancun': [os.environ.get('STABLE_FORGE', os.path.expanduser('~/.foundry/bin/forge'))],
    'prague': [os.environ.get('STABLE_FORGE', os.path.expanduser('~/.foundry/bin/forge'))],
    'amsterdam': [os.environ.get('AMS_FORGE', os.path.expanduser('~/Dev/aastar/tools/foundry-rams/nightly-4e8874b/forge'))],
}
results = {}
serial = 0
spec = importlib.util.spec_from_file_location('profile_trace', 'script/evidence/postop-gas-profile-trace.py')
trace_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace_module)
def run(engine, name, extra, expected_count=1, extra_env=None):
    global serial
    serial += 1
    name = f'{serial:04d}-{name}'
    cmd = engines[engine] + common
    if engine != 'cancun': cmd += ['--evm-version', 'prague']
    if engine == 'amsterdam': cmd += ['--no-isolate', '--hardfork', 'amsterdam']
    if '--match-path' in extra:
        i = cmd.index('--match-path')
        del cmd[i:i+2]
    cmd += extra
    e = env | {'FOUNDRY_OUT': f'{build.name}/{engine}/out', 'FOUNDRY_CACHE_PATH': f'{build.name}/{engine}/cache', 'PROFILE_AMSTERDAM': str(engine == 'amsterdam').lower()} | (extra_env or {})
    with (out / 'commands.jsonl').open('a') as f: f.write(json.dumps({'name':name, 'engine':engine, 'argv':cmd, 'profile_env': {k:v for k,v in e.items() if k.startswith('PROFILE_')}})+'\n')
    p = subprocess.run(cmd, env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / f'{engine}-{name}.log').write_text(p.stdout)
    with (out / 'exits.txt').open('a') as f: f.write(f'{engine}-{name} exit {p.returncode}\n')
    assert p.returncode == 0, f'{engine}-{name}: exit {p.returncode}'
    assert re.search(rf': {expected_count} tests? passed, 0 failed, 0 skipped', p.stdout), f'{engine}-{name}: missing/wrong test count'
    return p.stdout
for engine in ['cancun', 'prague', 'amsterdam']:
    results[engine] = {}
    (out / f'{engine}-version.txt').write_text(subprocess.check_output(engines[engine]+['--version'],text=True))
    run(engine, 'assertions', [], 14)
    for mode in ['balance', 'credit']:
        for path in ['entrypoint', 'direct']:
            def sample(g):
                name = f'{mode}-{path}-{g}'
                log = run(engine, name, ['--match-contract', f'^PostOpProfile{mode.title()}Test$', '--match-test', 'test_search_sample'], extra_env={'PROFILE_BUDGET':str(g), 'PROFILE_REAL_EP':str(path == 'entrypoint').lower()})
                found = re.findall(r'sample completed: ([01])', log)
                assert len(found) == 1
                return found[0] == '1'
            lo = 418000
            assert not sample(lo)
            for hi in range(lo + 2000, 900001, 2000):
                if sample(hi): break
                lo = hi
            else: raise AssertionError('search exhausted')
            while hi - lo > 1:
                mid = (lo + hi)//2
                if sample(mid): hi = mid
                else: lo = mid
            assert sample(hi) and not sample(hi-1)
            expected = 440000 if path == 'entrypoint' else (438828 if engine == 'amsterdam' else 431514)
            assert hi == expected, (engine, mode, path, hi, expected)
            results[engine][f'{mode}-{path}'] = hi
            print(engine, mode, path, hi, flush=True)
    if engine == 'amsterdam':
        for mode in ['balance', 'credit']:
            dump = pathlib.Path(build.name) / f'{mode}-steps.json'
            run(engine, f'{mode}-steps', ['--match-contract', f'^PostOpProfile{mode.title()}Test$', '--match-test', 'test_search_sample', '--debug', '--dump', str(dump)], extra_env={'PROFILE_BUDGET':'440000','PROFILE_REAL_EP':'true'})
            trajectory = trace_module.reduce_trace(dump)
            (out / f'{mode}-steps.json').write_text(json.dumps(trajectory, separators=(',',':'))+'\n')
            results[engine][f'{mode}-trajectory'] = {k:v for k,v in trajectory.items() if k not in ('chunks','columns')}
            dump.unlink()
    run(engine, 'snapshot-comparison', ['--match-path','contracts/test/v2/SuperPaymasterRR5GuardFail.t.sol','--match-test','test_RR5_diag_scan_band'], 2)
    (out / 'numbers.json').write_text(json.dumps(results, indent=2)+'\n')
assert source_hashes == {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(pathlib.Path('contracts/src').rglob('*.sol'))}, 'production source changed'
subprocess.run([sys.executable, 'script/evidence/postop-gas-profile-verify.py', str(out)], check=True)
(out / 'verdict.txt').write_text('VERDICT PASS: all exits zero; exact test counts; frozen thresholds; fresh-process searches; nonempty trajectories\n'+json.dumps(results, indent=2)+'\n')
(out / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in sorted(out.iterdir()) if p.is_file() and p.name != 'SHA256SUMS'))
print((out / 'verdict.txt').read_text())
