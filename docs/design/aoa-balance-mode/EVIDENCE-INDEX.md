# AOA / SP 5.5.0 证据索引（机器可读）

对应 DSR 人工登记册 `AOA_Evidence_Register_2026-09-13.md`（DSR-Research-Flow，paper3 report/）。本表给出登记册 §1–§2 每个数字的**原始数据文件、字段或行号、产生它的 commit 和复现命令**；没有原始数据的，标 **MISSING** 并写明原因。原始数据的格式说明见 [`data/README.md`](data/README.md)。

**完整性校验**：`cd docs/design/aoa-balance-mode && shasum -a 256 -c EVIDENCE.sha256`。F1 冻结集是独立的一组，单独校验：`cd b-layer && shasum -a 256 -c F1-EVIDENCE.sha256`（本次复核 22/22 OK；本索引只引用它，没有改动其中任何文件）。`EVIDENCE.sha256` 与本表 sha256 列由 `node script/evidence/build-manifest.mjs` 生成。

## 0. 先读这一段：哪些是真实链上数据

- **SP 5.5.0 在任何公网上都还没有交易。** 下面所有 `local-anvil` 和 `fork-simulation` 行里的交易哈希**只存在于产生它们的那条本地节点上**（那条节点已经关掉），**在 Sepolia、OP 主网或任何区块浏览器上都查不到**。它们只能作为"本地复现记录"引用，不能写成链上证据。
- `onchain-real`：公链上已经上链的交易，本次只读取回（任何浏览器可查）。目前只有 5.5.0 之前的历史交易。
- `onchain-readonly`：对公链的只读 JSON-RPC 查询（没有交易）。
- `unit-test`：forge 进程内 EVM 的测试输出。
- `spec-freeze`：规范冻结版本的 commit 与文件 sha256（不是实验数据；用于证明论文与 runbook 引用的是哪一版规范）。
- `HISTORICAL-VOID`：原稿（`910d1f7` 那一代合约）的 OP 主网数据，**重投时作废**，只作拒稿前存档。

"this commit" 指提交本索引的那个 commit（父 commit `df941d57`）。本 commit 对 `contracts/` 的唯一改动是 G2 fuzz 的导出钩子（环境变量不设时不生效，见 §1 U-01）；`contracts/src`、`foundry.toml` 未改。

## 1. 证据条目

