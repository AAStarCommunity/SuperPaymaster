# SDK x402 集成文档

> 文档日期：2026-04-27
> 关联仓库：aastar-sdk（main 分支）/ SuperPaymaster（security/audit-2026-04-25）/ SuperPaymaster packages/x402-facilitator-node
> 本文目的：把 SDK 中的 `@aastar/x402`、`@aastar/channel`、`@aastar/cli`、`@aastar/core` 与 SuperPaymaster 合约、x402 facilitator-node 服务三者的对接讲清楚，给出接入示例、签名细节、HMAC 握手流程、联调清单和 SDK 仍需补的工作项。

---

## 1. 概览：x402 在 SDK / facilitator / SP 三方的角色分工

```
┌─────────────────────┐    HTTP (x402 v2)    ┌────────────────────────────┐    JSON-RPC      ┌─────────────────────┐
│ Client (SDK / dApp) │◄────────────────────►│ Facilitator-Node (operator)│◄────────────────►│ SuperPaymaster (SP) │
│ @aastar/x402        │  /verify  /settle    │ packages/x402-facilitator- │  settleX402*     │ V5.3 + P0-13        │
│ @aastar/channel     │  /quote   /supported │ node (Hono on Node)        │  x402Settlement* │ UUPS proxy on SP    │
│ @aastar/cli         │  X-Challenge (HMAC)  │ middleware/hmac-challenge  │  facilitatorFee* │ x402NonceKey() ★    │
└─────────────────────┘                      └────────────────────────────┘                  └─────────────────────┘
```

三方分工：

| 层 | 职责 | 关键模块 |
|----|------|----------|
| SuperPaymaster (链上) | 真正记账：`settleX402Payment` (EIP-3009) / `settleX402PaymentDirect` (xPNTs)；nonce 三元组防重放；`facilitatorFeeBPS`/operator 自定义费率 | `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol` |
| Facilitator-Node (服务端) | x402 协议门面：HTTP `/verify`(链下签名校验) `/settle`(写链) `/quote` `/.well-known/x-payment-info`；可选 HMAC 防机器人 | `packages/x402-facilitator-node/src` |
| SDK (客户端) | 帮 dApp / 钱包 / agent 生成 EIP-3009 typed-data、调 facilitator、按 x402 v2 协议处理 402 → sign → retry；同时直接调链上 settle 函数（自托管模式） | `packages/x402/`、`packages/core/src/actions/x402.ts`、`packages/cli` |

> 关键差别：x402-facilitator-node 是 SuperPaymaster 自家维护的、专用于 SP 业务的 facilitator 实现；它和 Coinbase 公开的 x402 facilitator 协议**当前不完全兼容**（schema 用了简化字段而非 v2 spec 的 `paymentPayload/paymentRequirements`），SDK 通过 `FacilitatorClient` 接的是 v2 spec。下面"实现盘点"会标注这一差异。

---

## 2. 当前 SDK 实现盘点

### 2.1 `@aastar/x402` (v0.18.0)

源码在 `aastar-sdk/packages/x402/src/`：

| 模块 | 文件 | 状态 |
|------|------|------|
| 类型定义（v2 align） | `types.ts` | 已实现 |
| EIP-3009 EIP-712 typed-data 签名 | `eip3009.ts` | 已实现 |
| x402 v2 header 编解码 (PAYMENT-REQUIRED / PAYMENT-SIGNATURE / PAYMENT-RESPONSE，含 v1 X-PAYMENT 兼容) | `payment-header.ts` | 已实现 |
| HTTP `FacilitatorClient` (verify/settle/supported) | `facilitator.ts` | 已实现 |
| `X402Client` 高级 API | `X402Client.ts` | 已实现 |
| `x402Fetch` 自动 402 → sign → retry | `X402Client.ts` `x402Fetch()` | 已实现，有 TODO（部分 server 把 PaymentRequired 放 body 而非 header） |
| HMAC challenge 客户端封装 | — | **TODO（缺失，详见 §10）** |
| Direct path（xPNTs，无签名） | `X402Client.settleDirectOnChain()` | 已实现（链上直发） |
| Settlement via external facilitator | `X402Client.settleViaFacilitator()` | 已实现 |

入口导出（`packages/x402/src/index.ts`）：

