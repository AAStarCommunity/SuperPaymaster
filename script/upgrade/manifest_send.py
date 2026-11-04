#!/usr/bin/env python3
"""Gated live sender for the frozen pre-sampling manifest packet (MANIFEST-DESIGN.md §3, §4, §6).

DISABLED BY DEFAULT and NOT AUTHORISED TO RUN until DSR has reviewed this file and the author has given a separate
go for the specific packet sha256. `manifest_exec.py sign|send` keep refusing with rc=3; this module is the only
manifest broadcast path, kept apart so that manifest_exec.py itself still cannot broadcast. Without the environment
variable MANIFEST_SEND_ENABLE set to the approved packet sha256 it exits rc=3 before reading any file.

Usage (one contiguous range of packet steps per run; earlier runs' sent.json files prove the prefix):
  MANIFEST_SEND_ENABLE=<sha256> python3 -B script/upgrade/manifest_send.py \
    --packet <plan.json> --approved-sha256 <sha256> --first A1 [--last A5] [--prior <earlier sent.json> ...] \
    --rpc-file <file: primary URL> --rpc-file-secondary <file: independent URL> \
    --accounts <json: {"deployer": "<keystore name>", ...}> --password-file <0600 file> --out <new empty dir> [--dry-run]

Order of operations, each a hard stop with a named gate; nothing is retried, re-signed or repriced:
  0. Per-user lock shared with a3a_send.py (same signers); the packet is read once, its sha256 must equal
     --approved-sha256, and the plan is parsed from those hashed bytes (a copy is kept as evidence). It must be the final
     full-stage artifact and pass manifest_exec.validate_plan(frozen=True) (deterministic rebuild from its pin).
  1. Prefix: every step before --first is proven on BOTH endpoints by an earlier sent.json record (receipt, block
     hash, mined fields equal to the packet); the executor context (passed set, upgrade block, 6c timestamp) is
     derived from those receipts, never from the record alone.
  2. Before EACH signature, on BOTH endpoints: chain id; sender nonce latest == pending == planned; the executor's
     pre_send state re-reads (manifest_exec.pre_send_reads); timelock/ETA readiness; the B4 variant (both endpoints
     must select the same one); fee cap and sender balance; then sp_upgrade_exec.fresh_gas in live mode (latest, no
     overrides). STOP if the live estimate exceeds the frozen limit; STOP (re-pin) if it exceeds floor(limit/1.1).
     Every comparison (endpoint, block numbers before/after, estimate, limit, threshold, result) goes to
     gas-comparisons.json before the decision is acted on.
  3. `cast mktx --account <name> --password-file <path>` offline (whitelisted environment, no RPC variable);
     `cast decode-transaction` and a local keccak over stdin; every decoded field equals the packet.
  4. Nonces re-read on both endpoints. --dry-run stops here, before the first step's broadcast: the same code path,
     signature included, with nothing sent (result.json status DRY_RUN). Otherwise broadcast.json ("attempting") is
     written and eth_sendRawTransaction goes once to the primary endpoint only; from here every failure is
     send_after_broadcast with the local hash.
  5. Receipt on the primary, then the same receipt (block hash) on the secondary; status 0x1, except the B4 apply
     variant, which may mine 0x0 when its post-state holds; gasUsed <= gas; mined fields equal the packet on both.
  6. Post-state on both endpoints: the step's packet read-backs (batch read-backs for 5b/6d), Safe execution
     events, sender nonce + 1, the 6c ETA rule and the A16 inventory; after the packet's last step also the final
     state (frozen registry, post-swap accounting, every handed-over owner). Then the next step starts again at 2.
Signed bytes stay in memory until step 4 (signed.raw is written only after the broadcast attempt). RPC URLs and
provider text are never written or printed; records are scrubbed against both URLs (a3a_send helpers).
"""
import sys
sys.dont_write_bytecode = True
import argparse, copy, hashlib, json, os, stat, subprocess, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent/'a3a'))
import manifest_exec as m  # noqa: E402
import a3a_send as sd  # noqa: E402

