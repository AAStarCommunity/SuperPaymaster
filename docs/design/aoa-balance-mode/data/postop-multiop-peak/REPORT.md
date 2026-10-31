# Multi-operation postOp peak

Measured 2026-10-31 on the local Amsterdam nightly `4e8874b`, with stable Foundry Cancun/Prague completion controls. No production sources or gas parameters were changed. The retained run was generated from clean commit `6e6ebaa5` (`validation.log` records the HEAD).

**Worst observed peak: 391,239 gas; headroom at 440,000: 48,761 gas.** This is operation 1 of same-user all-BALANCE N=2/3/5 and BALANCE-first alternating N=3/5. Highest net consumption is 389,186. These are measured-case results, not production bounds.

## Method and scope

The fixture derives from `PostOpProfileFixture` in `contracts/test/v2/SuperPaymasterPostOpGasProfile.t.sol`. Each command starts a fresh Forge process and deploys fresh contracts in `setUp`; there are no snapshots or artificial slot cooling. The canonical EntryPoint v0.7 runtime performs real validation, SimpleAccount execution, and uninstrumented SuperPaymaster/token settlement. All operations share one operator and token. The operator rate limit is enabled, with initially zero settlement timestamps, operator transaction counter, protocol revenue, and account debts.

The matrix is N = 2, 3, 5 × all BALANCE, all CREDIT, alternating BALANCE-first, alternating CREDIT-first × same account, distinct account per operation. Each engine runs 24 cases. Same-account operations use sequential nonces; distinct accounts use nonce zero. Every operation calls the same target/hash, as in the original profiling fixture. The fixture checks ordered settlement mode and operation hash, successful UserOperationEvent, consumed token op hashes, zero outstanding locks/reservations, target execution count, and absence of PostOpRevertReason. All accounts have credit enabled; BALANCE remains the preferred admission path.

For mixed cases, BALANCE operations use 1 gwei and CREDIT operations use 10 gwei in both gas-fee fields. Each account starts with 1,000 tokens: smaller reservations fit its available balance, larger reservations fall back to credit. This permits actual alternation even for one account, since EntryPoint validates the entire bundle before execution. These are verified settlement modes, not labels inferred from balances. All-BALANCE uses 10,000 tokens/account; all-CREDIT uses zero; both use 1 gwei. Credit caps are 50,000 tokens/account. Execution and account gas limits are 300,000 and 400,000; preVerificationGas is 50,000. The paymaster verification allowance comes from DeploymentGasFixtures.

Amsterdam commands use `--no-isolate --evm-version prague --hardfork amsterdam`; controls use stable Forge with their corresponding compiler/EVM target. Exact argv, environment selectors, engine versions and exit codes are in `run/`. Dependencies are read from `PROFILE_DEPS_ROOT=/Users/jason/Dev/aastar/SuperPaymaster`. Build/debug scratch files are under `/tmp`, outside production source directories.

The existing instruction reducer now accepts multiple proxy postOp frames while preserving its single-frame entry point. For each nested instruction, it adds gas retained by ancestor callers; it resumes from actual caller gas on return, including Amsterdam state-gas credits. Peak = initial gas minus the lowest such aggregate remaining gas; net = initial gas minus final proxy-frame gas. These are whole proxy-frame figures, not transaction gas after refund caps, and exclude EntryPoint's own wrapper/penalty. Retained compact traces contain every postOp instruction and its state-gas reservoir; whole-test debug dumps are discarded after reduction.

## Amsterdam results at postOp limit 440,000

All 24 cases and all 80 operations completed, with no PostOpRevertReason. Each table reports **peak, net, and minimum remaining**, in gas, in operation order. B = BALANCE; C = CREDIT.

### N=2, balance, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 390,897 | 211,234 | 49,103 | Yes |
| 2 | B | 268,977 | 77,314 | 171,023 | Yes |

### N=2, balance, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 391,239 | 309,496 | 48,761 | Yes |
| 2 | B | 151,057 | 57,314 | 288,943 | Yes |