```ts
export { X402Client, type X402ClientConfig } from './X402Client.js';
export { FacilitatorClient } from './facilitator.js';
export type {
  X402PaymentParams, PaymentRequired, PaymentPayload, PaymentRequirements,
  SettleResponse, VerifyResponse, FacilitatorSupported, FacilitatorConfig,
  EIP3009Authorization, DirectPaymentPayload, ResourceInfo, NetworkId,
} from './types.js';
export { signTransferWithAuthorization, generateNonce, getEIP3009Domain, EIP3009_TYPES } from './eip3009.js';
export {
  encodePaymentRequired, decodePaymentRequired,
  encodePaymentPayload, decodePaymentPayload,
  encodeSettleResponse, decodeSettleResponse,
  extractPaymentRequired, extractSettleResponse,
  HEADER_PAYMENT_REQUIRED, HEADER_PAYMENT_SIGNATURE, HEADER_PAYMENT_RESPONSE,
  HEADER_V1_PAYMENT, HEADER_V1_PAYMENT_RESPONSE,
} from './payment-header.js';
```

### 2.2 `@aastar/core/actions/x402.ts` (L1 actions)

文件：`aastar-sdk/packages/core/src/actions/x402.ts`

工厂函数：`x402Actions(superPaymasterAddress) (client) => X402Actions`

| 类别 | 函数 | 链上对应 |
|------|------|----------|
| Settlement (write) | `settleX402Payment` | `SuperPaymaster.settleX402Payment(from,to,asset,amount,validAfter,validBefore,nonce,signature)` |
| Settlement (write) | `settleX402PaymentDirect` | `SuperPaymaster.settleX402PaymentDirect(from,to,asset,amount,nonce)` |
| View | `x402SettlementNonces({nonce})` | `mapping(bytes32 => bool)` 公共 getter（**注意：在 P0-13 之后 key 已变为三元组哈希；详见 §10**） |
| View | `facilitatorFeeBPS()` | 全局费率 |
| View | `facilitatorEarnings({operator,asset})` | 累计可提 |
| View | `operatorFacilitatorFees({operator})` | operator 自定义费率（0 = 用全局） |
| Admin (write) | `withdrawFacilitatorEarnings`, `setFacilitatorFeeBPS`, `setOperatorFacilitatorFee` | 管理员 / operator |
| **TODO** | `x402NonceKey(asset,from,nonce) pure` | P0-13 新增 helper，SDK **未暴露** |

### 2.3 `@aastar/cli` 命令

文件：`aastar-sdk/packages/cli/src/commands/x402.ts`

```
aastar x402 quote     --rpc <url> --paymaster <addr>                       已实现
aastar x402 nonce     --rpc <url> --paymaster <addr> --nonce <hex>         已实现（注意：P0-13 后单 nonce 查询将永远返回 false）
aastar x402 earnings  --rpc <url> --paymaster <addr> --operator --asset    已实现
aastar x402 pay                                                             stub: "not yet implemented"
aastar x402 settle                                                          stub: "not yet implemented"
```

姊妹命令：`aastar agent ...`（registry / reputation 查询）；`aastar channel status/voucher/...`。

### 2.4 `@aastar/channel` (v0.18.0)

源码在 `aastar-sdk/packages/channel/src/`，封装 `MicroPaymentChannel` 合约：

- `ChannelClient.openChannel / topUpChannel / signVoucherOffline / settleChannel / closeChannel / requestClose / withdraw / getChannelState`
- 离线 voucher 签名走 `signVoucher()`（EIP-712，domain `verifyingContract = channelAddress`）。
- 适合"先开通道，链下签 voucher，按需 settle 一次/n 次"的 agent 周期性微支付。

---

## 3. 三种集成场景

### 场景 A：dApp 后端用 SDK 主动 settle（server-to-server）

适用：dApp 服务端拿到用户授权后想直接代用户上链结算 USDC（EIP-3009）。后端持有 operator 私钥（运行 facilitator 角色）。

