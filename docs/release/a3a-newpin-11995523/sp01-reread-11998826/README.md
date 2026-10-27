# AOA-SP-01 evidence: identity map, live re-read at 11,998,826, negative-control pointers

Answers DSR CC-125 `9247a817` items 1–3 for the A3a packet `../a3a-plan/plan.json`
(sha256 `9b1e2e01dbd092ec2e3fdb21bca51e29c2ce4606cc6cf06126b9063e7cdcd1ad`). Read-only: nothing here was
signed or broadcast, and no shared Sepolia state was written. HOLD-R-AMS is unchanged. This bundle is not an
execution authorisation.

## 1. Identity map and applicability

| input | A3a packet | upgrade rehearsal (`../boot`, `../indep`) |
|---|---|---|
| repo commit of the run | `66df75ee` (`repoCommit` in every `simulate.log`, `dirtyCount` 0) | `66df75ee` (same runs) |
| commit the artifacts are compiled from | `66df75ee` (`plan.json` `rebuild.commit` = `rebuild.tempTreeCommit`) | `fbd74fb1` (`CANDIDATE`, `script/upgrade/sp_upgrade_exec.py:21`; `boot/plan.json` `rebuild.commit`) |
| compiler | forge 1.7.1 `4072e487`, profile `default`, solc 0.8.33 (from `foundry.toml`) | forge 1.7.1 `4072e487` (`rebuild.forgeVersion`) |
| fork engine | foundry nightly `4e8874b2` (`engineCommit` in `simulate.log`) | same |
| executor script | `script/a3a/a3a_exec.py` sha256 prefix `890678541b934139`, identical at `66df75ee` and `30e26c41` | `script/upgrade/sp_upgrade_exec.py` `caba4b81ecbc54fe`, identical at both |
| compiled sources | `plan.json` `artifactSources` (per-file keccak, `contracts/src` + `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2`) | per-contract identity in `boot/plan.json` `rebuild.contracts` |

**Between `fbd74fb1` and `66df75ee`** (`git diff --name-only fbd74fb1 66df75ee`):
- `contracts/src`, `foundry.toml`, `contracts/lib` and the pinned gitlinks are identical.
- The only `.sol` changes are under `contracts/test/rams/` and under `docs/`.
- `singleton-paymaster/` differs only in seven npm/yarn metadata files: `yarn.lock` under
  `lib/account-abstraction-v6|v7|v8`, `package-lock.json` under `lib/openzeppelin-contracts-v4.8.3|v5.0.2|v5.1.0`,
  and `lib/openzeppelin-contracts-v5.1.0/package.json`. Two of those directories do feed compilation:
  `openzeppelin-contracts-v5.0.2` feeds A3a and `account-abstraction-v7` feeds SP. But forge reads only their `.sol`
  files, and no `.sol` file under `singleton-paymaster/` changed
  (`git diff --name-only fbd74fb1 66df75ee -- '*.sol'` lists only `contracts/test/rams/` and `docs/`).
- Everything else is scripts (`script/`, `scripts/`), workflows, tests, docs, `README.md`, `CHANGELOG.md`,
  `.gitignore`, and npm metadata outside the Solidity tree: `package.json` and `pnpm-lock.yaml` under
  `packages/x402-facilitator-node/` and under `script/gasless-tests/`. None of them is a forge input.

This is a source-level comparison, not a rebuild.
- The A3a executor recompiles `66df75ee` from its git archive and compares runtime bytes with local `out/`
  (`rebuild_*` gates).
- The upgrade executor's `build()` compiles `CANDIDATE` (`fbd74fb1`) and uses those artifacts directly, with no
  comparison against local `out/`. The implementation bytes therefore come from the `fbd74fb1` build itself and do
  not depend on this equivalence.

**Between `66df75ee` and `30e26c41`** (the current `origin/main`), the only changed paths are this packet's
files under `docs/release/a3a-newpin-11995523/`, from #539 and #540. No code, script or build input changed.

