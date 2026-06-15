# Sepolia Deployment Record — v5.4.0-beta.1

**部署时间**: 2026-06-15 CST
**触发原因**: v5.4 "god-split" — 将 x402 结算从 SuperPaymaster 拆分为独立 `X402Facilitator`，新增 DVT 消费策略合约 `PolicyRegistry` + `TimelockController` 治理器，并就地 UUPS 升级 SuperPaymaster / Registry 实现
**部署脚本**: `contracts/script/v3/DeployV54.s.sol:DeployV54` (`--broadcast`)
**广播路径**: publicnode RPC 广播（规避 Alchemy ghost-nonce），Alchemy 仅用于读
**链**: Sepolia Testnet (Chain ID: 11155111)

---

## 一、新部署 / 升级合约地址

### 新部署（独立合约）

| 合约 | 地址 | 说明 |
|------|------|------|
| **X402Facilitator** | `0xFe95a77e4Db593E6EA88000Aad9cD1230BAB4512` | `X402Facilitator-1.0.0` — 从 SuperPaymaster 拆出的 x402 结算层；非升级，`owner = deployer`。`settleX402Payment` (EIP-3009 `receiveWithAuthorization`) + `settleX402PaymentDirect` (xPNTs `transferFrom`) + 费用模型 |
| **TimelockController** | `0x6cEc100c9CDc6ee7D9EDe0533edD3554E641DdBF` | OZ v5.0.2 `TimelockController`，`minDelay = 2 days`；Sepolia bootstrap 下 proposer/executor/admin = deployer（GA 时移交多签） |
| **PolicyRegistry** | `0x37e4E40e69Fb7d5C3fbAA0F52A4002D27472Ff29` | `PolicyRegistry-1.0.0` — sender-keyed、受治理门控的 DVT 触发 / 消费策略；ctor(`timelock`, `guardian`, `initialConsumer = SuperPaymaster proxy`)；非升级 |

### UUPS 就地升级（proxy 不变，impl 替换）

| 合约 | Proxy | 新 Implementation | 旧 Implementation |
|------|-------|-------------------|-------------------|
| **SuperPaymaster** | `0xFb090E82bD041C6e9787eDEbE1D3BE55b3c7266a` | `0xE84Ae83Eb1fF99AF859e5FADA1104A8376a96d7A` | `0x52C1E6f039eb9BA50ac9Ad0D041cB07Dcf4C9AA0` |
| **Registry** | `0xB5Fb8920F7AcD8b395934bd1F21222b32A30eF1A` | `0x0B5ce7032804aEFA698bddeB355D1FDDc553c14A` | `0xC931F91D134A16cCDfe4bf37EdEff217c9f193F1` |

- SuperPaymaster 新 impl：god-split 后的实现（结算/策略外移）。链上 `version()` 仍为 `SuperPaymaster-5.3.3`，升至 `5.4.0` **推迟到 GA**。
- Registry 新 impl：携带 #211 L-C 修复。
- 两者均通过 `upgradeToAndCall(newImpl, "")` 升级，UUPS 存储布局保持兼容（仅替换逻辑，不改 proxy 存储），无需重新 wiring。

### 不变的现有部署

EntryPoint v0.7 `0x0000000071727De22E5E9d8BAf0edAc6f37da032` · SimpleAccountFactory `0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985` · Chainlink ETH/USD `0x694AA1769357215DE4FAC081bf1f309aDC325306`。完整地址见 [`deployments/config.sepolia.json`](../../../deployments/config.sepolia.json)（已 patch）。

---

## 二、部署 / 升级流程（DeployV54.s.sol）

1. **X402Facilitator**（新部署）— `ctor(IRegistry registry, IxPNTsFactory factory)`，`owner = deployer`。
2. **TimelockController**（新部署）— `minDelay = 2 days`，proposer/executor/admin = `governor`（Sepolia 默认 deployer，可用 `GOVERNOR_ADDRESS` 覆盖）。
3. **PolicyRegistry**（新部署）— `ctor(timelock, guardian, initialConsumer = SuperPaymaster proxy)`；`guardian` 默认 deployer（可用 `GUARDIAN_ADDRESS` 覆盖）。
4. **SuperPaymaster** 新 impl（god-split）→ `upgradeToAndCall(newImpl, "")`。
5. **Registry** 新 impl（#211 L-C fix）→ `upgradeToAndCall(newImpl, "")`。

> 每个社区级 wiring 步骤都门控在 `communityOwner == deployer`；不匹配时仅 LOG 为手动 follow-up，不阻断部署。

---

## 三、链上验证状态（部署后即时核对）

| 检查项 | 结果 |
|--------|------|
| 5 个地址均有 code | ✅ |
| SuperPaymaster proxy impl slot → 新 impl `0xE84Ae83E…` | ✅ |
| Registry proxy impl slot → 新 impl `0x0B5ce703…` | ✅ |
| Deployer nonce +9 全部 mined | ✅ |
| publicnode 广播未出现 Alchemy ghost-nonce | ✅ |