```ts
import { createPublicClient, createWalletClient, http } from 'viem';
import { sepolia } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { X402Client } from '@aastar/x402';

const operator = privateKeyToAccount(process.env.OPERATOR_KEY as `0x${string}`);
const transport = http(process.env.SEPOLIA_RPC!);
const publicClient = createPublicClient({ chain: sepolia, transport });
const walletClient = createWalletClient({ account: operator, chain: sepolia, transport });

const client = new X402Client({
  publicClient,
  walletClient,
  superPaymasterAddress: '0x...sp',
  chainId: 11155111,
  tokenName: 'USDC',
  tokenVersion: '2',
});

// 用户已通过前端把 EIP-3009 签名给到后端：
const txHash = await client.settleOnChain({
  from: '0xUser', to: '0xPayee', asset: '0xUSDC',
  amount: 1_000_000n,                       // 1 USDC (6 decimals)
  validAfter: 0n,
  validBefore: BigInt(Math.floor(Date.now()/1000) + 3600),
  nonce: '0x...32bytes',
  signature: '0x...userSig',
});
```

### 场景 B：用户钱包按 x402 spec 拿 402 → 自动签名 → 自动 settle

适用：dApp 前端调"付费 API"（资源服务器），收到 402 后由 SDK 自动完成签名重试，无需用户多步交互。

```ts
import { X402Client } from '@aastar/x402';
import { walletClient, publicClient } from './viem-clients';

const client = new X402Client({
  publicClient,
  walletClient,                            // 必须有 account
  superPaymasterAddress: '0x...sp',
  chainId: 11155111,
  facilitator: { url: 'https://facilitator.example.com' },
  maxAmountPerRequest: 5_000_000n,         // policy: 单次最多 5 USDC
});

// 像普通 fetch 一样用：
const resp = await client.x402Fetch('https://api.example.com/premium', { method: 'GET' });
if (resp.ok) {
  const body = await resp.json();
}
```

`x402Fetch` 内部流程：
1. 先发一次原始请求；
2. 拿到 402 → 从 `PAYMENT-REQUIRED` header 解码 `PaymentRequired`；
3. 在 `accepts[]` 里挑同 chain（CAIP-2 `eip155:11155111`）+ `scheme === "exact"`；
4. policy 校验 amount；
5. 调 `createPayment()` 走 EIP-3009 typed-data 签名；
6. 把 base64 编码后的 `PaymentPayload` 放到 `PAYMENT-SIGNATURE` header 重发请求。

### 场景 C：Agent 周期性 micropayment（结合 channel 包）

适用：AI agent 每秒/每 token 计费，频繁结算上链不划算 → 一次开 channel，链下签累计 voucher，定期/到期一次性 settle。

```ts
import { ChannelClient } from '@aastar/channel';

const channel = new ChannelClient({
  publicClient, walletClient,
  channelAddress: '0x5753e9675f68221cA901e495C1696e33F552ea36', // Sepolia MicroPaymentChannel
  chainId: 11155111,
});

// 1. payer 开通道（一次链上 tx）
const openTx = await channel.openChannel({
  payee: '0xAgent',
  token: '0xUSDC',
  deposit: 100_000_000n,                  // 100 USDC
  salt: '0x...',
  authorizedSigner: payer.address,        // 谁可以签 voucher
});

// 2. 每个调用结束后，离线签一次 voucher（不上链）
const voucher1 = await channel.signVoucherOffline(channelId, 1_000n);   // cumulative 0.001 USDC
const voucher2 = await channel.signVoucherOffline(channelId, 2_000n);

// 3. payee 持有最新 voucher，按需 settle（一次链上 tx 落账）
const settleTx = await channel.settleChannel(voucher2);

// 4. payer 关 channel（含 challenge 期）
await channel.requestClose(channelId);
// ... 等过 CLOSE_TIMEOUT
await channel.withdraw(channelId);
```

---

## 4. 代码示例索引（可直接复制）

- 场景 A → §3.A 后端 settleOnChain（EIP-3009）
- 场景 B → §3.B 钱包 x402Fetch 自动重试
- 场景 C → §3.C ChannelClient open/sign/settle

下面 §5 / §6 给签名细节和 HMAC 客户端实现示例。

---

## 5. 签名流程

### 5.1 EIP-3009 path（USDC native；需用户 EIP-712 签名）

D4 决策：USDC（含 7 链稳定币）走 EIP-3009 `transferWithAuthorization`，资产合约本身做签名校验，不需要 approve/Permit2。

EIP-712 domain（`packages/x402/src/eip3009.ts`）：

