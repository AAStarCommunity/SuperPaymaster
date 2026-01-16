# xPNTs 安全模型重构对比 (Security Refinement: Global -> Local)

## 1. 核心逻辑变动概要
为了符合“社区 Paymaster 只能花费对应社区 Gas Token”的业务约束，我们将授权重心从 **工厂 (Factory)** 转移到了 **代币 (Token)** 合约本身。

### 📊 变动对比表
| 特性 | 重构前 (Pre-Refinement) | 重构后 (Post-Refinement) |
| :--- | :--- | :--- |
| **授权中心** | `xPNTsFactory` (中心化全局白名单) | `xPNTsToken` (分布式本地授权点) |
| **信赖边界** | 任何白名单 Paymaster 可花费任何 xPNTs | 仅指定 Paymaster + SuperPaymaster 可花费 |
| **授权时机** | 部署后通过 `addPaymaster` 独立调用 | 部署时通过 `deployxPNTsToken` 一次性绑定 |
| **工厂角色** | 鉴权中心 + 部署器 | 仅作为部署器 + 记录 `SUPERPAYMASTER` |

---

## 2. 代码变动详述

### [xPNTsFactory.sol]
```diff
- mapping(address => bool) public whitelistedPaymasters;
- 
- function addPaymaster(address pm) external onlyOwner {
-     whitelistedPaymasters[pm] = true;
- }

  function deployxPNTsToken(
      ...,
+     address paymasterAOA // 新增参数：该代币专属 Paymaster
  ) external returns (address token) {
      ...
      // AOA+ mode: 全局 SuperPaymaster 依然拥有权限
      if (SUPERPAYMASTER != address(0)) {
          newToken.addAutoApprovedSpender(SUPERPAYMASTER);
      }
      // AOA mode: 仅授予该社区专属 Paymaster 权限
+     if (paymasterAOA != address(0)) {
+         newToken.addAutoApprovedSpender(paymasterAOA);
+     }
  }
```

### [Deployment Scripts]
```diff
- factory.addPaymaster(address(paymasterProxy)); // 已移除
- factory.deployxPNTsToken(..., address(0));
+ factory.deployxPNTsToken(..., address(paymasterProxy)); // 部署即绑定
```

---

## 3. 对回归测试的影响
由于 `whitelistedPaymasters` 映射和 `addPaymaster` 函数已移除：
1. **API 破坏**：若脚本调用了 `addPaymaster`，交易会 revert。
2. **逻辑失效**：若脚本先部署代币再（期望通过工厂）授权 Paymaster，则该 Paymaster 在新模型下将无权划转用户资产。

---
**调试计划**：我将逐一检查 `scripts/12_test_staking_slash.ts` 等失败脚本，确保它们在代币部署阶段正确传入了 Paymaster 地址，或者通过 `token.addAutoApprovedSpender` 手动完成了本地授权。