| id | category | producing commit | file path（字段 / 行） | reproduction command | sha256 |
|---|---|---|---|---|---|
| R-01 | onchain-real | 链上：Sepolia 块 11,228,198 / 11,228,202 / 11,228,783；取回：this commit | `data/onchain-real/sepolia-5.4.x-upgrade-txs.json`（`transactions[]`：`recordLabel` = 部署记录里的说法，`observed` = 链上实际是 CREATE 还是 CALL） | `node script/evidence/fetch-public-receipts.mjs env:<.env.sepolia> <out> <label=hash>…`（只读；含 key 的 URL 不落盘） | sha256(data/onchain-real/sepolia-5.4.x-upgrade-txs.json)=1242d0e0cee283588dfddec6beaf2813a29ca6bc22f15198fe51585dd4557ad2 |
| R-02 | onchain-real（地址记录） | `b6438d35` | `../../../deployments/config.sepolia.json`（`.superPaymaster` L31、`.registry` L23） | — | 不入清单（在用的配置文件，会随部署更新） |
| R-03 | HISTORICAL-VOID | aastar-sdk `2db405ec`（2026-09-07） | `aastar-sdk/packages/analytics/data/paper_gas_op_mainnet/*/*.csv`（外部仓库，只引用，不复制） | `wc -l`、`shasum -a 256`（见 §2 R-03 子表） | 见 §2 子表（外部文件不入本清单） |
| O-01 | onchain-readonly | `d950e416` | `rehearsal/step0-inventory.json`（`.events`、`.crossCheck`、`.state`、`.range`、`.positiveControl`） | `node script/rehearsal/inventory.mjs <.env.sepolia> https://ethereum-sepolia-rpc.publicnode.com <out>` | sha256(rehearsal/step0-inventory.json)=ae3f8d25973b9da3b1d31c76e00722db64057cb00bcbe95526926e7d07310602 |
| O-02 | onchain-readonly | this commit（2026-09-13T03:57Z 查询） | `data/onchain-readonly-fork-level-probes.json`（`.summary.chains.*`；`.raw[]` 为逐条请求 / 响应原文） | `anvil --port A --hardfork prague & anvil --port B --hardfork osaka & node script/evidence/fork-level-probes.mjs <out> http://127.0.0.1:A http://127.0.0.1:B` | sha256(data/onchain-readonly-fork-level-probes.json)=9d9d7bbef6e3afae345cf3f72594e674d829909ac1fdcae7c95a06ca0cdb4a4a |
| O-03 | onchain-readonly | `1072720b`（2026-09-06，块 11,646,729） | `../credit-switch/01-onchain-vs-local.md` L28–L49 | 文档 §0 的 `cast code` 比对流程 | **MISSING（原始 dump）**：只有文档表格，当时的 `cast code` 输出和比对脚本输出没有落盘 |
| O-04 | onchain-readonly | `60c1359b`（后续 `bd8dfafe` 改文字） | `repcredit-bytecode-profile-audit.md` §2–§3（L56–L58、L137） | 文档 §6 | **MISSING（原始 dump）**：同上，只有文档表格 |
| L-01 | local-anvil | this commit | `data/local/l4-balance-mode-op.receipts.json`（6 笔；`handleOps` = `0x22a14e8e…23af`，块 94，status 1）；`data/local/l4-L4GaslessTest-verify.log` L5–L10；`l4-L4GaslessTest-run.log`；`l4-gasless.anvil.snapshot.json`（模拟值）；`l4-broadcast-run-latest.json`；`l4-config.anvil.json` | 见 `data/README.md` §3（全新 anvil 1.7.1，chain 31337，`deploy-core anvil --force` → `L4GaslessTest --broadcast --slow --gas-estimate-multiplier 400` → `--sig verify()`） | sha256(data/local/l4-balance-mode-op.receipts.json)=9232e8fe1f6a6af368bfafab7b3084cb4f9d065159138bab9aff8d699fe23efa；sha256(data/local/l4-L4GaslessTest-verify.log)=893c720f240b66ec5622d9ee79b97cb97e5656dc0f8954772ee4f43765e71894 |
| L-02 | local-anvil | this commit | `data/local/l4-deploy-core.log.gz`（解压后：143 行 `default artifact OK`；L10105 `T-4 read-back: passed 46 failed 0`；L15131 `passed 50 failed 0`；exit 0） | `ANVIL_RPC_URL=http://127.0.0.1:<p> ./deploy-core anvil --force`（全新 anvil） | sha256(data/local/l4-deploy-core.log.gz)=cd54078ac8c4b043a1027d85cd62032f359388bba8f7909661f1c5e33f6f0248 |
| L-03 | local-anvil | `60130aa8`（首版），`0b69492c`（加 Osaka 矩阵） | `b-layer/b0/*.json`（12 个；每个 `.cases.<用例>.verdict / .error / .included`） | `b-layer/README.md` §3 | 见清单（`b-layer/b0/…`） |
| L-04 | local-anvil | `4ba1d546` | `b-layer/cases/access-check.json`（`.summary` 三个 trace 文件 34 / 36 / 36 条，`.positiveControl`）、`access-check.txt`、`rundler-results.json`（`.cases.B1…B10`、`.cases["B9-below"].error`）、`alto-results.json`、`altoMulti-results.json`、`b8-op070.json`、`setup.json`、`deploy.json`、`layouts/*` | `script/b-layer/g1-run.sh <workDir> <rundler> <alto125>` → `g1-collect.sh` | sha256(b-layer/cases/access-check.json)=242d82b7bfbdb8f6e2fb9399b2a01a15d8f2bd18ef97df855e6bb0398fab6391；其余见清单 |
| L-05 | local-anvil（F1 冻结组） | 数据 `c0d9e350`；清单 `c9d5af9b` | `b-layer/F1-EVIDENCE.sha256`（22 个文件：`cases/f1/*`、`F1-investigation.md`、`F1-erc7562-text.md`） | `script/b-layer/f1-run.sh` / `f1-collect.sh`；校验 `cd b-layer && shasum -a 256 -c F1-EVIDENCE.sha256` | sha256(b-layer/F1-EVIDENCE.sha256)=de51413eb876b79fbf39eea6994e14354c554f79da7a7f8a8cd06900d56c9be6（清单文件本身） |
| F-01 | fork-simulation | this commit | `data/local/fork-sepolia-11692260/A*`：A1 取消 0xBb46（`A1-cancel.receipts.json`）→ A2 GOV-1 形状 timelock → A3 `DeployAPNTsCapped`（`A3-*.receipts.json`、`A3-deploy-apnts-capped.log` L44 ALL PASS）→ A4 Safe schedule / +48h / execute accept（`A4-accept.receipts.json`）、`A4-verify.log` L26 ALL PASS → A5 重新排队 `setAPNTsToken`（**手工 cast，脚本未覆盖**；`A5-requeue.receipts.json`、`A5-readback.txt`） | `script/evidence/fork-rehearsal.sh <.env.sepolia> 11692260 <dir>`（本地 `anvil --fork-block-number 11692260`，chain id 11155111；不广播到 Sepolia） | sha256(data/local/fork-sepolia-11692260/A5-readback.txt)=ea0519c57f5ebfbb2148a8485bf6deb81dee8a0f9c29ca673a89189c54b5e8e9；其余见清单 |
| F-02 | fork-simulation | this commit | `data/local/fork-sepolia-11692260/B*`：B1 取消 → B3 暂停 → B4 `run()` 严格模式（第 4 → 5 → 5b → 6 步，13 笔，`B4-run.receipts.json`；`B4-run.log` L38 `new impl runtime bytes: 22915`、L42 step-5 读回、L47 step-5b 1 ETH / 86400）→ B7a 发币 → B7c-1 `updatePrice` + `configureOperator` → B7c-2 解除暂停；`B7-readback.txt`（`creditPolicy = 0`、`getDepositInfo`） | 同上 | sha256(data/local/fork-sepolia-11692260/B4-run.receipts.json)=467c46e9b0453124c6711184c1c9f6737e4e8ab2732e56649d39c2afdd12ad5b；sha256(data/local/fork-sepolia-11692260/B7-readback.txt)=bbf9804991f84c9a8b5900e0d0aae00a60624a1ecb3803f9ca3857c50f1f1ab1 |
| F-03 | fork-simulation（只读） | this commit | `data/local/fork-sepolia-11692260/CheckDefaultArtifacts-config.sepolia.log` L3016 `T-4 read-back: passed 38 failed 13` | `script/evidence/check-default-artifacts-sepolia-fork.sh <.env.sepolia> 11692260 <out>` | sha256(data/local/fork-sepolia-11692260/CheckDefaultArtifacts-config.sepolia.log)=87cbf3689ae9a4500c56b9cee142845f1e994ff0d08ea932cef21f4d65cd3cae |
| U-01 | unit-test | this commit（树 = `df941d57` + 导出钩子；fuzz 与 fixtures 自 `7fa7b705` 起未改，`contracts/src` 自 `a3eb0945` 起未改） | `data/g2-main-7fa7b705-oldformula.jsonl`（6,055 行 = 4,389 结算 + 1,666 注入失败；字段见 `data/README.md` §1） | `G2_EXPORT_PATH=cache/g2-export.jsonl forge test --match-path contracts/test/v2/SuperPaymasterV55Fuzz.t.sol --match-test test_G2_coverage_replay_fixed_seeds -vv`（重跑逐字节相同） | sha256(data/g2-main-7fa7b705-oldformula.jsonl)=0dd700998de6093c724b7dd83ee0484f9044558c6069fd3a34ef53e3657fc1a8 |
| U-02 | unit-test（重算） | this commit | `data/g2-main-7fa7b705-oldformula.stats.txt` L7–L9、`.stats.json`（`.groups[]`） | `node script/evidence/overpay-stats.mjs docs/design/aoa-balance-mode/data/g2-main-7fa7b705-oldformula.jsonl [--json]`（在仓库根目录执行；本表所有命令都从仓库根目录执行） | sha256(data/g2-main-7fa7b705-oldformula.stats.txt)=aecd06a4d25bf03c1ad3b7f8a6cc094371297c7e2939680f650a12bf6481920c；sha256(data/g2-main-7fa7b705-oldformula.stats.json)=d91bdb9b62e971857a9c96829a0fdf427541cf9d7a31f42186ba4d9193273db6 |
| U-03 | unit-test | this commit | `data/g2-main-7fa7b705-oldformula.forge.log` L11–L43（`_report` 全部计数）；`data/g2-main-export-off.forge.log` L8–L10（导出关闭，三个 G2 测试） | 同 U-01；关闭导出：`forge test --match-path contracts/test/v2/SuperPaymasterV55Fuzz.t.sol -vv` | sha256(data/g2-main-7fa7b705-oldformula.forge.log)=371d33ae8426f9b16302c59fd52e3d4603acd723fb2c6432149c9bb9b9cae584；sha256(data/g2-main-export-off.forge.log)=d00e722b8e76d63c7297b00a7c0257bfd59618bc40772ce2f3cb12a754c7d002 |
| U-04 | unit-test | this commit（HEAD 树） | `data/g-layer/V55Gas-wrap-and-charge.log` L25–L35（wrap 上界）、L10–L21（charge ≥ need） | `forge test --match-path contracts/test/v2/SuperPaymasterV55Gas.t.sol -vv` | sha256(data/g-layer/V55Gas-wrap-and-charge.log)=a10b06f41b60c36fc7538126274a28bb72d1988e2ce334e3cbf4593cd453739d |
| U-05 | unit-test | this commit（HEAD 树） | `data/g-layer/V55-full-file.log` L13（实测 postOp 140,770）、L19–L20（T-R14-09 两条）、L8（no-OOG band） | `forge test --match-path contracts/test/v2/SuperPaymasterV55.t.sol -vv` | sha256(data/g-layer/V55-full-file.log)=82deac1faf40cce4c67e498f0a33cec95ac687e3b177ea634319925d6bf37827 |
| U-06 | unit-test | `c5fc803c`（`git archive`，未改动） | `data/g-layer/c5fc803c-V55-postOp-measured-cancun.log` L10、`…-prague.log` L10（均为 140,770） | 在 `git archive c5fc803c` 的树里：`forge test --match-path contracts/test/v2/SuperPaymasterV55.t.sol --match-test test_G_min_post_op_gas_covers_measured_postOp -vv [--evm-version prague]` | sha256(data/g-layer/c5fc803c-V55-postOp-measured-cancun.log)=bc2b57a6172d8819f69497657aafc00d9b154aa8d294cadcd603f48a635c5eee；sha256(data/g-layer/c5fc803c-V55-postOp-measured-prague.log)=eaf585ae5aefa6c3b5253d11c79c6f15d79b651bd79aeead1f33430593bf5236 |
| U-07 | unit-test | this commit（HEAD 树） | `data/g-layer/V55Adversarial-TR1407-gas-sweeps.log` L10、L14–L15（直接调用扫描：入口守卫 108 / 其他 revert 0 / 成功 73，最小成功 gas 168,000） | `forge test --match-path contracts/test/v2/SuperPaymasterV55Adversarial.t.sol --match-test test_TR1407_ -vv` | sha256(data/g-layer/V55Adversarial-TR1407-gas-sweeps.log)=a56bfdc5a15b56672ee1f83bafae423da53b055cb102f13d0f06e0056a84f52f |
| U-08 | unit-test | this commit（HEAD 树） | `data/g-layer/PoC_C04-min-gas-floor.log`（MIN_POST_OP_GAS 的第二份独立证据） | `forge test --match-path contracts/test/security/PoC_C04_ForcedPostOpOOG.t.sol -vv` | sha256(data/g-layer/PoC_C04-min-gas-floor.log)=e6d1c1d0f96ba4e3fd34db7b33843a17ddaf9c8a9593d34696b4744ac54f2477 |
| U-09 | unit-test | `31921fbc`（exp/buffer-and-params Part A；`git archive`，未改动） | `data/g-layer/31921fbc-exp-partA-PostOpBound.log` L27（W_postop 146,600）、L14（CREDIT 首次用户路径）、L28–L31（C_POSTOP 170k ≥ 146,600 × 1.15 = 168,590；wrap 1,702 ≤ 5k） | 在 `git archive 31921fbc` 的树里：`forge test --match-path contracts/test/v2/SuperPaymasterV55PostOpBound.t.sol -vv` | sha256(data/g-layer/31921fbc-exp-partA-PostOpBound.log)=3e654ea66fc2bb7ce0a2fd3af450130c4168c3e36e3a4030c97304e8ccd2d662 |
| U-10 | unit-test | this commit（= `a3eb0945` 的 contracts 树 + 导出钩子） | `data/unit-test/forge-test-cancun.log` 末行：126 个套件，1600 passed / 0 failed / 49 skipped | `forge test`（Cancun，导出钩子关闭） | sha256(data/unit-test/forge-test-cancun.log)=c6d3aa2b01cf8fb8b254814f34e602558c25e622952ab44e2b62f8e4ef211671 |
| U-11 | unit-test（构建产物） | `3b0d4821` / `c5fc803c` / `3e7ddd9a` / this commit / `31921fbc` | `data/sizes/sizes-*.json`（`.rows[]`：按产物自身 metadata 选 runs / evm，`sourceKeccakMatchesTree` 核对源码） | `node script/evidence/sizes.mjs <树根>`（历史 commit 用 `git archive` + `forge build`） | sha256(data/sizes/sizes-3b0d4821-sp542-baseline.json)=c3bd07ff38fef7ed525d29359385a3f155be4661a93e403787886cf4b4c29273；sha256(data/sizes/sizes-c5fc803c.json)=997cbcfe1a3dfc9fe67e4875be69d533033e625ddefd9ecd91ee91a89d5a0ab1；sha256(data/sizes/sizes-3e7ddd9a.json)=cd96208bc48aaaf5264fb09e0863efdc9802a0cf4a53ae7fc6e9cdffbd2b9a28；sha256(data/sizes/sizes-df941d57.json)=b13bbd7dd202d223ab2403e9dbf701e987f188175b90be584fa2f2761a01a064；sha256(data/sizes/sizes-31921fbc-exp-partA.json)=5955c1e346c14ca1076c1ab436ade5c0ca37b2ea2db3eead77a79db822e56b68 |
| U-12 | unit-test | Part A = `git archive 31921fbc` + 导出钩子（`data/g2-31921fbc-partA.hook.diff`）；Part B = `6c3a9a0e`（exp/buffer-and-params，已合入本分支） | `data/g2-31921fbc-partA.jsonl`、`data/g2-6c3a9a0e-partB.jsonl`（各 6,069 笔 = 4,398 结算 + 1,671 注入失败；`formula` 标签 `A_Cpostop170k_Cwrap5k` / `B_Cpostop175k_Cwrap5k_default`）+ `*.stats.txt/json` + `*.forge.log`；变异证据 `data/mutations/`（b-nolen-asm 等价变异、b-slice、c-384-as-legacy） | 见 `data/README.md` 末节「Part A / Part B exports」；`node script/evidence/overpay-stats.mjs <file>`（0 处不一致、0 补贴；重跑逐字节相同；Codex 第 5 轮复核通过） | sha256(data/g2-31921fbc-partA.jsonl)=fef179f9feddf086d350082909a811b4202dfbd441a1299187e9cc4625f3f694；sha256(data/g2-6c3a9a0e-partB.jsonl)=3f018408eb57b1ce702c9bc05218e05c21c2fa90c9eb360bf01b324f9b028c65 |
| T-01 | 模板 | this commit | `data/templates/p2-sepolia-runbook.csv`、`p4-deployments.csv`、`p4-op-mainnet-ops.csv`（只有表头；规范见 `03-final-spec.md` §6.1） | — | sha256(data/templates/p4-op-mainnet-ops.csv)=a882a46b1420aa921634327e04ae01d760f5088a7b2a180d8e49461eb0ac6b38 |
| S-01 | spec-freeze | `9213a1591552edeb0c1921a545a855294b3b1cd3`（2026-09-13；源码基线 `cbcb7045`；前一版 `70f8085f` 是合入前的草稿，已被本 commit 的补充取代，不作为冻结版） | `03-final-spec.md` **v4.0**（**已被 S-02 v4.0.1 取代**；改动清单见文件头的 v4.0 条目与"合入前的补充"） | `git show 9213a159:docs/design/aoa-balance-mode/03-final-spec.md \| shasum -a 256`（在仓库根目录执行）；当前工作树上的同一个值说明规范自冻结以来没有改动 | 03-final-spec.md v4.0 的 sha256 = `029e23bab5adba6315e73f92e5c47e63bc458723d0c135b77206c1427e5130df`（规范不在 `EVIDENCE.sha256` 的范围内，这个值只记在本行；**故意不写成 `sha256(路径)=` 的形式**，否则 `build-manifest.mjs` 会在规范日后修改时把冻结值静默改写成新值。以后的版本新增一行，不改本行） |
| S-02 | spec-freeze | `e91e3c56ba2d7d2ed417ea9e79b01d3ccb830edb`（2026-09-13；v4.0.1 勘误，**已被 S-03 v4.1 取代**；源码行号仍钉在 `cbcb7045`） | `03-final-spec.md` **v4.0.1**：只改 §10.7 SP owner 行与 §10.8 RDR-7 ①② 中 `slashOperator` 的上限描述（实为每次 ≤ 30%、queueSlash 在先、24h 冷却），见文件头 v4.0.1 条目；其余与 S-01 相同 | `git show e91e3c56:docs/design/aoa-balance-mode/03-final-spec.md \| shasum -a 256`（仓库根目录）；S-01 的值仍可用 `git show 9213a159:…` 复核 | 03-final-spec.md v4.0.1 的 sha256 = `0dc8f7b6b5f5d77792a07aee2eee92db1046f1ebfa32de5df7a8bf3a4e77fd4c` |
| S-03 | spec-freeze | `61ae4d9d`（2026-09-16；v4.1 勘误，取代 S-02 作为当前冻结版；D5c-1 有界符号验证发现，经 DSR 复核确认；源码行号仍钉在 `cbcb7045`，本版不涉及 §10.7/§10.8 的行号引用） | `03-final-spec.md` **v4.1**：不变量表 I2 行改为排除显式 ERC-20 `approve`、新增单步性质 I2-F、更正"累计 ≤ cap"的准确表述为"≤ 窗口内生效过的最大 cap"；§2.1 A-3 行改为"仅 `from ≠ msg.sender` 时 revert，SP 烧自己的余额（`burn(x)`/`burn(SP 自己,x)`）不受约束"，对应 D-A3-2；见文件头 v4.1 条目 | `git show 61ae4d9d:docs/design/aoa-balance-mode/03-final-spec.md \| shasum -a 256`（仓库根目录）；对应的 harness 判定见 H-01 | 03-final-spec.md v4.1 的 sha256 = `f32126d14959e7c2704f420ca6a48f48081dcdf3615cadeab19420a1b917d441` |
| D5B-01 | unit-test（构建产物） | D5b 分支 `d5b/core-admin-gov2`（本表所在 commit 的树） | `data/d5b/sizes/sizes-d5b.json`（`.rows[]`：SuperPaymaster 13,571 / SuperPaymasterAdmin 19,208 / Registry 23,306 / lens 5,329 / BLSAggregator 24,345，`sourceKeccakMatchesTree`）；`data/d5b/gates/check-sp-size.log`（核心余量 11,005 ≥ 1,024，self-test）；`data/d5b/sizes/variants.txt` + `gov2-monolith-variant.py`（D5b-design §1.1 第 1–5 行的变体） | `forge build && node script/evidence/sizes.mjs . SuperPaymaster=… SuperPaymasterAdmin=…`；`python3 scripts/check-sp-size.py --self-test` | sha256(data/d5b/sizes/sizes-d5b.json)=0824c7c829b6660c1ec0f0296d944f78c774cf2025bc35ef78ae8a7eebdce251；sha256(data/d5b/gates/check-sp-size.log)=733a4c3856f4a92b06a91f1a3e67e29bb35108520006d5f5cf5764caaf0afeb7 |
| D5B-02 | unit-test（门槛） | 同上 | `data/d5b/gates/check-sp-layout.log`、`check-sp-selectors.log`、`check_storage_layout-self-test.log`、`check_storage_layout-negative-control.log`、`check-live-scripts-compile.log`、`gen-sp-full-abi-check.log`、`check-abi-bundle.log` | 各文件第 1 行即命令 | sha256(data/d5b/gates/check-sp-selectors.log)=ad267637dc8286a673fe3a8a0037d9520e2a645542ed75c61029accd8cc9f038；sha256(data/d5b/gates/check_storage_layout-negative-control.log)=6b1f3dc32ec1695bfca4b1364440ececbb63a110aa3febf3553b148f97d0af46 |
| D5B-03 | unit-test（变异） | 同上 | `data/d5b/gates/mutation-matrix.log`（第 0 列 34 绿；(b)–(h) 每行的红列、盲列、RESULT；(e3) 等价变异）；`data/d5b/gates/mutation-matrix-recheck2.log`（Codex 复核 `ed2a4762` 的 (j)–(m)，历史）；`data/d5b/gates/mutation-matrix-recheck3.log`（(j)–(r)，历史）；`data/d5b/gates/mutation-matrix-recheck4.log`（(j)–(t)，历史）；`data/d5b/gates/mutation-matrix-recheck5.log`（Codex 复核 `48cba3bd` 之后：forge (j)–(r)、(t)、(v) 第 0 列 69 绿、十一个 RESULT OK；检查脚本变异 (u) 在这次运行里因我把诱饵错列为“不受影响”而判 FAIL，八个预期步骤其实全红）、`mutation-matrix-recheck5-u.log`（修正分类后单独重跑 (u)：RESULT OK）；证明的是预检各条核对各自有效，预检不是安全边界） | `python3 -u scripts/d5b-mutation-matrix.py`；`… --only u-checker-canonical-bytes-check-removed,j-…,…,r-…,t-…,v-attested-values-unchecked` | sha256(data/d5b/gates/mutation-matrix.log)=a4dac42450410812ca93bdd24eef706a427c78f98e5b729f4f1da08a1a9fb3a8；sha256(data/d5b/gates/mutation-matrix-recheck2.log)=eff4fb383a360b5d75e4f408e79269b1f1b55d8b17dc4808cf20aa8601590743；sha256(data/d5b/gates/mutation-matrix-recheck3.log)=4288de9ffb74e69761702bbe0252dbf401d3bfb41699c3e7a784b068cd203215；sha256(data/d5b/gates/mutation-matrix-recheck4.log)=019478c6d836f9656062d4a6460c938d0d05aa48a2d920e96a5b662f6db5b365；sha256(data/d5b/gates/mutation-matrix-recheck5.log)=559ccc742957778ce959892529d2b0f56e5b58f95c45487945bf1c871924a0b7；sha256(data/d5b/gates/mutation-matrix-recheck5-u.log)=1e90f2106d3f6b0954146aef681c9b1af35bdc2dc46d98718f708697837d0a34 |
| D5B-04 | unit-test | 同上 | `data/d5b/unit-test/forge-test-cancun.log` 末行 1,694 passed / 0 failed / 49 skipped（136 个套件）；`forge-test-prague.log` 末行 1,603 / 0 / 21 | `forge test`；`forge test --evm-version prague`（最后跑，之后 `forge build`） | sha256(data/d5b/unit-test/forge-test-cancun.log)=386454074f5970466e44e6503dd5285099455c9f06d4a5b751154a6a37dcd503；sha256(data/d5b/unit-test/forge-test-prague.log)=d1b906017b3de44fee048486fdf0321c39ce8e126870257320c2a0f602202108 |
| D5B-05 | unit-test（G 层） | 同上；基线 = `c30854f9` 源码 + 该 commit 的测试文件 | `data/d5b/g-layer/PostOpBound-d5b.log` L35–L40（W_postop 147,888；×1.15 = 170,072 ≤ 175,000；wrap 1,770）；`PostOpBound-c30854f9-baseline.log`（146,853）；`V55Fuzz-G2-d5b.log` L39/L61/L83/L105（I9 unbacked 0，SUBSIDY 0）；+1,035（+0.70%）的指令级归因（`D5b-design.md` §6.1b）：`ir-diff/postop-old-c30854f9.yul`、`ir-diff/postop-new-head.yul`（两棵树上 `forge inspect SuperPaymaster ir-optimized` 截出的 `fun_postOp_inner`）、`ir-diff/postop.diff`（逐行 diff，定位到 11 处从内联改为共享函数调用的具体位置：abi-decode OpCtx、operators/userOpState/_inflight 的映射槽位计算、5 处打包存储读改写） | `forge test --match-path contracts/test/v2/SuperPaymasterV55PostOpBound.t.sol -vv`；`… SuperPaymasterV55Fuzz.t.sol -vv`；`forge inspect SuperPaymaster ir-optimized`（两棵树各一次，`c30854f9` 用独立 worktree） | sha256(data/d5b/g-layer/PostOpBound-d5b.log)=4ad56dc365947a65de986ae715093d2ed3c7eee6dfdefdc252ee6b71f5b80e22；sha256(data/d5b/g-layer/V55Fuzz-G2-d5b.log)=caa0ae4de657bc1c1c4cca13341dadd7299564ef17169afb48af80d004124736；sha256(data/d5b/ir-diff/postop-old-c30854f9.yul)=af393ae045ebca0da07d7fbb2024cd10b7b76e828c8cf93dcc4006d100c8a34f；sha256(data/d5b/ir-diff/postop-new-head.yul)=66450d6966f336fdbe4d02bf26ee886c601e205bb69c90d6f8ac8cf5207ce0af；sha256(data/d5b/ir-diff/postop.diff)=0e49739a61501f1a79a7cb7a85d6dc3ccc886e8d4bd48cf1badb977ef54cfe21 |
| D5B-06 | local-anvil | 同上 | `data/d5b/rehearsal/d5b-anvil-rehearsal.log`（末行 `REHEARSAL OK`；每一次 timelock schedule / execute——M1 accept、SP 与 Registry 升级、M2 解除暂停——之前都有 `roles-*.log/json` 检查与 `attestation-*.json` 证明，四种调度各有一个"WITHOUT a roles attestation"负对照——这些是运维预检，不是安全边界；每次检查后挖一个块，9 次预检的 `headBlockHash` 都真正用 `blockhash` 核对）；同一脚本以线上 chainId 11155111 运行的 `data/d5b/rehearsal-live-chainid/`（预检走线上失败即停路径，9/9 核对通过，末行 `REHEARSAL OK`）及各步日志、`config.d5b-rehearsal.json`；**本机 anvil（Osaka，chain 31337），交易哈希只存在于那条已关闭的节点上**；anvil 自身日志未保留（开头打印公开开发者私钥） | `scripts/d5b-anvil-rehearsal.sh <workDir>` | sha256(data/d5b/rehearsal/d5b-anvil-rehearsal.log)=4c2594b7001a88e3697dbbc3c4d0bf6bf767e55a923691a90cb3d68ddb1b76e7；sha256(data/d5b/rehearsal/attestation-before-M2-unpause.json)=20a78344dc98f5d1c7e4adcc3cf775e61a5bfaa9601b41ae4f646943740724c2；sha256(data/d5b/rehearsal-live-chainid/d5b-anvil-rehearsal.log)=ea235f8879a9c2639b3c61c10bf82f1e9c20d0878174ca75fb52d62618b9c907 |
| D5B-07 | local-anvil（B 层重跑） | 同上 | `data/d5b/b-layer/verdict-diff-vs-committed.txt`（16×3 个用例判定与 L-04 基线相同）、`access-check.txt/json`（OUTSIDE 0，FORBIDDEN 0，正对照 allFlagged）、三组 `*-results.json`、`*-cases.log`、`*-traces.jsonl.gz`、`b8-op070.json`、`setup.json`、`deploy.json`；bundler 原始日志（数 MB）未保留 | `scripts/d5b-blayer-rerun.sh <work> <rundlerDir> <alto125Dir>`，之后按 `g1-collect.sh` 的方式收集（输出不进 `b-layer/cases`） | sha256(data/d5b/b-layer/verdict-diff-vs-committed.txt)=2c57531df4835aba5bd19331f2a813b3ad339bd62d45417f6ff20f262a25e283；sha256(data/d5b/b-layer/access-check.json)=5cfce8048d9995cdec392984053e09a50680752b7770304fb2e7cd46235d705c |
| D5B-09 | unit-test（M1 预检 + 变异 i） | 同上 | `data/d5b/unit-test/D5bTimelockPreflight.log`（从完整 Cancun 日志原样截取，35 PASS，全部是运维预检测试（含线上头块哈希失败即停，与 Codex 复核 `48cba3bd` 之后的证明值一致性——forge 侧不再检查字节形式）；`D5bTimelockPreflight-vv.log`（同一套件 -vv，含本地逃生开关的“canonical byte form NOT verified”警告）：预检正例 / 负对照 / 执行前复检 / 清单绑定、证明文件各条核对（含 schema、headBlockHash、TL_ATTEST_MAX_AGE 仅本地可调大）、清单 chainId、12 种空洞清单、空白标签、多余角色键、10 个缺字段、示例占位清单、M2 解除暂停运行预检、schedule-call 拒绝升级，以及两条界限测试——有界预检看不到清单外 admin；手工 PASS 漏掉它时能通过全部核对）；`data/d5b/gates/mutation-i-postOp-refund-lost.log`（前向守恒断言变红） | `forge test --match-path contracts/test/v2/D5bTimelockPreflight.t.sol`；`python3 scripts/d5b-mutation-matrix.py --only i-postOp-refund-lost` | sha256(data/d5b/unit-test/D5bTimelockPreflight.log)=4b40453702d0eedfe6926fb4da1aa98005b52bf951f8a08814158e6007a5e137；sha256(data/d5b/unit-test/D5bTimelockPreflight-vv.log)=9ad76968853cb331b9a8c8150566fedafbbc07cee676ede7e4c95450f329f9c4；sha256(data/d5b/gates/mutation-i-postOp-refund-lost.log)=023590083727347479f1fa23c3195a7f8d23bf9249112e70a3bc81fe9e7baae0 |
| D5B-10 | local-anvil（timelock 角色事件历史检查） | 同上 | `data/d5b/timelock-roles/selftest.log`（76 步，运维检查的自测；E4 规范字节 10 步——九种不规范字节被拒、`--canonicalize` 输出被接受；第 2 步起每步先放真实 PASS 再验证失败会替换它；E2 整数规范形式 15 步、E3 畸形结构 8 步；`TIMELOCK ROLE CHECKER SELF-TEST OK`：A 角色历史 8 步；B 清单 / rpc2 chainId 不符；C rpc2 钉住头块——头块 fork 与忠实代理两个正对照通过，落后一块、丢日志、改 sender 失败；D 部署块外的构造授予失败；E 缺字段 ×10、空角色、空 / 重复 / 零地址 mustHoldNothing、标签数量 / 空标签、示例占位清单失败，去掉占位标记只因 chainId 失败；F 退出 2 的八种路径——`--chunk` 0 / -5 / 1.5 / abc / 缺值、清单读不到、缺 `--rpc`、端点不可达——都把事先放在 `--attest` 路径上的真实 PASS 替换成写明原因的 FAIL）、`step*.json/log`（每步完整报告与输出）、`att*.json`（每步的证明）、`manifest*.json`；修复前一栏 `selftest-prefix-5ce18296.log`（同一自测对 `5ce18296` 的检查脚本，40 步中 31 步不符合要求，F 段当时是旧写法）、`selftest-prefix-626b6ea8.log`（对 `626b6ea8` 的检查脚本，43 步中 7 步不符合要求：F 段七个用法错误，旧 PASS 原样留下）、`selftest-prefix-7ca43549.log`（对 `7ca43549`：66 步中 21 步不符合要求，真正的行为缺陷 3 步）；演练中每次 schedule / execute 前的检查 `data/d5b/rehearsal/roles-*.json/log` | `scripts/d5b-timelock-roles-selftest.sh <workDir>`（修复前一栏：`KEEP_GOING=1 CHECK=<旧脚本包装，40 s 闹钟>`）；`node script/governance/check-timelock-roles.mjs --rpc <url> [--rpc2 <url>] --manifest <file> [--attest <path>]` | sha256(data/d5b/timelock-roles/selftest.log)=97048cbe22824b2a3baf2ff8fb0445a8aad206b5a3c7981d1b1cf573fffdaded；sha256(data/d5b/timelock-roles/selftest-prefix-5ce18296.log)=4b479b70b85386748f5ffff533bf68e8cfc956f896f138db8970e9e2797ce814；sha256(data/d5b/timelock-roles/selftest-prefix-626b6ea8.log)=3a0a19cd7e3ab595bcd4b872e7cf5f721447851dc16a2cda284ebb7993db5597；sha256(data/d5b/timelock-roles/selftest-prefix-7ca43549.log)=a5c389cb2245e33bdd6f26470636a99eb9eff92541f205076a5b122ec30ba661；sha256(data/d5b/timelock-roles/step16.json)=3eb4818abaccdd94e1ed5629649c32f76c63665123ad1cd04cf15f03d841c7d3 |
| D5B-08 | 测试 fixture | 源码 commit `c30854f9` | `../../../contracts/test/fixtures/superpaymaster-5.5.0-c30854f9-impl.creation.hex`、`registry-5.8.0-c30854f9-impl.creation.hex`、`d5b-previous-release.provenance.json`（源码 keccak、编译设置、creation / runtime 哈希） | 见 provenance 的 `note` | 不入清单（在 `contracts/` 下，随仓库提交） |
| D5B-11 | Sepolia fork 演练（D5b-design.md §7） | fork 于真实 Sepolia block 11716195（本表所在 commit 的树） | `data/d5b/fork-rehearsal/rehearsal.log`（末行 `REHEARSAL OK (all)`；Stage I：SP 5.4.2→5.5.0（含 D5b core/extension split）、Registry 5.8.0→5.9.0，全部在真实代理上完成；Stage II：M1 ownership handoff 到真实 timelock、C 段 SP/Registry timelock-aware 升级演练、M2 guardian pause/unpause，负对照——无证明拒绝、48h 内提前执行拒绝、旧 EOA 升级被拒、guardian 无法自行解除暂停——全部按预期）；两项真实发现（§7）：线上 timelock 部署者 EOA 仍持有 `DEFAULT_ADMIN_ROLE`（M1 在真实 Sepolia 上无法调度，直到 `renounceRole`）、`mustHoldNothing` 在单密钥部署下没有天然候选（登记为对 schema 所有者的待决问题）；`manifest.json`/`attestation-*.json`/`roles-*.json`（每次 schedule/execute 前的角色证明）、`I-A*.log`/`II-*.log`（每步完整 forge 输出） | `script/evidence/d5b-fork-rehearsal.sh .env.sepolia <fork block> <out dir> all` | sha256(data/d5b/fork-rehearsal/rehearsal.log)=0e0d4203b82324bb46e7f1e5b5de543218ae704cfbcbe3dddd41138be349dbd1；sha256(data/d5b/fork-rehearsal/manifest.json)=927697f9e7dd8877324f5a29cce69e48af73d40e4455a0d25a321807c2ad720f；sha256(data/d5b/fork-rehearsal/attestation-before-M1.json)=9c91dda0275a2eb5135233ca43bedaa57a7bebd19bfec7ec3ae9d0e2982b7e49 |
| H-01 | unit-test（有界符号验证，Halmos） | 分支 `d5c-1/halmos-token` 合入本 commit | `D5c-1-halmos.md`（报告：§0 结论表——CAP-1/R/I6/I6-J PROVEN，A-3/A3x/I2（含新增 I2-F）/引理 M 为有界符号验证并附具名 fuzz 替代证据；§3 逐项结果；§5 变异；§7 从单步引理到累计性质的组合论证；§8 局限（供论文附录 X）；§F 发现 F-D5c1-1）；`data/halmos/verify-final.txt`（判定脚本 `verify-d5c1.py` 的最终输出：**ALL EXPECTATIONS MET，266 行，0 处不一致，退出码 0**） | `cd .. && python3 script/halmos/verify-d5c1.py`（在本目录执行，需要预先跑完 `run-all-d5c1.sh` 各组、`run-mutations-all.sh`、`run-fuzz-liveness.sh`，见 `data/README.md` 与 `D5c-1-halmos.md` 顶部的复现命令） | sha256(D5c-1-halmos.md)=d3c59509c8365519d6fe90486977deb6af3f30a9b602b0322e37f45d25ff6cdc；sha256(data/halmos/verify-final.txt)=1facb68e9efe222abc7d85595737e51fedc183dc14217119e07cd4ec3b31e625 |
| H-02 | unit-test（判定脚本自检） | 同上 | `data/halmos/verify-selftest.log`（`script/halmos/verify-selftest.py`：57 个对照全部 behave，含 H3 的绑定伪造对照与 M6 的存档伪造对照——拷贝到别的分区名下的日志、错误参数、缺强制项、退出码不符、存档缺失、自检脚本本身被改过、报告引用数字与日志不符等，每条负对照都要求**因具名原因**失败） | `python3 script/halmos/verify-selftest.py` | sha256(data/halmos/verify-selftest.log)=515df224b045adf82aef0f2a9b8a5248c024535c95e50bd078a6c1f308d0520f |
| H-03 | 编译一致性（Halmos 用的字节码 = profile.default） | 同上 | `data/halmos/artifact-parity.log`（两遍独立运行，都是 `RESULT: OK`：每个受测合约的 default-profile creation code 是对应 harness 合约 creation code 的字节子串，registry-size（runs 200）产物**不**匹配，证明负对照有效；附两次运行各自的 xpnts/apnts 绑定行） | `python3 script/halmos/artifact-parity.py` | sha256(data/halmos/artifact-parity.log)=ac8a4e13779c76aacf4578da0a2a7ee4ea1d5e419d4121b21ef7bda732c9c891 |
| H-04 | unit-test（回放/布局/预热/边界 forge 套件） | 同上 | `data/halmos/forge-halmos-suite.log`（28 个测试，0 失败；11 个具名测试逐一核对：存储布局、selector 列表与 artifact 一致、"锁定/信用记录创建后恰好活跃"的预热性质、F-D5c1-1 的两条回归、D-A3-2 的具体回放、A-3 与 I4-B 的场景测试） | `forge test --match-path "../../../contracts/test/halmos/*.t.sol"` | sha256(data/halmos/forge-halmos-suite.log)=30172b4fff53a4d62cefa3198bb03c9dd90d142abcbb249557599b25cc2117d7 |
| H-05 | 发现（规范/代码不一致，已修复并有回归） | 见 `D5c-1-halmos.md` §F | F-D5c1-1：`xPNTsTokenV2.initialize` 未对 `exchangeRate` 设范围，锁定量可超 `uint128` 截断 `lockedOf`，破坏 I4；修复 `3c28ec21`（已在 `feat/aoa-balance-mode-5.5.0` 主线）。同一发现分支下另有代码行为**不改**、改规范的一项：D-A3-2（`burn(SP 自己, x)` 等价于 `burn(x)`，与 A-3 旧文字不符），已并入 v4.1 勘误（见规范文件头） | 回归：`test_D5c1_REGRESSION_F1_*`；变异 M-F1 使其在 Halmos 与 forge 两侧同时变红（见 H-01 的 `D5c-1-halmos.md` §5） | 不入清单（属于 `contracts/src` 的修复，随源码提交） |

