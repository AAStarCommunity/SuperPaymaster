# Manifest executor — round 4

Changes are uncommitted. No signing, broadcasting, key access, contract-source changes, protected evidence changes, or Git metadata edits were performed.

## Implemented gates

1. Mandatory SHA-256-bound `fraudProofFixture`, produced by DVT for the selected pin and derived A7 address. The schema uses the exact arguments of `queueGuardianSlash(uint256 fraudProofId, address[] guiltyGuardians, bytes fraudProof)`, which calls `IFraudProofVerifier.verify`. After B4, the local fork applies impersonated setup calls on an outer snapshot. Each proof starts on its own snapshot from the same setup state. Valid submission must succeed, freeze the expected proof/guardian hashes and pending status, and emit the expected `GuardianSlashJudgmentFrozen` event naming A12a. Invalid submissions must mine status 0 with a revert trace (out-of-gas is refused). All snapshots are restored, including on failure. The fixture digest and receipts enter the rehearsal report. Omitting the fixture refuses construction.
2. Collection reads OLD aggregator `MAX_VALIDATORS()` and all 13 `validatorAtSlot(uint8)` values at the pin. The supplied PoP `(validator, slot)` set must equal exactly the nonempty pinned inventory. Anni is fixed to `0xecaacb915f7d92e9916f449f7ad42bd0408733c9`.
3. Structured, digest-checked evidence for conformance, mutation, slither, reproducible-build, dvt-ci and dvt-conformance-4.12. Every record requires kind, subject commit, named/versioned tool, positive passed count, zero failed count, explicit skipped count, and PASS. SP subjects must match the frozen release commit. DVT records must bind both the pinned verifier commit and the SP commit, and name `BLSAggregator-4.12.0`. Independently compiled version AST and A7's version read-back must match. Dirty trees, changed HEAD versus cached build, wrong commits and stale versions fail. The existing source-verification-plan file requirement is retained.
4. Every amended A3a step S1/S2/S3/S4/S5a/S5b/S6a/S6b/S7 requires its successful mined receipt and exact planned identity via `a3a_exec.mined_identity`. Collection checks canonical blocks. Both embedded amended-plan gaps and outer pre-pin gaps are re-proven via `a3a_exec.check_gaps`; recorded reads are replayed by the offline builder. A contract-call embedded gap is explicitly tested and refused.
5. Dedicated negative tests reach the recursive Registry layout, storage count, owner slot, single-upgrade and implementation-identity gates. These tests pass all preceding checks, so removal of the target gate causes the expected assertion failure.

Schemas: [fraud fixture](fraud-proof-fixture.schema.json), [per-kind release evidence](release-evidence.schema.json). Usage and field semantics: [README](README.md).

## Verification

| Suite | Result |
| --- | --- |
| Manifest Python | 66 passed |
| Existing upgrade Python | 141 passed |
| A3a executor Python | 92 passed |
| Solidity ManifestSolvencyTest, including inherited tests | 9 passed |
| Total | 308 passed, 0 failed |
| Requested temporary-removal mutations | 5 killed, 0 survived |

Commands:

```sh
python -B -m unittest discover -s script/upgrade -q
python -B script/a3a/test_a3a_exec.py
FOUNDRY_TEST=script/upgrade /Users/jason/.foundry/bin/forge test \
  --offline --root /tmp/manifest-round2-tree \
  --match-contract ManifestSolvencyTest -vv
```

The Solidity run used the existing isolated temporary dependency tree. All `contracts/src/*.sol` bytes were compared recursively with this worktree and matched. The current `ManifestSolvency.t.sol` was copied there, changing only its relative import for the temporary location. No dependency installation or worktree Forge build was attempted. The 9 Solidity tests include both manifest buffer tests and 7 inherited real SP/token integration tests. This is not a full repository Solidity regression run. The A3a signing/sending test suite was excluded because it performs real synthetic-key signing, which the task prohibits.

Temporary mutations were applied individually and restored in `finally`. Every result below failed specifically with `AssertionError: Gate not raised`, not an import error or an earlier gate:

| Removed gate | Test that killed it |
| --- | --- |
| Recursive Registry storage comparison | `test_registry_recursive_layout_required` |
| Registry 32-variable requirement | `test_registry_32_variables_required` |
| Registry owner slot zero | `test_registry_owner_slot_required` |
| B2 single-upgrade requirement | `test_b2_single_upgrade_required` |
| B2 implementation identity | `test_b2_implementation_identity_required` |

Additional negative coverage includes each evidence kind's FAIL/zero-pass/nonzero-failure/missing-skipped/wrong-commit refusal; DVT wrong SP commit/version; stale tree/current HEAD/built version; fixture schema/pin/A7 binding; guardian identity/slot and Anni; every earlier A3a mined identity; and embedded contract-call gaps. Synthetic fraud orchestration tests cover setup, valid and invalid receipts, wrong state, missing event, out-of-gas refusal, and snapshot restoration. The main runner test asserts that the fraud rehearsal is invoked.

## Release limits

**Cryptographic validity is established only by the real authenticated fork run with the DVT-produced fixture and deployed verifier.** Python fixtures are synthetic and perform no cryptographic proof verification. No authenticated fork or releasable Sepolia packet was produced: the real DVT fraud fixture and reviewed release inputs were not supplied, and this uncommitted tree intentionally fails the release clean-tree gate.

Evidence validation establishes structure, digest, result and revision applicability; it does not authenticate the report author or rerun the named analysis tools. The executor remains an unsigned Phase A/B builder and local rehearsal tool. Phases C/D and an eventual broadcaster's authorization/hash enforcement remain outside this implementation.
