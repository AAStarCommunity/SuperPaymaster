# SuperPaymaster 严格全面审计报告（2026-03-22）

## 结论与发布判断
以“主网即刻发布”的严格标准衡量，当前状态**不建议直接发布主网**。理由是：
1) 存在中危逻辑一致性缺口；
2) 价格路径与外部调用容错不足，存在经济与可用性风险；
3) 文档与运维约束不够“硬”，可导致参数误配或 SLA 失败。

发布门槛建议：至少完成 P0/P1 修复与运维补强后再进入主网发布窗口。

## 审计范围与方法
覆盖 `contracts/src/` 全量合约与模块（Registry、GTokenStaking、MySBT、PaymasterV4、SuperPaymaster、xPNTsToken/xPNTsFactory、BLS/DVT/ReputationSystem、账户与工厂、EntryPoint 与接口/工具库）。未运行测试与自动化工具，结论基于静态阅读与逻辑推断。

## 系统性风险与信任假设
1. 多签/Owner 拥有升级与关键参数控制权，治理安全是系统安全的上限。
2. Oracle、Keeper、DVT/BLS 聚合器的可靠性是系统可用性与经济正确性的核心依赖。
3. 关键参数（gas cap、费用、阈值）对经济模型影响显著，必须有强制约束与公开策略。

## 风险发现（按严重级别）
### 中危
1. **Registry 角色列表一致性缺口**
`safeMintForRole()` 未维护 `userRoles` 数组，导致 `getUserRoles()` 与 `userRoleCount` 不一致，影响权限追踪与下游系统。位置：`contracts/src/core/Registry.sol`。建议将 `userRoles` 维护集中在 `_firstTimeRegister()` 或在 `safeMintForRole()` 补齐。

2. **PaymasterV4 价格计算潜在溢出与拒绝服务**
`_calculateTokenCost` 中多项乘法在高 gas cap 或异常 decimals 下可能溢出并 revert，导致验证或结算拒绝服务。位置：`contracts/src/paymasters/v4/PaymasterBase.sol`。建议分段 `mulDiv` 或限制 `tokenDecimals` 与 `maxGasCostCap`。

3. **SuperPaymaster `postOp` 外部调用无容错**
`recordDebt()` 若异常会导致 `postOp` 失败并引发赔付风险。位置：`contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`。建议 `try/catch` 并事件告警或补偿队列。

### 低危/提示
1. **xPNTsToken auto-approved 无限 allowance**
autoApproved 合约被入侵将危及用户资产。位置：`contracts/src/tokens/xPNTsToken.sol`。建议加强治理流程与名单审批。

2. **Registry 名称/ENS 规范化缺失**
字符串 key 无大小写/Unicode 规范化，可能出现“视觉重复”社区。位置：`contracts/src/core/Registry.sol`。

3. **GTokenStaking 零金额锁残留**
`slash()` 可能使 lock 变 0，但未清理 `userActiveRoles`，造成枚举噪音与额外 gas。位置：`contracts/src/core/GTokenStaking.sol`。

4. **Oracle 校验不完整**
`updatePrice()` 未验证 `updatedAt` 与 `answeredInRound`。位置：`contracts/src/paymasters/v4/PaymasterBase.sol`。

5. **DVTValidator 允许无效提案执行入口**
`executeWithProof()` 未校验提案是否存在或已创建，仅靠 BLS 证明约束。虽风险较低，但可被用于无意义调用与监控噪音。位置：`contracts/src/modules/monitoring/DVTValidator.sol`。

6. **ReputationSystem 输入长度未显式校验**
`computeScore()` 假定 `communities/ruleIds/activities` 维度一致，长度不匹配会 revert。位置：`contracts/src/modules/reputation/ReputationSystem.sol`。建议加入长度检查或在调用方保证一致性。

## 经济与扩展性审查
1. **质押与 slash 的“池化风险”**
GTokenStaking 采用共享资金池，slash 会影响全体锁仓余额，必须在用户文档与产品界面明确披露，并设置治理红线。

2. **费用结构对小额用户的冲击**
`minFee` 叠加 `feePercent` 会对小额退出产生高比例损失，需给出参数建议区间与收费策略。

3. **数据增长成本**
Registry 使用字符串与动态 bytes 作为主索引，长期存储成本高，建议对关键索引使用 `bytes32` 哈希并由前端映射。

## Gas 与性能审查
1. 优化点已存在：打包结构、缓存价格、swap&pop 删除。
2. 风险点仍在：字符串索引、动态 bytes、频繁事件记录会持续抬升成本。
3. PaymasterV4 使用 `this.calculateCost()` 外部自调用增加热路径开销，建议改为 internal 路径。

## 运维与文档合规检查
1. 部署与 E2E 脚本依赖多处 `.env` 路径，存在路径不一致与可迁移性风险。
2. CI 当前以 secrets 扫描为主，缺少测试、覆盖率与静态分析的“硬门槛”。
3. 文档多版本并存，缺少“单一权威入口”，可能导致主网版本与运行时版本字符串不一致。
4. 外部依赖（Oracle、Keeper、DVT）未形成 SLA 级别的运维要求与告警机制。

## 主网发布前行动清单
### P0（发布阻断）
1. 修复 Registry 角色列表一致性问题。
2. 修复 PaymasterV4 价格计算溢出风险。
3. 为 SuperPaymaster `postOp` 外部调用添加容错与告警。

### P1（发布前强烈建议）
1. Oracle 校验补齐并落地 Keeper SLA 文档。
2. 关键参数安全区间明确化并加入发布清单。
3. 文档统一版本映射与主网发布声明。

### P2（上线后优化）
1. 链上字符串索引优化为 `bytes32`。
2. 零金额锁清理与列表压缩策略。
3. CI 引入测试、覆盖率与静态扫描门槛。

## 限制说明
本报告未运行测试或自动化扫描，结论基于静态阅读与逻辑推断。主网发布前必须补齐本地测试与自动化扫描报告，并由多签复核关键参数与外部依赖。
