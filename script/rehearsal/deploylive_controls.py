"""Deploy-day controls; network and filesystem boundaries are injectable for tests."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import time
from urllib.parse import urlsplit
import stat
from deploylive_deploy_day import ROOT, require, integer, redact_error
from deploylive_runtime import clean_source_commit

TEMPLATE = ROOT / 'script/rehearsal/inputs.template.env'
EXPECTATIONS = ROOT / 'deployments/hardfork-expectations.json'


def input_keys():
    return set(re.findall(r'^([A-Z][A-Z0-9_]*)=', TEMPLATE.read_text(), re.M))


URL_KEYS = ('DEPLOYLIVE_RPC', 'DEPLOYLIVE_SOURCE_RPC', 'DEPLOYLIVE_SECOND_RPC', 'REHEARSAL_SOURCE_RPC')
URL_SCHEME = re.compile(r'^\s*(https?|wss?)://', re.I)


def read_endpoint_file(key, raw, no_credential=False):
    # Endpoint URLs carry credentials: they never appear in inputs, output, config or evidence.
    path = Path(os.path.expanduser(raw))
    try:
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) & ~0o600 == 0, 'endpoint file must be regular, owned by current user, mode <= 0600')
        raw_text = path.read_text()
        require(len(raw_text.splitlines()) == 1, 'endpoint file must hold one URL')
        text = raw_text.strip()
    except OSError:
        raise RuntimeError('unreadable endpoint file for ' + key) from None
    require(text and '\n' not in text and URL_SCHEME.match(text) is not None, 'endpoint file for ' + key + ' must hold one URL')
    # Start-up self-check: the scanner must be able to recognise this URL's credential. An endpoint
    # the operator explicitly declares credential-free (<KEY>_NO_CREDENTIAL=1) is allowed without
    # one; its host and full URL are still matched verbatim. A declaration contradicted by a
    # credential-like segment stops.
    from deploylive_rehearse import credential_fragments
    if no_credential:
        extra = credential_fragments(text) - {text, urlsplit(text).hostname or ''}
        require(not extra, 'endpoint ' + key + ' is declared credential-free but has a credential-like segment')
        return text
    try:
        credential_fragments(text, strict=True)
    except RuntimeError:
        raise RuntimeError('endpoint file for ' + key + ' has no credential-like segment; scanner cannot guard it; '
                           'if it truly has none, declare ' + key + '_NO_CREDENTIAL=1') from None
    return text


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
        hint = key if key.endswith('_FILE') else key + '_FILE'
        require(URL_SCHEME.match(values[key]) is None, 'inputs must not contain endpoint URLs; put the URL in a file and set ' + hint + ' to its path')
    require(set(values) == input_keys(), 'input keys differ: missing=' + ','.join(sorted(input_keys()-set(values)))
            + ' extra=' + ','.join(sorted(set(values)-input_keys())))
    optional = {'AGENT_IDENTITY_REGISTRY', 'AGENT_REPUTATION_REGISTRY', 'AGENT_VALIDATION_REGISTRY',
                'PRIVATE_KEY_ANNI', 'DEPLOY_TIME', 'REHEARSAL_BLS_SCALARS', 'REHEARSAL_SOURCE_RPC_FILE',
                'DEPLOYER_ACCOUNT', 'GUARDIANS'} | {k + '_NO_CREDENTIAL' for k in URL_KEYS}
    for key in sorted(input_keys() - optional):
        require(bool(values[key]), 'empty required input ' + key)
    inherited = os.environ if inherited is None else inherited
    commit = commit_reader()
    require('SP_COMMIT' not in inherited or inherited['SP_COMMIT'] == commit, 'SP_COMMIT mismatch with clean HEAD')
    # Only execution context survives; deployment values always come from the approved file.
    env = {k: inherited[k] for k in ('PATH', 'HOME', 'TMPDIR', 'LANG') if k in inherited}
    env.update({k:v for k,v in values.items() if v != '' and not (k.endswith('_FILE') and k[:-5] in URL_KEYS)})
    for key in URL_KEYS:
        flag = values.get(key + '_NO_CREDENTIAL', '')
        require(flag in ('', '1'), key + '_NO_CREDENTIAL must be empty or 1')
        if values.get(key + '_FILE'):
            env[key] = read_endpoint_file(key, values[key + '_FILE'], no_credential=flag == '1')
        else:
            require(flag == '', key + '_NO_CREDENTIAL set without ' + key + '_FILE')
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


def archive(source, destination, copy=None, env=None):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    # Same scanner as safe_logs and the final scan: one implementation, three call sites.
    from deploylive_rehearse import scan_evidence
    for key in URL_KEYS:
        if env and URL_SCHEME.match(env.get(key) or ''):
            scan_evidence(source, env[key], [], key)
    require(source.is_dir() and not destination.exists(), 'archive source missing or destination exists')
    require(not destination.is_relative_to(source) and not source.is_relative_to(destination), 'archive overlaps evidence')
    archive_records(source)
    files=sorted(p for p in source.rglob('*') if p.is_file())
    require(not any(p.is_symlink() for p in source.rglob('*')), 'evidence symlinks refused')
    require(all('\n' not in str(p.relative_to(source)) and '\\' not in str(p.relative_to(source)) for p in files), 'unsafe archive filename')
    require(not (source/'SHA256SUMS').exists(), 'reserved SHA256SUMS in evidence')
    snapshots = {p.relative_to(source): p.read_bytes() for p in files}
    sums=''.join(hashlib.sha256(data).hexdigest()+'  '+name.as_posix()+'\n' for name, data in snapshots.items())
    if copy is not None:
        copy(source,destination)
    else:
        destination.mkdir()
        for name, data in snapshots.items():
            target = destination/name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    for name, data in snapshots.items():
        require((destination/name).read_bytes() == data, 'archive verification failed')
    (destination/'SHA256SUMS').write_text(sums)
    print('ARCHIVE PASS')


MANIFEST = 'inputs.manifest'


def manifest_bytes(env, request):
    excluded = {'DEPLOYER_ACCOUNT', 'PRIVATE_KEY_ANNI', 'REHEARSAL_BLS_SCALARS'}
    keys = input_keys() - excluded - {k + '_FILE' for k in URL_KEYS}
    values = {k: env.get(k, '') for k in keys}
    values.update(SP_COMMIT=env['SP_COMMIT'], POP_REQUEST_SHA256=hashlib.sha256(request.read_bytes()).hexdigest())
    require(all('\n' not in v and '\r' not in v for v in values.values()), 'multiline manifest input')
    return ''.join(k+'='+values[k]+'\n' for k in sorted(values)).encode()


def write_manifest(env, evidence):
    data = manifest_bytes(env, evidence/'pop-request.json')
    (evidence/MANIFEST).write_bytes(data)
    (evidence/(MANIFEST+'.sha256')).write_text(hashlib.sha256(data).hexdigest()+'\n')
    (evidence/'checker.PASS.json').unlink(missing_ok=True)


def manifest_digest(evidence):
    digest = hashlib.sha256((evidence/MANIFEST).read_bytes()).hexdigest()
    require((evidence/(MANIFEST+'.sha256')).read_text() == digest+'\n', 'input manifest digest mismatch')
    return digest


def verify_manifest(env, evidence, request=None):
    digest = manifest_digest(evidence)
    require(manifest_bytes(env, request or evidence/'pop-request.json') == (evidence/MANIFEST).read_bytes(), 'input manifest mismatch; repeat predict and PoP')
    return digest


def write_conversion(evidence, export, request, guardians):
    # Hashes are drift checks against operator mistakes and stale files.
    # The trust root is the operator's machine. Keep the exact approved bytes.
    digest = manifest_digest(evidence)
    (evidence/'dvt-export.json').write_bytes(export)
    (evidence/'guardians.hex').write_bytes(guardians)
    write_json(evidence, 'conversion.json', dict(manifest=digest,
        exportSha256=hashlib.sha256(export).hexdigest(),
        requestSha256=hashlib.sha256(request).hexdigest(),
        guardiansSha256=hashlib.sha256(guardians).hexdigest()))


def verify_conversion(env, evidence):
    digest = verify_manifest(env, evidence)
    try:
        record = json.loads((evidence/'conversion.json').read_text())
        require(record.get('manifest') == digest, 'conversion manifest mismatch')
        contents = {}
        for key, name in (('export', 'dvt-export.json'), ('request', 'pop-request.json'), ('guardians', 'guardians.hex')):
            contents[key] = (evidence/name).read_bytes()
            require(record.get(key+'Sha256') == hashlib.sha256(contents[key]).hexdigest(),
                    'conversion digest mismatch: '+name)
        return contents['guardians'].decode().strip()
    except (OSError, ValueError, TypeError, AttributeError):
        raise RuntimeError('conversion record missing or malformed') from None


def plan_digest(plan):
    return hashlib.sha256(json.dumps(plan, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


FORGE_RPC_ALIAS = 'deploylive'
FORGE_RPC_ENV = 'DEPLOYLIVE_FORGE_RPC_URL'


def forge_endpoint(command, env):
    """forge script's --rpc-url has no env binding, so the URL reaches forge only through the
    foundry.toml [rpc_endpoints] alias `deploylive` = "${DEPLOYLIVE_FORGE_RPC_URL}". Every other
    endpoint variable is removed from forge's environment."""
    require('--rpc-url' not in command and '--fork-url' not in command, 'forge command already names an endpoint')
    forge_env = {k: v for k, v in env.items() if k not in URL_KEYS and k not in ('ETH_RPC_URL', FORGE_RPC_ENV)}
    forge_env[FORGE_RPC_ENV] = env['DEPLOYLIVE_RPC']
    return [*command, '--rpc-url', FORGE_RPC_ALIAS], forge_env


