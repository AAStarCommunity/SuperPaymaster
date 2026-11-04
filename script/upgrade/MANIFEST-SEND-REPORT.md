# Manifest live sender (`manifest_send.py`): gates, tests, probes

Disabled by default and not authorised to run. A run needs DSR's review of this module and the author's separate go for
one packet sha256, given as `MANIFEST_SEND_ENABLE=<sha256>`. The go is the author's own phrase, which `--confirm` carries
verbatim; `--confirm` bypasses `/dev/tty`, so nothing here is TTY-enforced. A live run records the phrase, its
`--authorized-at` time and the packet sha256 in `authorization.json` before the first signature. `manifest_exec.py sign|send` still return 3. No key, RPC
endpoint or public chain was used: every test runs offline against a local anvil (`--chain-id 11155111`) with the
public anvil keys.

## DSR #599 precondition (H2_GAS_GATE_REPORT.md, "DSR review of #599")

Before each signature, on each endpoint, `sp_upgrade_exec.fresh_gas(probe, step)` runs in live mode (`latest`, no
overrides):
- `send_live_gas_over_limit`: the estimate exceeds the frozen `tx.gas`. fresh_gas's own `fresh_estimate` stop is
  reported under this name.
- `send_live_gas_repin`: the estimate exceeds `floor(limit/1.1)`, computed as `limit*10//11`. STOP; the packet must be
  re-pinned.
- Each comparison is written to `gas-comparisons.json` before the decision is acted on. It records step, endpoint,
  latest block number before and after the estimate, estimate, limit, threshold, and result (`pass`, `repin`,
  `over_limit`, `other_gate` or `unavailable`).

## Review items (jhfnetboy, at 121a5652 and b7bdaa83)

- **B1 dry run.** `--dry-run` takes the live code path and stops right before the first broadcast. A test checks that
  its `need()` gate sequence equals the live run's up to the broadcast, minus the two authorization gates that only a
  live run has.
- **B2 leak test.** A dry run with a real `cast wallet` keystore and password file shows no key, password or keystore
  field (ciphertext, mac, salt, iv, or the whole JSON) in fd-level stdout/stderr, any `--out` file or any exception
  text. The same holds for the wrong-password failure.
- **B3 password file.** `a3a_send.outside_worktrees` is shared by both senders and applies three checks:
  - not under this repository (`send_password_outside_repo`);
  - `git rev-parse --show-toplevel` in the file's directory, with `GIT_*` removed, must fail
    (`send_password_git_worktree`; git not runnable is `send_password_git_unavailable`);
  - no ancestor holds `.git` (`send_password_git_dir`).

  The mode rule is unchanged per sender: the manifest sender accepts 0600 or stricter, and a3a_send keeps exactly
  0600. Negative tests cover each rule, in both test suites.
- **B4 authorization.** `--confirm` carries the author's go; it is not TTY-enforced. Live runs require
  `--authorized-at`, an ISO-8601 time with an offset (`send_authorized_at`), and the exact phrase
  (`send_operator_confirmation`). They write and read back `authorization.json` (`send_authorization_record`) before
  the first signature. Tests cover: missing or invalid time; wrong phrase, which writes no record; the record existing
  before the first `cast mktx` with matching contents; a tampered write; and a dry run needing none of these.

## Evidence (this commit, repository root, `A3A_ENGINE_DIR="$(dirname "$(command -v cast)")"`, both engines)

Logs: `script/upgrade/manifest-send-evidence/<engine>/*.log`; `engine.txt` shows `cast --version`.