The archived runs were produced on final code, which already includes the daemon-thread RPC deadline from
#536–#538, so no fork run was repeated for this delivery. What has changed since the pin is chain time. Section 2
re-reads the live state for that.

## 2. Live state at block 11,998,826 (finalized, hash `0xe291b2f8…cdd741`), two endpoints

Endpoint A is Alchemy (archive) and endpoint B is the Tenderly public gateway. URLs are not stored.

| file | script | exit | result |
|---|---|---:|---|
| `senders-11998826.json` | `script/evidence/a3a-newpin-senders-reread.py ../a3a-plan/plan.json` (new) | 0 | 22/22 checks true (refuses RPC_A == RPC_B; owners decoded only in canonical ABI form; threshold must be 2) |
| `reread-11998826.json` | `script/evidence/a3a-v4-reread.py ../../a3a-precheck-v4/cap-budget-evidence.json` | 0 | 17/17 checks true |
| `cap-budget-11998826.json` | `scripts/a3a-v2-cap-budget-read.py` | 0 | 6/6 checks true |

| item | at pin 11,995,523 | at 11,998,826 | latest = pending now, both endpoints |
|---|---|---|---|
| chain id | 11155111 | 11155111 | — |
| deployer `0xb560…df0e` | nonce 12131, 12.161907553052084158 ETH | same nonce, same balance | 12131 |
| approver `0x8c34…73d6` | nonce 7, 1.089121108158622069 ETH | same | 7 |
| executor `0x8716…fb48` | nonce 29, 122.783596408724861280 ETH | same | 29 |
| Safe `0x51eD…E114` | nonce 1, owners = plan, threshold 2 | same | latest 1 |
| predicted timelock / APNTsCapped | codesize 0 | codesize 0 | — |
| SP owner / pendingAPNTsToken | deployer / `0xbb46…9883` | same | — |

- **Budget against balance at 11,998,826.**
  - Deployer: A3a 0.4940 + upgrade 1.3891 = 1.8831 ETH, against 12.1619 ETH.
  - Approver: 0.0071 ETH, against 1.0891 ETH.
  - Executor: 0.0081 ETH, against 122.78 ETH.
- **Exposure, cap and price** (`cap-budget-11998826.json`). Every read value, all 41 log ids, and the mint/burn
  sums equal the v4 read at 11,961,849, field by field. Only the block hash and timestamp differ.
  - Old aPNTs totalSupply: 12,734,489.0087…; 10,000,000 of it sits at `0x42ba…3e22`.
  - SP EntryPoint deposit: 0.09347083 ETH, the same on both endpoints (`sp-deposit-11998826.json`, `cast call`).
  - `cachedPrice` is still the stale value from v4 (updatedAt 1790488836), now about 29 days old. A3a does not
    read it. It belongs to the later live upgrade packet.
  - The budget reasoning in `../../a3a-precheck-v4/CAP-BUDGET.md` therefore still applies unchanged.