def safe_logs(evidence, prefix, result, env, after_broadcast=False):
    from deploylive_rehearse import scan_content
    logs = []
    redacted = False
    for content in (result.stdout, result.stderr):
        try:
            require(redact_error(content) == content and not re.search(r'(?i)(?:https?|wss?)://', content), 'raw output contains credentials; refusing write')
            for key in URL_KEYS:
                scan_content(content.encode(), env.get(key, ''), json.loads(env.get('REHEARSAL_BLS_SCALARS', '[]')), key, prefix)
            if env.get('PRIVATE_KEY_ANNI'):
                require(env['PRIVATE_KEY_ANNI'].lower() not in content.lower(), 'raw output contains secret; refusing write')
        except (RuntimeError, ValueError, TypeError):
            if not after_broadcast:
                raise
            # Once transactions may have been sent, preserve evidence and continue the diff.
            # Redact the entire affected stream, including endpoint fragments and scalar encodings.
            content = 'REDACTED: sensitive output after broadcast\n'
            redacted = True
        logs.append(content)
    if redacted:
        (evidence/'REDACTED_AFTER_BROADCAST').write_text(prefix+'\n')
    for suffix, content in zip(('stdout', 'stderr'), logs):
        (evidence/(prefix+'.'+suffix+'.log')).write_text(content)


