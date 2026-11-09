"""Dependency-injected precheck design; deliberately no transport or send path."""
from copy import deepcopy
from manifests import check_plan, WindowStop


# Exactly the gates sp_attempt_precheck can raise: manifest_exec.py:2710,2717,2722-2725 and its
# price_gate (manifest_exec.py:2608-2611). Anything else (rpc_result, canonical_quantity, ...) is a defect.
POLICY_GATES = frozenset({
    'SP_RENEW_never', 'precheck_renewal_mode', 'precheck_allowance_cap',
    'precheck_total_cap', 'precheck_allowance', 'precheck_total',
    'C_price_decimals', 'C_price_bound',
})


def as_int(block):
    if isinstance(block, int) and not isinstance(block, bool):
        return block
    if isinstance(block, str) and block.startswith('0x'):
        return int(block, 16)
    return None


def before_sp_attempt(rpcs, plans_by_sender, sender, sp_attempt_precheck, refusal_types, flags=0, *, manifest=None):
    """Run the existing helper exactly once per endpoint, including after refusal.

    Only allowlisted Gate records count as policy refusals; other errors propagate.
    Pin the second endpoint by number when possible, then recheck each head hash.
    This does not prove that every eth_call observed that hash.

    Require separately frozen per-sender plans: silently replacing S in a plan
    would reuse single-account funding/Amax assertions for a different account.
    Capture the helper's first block read even when its subsequent checks raise.
    """
    if len(rpcs) != 2:
        raise ValueError('exactly two injected RPC callables required')
    if sender not in plans_by_sender:
        raise WindowStop('plan_sender_missing')
    plan = plans_by_sender[sender]
    check_plan(manifest, sender, plan)
    records, pinned, reorg = [], None, False
    pins = []
    for rpc in rpcs:
        pins.append(pinned)
        record = dict(block=None, blockHash=None, flags=flags, accepted=False)

        def archive(method, params):
            # Read-only allowlist prevents accidental executor mutations.
            if method not in ('eth_getBlockByNumber', 'eth_call', 'eth_getCode', 'eth_getStorageAt'):
                raise ValueError('precheck attempted a non-read RPC method')
            if pinned is not None and method == 'eth_getBlockByNumber' and params and params[0] == 'latest':
                params = [pinned, *params[1:]]
            if method != 'eth_getBlockByNumber':
                # State reads are bound to the anchor HASH (EIP-1898), not to its number, so a
                # reorg between the head read and a call fails instead of reading another block.
                if record['blockHash'] is None or not params or as_int(params[-1]) != as_int(record['block']):
                    raise ValueError('state read not bound to the anchor block')
                params = [*params[:-1], {'blockHash': record['blockHash'], 'requireCanonical': True}]
            result = rpc(method, params)
            if method == 'eth_getBlockByNumber' and result and record['block'] is None:
                record.update(block=result['number'], blockHash=result['hash'])
            return result

        try:
            evidence = sp_attempt_precheck(archive, deepcopy(plan), flags)
            record.update(evidence=evidence, accepted=True)
            if record['block'] is None or evidence['block'] != record['block'] or evidence['blockHash'] != record['blockHash']:
                raise ValueError('precheck anchor missing or inconsistent')
        except refusal_types as error:
            if error.record['gate'] not in POLICY_GATES:
                raise
            record.update(accepted=False, refusal={k: deepcopy(error.record[k])
                          for k in ('gate', 'observed', 'expected')})
        if record['block'] is not None:
            number = record['block'] if isinstance(record['block'], str) else hex(record['block'])
            head = rpc('eth_getBlockByNumber', [number, False])
            record['postReadBlockHash'] = head['hash'] if head else None
            if not head or head['number'] != record['block'] or head['hash'] != record['blockHash']:
                reorg = True
                record['accepted'] = False
        records.append(record)
        if len(records) == 1 and record['block'] is not None:
            pinned = record['block'] if isinstance(record['block'], str) else hex(record['block'])
    agree = records[0] == records[1]
    return dict(sender=sender, endpoints=records, endpoint_pins=pins,
                precheck_refused=reorg or not (agree and all(r['accepted'] for r in records)),
                invalid_reason='chain_reorg' if reorg else ('' if agree else 'rpc_mismatch'))


def broadcast_disabled(*args, **kwargs):
    raise NotImplementedError('RQ3 offline draft: broadcasting is disabled')


def stop_reason(attempts):
    """Chronological formal attempts; infrastructure classification is explicit."""
    failures = streak = 0
    for index, attempt in enumerate(attempts, 1):
        if attempt.get('stop_reason'):
            return attempt['stop_reason']
        infra = attempt['infrastructure_failure']
        if type(infra) is not bool:
            raise ValueError('infrastructure_failure must be boolean')
        failures += infra
        streak = streak + 1 if infra else 0
        if streak >= 3:
            return 'three_consecutive_infrastructure_failures'
        if index >= 20 and failures * 100 > index * 5:
            return 'infrastructure_failures_above_5_percent'
    return None


def timing_check(slot, starts, finishes, last_sp_inclusion):
    """Validate observed elapsed time, not just the planned schedule offsets."""
    if set(starts) != set(slot['order']) or set(finishes) != set(starts):
        raise ValueError('timing evidence required for each arm')
    ordered = slot['order']
    if any(starts[a] > finishes[a] for a in ordered):
        raise ValueError('negative attempt duration')
    if any(finishes[a] > starts[b] for a, b in zip(ordered, ordered[1:])):
        raise ValueError('attempts overlap or violate frozen arm order')
    if min(starts.values()) < slot['start_seconds'] or max(finishes.values()) > slot['deadline_seconds']:
        raise ValueError('attempt exceeds frozen block elapsed bound')
    previous = last_sp_inclusion.get(slot['senders']['SP'])
    if previous is not None and starts['SP'] - previous < 60:
        raise ValueError('SP sender still rate limited')


def account_available(sender, earlier_attempts):
    """Timeout classification is final; inclusion/drop evidence only unlocks sender."""
    return not any(a['sender'] == sender and a.get('failure_reason') == 'receipt_timeout'
                   and a.get('resolution') not in ('included_late', 'provably_dropped')
                   for a in earlier_attempts)