### N=2, credit, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 372,998 | 291,266 | 67,002 | Yes |
| 2 | C | 263,078 | 71,426 | 176,922 | Yes |

### N=2, credit, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 389,186 | 389,186 | 50,814 | Yes |
| 2 | C | 145,158 | 51,426 | 294,842 | Yes |

### N=2, mixed-bc, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 390,897 | 211,234 | 49,103 | Yes |
| 2 | C | 263,078 | 71,426 | 176,922 | Yes |

### N=2, mixed-bc, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 390,897 | 211,234 | 49,103 | Yes |
| 2 | C | 155,158 | 61,426 | 284,842 | Yes |

### N=2, mixed-cb, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 372,998 | 291,266 | 67,002 | Yes |
| 2 | B | 280,977 | 89,314 | 159,023 | Yes |

### N=2, mixed-cb, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 372,998 | 291,266 | 67,002 | Yes |
| 2 | B | 173,057 | 79,314 | 266,943 | Yes |

### N=3, balance, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 390,897 | 211,234 | 49,103 | Yes |
| 2 | B | 268,977 | 77,314 | 171,023 | Yes |
| 3 | B | 268,977 | 77,314 | 171,023 | Yes |

### N=3, balance, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 391,239 | 309,496 | 48,761 | Yes |
| 2 | B | 151,399 | 57,656 | 288,601 | Yes |
| 3 | B | 151,057 | 57,314 | 288,943 | Yes |

### N=3, credit, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 372,998 | 291,266 | 67,002 | Yes |
| 2 | C | 263,078 | 71,426 | 176,922 | Yes |
| 3 | C | 263,078 | 71,426 | 176,922 | Yes |

### N=3, credit, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 389,186 | 389,186 | 50,814 | Yes |
| 2 | C | 145,158 | 51,426 | 294,842 | Yes |
| 3 | C | 145,158 | 51,426 | 294,842 | Yes |

### N=3, mixed-bc, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 390,897 | 211,234 | 49,103 | Yes |
| 2 | C | 263,078 | 71,426 | 176,922 | Yes |
| 3 | B | 268,977 | 77,314 | 171,023 | Yes |

### N=3, mixed-bc, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 391,239 | 309,496 | 48,761 | Yes |
| 2 | C | 155,158 | 61,426 | 284,842 | Yes |
| 3 | B | 151,057 | 57,314 | 288,943 | Yes |

### N=3, mixed-cb, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 372,998 | 291,266 | 67,002 | Yes |
| 2 | B | 280,977 | 89,314 | 159,023 | Yes |
| 3 | C | 263,078 | 71,426 | 176,922 | Yes |

### N=3, mixed-cb, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 389,186 | 389,186 | 50,814 | Yes |
| 2 | B | 173,057 | 79,314 | 266,943 | Yes |
| 3 | C | 145,158 | 51,426 | 294,842 | Yes |

### N=5, balance, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 390,897 | 211,234 | 49,103 | Yes |
| 2 | B | 268,977 | 77,314 | 171,023 | Yes |
| 3 | B | 268,977 | 77,314 | 171,023 | Yes |
| 4 | B | 268,977 | 77,314 | 171,023 | Yes |
| 5 | B | 268,977 | 77,314 | 171,023 | Yes |

### N=5, balance, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 391,239 | 309,496 | 48,761 | Yes |
| 2 | B | 151,399 | 57,656 | 288,601 | Yes |
| 3 | B | 151,399 | 57,656 | 288,601 | Yes |
| 4 | B | 151,399 | 57,656 | 288,601 | Yes |
| 5 | B | 151,057 | 57,314 | 288,943 | Yes |

### N=5, credit, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 372,998 | 291,266 | 67,002 | Yes |
| 2 | C | 263,078 | 71,426 | 176,922 | Yes |
| 3 | C | 263,078 | 71,426 | 176,922 | Yes |
| 4 | C | 263,078 | 71,426 | 176,922 | Yes |
| 5 | C | 263,078 | 71,426 | 176,922 | Yes |