```ts
domain = {
  name: tokenName,                  // 'USDC'
  version: tokenVersion,            // '2'（USDC v2 合约）
  chainId,                          // 11155111 Sepolia / 1 mainnet / 8453 Base / ...
  verifyingContract: assetAddress,  // USDC 合约地址（注意：不是 SuperPaymaster！）
}
```

types：

```ts
TransferWithAuthorization: [
  { name: 'from',         type: 'address' },
  { name: 'to',           type: 'address' },
  { name: 'value',        type: 'uint256' },
  { name: 'validAfter',   type: 'uint256' },
  { name: 'validBefore',  type: 'uint256' },
  { name: 'nonce',        type: 'bytes32' },
]
primaryType: 'TransferWithAuthorization'
```

完整 typed-data：

```ts
const typedData = {
  domain: { name: 'USDC', version: '2', chainId: 11155111, verifyingContract: USDC_ADDR },
  types: { TransferWithAuthorization: [...] },
  primaryType: 'TransferWithAuthorization',
  message: {
    from:        '0xUser',
    to:          SUPER_PAYMASTER_ADDR,        // ★ 重要：to 必须是 SuperPaymaster；facilitator-node 在 verify 时硬编了这一约束（见 routes/verify.ts L60）
    value:       1_000_000n,                  // 1 USDC
    validAfter:  0n,
    validBefore: BigInt(now + 3600),
    nonce:       generateNonce(),             // 32 bytes 随机
  },
};
const signature = await walletClient.signTypedData(typedData);
```

> **注意**：`X402Client.createPayment()` 当前签的是用户 → payee 的转账（`to = params.to`），**与 facilitator-node 期望的 `to = SuperPaymaster` 不一致**。当资源服务器 + facilitator-node 是 SuperPaymaster 自家服务时（场景 A/B），用户应让 SDK 直接调 `client.settleOnChain()`，而 `to` 字段在合约内是"SP 收到 USDC 后再转给 payee"的语义。集成方需要看清楚自己用的是 spec 标准 to-payee 还是 SP 业务 to-SP 模型——**这是文档化漏点**（详见 §10 TODO）。

### 5.2 Direct path（xPNTs；无需用户签）

D4 决策：xPNTs 由 xPNTsFactory 部署时已自动 approve(SuperPaymaster, max)，**调用方 = operator/facilitator**，把 token 从 user 的余额按既定 nonce/asset/amount 直接转给 payee。无 EIP-712 签名。

调用约束（来自 `SuperPaymaster.settleX402PaymentDirect`）：
- `msg.sender` 必须有 `ROLE_PAYMASTER_SUPER`（即 operator）；
- `nonce` 三元组（asset, from, nonce）必须未用过（P0-13）；
- 资产必须在合约层判定为可信（**P0-12a 待修**：当前缺 `isXPNTs` 白名单，理论上恶意 token 也能走 direct path 制造伪结算事件）；
- facilitator 必须在 community 白名单内（**P0-12b 待修**）。

SDK 调用示例：

```ts
const txHash = await client.settleDirectOnChain({
  from:   '0xUser',
  to:     '0xPayee',
  asset:  '0xXPNTs',
  amount: 1_000_000_000_000_000_000n,    // 1 xPNTs (18 decimals)
  nonce:  generateNonce(),
});
```

---

## 6. HMAC challenge 客户端实现

> **重要修正**：HMAC 设计与任务描述里的"先调 /verify 拿 challenge 回填到 settle"**不一致**。实际实现（`packages/x402-facilitator-node/src/middleware/hmac-challenge.ts` + `index.ts`）是 hono middleware：
> - `hmacChallengeInjector()` 注册在 `app.use("*", ...)` 上，**任何**返回 402 的响应都会被注入 `X-Challenge` header；
> - `hmacSettleGuard()` 注册在 `/settle`，要求请求带 `X-Challenge` + `X-Payment-HMAC` 两个 header，并按 `HMAC(challenge, body)` 验证。
> - `/verify` 路由本身不涉及 challenge。

启用条件：facilitator 把 `ENABLE_HMAC_CHALLENGE=true` 且配置 `HMAC_SECRET=<secret>`。客户端可先 GET `/.well-known/x-payment-info` 或观察 402 响应判断。

### 6.1 客户端流程

