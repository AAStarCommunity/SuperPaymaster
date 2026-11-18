"""Deploy-day controls; network and filesystem boundaries are injectable for tests."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import time
from deploylive_deploy_day import ROOT, require, integer, redact_error
from deploylive_runtime import clean_source_commit

TEMPLATE = ROOT / 'script/rehearsal/inputs.template.env'
EXPECTATIONS = ROOT / 'deployments/hardfork-expectations.json'


def input_keys():
    return set(re.findall(r'^([A-Z][A-Z0-9_]*)=', TEMPLATE.read_text(), re.M))


def load_inputs(path, inherited=None, commit_reader=clean_source_commit):
    path = Path(path).resolve()
    require(path.is_relative_to(ROOT), 'inputs must be inside worktree')
    values = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'): continue
        match = re.fullmatch(r'([A-Z][A-Z0-9_]*)=(.*)', line)
        require(match is not None, 'inputs require literal KEY=value lines')
        key, raw = match.groups()
        require(key not in values, 'duplicate input ' + key)
        parts = shlex.split(raw, comments=True)
        require(len(parts) <= 1 and not any(c in raw for c in ('`', '$', '\n')), 'nonliteral input ' + key)
        values[key] = parts[0] if parts else ''
    require(set(values) == input_keys(), 'input keys differ: missing=' + ','.join(sorted(input_keys()-set(values)))
            + ' extra=' + ','.join(sorted(set(values)-input_keys())))
    optional = {'AGENT_IDENTITY_REGISTRY', 'AGENT_REPUTATION_REGISTRY', 'AGENT_VALIDATION_REGISTRY',
                'PRIVATE_KEY_ANNI', 'DEPLOY_TIME', 'REHEARSAL_BLS_SCALARS', 'REHEARSAL_SOURCE_RPC',
                'DEPLOYER_ACCOUNT', 'GUARDIANS'}
    for key in sorted(input_keys() - optional):
        require(bool(values[key]), 'empty required input ' + key)
    inherited = os.environ if inherited is None else inherited
    commit = commit_reader()
    require('SP_COMMIT' not in inherited or inherited['SP_COMMIT'] == commit, 'SP_COMMIT mismatch with clean HEAD')
    # Only execution context survives; deployment values always come from the approved file.
    env = {k: inherited[k] for k in ('PATH', 'HOME', 'TMPDIR', 'LANG') if k in inherited}
    env.update({k:v for k,v in values.items() if v != ''})
    env['SP_COMMIT'] = commit
    evidence_dir(env)
    return env


def evidence_dir(env):
    require(bool(env.get('DEPLOYLIVE_EVIDENCE_DIR')), 'missing evidence directory')
    directory = (ROOT / env['DEPLOYLIVE_EVIDENCE_DIR']).resolve()
    require(directory != ROOT and directory.is_relative_to(ROOT), 'evidence must be inside worktree')
    for key, default in (('DEFAULT_CACHE_PATH','cache'), ('DEFAULT_ARTIFACTS_OUT','out'),
                         ('FOUNDRY_OUT','cache/deploylive-rehearsal-out'), ('FOUNDRY_CACHE_PATH','cache/deploylive-rehearsal-cache')):
        require(not directory.is_relative_to((ROOT/env.get(key,default)).resolve()), 'evidence overlaps build cleanup')
    return directory


def write_json(directory, name, record):
    directory.mkdir(parents=True, exist_ok=True)
    (directory/name).write_text(json.dumps(record, indent=2)+'\n')


def hardfork_check(a, b, evidence, confirmations=2):
    require(type(confirmations) is int and confirmations > 0, 'positive confirmations required')
    chain = integer(a('eth_chainId'))
    require(integer(b('eth_chainId')) == chain, 'hardfork chain mismatch')
    rules = json.loads(EXPECTATIONS.read_text())
    require(str(chain) in rules, 'unsupported hardfork chain')
    rule = rules[str(chain)]
    number = integer(a('eth_blockNumber')) - confirmations
    require(number >= 0, 'insufficient head confirmations')
    def config(rpc, allow_unsupported):
        try: result = rpc('eth_config')
        except RuntimeError as error:
            require(allow_unsupported and re.search(r'(?<!\d)-32601(?!\d)', str(error)), 'eth_config: '+redact_error(error))
            return 'eth_config unsupported (-32601) → header-field rule'
        if rule.get('current'):
            current = result.get('current', {})
            require(current.get('forkId') == rule['current']['forkId']
                    and integer(current.get('activationTime', -1)) == rule['current']['activationTime'], 'current fork mismatch')
        else:
            raise RuntimeError('STOP OP eth_config supported but no approved current fork values')
        return result
    ca = config(a, rule['allowUnsupportedA'])
    cb = config(b, True)
    ha, hb = (rpc('eth_getBlockByNumber', hex(number), False) for rpc in (a,b))
    require(ha and hb and integer(ha['number']) == number and integer(hb['number']) == number, 'wrong pinned block')
    for field in ('hash', 'blockAccessListHash', 'slotNumber'):
        require(ha.get(field) == hb.get(field), 'header mismatch: '+field)
        require((ha.get(field) is not None) == rule['headerFields'].get(field, True), 'header-field rule: '+field)
    if rule.get('current'):
        require(integer(ha['timestamp']) >= rule['current']['activationTime'], 'pinned block predates expected fork')
    record = dict(chainId=chain, blockNumber=number, confirmations=confirmations,
                  endpointA=dict(eth_config=ca, header=ha), endpointB=dict(eth_config=cb, header=hb))
    write_json(evidence,'hardfork-check.json',record)
    print(f'HARDFORK PASS pinned block {number}')
    return record


def cap_control(rpc, evidence, production=False, sleep=time.sleep):
    require(not production, 'cap-control refused in production')
    sender='0x00000000000000000000000000000000c0ffee02'
    command=dict(from_=sender, data='0x5b600056', gas=hex(20_000_000))
    command['from']=command.pop('from_')
    before=rpc('eth_getBlockByNumber','latest',False)
    snap=rpc('evm_snapshot')
    record=dict(command=dict(method='eth_sendTransaction',params=[command]), snapshot=snap, passed=False)
    try:
        rpc('anvil_setBalance',sender,hex(10**18))
        rpc('anvil_impersonateAccount',sender)
        record['transactionHash']=rpc('eth_sendTransaction',command)
        receipt=None
        for _ in range(100):
            receipt=rpc('eth_getTransactionReceipt',record['transactionHash'])
            if receipt: break
            sleep(.2)
        record['receipt']=receipt
        require(receipt is not None, 'control receipt timeout')
        require(integer(receipt['status']) == 0 and integer(receipt['gasUsed']) == 16_777_216, 'control cap not enforced')
        record['passed']=True
    except Exception as error:
        record['error']=redact_error(error)
        raise
    finally:
        try:
            try: rpc('anvil_stopImpersonatingAccount',sender)
            finally:
                record['reverted']=rpc('evm_revert',snap)
                require(record['reverted'] is True, 'control snapshot revert failed')
            require(rpc('eth_getBlockByNumber','latest',False)['hash'] == before['hash'], 'control head not restored')
        except Exception:
            record['passed']=False
            raise
        finally: write_json(evidence,'cap-control.json',record)
    print('CONTROL PASS')
    return record


def archive(source, destination, copy=shutil.copytree):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    require(source.is_dir() and not destination.exists(), 'archive source missing or destination exists')
    require(not destination.is_relative_to(source) and not source.is_relative_to(destination), 'archive overlaps evidence')
    files=sorted(p for p in source.rglob('*') if p.is_file())
    require(not any(p.is_symlink() for p in source.rglob('*')), 'evidence symlinks refused')
    require(all('\n' not in str(p.relative_to(source)) and '\\' not in str(p.relative_to(source)) for p in files), 'unsafe archive filename')
    require(not (source/'SHA256SUMS').exists(), 'reserved SHA256SUMS in evidence')
    sums=''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.relative_to(source).as_posix()+'\n' for p in files)
    copy(source,destination)
    for p in files:
        require((destination/p.relative_to(source)).read_bytes() == p.read_bytes(), 'archive verification failed')
    (destination/'SHA256SUMS').write_text(sums)
    print('ARCHIVE PASS')
