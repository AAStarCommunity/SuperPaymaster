# A2 / spec §6 row 0 — complete-range `DebtRecordFailed` scan, `pendingDebts` reconciliation, operator full set

Responds to DSR CC-124 comment a6097e85 item (1) (`03-final-spec.md` §6 row 0, L370). Row 7b (legacy debt
inside the old tokens) is in the sibling directory `../legacy-debt-7b/` and was produced by the same run.

**Run**: `python3 scripts/a2-row0-7b-debt-scan.py` (defaults: `--block 11881000`, output = this directory and
`../legacy-debt-7b/`), script committed at **`c25a3fb16565d17b38c5f7f0ef6d8bc1d2b8c3a7`**, clean
(`scan.log` L2: `script differs from HEAD: no`, script sha256 `82b56065…fe04b`). Exit code 0,
`CHECK totals: OK=282 FAIL=0`, `RESULT OK` (last two lines of `scan.log`).

**Revision 2 (Codex challenge on #460, head `6f4ab439`).** Two Medium findings fixed in `c25a3fb1`:
(1) getter answers were decoded leniently (`"0x"` / `""` → 0), so an endpoint answering `"0x"` to every debt read
passed; now every `pendingDebts` / `getDebt` / `getRoleUserCount` / `hasRole` / state-override / role-array-length
read must be **exactly one 32-byte ABI word on each endpoint** (`word()`), anything else is a FAIL, and the
`DebtRecordFailed` / `DebtRecorded` / `DebtRepaid` data lengths are checked; (2) the token-debt replay sorted
by `(block, txHash, logIndex)`, which mis-orders same-block events — it now uses execution order
`(blockNumber, logIndex)` (logIndex is block-global). The scan was re-run at the **same** fixed block 11,881,000
with `c25a3fb1`: all 238 data files (`raw/`, `inventory.json`, `../legacy-debt-7b/raw/`, `legacy-debt.json`) are
**byte-identical** to revision 1 (`6f4ab439`); only `scan.log` changed (+4 CHECK lines: the data-length checks of
the four aPNTs debt events; every strict-word read replaced an existing "identical on A and B" line one for one).
New negative controls NC4/NC5 and the offline self-test are below. Revision 1 was produced by `eb073e5a`.

READ-ONLY: the script issues only `eth_chainId`, `eth_blockNumber`, `eth_getBlockByNumber`, `eth_getCode`,
`eth_getStorageAt`, `eth_call` (two of them with a state override — a local simulation, nothing is written)
and `eth_getLogs`. Nothing was signed or sent.

## Fixed block and endpoints

| | value |
|---|---|
| fixed block | **11,881,000**, hash `0xf785a1efed005453e054f35adf4877eac985fafdd500407595fb4ff6640595af` (identical on A and B), ≥ 64 blocks below both heads at run time |
| endpoint A | Alchemy `eth-sepolia.g.alchemy.com`, archive (the app behind `SEPOLIA_RPC` in `~/Dev/.env`; the `.env.sepolia` `SEPOLIA_RPC_URL` app is archive for state but is a free-tier app limited to 10-block `eth_getLogs` ranges, so it could not do the scan) |
| endpoint B | Tenderly `sepolia.gateway.tenderly.co`, archive, independently operated |
| URLs / keys | not in any file (the script scans every written file for the URL path/key segments and exits 1 on a hit) |

Every read and every log query below was issued to **both** endpoints and compared field by field
(`(block, tx, logIndex)` plus address, topics, data and blockHash for logs); any difference is a FAIL.
Raw responses: `raw/A/*.json`, `raw/B/*.json` (`request` + verbatim `response`; for `eth_getLogs` the
per-chunk responses are kept). Structured result: `inventory.json`.

**Archive depth (state)**: the SP proxy's creation block was located by an independent `eth_getCode`
binary search on each endpoint; both give **11,151,016**, with code empty at 11,151,015 and present at
11,151,016 on both (`raw/*/sp-creation.json`). Same for the Registry proxy (11,151,002) and every token /
factory below. A pruned node cannot answer these reads (see negative control NC1).

## Topic and selector verification

`DebtRecordFailed(address,address,uint256)` → topic0 **`0x8d05946ad7acf1695cdb2c1c7b76b11a907b33e5224f086eea17d6a23841e17f`**.

1. **Source**: the exact declaration `event DebtRecordFailed(address indexed token, address indexed user, uint256 amount);`
   exists in `v5.4.2` (`78364b12…`, `SuperPaymaster.sol`, the live 5.4.2 source) and in `v5.5.0-rc.2`
   (`1ac0e1c5…`, `SuperPaymasterStorage.sol`); `git log -S` shows the signature unchanged since it was
   introduced (2026-03-20). The keccak is computed by the script's own keccak-256, self-tested against two
   fixed vectors at start-up.
2. **Deployed bytecode**: the proxy had three implementations (`Upgraded` history): 5.4.0
   `0x168a…c700` @11,151,016, 5.4.1 `0x0274…0250` @11,151,219, 5.4.2 `0xe25f…2c27` @11,228,202 (= ERC-1967
   slot at the fixed block, `version()` = `SuperPaymaster-5.4.2`). **All three** contain `PUSH32` of the
   DebtRecordFailed, PendingDebtRetried, PendingDebtCleared, OperatorConfigured and TransactionSponsored
   topics and `PUSH4` of `pendingDebts(address,address)`; as a discrimination check none of them contains the
   token-only `DebtRecorded` topic (which the token impls do contain, and vice versa).
3. **Getter**: `pendingDebts(address,address)` (selector `0x7b707185`, computed from the source signature) — an unknown selector
   (`0xdeadbeef`) reverts on the SP proxy (NC), so a 32-byte answer means the selector dispatched; and a
   state-override positive control plants a distinct value at the slot computed for every candidate declaration
   slot 0..299 and the getter returns the one planted at **slot 17** on both endpoints (`scan.log` L154), i.e. the getter
   provably reads `pendingDebts[token][user]` storage. (Same technique for the token `getDebt`, slot 22.)

## Scan over [11,151,016 (SP creation), 11,881,000]

| query (address = SP proxy, same range) | A | B | role |
|---|---|---|---|
| `topics=[DebtRecordFailed]` | **0** | **0** | the row-0 scan (`scan.log` L87) |
| `topics=[PendingDebtRetried]` | 0 | 0 | reconciliation input |
| `topics=[PendingDebtCleared]` | 0 | 0 | reconciliation input |
| `topics=[Upgraded]` | 3 | 3 | **PC1**: first log is in block 11,151,016 = the range START → the endpoints serve logs from the very beginning of the range, not only recent blocks |
| `topics=[TransactionSponsored]` | 9 | 9 | **PC2**: same-shaped query on an event that was emitted (blocks 11,155,147 … 11,612,063) |
| no topic filter (all SP logs) | 73 | 73 | every topic0 decodes to an event declared in the tagged sources (25 distinct events, `scan.log` L45); each filtered count above equals the count of that topic inside this dump |

Identical `(block, tx, logIndex)` sets on A and B for every row (trivially for the empty ones; for the 0-rows the
evidence that the zero is real is: verified topic, PC1/PC2 of the same shape on the same contract and range,
two independent archive endpoints, and the unfiltered dump containing no such topic).

## pendingDebts reconciliation (fixed block)

`DebtRecordFailed − PendingDebtRetried − PendingDebtCleared` per `(token, user)` gives **no pair at all**. As a
second enumeration source the script read `SP.pendingDebts(token, user)` for the full cross product of the
5 in-scope tokens (see `../legacy-debt-7b`) × every user appearing in `TransactionSponsored` or in any token's
`DebtRecorded`/`DebtRepaid` (2 users: `0xecd9…dd70`, `0xf7bf…642c`) = 10 pairs, on both endpoints: **all 0**,
equal to the event-derived value. **Result: no non-zero `pendingDebts` entry; runbook step 2 has nothing to
retry/clear.**

Completeness argument: in the 5.4.2 source, the only write that increases `pendingDebts` is
`_recordDebt` (`SuperPaymaster.sol` L1473), immediately followed by `emit DebtRecordFailed` (L1474); the only
decreases emit `PendingDebtRetried` / `PendingDebtCleared`. All three deployed implementations carry those
topics in their bytecode. Hence a non-zero entry implies a `DebtRecordFailed` log on the proxy in
[creation, fixed], and there is none.
**Limits**: (a) the 5.4.0 / 5.4.1 bytecode was checked for the topics, not recompiled against source — the
"every increase emits" property for those two is inferred from source history, not proven on their bytecode;
(b) the result is as of block 11,881,000 — row 0 must be re-run at T (`--block <T-block>`), the script is
reproducible: the NC3 control run (endpoint B through a pass-through proxy, same script commit) produced all 238
`raw/`, `inventory.json` and `legacy-debt.json` files byte-identical to this archive once the B host string is
normalised (`negative-controls/nc3-…`).

## Operator full set (fixed block)

Basis = union of three sources, each queried on both endpoints:
1. SP proxy logs whose topic1 is the operator (14 event kinds from the 5.4.2 source: OperatorConfigured,
   OperatorDeposited/Withdrawn, TransactionSponsored, OperatorSlashed, ReputationUpdated, OperatorPaused/
   Unpaused, OperatorMinTxIntervalUpdated, UserBlockedStatusUpdated, SlashQueued/Cancelled,
   SlashExecutedWithProof, ProtocolRevenueUnderflow), over [SP creation, fixed];
2. Registry `RoleRegistered` / `RoleGranted` / `RoleExited` / `RoleRevoked` with `roleId = keccak256("PAYMASTER_SUPER")`
   over [Registry creation 11,151,002, fixed] (5 / 5 / 0 / 0) — **PC3** (non-zero, same shape);
3. state: `Registry.roleMembers[PAYMASTER_SUPER]` read from raw storage (slot 9) at the fixed block — **PC4**:
   the array length read from storage (5) equals `getRoleUserCount(PAYMASTER_SUPER)` (5), and every element has
   `hasRole == true`.

| operator | basis | `operators(op)` at 11,881,000 (both endpoints) |
|---|---|---|
| `0xb5600060e6de5E11D3636731964218E53caadf0E` (AAStar / deployer) | SP events + Registry | **isConfigured**, not paused, xPNTsToken = aPNTs `0x696A…aB89`, aPNTsBalance 1,690.0087… e18, 6 tx |
| `0xEcAACb915f7D92e9916f449F7ad42BD0408733c9` (ANNI / Mycelium) | SP events + Registry | **isConfigured**, not paused, xPNTsToken = PNTs `0xE657…A224`, aPNTsBalance 844.5407… e18, 3 tx |
| `0xf92dc383c74ea30d7791b929d5872dad18679516` | Registry only | not configured, token 0, balance 0 (holds PAYMASTER_SUPER) |
| `0x2e72a258fd9e1c69b2b2bb6ed8bc7e94773f7b00` | Registry only | not configured, token 0, balance 0 (holds PAYMASTER_SUPER) |
| `0x368f8cb8cca42174b03156cea761bae31cee5c94` | Registry only | not configured, token 0, balance 0 (holds PAYMASTER_SUPER) |
| `0xf7bf79acb7f3702b9dbd397d8140ac9de6ce642c` | SP slash/reputation events only | not configured, token 0, balance 0, no PAYMASTER_SUPER |

So the operators that can sponsor (and that runbook step 3 must pause) are exactly the two configured ones;
the other four have empty `operators[]` state apart from slash/reputation bookkeeping.
Completeness argument: `isConfigured = true` is set only in `configureOperator`, which emits
`OperatorConfigured` (5.4.2 L300; topic present in all three impl bytecodes); the script checks
`{isConfigured at fixed} ⊆ {OperatorConfigured emitters}`. A non-zero `aPNTsBalance` needs a deposit
(`OperatorDeposited`) or a refund in postOp of an already-configured operator. Limit: an address with
`operators[]` state written only by a path that emits no operator-indexed event would be missed by source 1;
in 5.4.2 no such path sets `isConfigured` or credits a balance for a non-configured operator, which is the
property step 3 relies on. The two known operators' readings alone are **not** offered as completeness
evidence; completeness rests on the three enumerations above.

## Negative controls of the script itself (`negative-controls/`)

| run | endpoint B | expected | result |
|---|---|---|---|
| NC1 | `ethereum-sepolia-rpc.publicnode.com` (prunes history) | fail-closed | exit 1: `pruned history unavailable` on the first old-state read |
| NC2 | Tenderly behind `scripts/d5b-rpc-tamper-proxy.mjs … drop` (drops the last log of every non-empty `eth_getLogs` answer — a *silent* partial answer) | fail-closed | exit 1, 22 `CHECK FAIL` (e.g. `sp-all-logs A=73 B=69`, `sp-logs-Upgraded A=3 B=2`) |
| NC3 | Tenderly behind `scripts/a2-debt-scan-tamper-proxy.py … pass` (control for NC2/NC4/NC5) | OK | exit 0, `OK=282 FAIL=0`, all 238 data files identical to the archived run |
| NC4 | Tenderly behind `scripts/a2-debt-scan-tamper-proxy.py … empty-once:0x9a78e72e` — answers `"0x"` to the first plain `getDebt` call (aPNTs, user `0xf7bf…642c`; real answer was a zero word) | fail-closed | exit 1: `CHECK FAIL token-0x696a7370-getDebt-0xf7bf79ac: B answer is exactly one 32-byte ABI word (… '0x')` |
| NC5 | same proxy, `empty-once:0x7b707185` — answers `"0x"` to the first plain `pendingDebts` call (`(0x4680…, 0xecd9…)`; real answer a zero word) | fail-closed | exit 1: `CHECK FAIL sp-pendingDebts-0x4680bf1a-0xecd9c07f: B answer is exactly one 32-byte ABI word (… '0x')` |
| self-test | offline, `python3 scripts/a2-row0-7b-debt-scan-selftest.py` (`selftest-offline.log`) | 19 PASS | exit 0. T1: `word()` rejects `0x`, `''`, 31/33 bytes, two words, non-hex, no prefix, revert object, None. T2: same-block `DebtRecorded` (logIndex 5, tx `0xff…`) → `DebtRepaid` (logIndex 9, tx `0x00…`) fed in reverse order reconciles (remaining 0 == replayed 0); discrimination: the old `(block, txHash, logIndex)` key puts the repay first and the check is red. T3: malformed event data rejected. |

NC4/NC5 are exactly the Codex probe ("replace a getter answer with `0x`") applied end-to-end on the real run:
revision 1 would have read that `"0x"` as 0 and passed.

## Files

`scan.log` (full CHECK log), `inventory.json`, `raw/{A,B}/` (verbatim responses), `negative-controls/`,
`EVIDENCE.sha256` (verify: `cd` here and `shasum -a 256 -c EVIDENCE.sha256`).
