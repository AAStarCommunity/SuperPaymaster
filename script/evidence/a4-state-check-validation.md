# A4 fixed-block checker and release checker evidence

The release conformance schema now describes **checker logic only** with
`scope: checker-logic-offline`. Every C1–C9 entry requires a primary suite and exact
Python test name, nonempty positive/negative test references, and PASS. The
validator checks test definitions without importing or executing the referenced
files. It retains the existing subjectCommit/tag/head binding in release_gate.
This verifies references and attestations, not test execution by itself.

`a4-conformance-record.template.json` preserves the DSR mapping. It is deliberately
**not releasable**: subjectCommit is null, the overall result is BLOCKED, and the
Anvil run did not complete. Do not substitute an arbitrary commit or copy test
fixture PASS values into a release record. Once the real control succeeds, bind
this record to the actual release tag commit and replace counts with that run's
observed totals. No release tag or subject commit was selected or created for this task.

## State-check invocation

```
python3 script/evidence/a4_state_check.py \
  --rpc-a-file rpc-a.txt --rpc-b-file rpc-b.txt \
  --config state-input.json --out state-evidence.json
```

The config contains `token`, `user`, `sp`, `community`, integer `block`, optional integer
`deployBlock`, and optional `knownOperations: {source, opHashes}`. A supplied
list may add hashes but must include every chain-derived hash; omissions STOP
C6/C9. Without a list the inventory is derived entirely from chain history. `pins` contains
`factory`, `implementation`, `extension`, `factoryCodehash`,
`implementationCodehash`, and `extensionCodehash`. Addresses/hashes are full hex
strings. These are trusted, reviewed release inputs, not values inferred from the
contract being checked. Both endpoints must support archive reads and
`eth_getBlockReceipts`. The end block must be finalized on both endpoints.

Fixed-block code/getter reads use EIP-1898 `{blockHash, requireCanonical:true}`;
responses must be identical before ABI decoding. Block hashes are checked again
at the end. The record includes raw getter reads, the embedded logscan, the debt
user set, and the supplied/discovered union of operation hashes with its source.
C6 checks every union hash for the requested user. C8 checks every history-touched
user plus the requested user. C9 checks the union plus all EntryPoint-discovered hashes, including
all supplied pre-window operations. Caller additions need not enumerate the new
EntryPoint inventory; it is always added automatically. An unavailable history makes C4/C6/C7/C8/C9
unverified. A non-pass item blocks the overall result.

C1 checks the exact 45-byte EIP-1167 runtime, token FACTORY, factory implementation,
getTokenAddress/community binding and isXPNTs, actual factory/core/extension code
hashes, and factory-pinned core/extension hashes. C3 uses hasPendingPolicy: the
source leaves pendingPolicyEta populated after execution/cancellation. C6 decodes
CreditRes as `(uint128 amount, address locker)` and checks locker independently of
amount. C9 decodes `(address operator, uint256 a0)` and requires both zero.

Creation blocks for the token and SP proxy are derived independently by bisection
of `eth_getCode` on both endpoints over [0, B]. Optional
`tokenCreationLowerBound` and `spCreationLowerBound` narrow the search, but the
result must still have empty code at creation−1 and nonempty code at creation.
Every probe must agree; missing archive data or disagreement blocks verification.
The result records both blocks in `derivedBlocks`. This assumes persistent code;
genesis deployments cannot provide the required predecessor proof.

Credit and lock discovery starts at token creation (or an earlier `deployBlock`);
SP event discovery starts at SP creation. A later caller start is rejected.
Every scan cross-checks receipt log lists only for hit blocks plus seeded samples.
Full completeness relies on dual-endpoint agreement + split consistency;
per-block coverage is NOT claimed. This limitation is also emitted in `coverage`. An incomplete
scan blocks C6/C9 even with an empty inventory.

### C9 EntryPoint discovery and coverage argument

Configure `entryPoint` (defaults to EntryPoint v0.7
`0x0000000071727De22E5E9d8BAf0edAc6f37da032`) and, optionally, an earlier pinned start:

```json
"inflightStart": {
  "block": 123456,
  "blockHash": "0x<64 hex digits>",
  "source": "inflight-upgrade"
}
```

`inflightStart.block` must be at or before the derived SP creation block.
If supplied, its hash must match both endpoints and its source must be
`sp-proxy-deploy` or `inflight-upgrade`; the source label grants no authority to
skip history. If omitted, scanning starts at derived SP creation.

