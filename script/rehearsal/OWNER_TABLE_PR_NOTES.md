# PR notes (draft): rc.8 owner table v1 + two-endpoint hardening

## What this adds
- `docs/security/rc8-owner-table.json` is the source of truth. `docs/security/rc8-owner-table.md` is generated from it by `scripts/gen-rc8-owner-table.mjs`; `--check` fails if the doc is stale or the data is invalid. The doc embeds the sha256 of the canonical JSON.
- Every authority row is in exactly one class:
  1. handed over to TL48 or the community Safe (or no holder);
  2. operator-owned by design;
  3. legacy, backed by mechanical probes. A class-3 row shows PENDING while anything still references its subject or any probe read did not answer.
- `script/rehearsal/owner-table-read.mjs` fills the `current` column from Sepolia. It is read-only and runs on both endpoints at the inventory's pinned block.
- `script/rehearsal/lib/two-endpoint.mjs` is the one shared implementation of:
  - redaction;
  - endpoint independence;
  - finalized pin selection and verification;
  - full-payload log comparison;
  - reads on both endpoints with an `ok` discriminant;
  - atomic write.

  `script/rehearsal/lib/inventory-accept.mjs` is the consumer's acceptance gate (versioned, exact control set).

## inventory.mjs changes (correcting #639)
- Uses the shared module. Its own redactor, host check and log fingerprint are removed.
- Rejects identical endpoints by normalized hostname (and two endpoints of the same named provider).
- Verifies `eth_chainId == 11155111` on both endpoints.
- Labels endpoints by a provider name from a fixed host map. It no longer writes the second endpoint's host into the output.
- Log agreement covers the full payload: address, topics, data, blockHash, logIndex, transactionHash, transactionIndex, removed. It rejects `removed: true` and duplicate log identities. It fails before deriving anything from logs that differ.
- The state reads previously made on endpoint 0 only are now made on both endpoints and must be equal:
  - SP `version`, `APNTS_TOKEN`, `pendingAPNTsToken`, `pendingAPNTsEta`, `operators(addr)` and `pendingDebts`;
  - Registry `roleMembers` storage and `getRoleUserCount`;
  - the pinned block hash re-check.
- Output gains `schema: "sp-inventory/2"` and `chainId`.
- The control names must equal `REQUIRED_CONTROLS["sp-inventory/2"]`.
- The file is written only after every control is true, atomically: a temp file in the same directory, then a rename. The temp file is removed on failure.

## Old vs new inventory
The old run is `inventory-12158083.json` (3b9d83fb, old code); the new one is `inventory-12158399.json` (a90fb624, new code).
- The configured `operators` list (with balances, token and treasury) is identical, and so are `superHolders.fromStorage`, `everRegistered` and `outsideList`.
- All 26 topic0 rows are identical except one: the count of `PriceUpdated(int256,uint256)` grew from 429 to 430 because the pinned block moved.
- The round-3 run `inventory-12158619.json` gives the same result against the first run, with that count now 431.

## Known limitations
- Trust root: the two endpoints are operator-configured and assumed to be two different honest providers. The work does not defend against an operator who crafts malicious inputs.
- The legacy probe covers the zero-argument address getters of the rc.8 ABIs and a fixed list of role mappings on deployed rc.8 contracts. It cannot see an address held in a mapping or struct it does not query.
  - Known instance: `operators(ANNI).xPNTsToken` still names the v1 pNTs token; it is disclosed in the table.
  - Undeployed rc.8 contracts (A7, AOAProtocolRegistry, xPNTsFactoryV2, the new implementations) are covered only by the source scan, and are read back at step 13.
- `notInCode` ("cannot return the subject") is returned for exactly one shape, established on both endpoints:
  - a plain runtime (no EIP-1167 prefix, and no DELEGATECALL opcode unless the EIP-1967 implementation slot is set);
  - an optional EIP-1967 implementation and an optional `EXTENSION()`, all readable;
  - a zero beacon slot;
  - a selector whose first two bytes are not both zero;
  - the selector found as neither PUSH4 nor (first byte 0) PUSH3 in any of those runtimes.

  Every other shape returns `reverted` and keeps the rows PENDING: an EIP-1167 clone, a delegating runtime without an EIP-1967 slot, a beacon, an unreadable slot or code, a selector starting `0000`, or a read that did not revert on both endpoints. Remaining limit: a selector that the compiler encodes in some other form (for example split across instructions) would be reported absent.