**Etherscan 验证**: 5 个合约源码验证随发布跟进（X402Facilitator / PolicyRegistry / TimelockController 为新合约需 verify；SuperPaymaster / Registry 新 impl 为新字节码需 verify）。

---

## 四、ABI / 配置更新

- 新增 `abis/X402Facilitator.json`、`abis/PolicyRegistry.json`、`abis/TimelockController.json`。
- `scripts/extract_v3_abis.sh` 增加 `PolicyRegistry` + `TimelockController` 抽取项。
- 重新生成 `abis/abi.config.json`（刷新 `buildTime` / `totalHash` / 全量文件哈希）。
- `node scripts/gen-abi-docs.mjs --check` 通过（48 contracts, 808 functions, 227 errors, 166 events）。
- `deployments/config.sepolia.json` 已写入 `x402Facilitator` / `policyRegistry` / `timelockController` / 新 `spImpl` / 新 `registryImpl`。

---

## 五、E2E 验证摘要

- **Gasless 主链路不变**：SuperPaymaster / Registry 走 UUPS 就地升级，存储布局兼容、proxy 地址不变，PaymasterV4 + SuperPaymaster 的 gasless 赞助路径与 `v5.3.3-beta.5` 基线一致，无需重跑既有 gasless 套件即可继承其绿色结果。
- **x402 结算路径迁移**：x402 结算从 SuperPaymaster 内嵌函数迁至独立 `X402Facilitator`；调用方需把 facilitator 目标从 SP proxy 切到 `0xFe95a77e…`，并按新签名携带 `maxFee`（EIP-3009 `receiveWithAuthorization`）。E2E x402 用例随 SDK 切换更新后重跑。
- **网络容错**：E2E 套件已包含 PR #267 的冗余广播 + 网络重试改造（Alchemy 读 + publicnode 广播），与本次部署广播策略一致。

### 链上 E2E 验证（已跑，真实交易）

部署后已在 Sepolia 实跑 E2E，所有交易链上确认（publicnode 冗余广播，无 Alchemy 幽灵 nonce）。测试脚本经 Codex 对抗挑战，false-green（断言失败仍 exit 0）已修复——下表为**退出码可靠后重跑**的结果：

| E2E 用例 | 结果 | 链上交易 |
|---|---|---|
| 核心 gasless（PaymasterV4 + SuperPaymaster×2 + credit/debt） | ✅ PASS（xPNTs burn 487→444，debt 不变） | [`0x1314974448…`](https://sepolia.etherscan.io/tx/0x1314974448fbcf6e9d9fadaf4b3e722f397b67a6a1af0b2ae8467e0f700ed324) |
| x402 direct settle（xPNTs，含重放拒 + C-02 recipient binding） | ✅ PASS（payee +1 xPNTs，NonceAlreadyUsed，redirect→InvalidX402Signature） | [`0x3bb790b6…`](https://sepolia.etherscan.io/tx/0x3bb790b6c7e82e4c1e5ff4609c9737aff089671b60e2fd43f44dc852547b317f) |
| EIP-3009 settle（USDC `receiveWithAuthorization`，含重放拒） | ✅ PASS（payee +1 USDC，ReceiveWithAuthorization typehash，nonce consumed） | [`0x878dbb0b…`](https://sepolia.etherscan.io/tx/0x878dbb0b236c3ed9e300092ebb8a3d7e9f7f99b55690ebc0d5ebd7ffea2af0bd) |

> 重放保护 + C-02 + ReceiveWithAuthorization typehash 链上 PASS——验证了 god-split 后 X402Facilitator 的 nonce/签名一致性修复有效（经 Codex 多轮挑战）。

---

## 六、部署后手动步骤（推迟到 GA）

1. **多签 / Timelock 移交**：当前 Sepolia bootstrap 下 `governor`（Timelock proposer/executor/admin）与 `guardian` 均为 deployer。GA 前需将 Timelock 治理权与 X402Facilitator `owner` 移交到运营商 Safe 多签。
2. **`POLICY_REGISTRY_ADDRESS` 交接到 #110**：把 `0x37e4E40e…` 作为 `POLICY_REGISTRY_ADDRESS` 交给消费方 wiring（SuperPaymaster / AirAccount consumer 授权、issue #110）。PolicyRegistry 已在部署时把 SuperPaymaster proxy 设为 `initialConsumer`；AirAccount 等其余 consumer 经 Timelock `setConsumerAuthorization` 增量授权。

---

*生成时间: 2026-06-15 | 环境: Sepolia Testnet (Chain ID: 11155111) | 发布: v5.4.0-beta.1（god-split）*
