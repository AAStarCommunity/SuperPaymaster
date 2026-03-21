# SuperPaymaster 合约安全与 Gas 审计报告（2026-03-21）

## 范围与方法
本报告为静态审计与逻辑一致性检查，覆盖 `contracts/src/` 下核心合约与关键模块，包括 Registry、GTokenStaking、MySBT、xPNTsToken/xPNTsFactory、PaymasterV4、SuperPaymaster、BLS/DVT 相关模块及工厂合约。未运行测试、未执行链上验证或自动化工具扫描。

## 总结
整体架构清晰，角色注册、质押、SBT 与 Paymaster 的协作逻辑完整。风险主要集中在：
1) 少数路径的逻辑一致性缺口；
2) 价格路径与外部调用的容错；
3) 可配置项的安全边界与文档约束不完全同步。

## 发现概览
- 严重/高危：0
- 中危：3
- 低危/提示：5

## 中危发现
1. `Registry.safeMintForRole` 未维护 `userRoles` 数组
证据：`contracts/src/core/Registry.sol` 中 `safeMintForRole()` 调用 `_firstTimeRegister()` 但未执行 `userRoles[user].push(roleId)`。而 `registerRole()` 路径会维护该数组。导致 `getUserRoles()` 结果与实际角色不一致，可能影响前端/索引与下游逻辑。建议将 `userRoles` 的写入逻辑统一到 `_firstTimeRegister()` 或在 `safeMintForRole()` 补齐。

2. PaymasterV4 价格计算潜在溢出导致拒绝服务
证据：`contracts/src/paymasters/v4/PaymasterBase.sol` 中 `_calculateTokenCost` 先做多项乘法再 `Math.mulDiv`，在高 gas cap 或异常 decimals 下可能溢出并 revert。建议分段 `mulDiv` 或限制 `tokenDecimals` 和 `maxGasCostCap` 上限。

3. SuperPaymaster `postOp` 对外部 token 调用无容错
证据：`contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol` 中 `postOp()` 直接调用 `IxPNTsToken.recordDebt`。若 token 异常会导致 `postOp` 失败并触发赔付风险。建议 `try/catch` 并记录失败事件或进入补偿队列。

## 低危/提示
1. `xPNTsToken` auto-approved spender 具无限 allowance
证据：`contracts/src/tokens/xPNTsToken.sol` 中 `allowance()` 对 autoApprovedSpenders 返回 `type(uint256).max`，且 `burn()` 仅禁止 SuperPaymaster，但其他 autoApproved 仍可烧毁用户资产。需明确信任边界与治理流程。

2. Registry 名称/ENS 去重缺少规范化
证据：`contracts/src/core/Registry.sol` 以字符串作为 key (`communityByName`/`communityByENS`)；未做大小写或 unicode 规范化，可能产生“视觉重复”社区。建议前端与合约层统一规范化策略。

3. GTokenStaking 的 `userActiveRoles` 可能保留零金额角色
证据：`contracts/src/core/GTokenStaking.sol` 中 `slash` 可能将 `roleLocks[roleId].amount` 降至 0，但未同步移除 `userActiveRoles`，造成枚举噪音与额外 gas。建议在锁变 0 时清理数组。

4. Oracle 响应校验不完整
证据：`contracts/src/paymasters/v4/PaymasterBase.sol` 的 `updatePrice()` 仅校验 `price > 0`，未验证 `updatedAt` 与 `answeredInRound`。建议加入标准 Chainlink 校验。

5. 可配置项的安全边界需文档化
例如 `maxGasCostCap`、`serviceFeeRate`、`priceStalenessThreshold` 等关键参数，若设置不当会造成拒绝服务或经济性偏差。建议在部署文档中给出安全区间建议。

## Gas 效率分析（概览）
正向优化：SuperPaymaster 使用 `UserOperatorState` 打包与缓存价格降低热路径 SLOAD；Registry 使用 `roleMemberIndex` + swap&pop 删除避免 O(n) 级数组删减。

可优化点：
1. Registry 中大量字符串与动态 bytes 的存储与比较成本高，建议对关键索引字段使用 `bytes32` 哈希并在前端做可读映射。
2. PaymasterV4 `postOp` 中 `this.calculateCost()` 外部自调用引入额外开销，可改为 internal 纯函数路径。
3. BLS 相关模块（`BLSValidator`/`BLSAggregator`）执行成本高，建议确保其只在管理/惩罚路径触发。

## 逻辑一致性检查（关键路径）
- **角色注册/退出**：`registerRole` 与 `exitRole` 状态更新基本完整，但 `safeMintForRole` 与 `userRoles` 不一致（中危）。
- **质押与 slash**：GTokenStaking 已将 slash 影响分摊到 role locks，避免余额与统计不一致；但零金额锁的残留建议清理。
- **SBT 与 Registry**：Registry 控制 SBT 的 mint/burn 与成员激活逻辑集中，安全边界清晰。
- **Paymaster 资金路径**：V4 deposit-only 模型清晰，主要风险为价格与参数配置；V3 信用模型依赖 token 记录债务，需容错。

## 建议清单（摘要）
1. 修复 `safeMintForRole` 的 `userRoles` 维护缺口。
2. 重构 PaymasterV4 价格计算为分段 `mulDiv` 或限制 `tokenDecimals`。
3. `postOp` 外部调用加 `try/catch` 并事件上报。
4. Registry 名称/ENS 规范化策略固化。
5. 文档中明确关键参数的安全范围与 Keeper 运维要求。

## 限制说明
本报告未执行测试与自动化扫描，仅基于静态阅读与逻辑推断。建议在本地通过 `forge test`、`forge coverage`、Slither/Aderyn/Echidna 等补齐验证结果。
