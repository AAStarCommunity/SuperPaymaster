# DeployLive round 6c validation

Built on the supplied uncommitted rounds 6/6b tree. No formatter, network, RPC,
keystore, .env or git writes; no edits to contracts/src or TimelockHandoverBootstrap.
All generated evidence and the starting snapshot are inside ignored
`cache/deploylive-tests/round6c/`. The previous validation report is preserved in
that snapshot; round 6b's evidence remains in its existing cache directory.

## Treasury and accounting

Production sets staking treasury immediately after deployment and SP treasury
immediately after proxy deployment. Both setters were removed from handover;
there is no duplicate transaction. The v5.4-relative TL prediction changes from
+9 to +7 (three v5.4 transactions plus four handover transactions). The recorded
transaction walk independently derives the pre-H count and TL-to-H distance;
it does not assume a fixed total transaction count.

N=3 measured accounting (GToken, 18 decimals):

| Quantity | Amount |
|---|---:|
| Minted / totalSupply | 2199 |
| Staked | 140 |
| ticketsToTreasury | 74 |
| deployerRemainderToRecipient | 1985 |
| Deployer final balance / allowance | 0 / 0 |

`_assertHandover` and the checker enforce minted = staked + treasury tickets +
recipient remainder = totalSupply. Config records both measured amounts, the
pre-registration treasury balance, and the pre-transfer recipient balance. When
recipient is Safe, the final balance is 2059; the 74 tickets are excluded from the
1985 remainder. With a separate recipient, Safe holds 74 and the recipient 1985.
Both scenarios have independent output paths: the distinct-recipient test writes
under `cache/deploylive-tests/separate/`. They run as separate tests to stay within
the per-test gas limit. Each test records the two measured config fields.

## External tokens

`inputs/external-tokens.json` contains all seven requested OP entries and all
three Sepolia entries with explicit labels, addresses and decimals. The rehearsal
inputs select that file through EXTERNAL_TOKENS_FILE; the inventory also accepts
config.externalTokens for local mock groups. eth_chainId selects the group.
Every listed token must have code, then return exactly one ABI uint256 balance
for every contract in the failed set. No code means FAIL and no balance call;
unknown chain, empty group, unreadable balance and positive balance all FAIL.
The tests use distinct addresses for all 27 inventory entries and assert every
listed-token/holder pair was read. The positive fixture deliberately emits no
Transfer log. Existing log-discovered-token and ETH failure tests remain.

The log scan cannot see an unlisted non-standard token that emits no Transfer
event. Both handoff and security disclosures retain this limit. No on-chain
verification or claim of an exhaustive inventory of all possible tokens is made.

## Red evidence

Before implementation changes, the distinct-recipient regression failed against
round 6b:

```text
[FAIL: round6: treasury tickets] test_TicketsReachSafeWithSeparateRecipient() (gas: 318535166)
```

This named scenario is retained as its own production test. The five new
external-token behavior tests were also run first against the unchanged code:

```text
Ran 6 tests in 0.035s
FAILED (failures=5)
```

All-zero fails there because the original implementation never reads the listed
token. The other failures are positive-without-Transfer, unreadable, no-code and
unknown chain. The four metadata/empty-group tests were first executed against
the saved unchanged module (after implementation editing), then the final module:

```text
Ran 4 tests in 0.003s
FAILED (failures=4)
```

The updated accounting checker fixture and negative cases ran before checker
changes; the unchanged checker rejected the valid three-way accounting and lacked
the new treasury checks and integer input validation:

```text
Ran 21 tests in 1.068s
FAILED (failures=10)
```

Logs: red-treasury.log, red-external.log, red-external-metadata.log and
red-checker.log. Existing handover negative probes still cover every ticket-ledger
entry and conservation. When Safe is the recipient, corrupting its final balance
now reaches `handover: treasury tickets` before the recipient-delta assertion;
the separate-recipient scenario still independently reaches the latter.

