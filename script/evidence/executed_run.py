"""Clean-checkout execution primitives. Trust local checkout, binaries and tool."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def snapshot(root):
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], text=True)
    dirty = git('status', '--porcelain', '--untracked-files=all', '--', '.', ':(exclude).codex-work')
    if dirty.strip():
        raise ValueError('dirty tree: execution requires a clean checkout')
    paths = git('ls-files').splitlines()
    sources = {p: sha(root / p) for p in paths if (root / p).is_file()}
    sources.update({str(p.relative_to(root)): sha(p) for p in (root/'contracts/src').rglob('*.sol')})
    return dict(head=git('rev-parse', 'HEAD').strip(), sources=sources)


def engine_command(engine, forge, out):
    argv = [str(Path(forge).resolve()), 'test', '--offline']
    # TRAJECTORY_RECORD only un-gates PostOpGasProfile test_trajectory_record (the sole reader);
    # setting it on every engine makes that measurement test execute instead of skipping.
    env = {'TRAJECTORY_RECORD': 'true'}
    if engine == 'prague':
        argv += ['--evm-version', 'prague']
    elif engine == 'amsterdam':
        argv += ['--no-isolate', '--evm-version', 'cancun', '--hardfork', 'amsterdam']
        env['PROFILE_AMSTERDAM'] = 'true'
    elif engine != 'cancun':
        raise ValueError('unknown engine')
    return argv + ['--out', str(out/'build'), '--cache-path', str(out/'cache')], env


def engine_from(argv, env):
    if '--hardfork' in argv:
        if argv[argv.index('--hardfork')+1] != 'amsterdam' or env != {'TRAJECTORY_RECORD': 'true', 'PROFILE_AMSTERDAM': 'true'}:
            raise ValueError('engine argv/env mismatch')
        return 'amsterdam'
    return 'prague' if '--evm-version' in argv and argv[argv.index('--evm-version')+1] == 'prague' else 'cancun'


def child_env(extra):
    # Do not inherit test selectors, profile overrides or a fork RPC from the shell.
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FOUNDRY_', 'DAPP_', 'PROFILE_', 'SEPOLIA_', 'LIFECYCLE_'))}
    env.update(extra)
    return env


def command(argv, env, root, log, scrub=False):
    result = subprocess.run(argv, cwd=root, env=child_env(env), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    output = result.stdout
    if scrub:
        output = re.sub(r'(?i)\b[a-z][a-z0-9+.-]*://[^\s<>"\']+', '[REDACTED_URL]', output)
        if env.get('SEPOLIA_FORK_RPC'):
            output = output.replace(env['SEPOLIA_FORK_RPC'], '[REDACTED_RPC]')
    log.write_text(output)
    return dict(argv=argv, env={k: v for k, v in env.items() if k != 'SEPOLIA_FORK_RPC'},
                rc=result.returncode, log=str(log), sha256=sha(log))


def version(forge, root, out):
    record = command([str(Path(forge).resolve()), '--version'], {}, root, out/'version.log')
    match = re.search(r'Commit SHA:\s*([0-9a-fA-F]{40})\b', (out/'version.log').read_text())
    if record['rc'] or not match:
        raise ValueError('engine version requires a 40-hex commit')
    return record, match[1].lower()


def rr5_logs(directory, engine, root):
    directory = Path(directory).resolve()
    result = subprocess.run(['python3', str(root/'script/evidence/rr5-lifecycle-run.py'), '--verify', str(directory)],
                            cwd=root, text=True, capture_output=True)
    if result.returncode:
        raise ValueError('RR5 RELEASE verification failed: ' + result.stderr)
    records = [json.loads(line) for line in (directory/'commands.jsonl').read_text().splitlines()]
    return [directory/r['log'] for r in records if r['engine'] == engine], dict(path=str(directory), sha256=sha(directory/'SHA256SUMS'))