u, a = m.u, m.a
ENABLE_ENV = 'MANIFEST_SEND_ENABLE'
REPIN_NUM, REPIN_DEN = 10, 11  # floor(limit / 1.1) == limit * 10 // 11 in integers
RECEIPT_WAIT_SECONDS = 600
SECONDARY_WAIT_SECONDS = 120
POLL_SECONDS = 4
DECODED_FIELDS = sd.DECODED_FIELDS
ENDPOINTS = ('primary', 'secondary')
ROOT = HERE.parents[1]


def password_file_check(path):
    """Metadata only (cast alone reads the password): a regular file of the current user, outside the repository,
    mode 0600 or stricter (owner read required, nothing for group/other, no execute), in a directory that only the
    current user can enter or write, so the file cannot be swapped between this check and cast's open."""
    try:
        info = path.lstat()
        parent = path.parent.lstat()
    except OSError:
        raise a.Gate('send_password_file', 'unavailable', 'regular file owned by current user, mode 0600 or stricter') from None
    a.need('send_password_symlink', stat.S_ISLNK(info.st_mode), False)
    a.need('send_password_regular', stat.S_ISREG(info.st_mode), True)
    a.need('send_password_owner', info.st_uid, os.getuid())
    mode = stat.S_IMODE(info.st_mode)
    a.need('send_password_mode', mode & ~0o600 == 0 and mode & 0o400 != 0, True)
    resolved = path.resolve()
    a.need('send_password_outside_repo', resolved != ROOT and ROOT not in resolved.parents, True)
    a.need('send_password_dir_symlink', stat.S_ISLNK(parent.st_mode), False)
    a.need('send_password_dir_owner', parent.st_uid, os.getuid())
    a.need('send_password_dir_mode', stat.S_IMODE(parent.st_mode) & 0o077, 0)


def signed(tx, account, password_file):
    """`cast mktx --account <name> --password-file <path>` offline (a3a_send's whitelisted environment, stdin and
    stderr left to the terminal), then a3a_send's local decode, field-by-field comparison and keccak.
    The signed bytes are returned to the caller only; they are never written or sent here."""
    password_file_check(password_file)
    cmd = [sd.CAST, 'mktx', '--account', account, '--password-file', str(password_file), '--chain', str(a.CHAIN),
           '--nonce', str(a.qty(tx['nonce'])), '--gas-limit', str(a.qty(tx['gas'])),
           '--gas-price', str(a.qty(tx['maxFeePerGas'])), '--priority-gas-price', str(a.qty(tx['maxPriorityFeePerGas'])),
           '--value', str(a.qty(tx['value']))]
    cmd += ['--create', tx['data']] if tx.get('to') is None else [tx['to'], tx['data']]
    r = subprocess.run(cmd, env=sd.signer_env(), stdout=subprocess.PIPE, text=True)
    a.need('send_sign_exit', r.returncode, 0)
    raw = r.stdout.strip()
    a.need('send_sign_output', raw.startswith('0x02') and all(c in '0123456789abcdef' for c in raw[2:].lower()), True)
    decoded = sd.decode(raw)
    h = sd.check_signed(decoded, tx)
    a.need('send_signed_hash', sd.local_keccak(raw), h)
    return raw, h, decoded


def repin_threshold(limit):
    return limit*REPIN_NUM//REPIN_DEN


class GasProbe:
    """Transparent endpoint wrapper that keeps the last eth_estimateGas result, so a comparison that fresh_gas
    rejects is still recorded with its estimate."""
    def __init__(self, rpc):
        self.rpc, self.estimate = rpc, None

    def __call__(self, method, params, *rest):
        result = self.rpc(method, params, *rest)
        if method == 'eth_estimateGas':
            self.estimate = result
        return result


def latest_number(rpc):
    return a.qty(a.block_data(rpc, 'latest')['number'])