The configured EntryPoint must equal `SP.entryPoint()` on both endpoints at B,
at SP creation, and at every block containing an ERC-1967 `Upgraded(address)`
event. Upgrade logs are enumerated over [SP creation, B] with the same cap,
chunking, finality, and hit-block plus seeded-sample receipt cross-checks. Historical getter
reads use agreed block hashes. Missing history or a differing binding leaves C9
unverified. Output includes the upgrade scan and the binding reads.

The checker scans the inclusive [inflightStart.block, B] range at the configured
EntryPoint address for
`UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)` with
topic3 equal to the padded SP address. It uses the same dual-endpoint adaptive
chunking, provider-cap checks, finality/hash checks, and hit-block plus seeded-sample receipt
log comparison as the credit scanner. The indexed filter applies to both RPC
queries and receipt selection, so foreign paymaster events are ignored. Topics,
address padding, data length and the ABI boolean are validated. Output records
the start provenance, EntryPoint address, scan evidence, completeness, and
`inflightHashSet` with EntryPoint-discovered and caller-supplied hashes.

Local source audit:

* `SuperPaymaster.sol:226` restricts validation to `onlyEntryPoint`; line 324 is
  the sole `_inflight` creation writer, after reservation. PostOp and release
  delete records. Thus persisted creations originate in EntryPoint validation.
* `EntryPoint.sol:108–165` emits UserOperationEvent on the inner low-prefund
  path, sends other inner failures through `_postExecution(postOpReverted)`, and
  reverts the whole bundle on AA95. Reverted bundles leave no persisted inflight.
* `_postExecution` (approximately lines 680–760) emits the event for normal
  settlement and the postOpReverted path, including insufficient prefund.
  `IEntryPoint.sol` declares userOpHash, sender and paymaster as indexed fields.
  Every included operation whose validation can persist therefore exposes its
  hash with the SP paymaster, even if postOp failed and left inflight state.

Consequently the complete EntryPoint inventory covers SP across all tokens.
C9 requires `inflightOf(h) == (0,0)` for every discovered hash plus caller
additions (and conservatively retains the prior credit/lock/SP inventory).
A nonzero record fails; complete empty history passes only after getter support
is verified at the fixed block; incomplete EntryPoint
history stays unverified even when no hashes were returned. Existing token
history and supplied-inventory guards remain in force.

Residual assumptions: the configured EntryPoint and SP throughout the window
must have the audited v0.7 validation/event semantics and inflight writer rules;
creation bisection assumes persistent contract code. Binding checks establish the
EntryPoint address at creation and upgrade block boundaries, not implementation semantics. Upgrades or alternate
EntryPoints require review of this argument. Receipt comparison is not a
cryptographic completeness proof; provider independence and identical omissions
remain limitations documented in `a4-credit-logscan-validation.md` (S562-0).
C6 remains covered by this token's credit creation events. No contract code was
changed.

Offline controls cover late SP/token starts, independent creation blocks,
archive gaps and disagreement, EntryPoint substitution and historical changes,
upgrade log omissions, and case-normalized receipt filtering for credit,
EntryPoint and upgrade events, with positive controls. Topics, addresses and data
are normalized before receipt selection and comparison.

Repository-root `python3 -B` runs on 2026-11-03 passed 48 state-check tests and 56 credit-logscan
tests. Guard removal killed 90/93 mutations with zero errors; only the three
previously documented legacy mutants survive independent receipt defenses.
Detailed outcomes are in `a4-guard-mutations.json`.

## DSR ruling — 2026-11-03

For the C9 regression, supply `expectedEntryPointHits: {head, opHashes}` in the
state config. `head` is the integer checkpoint height of the reviewed positive
control; it must fall between the scan start and fixed block. `opHashes` is the
reviewed array of full 32-byte hashes, normalized before comparison. Every hash
must occur at or before that checkpoint. Any missing hash makes C9 `fail` and the
overall result `FAIL`. The output's `discovery.entryPoint.positiveControl` records
expected hashes, checkpoint, missing hashes and result. `newHits` lists every
hit outside that list with `opHash` and `blockNumber`; additions do not themselves
fail C9, but their fixed-block inflight records must still be zero.

