# A6 per-operation evidence index, version 1

`evidence-index.schema.json` (JSON Schema 2020-12, `urn:a6:evidence-index:1`) is the stable structural contract. A breaking change requires a new schemaVersion. Paths are relative to the window directory unless a pin explicitly names an absolute source path. SHA-256 digests are lowercase hex over exact file bytes. Never normalize files before hashing.

## Attempt identity and disposition

`<window>/index.ndjson` contains one JSON object per attempt, appended and fsynced immediately at attempt completion, before the collector continues. Rows are never rewritten. `windowId` plus zero-based `attempt` is unique. `tripleIndex` identifies a candidate, not a successful-sample counter. `arm` is SP/VPM/TPM; `armOrder` is the planned permutation. An interrupted window retains every completed row and raw archive; without a valid trailer it is non-compliant.

Rows keep the schemaVersion 1 field set. `included` is always false in the immutable row and is NOT a final verdict. The validator derives final inclusion exclusively from `trailer.json`. `passports.end` is null with a missing explanation. Final inclusion and matching live exclusively in `<window>/trailer.json`, created once with exclusive creation and fsync at run end. Missing, truncated or void trailers are refused. A successful attempt row has `exclusionReason: null`, even if its candidate is later abandoned. `not_included` means only that the operation was not included in a block; it is refused on a mined operation.

`replaces` is null or `{windowId, tripleIndex}`: every attempt of a replacement candidate points to the abandoned candidate. `replacedBy` remains a required schema field but is ALWAYS null. It is derived by the validator from trailer edges, never written back. The trailer has `replacements: [{abandoned, replacement, reason}]`, where both endpoints use this candidate link shape. Edges and rows' replaces must be exact inverses, one-to-one and acyclic. Replacements start only after the abandoned candidate ends. Every abandoned attempt is retained with included=false in both the row and final disposition.

The closed exclusion enum is `AA32`, `price_stale`, `not_included`, `op_failed_nongas`, `bundler_error`, `basefee_above_cap`. Null is required for successful attempt rows; failed attempts carry an enum reason. Reasons describe expiry, price freshness, absence of inclusion, explicitly identified non-gas execution failure, bundler failure, or the fixed basefee cap. Gas measurements and effect sizes never authorize abandonment. The collector recognizes decoded AA32, explicit decoded price-stale preflight reasons, arithmetic overflow/division-by-zero panic payloads (non-gas), submission exceptions (bundler_error, still fail-closed because delivery is uncertain), and basefee pauses. When a candidate containing successful operations is abandoned, those rows keep null reasons. The abandonment reason lives only in the trailer’s replacements edge and must be a member of the closed enum. A null-reason successful row in an abandoned candidate is valid only with such an edge. Other unclassified failures stop with UNAPPROVED_ABANDONMENT instead of being relabeled as eligible replacement reasons. Stop reasons are separate diagnostics, not exclusion-enum extensions.

The trailer has `schemaVersion: "a6-evidence-trailer/1"`, `windowId`, `void`, `stopReason`, `stopAttempt` (last recorded attempt, or null), `endPassport` (path/raw reference), `triples: [{tripleIndex, attempts, included}]`, `replacements`, and `counts`. It covers every candidate and attempt exactly once. A compliant window has exactly 50 included triples, each with one successful complete SP/VPM/TPM attempt: 150 included attempts. `counts` contains SP/VPM/TPM objects with `attempts`, `included`, `excluded` (reason-to-count map), and `notSent`. Not-sent attempts also count as excluded. Counts use final trailer inclusion, not row inclusion. For excluded successful rows with null reasons, the excluded count uses the candidate’s replacement-edge reason without modifying the row.

RPC A/B disagreement, reorg, conservation failure, Passport drift and other fail-closed events stop execution. The trailer records the stop reason and void=true; no replacement may continue. The validator rejects void windows, attempts after a stop, unapproved reasons, and index/trailer dispositions inconsistent with the independently checked run journal. Invoke `validate.mjs <window/run.jsonl>`; formal runs require the sibling index and trailer in addition to the existing chain/conservation checks.

