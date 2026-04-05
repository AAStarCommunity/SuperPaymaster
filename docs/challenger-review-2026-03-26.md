# Challenger Deep Review 报告（2026-03-26）

## 立场与结论
本报告以“挑战者”视角进行深度复审，目标是识别可利用漏洞与性能黑洞。结论：当前代码库存在可利用的逻辑缺口与性能陷阱，**主网发布前需修复至少 P0/P1 项**。

## 关键漏洞（含利用面）
1. **角色视图污染（权限与索引失真）**
位置：`contracts/src/core/Registry.sol`
问题：`safeMintForRole()` 未维护 `userRoles` 数组，导致 `getUserRoles()` 与 `userRoleCount` 不一致。攻击者可利用该不一致制造“无角色/错角色”视图，在前端或索引器上绕过风控或触发错误授权流程。
建议：将 `userRoles` 维护合并进 `_firstTimeRegister()` 或在 `safeMintForRole()` 中补齐。

2. **PaymasterV4 价格计算溢出 → 拒绝服务**
位置：`contracts/src/paymasters/v4/PaymasterBase.sol`
问题：`_calculateTokenCost` 中多重乘法可能溢出并 revert。攻击者通过选择异常 `tokenDecimals` 或极高 `gasCostWei` 触发拒绝服务，导致 Paymaster 不可用。
建议：分段 `mulDiv`，并对 `tokenDecimals` 与 `maxGasCostCap` 设置硬性上限。

3. **SuperPaymaster `postOp` 外部依赖失败 → 赔付风险**
位置：`contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`
问题：`recordDebt()` 失败会导致 `postOp` revert，产生资金一致性问题与赔付风险。攻击者可通过异常 token 行为触发。
建议：`try/catch` + 失败事件 + 进入补偿队列。

## 性能黑洞与可扩展性风险
1. **Registry 使用字符串索引导致长期高 gas**
位置：`contracts/src/core/Registry.sol`
问题：`communityByName`/`communityByENS` 使用 string 作为 key，长期存储成本高，且容易因规范化问题导致重复索引与垃圾数据。
建议：引入 `bytes32` 索引与前端映射，分阶段迁移。

2. **GTokenStaking 零金额 lock 残留**
位置：`contracts/src/core/GTokenStaking.sol`
问题：`slash()` 可将 lock 归零，但不清理 `userActiveRoles`，导致枚举噪音与额外读写开销。
建议：当 lock 归零时移除 role。

3. **PaymasterV4 `postOp` 使用外部自调用**
位置：`contracts/src/paymasters/v4/PaymasterBase.sol`
问题：`this.calculateCost()` 引入外部调用开销与失败风险，且增加 gas。
建议：改为 internal 路径调用。

4. **BLS 模块高成本路径缺少严格边界**
位置：`contracts/src/modules/monitoring/BLSAggregator.sol`、`contracts/src/modules/validators/BLSValidator.sol`
问题：BLS 验证成本高，若治理流程或外部系统错误调用，会导致严重 gas 消耗。
建议：严格限定调用路径与频率，增加治理层阈值与速率限制。

## 经济模型风险（挑战者视角）
1. **质押池化风险**
GTokenStaking 采用共享池模型，slash 会影响所有质押者，易被攻击者利用治理/舆论造成挤兑与信誉攻击。

2. **小额退出费用不公平**
`minFee` 与 `feePercent` 叠加可能导致小额用户退出成本异常高，攻击者可利用引导恐慌或声誉攻击。

## 文档与运维漏洞
1. `.env` 路径与脚本配置不统一，易出现“环境漂移”导致错误部署或测试失效。
2. 缺少测试/覆盖率/静态扫描的硬门槛，发布风险不可量化。
3. 版本字符串分散且缺少统一映射，主网公告可能与链上版本不一致。

## 结论与奖励级别建议
- **漏洞级（奖励优先）**：Registry 角色视图污染、PaymasterV4 价格溢出、SuperPaymaster postOp 外部依赖失败。
- **性能黑洞级**：字符串索引、零金额锁残留、外部自调用、BLS 高成本路径无边界。

## 发布前最小修复清单
1. 修复 `safeMintForRole` 的 `userRoles` 维护。
2. 修复 PaymasterV4 价格计算溢出风险。
3. 为 SuperPaymaster `postOp` 添加容错与告警。
4. 明确关键参数安全区间并写入发布流程。

## 限制说明
本报告为静态挑战性审计，未运行测试或自动化扫描。主网发布前必须补齐测试与安全工具报告。