def live_gas(rpc, label, step, comparisons, write):
    """sp_upgrade_exec.fresh_gas in live mode plus the DSR #599 rules; the record is written before any decision."""
    tx = step['tx']
    limit = a.qty(tx['gas'])
    entry = dict(step=step['id'], endpoint=label, to=tx['to'], limit=limit, repinThreshold=repin_threshold(limit),
                 estimate=None, blockNumber=None, blockNumberAfter=None, result='unavailable')
    comparisons.append(entry)
    probe = GasProbe(rpc)
    failure = None
    try:
        entry['blockNumber'] = latest_number(rpc)
        try:
            u.fresh_gas(probe, step)
        except a.Gate as e:
            failure = e
        if probe.estimate is not None:
            try:
                entry['estimate'] = a.qty(probe.estimate)
            except a.Gate:  # malformed: fresh_gas has already refused it under its own gate
                pass
        entry['blockNumberAfter'] = latest_number(rpc)
    finally:
        if entry['estimate'] is not None:
            entry['result'] = ('over_limit' if entry['estimate'] > limit else
                               'repin' if entry['estimate'] > entry['repinThreshold'] else
                               'pass' if failure is None else 'other_gate')
        write()
    est = entry['estimate']
    if est is None:  # fresh_gas raises whenever it has no usable estimate
        raise failure
    a.need('send_live_gas_over_limit', est <= limit, True)
    a.need('send_live_gas_repin', est <= entry['repinThreshold'], True)
    if failure is not None:  # e.g. block_gas_limit: still a STOP under fresh_gas's own name
        raise failure
    return entry


def nonce_gate(rpc, tx, prefix='send_nonce'):
    planned = a.qty(tx['nonce'])
    a.need(prefix+'_latest', a.nonce(rpc, tx['from']), planned)
    a.need(prefix+'_pending', a.nonce(rpc, tx['from'], 'pending'), planned)


def timing_gate(rpc, plan, step, variant):
    """Fail-closed readiness: the fork rehearsal warps time, a live send must wait instead (and is re-run later)."""
    sid, now = step['id'], a.qty(a.block_data(rpc, 'latest')['timestamp'])
    if sid.endswith('execute_exec'):
        ready = a.word(rpc, u.TL, 'getTimestamp(bytes32)', plan['operations'][step['operation']]['id'])
        a.need('send_timelock_scheduled', ready > 1, True)
        a.need('send_timelock_ready', now >= ready, True)
    if sid == 'activation_schedule_approve':
        floor = max(u.uints(a.call(rpc, u.SP, 'gasParams()'))[8], plan['activationScheduleNotBefore'])
        a.need('send_activation_schedule_floor', now >= floor, True)
    if sid == 'B4' and variant == 'apply':
        ready = a.word(rpc, plan['addresses']['BLSAggregator'], 'pendingFraudProofVerifierReadyAt()')
        a.need('send_b4_ready', 0 < ready <= now, True)


def money_gate(rpc, tx):
    base = a.qty(a.block_data(rpc, 'latest')['baseFeePerGas'])
    a.need('send_fee_cap', base+a.qty(tx['maxPriorityFeePerGas']) <= a.qty(tx['maxFeePerGas']), True)
    cost = a.qty(tx['gas'])*a.qty(tx['maxFeePerGas'])+a.qty(tx['value'])
    a.need('send_balance', a.qty(rpc('eth_getBalance', [tx['from'], 'latest'])) >= cost, True)


def selected_step(plan, step, variant):
    if 'variants' not in step:
        return step
    selected = dict(step, tx=copy.deepcopy(step['variants'][variant]))
    if variant == 'placeholder':
        selected.update(step['variantMeasurements']['placeholder'])
    return selected