- The DVTValidator 0.6.0 bytecode match is against a local build of 41784173 with that commit's default profile. The build uses `bytecode_hash none`, so the CBOR tail carries no metadata hash (only the solc version). The tail is compared byte for byte.
- Many required steps are missing from `script/upgrade/manifest_exec.py` on main. They are listed as GAP or PENDING in the table's open items:
  - treasury, role-owner, staking, GToken, MySBT and ReputationSystem handovers;
  - revocation of the deployer's reputation source;
  - slasher revocation of 4.11.0 and 4.1.0;
  - the old PaymasterFactory disable step;
  - A7.dvt.
- The manifest still pins stale versions (`BLSAggregator-4.12.0`, `Registry-5.9.0`) and the old DVTValidator (`fixed_dvt`, :637).

## Round 4 (after the last review)
- **The round-4 changes were made after the last DSR-arranged review (Codex APPROVED at 491eff87) and were not re-reviewed by it.**
- `notInCode` is now proxy-aware (`classifyRead` in `lib/two-endpoint.mjs`). The selector must be absent from:
  - the address's own runtime;
  - its EIP-1967 implementation's runtime (the implementation slot is read on both endpoints at the pin, and both must agree);
  - its `EXTENSION()` when it has one.

  A beacon, or any slot/code read that fails or disagrees, keeps the read `reverted`, so the row stays PENDING. The real re-read at the round-4 pin changed no row's class: `SP.EXTENSION()`, `SP.guardian()`, `SP.pendingOwner()` and `REGISTRY.pendingOwner()` are still `notInCode`, now established against the implementations. `script/evidence/owner-table-impl-selector-check.mjs` is a positive control: `owner()`, `xpntsFactory()` and `blsAggregator()` are found in the implementation code and not in the proxy code.
- Redaction registers both the raw percent-encoded and the decoded form of every query value.
- The registrable-domain rejection is removed. Under the trust root only equal normalized hostnames are rejected.
- Main-session addition after round 4 (also not re-reviewed): an `EXTENSION()` read that fails in transport (not a revert) now leaves the extra code holders unknown, so the row stays `reverted` (PENDING) instead of being searched without the extension. The real read had `gettersFailed = 0`, so the committed table is unchanged by this.

## Round 5 (clestons)
- **B1:** `docs/security/rc8-owner-table.json` and `.md` name the old timelock on purpose: it is a class-3 holder. They are added to `script/upgrade/legacy_timelock_allowlist.json` with one-line reasons, so `test_no_legacy_timelock.py` passes. No string was split. The whole offline `a3a-executor` suite was run locally (results in the PR body).
- **Status column:** it now shows measured state. A class-1 row reads `handed over` only when Current equals Expected at the pin (13 rows). Otherwise it reads `planned: <step> (not executed at the pin)` and is listed in Open items: 6 rows still held by D, and 4 whose contract is not deployed. A row with no step still reads `GAP`. Open items went from 23 to 33. The header states that a class-1 Expected is the value after rc.8.
- **`validate()`:** rejects a class-1 Expected entry that is neither an identity key nor a 40-hex address (`TL84`, `0xZZ`).
- **`classifyRead`:**
  - fails closed for EIP-1167 clones, for DELEGATECALL without an EIP-1967 slot, and for selectors starting `0000`;
  - its reads no longer sit in one outer try, so each fail-closed branch has a test that goes red when the branch is removed: beacon, unreadable implementation code, `extra === null`, and both-endpoints-revert.
- **Redactor:** every decode has its own try; a malformed `%` escape no longer drops later values.
- **`isRevert`:** decides from the error's structured `name` / `code` / `data` along the `cause` chain (viem `ContractFunctionRevertedError` / `ExecutionRevertedError`, or JSON-RPC code 3 with data). Any transport error in the chain means not a revert, whatever the text says. The real Sepolia reverts used by the probes come back as `ContractFunctionRevertedError > ... > RpcRequestError(code 3)[data]` on both providers.
- **`owner-table-read.mjs`:** writes the tracked JSON with `writeAtomic`.
- **Wording:** a verified class-3 row reads `legacy (no rc.8 reference found at the pin)`. The policy rows cite the `core/LivenessRegistry.sol:13` doc-comment mention.
- The real two-endpoint reads were re-run because classification and `isRevert` changed. No row's class or current value changed.
- DSR ruling 2026-11-18, which takes precedence over the earlier legacy classification: `pmFactory.owner` and `pmv4Impl.owner` are now class 1. Their Expected is TL48, set by the not-yet-existing (i)-series step "old PaymasterFactory disable + transferOwnership(TL48)". They render `GAP (step missing)`, because the generator shows `planned` only for an existing manifest step. Open items stay at 33; class counts are 40 / 4 / 19.
- **These round-5 changes have not been reviewed by clestons yet.**