DSR's reference observation is **9 hits**, scanning from **11,151,016** to head
approximately **12,052,152**; first hit **11,155,147**, last **11,612,063**.
The actual nine hashes must come from the reviewed DSR input; counts and block
bounds are not a substitute for those hashes. No live scan or fabricated hash
inventory is included in this change. Omitting this optional config field omits
the regression control, so DSR regression runs must explicitly supply it.

C9 checks fixed-block runtime on both endpoints, resolving the ERC-1967
implementation slot when nonzero. The implementation runtime must contain the
`inflightOf(bytes32)` selector. Every discovered/supplied operation must return
`(0,0)` on both endpoints using the fixed block hash. Missing selector, unavailable
implementation/storage, disagreement, or a reverting getter leaves C9
`unverified`, never pass. An empty hash inventory still probes the getter using
the zero hash to establish that it is callable. Selector presence is a necessary
check, not proof of implementation semantics; the audited-code assumption remains.

EntryPoint's indexed paymaster filter uses a default 50,000-block chunk and never
exceeds it. Credit/lock scans retain 2,000 unless also indexed-filtered. The state
config accepts `rpcMinInterval` (default 0.25 seconds) and `rpcMaxRetries` (default
5, allowed 0–5). Pacing spans nested scans. `rpcCalls` records method, endpoint A/B,
latency, retry count, status and applicable backoff without URLs. Exhausted HTTP
429/5xx/timeout retries remain failures. See the scanner validation document for
retry and coverage details.

## DSR mapping audit

All named DSR tests exist and their bodies were read. The following limits matter:

* C4 `test_policy_positive` is a positive **detection** control: policy=2 produces
  C4 fail, not a positive conformant state. `test_off_policy_reported` checks a
  policy=0 event is retained and permits C4 pass.
* C4 `test_missing_chunk_log` tests asymmetric omission only; it did not test
  identical endpoint truncation. The new receipt control closes that gap.
* C4 `test_shrink_completes` checks range-error recovery and detects an ON event
  (C4 fail); it is not evidence that credit was never enabled.
* C4 `test_archive_both_required` checks either endpoint's unavailable historical
  code read blocks the scan. It does not establish independent providers.
  `test_start_after_deploy` rejects incomplete deployment history as expected.
* C7 `test_reuse_chronological` uses R→S→R→L, not R→L→R. The latter is covered by
  `test_reuse_left_open`, and the new real-chain control implements R→L→R followed
  by a final release. `test_open_zero_amount`, `test_duplicate_reserve`, and
  `test_orphan_closes` assert the named conditions. `test_user_and_token_key`
  asserts open/anomaly counts, not the verdict directly.
* C2/C3 are archived `a6-gauge-credit` fixtures plus the actual `validate.mjs`, not
  previously named Python tests. The new wrappers provide exact executable test
  names: `test_credit_off`, `test_credit_on`, `test_credit_queued`. OFF is accepted
  as a local instrumentation run; this does not make it protocolConformant or
  prove the current release's chain state.
* The existing shell Anvil control detects policy=2 only. It never exercised
  reservation reuse. The new Python control compiles a harness inheriting the
  actual token, configures fixture storage, then sends zero-amount reserve,
  release, re-reserve, and final release transactions using unlocked Anvil
  accounts. It never uses real keys or claims independent-provider evidence.

## Local execution limitation

Forge 1.7.1 successfully compiled the isolated control against production sources.
The managed sandbox denied binding a localhost socket (errno 1), before Anvil
could start. The default-on test therefore reports an error, not a skip or PASS.
`A4_SKIP_ANVIL=1` is the only supported explicit skip. CI installs Foundry 1.7.1
and runs the test without that flag. Its process cleanup uses terminate/wait,
then kill/wait if needed.

An initial repository-root `forge build --offline` unexpectedly attempted
submodule initialization. Those attempts failed on protected filesystem writes;
no successful fetch or git mutation was reported. The test was changed to copy
local sources into an isolated temporary Forge project, avoiding repository git
metadata and dependency auto-installation. No contracts/src files were edited.

Run summaries and individual guard-removal outcomes are in
`a4-test-results.json`, `a4-anvil-control-result.json`, and
`a4-guard-mutations.json`. Three old single-guard mutants survive because the new
receipt checks independently block their bad input; they are explicitly recorded,
not counted as kills. All new state, schema, cap and receipt guard mutants must
be killed without runtime errors.