def pre_signature(endpoints, plan, step, context, comparisons, write):
    """Everything that must hold on both endpoints before one signature; returns the selected step."""
    variants = {}
    for label, rpc in endpoints:
        variants[label] = (m.select_b4(rpc, plan, step)[0] if 'variants' in step else None)
    a.need('send_b4_variant_agree', variants['secondary'], variants['primary'])
    variant = variants['primary']
    chosen = selected_step(plan, step, variant)
    tx = chosen['tx']
    a.need('send_packet_chain', tx['chainId'], hex(a.CHAIN))
    a.need('send_sender_binding', plan['pin']['senders'][step['sender']]['address'], tx['from'])
    for label, rpc in endpoints:
        with u.gas_step(dict(id='%s@%s' % (step['id'], label))):
            a.need('send_chain_id', a.qty(rpc('eth_chainId', [])), a.CHAIN)
            nonce_gate(rpc, tx)
            m.pre_send_reads(rpc, plan, chosen, context)
            timing_gate(rpc, plan, step, variant)
            money_gate(rpc, tx)
    for label, rpc in endpoints:
        live_gas(rpc, label, chosen, comparisons, write)
    return chosen, variant


def wait_receipt(rpc, h, deadline_seconds, gate, tokens):
    deadline = time.monotonic()+deadline_seconds
    transient = 0
    while time.monotonic() < deadline:
        try:
            r = rpc('eth_getTransactionReceipt', [h])
            transient = 0
        except a.Gate as e:
            if e.record['gate'] not in sd.TRANSIENT_GATES:
                raise
            transient += 1
            if transient > sd.RECEIPT_TRANSIENT_MAX:
                raise a.Gate(gate+'_rpc', e.record['gate'], 'receipt reads recovering') from None
            time.sleep(POLL_SECONDS)
            continue
        if r is not None:
            r = sd.clean_receipt(r, tokens)
            a.need(gate+'_hash', r['transactionHash'], h)
            return r
        time.sleep(POLL_SECONDS)
    raise a.Gate(gate+'_timeout', h, 'mined within %ds; never resend or reprice without review' % deadline_seconds)


def check_status(step, variant, r, tx):
    allowed = ('0x1', '0x0') if step['id'] == 'B4' and variant == 'apply' else ('0x1',)
    a.need('send_receipt_status', r['status'] in allowed, True)
    a.need('send_receipt_gas', a.qty(r['gasUsed']) <= a.qty(tx['gas']), True)


def check_mined(rpc, h, tx, r, prefix='send_mined'):
    """Provider fields are validated before comparison; every packet field must match, in the receipt's block."""
    mined = rpc('eth_getTransactionByHash', [h])
    if not isinstance(mined, dict):
        raise a.Gate(prefix+'_tx', 'malformed', 'transaction object')
    for k in ('nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value', 'chainId', 'type'):
        sd.field(mined.get(k), a.QTY, k)
    for k in ('nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value', 'chainId'):
        a.need(prefix+'_'+k, a.qty(mined[k]), a.qty(tx[k]))
    a.need(prefix+'_type', mined['type'], '0x2')
    a.need(prefix+'_from', sd.field(mined.get('from'), a.ADDRESS_RX, 'from'), tx['from'].lower())
    to = None if mined.get('to') is None else sd.field(mined.get('to'), a.ADDRESS_RX, 'to')
    a.need(prefix+'_to', to, tx['to'] and tx['to'].lower())
    a.need(prefix+'_input', sd.field(mined.get('input'), a.HEXDATA, 'input'), tx['data'].lower())
    a.need(prefix+'_access_list', mined.get('accessList', []), [])
    a.need(prefix+'_authorizations', mined.get('authorizationList') in (None, []), True)
    a.need(prefix+'_blockHash', sd.field(mined.get('blockHash'), a.HASH32, 'blockHash'), r['blockHash'])
    a.need(prefix+'_blockNumber', sd.field(mined.get('blockNumber'), a.QTY, 'blockNumber'), r['blockNumber'])


def canonical_block(rpc, r, gate):
    b = a.block_data(rpc, r['blockNumber'])
    a.need(gate+'_canonical', b['hash'].lower(), r['blockHash'])
    return a.qty(b['timestamp'])


