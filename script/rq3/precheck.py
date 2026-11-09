"""Dependency-injected precheck design; deliberately no transport or send path."""
from copy import deepcopy


def before_sp_attempt(rpcs, plans_by_sender, sender, sp_attempt_precheck, refusal_types, flags=0):
    """Run the existing helper exactly once per endpoint, including after refusal.

    Only `refusal_types` (the executor's Gate) count as a refusal; any other exception is a
    sampler/transport defect and propagates, so the window stops instead of logging a refusal.
    The second endpoint is pinned to the block the first one read as `latest`, so the two
    records compare the same state rather than two different heads.

    Require separately frozen per-sender plans: silently replacing S in a plan
    would reuse single-account funding/Amax assertions for a different account.
    Capture the helper's first block read even when its subsequent checks raise.
    """
    if len(rpcs) != 2:
        raise ValueError('exactly two injected RPC callables required')
    plan = plans_by_sender[sender]
    if plan['phaseC']['addresses']['S'].lower() != sender.lower():
        raise ValueError('plan S is not the rotating sender')
    records, pinned = [], None
    for rpc in rpcs:
        record = dict(block=None, blockHash=None, flags=flags, accepted=False)

        def archive(method, params):
            # Read-only allowlist prevents accidental executor mutations.
            if method not in ('eth_getBlockByNumber', 'eth_call', 'eth_getCode', 'eth_getStorageAt'):
                raise ValueError('precheck attempted a non-read RPC method')
            if pinned is not None and method == 'eth_getBlockByNumber' and params and params[0] == 'latest':
                params = [pinned, *params[1:]]
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
            record.update(accepted=False, failure_type=type(error).__name__)
            # Do not serialize exception text: transport errors may contain URLs.
        records.append(record)
        if pinned is None:
            if record['block'] is None:
                raise ValueError('first endpoint returned no anchor block')
            pinned = record['block'] if isinstance(record['block'], str) else hex(record['block'])
    agree = records[0] == records[1]
    return dict(sender=sender, endpoints=records, precheck_refused=not (agree and all(r['accepted'] for r in records)),
                invalid_reason='' if agree else 'rpc_mismatch')


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
