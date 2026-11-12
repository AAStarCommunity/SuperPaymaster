"""Execute the pinned Sepolia fork rehearsal; RPC credentials only enter child env.

Trust local checkout, pinned nightly and tool. This never broadcasts transactions.
"""
import argparse
import json
from pathlib import Path
import re
import sys
from executed_run import snapshot, version, engine_command, command, sha
from test_exec_inventory import inventory
from url_free import assert_dir_url_free

TEST = 'contracts/test/rams/RamsARouteRehearsal.t.sol'


def chain_assertion(root):
    lines = (root/TEST).read_text().splitlines()
    hits = [i + 1 for i, l in enumerate(lines) if 'assertEq(block.chainid, 11155111' in l]
    if len(hits) != 1:
        raise ValueError('Sepolia chainId assertion not found exactly once')
    return f'{TEST}:{hits[0]}'


def run(nightly, rpc_file, provider, block, operators, out_dir, root=None):
    root = Path(root or Path(__file__).resolve().parents[2]).resolve()
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', provider) or block <= 0:
        raise ValueError('provider must be a name; block must be positive')
    rpc = Path(rpc_file).read_text().strip()
    ops = Path(operators).read_text().strip()
    if not rpc or not re.fullmatch(r'0x[0-9a-fA-F]{40}(,0x[0-9a-fA-F]{40})*', ops):
        raise ValueError('RPC or operator input invalid')
    before = snapshot(root)
    out = Path(out_dir).resolve()
    out.mkdir(parents=True, exist_ok=False)
    ver, commit = version(nightly, root, out)
    argv, env = engine_command('amsterdam', nightly, out)
    argv += ['--match-path', TEST]
    listed = command(argv + ['--list', '--json'], env, root, out/'declared.json', scrub=True)
    if listed['rc']:
        raise ValueError('forge list failed')
    env.update(SEPOLIA_FORK_RPC=rpc, FORK_BLOCK=str(block), OPERATORS=ops)
    executed = command(argv, env, root, out/'test.log', scrub=True)
    if snapshot(root) != before:
        raise ValueError('HEAD or sources changed during execution')
    # Fork mode deliberately counts Rams; the generic full-run inventory excludes it.
    declarations = json.loads((out/'declared.json').read_text())
    alias = 'fork-rehearsal.t.sol'
    declared = {alias: declarations[TEST]}
    log = (out/'test.log').read_text().replace(TEST, alias)
    counts, rc = inventory(declared, [log], 'amsterdam')
    report = dict(provenance='executed', snapshot=before, engine='amsterdam', engine_commit=commit,
                  provider=provider, block=block, chainId=11155111, chainId_assertion=chain_assertion(root),
                  operators_sha256=sha(operators), commands=[ver, listed, executed], counts=counts)
    (out/'rams.json').write_text(json.dumps(report, indent=2)+'\n')
    assert_dir_url_free(out)
    return rc or int(bool(executed['rc']))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('nightly', 'rpc-file', 'provider', 'operators', 'out-dir'):
        p.add_argument('--'+name, required=True)
    p.add_argument('--block', required=True, type=int)
    a = p.parse_args()
    try:
        return run(a.nightly, a.rpc_file, a.provider, a.block, a.operators, a.out_dir)
    except (ValueError, OSError, KeyError) as exc:
        # Child output and credential-bearing exception text must never reach stdout.
        print('Rams execution failed ('+type(exc).__name__+'); inspect scrubbed artifacts', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
