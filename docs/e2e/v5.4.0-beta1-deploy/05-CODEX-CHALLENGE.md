# 05 — CODEX CHALLENGE (v5.4.0-beta.1 fresh redeploy — adversarial verification)

> TX-Value-Verification framework, document 5 of 5.
> Independent 2-axis adversarial sign-off. The framework's whole point: **a green receipt is not a proven feature** — each tx is judged separately on (1) is it REAL on-chain, and (2) was the intended feature actually MET by the resulting state.
>
> This run is a **fresh full redeploy of the same `v5.4.0-beta.1` code** (mainnet rehearsal). The two beta.1 GA blockers (`version()`==5.3.3 and the `APNTS_TOKEN`↔`config` divergence) are RESOLVED by the clean deploy — so this challenge does not need to re-litigate them; it focuses on the headline value + the owed items.

## A. Method & two axes

- **Axis 1 — REAL vs FABRICATED**: does the tx hash exist on-chain, mined, with a receipt (block/gas)?
- **Axis 2 — FEATURE-MET vs NOT-MET**: did the load-bearing L2 state delta asserted in 02-PLAN actually occur (balance/debt/nonce/role/flag), and for ⛔ rows did it revert with the EXACT named selector?

**Network limitation (carried over from beta.1).** The Codex CLI sandbox has **no outbound network** — `cast`/`fetch` against any RPC returns `Operation not permitted`, so Codex cannot independently confirm tx existence (AXIS-1). To compensate, **AXIS-1 was performed human-side in a network-enabled shell** and is **pre-filled below (section B)**; Codex's contribution is scoped to the **AXIS-2 / document-consistency adversarial challenge (section C)**, whose verdicts are now **FILLED** (see §C). The independently-re-derived AXIS-1 set is now **90** (the 86-set below + the 4 gasless-rerun fix-txs, which were previously suite-only and are now RPC-confirmed status=1).

## B. AXIS-1 (REAL vs FABRICATED) — independent RPC re-derivation (human-side, network-enabled) ✅ PRE-FILLED

