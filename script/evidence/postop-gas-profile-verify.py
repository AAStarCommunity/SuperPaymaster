"""Fail closed on incomplete, empty, failing, or numerically changed evidence."""
import json, pathlib, re, sys

def verify(out):
    commands = [json.loads(l) for l in (out / 'commands.jsonl').read_text().splitlines()]
    exits = (out / 'exits.txt').read_text().splitlines()
    assert commands and len(commands) == len(exits), 'missing commands/exits'
    for command, exit_line in zip(commands, exits):
        stem = f"{command['engine']}-{command['name']}"
        assert exit_line == f'{stem} exit 0', exit_line
        log = (out / f'{stem}.log').read_text()
        count = 14 if command['name'].endswith('-assertions') else 2 if command['name'].endswith('-snapshot-comparison') else 1
        assert re.search(rf': {count} tests? passed, 0 failed, 0 skipped', log), f'{stem}: empty/wrong test summary'
        if command['name'].endswith('-snapshot-comparison'):
            sections = re.split(r'Ran \d+ tests? for ', log)[1:]
            assert len(sections) == 2
            for section in sections:
                credit = 'SuperPaymasterRR5GuardCreditTest' in section.splitlines()[0]
                expected = (634000 if credit else 570000) if command['engine'] == 'amsterdam' else 432000
                assert f'scan first settled call gas: {expected}' in section
                if command['engine'] == 'amsterdam':
                    assert 'scan first non-guard failure call gas: 440000' in section
                    assert f'scan last non-guard failure call gas: {expected-2000}' in section
                else:
                    assert 'scan non-guard failures (2k steps): 0' in section
    numbers = json.loads((out / 'numbers.json').read_text())
    assert set(numbers) == {'cancun','prague','amsterdam'}
    for engine, data in numbers.items():
        for mode in ['balance','credit']:
            assert data[f'{mode}-entrypoint'] == 440000
            assert data[f'{mode}-direct'] == (438828 if engine == 'amsterdam' else 431514)
            # Require explicit independently deployed adjacent endpoint samples.
            for path in ['entrypoint','direct']:
                boundary = data[f'{mode}-{path}']
                for gas, completed in [(boundary,1),(boundary-1,0)]:
                    matches = [c for c in commands if c['engine']==engine and c['name'].endswith(f'-{mode}-{path}-{gas}')]
                    assert matches
                    for c in matches:
                        log = (out / f"{engine}-{c['name']}.log").read_text()
                        assert f'sample budget: {gas}' in log and f'sample completed: {completed}' in log
    for mode in ['balance','credit']:
        trajectory = json.loads((out / f'{mode}-steps.json').read_text())
        expected_peak, expected_net = (390897, 211234) if mode == 'balance' else (372998, 291266)
        assert (trajectory['peak'], trajectory['net']) == (expected_peak, expected_net), 'frozen peak/net changed'
        assert trajectory['chunks'] and trajectory['initial'] == 440000
        assert trajectory['peak'] > trajectory['net'] > 0
        assert trajectory['peak'] < 440000
        assert trajectory['peak'] == 440000 - min(s[5] for chunk in trajectory['chunks'] for s in chunk['steps'])
        for key in ['initial', 'minimum_remaining', 'peak', 'net', 'terminal']:
            assert numbers['amsterdam'][f'{mode}-trajectory'][key] == trajectory[key]
    return len(commands)

if __name__ == '__main__':
    out = pathlib.Path(sys.argv[1])
    try:
        count = verify(out)
    except Exception as exc:
        print(f'VERDICT FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
    print(f'VERDICT PASS: {count} commands; all exits zero; exact counts, adjacent thresholds, snapshot bands, and trajectories verified')