```
(1) Client → 资源服务器 GET /resource             [初始请求]
(2) Server → Client 402 + X-Challenge: <token>     [middleware 自动注入]
(3) Client 计算 hmac = HMAC_SHA256(challenge, body)
(4) Client → Facilitator POST /settle
        Headers: X-Challenge: <token>
                 X-Payment-HMAC: <hmac hex>
        Body:    <settle 请求体>
(5) Facilitator middleware:
        - verifyChallenge(token)            check timestamp + HMAC(secret, "challenge:"+ts)
        - verifyHmacResponse(token, body, hmacHex)  -> crypto.subtle.verify (constant-time)
        - 通过则放行到 settle 路由
```

challenge 格式：`<unix_ms_timestamp>:<hex_hmac_of_"challenge:timestamp">`，TTL 5 分钟。

### 6.2 客户端示例（SDK 当前**未封装**，需要手写）

```ts
async function hmacSha256Hex(key: string, data: string): Promise<string> {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, enc.encode(data));
  return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
}

// (1) 获取 challenge：从 402 响应或 OPTIONS / .well-known 探测
const trigger = await fetch('https://facilitator.example.com/some-paid-endpoint');
const challenge = trigger.headers.get('X-Challenge');
if (!challenge) throw new Error('Facilitator did not issue challenge');

// (2) 准备 settle 请求体（与 facilitator-node SettleRequest 对齐）
const settleBody = {
  payload: '...base64 PaymentPayload...',
  payment: {
    from, to, asset, amount: amount.toString(), nonce,
    validAfter: validAfter.toString(),
    validBefore: validBefore.toString(),
    signature,
  },
  scheme: 'eip-3009',                     // 或 'direct'
};
const bodyText = JSON.stringify(settleBody);

// (3) 计算 HMAC
const hmacHex = await hmacSha256Hex(challenge, bodyText);

// (4) 发送 settle
const resp = await fetch('https://facilitator.example.com/settle', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    'X-Challenge': challenge,
    'X-Payment-HMAC': hmacHex,
  },
  body: bodyText,
});
```

> SDK TODO：在 `FacilitatorClient` 加 `enableHmac: boolean` 选项；自动从 402 响应抓 `X-Challenge`、缓存到下一次 settle、自动计算 HMAC。

---

## 7. 联调清单（test plan，anvil 本地）

前提：anvil 起本地链 + SuperPaymaster 全套合约部署 + 一份 xPNTs + facilitator-node 起在 :3402（默认端口待确认；当前 `index.ts` 从 `config.port` 读取）。

```bash
# 1) SuperPaymaster：起 anvil 并部署（需要切到 fix/p0-wave2-funds-price 才有 P0-13）
cd /Users/jason/Dev/aastar/SuperPaymaster
git checkout fix/p0-wave2-funds-price
./deploy-core anvil --force
./prepare-test anvil

# 2) 重新提取 ABI 并同步到 SDK
./scripts/extract_v3_abis.sh
./sync_to_sdk.sh

# 3) Facilitator-Node：填 .env 并启动
cd packages/x402-facilitator-node
cp .env.example .env
# 编辑 .env：RPC_URL / SUPER_PAYMASTER_ADDRESS / OPERATOR_PRIVATE_KEY / USDC_ADDRESS / ENABLE_HMAC_CHALLENGE=true / HMAC_SECRET=...
pnpm install && pnpm dev   # 默认 port 3402

# 4) SDK：跑单元测试
cd /Users/jason/Dev/aastar/aastar-sdk
pnpm install
pnpm --filter @aastar/x402 test
pnpm --filter @aastar/channel test
pnpm --filter @aastar/cli test

# 5) 现成的合约级 E2E（Sepolia / anvil 都能跑）
cd /Users/jason/Dev/aastar/SuperPaymaster/script/gasless-tests
node test-x402-eip3009-settlement.js     # USDC EIP-3009 path 直发链上
node test-x402-permit2-settlement.js     # 历史脚本（V5.3 已弃用 Permit2，保留参考）

# 6) 全链路 E2E：尚无现成脚本（详见 §10 TODO）
#    建议：写一个 packages/x402/__e2e__/anvil-full-flow.test.ts
#    起 SP + facilitator-node + 1 个 mock 资源服务器，验证：
#      - GET /pay → 402 + PAYMENT-REQUIRED + X-Challenge
#      - X402Client.x402Fetch(...) 自动签名重试
#      - facilitator /verify 通过 → /settle 写链
#      - 链上事件 X402PaymentSettled 触发
#      - facilitatorEarnings 增加预期 fee
#      - 重复 settle 同 (asset,from,nonce) → revert NonceAlreadyUsed
```