### N=5, credit, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 389,186 | 389,186 | 50,814 | Yes |
| 2 | C | 145,158 | 51,426 | 294,842 | Yes |
| 3 | C | 145,158 | 51,426 | 294,842 | Yes |
| 4 | C | 145,158 | 51,426 | 294,842 | Yes |
| 5 | C | 145,158 | 51,426 | 294,842 | Yes |

### N=5, mixed-bc, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 390,897 | 211,234 | 49,103 | Yes |
| 2 | C | 263,078 | 71,426 | 176,922 | Yes |
| 3 | B | 268,977 | 77,314 | 171,023 | Yes |
| 4 | C | 263,078 | 71,426 | 176,922 | Yes |
| 5 | B | 268,977 | 77,314 | 171,023 | Yes |

### N=5, mixed-bc, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | B | 391,239 | 309,496 | 48,761 | Yes |
| 2 | C | 155,553 | 61,426 | 284,447 | Yes |
| 3 | B | 151,399 | 57,656 | 288,601 | Yes |
| 4 | C | 145,158 | 51,426 | 294,842 | Yes |
| 5 | B | 151,057 | 57,314 | 288,943 | Yes |

### N=5, mixed-cb, distinct user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 372,998 | 291,266 | 67,002 | Yes |
| 2 | B | 280,977 | 89,314 | 159,023 | Yes |
| 3 | C | 263,078 | 71,426 | 176,922 | Yes |
| 4 | B | 268,977 | 77,314 | 171,023 | Yes |
| 5 | C | 263,078 | 71,426 | 176,922 | Yes |

### N=5, mixed-cb, same user(s)

| Op | Mode | Peak consumed | Net consumed | Minimum remaining | Complete |
|---:|:---:|---:|---:|---:|:---:|
| 1 | C | 389,186 | 389,186 | 50,814 | Yes |
| 2 | B | 173,399 | 79,656 | 266,601 | Yes |
| 3 | C | 145,158 | 51,426 | 294,842 | Yes |
| 4 | B | 151,057 | 57,314 | 288,943 | Yes |
| 5 | C | 145,158 | 51,426 | 294,842 | Yes |

## Worst case and admission floor

**The worst observed peak is 391,239 gas, leaving 48,761 gas at 440,000 (11.08% of the initial limit).** It occurs in operation 1 for same-user all-BALANCE bundles of N=2, 3, and 5, and same-user BALANCE-first alternating bundles of N=3 and 5. That operation's net consumption is 309,496. This is 342 gas above the earlier single-operation BALANCE peak of 390,897.

The highest net consumption is **389,186**, in operation 1 of same-user all-CREDIT N=2, 3, 5 and CREDIT-first alternating N=3, 5. Its peak is also 389,186 and minimum remaining is 50,814. Thus the operation with the greatest peak is not the operation with the greatest net consumption.

All measured bundles complete at MIN_POST=440,000. The runner chooses the N=5, same-user, BALANCE-first alternating case among the tied worst cases and separately runs it at 439,999. The test requires exact EntryPoint FailedOp(0, "AA34 signature error") at that lower limit. This is an **admission failure**, not a settlement out-of-gas result. The settlement limit cannot be probed below the admission floor without changing the configured contract. Consequently there is no 2,000-gas-step/bisection settlement search: the task's admission-floor exception applies. The measured answer is 48,761 minimum remaining, not a claimed intrinsic execution threshold of 440,000.

## Implications for the final tuple

The measured tuple remains `MIN_POST / SETTLE / C_WRAP / C_POSTOP = 440000 / 420000 / 5000 / 340000`. It completes these bundles. A final tuple must allow the **intermediate peak**, including proxy and forwarding effects, and must separately account for the **net settlement cost** when evaluating reimbursement. Amsterdam credits arriving later in a frame cannot finance an earlier gas shortage.