All keys are required. Unknown/unavailable evidence is null (or an empty reference array), with a JSON-pointer key in `missing` and a concrete explanation. Non-applicable arm state uses `not applicable to <arm>`. Missing required evidence disqualifies inclusion even if the operation succeeded. Null is never zero, a successful read, or proof of absence.

## Chain, operation and transaction

`chainId`, `nonce`, gas, fees, block numbers and decoded integer values are unsigned decimal strings. Addresses are 20-byte hex; hashes are 32-byte hex; byte strings have a 0x prefix. `entryPoint`, `sender`, `paymaster` and `bundler` identify the actual addresses, with bundler meaning the transaction-sending EOA. `packedOp` contains all nine EntryPoint v0.7 packed fields including signature. `bundle` is the complete ordered handleOps operation array; `callDataHash` is keccak256 of packedOp.callData. `gas` contains the seven unpacked gas-limit and fee fields actually used, including both paymaster limits.

`tx` is null before submission. Otherwise it contains txHash, blockNumber/hash, the complete RPC transaction object in `raw`, exact transaction calldata in `input`, zero-based `handleOpsIndex`, and outer transaction gasLimit/maxFeePerGas/maxPriorityFeePerGas. `raw` is the JSON-RPC transaction object, not a reserialized signed envelope. The original eth_getTransactionByHash response bytes are referenced separately. The full bundle and index must agree with decoding input; lack of membership is null with a missing reason, never index zero by default.

`expectedUserOpHash` is the hash expected before submission. `observedUserOpHash` comes from the observed UOE, not local recomputation. `uoe` holds the observed txHash/logIndex, emitting address, complete topics and data. Log indices are integers in the entire transaction receipt, not positions in a filtered event list. Receipt references include every log, including EntryPoint revert/prefund events, SP sponsorship, lock/settlement and credit events. `endpoints.A/B` each list raw references for receipt, logs, transaction and every state read. `logs` references the complete unfiltered receipt logs array in the referenced receipt response; it is not a filtered eth_getLogs query.

## Fixed-block state and Passports

Both `state.before` and `state.after` contain exactly these field names: entryPointDeposit, operatorBalance, protocolRevenue, inflightOf, userXPNTs, totalSupply, lockedOf, debts, creditReservedOf, operatorTotalSpent, operatorTotalTxSponsored, tpmTokenBalances, tpmCachedPriceTimestamp, vpmDeposit. Each applicable field is `{value, anchor:{number,hash}, raw:{A:[{path,id}],B:[{path,id}]}}`. BEFORE is inclusion block minus one; AFTER is inclusion block. A/B must agree on anchor and value. Raw references contain the fixed-block calls needed to derive the field; a shared operators tuple response supports multiple fields. Consumers use method/params in those records to reproduce reads, not guessed ABIs.

entryPointDeposit is EntryPoint.balanceOf(current arm paymaster); operatorBalance is SP.operators(operator)[0] on every arm. SP fields are protocolRevenue(), inflightOf(expectedUserOpHash) as {operator,a0}, token balanceOf(sender), totalSupply(), lockedOf(sender), debts(sender), creditReservedOf(sender), and operators()[7]/[8]. TPM equivalents are token balances `{sender,paymaster}` and cachedPriceTimestamp(). VPM deposit is EntryPoint.balanceOf(VPM). Other arm-specific fields are null and explicitly non-applicable. Additional lockOf reads remain available in stateReads; they do not change this fixed field list.

`passports.start/attempt` and the trailer’s `endPassport` reference JSON files plus all A/B raw records supporting them. Passports retain code addresses, runtime sizes/codehashes, proxy/implementation bindings, configuration getters, prices and gas configuration. Unavailable Passports are null with a reason. `pins` has six categories: collector, validator, dependencies, contractSources, abi, config. Every entry is `{path,sha256}`. Pin every used source/ABI/config and dependency lock/source inventory; an empty category cannot support a complete formal package. `rpcIdentity` pins the credential-free registered A/B identity document.

## Exact raw archive convention