应该验证的关键不变量：
- `facilitatorFeeBPS` ≤ `MAX_FACILITATOR_FEE`（来自 quote 接口）
- payee 实收 = amount - fee
- `facilitatorEarnings[operator][asset]` += fee
- nonce 重放保护（per-(asset, from, nonce) 三元组）
- HMAC 启用时无 `X-Payment-HMAC` → 400 / HMAC 错 → 403

---

## 8. TODO（SDK 需要补的东西）

| 优先级 | 项目 | 说明 |
|--------|------|------|
| **P0** | 重新生成 SDK ABI（带 `x402NonceKey`） | P0-13 给 SuperPaymaster 加了新 `pure` 函数 `x402NonceKey(asset,from,nonce)`，SDK 当前 ABI 不含；`actions/x402.ts` 也未暴露。一旦 wave2 合并/上线，单参数 `x402SettlementNonces(nonce)` 的查询永远返回 false（key 已变三元组），SDK 现有 `checkNonce(nonce)` 会给出错误结果。 |
| **P0** | 校正 `X402Client.createPayment` 的 `to` 字段语义 | 当前 `to = params.to` 直签给 payee，但 facilitator-node `verify.ts` L60 期望 `to = SuperPaymaster`。需要明确"SP 业务模式 vs spec 标准"，至少在文档/参数层把这个差异显式表达，且 EIP-712 签名要和 SP 业务对齐。 |
| **P1** | 一行 helper 让 dApp 完成 x402 settle | 当前 `aastar x402 pay/settle` CLI 是 stub。建议封装：`await aastar.payx402(url, { wallet, max })` 一句话搞定。 |
| **P1** | HMAC challenge 客户端封装 | `FacilitatorClient` 加 `enableHmac`、自动抓 `X-Challenge`、调 settle 时自动计算 HMAC（见 §6）。 |
| **P1** | facilitator-node schema 与 x402 v2 spec 对齐 | facilitator-node 用 `{payment, scheme}` 平面字段；SDK `FacilitatorClient.verify/settle` 发的是 `{x402Version:2, paymentPayload, paymentRequirements}`。两者**当前互不兼容**。要么改 facilitator-node 接 v2 spec，要么 SDK 对自家 facilitator 提供专用 client。 |
| **P2** | 错误归一化 | review.md J4-MINOR-7：`AAStarError.fromViemError` 对 settle revert 的归类不细，"NonceAlreadyUsed/Unauthorized/InsufficientBalance" 都报成 generic message。 |
| **P2** | 测试覆盖率 | x402 包仅 37 个单元测试（编解码、EIP-712 签名 mock、FacilitatorClient mock）；缺：(a) `x402Fetch` 自动重试集成测试、(b) 真链 settle 走 anvil/forge fixture、(c) HMAC 端到端、(d) Direct path 测试、(e) channel + voucher 重放保护。 |
| **P2** | CLI `pay` / `settle` 实装 | 接到 X402Client + 钱包 keystore（参考 `enduser` 包钱包加载方式）。 |

---

## 9. 验证记录（实际执行）

### 9.1 SDK 仓库定位

```
$ find /Users/jason/Dev -maxdepth 5 -type d -name "aastar-sdk"
/Users/jason/Dev/aastar/aastar-sdk          ← 活跃开发，本文档对应
/Users/jason/Dev/aastar-sdk
/Users/jason/Dev/jhfnetboy/aastar-launch/aastar-sdk
/Users/jason/Dev/aastar/aastar-start/packages/aastar-sdk
... (其他 backup / submodule 副本)
```