## 2. 登记册数字 → 证据

"本次读数"是本 commit 从原始数据里读出的值。**不一致**的地方都列在"对照"一栏，没有静默调整。

### §1.1 Sepolia 现有部署

| 登记册条目 | 登记册值 | 证据 | 本次读数 | 对照 |
|---|---|---|---|---|
| SP 代理 | `0x09DF…4DE9` | R-02 `.superPaymaster`；F-02 `B0-inventory.log` "SP proxy" | 同 | 一致 |
| SP impl 5.4.2 | `0xe25f…2C27` | R-01：tx `0xc73a…3fcf` 的 `receipt.contractAddress` | `0xe25f88db…2c27` | 一致 |
| "5.4.2 impl 部署交易" | `0xae03…3ec6` | R-01 `recordLabel = record_sp542_implDeploy` | **链上实际是 `upgradeToAndCall` 调用**（`observed: CALL 0x4f1ef286 -> 0x09df…`，nonce 8819，块 11,228,202 idx 122） | **不一致：部署记录把两笔标反了**。impl 的 CREATE 是 `0xc73a…3fcf`（nonce 8818，idx 121）。`deployments/deploy-record-v5.4.2-sepolia.md` L28–L29、`repcredit-bytecode-profile-audit.md` L58 与登记册 §1.1 都沿用了错误标签 |
| "5.4.2 升级 + prime 交易" | `0xc73a…3fcf` | 同上 | 链上是 impl 的 CREATE | 同上（标反） |
| Registry 代理 | `0xf5Bf…8E71` | R-02 `.registry`；R-01 `0x355b…` 的 `to` | 同 | 一致 |
| Registry 5.4.1 impl 部署 / 升级 | `0xff7b…d766` / `0x355b…824d` | R-01 | CREATE → `0x6af5…a1db` / CALL `upgradeToAndCall`，块 11,228,198 | 一致 |
| （附带）Registry 5.4.2 两笔 | `deploy-record-registry-v5.4.2-sepolia.md` L16–L17 | R-01 | `0x8d4e…`（记录说"impl deploy"）实为 `upgradeToAndCall`；`0x6cdb…`（记录说"upgrade"）实为 CREATE → `0x9e5d…cc00` | **同样标反** |
| owner EOA | `0xb560…df0E` | R-01 六笔的 `from`；F-02 `B0-inventory.log` "owner" | `0xb5600060…adf0e` | 一致 |
| 链上字节码 = 本地源码（块 11,646,729） | 4 个一致 + LivenessRegistry 逐字节相同 | O-03 | — | **MISSING（原始 dump）** |