def post_state(rpc, plan, step, variant, chosen, r, timestamp, context):
    """The packet's read-backs for this step, read on one endpoint after the receipt."""
    sid, tx = step['id'], chosen['tx']
    a.need('send_post_nonce', a.nonce(rpc, tx['from']), a.qty(tx['nonce'])+1)
    a.need('send_post_safe_nonce', a.word(rpc, u.SAFE, 'nonce()'), step['safeNonce']+int(sid.endswith('_exec')))
    if sid == 'B4':
        return m.b4_post_state(rpc, plan, variant, r)
    observed = []
    for pred in step['readbacks']:
        if pred['kind'] in ('upgrade', 'activation'):
            observed.append(m.batch_readback(rpc, plan, pred['kind'] == 'activation', timestamp))
        else:
            observed.append(m.check_predicate(rpc, pred, timestamp))
    if sid.endswith('_exec') and 'safeHash' in step:
        u.safe_exec_events(r['logs'], step['safeHash'])
    if sid == 'activation_schedule_exec':
        m.activation_eta_gate(plan, timestamp, a.word(rpc, u.TL, 'getTimestamp(bytes32)', plan['operations']['activation']['id']))
    if sid == 'A16':
        u.check_inventory(rpc, plan['pin'])
    return observed


def final_readback(rpc, plan):
    """After the packet's last step: the end state the fork rehearsal asserts, read live (no fixture writes)."""
    m.assert_manifest_frozen(rpc, plan['pin'], True)
    accounting = m.balances(rpc, plan['pin']['pauseList'])
    a.need('post_swap_tracked', accounting['totalTrackedBalance'], m.BUFFER)
    a.need('post_swap_revenue', accounting['protocolRevenue'], m.BUFFER)
    a.need('post_swap_capped_balance', a.word(rpc, plan['pin']['capped'], 'balanceOf(address)', u.SP), m.BUFFER)
    m.check_predicate(rpc, m.address_pred(u.SP, 'owner()', u.TL))
    for name, target, owner in m.handover_contracts(plan['addresses']):
        m.check_predicate(rpc, m.address_pred(target, 'owner()', owner))
        if name in ('aggregator', 'old_aggregator'):
            m.check_predicate(rpc, m.address_pred(target, 'slashPolicyAdmin()', u.SAFE))
    for pred in m.registry_ownership(u.TL, a.ZERO):
        m.check_predicate(rpc, pred)
    return accounting


def receipt_core(r):
    """What two providers must agree on; optional per-log position fields may legitimately be absent on one."""
    return dict({k: r[k] for k in ('transactionHash', 'blockHash', 'blockNumber', 'gasUsed', 'status', 'contractAddress')},
                logs=[{k: x[k] for k in ('address', 'topics', 'data')} for x in r['logs']])


def advance(context, sid, r, timestamp):
    """The executor context after step sid, exactly as run_manifest derives it."""
    context['passed'].add(sid)
    if sid == 'A17':
        context['transferred'] = True
    if sid == 'activation_execute_exec':
        context['activated'] = True
    if sid == 'A16':
        context['frozen'] = True
    if sid == 'upgrade_execute_exec':
        context['upgradeBlock'] = r['blockNumber']
    if sid == 'activation_schedule_exec':
        context['activationScheduledAt'] = timestamp


def step_tx(step, variant):
    return step['variants'][variant] if variant else step['tx']


