# Legacy token debt record — spec §6 row 7b (Sepolia)

Responds to DSR CC-124 comment a6097e85 item (2) (`03-final-spec.md` §6 row 7b, L380: "对账 / 放弃记录（文件路径 + sha256）").
Line numbers: row 7b is L380 in the spec as it stands on the #459 branch (`d5c-2/a2-full-rehearsal`), which is the
numbering DSR uses; on `feat/aoa-balance-mode-5.5.0` (`9d2fe5a4`, spec v4.1.1) the same row is L382. The text of the
row is identical in both.

> **Timing disclaimer.** This record was produced on 2026-10-10 against Sepolia block 11,881,000, **after** the
> A2 fork rehearsal of PR #459 (fork block 11,877,936, script `0c21a8fe`). It does **not** claim to have existed
> before, or to have gated, that run's 7c step. For the real upgrade window (A3b) this record must be
> regenerated at the T block (`python3 scripts/a2-row0-7b-debt-scan.py --block <T-block>`) and filed before 7c.
>
> `SP.pendingDebts == 0` is **not** used as a substitute for the token ledgers: the old xPNTs tokens keep their
> own `debts[user]` ledger, which is reconciled separately below (the SP side is in `../debt-scan-row0/`).

## Method

Produced by the same run as `../debt-scan-row0/` (script `scripts/a2-row0-7b-debt-scan.py` at
`c25a3fb1`, exit 0, `OK=282 FAIL=0`; full log `../debt-scan-row0/scan.log`; revision 2 after the Codex challenge
on #460 — see `../debt-scan-row0/README.md` "Revision 2": the data files of this directory are byte-identical to
revision 1 (`eb073e5a`)). Two independently operated
archive endpoints — A = Alchemy `eth-sepolia.g.alchemy.com`, B = Tenderly `sepolia.gateway.tenderly.co` — every
read and every log set compared; raw responses in `raw/{A,B}/`, structured result in `legacy-debt.json`.

**Debt ledger in the old tokens** (source: XPNTs-3.4.0 = `d04b83cf` `xPNTsToken.sol`, XPNTs-3.5.0 = `v5.4.2`
`xPNTsToken.sol`; identical debt surface in both): `mapping(address => uint256) public debts` (aPNTs units, 18
decimals), read via `getDebt(address)` (selector `0x9a78e72e`). Every increase (`recordDebt`,
`recordDebtWithOpHash`) emits `DebtRecorded(address indexed user, uint256 amount)`
(topic0 `0x99cf5cc1e3146bd15204f8eae4fe16c690d6123fbdac32515502fe688b86b8f5`); every decrease (`repayDebt`,
auto-repay on mint) emits `DebtRepaid(address indexed user, uint256 amountRepaid, uint256 remainingDebt)`. No
other function writes `debts`.

Per token, over [token creation block, 11,881,000]:
1. creation block by independent `eth_getCode` binary search on each endpoint (equal on both; proves state depth);
2. EIP-1167 clone → implementation; implementation bytecode contains `PUSH32` of both debt topics and
   `PUSH4 getDebt`, and does **not** contain the SP-only `DebtRecordFailed` topic (discrimination check);
3. `eth_getLogs` `topics=[DebtRecorded]` and `[DebtRepaid]` — **positive control** of the same shape:
   `topics=[Transfer]` on the same token and range must be > 0; plus the unfiltered log dump of the token,
   whose per-topic counts must equal the filtered counts;
4. `getDebt(user)` at the fixed block on both endpoints — each answer must be exactly one 32-byte ABI word (a
   `"0x"` answer is a FAIL, not a zero) — for every user in those events must equal Σ`DebtRecorded` −
   Σ`DebtRepaid`; the events are replayed in execution order `(blockNumber, logIndex)` and each
   `DebtRepaid.remainingDebt` must equal the replayed running balance (event data lengths checked);
5. getter positive control: `eth_call` state override plants distinct values at the `debts[user]` slot for every
   candidate slot 0..299; `getDebt` returns the value planted at slot 22 on both endpoints for every token.

**Token scope** (derived on-chain, not only the named ones): the three tokens named by DSR; the token of every
operator in `SP.operators` (row-0 operator set); every token in an `OperatorConfigured`, `APNTsTokenChangeQueued`
or `DebtRecordFailed` log of the SP proxy; and every token deployed (`xPNTsTokenDeployed`) by every factory
`SP.xpntsFactory` ever pointed to (one: `0x6742…09a2`, from `XPNTsFactoryUpdated`) plus the two other known
Sepolia xPNTs factories (`0x0e54…a244` = `FACTORY()` of `0xBb46`, and the CC-28 test factory `0x9f42…0d11`).

## Result (block 11,881,000, hash `0xf785a1ef…95af`)