Files are `<window>/raw/A/YYYYMMDD.ndjson` and `<window>/raw/B/YYYYMMDD.ndjson`, with date taken from request-start UTC. Each record contains `{id, ts, method, params, blockAnchor, request, response}`. `id` is an integer starting at 1, strictly increasing in physical append order per endpoint across date files; it never resets at midnight. `ts` is request-start ISO-8601 UTC with milliseconds. `method` and `params` are the exact JSON-RPC method and parsed parameter array. `blockAnchor` is null when unknown, otherwise `{number,hash}`, number an unsigned decimal string. It describes the block observed for this response, not a latest-state assumption. Fixed state calls are bracketed with block-hash checks. Reorgs stop the window.

`request` and `response` are standard padded base64 strings encoding exact HTTP body bytes. HTTP headers and credential-bearing URLs are deliberately excluded. response is null only when no complete response body was received; transportError then explains that absence. HTTP status, endpoint, blockRange and transport diagnostics may be additional record metadata. Invalid JSON and RPC errors are archived before rejection. The JSON-RPC wire id need not equal the archive id. Requests are not reconstructed from method/params. Reference `{path,id}` resolves exactly one record; IDs alone are insufficient across endpoints. A new run cannot reuse an existing window archive. Append/fsync happens before decoded results are returned.

## Identity, freezing and DSR handoff

Formal mode requires `--rpc-registry <file>` and `--pins <file>`. Registry version is `a6-rpc-identity/1`; A/B entries each have operatorName, backendIdentity, upstream, endpointLabel, registeredAt and evidence (path/SHA-256 references). Labels contain no URL or credentials. Different labels alone do not establish independence; operator, backend and upstream must differ and supporting evidence must be inspected by DSR. Pins input has the six categories above; hashes are verified before use.

Run `node script/a6-collector/freeze.mjs <window> --sampling <DSR-file>`. The supplied sampling seed/list/command artifact is copied byte-for-byte into the window and hashed; its contents and pre-submission timing remain DSR's responsibility. The command writes manifest.json and manifest.sha256 exclusively, refuses a second freeze, includes every regular file (including hidden files), and rejects symlinks. The manifest excludes itself and its digest sidecar. Freeze is an integrity snapshot, not filesystem immutability or chain authenticity.

## Summary

One immediately durable append-only index row identifies each attempt; the one-shot trailer supplies final disposition, matching, counts and end Passport. Each row records full operation/bundle, transaction membership and observed UOE. Both RPC endpoints have exact-byte raw archives with integer IDs and fixed-block state references. Start/attempt/end Passports, six pin categories and the RPC identity registry complete the reference graph. Missing evidence is explicit; failed and unsent attempts remain visible. The one-shot SHA-256 manifest includes DSR's supplied sampling artifact. DSR must independently re-fetch chain evidence; this format and offline acceptance do not establish formal A6 compliance.

### Formal repair gates

`tpm_postop_refresh` is a closed abandonment reason. Successful attempt rows keep
`exclusionReason: null`; the replacement edge carries this reason and the trailer
counts all three abandoned arms. TPM attempts require A/B callTracer (with logs)
and prestateTracer diff evidence. Calls to the pinned TPM oracle or `latestRoundData` within postOp,
TokenPriceUpdated logs, or TPM storage changes exclude the triple. Storage-change
classification is conservative: it can reject changes unrelated to price. An
unavailable trace stops the formal window; no trace-less TPM sample is accepted.

The offline gate opens raw references, requires unique endpoint-local IDs, checks
request bytes against method/params, binds state calls and return values to their
contract and fixed block, hashes pins and the registry, and compares the index
with the journal. Included evidence cannot be excused by `missing`. Finalization
records A/B re-reads of every historical anchor in `finalBlockCheck`.

RPC hostnames are resolved before collection; non-public addresses and overlapping
address sets are refused. Production connections use those vetted addresses while
retaining the URL hostname for TLS. Different IPs do **not** prove independent
providers: DSR must manually verify operators, backends and upstreams in the registry.

Archive request/response bytes are scanned against URL userinfo, nonempty path
segments, query values (including decoded forms), and the frozen configuration's
`secretPatterns` regular expressions. A match sets `credentialFlag`, stops further
RPC requests, and prevents freezing. Exact bytes remain on disk for investigation;
do not distribute a flagged window. Errors never print the matched substring.
Freeze also rejects symlinked ancestors of the window or sampling file before
creating its lock.