def prove_prefix(endpoints, plan, priors, first_index, sha, tokens):
    """Earlier runs' sent.json records must cover exactly the packet prefix; each is re-read on both endpoints."""
    records = []
    for prior in priors:
        data = a.plan_json(prior.read_bytes())
        a.need('prior_packet', data.get('packetSha256'), sha)
        a.need('prior_records', isinstance(data.get('sent'), list) and all(isinstance(x, dict) for x in data['sent']), True)
        records += data['sent']
    expected = [s['id'] for s in plan['steps'][:first_index]]
    a.need('prior_prefix', [x.get('step') for x in records], expected)
    context = {'passed': set()}
    for rec, step in zip(records, plan['steps']):
        a.exact_keys('prior_record_keys', rec, ('step', 'variant', 'hash', 'blockNumber', 'blockHash'))
        variant = rec['variant']
        a.need('prior_variant', variant in (('apply', 'placeholder') if 'variants' in step else (None,)), True)
        tx = step_tx(step, variant)
        stamps = []
        for label, rpc in endpoints:
            raw = rpc('eth_getTransactionReceipt', [rec['hash']])
            if raw is None:
                raise a.Gate('prior_receipt_missing', dict(step=step['id'], endpoint=label), 'mined receipt')
            r = sd.clean_receipt(raw, tokens)
            a.need('prior_receipt_hash', r['transactionHash'], rec['hash'])
            a.need('prior_receipt_block', (r['blockNumber'], r['blockHash']), (rec['blockNumber'], rec['blockHash']))
            with u.gas_step(dict(id=step['id'])):
                check_status(step, variant, r, tx)
                check_mined(rpc, rec['hash'], tx, r, 'prior_mined')
                stamps.append(canonical_block(rpc, r, 'prior_block'))
                if r['status'] == '0x0':  # only the B4 apply variant gets here: its post-state must still hold
                    m.b4_post_state(rpc, plan, variant, r)
        a.need('prior_timestamp_agree', stamps[1], stamps[0])
        advance(context, step['id'], r, stamps[0])
    return context


def load_packet(args):
    raw = args.packet.read_bytes()
    a.need('packet_approved_sha256', hashlib.sha256(raw).hexdigest(), args.approved_sha256)
    (args.out/'packet.approved.json').write_bytes(raw)  # evidence copy; the plan is parsed from the hashed bytes
    plan = a.plan_json(raw)
    a.require_final_artifact(plan)
    a.need('packet_stage', plan.get('stage'), 'full')
    m.validate_plan(plan, plan['externalInputs'], frozen=True)
    return plan


def step_range(plan, first, last):
    ids = [s['id'] for s in plan['steps']]
    a.need('send_first_step', first in ids, True)
    a.need('send_last_step', (last or first) in ids, True)
    i, j = ids.index(first), ids.index(last or first)
    a.need('send_step_order', i <= j, True)
    return i, j


def scrub_all(value, urls):
    for url in urls:
        value = sd.scrub(value, url)
    return value


def guard_all(obj, urls, h=None):
    return obj if all(sd.leak_free(obj, url) for url in urls) else {'redacted': 'contained an RPC URL token', 'hash': h}