### §1.2 第 0 步盘点（`step0-inventory.json`，O-01）

| 条目 | 登记册值 | 字段 | 本次读数 |
|---|---|---|---|
| OperatorConfigured / OperatorDeposited | 4 / 5 | `.events.OperatorConfigured`、`.events.OperatorDeposited`；两端点一致 `.crossCheck.*.identical` | 4 / 5，identical = true |
| DebtRecordFailed | 0 | `.events.DebtRecordFailed`；`.state.pendingDebts` | 0；`[]` |
| PendingDebtRetried / Cleared | 0 / 0 | `.events.PendingDebtRetried/Cleared` | 0 / 0 |
| Queued / Cancelled / Executed | 2 / 0 / 0 | `.events.APNTsTokenChange*` | 2 / 0 / 0 |
| 2 个 operator，均已配置 | — | `.state.operators[]` | 2，`isConfigured = true` |
| `pendingAPNTsToken = 0xBb46…` | — | `.state.pendingAPNTsToken` | `0xBb46…9883` |
| cachedPrice 已过期 | — | 盘点 JSON **没有**这个字段（`.state.pendingAPNTsEta` 也是 null）；fork 读回见 F-02 `B0-inventory.log`（块 11,692,260）："cachedUpdatedAt 1788255708"、"block.timestamp 1789257384"、"staleness (s) 4200" | 过期（相差约 11.6 天 ≫ 4200 s） |
| 采集时间 / 区间 | 2026-09-12T23:50:11Z | `.at`、`.range` | 同；块 11,151,016–11,692,228 |

