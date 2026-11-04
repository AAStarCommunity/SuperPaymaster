#!/usr/bin/env python3
"""Gate-removal probes for manifest_send.py (and the shared password rule in a3a_send.py): each named control must be green with the gate and red without it.

`need` gates are suppressed by name at runtime (a3a_exec.need skips exactly that gate name, so a computed name such
as send_nonce_latest is suppressed wherever it is built). Direct raises and the enable checks are neutralised in a
mutated copy of the module source. No production file is changed; nothing leaves this machine (local anvil only).
"""
import sys
sys.dont_write_bytecode = True
import types, unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import test_manifest_send as t  # noqa: E402
sys.path.insert(0, str(HERE.parent/'a3a'))
import test_a3a_send as ta  # noqa: E402

SRC = {'ms': (HERE/'manifest_send.py').read_text(), 'sd': (HERE.parent/'a3a'/'a3a_send.py').read_text()}
TEST_MODULES = {'': t, 'a3a.': ta}
NEED = {
    # a3a_send.py's password check carries the shared worktree rule (outside_worktrees).
    'a3a.SenderTests': {
        'test_password_in_this_repository': 'send_password_outside_repo',
        'test_password_in_another_git_worktree': 'send_password_git_worktree',
        'test_password_under_git_marker': 'send_password_git_dir',
    },
    'SendTests': {
        'test_live_estimate_over_limit': 'send_live_gas_over_limit',
        'test_secondary_estimate_over_limit': 'send_live_gas_over_limit',
        'test_live_estimate_requires_repin': 'send_live_gas_repin',
        'test_repin_boundary_on_secondary': 'send_live_gas_repin',
        'test_secondary_chain_id': 'send_chain_id',
        'test_primary_nonce_latest': 'send_nonce_latest',
        'test_secondary_nonce_latest': 'send_nonce_latest',
        'test_secondary_nonce_pending': 'send_nonce_pending',
        'test_nonce_moved_after_signing': 'send_final_nonce_latest',
        'test_final_nonce_pending': 'send_final_nonce_pending',
        'test_secondary_fee_cap': 'send_fee_cap',
        'test_secondary_balance': 'send_balance',
        'test_packet_hash': 'packet_approved_sha256',
        'test_packet_chain': 'send_packet_chain',
        'test_sender_binding': 'send_sender_binding',
        'test_operator_confirmation': 'send_operator_confirmation',
        'test_missing_account': 'send_account_named',
        'test_first_step_unknown': 'send_first_step',
        'test_last_step_unknown': 'send_last_step',
        'test_step_order': 'send_step_order',
        'test_endpoint_roles': 'send_endpoints',
        'test_prior_missing_step': 'prior_prefix',
        'test_prior_other_packet': 'prior_packet',
        'test_prior_records_not_objects': 'prior_records',
        'test_prior_record_keys': 'prior_record_keys',
        'test_prior_variant': 'prior_variant',
        'test_prior_receipt_hash_on_secondary': 'prior_receipt_hash',
        'test_prior_wrong_block': 'prior_receipt_block',
        'test_prior_hash_of_another_step': 'prior_mined_nonce',
        'test_prior_block_not_canonical_on_secondary': 'prior_block_canonical',
        'test_prior_timestamp_on_secondary': 'prior_timestamp_agree',
        'test_prior_receipts_disagree': 'prior_receipt_agree',
        'test_prior_exec_without_safe_success': 'safe_success_event',
        'test_nonempty_output_directory_is_never_reused': 'output_empty',
        'test_signed_nonce': 'send_signed_nonce',
        'test_signed_gas': 'send_signed_gas',
        'test_signed_max_fee': 'send_signed_maxFeePerGas',
        'test_signed_priority_fee': 'send_signed_maxPriorityFeePerGas',
        'test_signed_value': 'send_signed_value',
        'test_signed_chain': 'send_signed_chainId',
        'test_signed_to': 'send_signed_to',
        'test_signed_input': 'send_signed_input',
        'test_signed_by_another_key': 'send_signed_signer',
        'test_sign_failure': 'send_sign_exit',
        'test_password_file_mode': 'send_password_mode',
        'test_reverted_step': 'send_receipt_status',
        'test_receipt_gas': 'send_receipt_gas',
        'test_receipt_hash': 'send_receipt_hash',
        'test_secondary_receipt_differs': 'send_secondary_receipt_agree',
        'test_secondary_mined_fields': 'send_mined_input',
        'test_block_not_canonical_on_secondary': 'send_block_canonical',
        'test_secondary_block_timestamp': 'send_timestamp_agree',
        'test_secondary_post_nonce': 'send_post_nonce',
        'test_post_safe_nonce': 'send_post_safe_nonce',
        'test_secondary_readback': 'readback_owner()',
        'test_returned_hash_mismatch': None,  # direct raise, below
        'test_live_run_requires_authorized_at': 'send_authorized_at',
        'test_authorized_at_in_the_future': 'send_authorized_at_future',
        'test_authorized_at_before_the_packet_pin': 'send_authorized_at_before_pin',
        'test_authorization_record_must_read_back': 'send_authorization_record',
        'test_wrong_phrase_writes_no_authorization': 'send_operator_confirmation',
    },
    'B4Tests': {
        'test_endpoints_disagree_on_variant': 'send_b4_variant_agree',
        'test_apply_not_ready': 'send_b4_ready',
        'test_placeholder_status_zero_is_never_allowed': 'send_receipt_status',
        'test_apply_status_zero_without_post_state_stops': 'readback_fraudProofVerifier()',
    },
    'FinalTests': {
        'test_final_owner_differs_on_secondary': 'readback_owner()',
        'test_final_accounting': 'post_swap_revenue',
    },
    'TimingTests': {
        'test_timelock_ready': 'send_timelock_ready',
        'test_timelock_unscheduled_or_done': 'send_timelock_scheduled',
        'test_activation_schedule_floor': 'send_activation_schedule_floor',
    },
    'PasswordFileTests': {
        'test_mode_too_open': 'send_password_mode',
        'test_inside_repository': 'send_password_outside_repo',
        'test_symlink': 'send_password_symlink',
        'test_inside_another_git_worktree': 'send_password_git_worktree',
        'test_under_git_marker': 'send_password_git_dir',

        'test_directory_open_to_others': 'send_password_dir_mode',
    },
    'PacketTests': {
        'test_approved_sha256': 'packet_approved_sha256',
        'test_stage_missing': 'packet_stage',
    },
    'CliTests': {
        'test_endpoints_must_differ': 'send_independent_endpoints',
    },
}
# (class, control, gate, source fragment, replacement[, module]): the fragment must occur in that module's source
# ('ms' = manifest_send.py, the default; 'sd' = a3a_send.py).
SOURCE = [
    ('a3a.SenderTests', 'test_password_git_unavailable', 'send_password_git_unavailable',
     "raise ex.Gate('send_password_git_unavailable', 'git not runnable', 'git rev-parse failing outside a worktree') from None",
     "r = None", 'sd'),
    ('SendTests', 'test_prior_unknown_hash', 'prior_receipt_missing',
     "raise a.Gate('prior_receipt_missing'", "(lambda *x: None)('prior_receipt_missing'"),
    ('SendTests', 'test_prior_receipt_on_secondary', 'prior_receipt_missing',
     "raise a.Gate('prior_receipt_missing'", "(lambda *x: None)('prior_receipt_missing'"),
    ('SendTests', 'test_secondary_never_sees_receipt', 'send_secondary_receipt_timeout',
     "raise a.Gate(gate+'_timeout'", "(lambda *x: None)(gate+'_timeout'"),
    ('SendTests', 'test_broadcast_error_is_monitored_not_retried', 'send_receipt_timeout',
     "raise a.Gate(gate+'_timeout'", "(lambda *x: None)(gate+'_timeout'"),
    ('SendTests', 'test_returned_hash_mismatch', 'send_returned_hash',
     "raise a.Gate('send_returned_hash'", "(lambda *x: None)('send_returned_hash'"),
    ('SendTests', 'test_dry_run_shares_the_live_gate_sequence', 'dry_run_stop (no broadcast)',
     "if args.dry_run:  # the only difference", "if False:  # the only difference"),
    ('SendTests', 'test_dry_run_with_real_keystore_leaks_no_secret', 'dry_run_stop (no broadcast)',
     "if args.dry_run:  # the only difference", "if False:  # the only difference"),
    ('PasswordFileTests', 'test_git_unavailable', 'send_password_git_unavailable',
     "raise ex.Gate('send_password_git_unavailable', 'git not runnable', 'git rev-parse failing outside a worktree') from None",
     "r = None", 'sd'),
    ('SendTests', 'test_authorization_recorded_before_the_first_signature', 'authorization.json before signing',
     "    if not args.dry_run:  # the author's go is on disk", "    if False:  # the author's go is on disk"),
    ('SendTests', 'test_interrupt_during_bookkeeping_is_after_broadcast', 'interrupt after broadcast -> send_after_broadcast',
     "except (Exception, KeyboardInterrupt) as e:", "except Exception as e:"),
    ('SendTests', 'test_failure_after_broadcast_is_recorded_with_the_hash', 'interrupt after broadcast -> send_after_broadcast',
     "except (Exception, KeyboardInterrupt) as e:", "except Exception as e:"),
    ('CliTests', 'test_disabled_by_default', 'disabled_by_default (rc=3)',
     "if os.environ.get(ENABLE_ENV) in (None, ''):", "if False:"),
    ('CliTests', 'test_enable_names_another_packet', 'enable_names_packet (rc=3)',
     "if os.environ[ENABLE_ENV] != args.approved_sha256:", "if False:"),
]