def run(args, endpoints, urls, confirm=None):
    """The caller holds sd.sender_lock() and owns args.out (see main). endpoints: ((label, rpc), (label, rpc))."""
    a.need('send_endpoints', [x[0] for x in endpoints], list(ENDPOINTS))
    tokens = frozenset().union(*(sd.url_tokens(x) for x in urls))
    plan = load_packet(args)
    first, last = step_range(plan, args.first, args.last)
    accounts = json.loads(args.accounts.read_text())
    steps = plan['steps'][first:last+1]
    for step in steps:
        a.need('send_account_named', isinstance(accounts.get(step['sender']), str) and accounts[step['sender']] != '', True)
    password_file_check(args.password_file)
    context = prove_prefix(endpoints, plan, args.prior, first, args.approved_sha256, tokens)
    verb = 'DRY-RUN' if args.dry_run else 'SEND'
    phrase = '%s %s..%s %s' % (verb, steps[0]['id'], steps[-1]['id'], args.approved_sha256[:12])
    typed = args.confirm
    if typed is None:
        typed = (confirm or sd.tty_confirm)('Type "%s" to %s %d packet steps: ' % (
            phrase, 'sign without sending' if args.dry_run else 'sign and send', len(steps))).strip()
    a.need('send_operator_confirmation', typed, phrase)
    comparisons, sent = [], []
    def write_comparisons():
        a.write_json(args.out/'gas-comparisons.json', guard_all(dict(packetSha256=args.approved_sha256,
                     comparisons=comparisons), urls))
    def write_sent():
        a.write_json(args.out/'sent.json', guard_all(dict(packetSha256=args.approved_sha256, sent=sent), urls))
    write_sent()
    for step in steps:
        sid = args.current = step['id']
        chosen, variant = pre_signature(endpoints, plan, step, context, comparisons, write_comparisons)
        tx = chosen['tx']
        a.write_json(args.out/('unsigned.%s.json' % sid), tx)
        raw, h, decoded = signed(tx, accounts[step['sender']], args.password_file)  # in memory until broadcast
        a.write_json(args.out/('decoded.%s.json' % sid), {k: decoded.get(k) for k in DECODED_FIELDS})
        for label, rpc in endpoints:  # the only window between the gates and the broadcast is local signing
            nonce_gate(rpc, tx, 'send_final_nonce')
        if args.dry_run:  # the only difference from a live run: no broadcast (and so nothing after it)
            result = guard_all(dict(status='DRY_RUN', packetSha256=args.approved_sha256, step=sid, variant=variant,
                                    hash=h, broadcast=False), urls)
            sd.note(args.out/'result.json', lambda p: a.write_json(p, result))
            return result
        a.write_json(args.out/('broadcast.%s.json' % sid), dict(step=sid, hash=h, outcome='attempting'))
        outcome, provider = 'unknown', None
        try:
            try:
                returned = sd.broadcast(urls[0], raw)
                outcome = 'accepted' if returned == h else 'accepted_hash_mismatch'
            except a.Gate as e:
                provider = {'gate': e.record['gate'], 'observed': e.record['observed']}
            evidence = dict(step=sid, hash=h, outcome=outcome, endpoint='primary',
                            provider=None if provider is None else dict(gate=e_gate(provider['gate'], urls),
                                                                        observed=scrub_all(provider['observed'], urls)))
            sd.note(args.out/('broadcast.%s.json' % sid), lambda p: a.write_json(p, guard_all(evidence, urls, h)))
            sd.note(args.out/('signed.%s.raw' % sid), lambda p: p.write_text(raw+'\n'))
            r = wait_receipt(endpoints[0][1], h, RECEIPT_WAIT_SECONDS, 'send_receipt', tokens)
            sd.note(args.out/('receipt.%s.json' % sid), lambda p: a.write_json(p, guard_all(r, urls, h)))
            r2 = wait_receipt(endpoints[1][1], h, SECONDARY_WAIT_SECONDS, 'send_secondary_receipt', tokens)
            a.need('send_secondary_receipt_agree', receipt_core(r2), receipt_core(r))
            check_status(step, variant, r, tx)
            stamps, observed = [], {}
            for label, rpc in endpoints:
                with u.gas_step(dict(id='%s@%s' % (sid, label))):
                    check_mined(rpc, h, tx, r)
                    stamps.append(canonical_block(rpc, r, 'send_block'))
            a.need('send_timestamp_agree', stamps[1], stamps[0])
            for label, rpc in endpoints:
                with u.gas_step(dict(id='%s@%s' % (sid, label))):
                    observed[label] = post_state(rpc, plan, step, variant, chosen, r, stamps[0], context)
                    if sid == plan['steps'][-1]['id']:
                        observed[label] = dict(readbacks=observed[label], final=final_readback(rpc, plan))
            if outcome == 'accepted_hash_mismatch':
                raise a.Gate('send_returned_hash', 'mismatch', h)
        except (Exception, KeyboardInterrupt) as e:
            if isinstance(e, KeyboardInterrupt):
                inner = {'gate': 'interrupted', 'observed': None}
            elif isinstance(e, a.Gate):
                inner = e.record
            else:
                inner = {'gate': 'local_error', 'observed': type(e).__name__}
            raise a.Gate('send_after_broadcast', {'hash': h, 'broadcast': outcome, 'provider': provider, 'step': sid,
                                                  'cause': inner.get('gate'), 'causeObserved': inner.get('observed')},
                         'reconcile by hash on both endpoints; never resend, re-sign or reprice without a new review') from None
        advance(context, sid, r, stamps[0])
        sent.append(dict(step=sid, variant=variant, hash=h, blockNumber=r['blockNumber'], blockHash=r['blockHash']))
        sd.note(args.out/'sent.json', lambda p: write_sent())
        sd.note(args.out/('readback.%s.json' % sid), lambda p: a.write_json(p, guard_all(dict(
            step=sid, variant=variant, status=r['status'], gasUsed=a.qty(r['gasUsed']), readbacks=observed), urls, h)))
    result = guard_all(dict(status='SENT', packetSha256=args.approved_sha256, steps=[x['step'] for x in sent],
                            hashes=[x['hash'] for x in sent]), urls)
    sd.note(args.out/'result.json', lambda p: a.write_json(p, result))
    return result


