# Manifest executor — round 5

Changes remain uncommitted. No Git metadata writes, signing, public broadcasting, key access, contract-source edits, or protected evidence edits were performed.

## Changes

- Replaced the old `dvtCommit`/arbitrary setup fixture with separate `toolCommit` and pinned `verifierCommit`, derived A7/A12a bindings, pinned Registry/block/guardian set, domain, proposal id, proof id, proof bytes, signer mask, message hash, mock runtime/keccak and commitment slot/value.
- The build runs `forge inspect BLSAggregator storage-layout --offline --json` in an isolated committed tree. The executor checks mapping type and build parity, derives the proposal's storage slot itself, and refuses fixture disagreement. The drill reads the written value back through `proposalSignersCommitment(pid)`.
- The post-B4 drill takes an outer snapshot before code/storage writes and a separate snapshot for every case. Reports retain both levels of snapshot ids, code and storage writes, A7/verifier runtime hashes checked against the packet, tool/verifier revisions, receipts, exact selectors, and restoration read-backs. Cleanup runs on failure too. Restored commitment and empty T code are checked after the outer revert.
- Valid asserts successful receipt, frozen case and the complete `GuardianSlashQueued` event. N1 removes exactly one pinned guardian; N2 writes T.over=true at slot 0 and reuses the proof; N3 changes exactly one signerMask bit; N4 changes one digest bit and calls the verifier directly, requiring false.
- N1–N3 require the complete `InvalidFraudProof(uint256)` revert payload, including the expected id. N3 has no distinct custom commitment error: at verifier commit `72aca4fa`, `_commitmentMatches` failure returns false through `check`/`verify`, and A7's `queueGuardianSlash` raises `InvalidFraudProof`.

## Verification

| Suite | Passed | Failed |
| --- | ---: | ---: |
| Manifest Python | 71 | 0 |
| Existing upgrade Python | 141 | 0 |
| A3a executor Python | 92 | 0 |
| Solidity ManifestSolvencyTest (including inherited tests) | 9 | 0 |
| Total | 313 | 0 |

Commands:

```sh
python -B -m unittest discover -s script/upgrade -q
python -B script/a3a/test_a3a_exec.py
FOUNDRY_TEST=script/upgrade /Users/jason/.foundry/bin/forge test \
  --offline --root /tmp/manifest-round2-tree \
  --match-contract ManifestSolvencyTest -vv
```

Schema/validator refusal cases include wrong verifier commit, malformed tool commit, wrong A7/A12a, wrong pin/Registry, unsorted/foreign guardians, each missing N-case, wrong slot, wrong runtime digest and invalid mutation definitions. Additional tests demonstrate independent tool revision recording and storage-layout changes causing slot refusal.

The fake chain enforces that every code/storage mutation occurs inside a snapshot, every case starts with unqueued state, and only N2 sees over=true. It checks exact queue calldata and N4's direct verifier arguments. Failure cases cover missing event, wrong frozen state, failed commitment read-back, each incorrect N1–N3 selector, N4 returning true, wrong runtime/domain/derived id, and failed main-state restoration.

A separate `forge inspect BLSAggregator storage-layout --offline --json` run against the matching temporary tree succeeded; the real mapping base slot was 16, and the executor successfully derived a sample proposal slot from that output. `git diff --check` passed.

The Solidity run uses the existing temporary dependency tree. All 59 worktree `contracts/src/*.sol` files match it byte-for-byte; the manifest Solidity test matches except for its temporary import path. This is the relevant manifest Solidity suite, not a full repository Solidity regression. The A3a signing/sending suite remains excluded because it performs synthetic-key signing.

## Integration limits

The local DVT checkout and available history contain no `--export-fraud-drill` implementation. Its checkout is still at `72aca4fa`; no real export fixture or export-tool commit was supplied. The schema documents the input contract, but compatibility with actual exporter output remains unverified. `toolCommit` records the reviewed export's revision; it is not silently substituted with the verifier revision.

The fixture digest binds reviewed bytes and runtime keccak detects mismatches. The tool revision and mock runtime's claimed source provenance still require DVT review. Synthetic tests do not establish cryptographic proof validity. No authenticated fork run or releasable packet was produced. A real exported fixture, reviewed release inputs, clean tagged build and authenticated fork are still required. The drill also does not prove `verifyAndExecute` commitment parity or exercise `_checkSignatures`; those remain source-level/precompile-test obligations under spec §7.
