# A6 collector — mechanism (SP-owned half)

This is the implementation half of the "A6 collector" from CC-122's sequencing plan
(`AOA_RepCredit_Sequencing_Plan_2026-09-13.md` §7.7, §8.4; RDR-6 in
`docs/design/aoa-balance-mode/03-final-spec.md` §10.8). It is **not** the collector's final
form and its dry-run output is **not accepted evidence** — see "Division of labor" below.

## Division of labor (plan §8.4)

- **DSR owns the sample protocol**: sample size, failure-sample mix, baseline configuration
  choices, the "Passport" schema, evidence-registry fields. The trust root, validator scope and
  N=50 acceptance conditions are decided in Seeder `dc7d0fab` (2026-10-15), as recorded below.
- **SP (this code) owns the implementation**: same harness/ABI/lens conventions as D7's
  `script/gasless-tests/`, baseline comparator paymasters, dry-run on anvil first.

`--count` and `--b-max` on `collector.mjs` are required explicit arguments. Formal A6 requires
50 matched triplets; the local dry-run's `--b-max 1` is not a formal protocol choice. Remaining
campaign configuration must be recorded before the window. A dry-run proves the mechanism
works, nothing about paymaster performance.

## 信任根与范围

DSR 已在 Seeder `dc7d0fab`（2026-10-15）选择范围 **(a)**，按此已决范围执行。
A6 校验器不要求复刻完整 EntryPoint、VPM、TPM、SimpleAccount 链上验证规则。
可信根是实际链上交易、EntryPoint v0.7 的逐 `UserOperationEvent`（UOE）及 receipt、固定块状态。
同一攻击者可以整体伪造离线 JSONL 并重算 `userOpHash`，因此 #477/#479 的校验器不能称为独立链上重放器。
正式步骤见 [A6 正式 SOP](A6-SOP.md)。

`validate.mjs <run.jsonl> [--json <report.json>]` 只读取归档，使用独立于 `gauge-lib.mjs` 的解码实现，检查：

- 内部逐行自洽、必需字段、packed operation 与重算 hash 的绑定，以及 receipt/log 中逐 UOE 的判定。
- SP、VPM、TPM 三臂的匹配、唯一性、计数、失败与排除记录、运行汇总和停止状态。
- 归档中的 A/B 逐值一致、固定块锚定、前后状态连续性、SP 守恒及各臂 EntryPoint deposit 变化。
- Passport 的字段完整性、地址与配置绑定、代码信息的归档内一致性及漂移。

这些检查只证明所给材料内部满足已实现的规则。源码推导的 prefund 算术、局部 gas/packed 字段绑定或
code size/codehash 字段自洽检查，不等于重新执行对应链上准入规则，也不能认证材料的链上真实性。

第 6 轮“伪造整行并重算哈希”的下列对抗项属于 **OUT OF SCOPE（校验器范围外）**，由链上重取控制，
不得写成“已被离线校验器拒绝”：

- EntryPoint `requiredPrefund` / `AA31`。
- `uint120` gas packing / `AA94`。
- TPM `paymasterAndData` 长度及 postOp limit。
- VPM 签名长度及 `ECDSA.recover` / `AA34`。
- SimpleAccount 签名长度 / `AA23`。
- EntryPoint、SP proxy 的 code size 与 codehash。
- empty-code accounts（空代码账户）。

正式 A6 的验收条件如下，不能由离线通过或 collector 的 `protocolConformant` 自报代替：

1. A/B 必须来自不同运营方、不同后端的独立 RPC，在相同 `chainId`、block number/hash 上逐值一致。
   不同 URL 或主机名不证明独立性；本地两端口加 override 的 N=50 仍不合规。
2. 对纳入 50 个匹配三元组的每个操作保留 txHash、blockHash、expected/observed userOpHash、
   原始 receipt/UOE、相关前后状态、源代码与配置 pin、失败和排除原因。DSR 必须从独立 RPC
   对全部 150 个纳入样本重取 receipt、UOE 及交易归属，并在冻结后随机抽样深查状态、Passport 与守恒。
   DSR 不能只信 JSONL 或 collector 自报。
3. 冻结原始 JSONL、双端 raw response、抽样 seed、名单、命令及 SHA-256。
   抽样 seed、名单与命令须在执行抽样深查前提交并冻结。若签名，签名只证明冻结后的归档未变，
   不证明链上真实性。
4. RPC 分歧、缺失或重复事件、hash 不匹配、区块重组、无法归因的额外 UOE、状态或配置漂移均
   fail closed。抽检任一不符，整窗停用并调查，整窗作废（whole window void），不得报告合规 N=50。