### §1.3 目标链硬分叉（O-02，2026-09-13 重新查询；`0b69492c` 当时的原始响应**未落盘**，这一份是替代）

| 条目 | 登记册值 | 字段 | 本次读数 |
|---|---|---|---|
| Sepolia `eth_config` | 1761607008 激活，target 14 / max 21，next = none | `.summary.chains.sepolia.eth_config` | `currentActivationTime 1761607008`，`blobSchedule {target 14, max 21}`，`next null`（查询块 11,693,426） |
| CLZ 探针三链 | 0xff | `.summary.chains.{sepolia,op-mainnet,op-sepolia}.clz` | 三链均 `…ff` |
| 负 / 正对照 | prague NotActivated，osaka 0xff | `.summary.chains["anvil --hardfork prague (negative control)"]` / `osaka` | `EVM error NotActivated` / `…ff` |
| EntryPoint codehash 三链相同（§2.3 附带） | `0x8db5ff69…` | `.summary.chains.*.entryPointCodehash` | 三链均 `0x8db5ff69…fc58` |
| SP 质押 0.1 ETH（§2.6 附带） | Sepolia 0.1 ETH | `.summary.chains.sepolia.spDepositInfo`；OP 主网 V3 SP 同字段 | Sepolia stake 1e17 / 86400 s；OP 主网 `0xA2c9…` stake 1e17 / 86400 s |