def e_gate(name, urls):
    for url in urls:
        name = sd.trusted_gate(name, url)
    return name


def failure_record(record, step, urls):
    """a3a_send's scrubbed failure record, applied once per endpoint URL."""
    for url in urls:
        record = sd.failure_record(record, step, url)
    return record


def main(argv=None):
    if os.environ.get(ENABLE_ENV) in (None, ''):
        print('STOP: manifest live sending is disabled (set %s to the approved packet sha256)' % ENABLE_ENV, file=sys.stderr)
        return 3
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('--packet', type=Path, required=True)
    p.add_argument('--approved-sha256', required=True)
    p.add_argument('--first', required=True)
    p.add_argument('--last')
    p.add_argument('--prior', type=Path, action='append', default=[])
    p.add_argument('--rpc-file', type=Path, required=True)
    p.add_argument('--rpc-file-secondary', type=Path, required=True)
    p.add_argument('--accounts', type=Path, required=True)
    p.add_argument('--password-file', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--confirm')
    p.add_argument('--dry-run', action='store_true',
                   help='every gate, signing in memory included, then stop before the first broadcast')
    args = p.parse_args(argv)
    args.current = None  # the step being processed, for FAILURE.json
    if os.environ[ENABLE_ENV] != args.approved_sha256:
        print('STOP: %s does not name the approved packet' % ENABLE_ENV, file=sys.stderr)
        return 3
    os.umask(0o077)
    try:
        with sd.sender_lock():
            if args.out.exists():
                a.need('output_empty', args.out.is_dir() and not any(args.out.iterdir()), True)
            args.out.mkdir(parents=True, exist_ok=True)
            os.chmod(args.out, 0o700)
            urls = (args.rpc_file.read_text().strip(), args.rpc_file_secondary.read_text().strip())
            try:
                a.need('send_independent_endpoints', urls[0] != urls[1] and all(urls), True)
                try:
                    result = run(args, tuple(zip(ENDPOINTS, (a.RPC(x) for x in urls))), urls)
                except a.Gate:
                    raise
                except Exception as e:  # run() wraps everything after a broadcast in a Gate
                    raise a.Gate('local_error', type(e).__name__, 'no local failure before broadcast') from None
            except a.Gate as e:
                try:
                    record = failure_record(e.record, args.current, urls)
                    if not all(sd.leak_free(record, x) for x in urls):
                        record = sd.hash_only(e.record, args.current, urls[0], 'contained an RPC URL token')
                except Exception:
                    record = sd.hash_only(e.record, args.current, urls[0], 'failure record could not be built')
                try:
                    a.write_json(args.out/'FAILURE.json', record)
                except OSError:
                    sd.report('FAILURE record (not written): '+json.dumps(record), sys.stderr)
                raise
        sd.report(json.dumps(result, indent=2), sys.stdout)
        return 0
    except a.Gate as e:
        sd.report('FAILURE: '+e.record['gate'], sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