| token | symbol / version | why in scope | range | DebtRecorded A / B | DebtRepaid A / B | Transfer (PC) A / B | outstanding `debts` |
|---|---|---|---|---|---|---|---|
| `0x696A73701b104c6cCBbAadDD2216788ea08EaB89` | aPNTs / XPNTs-3.4.0 | current `SP.APNTS_TOKEN`; xPNTs token of operator `0xb560…df0E` | 11,151,014 – 11,881,000 | 2 / 2 | 2 / 2 | 100 / 100 | **0** |
| `0xE6579A90dc498a710008de12119812D0FB7aA224` | PNTs / XPNTs-3.4.0 | xPNTs token of operator ANNI `0xEcAA…33c9` | 11,151,051 – 11,881,000 | 0 / 0 | 0 / 0 | 23 / 23 | **0** |
| `0xBb46321545a91DB2F3B5c3e694F2f23aBe259883` | aPNTs / XPNTs-3.5.0 | `SP.pendingAPNTsToken` (to be cancelled, step 1 ①) | 11,631,079 – 11,881,000 | 0 / 0 | 0 / 0 | 1 / 1 | **0** |
| `0x948c9d1bd99b39dee482c23d6a3bd26210b56040` | aPNTs / XPNTs-3.5.0 | earlier `APNTsTokenChangeQueued` (overwritten by 0xBb46) | 11,611,635 – 11,881,000 | 0 / 0 | 0 / 0 | 1 / 1 | **0** |
| `0x4680bf1a4c72814abf090e7fa2b17c07c2407714` | cc28PNT / XPNTs-3.5.0 | CC-28 test factory token (not bound to any SP operator) | 11,230,570 – 11,881,000 | 0 / 0 | 0 / 0 | 1 / 1 | **0** |

The only debt ever recorded in any in-scope token: user `0xf7bf79acb7f3702b9dbd397d8140ac9de6ce642c` on aPNTs
`0x696A…`, 400 aPNTs twice, each fully repaid:

| event | block | tx | amount | remainingDebt |
|---|---|---|---|---|
| DebtRecorded | 11,222,201 | `0xbbbed5700fe4c4b74b4f66b5d67e90f3e7acc7550c5249cd996f7f417230082c` | 400e18 | — |
| DebtRepaid | 11,223,367 | `0xc42c64afadb2d8ef2013f04f28f0fdd8fc3805eaa571cbdc34403c2514871f82` | 400e18 | 0 |
| DebtRecorded | 11,228,400 | `0x92d34a5f374a1723e13d3f2f466764d8623c3add7a82574a94551ee015847540` | 400e18 | — |
| DebtRepaid | 11,228,500 | `0x0ca81567f1625122bb39c89774d0be5fb830d4795fddfbd27c06bb25d35f4e63` | 400e18 | 0 |

`getDebt(0xf7bf…642c)` at block 11,881,000 = 0 on both endpoints = event-derived balance.

**Total outstanding legacy debt across all in-scope old tokens: 0 aPNTs** (`legacy-debt.json`
`.grandTotalOutstanding_aPNTsWei = "0"`).

## Disposition (per the author decision D-21)

The disposition of legacy token debt is already decided by the author. `03-final-spec.md` §6 row 7b (L380 on the
#459 branch / L382 on feat), quoted exactly:

> **D-21（作者定：不处理）**：旧代币里的债务都是测试数据，直接放弃，只在迁移记录里写一句。

This record is that migration-record entry. It does not add a new author-signature gate for in-scope test debt.

| token | outstanding at block 11,881,000 | disposition |
|---|---|---|
| all five tokens above | **0** | Waived per D-21. Disclosure: range = each token's creation block → 11,881,000; amount = 0 outstanding (the only debt ever recorded, 2 × 400e18 aPNTs to `0xf7bf…642c` on aPNTs `0x696A…`, was repaid in full, see table above); source = the tokens' own `debts` ledgers (`DebtRecorded` / `DebtRepaid` events + `getDebt` at the fixed block, two archive endpoints); method = §Method above. With 0 outstanding there is nothing to abandon. |

**Rule for the T-block re-run (A3b).**
- **In-scope legacy test debt** — any non-zero `debts[user]` on the old xPNTs tokens covered by D-21 (the Sepolia
  test tokens and test users in scope above) — is **disclosed** in this record (token, user, range, amount,
  source, method) and **waived per D-21**. It needs no new author signature and does **not** block 7c.
- **Only** a real obligation, or anything outside D-21's scope — for example a non-test token or a non-test user,
  or any production obligation — must be **escalated to the author**, and it **blocks 7c** until the author
  decides.

## Limits

- **Point in time**: block 11,881,000. Debt can be recorded until the operators are paused (runbook step 3); the
  record must be regenerated at T.
- **Bytecode ↔ source**: the deployed token implementations (`0xfdfb…beb8` 3.4.0, `0x9210…2502` / `0x3d78…daf4`
  / `0x04a9…56b7` 3.5.0) were checked for `version()`, the debt topics and the `getDebt` selector, and the
  `debts` slot was located by state override — they were not recompiled from source. The "every write to `debts`
  emits an event" property is taken from the source of those versions.
- **Scope**: xPNTs-style tokens outside the factories listed above (e.g. tokens of SP deployments that predate the
  current proxy) are not bound to the current SP (it only accepts operator tokens from `xpntsFactory`, which has
  had a single value) and are not covered.