主仓库：`/Users/jason/Dev/aastar/aastar-sdk` (git, 当前默认 `main` 分支已合并 V5.3 SDK PR #9)。

x402/channel/cli 源代码在 `main` 分支（当前 `feat/paper3-controlled-baseline` 工作树**没有**这些 src，只有 dist）。

### 9.2 ABI 同步检查（关键）

P0-13 (`b478a10`) 在 SuperPaymaster 上加了 `function x402NonceKey(address asset, address from, bytes32 nonce) public pure returns (bytes32)`，并把 `x402SettlementNonces` 的 key 改为三元组。

```
$ grep -c "x402NonceKey" /Users/jason/Dev/aastar/SuperPaymaster/abis/SuperPaymaster.json
0    (NOT in SP repo abi)

$ git show main:packages/core/src/abis/SuperPaymaster.json | grep -c x402NonceKey   # in aastar-sdk
0    (NOT in SDK abi on main)

$ git show fix/p0-wave2-funds-price:contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol | grep -n "x402NonceKey"
1148:    function x402NonceKey(address asset, address from, bytes32 nonce) public pure returns (bytes32) {
1157:        bytes32 key = x402NonceKey(asset, from, nonce);
```

**结论**：
- P0-13 修复在 `fix/p0-wave2-funds-price` 分支，**未合入 SuperPaymaster main**。
- 当前 SuperPaymaster `abis/` 输出（被 `sync_to_sdk.sh` 同步到 SDK）**仍是合并前的 ABI**，不含 `x402NonceKey`。
- SDK `packages/core/src/abis/SuperPaymaster.json` 也不含 `x402NonceKey`。
- `packages/core/src/actions/x402.ts` 没有 `x402NonceKey` action。
- 一旦 wave2 合并并部署，SDK 现有 `checkNonce()` 单参数查询会**永远返回 false**（旧 key 没人写了），调用方无法在链下判断 nonce 是否已用。

### 9.3 Facilitator-Node 接口检查

facilitator-node 当前实现**未跟进 P0-13**：

```
verify.ts L40:
  args: [nonce]                ← 应改为：args: [await sp.read.x402NonceKey([asset, from, nonce])] 后再传入
```

`/verify` 的 nonce 重放检测在 P0-13 部署后会失效（旧 key 永远没人写，永远返回 false）。这不是安全问题（settle 仍会按新 key 防重放），但 facilitator 对客户端的"提前判断"不再有意义。

### 9.4 Facilitator-Node ↔ SDK schema 不一致

| 端点 | facilitator-node 期望 (`types.ts`) | SDK `FacilitatorClient` 发出 (`facilitator.ts`) |
|------|-----------------------------------|---------------------------------------------|
| `/verify` POST body | `{ payload, payment: {from,to,asset,amount,nonce,validAfter,validBefore,signature}, scheme: 'eip-3009'\|'permit2'\|'direct' }` | `{ x402Version: 2, paymentPayload, paymentRequirements }` |
| `/settle` POST body | 同上 | 同上 |
| `/quote` GET | 返回 `{feeBPS,feePercent,supportedAssets,supportedSchemes}` | SDK 没有 `quote` 方法（只有 `supported`） |
| `/supported` GET | 不存在 | SDK 期望存在，返回 `{kinds, extensions}` |
| `.well-known` | `/.well-known/x-payment-info` 返回 `PaymentInfo` (自定义) | SDK 不读 |

**结论：当前 SDK 的 `FacilitatorClient` 不能直接对接 SuperPaymaster 自家 facilitator-node**，要么 facilitator-node 升级到 x402 v2 spec，要么 SDK 提供 `SuperPaymasterFacilitatorClient` 走平面 schema。

### 9.5 测试结果

```
@aastar/x402     pnpm test  →  ✓ 37 tests passed (1 file, 55ms)
@aastar/channel  pnpm test  →  ✓ 11 tests passed (1 file, 11ms)
@aastar/cli      pnpm test  →  ✓ 1 test passed
```

合计 49/49 通过。**注意覆盖率只覆盖编解码 / EIP-712 签名 mock / FacilitatorClient HTTP mock**，没有真链或真 facilitator 的 e2e。

facilitator-node：**没有任何测试**（package.json 无 `test` 脚本，src 下没有 `__tests__`）。

### 9.6 联调脚本

- 已有合约级脚本：`SuperPaymaster/script/gasless-tests/test-x402-eip3009-settlement.js`、`test-x402-permit2-settlement.js`（用 ethers，直接调链上 settle，**不经过 facilitator-node**）。
- 全链路（SDK → facilitator-node → SP）e2e：**不存在**。这是 §10 TODO 的一项。

---

## 10. 回归测试建议

每次 SuperPaymaster 修改 x402 接口（P0-13 已做、P0-12a/12b 待做、未来 D4 重构等），SDK 必须按以下顺序操作：

1. **重新提取 ABI**
   ```bash
   cd SuperPaymaster
   ./scripts/extract_v3_abis.sh
   ./sync_to_sdk.sh           # 复制 abis/*.json 到 aastar-sdk/packages/core/src/abis/
   ```

2. **检查 ABI diff** — 任何新函数/事件/error 都要在 `aastar-sdk/packages/core/src/abis/abi.config.json` 的 hash 上反映出来；新函数若属于 x402 范畴，必须在 `actions/x402.ts` 加对应 action 并导出。

3. **更新 `actions/x402.ts`**（按 P0-13 / P0-12a/12b 的需求）
   - 新增：`x402NonceKey({asset, from, nonce})` view（pure 函数）
   - 修正：`x402SettlementNonces({asset, from, nonce})` 接受三元组，内部先 `keccak256(abi.encode(...))` 再查 mapping
   - 添加 P0-12 后：`isXPNTs({asset})` 视情况、`isApprovedFacilitator({operator})` 视情况

4. **更新 `X402Client.checkNonce()`** — 改成接受 `(asset, from, nonce)` 三元组。

5. **跑测试**
   ```bash
   pnpm --filter @aastar/x402 test
   pnpm --filter @aastar/channel test
   pnpm --filter @aastar/cli test
   ```

6. **跑合约级 E2E**（`script/gasless-tests/test-x402-*.js`），确认旧脚本仍 pass（它们用的是简化 ABI，对 ABI 变更最敏感）。

7. **跑全链路 E2E**（待补）— SDK + facilitator-node + 本地 anvil SP。

8. **bump 版本**：`@aastar/x402` `@aastar/core` 升 minor（接口扩展）或 major（不兼容变更，例如 `checkNonce` 签名改）。

9. **同步更新** `packages/x402-facilitator-node/src/routes/verify.ts` 的 `x402SettlementNonces(nonce)` 调用，改为 `x402SettlementNonces(x402NonceKey(asset,from,nonce))`，否则 verify 阶段的 nonce 检查会失效。

---

## 11. 关键路径速查

| 资源 | 绝对路径 |
|------|----------|
| SDK 主仓库 | `/Users/jason/Dev/aastar/aastar-sdk` |
| `@aastar/x402` 源码 | `/Users/jason/Dev/aastar/aastar-sdk/packages/x402/src/` (main 分支) |
| `@aastar/core x402 actions` | `/Users/jason/Dev/aastar/aastar-sdk/packages/core/src/actions/x402.ts` |
| `@aastar/cli` x402 命令 | `/Users/jason/Dev/aastar/aastar-sdk/packages/cli/src/commands/x402.ts` |
| `@aastar/channel` 源码 | `/Users/jason/Dev/aastar/aastar-sdk/packages/channel/src/` |
| SDK SuperPaymaster ABI | `/Users/jason/Dev/aastar/aastar-sdk/packages/core/src/abis/SuperPaymaster.json` |
| SP 仓库 ABI 输出 | `/Users/jason/Dev/aastar/SuperPaymaster/abis/` |
| ABI 同步脚本 | `/Users/jason/Dev/aastar/SuperPaymaster/sync_to_sdk.sh` + `scripts/extract_v3_abis.sh` |
| Facilitator-Node 源码 | `/Users/jason/Dev/aastar/SuperPaymaster/packages/x402-facilitator-node/src/` |
| HMAC middleware | `/Users/jason/Dev/aastar/SuperPaymaster/packages/x402-facilitator-node/src/middleware/hmac-challenge.ts` |
| SuperPaymaster 合约 | `/Users/jason/Dev/aastar/SuperPaymaster/contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol` |
| P0-13 修复分支 | `fix/p0-wave2-funds-price` (commit b478a10) |
| Forge x402 测试 | `/Users/jason/Dev/aastar/SuperPaymaster/contracts/test/v3/SuperPaymasterV5Features.t.sol` (F3/F3b) |
| 链上 E2E 脚本 | `/Users/jason/Dev/aastar/SuperPaymaster/script/gasless-tests/test-x402-eip3009-settlement.js` |
| MicroPaymentChannel (Sepolia) | `0x5753e9675f68221cA901e495C1696e33F552ea36` |