The matrix supplies observed lower bounds for that design exercise: peak 391,239 and net 389,186. The existing C_POSTOP=340,000 is 49,186 below the observed maximum whole-proxy net frame. That comparison alone is not a subsidy calculation: EntryPoint wrapper/penalty, C_WRAP, the budget term, and charge accounting must be reconciled in a dedicated no-subsidy test. SETTLE is an implementation-entry guard, not the same measurement boundary as the outer proxy peak. Do not simply subtract these frame numbers from SETTLE to claim internal guard headroom.

This work closes the stated multi-operation peak measurement for these fixtures. It does **not** choose or deploy a final tuple, prove reimbursement sufficiency, or establish a production bound. A margin policy and parameter acceptance tests remain necessary before adoption.

## Not established

- Bundles larger than five, multiple operators/tokens, arbitrary operation orderings, different reservation amounts, fees, calldata, target behavior, or account implementations.
- Other token implementations/configurations, credit tiers, prices, renewal/emergency/rotation paths, user reverts, pre-existing debts/counters, and every possible Amsterdam state-gas reservoir regime.
- Different engine revisions, live bundler estimates, transaction/block limits, malicious tokens, or universal out-of-gas/no-subsidy guarantees.
- An intrinsic minimum postOp execution budget below the configured admission floor.

## Reproduction and verification

```sh
PROFILE_DEPS_ROOT=/Users/jason/Dev/aastar/SuperPaymaster \
  bash script/evidence/postop-multiop-run.sh EMPTY_OUT_DIR
python3 script/evidence/postop-multiop-verify.py EMPTY_OUT_DIR
python3 contracts/test/postop_multiop_evidence_test.py EMPTY_OUT_DIR
```

The runner rejects nonempty output directories. The verifier requires the complete Cartesian inventory: 24 cases on each of three engines plus the single worst-case floor control, exactly 73 commands. It checks their selectors, exit codes and successful test counts; all 24 Amsterdam trajectories and all 80 per-operation frozen measurements; frame arithmetic; and source/evidence hashes. Expected numbers reside in `contracts/test/fixtures/postop-multiop-expected.json` and are never updated by the runner. The Python regression tests fail if any measured number changes.

The negative control removes one complete case from commands, logs, trajectories and numbers, then recomputes the evidence manifest. Verification must still reject it for missing inventory, rather than accepting the remaining successful commands. Raw retained evidence is in [run/](run/).

## Retained run and command exit codes

| Check | Result | Exit code |
|---|---|---:|
| Amsterdam matrix | 24 cases / 80 operations complete; frozen trajectories match | 0 for every command |
| Cancun completion control | 24 cases / 80 operations complete | 0 for every command |
| Prague completion control | 24 cases / 80 operations complete | 0 for every command |
| Amsterdam worst-case budget 439,999 | Exact validation rejection asserted | 0 |
| Full runner/wrapper | 73/73 Forge commands and evidence checks pass | 0 |
| Standalone verifier (invoked by runner) | Complete inventory, hashes, all frozen numbers pass | 0 |
| Python evidence regression tests | 2 passed, including resealed missing-case negative control | 0 |
| Verifier on missing-case run | Rejected, as required | 1 |
| Runner on nonempty output directory | Rejected, as required | 1 |
| Solidity formatting / git whitespace / unchanged production source checks | Pass | 0 |

See [validation.log](validation.log), [run/commands.jsonl](run/commands.jsonl) (per-command exit codes), [nonempty-output-control.log](nonempty-output-control.log), and [run/SHA256SUMS](run/SHA256SUMS). The missing-case CLI check is performed inside the Python test and its exit 1 is asserted. Forge's logs may include failed automatic dependency-install warnings for the unpopulated worktree submodules; the explicit read-only remappings resolve the imports, and the retained test commands all exit zero.

Files added: the multi-operation Solidity fixture, frozen per-operation JSON, Python evidence tests, runner/wrapper/verifier, this report and retained evidence. Existing files changed: the profiling fixture's setUp is now virtual to allow reuse; the reducer supports multiple frames while retaining the original single-frame API. All changes are confined to `contracts/test/`, `script/evidence/`, and `docs/`; `contracts/src/` is unchanged.