- **Funding (DSR gap IG-04).** The +10 ETH came from transaction
  `0x1bf66ae42dcb55c7b4fa37f2ed39604faf1b31dd1d52e5395971dc78a3417495`, mined in block 11,995,503 (hash
  `0x37a39e61…b33dd`, 20 blocks before the pin).
  - It was sent by the executor `0x8716…fb48` (its nonce 28) to the deployer, value 10 ETH, status 1, gas 21,000.
  - The deployer's balance went 2.161907553052084158 → 12.161907553052084158 ETH at nonce 12131. It is unchanged
    from then to the pin.
  - The receipt's only log is the Amsterdam EIP-7708 ETH-transfer log: emitter `0xff…fe`,
    `Transfer(executor, deployer, 10e18)`.
  - The executor balance in the plan pin is the balance after this transaction.
  - Two endpoints, 13/13 checks (bound to the plan's chain id and pin hash; tx, receipt and block identity cross-checked): `funding-provenance.json`, from `script/evidence/a3a-funding-provenance.py`.
    Its offline controls are in `script/evidence/test_a3a_funding_provenance.py` (5 tests: 17 table cases plus pin-at-funding-block, endpoint divergence and same-endpoint refusal;
    setting each of the 13 checks to `True` turns the suite red).
  - The funding is not a packet step.
- **Pending values at plan time (DSR gap IG-03).** The archived packet does not record the `pending` nonces seen
  when the plan was built. They can only be inferred from the plan having been produced, because `plan` refuses
  unless pin nonce == pending (`a3a_exec.py:679,706`) and rechecks after the rehearsal (`pin_recheck`,
  `:1530`). This is a limitation of the historical record, and the packet is not rebuilt for it.
  `senders-11998826.json` records explicit `latest` and `pending` values for every sender on both endpoints, and
  any later re-read keeps doing so.
- **Endpoints and method (DSR gap IG-02).** Endpoint A is an Alchemy Sepolia archive endpoint; the key is not
  published. Endpoint B is the public `https://sepolia.gateway.tenderly.co`. The three scripts and the methods
  they call are listed in each script's docstring. For an independent re-read, DSR can substitute any two
  archive endpoints.
- **Drift STOP.** Any of the 22 + 17 checks turning false means STOP and a rebuild at a new pin. Before every
  live step, the executor's own guard `pre_send` (`script/a3a/a3a_exec.py:1323-1336`) re-reads chain id, code,
  latest = pending = planned nonce and the Safe nonce. This re-read is evidence. It does not replace that guard.

## 3. Negative controls

**New script, live (`negctl/`).** Each control mutates one plan field in a scratch copy and re-reads the live
block. Every one exits 1, and only the intended checks turn false:

| control | false checks |
|---|---|
| `approverNonce` (8) | approver pin / unchanged / first-planned / latest=pending |
| `safeNonce` (2) | `safeNonceAtBlockMatchesPlan`, `safeNonceLatestNowMatchesPlanBothEndpoints` |
| `owner` (one owner replaced) | `safeOwnersMatchPlan` |
| `budget` (approver 2 ETH) | `approver_balanceAtBlockCoversBudget` |
| `pinHash` (zeroed) | `pinBlockHashMatchesPlan` |

**New script, offline (`script/evidence/test_a3a_newpin_senders_reread.py`, 9/9).** Fake endpoints serve the
recorded values. The positive control reproduces 22/22. The negative controls are:
- threshold 3 on both endpoints;
- non-canonical `getOwners` encodings, one per rule (offset, length, padding), each with its own refusal message;
- the same endpoint given twice;
- endpoint B diverging by 1 wei;
- a sender nonce moved since the pin;
- pending ahead of latest;
- the Safe nonce advanced;
- a balance below budget.

Each control asserts the exact set of false checks, or the exact refusal message. The first three were found
by Codex review before push. Mutating each fix away turns its test red.

**Executor gates: where each chain, pin, nonce and budget error is refused** (`script/a3a/test_a3a_exec.py`,
77/77 pass):

| error | gate | test |
|---|---|---|
| wrong chain at plan time | `chain_id` | `test_distinct_preflight_gates` |
| sender latest ≠ pending at plan time (deployer, approver, executor) | `deployer_nonce_pending`, `approver_nonce_pending`, `executor_nonce_pending` | same |
| Safe owners or threshold differ | `safe_owners`, `safe_threshold` | same |
| deployer balance below the early floor | `deployer_budget` | same |
| per-sender budget and fee caps | `plan_budget(s)` | `test_each_sender_has_its_own_budget`, `test_both_budget_fields_recomputed`, `test_final_budget_uses_planned_limits_and_fee_caps` |
| state drift during the plan rehearsal | `pin_recheck` | **new** `test_pin_recheck_refuses_drift_during_rehearsal` |
| live state ≠ frozen pin when replaying a plan | `simulation_pin` | **new** `test_simulation_pin_refuses_live_drift` |
| wrong chain at send time | `pre_send_chain` | **new** `test_pre_send_chain_and_safe_nonce` |
| Safe nonce ≠ planned at send time | `pre_send_safe_nonce_<step>` | **new** `test_pre_send_chain_and_safe_nonce` |
| pending ≠ latest, or latest ≠ planned, at send time | `pre_send_pending_<step>`, `pre_send_nonce_<step>` | `test_pre_send_pending_nonce_and_fresh_gas`, `test_pre_send_s4_requires_chain_predecessor_readback` |
| edited frozen plan, or hash mismatch | `plan_step_*`, `plan_hash` | `test_frozen_simulation_is_independent`, `test_tampered_plan_cli` |
| local fork at the wrong block | `local_engine_fork_block` | `test_local_engine_authentication` |
| on-chain wrong Safe nonce or early execute (mined, reverted) | fork controls | `../a3a-sim/simulate.json` `negativeControls` |

Before this delivery, four gates had no test of their own: `pin_recheck`, `simulation_pin`, `pre_send_chain` and
`pre_send_safe_nonce_`. Each now has one. The check was a mutation run: removing a gate's `need(...)` turns that
gate's new test red, and restoring it turns the test green again. For `pre_send_safe_nonce_`, the
`pre_send_chain` subtest in the same test stays intact under that mutation, so the red comes from the Safe-nonce
subtest.

**Not covered.**
- `fork_block_hash` (`a3a_exec.py:985`) has no unit test. It compares the local fork's block hash with
  `pin.blockHash` and fires only inside a real engine. The archived runs passed it, and the new reread checks the
  same hash independently (`pinBlockHashMatchesPlan`).
- Live sending stays disabled, so `pre_send` has run only against local forks and fakes, never against Sepolia.

## 4. Open for the author, not decided here

- **Nonce exclusivity owner.** Which automation shares the deployer EOA, who pauses it, and when it may resume.
  The proposed rule: pause before S1, resume only after S7 is confirmed and the live upgrade plan has been rebuilt.
  Resuming earlier forces another rebuild.
- **Signers.** How the approver and executor transactions, and the Safe owner approvals, are signed. The executor
  has no signing path.
- **Service stop and resume.** A3a itself does not pause SP. The pause and pre-restore readback belong to the later
  live upgrade packet. Its `boot/` rehearsal covers them and ends with the service still `PAUSED`
  (`script/upgrade/sp_upgrade_exec.py:823`, `service='PAUSED'`). Resuming service is not rehearsed here. It is a
  separate packet.

## Reproduce

```sh
RPC_A=<archive rpc> RPC_B=https://sepolia.gateway.tenderly.co BLOCK=11998826 \
  python3 -B script/evidence/a3a-newpin-senders-reread.py docs/release/a3a-newpin-11995523/a3a-plan/plan.json
RPC_A=<archive rpc> RPC_B=https://sepolia.gateway.tenderly.co BLOCK=11998826 \
  python3 -B script/evidence/a3a-v4-reread.py docs/release/a3a-precheck-v4/cap-budget-evidence.json
RPC_A=<archive rpc> RPC_B=https://sepolia.gateway.tenderly.co BLOCK=11998826 python3 -B scripts/a3a-v2-cap-budget-read.py
(cd script/a3a && python3 -B -m unittest test_a3a_exec)          # 77 tests OK
(cd script/upgrade && python3 -B -m unittest test_sp_upgrade_exec)  # 141 tests OK
(cd script/evidence && python3 -B -m unittest test_a3a_newpin_senders_reread)  # 10 tests OK
(cd script/evidence && python3 -B -m unittest test_a3a_funding_provenance)  # 5 tests OK
RPC_A=<archive rpc> RPC_B=https://sepolia.gateway.tenderly.co python3 -B script/evidence/a3a-funding-provenance.py \
  docs/release/a3a-newpin-11995523/a3a-plan/plan.json 0x1bf66ae42dcb55c7b4fa37f2ed39604faf1b31dd1d52e5395971dc78a3417495
```

`SHA256SUMS` covers every file here except itself and this README.