```text
# foundry-1.7.1: cast Version: 1.7.1, Commit SHA: 4072e48705af9d93e3c0f6e29e93b5e9a40caed8
test_manifest_exec.py: Ran 235 tests in 224.303s -> OK
test_a3a_exec.py: Ran 102 tests in 2.756s -> OK
test_sp_upgrade_exec.py: Ran 141 tests in 0.944s -> OK
test_pop_adapter.py: Ran 53 tests in 0.205s -> OK
test_release_evidence.py: Ran 69 tests in 3.025s -> OK
test_a3a_send.py: Ran 77 tests in 8.514s -> OK
test_manifest_send.py: Ran 108 tests in 52.581s -> OK
probe_send_gates.py: SEND_GATE_PROBES PASS 88/88

# nightly-4e8874b: cast Version: 1.8.7-nightly, Commit SHA: 4e8874b2bdc840929585ca73e170993c50a4a531
test_manifest_exec.py: Ran 235 tests in 245.140s -> OK
test_a3a_exec.py: Ran 102 tests in 2.809s -> OK
test_sp_upgrade_exec.py: Ran 141 tests in 1.178s -> OK
test_pop_adapter.py: Ran 53 tests in 0.220s -> OK
test_release_evidence.py: Ran 69 tests in 2.863s -> OK
test_a3a_send.py: Ran 77 tests in 9.316s -> OK
test_manifest_send.py: Ran 108 tests in 50.008s -> OK
probe_send_gates.py: SEND_GATE_PROBES PASS 88/88
```

## Gate-removal probes (`probe_send_gates.py`)

Each control is green with its gate. It turns red when the gate is removed: a `need` gate is suppressed by exact name,
and a direct raise, an enable check, the dry-run stop or the authorization write is replaced by a no-op in a mutated
copy of the module source. The table is identical under both engines (Foundry 1.7.1 shown).