## Final commands and verbatim result excerpts

`forge build --offline` (exit 0; complete warnings in build-final.log):

```text
Compiling 1 files with Solc 0.8.33
Solc 0.8.33 finished in 10.80s
Compiler run successful with warnings:
Warning (4591): There are more than 256 warnings. Ignoring the rest.
```

`forge test --offline --match-path 'contracts/test/scripts/DeployLive*.t.sol'` (exit 0):

```text
Suite result: ok. 7 passed; 0 failed; 0 skipped; finished in 577.42µs (289.42µs CPU time)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 13.14ms (13.85ms CPU time)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 14.31ms (3.05ms CPU time)
Suite result: ok. 29 passed; 0 failed; 0 skipped; finished in 15.42ms (42.88ms CPU time)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 273.68ms (272.87ms CPU time)
Suite result: ok. 2 passed; 0 failed; 0 skipped; finished in 1.74s (3.46s CPU time)
Ran 6 test suites in 1.75s (2.05s CPU time): 47 tests passed, 0 failed, 0 skipped (47 total tests)
```

`python3 -m unittest discover -s script/rehearsal -p 'test_deploylive*.py'` (exit 0):

```text
..........................................
----------------------------------------------------------------------
Ran 42 tests in 1.143s

OK
SUMMARY 159 passed, 0 failed, 159 total
```

`python3 -m unittest discover -s script/rehearsal -p 'test_creation_pins.py'` (exit 0):

```text
.
----------------------------------------------------------------------
Ran 1 test in 0.004s

OK
```

Production fixture measurements (each recipient scenario):

```text
pre-H zero-value transactions: 96
TL-to-H observed distance: 22
ticketsToTreasury: 74000000000000000000
deployerRemainderToRecipient: 1985000000000000000000
```

The checker SUMMARY is from mocked read-only calls, N=2, not a live RPC run.
The count formula is **155 + 2N**: **159 at N=2**, **161 at N=3**. Round six's
153 + 2N gains the 6b Safe-owner exclusion and the 6c treasury-ticket assertion.
The handoff contains all 159 concrete N=2 rows mapped to the original 53, with
instructions for the extra guardian/stake rows at N=3. The external-token audit
is separate from this post-deployment count; INFO and N/A lines do not count,
except the two explicitly counted implementation-isolation INFO-PASS rows.

`git diff --stat bfb9cc45 -- contracts/script/v3/TimelockHandoverBootstrap.sol`
produced no output. `git diff -- contracts/src` and `git diff --check` also
produced no output. Existing build warnings remain in build-final.log.

## Per-file round-6c delta

Added/deleted lines versus the starting round-6b worktree snapshot, using
`git diff --no-index --numstat`; not versus HEAD. Generated logs, caches and
compiler artifacts are excluded. The new external-token file is counted from empty.

| File | Added | Deleted |
|---|---:|---:|
| `contracts/script/v3/DeployLive.s.sol` | 18 | 6 |
| `contracts/test/scripts/DeployLiveNonce.t.sol` | 2 | 2 |
| `contracts/test/scripts/DeployLiveProduction.t.sol` | 28 | 12 |
| `docs/security/rc8-daybreak-fixes.md` | 13 | 2 |
| `script/rehearsal/DEPLOYLIVE_HANDOFF.md` | 199 | 9 |
| `script/rehearsal/DEPLOYLIVE_VALIDATION.md` | 140 | 186 |
| `script/rehearsal/deploylive_failed_set_check.py` | 44 | 5 |
| `script/rehearsal/deploylive_postdeploy_check.py` | 4 | 3 |
| `script/rehearsal/inputs/deploylive-rehearsal.inputs` | 3 | 0 |
| `script/rehearsal/test_deploylive_failed_set.py` | 50 | 0 |
| `script/rehearsal/test_deploylive_postdeploy_check.py` | 16 | 3 |
| `script/rehearsal/inputs/external-tokens.json` | 56 | 0 |
