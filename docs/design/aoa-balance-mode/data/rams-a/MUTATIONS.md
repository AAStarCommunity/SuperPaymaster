# Route A procedure mutations

The current definitions are `mutations-def4/M1.diff` through `M21.diff` and `mutations-def4/targets.tsv`, generated at committed HEAD. **Observed: `mutations-run10/` (commit ec8f2c0c) CONTROL 16/16 GREEN, M1–M21 all KILLED by their expected assertion.** Superseded: `mutations-run9/` (M20 killed by a changed revert, not a granted role; A6e now uses a qualified prospect), `mutations-run8/` (M19 WRONG-ASSERTION, read-back fired first; fixed by a unique message plus M21), `mutations-run7/` (M1–M18, pre-A6e), `mutations-run6/` (M16–M18 PATCH-FAILED: generated before commit — the generator reads `git show HEAD:`, so **commit the test change first, then generate**), `mutations-run5/`, `mutations-run4/`. `mutations-run2/` keeps the original 13 definitions byte-for-byte.

After the owner establishes the reviewed rehearsal as HEAD, regenerate into a fresh directory and copy the target contract:

```bash
D=docs/design/aoa-balance-mode/data/rams-a/mutations-review2
bash script/evidence/rams-a-mutations-generate.sh "$D"
cp docs/design/aoa-balance-mode/data/rams-a/mutations-def4/targets.tsv "$D/targets.tsv"
FORGE=/absolute/path/to/amsterdam-nightly/forge \
SEPOLIA_FORK_RPC="$ARCHIVE_RPC" FORK_BLOCK=11974561 \
OPERATORS="$COMPLETE_OPERATOR_INVENTORY" \
bash script/evidence/rams-a-mutations-inplace.sh "$D" "$D/results"
```

The runner refuses to run when the rehearsal differs from HEAD. It obtains the baseline with `git show HEAD:<target>`, applies each patch with zero fuzz, and restores the baseline on exit. Its first failure for the exact target must contain column 3 of `targets.tsv`. An unrelated assertion is WRONG-ASSERTION, a pass is SURVIVED, and a skip or missing result is INVALID. CONTROL requires every route test to pass without skips. The runner exits nonzero for any other outcome.

| ID | Mutation | Required failure |
| --- | --- | --- |
| M1 | Empty atomic upgrade calldata | `atomic global pause` |
| M2 | Skip first operator pause | `operator pause read-back` |
| M3 | Activate at ETA−1 | `RAMS A5: activation not mature` |
| M4 | Resume before gas activation | `exact SIG_FAILURE required` |
| M5 | Queue SETTLE=160000 | `SETTLE read-back` |
| M6 | Extra executor at construction | `extra executor` |
| M7 | Execute upgrade batch at its ETA in the early negative | `RAMS A6: upgrade batch executed before delay` |
| M8 | Omit guardian gate | `RAMS gate negative: RAMS gate: guardian` |
| M9 | A2 upgrade without global pause | `exact SIG_FAILURE required` |
| M10 | Submit pre-signed operation before pause | `RAMS A4: pre-signed operation escaped pause` |
| M11 | Remove required predecessor on mature 5.5.0 activation | `TimelockUnexecutedPredecessor` |
| M12 | Skip ANNI rejection probes | `all operator classes probed` |
| M13 | Grant executor after constructor audit | `RAMS A6: non-Safe executor accepted` |
| M14 | Omit global pause and disable upgrade read-backs | `exact SIG_FAILURE required` |
| M15 | Skip one pause and disable pause read-backs | `exact SIG_FAILURE required` |
| M16 | Omit an operator from gate input | `RAMS gate: missing inventory` |

M3 catches failure of the intended successful activation with a distinct message. M7 now exercises the early-delay negative itself; it no longer relies on a missing legacy selector. M8, M10, and M13 use low-level calls with distinct failure messages and exact revert payload checks. M11 proves predecessor enforcement after upgrading, with a mature gas queue and an unexecuted required batch.

M14 and M15 must reach the validation probes even when helper read-backs are disabled. A3 counts returned SIG_FAILURE results rather than loop iterations. M16 tests gate inventory omission against the setup's inventory commitment. External scan completeness remains assumed.

M5 is killed only by the tuple read-back. No universal settlement need or margin is claimed. The historical A5b thresholds 438,786 and 174,659 measure synthetic postOp guard crossings with cost=100000 and fee=1 under no-isolate. Their delta 264127 equals `ceil(260000 * 64 / 63)`, consistent with EIP-150 forwarding scaling. The 4127 excess is forwarding overhead, not extra settlement work; exact trace attribution remains pending. The former 1214 settlement-margin claim is withdrawn. A5c adds actual `handleOps` MIN−1/MIN/MIN+1 checks for the proposed tuple. See [README.md](README.md) for evidence limits and the separate R-AMS-2a fixture measurements.