### §1.4 原稿 OP 主网数据集（R-03，HISTORICAL-VOID）

外部仓库 aastar-sdk `2db405ec`，路径 `packages/analytics/data/paper_gas_op_mainnet/`。行数（不含表头）与登记册逐项一致：

| 文件 | 行数 | sha256 |
|---|---|---|
| 2026-02-17/op_mainnet_super_simple_erc20.csv | 43 | `c3dd4c273cdbdbdb628929572bd33ac2149319587a4ce8079bfcefeef4bfe6f6` |
| 2026-02-17/op_mainnet_v4_simple_erc20.csv | 36 | `b798f16b5e267c1b36bbd3eb8a8ded8c9034afe816864e3890ec03a07d1bc57a` |
| 2026-02-17/op_mainnet_super_controlled_simple_erc20.csv | 20 | `0e8a18c673de93fc43fc7d9789296a4bf7354c2c9cda9d4bf7ea719744429594` |
| 2026-02-17/op_mainnet_v4_controlled_simple_erc20.csv | 20 | `dca99130cc06f9b5669d82a4b2eb62a7585771655ba5e3b8004f68b1e0749c85` |
| 2026-02-18/op_mainnet_super_simple_erc20_with_sender.csv | 50 | `ecfa7fc6f1b09cc9924583844c514a62dd97a6dd94f8e63f9f1edc3c4c08a58d` |
| 2026-02-18/super_t2_sender.csv | 50 | `6d581ce3fc071bcde1412c9e7f732f005a7e67b0ea1722cb959c49bbfcd97834` |
| 2026-02-18/v4_t1_sender.csv | 28 | `ce62c32319b4bf59fc92b349559897d96f4588065487b6f4c295370ebc58d92b` |
| 2026-02-18/op_mainnet_v4_simple_erc20_with_sender.csv | 36 | `7911d9933ba24cdcedbfcd5375514f7d4aeaa7d8f93899dc440d86adabb7d28f` |
| 2026-02-18/op_mainnet_v4_controlled_simple_erc20_with_sender.csv | 28 | `ce62c32319b4bf59fc92b349559897d96f4588065487b6f4c295370ebc58d92b` |
| 2026-02-18/aa_sender_txhashes.csv | 112 | `cddd97926b705a723ffd19a4bc1afeb68dbb8b654ddb2bcb4b7e684d619d6398` |
| 2026-02-21/op_mainnet_super_t21_normal.csv | 19 | `582890219d66d3dbf374879f9b4267f85e46e9be08999ebec73e59144bf0e225` |
| 2026-04-14/alchemy_controlled_simple_erc20.csv | 0 | `28b78291675816840e9c9bc75dc41ce5a048aaabf1d9754647e1a224657f04b7` |