def run_case(cls, name):
    result = unittest.TestResult()
    # A suppressed gate can let a transaction through that anvil rejects: bound the receipt wait for probes.
    with patch.object(t.ms, 'RECEIPT_WAIT_SECONDS', 2):
        case = cls(name)
        try:
            case.run(result)
        except KeyboardInterrupt:  # unittest re-raises it: an injected interrupt escaping the sender is a red control
            case.doCleanups()  # TestCase.run skipped them: never let this case's patches leak into the next one
            return 'RED', 'KeyboardInterrupt escaped the sender (no send_after_broadcast)'
    problems = result.failures+result.errors
    if not problems:
        return 'GREEN', ''
    text = problems[0][1].strip().splitlines()
    line = next((x for x in reversed(text) if x.startswith(('AssertionError', 'a3a_exec.Gate', 'Error'))), text[-1])
    return 'RED', line[:110].replace('|', '/')


def mutated(fragment, replacement, which='ms'):
    src = SRC[which].replace(fragment, replacement)
    assert src != SRC[which], fragment
    name, path = (('manifest_send', HERE/'manifest_send.py') if which == 'ms' else
                  ('a3a_send', HERE.parent/'a3a'/'a3a_send.py'))
    mod = types.ModuleType(name)
    mod.__file__ = str(path)
    exec(compile(src, mod.__file__, 'exec'), mod.__dict__)
    return mod