| Control | Gate removed | Removal | With gate | Without gate | First failure without the gate |
|---|---|---|---|---|---|
| a3a.SenderTests.test_password_in_this_repository | `send_password_outside_repo` | need suppressed | GREEN | RED | AssertionError: 'send_password_git_worktree' != 'send_password_outside_repo' |
| a3a.SenderTests.test_password_in_another_git_worktree | `send_password_git_worktree` | need suppressed | GREEN | RED | AssertionError: 'send_password_git_dir' != 'send_password_git_worktree' |
| a3a.SenderTests.test_password_under_git_marker | `send_password_git_dir` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| a3a.SenderTests.test_password_git_unavailable | `send_password_git_unavailable` | source: raise -> no-op | GREEN | RED | AttributeError: 'NoneType' object has no attribute 'returncode' |
| SendTests.test_live_estimate_over_limit | `send_live_gas_over_limit` | need suppressed | GREEN | RED | AssertionError: 'send_live_gas_repin' != 'send_live_gas_over_limit' |
| SendTests.test_secondary_estimate_over_limit | `send_live_gas_over_limit` | need suppressed | GREEN | RED | AssertionError: 'send_live_gas_repin' != 'send_live_gas_over_limit' |
| SendTests.test_live_estimate_requires_repin | `send_live_gas_repin` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_repin_boundary_on_secondary | `send_live_gas_repin` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_secondary_chain_id | `send_chain_id` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_primary_nonce_latest | `send_nonce_latest` | need suppressed | GREEN | RED | AssertionError: 'send_nonce_pending' != 'send_nonce_latest' |
| SendTests.test_secondary_nonce_latest | `send_nonce_latest` | need suppressed | GREEN | RED | AssertionError: 'send_final_nonce_latest' != 'send_nonce_latest' |
| SendTests.test_secondary_nonce_pending | `send_nonce_pending` | need suppressed | GREEN | RED | AssertionError: 'send_final_nonce_pending' != 'send_nonce_pending' |
| SendTests.test_nonce_moved_after_signing | `send_final_nonce_latest` | need suppressed | GREEN | RED | AssertionError: 'send_final_nonce_pending' != 'send_final_nonce_latest' |
| SendTests.test_final_nonce_pending | `send_final_nonce_pending` | need suppressed | GREEN | RED | AssertionError: 'send_nonce_pending' != 'send_final_nonce_pending' |
| SendTests.test_secondary_fee_cap | `send_fee_cap` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_secondary_balance | `send_balance` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_packet_hash | `packet_approved_sha256` | need suppressed | GREEN | RED | AssertionError: 'prior_packet' != 'packet_approved_sha256' |
| SendTests.test_packet_chain | `send_packet_chain` | need suppressed | GREEN | RED | AssertionError: 'remote_fresh_estimate_unavailable' != 'send_packet_chain' |
| SendTests.test_sender_binding | `send_sender_binding` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_operator_confirmation | `send_operator_confirmation` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_missing_account | `send_account_named` | need suppressed | GREEN | RED | KeyError: 'deployer' |
| SendTests.test_first_step_unknown | `send_first_step` | need suppressed | GREEN | RED | ValueError: 'Z9' is not in list |
| SendTests.test_last_step_unknown | `send_last_step` | need suppressed | GREEN | RED | ValueError: 'Z9' is not in list |
| SendTests.test_step_order | `send_step_order` | need suppressed | GREEN | RED | AssertionError: 'prior_prefix' != 'send_step_order' |
| SendTests.test_endpoint_roles | `send_endpoints` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_prior_missing_step | `prior_prefix` | need suppressed | GREEN | RED | AssertionError: 'prior_mined_nonce' != 'prior_prefix' |
| SendTests.test_prior_other_packet | `prior_packet` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_prior_records_not_objects | `prior_records` | need suppressed | GREEN | RED | AttributeError: 'str' object has no attribute 'get' |
| SendTests.test_prior_record_keys | `prior_record_keys` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_prior_variant | `prior_variant` | need suppressed | GREEN | RED | KeyError: 'variants' |
| SendTests.test_prior_receipt_hash_on_secondary | `prior_receipt_hash` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'prior_receipt_hash' |
| SendTests.test_prior_wrong_block | `prior_receipt_block` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_prior_hash_of_another_step | `prior_mined_nonce` | need suppressed | GREEN | RED | AssertionError: 'prior_mined_input' != 'prior_mined_nonce' |
| SendTests.test_prior_block_not_canonical_on_secondary | `prior_block_canonical` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'prior_block_canonical' |
| SendTests.test_prior_timestamp_on_secondary | `prior_timestamp_agree` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'prior_timestamp_agree' |
| SendTests.test_signed_nonce | `send_signed_nonce` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_signed_nonce' |
| SendTests.test_signed_gas | `send_signed_gas` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_signed_gas' |
| SendTests.test_signed_max_fee | `send_signed_maxFeePerGas` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_signed_maxFeePerGas' |
| SendTests.test_signed_priority_fee | `send_signed_maxPriorityFeePerGas` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_signed_maxPriorityFeePerGas' |
| SendTests.test_signed_value | `send_signed_value` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_signed_value' |
| SendTests.test_signed_chain | `send_signed_chainId` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_signed_chainId' |
| SendTests.test_signed_to | `send_signed_to` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_signed_to' |
| SendTests.test_signed_input | `send_signed_input` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_signed_input' |
| SendTests.test_signed_by_another_key | `send_signed_signer` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_signed_signer' |
| SendTests.test_sign_failure | `send_sign_exit` | need suppressed | GREEN | RED | AssertionError: 'send_sign_output' != 'send_sign_exit' |
| SendTests.test_password_file_mode | `send_password_mode` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_reverted_step | `send_receipt_status` | need suppressed | GREEN | RED | AssertionError: 'readback_owner()' != 'send_receipt_status' |
| SendTests.test_receipt_gas | `send_receipt_gas` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_receipt_hash | `send_receipt_hash` | need suppressed | GREEN | RED | AssertionError: 'send_secondary_receipt_agree' != 'send_receipt_hash' |
| SendTests.test_secondary_receipt_differs | `send_secondary_receipt_agree` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_secondary_mined_fields | `send_mined_input` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_block_not_canonical_on_secondary | `send_block_canonical` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_secondary_block_timestamp | `send_timestamp_agree` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_secondary_post_nonce | `send_post_nonce` | need suppressed | GREEN | RED | AssertionError: 'send_nonce_latest' != 'send_after_broadcast' |
| SendTests.test_post_safe_nonce | `send_post_safe_nonce` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_secondary_readback | `readback_owner()` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_live_run_requires_authorized_at | `send_authorized_at` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_authorization_record_must_read_back | `send_authorization_record` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_wrong_phrase_writes_no_authorization | `send_operator_confirmation` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_prior_unknown_hash | `prior_receipt_missing` | source: raise -> no-op | GREEN | RED | AssertionError: 'send_provider_receipt' != 'prior_receipt_missing' |
| SendTests.test_prior_receipt_on_secondary | `prior_receipt_missing` | source: raise -> no-op | GREEN | RED | AssertionError: 'send_provider_receipt' != 'prior_receipt_missing' |
| SendTests.test_secondary_never_sees_receipt | `send_secondary_receipt_timeout` | source: raise -> no-op | GREEN | RED | AssertionError: 'local_error' != 'send_secondary_receipt_timeout' |
| SendTests.test_broadcast_error_is_monitored_not_retried | `send_receipt_timeout` | source: raise -> no-op | GREEN | RED | AssertionError: 'local_error' != 'send_receipt_timeout' |
| SendTests.test_returned_hash_mismatch | `send_returned_hash` | source: raise -> no-op | GREEN | RED | AssertionError: Gate not raised |
| SendTests.test_dry_run_shares_the_live_gate_sequence | `dry_run_stop (no broadcast)` | source: raise -> no-op | GREEN | RED | AssertionError: Lists differ: ['sen[90864 chars]ding', '<broadcast>', 'send_receipt_hash', 'se[1835 chars]ity' |
| SendTests.test_dry_run_with_real_keystore_leaks_no_secret | `dry_run_stop (no broadcast)` | source: raise -> no-op | GREEN | RED | AssertionError: 'SENT' != 'DRY_RUN' |
| SendTests.test_authorization_recorded_before_the_first_signature | `authorization.json before signing` | source: raise -> no-op | GREEN | RED | AssertionError: False is not true : authorization.json must precede the first signature |
| B4Tests.test_endpoints_disagree_on_variant | `send_b4_variant_agree` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_b4_variant_agree' |
| B4Tests.test_apply_not_ready | `send_b4_ready` | need suppressed | GREEN | RED | AssertionError: 'send_after_broadcast' != 'send_b4_ready' |
| B4Tests.test_placeholder_status_zero_is_never_allowed | `send_receipt_status` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| B4Tests.test_apply_status_zero_without_post_state_stops | `readback_fraudProofVerifier()` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| FinalTests.test_final_owner_differs_on_secondary | `readback_owner()` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| FinalTests.test_final_accounting | `post_swap_revenue` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| TimingTests.test_timelock_ready | `send_timelock_ready` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| TimingTests.test_timelock_unscheduled_or_done | `send_timelock_scheduled` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| TimingTests.test_activation_schedule_floor | `send_activation_schedule_floor` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| PasswordFileTests.test_mode_too_open | `send_password_mode` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| PasswordFileTests.test_inside_repository | `send_password_outside_repo` | need suppressed | GREEN | RED | AssertionError: 'send_password_git_worktree' != 'send_password_outside_repo' |
| PasswordFileTests.test_symlink | `send_password_symlink` | need suppressed | GREEN | RED | AssertionError: 'send_password_regular' != 'send_password_symlink' |
| PasswordFileTests.test_inside_another_git_worktree | `send_password_git_worktree` | need suppressed | GREEN | RED | AssertionError: 'send_password_git_dir' != 'send_password_git_worktree' |
| PasswordFileTests.test_under_git_marker | `send_password_git_dir` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| PasswordFileTests.test_directory_open_to_others | `send_password_dir_mode` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| PasswordFileTests.test_git_unavailable | `send_password_git_unavailable` | source: raise -> no-op | GREEN | RED | AttributeError: 'NoneType' object has no attribute 'returncode' |
| PacketTests.test_approved_sha256 | `packet_approved_sha256` | need suppressed | GREEN | RED | AssertionError: Gate not raised |
| PacketTests.test_stage_missing | `packet_stage` | need suppressed | GREEN | RED | AssertionError: 'manifest_keys' != 'packet_stage' |
| CliTests.test_endpoints_must_differ | `send_independent_endpoints` | need suppressed | GREEN | RED | AssertionError: 'local_error' != 'send_independent_endpoints' |
| CliTests.test_disabled_by_default | `disabled_by_default (rc=3)` | source: raise -> no-op | GREEN | RED | KeyError: 'MANIFEST_SEND_ENABLE' |
| CliTests.test_enable_names_another_packet | `enable_names_packet (rc=3)` | source: raise -> no-op | GREEN | RED | AssertionError: 1 != 3 |