**新发现**：`v4_t1_sender.csv` 与 `op_mainnet_v4_controlled_simple_erc20_with_sender.csv` 的 sha256 **完全相同**，是同一份数据的两个文件名（归入 R1-6 数据管道复盘）。

### §2.1 测试规模

| commit | 登记册值 | 证据 | 本次读数 |
|---|---|---|---|
| `a3eb0945`（当前有效） | 1600 / 0 / 49，126 套件 | U-10（树与 `a3eb0945` 的 `contracts/` 相同，只多了默认关闭的导出钩子） | **1600 / 0 / 49，126 套件**，一致 |
| `9a41b66b`、`c5fc803c`、`3e7ddd9a`、`66d3e4c1`（Cancun / Prague） | 见登记册 | — | **MISSING**：DSR 在独立 worktree 复现，原始日志不在本仓库；需要时按 commit `git archive` + `forge test` 重跑 |

### §2.2 合约体积（U-11，runtime，EIP-170 = 24,576）

| 条目 | 登记册值 | 文件 / 行 | 本次读数 |
|---|---|---|---|
| SP 5.4.2 基线 `3b0d4821` | 23,569 | `sizes-3b0d4821-sp542-baseline.json` SuperPaymaster runs 500 | 23,569 |
| SP 5.5.0 D2 `c5fc803c` | 23,031 | `sizes-c5fc803c.json` | 23,031 |
| SP 5.5.0 D3 `3e7ddd9a` | 21,857 | `sizes-3e7ddd9a.json` | 21,857 |
| SP 5.5.0 当前（`66d3e4c1` 起） | 22,915 | `sizes-df941d57.json`（registry-size 版 22,756 同列） | 22,915；fork 部署读回 F-02 `B4-run.log` L38 = 22,915 |
| xPNTsTokenV2 / Ext / Lens | 19,851 / 21,922 / 4,731 | `sizes-3e7ddd9a.json`、`sizes-df941d57.json` | 19,851 / 21,922 / 4,731 |
| APNTsCapped | 5,346 | `sizes-df941d57.json` | 5,346 |
| BLSAggregator default / registry-size | 24,345 / 23,940 | `sizes-df941d57.json`（runs 500 / 200） | 24,345 / 23,940 |
| 实验 Part A（附带） | 21,747（commit 信息） | `sizes-31921fbc-exp-partA.json` | 21,747 |
| 实验 Part B 余量 1,079–1,124；一版 24,908 B | — | — | **PENDING（exp 分支 `d7ae5099` / `e0cf0dc8` 未构建）**；24,908 B 那一版从未提交，**MISSING（不可复现）** |

### §2.3 gas 上界（G 层）

| 条目 | 登记册值 | 证据 | 本次读数 | 对照 |
|---|---|---|---|---|
| EntryPoint 包裹开销 | 1,687–1,702 | U-04 L32–L34（200k 1,689；1M 1,687；opReverted 1,702），L25–L28（bundle 位置 1,689 / 1,701×3） | 同 | 一致 |
| postOp 入口检查之后最坏路径 | 约 137k（`6ef5f0e7`） | — | — | **MISSING**：当时的扫描（SETTLE_GAS_BOUND = 80k 时）没有落盘；现在的守卫是 160k，直接扫描只能测到"最小成功 gas 168,000"（U-07 L15），测不到这个区间。它已被下一行 W_postop 的实测取代 |
| W_postop（Part A） | 146,600 | U-09 L27、L14 | 146,600（CREDIT 首次用户、冷写、首笔债） | 一致。另：`d7ae5099` 的 commit 信息为 147,478、`e0cf0dc8` 为 146,817，**未采集日志（PENDING，exp 分支）** |
| T-R14-09 实测 postOp | 140,805 → 163,040 ≤ 200,000 | U-05 L13（HEAD）；U-06 L10（`c5fc803c`，Cancun 和 Prague） | **140,770**（三次运行都是） | **不一致（35 gas）**：140,805 在 `c5fc803c` 和当前 HEAD 上都复现不出来；引入该测试的 `e09db389` 单独 `git archive` 编译失败（遗留测试尚未迁移），无法复跑。按 140,770：140,770 × 64/63 + 20,000 = 163,005 ≤ 200,000，结论不变 |
| SP 验证期实际 pmVerif | 198k–238k（G1 F2） | `b-layer/B1-B10.md` L113（B1 209,036、B5 237,515、B6 198,036、B7 218,543、B4 209,067） | — | **MISSING（原始 trace）**：数值来自 `rundler-traces.jsonl` 等根帧 `gasUsed`，这些 trace 文件没有提交（`access-check.json` 只保存分类结果）。需要按 L-04 的命令重跑并保存 traces |

### §2.4 G2 fuzz（U-01 / U-03）

| 条目 | 登记册值 | 证据 | 本次读数 |
|---|---|---|---|
| 规模 | 1,000 种子，2,530 bundle；inline 1,000 runs（0xd5c2）；直接 postOp 1,000 runs（0xd5c3） | U-03 L11；export-off 日志 L8–L10 | 1000 / 2530；两条 fuzz 各 runs 1000 |
| 已结算 BALANCE / CREDIT；精确比对 | 3,268 / 1,121；4,389 | U-03 L15–L16；JSONL 重算（U-02 stats L3） | 3,268 / 1,121；4,389（JSONL 同） |
| 中途变价后才 postOp（ETH / aPNTs） | 817 / 835 | U-03 L17；U-02 stats L4 | 817 / 835（JSONL 同） |
| 注入失败 | 787 + 879 | U-03 L18；U-02 stats L3 | 787 / 879（JSONL 同） |
| 资不抵债拒绝 | 687 | U-03 L14 | 687 |
| I9 没有后盾的赞助 | 0 / 0 | U-03 L29；U-02 "no subsidy"（0 mismatches） | 0 / 0 |
| DSR 变异抽查 | 3 项变红 | — | **MISSING（原始日志）**：DSR 本地执行，未留日志；SP 侧 10 个变异的描述在 `D5-traceability.md` L91，也没有原始日志 |

### §2.5 用户多付（U-02：从 JSONL 逐笔重算；定义：均值 = floor(Σppm / n)，P95 = 最近秩 a[⌈0.95n⌉−1]，与 fuzz 的 `_dist` 相同）

| 公式版本 | 登记册值 | 证据 | 本次重算 | 对照 |
|---|---|---|---|---|
| 5.5.0 现行（修复后 op 组合），全部 | 83.2 / 269.6 / 371.1 %（n 4,389） | U-02 stats L7 | 83.2 / 269.6 / 371.1 %（ppm 831,541 / 2,696,041 / 3,711,360） | 一致，且与 fuzz 自身输出（U-03 L33–L35）逐 ppm 相同 |
| 同上，postOpGasLimit ≤ MIN+50k | 41.8 / 61.3 / 81.5 %，最小 21.8 %（n 3,489） | U-02 stats L8 | 41.8 / 61.3 / 81.5 %，最小 21.8 % | 一致（U-03 L39–L42） |
| 同上，postOpGasLimit 1.0–1.5M | 243.4 / 305.3 / 371.1 % | U-02 stats L9（谓词 `postOpGasLimit ≥ 1,000,000`，n 900） | 243.4 / 305.3 / 371.1 % | 一致。注意：这一组 main 分支的 fuzz 本身不输出，数字最早见于 `31921fbc` 的 commit 信息（实验分支 fuzz 的旧公式模式）；现在第一次有逐笔原始数据 |
| 修复前（`4fa67967`）36.6 / 58.6 / 76.6；75.9 / 251 / 342 | 已被替代 | `D5-traceability.md` L47–L52 | — | **MISSING（原始数据）**，已被取代，不再引用 |
| Part A `31921fbc`（C_POSTOP 170k，C_WRAP 5k） | 见登记册 | U-12 | 全部 22.6 / 37.4 / 45.6 %；≤ 250k 23.7 / 38.3 / 45.6 %；≥ 1M 18.3 / 28.8 / 32.5 % | 同一 schema / 同一脚本重算 |
| Part B `6c3a9a0e`（默认参数 175k / 5k） | 见登记册 | U-12 | 全部 23.7 / 38.8 / 47.2 %；≤ 250k 24.9 / 39.7 / 47.2 %；≥ 1M 19.3 / 29.9 / 33.7 % | 同上；m 敏感性与全下限组合只有 fuzz 断言（零补贴），未做逐笔导出 |