5. #477/#479 已合并的本地 Anvil 运行只证实量具机制，仍非 A6 真链数据，也不阻塞 A2。
   当前 A3a 为 **NO-GO**；正式 A6 必须等待作者 A3a go 且 A4 完成。

### SP TODO before formal A6

当前 `collector.mjs` 只接受本地 HTTP RPC，依赖 `ANVIL_KEYS`、`anvil_impersonateAccount` 和
`anvil_setBalance`，不能原样运行正式 A6。以下能力尚不存在，SP 必须在正式 A6 前补齐：

- 可用于正式链和独立远端 A/B 的采集与账户准备路径，替换本地密钥和 impersonation 依赖。
- RPC 运营方与后端身份的独立性证据记录；现有 URL/主机名判断不足以证明独立性。
- 双端完整 raw request/response 归档；现有 JSONL 的选取字段和 A/B readback 不是完整原始响应档案。
- 将原始 receipt/UOE、交易、固定块状态及源码/配置 pin 关联到每个纳入、失败和排除操作的完整证据包。
- 文件及 SHA-256 manifest 冻结、抽样 seed/名单/命令预先提交、抽样复查记录流程。
- DSR 从独立 RPC 重取全部 150 个纳入样本及随机深查的工具和核对记录。

详细执行与停窗要求见 [SOP 的 SP TODO 清单](A6-SOP.md#sp-todo-before-formal-a6)。本节规定正式验收要求，
不表示这些缺失能力已经实现。

## Per-UserOperation gauge (CC-125 a71741ed)

`collector.mjs` is now a per-UserOperation gauge (it replaced the receipt-level dry-run that
recorded `receipt.status` only). Evidence of it working, including fixture negative controls and
the old-vs-new comparison, is archived in `docs/design/aoa-balance-mode/data/a6-gauge-local/`.
**Local Anvil only; not A6 data. Formal A6 requires author A3a go and A4 complete; A3a is NO-GO.**

- **Verdict per op, never per tx.** For every bundle tx the collector decodes every EntryPoint
  `UserOperationEvent` / `UserOperationRevertReason` / `PostOpRevertReason` /
  `UserOperationPrefundTooLow` and classifies the attempt for the *expected* `userOpHash`
  (computed locally and via `EntryPoint.getUserOpHash`; they must agree or the run stops):
  `USEROP_SUCCESS`, `USEROP_REVERTED`, `NO_EVENT`, `HASH_MISMATCH`, `EVENT_FIELD_MISMATCH`,
  `DUPLICATE_EVENT`, `TX_FAILED`, `NOT_SENT`. Only `USEROP_SUCCESS` is a success.
- **SP conservation.** The SP arm decodes `TransactionSponsored`, `LockCreated`/`LockSettled`
  (or `CreditReserved`/`CreditSettled`) and checks before/after read-backs (pinned to blocks N-1
  and N) of operator balance, `protocolRevenue`, `inflightOf`, user xPNTs, `totalSupply`,
  `lockedOf`, `debts`, `creditReservedOf`, operator `totalSpent`/`totalTxSponsored` against the
  identities derived from source in `gauge-lib.mjs` (each check carries its `path:line`). Every
  arm also checks `ΔEntryPoint deposit == −actualGasCost`.
- **Passport + A/B.** Every read-back is made on two endpoints (`--rpc-a`, `--rpc-b`) at the
  same block and compared; the Passport (chain id, blocks, runtime codehashes of EntryPoint / SP
  proxy+impl / xPNTs clone+impl+ext / account proxy+impl / VPM / TPM / feed, config getters) is
  taken at the start, after every attempt and at the end, and must not drift.
- **Attempts / exclusions / stops.** One append-only JSONL line per attempt (failures included);
  `run_start` / `run_end` lines frame the run. `--count` (matched triplets, required, 1..1000;
  `protocolConformant` requires 50 plus the recorded arm/fixture/endpoint gates, which cannot
  prove operator/backend independence) and `--b-max` (required) are validated. Stops:
  `RPC_DISAGREEMENT` 20, `PASSPORT_DRIFT` 21, `CONSERVATION_MISMATCH` 22, `EVIDENCE_CONTINUITY_MISMATCH` 28, `END_PASSPORT_ERROR` 29, `HASH_SELF_CHECK` 23,
  `BLOCK_NOT_ISOLATED` 24, `RECEIPT_DISAGREEMENT` 25, `ENTRYPOINT_MISMATCH` 26 (every arm and the account must be bound to the same EntryPoint; `--expect-entrypoint` pins its address); attempt budget exhausted 10.
- **`validate.mjs`** re-reads the JSONL and recomputes every verdict, hash, A/B equality,
  conservation identity, matched-triplet count and Passport drift with its own decoder (it does
  not import `gauge-lib.mjs`); missing fields fail closed (exit 2). These are offline
  consistency checks within the decided scope above, not independent on-chain replay.
- **`rpc-proxy.mjs`** is the local endpoint B (pass-through, or `--tamper-*` for control d);
  `negative-controls/run.sh` runs all controls and the N=50 mechanism run.

The sections below describe the earlier mechanism dry-run; its commands are superseded by the
archive README above where they differ (`--rpc-a/--rpc-b/--count/--b-max/--out` are now required).

## What's here

- `deposit-guard.mjs` — RDR-6 ① deposit-floor guard as pure functions: `F = B_max *
  gasLimitSum * maxFeePerGasCeiling` (gasLimitSum includes `preVerificationGas`, matching
  EntryPoint's own `_getRequiredPrefund`); before every send, if `deposit - estimatedCost < F`,
  the op is withheld and recorded as `{skipped: true, reason: 'DEPOSIT_FLOOR'}`, never sent.
- `collector.mjs` also classifies every `handleOps` revert it observes (via a read-only
  `simulateContract` preflight before broadcasting, and a same-block replay if a tx is mined but
  reverted anyway) by decoding EntryPoint's `FailedOp`/`FailedOpWithRevert` reason string: only
  `"AA31 ..."` (deposit too low — the guard should have prevented this) is
  `{infraFailure: true, sponsorshipFailed: false}`, counted apart from a paymaster's own failure
  rate. Every other reason (`"AA33 reverted"`, `"AA34 signature error"`, etc.) is the paymaster's
  OWN validation decision — `{infraFailure: false, sponsorshipFailed: true, revertReason}` — and
  counts toward that paymaster's sponsorship failure rate, not infra. A revert whose reason can't
  be decoded at all falls back to `infraFailure: true` (never silently counted as "the paymaster
  said no" when we don't actually know that).
- `build-baseline.sh` — compiles an UNMODIFIED eth-infinitism v0.7 sample paymaster
  (`VerifyingPaymaster` or `TokenPaymaster`) in a throwaway foundry project, because
  `TokenPaymaster` imports `@uniswap/v3-periphery`, which this repo does not vendor and must
  not be forced to. Generalizes `script/b-layer/f1-build-tpm.sh`'s technique (kept there
  unmodified — existing F1 evidence reproduction depends on its exact invocation).
- `artifacts/` — the two compiled baseline artifacts (abi + creation bytecode + source sha256),
  produced by `build-baseline.sh`. Regenerate: see command block below.
- `deploy-baselines.mjs` — deploys both baselines on a local anvil, staked (1 ETH /
  86400s, matching this repo's own SP anvil convention) and deposited (10 ETH). Reads
  `entryPoint` from the target deploy's own `deployments/config.*.json` — a plain
  `deploy-core anvil` run does NOT put EntryPoint at the canonical singleton address
  (`0x0000...7da032`); that address only exists on chains that pre-fund the ERC-2470
  deterministic deployer at genesis (as `script/b-layer/`'s own fixtures do).
- `collector.mjs` — the driver: one-time sender setup (a `SimpleAccount`, funded with xPNTs and
  the TokenPaymaster's own test ERC-20, and made SP-sponsorship-eligible), then drives `--count`
  ops through SP, VerifyingPaymaster and TokenPaymaster in turn, guarding every send, writing one
  JSONL row per op to `--out`.

## Why sender setup is done here, not via `script/gasless-tests/`

`prepare-test anvil` provisions SP *operators* (deployer, Anni), not a sender smart account —
D7's own phase-2 fork hit the same gap. Rather than depend on D7's test-only fixtures (kept
untouched per this deliverable's scope), this collector creates and funds its own `SimpleAccount`
directly. SBT eligibility (`SuperPaymaster.sbtHolders`, set via `SuperPaymaster.updateSBTStatus`,
`onlyRegistry`) is granted by impersonating the Registry address on the local anvil and calling
the exact same setter the real `Registry.safeMintForRole` path would call — not a fabricated
storage write, just skipping the community/role/staking bootstrap that path also requires, which
is out of proportion for a mechanism smoke test.

## Historical dry-run (verified working end to end)

The following commands record the 2026-09-16 mechanism run, not the current CLI or a formal
A6 procedure. Current local collection requires `--rpc-a`, `--rpc-b`, `--count`, `--b-max`,
`--out` and `--allow-same-endpoint-local` with different local ports. Formal A6 is blocked by
the missing capabilities listed above.

```bash
export PATH="$HOME/.foundry/bin:$PATH"
anvil &                                            # fresh local chain
./deploy-core anvil --force && ./prepare-test anvil

# Rebuild baseline artifacts only if singleton-paymaster's samples changed:
#   script/a6-collector/build-baseline.sh <workDir> VerifyingPaymaster script/a6-collector/artifacts/VerifyingPaymaster.json
#   script/a6-collector/build-baseline.sh <workDir> TokenPaymaster script/a6-collector/artifacts/TokenPaymaster.json <@uniswap node_modules dir>

node script/a6-collector/deploy-baselines.mjs http://127.0.0.1:8545 script/a6-collector/dryrun-output/baselines.anvil.json
node script/a6-collector/collector.mjs --rpc http://127.0.0.1:8545 --count 2 --b-max 1
```

Confirmed (2026-09-16, this branch): all three paymasters (`SP`, `VerifyingPaymaster`,
`TokenPaymaster`) sponsor a real `handleOps` call successfully and produce a correct JSONL row
each. The deposit-floor guard was deliberately forced (`--b-max` set high enough that `F` exceeds
every paymaster's 10 ETH deposit) and verified to withhold all three ops — confirmed both via the
JSONL log (`skipped: true, reason: 'DEPOSIT_FLOOR'`) and by checking on-chain that the block range
covering that run contains zero transactions to the EntryPoint address (nothing was broadcast).

One SP-side finding surfaced during the dry-run, unrelated to D7 but worth flagging for whoever
tunes real gas limits later: `TestAccountPrepare.s.sol` only deposits 1,000 aPNTs into the
deployer operator's SP collateral by default, which is INSUFFICIENT_BALANCE at this dry-run's
(deliberately generous) gas limits — `collector.mjs`'s sender setup tops it up to 5,000 aPNTs.

**What "AA31/AA33 verified" does and does NOT mean (DSR review, 2026-09-17).** During
development, `classifyRevert`'s discrimination (AA31 → `infraFailure`, AA33/AA34 →
`sponsorshipFailed`, not infra) was proven against two genuinely forced, independently
confirmed on-chain reverts: a paymaster's EntryPoint deposit drained below what an op needed
(real AA31), and TokenPaymaster's test-token allowance drained to zero for the sender (real
AA33) — each confirmed via a raw `eth_getTransactionReceipt` call, not just the collector's own
log. **Both were produced with temporary, since-removed debug-only env-var hooks** (to bypass
the deposit-floor guard and to stop the sender's automatic token top-up) that exist in neither
this commit nor any other — running the exact `collector.mjs --count N --b-max B` command above
will only ever produce the happy-path or guard-withheld outcomes, never AA31/AA33, because
`collector.mjs` has no built-in failure-injection feature. Whether/how to inject failure
scenarios is campaign scenario-mix configuration (§8.4), to be recorded before a formal window
under the decided scope above. Do not read
"the classifier was verified" as "this artifact demonstrates AA31/AA33 handling on a plain
re-run" — those are two different claims and only the first is true of the code as shipped.

## Campaign configuration to record before formal A6

Seeder `dc7d0fab` has decided the trust root, scope and 50-triplet acceptance requirements.
The following operational choices do not reopen that decision and are not supplied by the
historical dry-run:

- Real `B_max` (this file's placeholder is `1`, chosen only so `F` is a nonzero, checkable
  number in a dry-run — it is not a considered value).
- Scenario / failure-injection mix (this dry-run only exercises the "everything succeeds" and
  "everything withheld by the guard" cases — no partial failures, no AA33/AA34 injected samples,
  no rate-limit/blocked-user scenarios).
- The formal evidence-registry mapping for the implemented Passport and per-operation fields,
  extended to the raw-response and DSR re-fetch requirements in [A6-SOP.md](A6-SOP.md).
  The current JSONL does not supply that complete formal evidence package.
- Top-up bookkeeping (plan: "只能在窗口之间由协议账户按固定额度补充，每次补充都登记") is an
  operational/runbook step, not automated here.
- **Reporting for the "undecodable revert" fallback bucket** (DSR review, 2026-09-17):
  `classifyRevert`'s default when a revert reason can't be decoded at all is `infraFailure:
  true` — a conservative fallback, not a confirmed AA31. When the real sample protocol runs,
  this bucket must be counted and reported SEPARATELY from genuine decoded-AA31 infra failures,
  not silently merged into one "infrastructure failure" total — an undecoded revert could be a
  bug in this collector, a new EntryPoint error shape, or something else entirely, and merging
  it with AA31 would misattribute causes future readers can't recover from the aggregate number.

Round-3 offline validation: local runs now require different RPC ports and the explicit
`--allow-same-endpoint-local` override. Such runs are mechanism evidence with
`protocolConformant: false`; the two local ports cannot establish provider independence.
See [offline review](offline-review/README.md) for tampering controls and changed archive verdicts.
