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
- Rejects identical endpoints by normalized hostname, and the same provider or the same registrable domain.
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
- Registrable-domain comparison uses the last two labels. There is no public-suffix list.
- The legacy probe covers the zero-argument address getters of the rc.8 ABIs and a fixed list of role mappings on deployed rc.8 contracts. It cannot see an address held in a mapping or struct it does not query.
  - Known instance: `operators(ANNI).xPNTsToken` still names the v1 pNTs token; it is disclosed in the table.
  - Undeployed rc.8 contracts (A7, AOAProtocolRegistry, xPNTsFactoryV2, the new implementations) are covered only by the source scan, and are read back at step 13.
- A getter whose selector is not in the deployed runtime counts as "cannot return the subject". Selector detection looks for PUSH4, or PUSH3 when the first byte is zero. Any other form would show as "reverted" and keep the rows PENDING.
- The DVTValidator 0.6.0 bytecode match is against a local build of 41784173 with that commit's default profile. The build uses `bytecode_hash none`, so the CBOR tail carries no metadata hash (only the solc version). The tail is compared byte for byte.
- Many required steps are missing from `script/upgrade/manifest_exec.py` on main. They are listed as GAP or PENDING in the table's open items:
  - treasury, role-owner, staking, GToken, MySBT and ReputationSystem handovers;
  - revocation of the deployer's reputation source;
  - slasher revocation of 4.11.0 and 4.1.0;
  - the old PaymasterFactory disable step;
  - A7.dvt.
- The manifest still pins stale versions (`BLSAggregator-4.12.0`, `Registry-5.9.0`) and the old DVTValidator (`fixed_dvt`, :637).