### §2.6 真实 bundler 测试（G1，本地 anvil Osaka）

| 条目 | 登记册值 | 证据 |
|---|---|---|
| 工具版本 | Rundler v0.11.0 `2a3db237`；Alto v1.2.5 `45bbf341` | `b-layer/README.md` L9–L10；`b-layer/rundler-chain-31337.toml`；bundler tracer 源码 `b-layer/cases/*-bundler-tracer-*.js`（入清单） |
| B0 | 4 违规被拒、对照接受；safe mode 关 → 5 个都上链 | L-03：`b0-rundler-anvilo.json`、`b0-alto125-anvilo.json` 等的 `.cases.*.verdict/.pass`；`b0-alto-unsafe.json`（safe mode 关） |
| B1–B10 106 次模拟，清单外 0 / 禁止 0 / 禁用操作码 0 | 34 + 36 + 36 | L-04 `access-check.json` `.summary`：rundler 34 条、alto 36、altoMulti 36，`outside`、`forbidden`、`otherBanned` 合计均为 0（本次重算） |
| 分类器正对照 7/7 | 7/7 | L-04 `.positiveControl`：7 个注入全部被标出，两条基线为 0 |
| 质押门槛：0.1 ETH 被拒、1 ETH 被打包 | — | L-04 `rundler-results.json` `.cases["B9-below"].error`（`-32502 entity stake/unstake delay too low`，`minimumStake 0xde0b6b3a7640000`，`minimumUnstakeDelay 0x15180`）、`.cases["B9-above"]` |
| F1 | 见登记册 | L-05（冻结组，22/22 OK） |

### §2.7 部署与字节码一致性

| 条目 | 登记册值 | 证据 | 本次读数 | 对照 |
|---|---|---|---|---|
| T-4 全新 anvil 部署 | exit 0，143 行 `default artifact OK`，读回 50/0 | L-02 | exit 0；143 行；L15131 `passed 50 failed 0` | 一致 |
| BLSAggregator 换成 registry-size → exit 1 | — | — | — | **MISSING（原始日志）**：`D5-deploy-migration.md` L262 的反例未落盘；本次未重做 |
| 真实 Sepolia 上的 audit-core：38 / 13 | 38 通过 / 13 失败 | F-03 L3016（CheckDefaultArtifacts 读 `config.sepolia.json`，本地 fork 块 11,692,260） | `passed 38 failed 13` | 一致。说明：这是 fork 上的**只读**检查，读的是真实链上的代码，不是在 Sepolia 上执行的 audit-core |
| RepCredit 字节码配置（8 个合约、B3 的 5 个 runtime） | 一致 | O-04 | — | **MISSING（原始 dump）** |
| 本地 L4 余额模式 op | 烧毁 78.2766 = operator 减少 = revenue 增加，`lockedOf` = 0 | L-01 `l4-L4GaslessTest-verify.log` L5–L8；`handleOps` 回执（块 94）里的 `UserOperationEvent`：success，actualGasUsed 489,537，actualGasCost 489,540,813,003,693 wei | **78.276939694334370000**；三者严格相等；`lockedOf` = 0 | **数值不同、性质相同**：登记册的 78.2766 与 `D5-deploy-migration.md` L202 的 78.3278、L4 小节的 78.3632 都是更早几次运行（那几条 anvil 链已不存在，原始输出没有保存，**MISSING**）；charge 按上链区块的 gas 价计价，每次运行都会不同。可以引用的是"烧毁 = operator 减少 = revenue 增加、lockedOf = 0"，不是具体数值 |

### §2.8 其他计算

| 条目 | 登记册值 | 来源 | 说明 |
|---|---|---|---|
| 主网 aPNTs 初始上限 300,000 | 20,000 笔/月 × 0.624 × 12 × 2 | DSR 仓库 `AOA_Decision_1_2_RouteA_BoundedAllowance_2026-09-12.md` §15.9 L561–L567（外部） | 0.624 = $0.008 × 1.418 × 1.10 ÷ $0.02，其中 1.418 = 1 + 41.8 %，即 U-02 的 ≤ MIN+50k 均值（已重算一致） |
| 每笔约 287k billed gas、L1 数据费约 8 % | — | 同上 L566，"按原稿实测" | **依据是 R-03（HISTORICAL-VOID）**：重投时应改用 P4 数据（`data/templates/p4-op-mainnet-ops.csv` 的 `tx_gas_used`、`l1_fee_wei`） |

## 3. 汇总

### MISSING（没有原始数据）

| 条目 | 原因 | 补救 |
|---|---|---|
| O-03 链上字节码比对（块 11,646,729） | 当时只写了文档表格 | 需要时按文档 §0 重跑并保存 `cast code` 输出 |
| O-04 RepCredit 字节码配置审计 | 同上 | 同上 |
| §1.3 `0b69492c` 当时的探针原始响应 | 未落盘 | 已由 O-02（2026-09-13 重新查询）替代 |
| §2.1 早期 commit 的测试计数 | DSR 在独立 worktree 复现，日志不在本仓库 | 按 commit 重跑 |
| §2.3 约 137k（入口检查之后最坏路径） | 修复前的扫描未落盘；当前代码的守卫使它不可测 | 已被 W_postop 146,600（U-09）取代 |
| §2.3 T-R14-09 的 140,805 | 在 `c5fc803c` 和 HEAD 上都测得 140,770；源头 `e09db389` 不能单独编译 | 论文用 140,770（U-05 / U-06） |
| §2.3 pmVerif 198k–238k | B 层原始 trace 未提交 | 重跑 G1（L-04 命令）并提交 traces |
| §2.4 DSR 变异抽查、SP 10 个变异 | 未留日志 | 需要时逐个重做并保存日志 |
| §2.5 修复前（`4fa67967`）多付 | 已被取代 | 不再引用 |
| §2.2 Part B 那一版 24,908 B | 从未提交 | 不可复现 |
| §2.7 BLSAggregator 反例；L4 的 78.2766 / 78.3278 / 78.3632 | 早期运行的输出没有保存 | 以 L-01 的新运行为准（性质相同） |
| D5 §9 第 1 步两条分支（块 11,692,260）、7d 演练（块 11,692,415）、APNTsCapped 的全新 anvil / Sepolia fork / 主网 fork 演练（`apnts-capped-deliverable.md` §4.1） | 当时只写文档 | F-01 / F-02 已在同一 fork 块上重跑本分支现在脚本化的步骤；第 1 步 ④（切换到 APNTsCapped + 1:1 重存）**没有脚本**（`executePendingAPNTs` 依赖 xPNTs 的 communityOwner），未演练 |

### PENDING

| 条目 | 由谁 / 在哪 |
|---|---|
| ~~Part B 体积与 W_postop 146,853 的原始日志~~ | **已由 D5B-01（`variants.txt` 第 2 行 23,568 B）与 D5B-05（`PostOpBound-c30854f9-baseline.log`，146,853）补上** |
| P2 / P4 的 onchain-real 数据 | 按 `03-final-spec.md` §6 第 4 列与 §6.1 采集 |

### 本次发现（需要更正别处的文字）

1. **Sepolia 5.4.2 部署记录把 impl 部署和升级两笔交易标反了**（SP 和 Registry 5.4.2 都是）。链上：`0xc73a…3fcf` 才是 SP 5.4.2 impl 的 CREATE，`0xae03…3ec6` 是 `upgradeToAndCall`；Registry 5.4.2 同理（`0x6cdb…` 是 CREATE，`0x8d4e…` 是升级）。影响 `deployments/deploy-record-v5.4.2-sepolia.md` L28–L29、`deployments/deploy-record-registry-v5.4.2-sepolia.md` L16–L17、`repcredit-bytecode-profile-audit.md` L58 和登记册 §1.1。本 commit 没有改这些文件（它们不在本任务范围内），只在这里登记。
2. T-R14-09 的实测 postOp 应为 140,770（不是 140,805）。
3. 原稿数据集里有两个文件内容完全相同（§1.4）。
4. forge 1.7.1 的 broadcast 文件里，`transactions[i].hash` 与该条目的合约名 / 函数名可能错配（本次 fork 上不带 `--slow` 的 `run()` 运行中实际出现过：两次运行给同一个 hash 标了不同的函数）；`collect-receipts.mjs` 因此改为按链上交易本身（CREATE 地址或完整 calldata）重新标注，不信任数组顺序。L-01（带 `--slow`）的 6 个标签已按 calldata 逐笔核对，全部正确。