def plan_diff(gated, actual, gas_bounds=None):
    left, right = gated['transactions'], actual['transactions']
    diff = []
    if len(left) != len(right): diff.append('transaction count mismatch')
    for label, transactions in (('gated', left), ('compared', right)):
        if transactions:
            start = integer(transactions[0]['transaction']['nonce'])
            for i, tx in enumerate(transactions):
                if integer(tx['transaction']['nonce']) != start + i:
                    diff.append(f'{label} index={i} nonce progression mismatch')
    for i, (a, b) in enumerate(zip(left, right)):
        if a.get('transactionType') != b.get('transactionType'):
            diff.append(f'index={i} field=transactionType')
        if a['transaction'].get('type') != b['transaction'].get('type'):
            diff.append(f'index={i} field=type')
        a, b = a['transaction'], b['transaction']
        for key in ('to', 'input', 'value', 'from', 'chainId', 'nonce'):
            if key not in a or key not in b or a[key] != b[key]: diff.append(f'index={i} field={key}')
        if gas_bounds is not None:
            low, high = gas_bounds[i]
            if not low <= integer(b['gas']) <= high: diff.append(f'index={i} gas outside [{low},{high}]')
    return diff


def gas_changes(gated, actual, gas_bounds):
    """Informational: limits that differ from the gated plan but sit inside the accepted range."""
    out = []
    for i, (a, b) in enumerate(zip(gated['transactions'], actual['transactions'])):
        ga, gb = integer(a['transaction']['gas']), integer(b['transaction']['gas'])
        if ga != gb: out.append(dict(index=i, gated=ga, broadcast=gb, range=gas_bounds[i]))
    return out


def check_start_nonce(plan, expected, rpc, deployer):
    require(integer(rpc('eth_getTransactionCount', deployer, 'pending')) == integer(expected)
            and integer(plan['transactions'][0]['transaction']['nonce']) == integer(expected), 'predict-time starting nonce mismatch')


def deployment_rule(env, evidence, transport, chain):
    require(env['DEPLOYLIVE_SOURCE_RPC'] != env['DEPLOYLIVE_SECOND_RPC'], 'distinct endpoints required')
    record = hardfork_check(transport(env['DEPLOYLIVE_SOURCE_RPC']), transport(env['DEPLOYLIVE_SECOND_RPC']), evidence)
    require(chain == 31337 or record['chainId'] == chain, 'hardfork deployment chain mismatch')
    return record


def write_success(evidence, env, config, broadcast, gated_plan):
    digest = plan_digest(gated_plan)
    require(digest == plan_digest(json.loads((evidence/'gated-plan.json').read_text())),
            'gated plan changed before checker PASS')
    write_json(evidence, 'checker.PASS.json', dict(status='PASS', manifest=manifest_digest(evidence),
        gatedPlanSha256=digest,
        noCredentialEndpoints=sorted(k for k in URL_KEYS if env.get(k + '_NO_CREDENTIAL') == '1'),
        env=env['ENV'], config=str(config), broadcast=str(broadcast),
        configSha256=hashlib.sha256(config.read_bytes()).hexdigest(),
        broadcastSha256=hashlib.sha256(broadcast.read_bytes()).hexdigest()))


def archive_records(source):
    record = json.loads((source/'checker.PASS.json').read_text()) if (source/'checker.PASS.json').is_file() else {}
    require(record.get('status') == 'PASS' and record.get('manifest') == manifest_digest(source), 'archive requires current manifest-bound checker PASS')
    require(record.get('gatedPlanSha256') == plan_digest(json.loads((source/'gated-plan.json').read_text())),
            'archived gated plan differs from checker PASS')
    for key, name in (('config', 'config.'+record['env']+'.json'), ('broadcast', 'run-latest.json')):
        path = Path(record[key])
        require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(ROOT), 'missing deployment record')
        data = path.read_bytes()
        require(hashlib.sha256(data).hexdigest() == record[key+'Sha256'], 'deployment record changed since PASS')
        require(Path(name).name == name, 'unsafe archive record name')
        destination = source/name
        try:
            require(not stat.S_ISLNK(destination.lstat().st_mode), 'evidence destination symlink refused')
        except FileNotFoundError:
            pass
        destination.write_bytes(data)
