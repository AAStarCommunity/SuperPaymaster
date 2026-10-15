# A6 正式采集与验收 SOP

依据 DSR 在 Seeder `dc7d0fab`（2026-10-15）的已决范围 (a) 执行。
可信根是实际链上交易、EntryPoint v0.7 的逐 `UserOperationEvent`（UOE）及 receipt、固定块状态。
离线校验器负责内部逐行自洽、逐 UOE 判定、三臂匹配、SP 守恒和 Passport 漂移，不能称为独立链上重放器。
具体检查与第 6 轮范围外项目见 [README 的信任根与范围](README.md#信任根与范围)。

当前 A3a 为 **NO-GO**。本 SOP 规定正式 A6 的流程，不表示现有工具具备正式运行能力。
#477/#479 已合并的本地 Anvil 运行只证实量具机制，仍非 A6 真链数据，也不阻塞 A2。

## 1. 确认开窗前提

1. 取得作者明确的 A3a go，登记决定及其来源。
2. 确认 A4 已完成，登记完成依据。作者 A3a go 和 A4 完成两项缺一不可，满足前不得启动正式 A6。
3. 完成本页末尾的 `SP TODO before formal A6`，保存实现与核对依据。
   现有 `collector.mjs` 不能原样执行正式 A6；不得把本地 override 或改写 JSONL 当作正式链支持。
4. 登记本次窗口标识、目标链、EntryPoint v0.7 地址、SP/VPM/TPM 地址、sender、operator、bundler、
   基线配置、`B_max`、gas 参数、场景及失败样本安排、Passport 和证据登记映射。
   固定源码版本、配置内容及 SHA-256，不沿用本地 dry-run 的占位值作为正式配置。
5. 将目标固定为 50 个匹配三元组，每组包含 SP、VPM、TPM 各一个操作，共 150 个纳入样本。
   保留所有失败、未发送和排除尝试及原因，不能只保存最终纳入的行。

## 2. 登记并核实 RPC A/B 独立性

1. 为 A、B 分别登记运营方名称、后端节点或服务身份、上游来源、端点标识、登记时间和可核对的
   服务或节点资料。公开记录不包含访问凭据；保留足以核对实际端点与后端的映射。
2. 核实 A/B 来自不同运营方和不同后端，将独立性依据一并归档。
   不同端口、域名、URL、API key 或网关若共用同一上游，不满足独立性要求。
3. 本地 Anvil 直连加 `rpc-proxy.mjs` 仍共用同一后端。即使使用两个端口、
   `--allow-same-endpoint-local` 且凑齐 N=50，也不合规。
4. DSR 登记自己用于重取的独立 RPC 身份和核对依据，从该 RPC 直接读取链上材料。
   不以 SP 提供的 JSONL、代理响应或 collector 自报代替重取。

现有 `validate.mjs` 只根据归档 URL 的规范化 host/port 检查端点形式，不能证明运营方与后端独立。
端点形式检查通过不构成正式 A6 的独立性证据。

## 3. 在发送前核对链和固定块

1. 从 A/B 分别读取 `chainId`，必须逐值一致。
2. 选定同一 block number，分别取得对应 block hash，要求 number/hash 一致。
   在该固定块核对 Passport、代码和配置、相关初始状态，逐值比较 A/B。
   不把两个各自的 `latest` 响应当作同一块状态。
3. 保存双方原始请求、响应、方法、参数、读取时间与块锚点。
   无法取得固定块状态、无法确认独立性或 A/B 任一分歧，均不得开窗。
4. 每个操作的前后状态及运行末尾 Passport 继续使用固定 block number/hash，并核对 A/B。
   重新核对已记录块的 hash；发现重组立即停窗，不能把同高度新块替换进原窗口。

## 4. 逐操作采集并保留证据

按 SP、VPM、TPM 三臂匹配采集，逐 `userOpHash` 判定，不能用 `receipt.status == success`
代替操作成功。每个纳入操作必须能关联到以下材料，失败和排除尝试也保留其已有材料与缺失原因：

- 窗口、三元组、attempt、arm 的标识，是否纳入，以及 verdict、失败、未发送、排除或停止原因。
- `chainId`、EntryPoint 地址、sender、nonce、paymaster、bundler，完整 packed operation 和 bundle。
- `txHash`、block number、`blockHash`、交易原文及 input，操作在交易中的归属。
- expected/observed `userOpHash`。现有行名包括 `expectedUserOpHash`、`localUserOpHash`、
  `epUserOpHash`；observed 值必须指向原始 UOE 的 `userOpHash` 及其日志位置，不能只重算离线字段。
- A/B 各自的原始 receipt 和完整 logs，UOE 的 address/topics/data/logIndex，相关
  `UserOperationRevertReason`、`PostOpRevertReason`、`UserOperationPrefundTooLow`，
  SP 的 `TransactionSponsored`、锁定与结算、credit 事件。
- 固定块的前后状态和双方 raw response。保留 EntryPoint deposit、operator balance、
  `protocolRevenue`、`inflightOf`、用户 xPNTs、`totalSupply`、`lockedOf`、`debts`、
  `creditReservedOf`、operator `totalSpent`/`totalTxSponsored` 及相应块锚点。
- 起始、逐尝试和结束 Passport，代码地址、runtime code size/codehash、proxy/implementation 绑定、
  配置 getter、价格与 gas 配置；关联 collector、validator、依赖、合约源码、ABI、配置的版本 pin 和 SHA-256。

现有 JSONL 中的 `tx`、`logs`、`userOpEvent`、`readbacks.before/after` 是选取后的记录，
不是双端完整 raw response 档案。正式证据包必须补齐原始材料与逐操作索引。
未发送操作如实记为无 txHash/receipt，不能补造链上材料，也不能计入 150 个纳入样本。

## 5. 冻结归档并预先提交抽样材料

1. 结束采集后，原样封存 append-only JSONL、A/B 完整 raw request/response、所有 receipt/UOE、
   交易与固定块状态、Passport、源码及配置 pin、RPC 身份依据、150 个纳入样本索引、失败和排除清单。
   不修补原始行；派生报告与原始材料分别保存并建立索引。
2. 用现有离线命令核对 JSONL，将输出、退出码和 validator pin 纳入冻结包：

   ```sh
   node script/a6-collector/validate.mjs <run.jsonl> [--json <report.json>]
   ```

   尖括号和方括号表示参数语法。退出 0 表示离线检查 accepted，仍须完成本 SOP 的链上重取和验收。
   退出 1 表示不自洽，2 表示输入或必需字段错误，3 表示自洽但不 accepted。
3. 为冻结包逐文件计算 SHA-256，保存包含路径和摘要的 manifest，并登记 manifest 自身摘要。
   manifest 不列入自身。保存提交位置、时间与冻结版本，禁止覆盖既有材料。
4. 原始证据冻结后，由 DSR 随机选取深查样本。记录抽样 seed、候选全集、选择方法、名单和准确命令，
   命令包括 RPC 身份、块锚点、方法和参数。**在执行任何抽样深查之前，先将 seed、名单、命令提交到
   证据登记处并以 SHA-256 manifest 冻结。** 不得先查结果再补录、换 seed 或换名单。
5. 后续 DSR 全量重取与抽样深查的 raw response、命令、结果和差异单独追加归档，生成关联前版的
   SHA-256 manifest，保留先前冻结包。若签名，签名只证明冻结后的归档未变，不证明链上真实性。

本节是待落实的正式冻结流程。仓库目前没有自动冻结、抽样或预先提交流程，不能声称已有工具执行了这些步骤。

## 6. 由 DSR 全量重取并随机深查

1. DSR 从已登记的独立 RPC 对全部 150 个纳入样本重取 receipt，保留原始响应。
   这是全量核对，不以抽样代替。逐项核对 `txHash`、block number/hash、EntryPoint 地址和 UOE。
2. 逐操作核对 expected/observed `userOpHash`、sender、nonce、paymaster，以及交易 input/bundle 归属。
   确认操作确属该链、该交易、该块中的 EntryPoint v0.7 UOE，检查缺失、重复及无法归因的额外事件。
   不把 collector 的解码结果当作独立重取结果。
3. 按已预先提交并冻结的 seed、名单和命令执行随机深查，从独立 RPC 重取固定块前后状态、
   Passport 代码及配置，重新核对 SP 守恒和各臂 deposit 变化。保留原始响应、计算过程与差异。
   抽样在原始证据冻结后进行，深查范围包括状态、Passport 和守恒，不能只检查 JSONL 是否自洽。
4. 第 6 轮整行伪造并重算哈希的风险由这些链上重取控制。
   不要求离线校验器复刻完整 EntryPoint/VPM/TPM/SimpleAccount 验证，也不得把这些范围外项目记成
   “离线校验器已拒绝”。[README](README.md#信任根与范围) 列出全部范围外项目。
5. 归档 DSR 对 150 个样本的逐项结果、随机深查结果及最终验收结论。
   JSONL、collector 自报和离线 exit 0 都不能单独给出正式合规结论。

## 7. Fail closed，整窗作废

出现以下任一情况，立即停止该窗口并调查；整窗停用、整窗作废（whole window void），不得报告合规 N=50：

- RPC 分歧，或不能证明 A/B 来自不同运营方和不同后端。
- 必需 receipt/UOE 缺失、重复事件、expected/observed hash 不匹配，或交易归属不能确认。
- 区块重组，固定 block number/hash 不再一致，或无法取得对应固定块状态。
- 无法归因的额外 UOE、无法解释的状态变化、SP 守恒失败、Passport 或配置漂移。
- 原始证据不完整、SHA-256 不符，或抽样 seed、名单、命令未在抽样深查前提交冻结。
- DSR 全量重取或随机深查中任一项不符。

保留停止点、差异、失败与排除原因和调查材料。不能仅删除有问题的行、替换样本或重算 JSONL 后
继续使用原窗口的合规结论。再次采集须重新满足开窗前提，使用新窗口及新的冻结记录。

## 8. 限定报告结论

- 只有开窗前提、独立 A/B、50 个匹配三元组、完整冻结证据、离线检查、DSR 全部 150 个重取和
  随机深查均符合本 SOP，才能报告正式 A6 的合规 N=50，并引用 DSR 验收记录。
- 本地 Anvil、双端口 override、合成 fixture 或离线 positive control 只能报告相应量具机制结果。
  #477/#479 的合并不能升级为 A6 真链验收，也不阻塞 A2；A3a 当前仍为 NO-GO。
- 离线校验器不能称为独立链上重放器。不得声称它证明任意离线 JSONL 的链上真实性，或已拒绝
  第 6 轮范围外的整行伪造。归档签名也不能证明链上真实性。

## SP TODO before formal A6

以下能力当前缺失。SP 必须补齐并核对，不能把本 SOP 中的步骤描述当作已实现功能：

- **正式链采集和账户准备。** `collector.mjs` 只接受 `http://127.0.0.1:<port>` 或
  `http://localhost:<port>`，使用 `ANVIL_KEYS` 签名，并依赖 `anvil_impersonateAccount`、
  `anvil_setBalance` 准备账户。尚无可原样用于正式 A6 的远端独立 A/B 与真实账户准备路径。
- **RPC 独立性证据。** 尚无不同运营方、后端与上游身份依据的记录能力。
  `validate.mjs` 的 host/port 判断只检查归档端点形式。
- **双端 raw response 档案。** 尚无 A/B 完整原始请求、响应归档能力。
  `readAB` 对比和 JSONL 中的归一化字段不能替代它。
- **完整逐操作证据包。** 需补齐原始 receipt/UOE、交易归属、固定块状态、源码/配置 pin 与
  纳入、失败、排除清单的关联索引；不能假定现有 JSONL 已覆盖全部要求。
- **排除记录校验。** `validate.mjs` 不读取 `exclusion`，`failingCheck` 只对 NOT_SENT 行核对；
  排除原因缺失或与失败原因矛盾时校验仍接受。需补校验，或列入 DSR 抽检清单逐条核对。
- **冻结和抽样流程。** 尚无文件 SHA-256 manifest 冻结、抽样 seed/名单/命令预先提交、
  深查执行及追加归档流程。
- **DSR 独立重取工具。** 尚无对全部 150 个纳入样本重取 receipt/UOE/交易归属并核对的工具，
  也无固定块状态、Passport、守恒的随机深查与结果记录工具。现有 `validate.mjs` 只读离线文件。