All **86 unique TX hashes** in `logs/all-tx-inventory.txt` were independently checked via `cast receipt <hash>` against `https://ethereum-sepolia-rpc.publicnode.com` (a different RPC than the suite used, to avoid trusting the harness's own provider).

**Result: 86/86 REAL, all `status = 1`** (this table), **+ 4 gasless-rerun fix-txs now also RPC-verified status=1 → 90/90 independent total.** Zero `NOT_FOUND`, zero `status = 0`. Block range 11071076→11071279; total gas (86-set) 4,913,548. Source: `logs/rpc-independent-verify.txt`.

> **Why every mined tx is status=1 (not a contradiction):** the ⛔ negatives are probed via read-only `eth_call`/staticcall, which revert *without* producing a mined transaction — they never become `status=0` receipts. The absence of any `status=0` row is expected and correct, not evidence that negatives were skipped. The ⛔ legs are accounted for in section C and in 03/04.
>
> **Scope note (updated):** the 86-set covers the admin/config/governance/x402/channel/state surface. The 4 first-pass-failure **rerun fix-txs** ([26] gasless `0x7b015620…`, [27] `0x2756e812…`, [28] `0xaa9268a5…`, [29] `0x23b807e2…`) are now **also independently RPC-re-derived status=1** and appended to `logs/rpc-independent-verify.txt`, bringing the independent set to **90/90 REAL**. [36] I1 is a read-only group (`version()=="SuperPaymaster-5.4.0"`, now also eth_call-verified).

### AXIS-1 per-tx (REAL re-derived) — AXIS-2 adjudicated by capability category in §C

> The 86 admin/config/governance/x402/channel txs below are feature-met-judged **at the capability level in section C** (per-tx feature-met for 86 config-surface txs collapses to the category verdicts there: MET / PARTIAL / NOT-MET). The AXIS-2 column therefore points to §C rather than repeating a verdict per row. The 4 gasless-rerun fix-txs are now also RPC-verified status=1 (the independent set is **90**); see 03 §Independent RPC verification.

| TX hash | AXIS-1 (RPC re-derived) | status | block | gas | AXIS-2 (feature-met) |
|---|---|---|---|---|---|
| `0x002b5efefedb9efe99f4d1b2de509a6b4a23c820a713ffc05911cfed1a6aadcf` | REAL | 1 | 11071204 | 60864 | see §C (by capability) |
| `0x032dc3b6e9048f5d716828e3bf2d2e49c2403879975a052c853d173e58636819` | REAL | 1 | 11071273 | 29005 | see §C (by capability) |
| `0x085619b2358aca0c93c937e885185b3b1901591e70f4c43325da5ba62dd28bb8` | REAL | 1 | 11071231 | 60852 | see §C (by capability) |
| `0x0d2f92e983b43c5a2a2b2040f81fd0121f2d5415eb03c4149224956418c45ebd` | REAL | 1 | 11071169 | 62955 | see §C (by capability) |
| `0x0f3702269e6a28a4410b74397155dab673675523538ea2be801565b6e84dc6da` | REAL | 1 | 11071107 | 25059 | see §C (by capability) |
| `0x14ac938129c609b90227f1c22069dc944e78d82a1337cf906cc9d82c4d30aa60` | REAL | 1 | 11071103 | 41517 | see §C (by capability) |
| `0x1c2615325a092c8788362e2b01ebde55a2ea78bf589e152065172c157d71a3cf` | REAL | 1 | 11071171 | 34932 | see §C (by capability) |
| `0x1e7ab565e193116b05dbefefa2a6c4ceec951edc5184ae4380b98e5c7854ba37` | REAL | 1 | 11071076 | 29169 | see §C (by capability) |
| `0x1e7fa93960668170f3b008fda72a49d305f723c3b92b7e0f371e74f71bd1371a` | REAL | 1 | 11071261 | 58233 | see §C (by capability) |
| `0x2271a4cff387b9ac1b40643736531991c95144209030f49a5aadd4a732a43901` | REAL | 1 | 11071185 | 115284 | see §C (by capability) |
| `0x22c156b05f6ecd9ea05f95a6883f57ade005995bfb267e261bb0028c6f70509c` | REAL | 1 | 11071254 | 32717 | see §C (by capability) |
| `0x26d14619b950eca294a19441bdb9b617046789fbc76062d261cc5b8466ac5541` | REAL | 1 | 11071170 | 62931 | see §C (by capability) |
| `0x2842fdac23924cab3d3898c8796a3aead67148f307469c7b8304a64a8a5a8e30` | REAL | 1 | 11071094 | 62544 | see §C (by capability) |
| `0x293192cd6a508aed68add24ed789d1644a516c717ca42c682dc6f023a84b1baa` | REAL | 1 | 11071108 | 46410 | see §C (by capability) |
| `0x2bc3f97f361c3673b7c8c4a2b8323186e4181e2882f86fb6d8926067f2b087bb` | REAL | 1 | 11071101 | 34089 | see §C (by capability) |
| `0x2bd1c181c66356e0edd0cfb76fbc93be9ad4c1d5e349f620c5f050043a10cecb` | REAL | 1 | 11071113 | 53491 | see §C (by capability) |
| `0x2d0db1cd494bcbe58592d18ce3561f3b2ea5f7fce95ae53f6ea80cab41f4170e` | REAL | 1 | 11071146 | 54493 | see §C (by capability) |
| `0x3299bbfe7d82085fd76c43e3fe2cd20dafd3d75df109ed4150d653342e52eef3` | REAL | 1 | 11071106 | 46971 | see §C (by capability) |
| `0x355f89edee6181f3d11c6a26aaefe01684c34ccbc8c14dc10f20a6eff2f753ec` | REAL | 1 | 11071166 | 30810 | see §C (by capability) |
| `0x3581742cec28c64f50c19118555949e4e045d54577907c4f1fe063e5b19f398b` | REAL | 1 | 11071228 | 153491 | see §C (by capability) |
| `0x388fb325998b03bd55d0a32031e9de294d15ee49dc0d536c877bf4cc29a26f57` | REAL | 1 | 11071110 | 24498 | see §C (by capability) |
| `0x39ad4ca8884b7f0474abc31ec3216e316f2932967a987084a70e754585bde11f` | REAL | 1 | 11071144 | 36549 | see §C (by capability) |
| `0x39e7c8dc4e0359fde70713a1f38216faaf01ed64a45c04a1fa38f93da332ce7c` | REAL | 1 | 11071179 | 52044 | see §C (by capability) |
| `0x3af6e1118650f6c93373e21eaf6e20d5312ea14d7cac5be57b2ade972fe04f4f` | REAL | 1 | 11071092 | 82776 | see §C (by capability) |
| `0x3bff8eb5f63e4db05e0c68c35ba5561c4e46286965e4e4ae088eb65714790cac` | REAL | 1 | 11071234 | 168433 | see §C (by capability) |
| `0x3e54a36a41c01395eb8b8bd4dfcac4be77d55979ded191b02634148519020c48` | REAL | 1 | 11071163 | 47655 | see §C (by capability) |
| `0x3e5654548498bd02acc67c69ec25834e636bebe275c94d00d21becdb84d020f3` | REAL | 1 | 11071088 | 36694 | see §C (by capability) |
| `0x455f0c772977e5ea6242887e99eed36e63bb4ff40bd1709b8bfaf9b8aae5ba93` | REAL | 1 | 11071233 | 50596 | see §C (by capability) |
| `0x480aca5c7ce94d14623fbc4f4b99b850699c2cd31fb0f366ca7d4e4982d0bca1` | REAL | 1 | 11071159 | 37068 | see §C (by capability) |
| `0x48e6f1f3bdfa4fe2eb8eb3ab6f9a2dcb69c1bd75b979af5f77e4c06dcbfbfaa0` | REAL | 1 | 11071257 | 28687 | see §C (by capability) |
| `0x4b180329ddb95dc94d41423dea5ab5fc89209249fc5a59f51e16aa12f03f2077` | REAL | 1 | 11071145 | 36537 | see §C (by capability) |
| `0x4c4e777ecc1138b8abba72e7a37bae86904ea51438e244fd51b583d532f6bb53` | REAL | 1 | 11071162 | 29205 | see §C (by capability) |
| `0x4f466949ef38c12c1de3fa1d55c7e40d6ddea52c9ea96b09932047223a2fc06c` | REAL | 1 | 11071279 | 62743 | see §C (by capability) |
| `0x50cc95b5bef66c9b301e38a0214d5d84b52731314063bbe0df75bfa79f1864a3` | REAL | 1 | 11071132 | 48430 | see §C (by capability) |
| `0x56c7d13354e3624f040a989f3f24a3d02d5c5d0826bf0d71ffb1e77e67b599e3` | REAL | 1 | 11071116 | 36705 | see §C (by capability) |
| `0x5771b1f0f915cc1bb19572f54bf0568161006139f9e56f7329579eca1f5ce93b` | REAL | 1 | 11071167 | 52722 | see §C (by capability) |
| `0x58a8af7f5a374b650ab29c57bf5ff6959cbff34a5cadd20661c0640de031c580` | REAL | 1 | 11071244 | 56957 | see §C (by capability) |
| `0x5a479081706ee9167541eefa3033ae32a9e4c0d4612fce5f1dbe1cdf896e2298` | REAL | 1 | 11071126 | 47705 | see §C (by capability) |
| `0x5c9c68f41e6fb65ebe45208967cbf8d86d249bc00a20eaeae6be42f6ccc66356` | REAL | 1 | 11071134 | 45408 | see §C (by capability) |
| `0x6ab1c648a9ecda2cd706c59d1241d30a8efa978c45d641602fa48c5b7b70ceac` | REAL | 1 | 11071226 | 111376 | see §C (by capability) |
| `0x72a826662dd5a9ae98a02da5636205951750f183735722ed166b9cb7b6ccd1cc` | REAL | 1 | 11071105 | 46541 | see §C (by capability) |
| `0x7456c7f98914321831a87b8a96546c7279a6466c01d17817c3b8e1baf09f9938` | REAL | 1 | 11071154 | 35457 | see §C (by capability) |
| `0x76c79a94f79864649824cf9705693c050890701d53db1aa769b9ddd4b18462f5` | REAL | 1 | 11071124 | 170232 | see §C (by capability) |
| `0x7a5f45603034138ad1cc716059efa12206a18d1cd2796726bd31e3771ee0ffbd` | REAL | 1 | 11071215 | 49038 | see §C (by capability) |
| `0x7f18f43b7f202a302be88fe74ba7b391b3f167bbf44d7e1fbcd890b05c5ab27e` | REAL | 1 | 11071188 | 82788 | see §C (by capability) |
| `0x80f287d9a26b45f04aa200e8a6e162837f925c43adb188f14f95639a24e0981a` | REAL | 1 | 11071276 | 31674 | see §C (by capability) |
| `0x853919953001b7d83a70a2c53409f1a20fa4b05d8b0024195eda52e0331ee460` | REAL | 1 | 11071270 | 52917 | see §C (by capability) |
| `0x899d841d98f997ae5ef37a16deb564e993c0b05128eaffea9a0f17a2e3dcdbee` | REAL | 1 | 11071143 | 60895 | see §C (by capability) |
| `0x89ba1a1e101a97f901b31475768aea174e892e45d5a338005bd0156acc68936f` | REAL | 1 | 11071197 | 60864 | see §C (by capability) |
| `0x8c8cba950981607e61dac051f34586b18cf23f8d4a69d06580894272f24714ee` | REAL | 1 | 11071093 | 82175 | see §C (by capability) |
| `0x8d808d759b4dbf7567f6028e3c65ebaec39fbf20fbe6d1c2557a27e7095ade1f` | REAL | 1 | 11071243 | 61172 | see §C (by capability) |
| `0x8f246bb00fd98dc61775dba0da72bf19976d08b3f46cd689be1b2843c40159c4` | REAL | 1 | 11071237 | 132710 | see §C (by capability) |
| `0x904d833481ac04577cf9e3a6bd937038fe349f7e0795d5ffb4a79c16ce26b502` | REAL | 1 | 11071194 | 60864 | see §C (by capability) |
| `0x933c2c458af74a99f9b458987c6817275a8f6a9c0c31adad10c6965115ec2b36` | REAL | 1 | 11071173 | 34932 | see §C (by capability) |
| `0x9578c77ea85e7980eb403309459fa6e4ec33cff9d365309760e63045cd494b80` | REAL | 1 | 11071099 | 58854 | see §C (by capability) |
| `0x9923c682c2762559b1f74891753937b7fc4a27b77517abfdd0d9a89491acd84d` | REAL | 1 | 11071256 | 29017 | see §C (by capability) |
| `0x9d1c303a088147ef4dfc74905dcde5e0a3ad3a9ada20fc89b50c3b913269e2e9` | REAL | 1 | 11071084 | 36705 | see §C (by capability) |
| `0xa0ee356a30e4432f2d2476919b1e99e17d4635c5f5c18955dc65b605f99dba8a` | REAL | 1 | 11071240 | 50631 | see §C (by capability) |
| `0xa367dc1e59e73d38796f2e2f492f24009707e8c977f75273bc435b29ca35d834` | REAL | 1 | 11071140 | 52044 | see §C (by capability) |
| `0xa9d28d807c142c40ce4cdeae4de30af072a40d3ec971ab2baed40cf8182f0ca0` | REAL | 1 | 11071158 | 155715 | see §C (by capability) |
| `0xaba63ca47551c462ddcadeff24c3d06332f60e17cea567662d8e351db3b568a9` | REAL | 1 | 11071196 | 60864 | see §C (by capability) |
| `0xae7ae365d7498139aae23a655e3ac8fd89aca79e0c905a8a1077321fcdba574b` | REAL | 1 | 11071249 | 33113 | see §C (by capability) |
| `0xb348df670aea29ec9533db5032a02cfdceec85dee32a39e1b93b29adcc332fae` | REAL | 1 | 11071129 | 30605 | see §C (by capability) |
| `0xb7b2a6a2a4ba39a14e305f734bf28424619e85e06166d5c3252ca543f12a8bbf` | REAL | 1 | 11071155 | 35457 | see §C (by capability) |
| `0xb9df8305aaaba06a9a5ab4e02b848fe60caada3f8e5da2faca18e48f781c5102` | REAL | 1 | 11071192 | 60864 | see §C (by capability) |
| `0xbcc29449e396ef1661bae4173ac022ff245749b329c59c51eb72eb9223ad87bb` | REAL | 1 | 11071095 | 62544 | see §C (by capability) |
| `0xbcc9e00b51441a629df0c83c7d61ccc3f846a4eea4f1d67b120756dd1a841460` | REAL | 1 | 11071164 | 25743 | see §C (by capability) |
| `0xbd6f3e2626c87512bea605ed760c3532e320d93ed3be8d624d693ad36e1c5b13` | REAL | 1 | 11071181 | 30048 | see §C (by capability) |
| `0xbf9db46d9e3c50e717949162b74d476677930e60f7c7b1f15fd0b01dc50c72b0` | REAL | 1 | 11071224 | 72378 | see §C (by capability) |
| `0xc44fccf6053dc133e136a6e4648a84d33057197618f898d9d3947eb5c26de2ba` | REAL | 1 | 11071259 | 50596 | see §C (by capability) |
| `0xca520191bde57c4247627f9ac8f08e2a63d57284c522502c6fb6e6e7626bada7` | REAL | 1 | 11071275 | 61142 | see §C (by capability) |
| `0xcfbeacff799ccf264ef782db39646268675901e4eb058a5ca83f1a292285f117` | REAL | 1 | 11071241 | 29586 | see §C (by capability) |
| `0xd5d1b440b3566657dc1861d1a8bf7241142d87d33ff6b939cf29de0152b2181d` | REAL | 1 | 11071220 | 168825 | see §C (by capability) |
| `0xd60ebac08941cee9bb79bc578321b9c977381fec61baf42b79d17c7f025e6cc8` | REAL | 1 | 11071255 | 52929 | see §C (by capability) |
| `0xd77bc9da79e0843b98bca92ce819ac06416f12b23e0d6bd68b2792fe951da4b3` | REAL | 1 | 11071142 | 30048 | see §C (by capability) |
| `0xda3c37572cb041c2d8162bba7f19b0159d0cba78180d1c74aa10bf18f9428515` | REAL | 1 | 11071184 | 49038 | see §C (by capability) |
| `0xe4cfdfd94e98d491f9f489d51dfa806c9176a874625db219926080238f27589b` | REAL | 1 | 11071160 | 70790 | see §C (by capability) |
| `0xe65c14ef673e6bcd8a26d780436c38055eb0afe02cce05c037cfefebd1ef7a07` | REAL | 1 | 11071246 | 54493 | see §C (by capability) |
| `0xe853e883e976e27ac6e59804ba454ad73ad3fbfbad90c0120e2609c7298104d4` | REAL | 1 | 11071250 | 33113 | see §C (by capability) |
| `0xe8d5ff66ef79e77bffb819a845557fb6b12e093ff5ab95860ed4361def32a575` | REAL | 1 | 11071195 | 60864 | see §C (by capability) |
| `0xedf964362c76bc1d2e9448cace7c73fca0f1cfe905d5ecb8497339748ff3fcef` | REAL | 1 | 11071097 | 58854 | see §C (by capability) |
| `0xf12479efb88810ac8d3a246ba2d7db8385a69ebb9680900fced31b8cb6d38ab9` | REAL | 1 | 11071122 | 36694 | see §C (by capability) |
| `0xf89b7f26c0e6516e5823460437ad12783347586820055a2ef471adde47adbe22` | REAL | 1 | 11071253 | 32717 | see §C (by capability) |
| `0xf9487f89cc9f2f5a5cc79d5430952c1d82c86aabd5c6af76034065dc53edc23a` | REAL | 1 | 11071260 | 36714 | see §C (by capability) |
| `0xfa8bbb5d9a3834cc94b25893002594494d372066b8d2ec3677dff0e4d72b7f36` | REAL | 1 | 11071083 | 45390 | see §C (by capability) |
| `0xfe0340741a743e3edef1c5078d161cd27a4248c5a98417236a047881ce3b457f` | REAL | 1 | 11071265 | 96309 | see §C (by capability) |

**AXIS-1 tally: 86/86 REAL in this table; with the 4 RPC-verified gasless-rerun fix-txs the full independent set is 90/90 REAL, all status=1.**

## C. AXIS-2 (FEATURE-MET vs NOT-MET) — challenge areas — Codex verdicts FILLED

Codex adversarially challenged each area below (a green/effective-green group is NOT automatically a proven feature). The Codex verdict column is now filled. Legend: **MET** = tx-proven on-chain; **PARTIAL** = real tx but post-state/selector inferred or suite-asserted, not independently re-derived this run; **NOT-MET** = not exercised live this run (owed); **CONFIRMED** = Codex independently corroborated the human-side claim.

| Item | Human-side position (to be challenged) | Codex verdict |
|---|---|---|
| **The 4 first-pass failures = harness/L1/test, not contract bug** | [27]/[28]/[29] `AA34` is the **L1-gas credit-ceiling artifact** (fresh user tier-1 = 100 aPNTs < ~120 aPNTs L1 validate charge; H-1 anti-drain has no balance short-circuit by design). Fixed via `setCreditTier(1/2,300)` live; **contract default kept**. [36] I1 + `check-contracts.js` = stale hard-coded `5.3.3` expected strings; on-chain is `5.4.0`. Failure #1 (`prepare-test Unauthorized`) = fresh deployer lacked `PAYMASTER_SUPER`, fixed idempotently in `TestAccountPrepare.s.sol`. **None is a SuperPaymaster contract bug.** | **CONFIRMED.** Codex verified the H-1 credit-ceiling analysis is accurate — it DOES block balance-payers (`SuperPaymaster.sol` 1102–1106 + `_creditExceeded` 812–814, no balance short-circuit). All 4 first-pass failures are harness/L1/test-hygiene, not a contract bug. |
| **Credit-ceiling OP-L2 caveat** | (original wording claimed the 100-aPNTs default is "plenty" on OP and "mainnet/OP needs no change"). | **DOWNGRADED — RISKY/UNPROVEN.** The directional reasoning (OP execution gas ≈100× cheaper than Sepolia L1 → lower per-tx aPNTs charge) is kept, but "keep 100 on OP, no change needed" is an **UNVERIFIED hypothesis**: no OP receipt, no OP gas model, no L1-data-fee calc was produced. **"Keep base credit 100" is an OPEN GA decision, NOT resolved.** Before relying on 100 for OP, the actual sponsored-tx validate-charge MUST be measured on OP and confirmed < 100 aPNTs; else raise the base tier via `setCreditTier`. |
| **#295 nonce-retry validated** | B1/B2/B4 PASSED in-suite (beta.1 saw them fail). Log shows `nonce/in-flight conflict — draining mempool & retrying 1/2…` then confirm. | **PARTIAL.** Operator config/funding txs are real (status=1) and the retry path executed in-suite, but the post-state deltas are suite-asserted, not independently re-derived this run. |
| **SP gasless burn-path (1.1/1.2)** | [27]/[28] (reruns) prove SP xPNTs balance-pay + burn on two tokens (aPNTs, PNTs). [29] proves the BURN branch (burned 48.47 aPNTs, debt stayed 0). | **PARTIAL.** The 3 rerun hashes are now status=1-verified (part of the 90-set), but the post-state balance/burn deltas are suite-asserted, not independently re-derived. SP aPNTs balance-pay + PNTs multi-token + burn branch are inferred/state-delta-claimed, not fully independently post-state-proven. |
| **PaymasterV4 independent gasless (1.5)** | [26] `0x7b015620…` proves AOA escrow path. | **PARTIAL.** Tx is status=1-verified, but the escrow post-state delta is suite-asserted, not independently re-derived. |
| **x402 EIP-3009 + direct + C-02 (2.1/2.2)** | [31] USDC settle + replay-reject `NonceAlreadyUsed`; [32] direct xPNTs + redirect-reject `InvalidX402Signature`. | **MET (tx-proven)** for the EIP-3009 USDC settle and the direct xPNTs settle (hashes in verify file). **PARTIAL** for the replay/C-02 negatives — the selector is claimed but not independently decoded (eth_call/unit, not a live-failed mined tx). |
| **MicroPaymentChannel (2.5)** | [30] open/settle/close lifecycle. | **MET (tx-proven).** Open/settle/close are real mined txs (hashes in verify file). |
| **Emergency halt (7.5)** | [37] I2 reverted `0x4e97bcfc == EmergencyStop()` — clean ⛔ named-selector match. | **PARTIAL.** The `emergencyRevoke`/`addAutoApproved` flag-flip txs are status=1 (admin surface, state-delta suite-asserted). The `EmergencyStop()` revert is selector-level — eth_call/decoded, not a live-failed mined tx. |
| **Fresh-deploy provenance** | `version()`=="SuperPaymaster-5.4.0" (I1, clean — beta.1 GA blocker resolved); `APNTS_TOKEN==config.aPNTs==0x9e66B457…` (B2, no migration/divergence); `agentIdentityRegistry==0x8004A818…` (B4, == config). | **CONFIRMED (eth_call-verified).** Both GA blockers are now independently eth_call-confirmed (not just doc-claimed): `version()`→`"SuperPaymaster-5.4.0"`; `APNTS_TOKEN()`→`0x9e66B457…` == `config.aPNTs` (identical). Recorded as `ETH_CALL` lines in `logs/rpc-independent-verify.txt`. |
| **[OWED] Dual-channel agent `handleOps` (3.4)** | G2 verified eligibility LOGIC read-only only. Registry IS deployed & wired (`0x8004A818…`). Owed = register a no-SBT agent + run a live agent-channel op. **Test-fixture gap, NOT a deployment gap.** | **NOT-MET (read-only only).** No no-SBT agent registered, no live agent-channel `handleOps`; agent-feedback emission not asserted. Owed, honestly. |
| **[OWED] credit/debt DEBT branch + `repayDebt` (1.2/1.3)** | [29]/TC4 took the BURN branch (AA-A held balance). The 0-balance→`recordDebtWithOpHash` branch + repay cycle NOT driven live this run (proven in beta.1 via a drain fixture). | **NOT-MET (not exercised live).** Only the burn branch ran; credit/debt accrual + `repayDebt` cycle was not driven this run. Owed. |
| **Negatives unit-tested-only** | Rate-commitment, stale-price, credit-ceiling drain (isolated), xPNTs firewall, burn replay, unapproved-facilitator: not live mined txns this run (unit-tested / `eth_call`-observed). | **NOT-MET / NOT-EXERCISED-LIVE.** These remain eth_call/unit-tested, not live-failed mined txs. Also owed: value-bearing DVT slash, timelock apply steps, BLS aggregate reputation update, UUPS upgrade, facilitator earnings withdraw, isolated credit-ceiling over-limit reject. |

## C-bis. Resolution of Codex findings

Recording how the Codex pass changed this document:

- **(a) AXIS-1 gap closed.** The 4 gasless-rerun fix-txs (`0x7b015620…`, `0x2756e812…`, `0xaa9268a5…`, `0x23b807e2…`) are now independently RPC-verified status=1 and appended to `logs/rpc-independent-verify.txt`, so the independently-re-derived set is **90/90 REAL, all status=1** (was 86; the 4 reruns were previously only suite/`rerun-*.log`-confirmed). Both GA blockers are now `ETH_CALL`-confirmed in the same file (`version()`→`"SuperPaymaster-5.4.0"`; `APNTS_TOKEN()`→`0x9e66B457…` == `config.aPNTs`), and "no `src/` change this session" is `GIT_EVIDENCE`-recorded (last 6 `main` commits touched 0 `contracts/src/*.sol`).
- **(b) OP-100 claim downgraded.** The "keep base credit 100 on OP, no change needed" claim is downgraded from a settled conclusion to an **OPEN GA item** (Codex: RISKY/UNPROVEN — no OP receipt / gas model / L1-data-fee calc). Directional reasoning kept; the OP value must be measured before GA. (03 §Credit-ceiling KEY OPEN ITEM + 04 footnote 14.)
- **(c) Honest coverage scope.** The PARTIAL items (SP aPNTs balance-pay, SP PNTs multi-token, PaymasterV4 gasless, operator config/funding, V4 lifecycle, reputation/credit-tier config, oracle update, protocol-/facilitator-fee config, admin surfaces, x402 replay/C-02 negatives) are real txs with suite-asserted (not independently re-derived) post-states. The NOT-MET items (credit/debt accrual + repayDebt, dual-channel agent `handleOps`, agent-feedback emission, value-bearing DVT slash, timelock apply, BLS aggregate reputation, UUPS upgrade, facilitator earnings withdraw, xPNTs firewall reverts, unapproved-facilitator revert, burn-replay, rate-commitment/stale-price reverts, isolated credit-ceiling over-limit reject) are owed.
- **(d) Selector-level negatives** (x402 replay/C-02, EmergencyStop, firewall, burn-replay, unapproved-facilitator) remain **eth_call / unit-tested, not live-failed mined txs** — not independently decoded this run.

## D. Release-level verdict — did the fresh redeploy reproduce v5.4.0-beta.1's proven value? (Codex AXIS-2 verdicts FILLED)

Honest scorecard, scoped to what is proven on-chain (AXIS-1 independently RPC-verified REAL 90/90; AXIS-2 per Codex categories in §C):

| Capability | Codex AXIS-2 verdict (on-chain proof status) |
|---|---|
| x402 EIP-3009 settlement (native USDC) | **MET (tx-proven)** |
| x402 direct settle (xPNTs, C-02) | **MET (tx-proven)** |
| MicroPaymentChannel lifecycle | **MET (tx-proven)** |
| SP xPNTs gasless sponsorship (burn path, 2 tokens) | **PARTIAL** — rerun txs status=1-verified, but burn/balance deltas suite-asserted, not independently re-derived |
| PaymasterV4 independent gasless | **PARTIAL** — tx status=1, escrow delta suite-asserted |
| Operator funding / config / governance (B1–B5, #295 nonce-retry) | **PARTIAL** — real txs, post-state suite-asserted |
| V4 lifecycle / reputation-rule + credit-tier config / oracle price cache / protocol- & facilitator-fee config / admin surfaces | **PARTIAL** — real txs, post-state suite-asserted |
| x402 replay (`NonceAlreadyUsed`) / C-02 redirect (`InvalidX402Signature`) / Emergency halt (`EmergencyStop()`) | **PARTIAL** — selector claimed, eth_call/decoded, not a live-failed mined tx |
| Fresh-deploy provenance (clean `version()` 5.4.0, `APNTS_TOKEN==config.aPNTs`) | **CONFIRMED (eth_call-verified)** — both beta.1 GA blockers independently eth_call-confirmed |
| **Credit/debt DEBT branch + `repayDebt`** | **NOT-MET — not driven live this run** (burn branch only; proven in beta.1) |
| **Dual-channel agent `handleOps` + agent-feedback emission** | **NOT-MET — read-only only** (registry wired `0x8004A818…`; no live agent op) |
| ⛔ negatives (rate-commitment, stale-price, credit-ceiling drain, firewall, burn replay, unapproved-facilitator) + value-bearing DVT slash, timelock apply, BLS aggregate rep, UUPS upgrade, facilitator earnings withdraw | **NOT-MET / NOT-EXERCISED-LIVE** — unit-tested / `eth_call`-observed, not live this run |
| **Base credit-tier value for OP** | **OPEN GA DECISION — UNPROVEN** (no OP gas measurement; "keep 100" is a hypothesis, not a result) |

**Bottom line (Codex AXIS-2 verdicts folded in).** This fresh redeploy of the **same `v5.4.0-beta.1` code** **faithfully validated the mainnet DEPLOY MECHANICS of v5.4.0-beta.1**: wiring is correct, both GA blockers are now **eth_call-confirmed** (`version()`==5.4.0; `APNTS_TOKEN==config.aPNTs`), the deploy/test-script gaps were found and fixed, and **90/90 txs are independently RPC-verified REAL (all status=1)**. The 4 first-pass failures are all non-contract (L1 credit-ceiling artifact + stale test version strings + fresh-deploy role grant). **However, several business capabilities remain PARTIAL or owed** — dual-channel agent `handleOps`, the 0-balance debt-accrual + `repayDebt` cycle, and the live ⛔ negatives are not proven live this run — and **the base-credit-tier value for OP is an UNRESOLVED GA decision pending an actual OP gas measurement** (it was NOT proven by this L1 rehearsal; the earlier "keep 100, no change needed" claim is downgraded to an open item). Do not read this rehearsal as a full business-capability sign-off; it is a deploy-mechanics validation with an honest PARTIAL/owed tail.
