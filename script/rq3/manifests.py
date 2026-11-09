"""Canonical offline freezes; no RPC transport."""
from copy import deepcopy
from schedule import digest

import json
from pathlib import Path

CHAIN_PARAMS = json.loads(Path(__file__).with_name('chain-params.json').read_text())


class WindowStop(ValueError):
    def __init__(self, reason):
        self.stop_reason = reason
        super().__init__('window_stop: ' + reason)


def qualification(chain):
    payload = dict(schema='rq3-qualification-v1', chain=chain, **CHAIN_PARAMS[chain])
    return dict(payload=payload, sha256=digest(payload))


def validate_qualification(manifest):
    if manifest != qualification(manifest['payload']['chain']):
        raise WindowStop('qualification_manifest_mismatch')
    return manifest['payload']


def build_window(window_id, schedule, plans, qualification_manifest, baseline):
    validate_qualification(qualification_manifest)
    accounts = schedule['payload']['accounts']
    if schedule['sha256'] != digest(schedule['payload']):
        raise WindowStop('schedule_hash_mismatch')
    if schedule['payload']['qualification'] != qualification_manifest:
        raise WindowStop('qualification_manifest_mismatch')
    if len(plans) != 3 or set(plans) != set(accounts):
        raise WindowStop('three_sender_plans_required')
    for sender, plan in plans.items():
        if plan['phaseC']['addresses']['S'].lower() != sender.lower():
            raise WindowStop('plan_sender_mismatch')
    if not baseline.get('tpm_runtime_codehash') or not baseline.get('frozen_build_sha256'):
        raise WindowStop('tpm_baseline_binding_missing')
    payload = dict(schema='rq3-window-v1', window_id=window_id,
                   schedule_sha256=schedule['sha256'], qualification=qualification_manifest,
                   plan_sha256={s: digest(p) for s, p in plans.items()}, baseline=deepcopy(baseline))
    return dict(payload=payload, sha256=digest(payload))


def validate_window(manifest, schedule, plans, qualification_manifest, baseline):
    if manifest != build_window(manifest['payload']['window_id'], schedule, plans,
                                qualification_manifest, baseline):
        raise WindowStop('window_manifest_mismatch')


def check_plan(manifest, sender, plan):
    if plan['phaseC']['addresses']['S'].lower() != sender.lower():
        raise WindowStop('plan_sender_mismatch')
    if manifest is None or manifest['sha256'] != digest(manifest['payload']):
        raise WindowStop('window_manifest_mismatch')
    if len(manifest['payload']['plan_sha256']) != 3:
        raise WindowStop('three_sender_plans_required')
    if digest(plan) != manifest['payload']['plan_sha256'].get(sender):
        raise WindowStop('plan_hash_mismatch')


def receipt_status(qualification_manifest, broadcast_at, observed_at, receipt=None,
                   head_number=None, reread_hash=None, finalized_timeout=False, timeout_declared_at=None):
    p = validate_qualification(qualification_manifest)
    if finalized_timeout and (timeout_declared_at is None or
                              timeout_declared_at - broadcast_at < p['receipt_timeout_seconds']):
        raise ValueError('final timeout declared before frozen deadline')
    timeout = finalized_timeout or observed_at - broadcast_at >= p['receipt_timeout_seconds']
    if timeout:
        return dict(success=False, failure_reason='receipt_timeout',
                    supplemental_only=receipt is not None)
    if receipt is None:
        return dict(pending=True)
    if head_number is None or head_number - receipt['blockNumber'] < p['confirmation_depth']:
        return dict(pending=True)
    if reread_hash is None:
        raise ValueError('confirmation block hash reread required')
    if reread_hash != receipt['blockHash']:
        return dict(success=False, invalid_reason='chain_reorg')
    return dict(ready=True)
