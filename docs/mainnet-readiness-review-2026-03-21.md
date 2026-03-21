# SuperPaymaster 主网发布前严格审查报告（2026-03-21）

## 执行摘要
从严格审查角度看，当前合约体系结构成熟，但**不建议在未修复中危问题与完善运维约束前直接主网发布**。主要风险集中在：
1) 逻辑一致性缺口（Registry 的角色列表）；
2) 价格路径与外部调用的容错；
3) 关键参数与运营流程在文档中的硬性约束不足；
4) 可扩展性与链上数据增长的长期成本。

结论：**主网发布前建议先完成 P0/P1 修复与运维补强**（见“结论与行动项”）。

## 审查范围与方法
范围覆盖 `contracts/src/` 全部合约与模块，并结合部署脚本、文档与配置文件进行一致性检查。未执行测试与自动化安全扫描，仅基于静态阅读与逻辑推断。

## 核心信任假设
1. Owner/DAO/多签拥有最终权限并可升级关键合约（Registry、PaymasterFactory、SuperPaymaster）。
2. Oracle、Keeper、DVT/BLS 聚合器等外部系统可靠且有明确 SLA。
3. 关键参数由可信治理设置并遵守安全区间（gas cap、费用、价格阈值等）。

## 关键安全发现（分级）
### 中危
1. **Registry 角色列表不一致**：`safeMintForRole()` 未维护 `userRoles` 数组，`getUserRoles()` 与 `userRoleCount` 不一致，影响权限追踪与下游系统。涉及 `contracts/src/core/Registry.sol`。
2. **PaymasterV4 价格计算潜在溢出**：`_calculateTokenCost` 中多项乘法可能在高 gas cap 或异常 decimals 下溢出，导致拒绝服务。涉及 `contracts/src/paymasters/v4/PaymasterBase.sol`。
3. **SuperPaymaster `postOp` 外部调用无容错**：`recordDebt()` 失败会导致 `postOp` 失败与赔付风险。涉及 `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`。

### 低危/提示
1. **xPNTsToken auto-approved 无限 allowance**：需明确强信任边界与治理限制，否则名单合约被入侵即导致用户资产风险。涉及 `contracts/src/tokens/xPNTsToken.sol`。
2. **Registry 名称/ENS 缺少规范化**：字符串 key 无大小写/Unicode 规范化，易产生“视觉重复”社区。涉及 `contracts/src/core/Registry.sol`。
3. **GTokenStaking 零金额锁残留**：`slash()` 可使 role lock 变 0，但未清理 `userActiveRoles`，造成枚举噪音与额外 gas。涉及 `contracts/src/core/GTokenStaking.sol`。
4. **Oracle 校验不完整**：`updatePrice()` 未验证 `updatedAt` 与 `answeredInRound`。涉及 `contracts/src/paymasters/v4/PaymasterBase.sol`。
5. **关键参数安全区间未文档化**：`maxGasCostCap`、`serviceFeeRate`、`priceStalenessThreshold` 等缺少硬性边界与运维指引。
6. **BLS 执行成本高**：BLS 相关模块需明确仅在治理/惩罚路径调用，避免误入高频热路径。

## 经济模型与风险评估
1. **质押与 slash**：GTokenStaking 采用共享资金池模式，slash 会影响全体锁仓余额，需在用户与社区文档中明确风险并设置治理约束。
2. **信用模型**：SuperPaymaster 通过 `recordDebt` 记录债务，若 token 侧异常会导致未记录债务与资金不一致。必须加容错与监控。
3. **费用结构**：出口费 `minFee` 与 `feePercent` 的组合可能对小额用户不公平，建议提供参数边界与运营策略。

## 可扩展性与链上成本
1. Registry 使用字符串与动态 bytes 作为主索引，长期存储成本高，建议对关键索引采用 `bytes32` 并在前端做映射。
2. 多处使用数组存储成员列表，删除虽采用 swap&pop，但仍可能产生大规模枚举成本。建议将“列表型查询”逐步转移到索引器或子图。

## 运维与部署风险
1. 部署脚本依赖 `.env.*` 与多路径配置，存在环境路径不统一的问题（例如 E2E 脚本路径）。建议统一环境变量读取路径与规范。
2. 目前 CI 以 secrets 扫描为主，缺少测试、覆盖率与静态分析的强制门槛。主网发布前应建立基础 CI 安全门槛。

## 文档合规与一致性
1. 文档数量多且存在版本分散，容易出现主网版本与运行时版本字符串不一致。
2. 运维与关键参数安全区间缺乏“强制性”描述，建议补充“不可低于/高于”的硬规则。
3. 需要在文档中显式声明外部依赖与 SLA（Oracle、Keeper、DVT）。

## Gas 效率分析（严格视角）
1. 优点：SuperPaymaster 采用缓存与打包结构降低热路径成本；Registry 的成员索引维护方式较为高效。
2. 风险：字符串索引、动态 bytes 与频繁事件写入会显著提高长期成本，建议区分热路径与冷路径写入。
3. 建议：将价格计算改为分段 `mulDiv`，减少中间溢出风险并提升稳定性。

## 结论与行动项（主网发布前必须完成）
### P0（发布阻断）
1. 修复 Registry 角色列表一致性问题（`safeMintForRole`）。
2. 修复 PaymasterV4 价格计算溢出风险。
3. 为 SuperPaymaster 的 `postOp` 外部调用增加容错与告警。

### P1（发布前强烈建议）
1. Oracle 校验补齐与 Keeper SLA 文档化。
2. 关键参数安全区间明确化并加入部署清单。
3. 文档统一版本映射与主网发布声明。

### P2（上线后优化）
1. 链上字符串索引优化为 `bytes32`。
2. 零金额 role lock 清理与列表压缩策略。
3. 增强 CI（测试、覆盖率、静态扫描）门槛。

## 限制说明
本报告为静态审核结论，未运行测试或自动化扫描。若主网发布迫在眉睫，至少应补齐本地测试、覆盖率与 Slither/Aderyn/Echidna 报告，并由多签复核关键参数与外部依赖。