def swapped(source):
    """Patches that put the mutated module wherever the tests and the sender look it up."""
    which = source[2] if len(source) > 2 else 'ms'
    mod = mutated(*source)
    if which == 'ms':
        return [patch.object(t, 'ms', mod)]
    return [patch.object(t.ms, 'sd', mod), patch.object(t, 'sd', mod), patch.object(ta, 'sd', mod)]


def main():
    rows, failed = [], []
    names = list(NEED) + [x[0] for x in SOURCE if x[0] not in NEED]
    classes = {}
    for name in names:
        prefix = 'a3a.' if name.startswith('a3a.') else ''
        classes[name] = getattr(TEST_MODULES[prefix], name[len(prefix):])
    for cname, cls in classes.items():
        cases = ([(c, g, None) for c, g in NEED.get(cname, {}).items() if g] +
                 [(x[1], x[2], tuple(x[3:])) for x in SOURCE if x[0] == cname])
        cls.setUpClass()
        try:
            for control, gate, source in cases:
                base, why = run_case(cls, control)
                if source is None:
                    original = t.a.need
                    def without(name, *args, _gate=gate, **kw):
                        if name != _gate:
                            return original(name, *args, **kw)
                    with patch.object(t.a, 'need', without):
                        probe, detail = run_case(cls, control)
                    how = 'need suppressed'
                else:
                    patches = swapped(source)
                    for p in patches:
                        p.start()
                    try:
                        probe, detail = run_case(cls, control)
                    finally:
                        for p in reversed(patches):
                            p.stop()
                    how = 'source: raise -> no-op'
                ok = base == 'GREEN' and probe == 'RED'
                rows.append((cname+'.'+control, gate, how, base, probe, detail or why))
                if not ok:
                    failed.append(control)
        finally:
            cls.tearDownClass()
    print('| Control | Gate removed | Removal | With gate | Without gate | First failure without the gate |')
    print('|---|---|---|---|---|---|')
    for r in rows:
        print('| %s | `%s` | %s | %s | %s | %s |' % r)
    print('SEND_GATE_PROBES %s %d/%d' % ('PASS' if not failed else 'FAIL', len(rows)-len(failed), len(rows)))
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
