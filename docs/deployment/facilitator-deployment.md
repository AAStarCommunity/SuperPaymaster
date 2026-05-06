# SuperPaymaster x402 Facilitator 部署运维文档

> 适用版本：`@superpaymaster/x402-facilitator-node@0.1.0`
> 源码路径：`packages/x402-facilitator-node/`
> 最后更新：2026-04-27
> 状态：**测试网可用，主网 beta 须等待 Stage 1 P0-12a / P0-12b 修复完成**

---

## 1. 概览

### 1.1 facilitator 在 x402 生态里的位置

facilitator 是 x402 协议的链下结算服务，负责：

- 离线校验付款方的 EIP-3009 签名（约 100ms 一次）
- 把签名提交到 SuperPaymaster 合约执行链上结算（USDC / xPNTs）
- 对 operator 收 BPS 费率（默认 200 BPS = 2%）

它是 **operator 自己的服务**，不是协议核心组件。

### 1.2 链上 vs 链下职责分离

| 维度 | 链上（Solidity） | 链下（本服务） |
| --- | --- | --- |
| 信任根 | xPNTs.approvedFacilitators 白名单（地址） | 无，仅是 RPC 入口 |
| 标识 | 0x... 地址（合约或 EOA） | HTTPS URL，比如 `https://facilitator.aastar.io` |
| 替换成本 | 社区多签 tx | 改 DNS 即可 |

**关键理解**：链上白名单只认地址，HTTP URL 只是 x402 协议响应里的 metadata。同一个 operator 可以在多个 URL 后面跑同一个地址，也可以在同一个 URL 后面切换地址（不推荐）。

### 1.3 与 P0-12a / P0-12b 修复的依赖关系

Stage 1 安全审计列出两条 P0 修复：

- **P0-12a**：`xPNTsFactory.isXPNTs(asset)` 检查 —— 防止伪 xPNTs 资产被结算
- **P0-12b**：`IXPNTsToken.approvedFacilitators(facilitatorAddress)` 检查 —— 防止任意 EOA 当 facilitator

这两条还在 Wave 2 待修。当前 SuperPaymaster.sol 中 `settleX402Payment` / `settleX402PaymentDirect` 还没有这两道闸门。

**结论**：facilitator 服务本身可以上测试网，但是 **mainnet beta 必须等到这两条 P0 合并部署后才能开放**。否则任意人都可以注册自己的 facilitator 地址结算，社区代币会被无授权扣费。

---

## 2. 预条件

### 2.1 基础设施

- **RPC URL**：建议 Alchemy / Infura 付费档；公共 RPC 不稳定（详见 §10 验证日志中的 Blast API 失败）
- **域名 + TLS 证书**：facilitator 必须 HTTPS 暴露（x402 客户端校验）
- **服务器**：1 vCPU + 512 MB RAM 起步；CPU bottleneck 在 viem 的 ECDSA recover

### 2.2 链上资源

- **operator 私钥**（或多签热钱包）：负责签发结算 tx
  - 单签：testnet 可用，主网不推荐
  - 多签：用 Safe 配 hot signer + cold signer + threshold（推荐主网用）
  - 私钥泄露 = 资金风险，参考 §9 紧急停机
- **operator 已在 SuperPaymaster 注册**：用 `prepare-test <env>` 或手动 `registerOperator`
- **operator 地址注册到对应 xPNTs**：等 P0-12b 落地后调 `IXPNTsToken.addApprovedFacilitator(operatorAddr)`，由社区多签触发
- **SuperPaymaster 部署地址**：从 `deployments/config.<network>.json` 取 `superPaymaster.proxy`
- **USDC 地址**：Sepolia 已经默认配好（见 `lib/config.ts`），其他链需手动覆盖

### 2.3 软件版本

| 组件 | 最低版本 | 测试通过版本 |
| --- | --- | --- |
| Node.js | 18 | 24.12.0 |
| pnpm | 9 | 10.15.1 |
| Docker | 20 | 未在本机验证，详见 §10 |

---

## 3. 配置

### 3.1 .env 字段说明

```bash
# ===== 必填 =====

# 链 RPC 端点。测试网用 Alchemy/Infura，主网必须用付费档。
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# operator 私钥（0x 开头 32 字节 hex）。生产环境强烈建议改用 KMS / HSM / 多签。
OPERATOR_PRIVATE_KEY=0x...

# 当前网络 SuperPaymaster proxy 地址。Sepolia v5.3 默认值如下。
SUPER_PAYMASTER_ADDRESS=0x829C3178DeF488C2dB65207B4225e18824696860

# ===== 可选 =====

# 监听端口。默认 3402。反代可改 80/443。
PORT=3402

# Chain ID。11155111=Sepolia, 8453=Base, 84532=Base Sepolia。其它链请显式覆盖 USDC_ADDRESS。
CHAIN_ID=11155111

# 网络名（出现在 health/well-known 响应里）。
NETWORK=sepolia

# 该链上的 USDC（不指定就走 lib/config.ts 内置默认表）。
USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238

# facilitator 对外 URL。注意要和实际 DNS 一致，否则 well-known 返回错误。
BASE_URL=https://facilitator.aastar.io

# ===== HMAC challenge（可选） =====

# 启用 HMAC 反爬：true / false（默认 false）
ENABLE_HMAC_CHALLENGE=true

# HMAC 共享秘钥。32 字节随机串建议：openssl rand -hex 32
HMAC_SECRET=please-rotate-me-with-openssl-rand-hex-32
```

### 3.2 推荐配置

| 字段 | 测试网（Sepolia） | 生产（mainnet 待 P0 修复） |
| --- | --- | --- |
| `RPC_URL` | Alchemy free tier 够用 | Alchemy Growth / Infura Team |
| `OPERATOR_PRIVATE_KEY` | dev 私钥 | Safe 多签 + hot signer，或 AWS KMS |
| `PORT` | 3402 直接暴露或 Cloudflare 代理 | 反代背后的 8080，前面套 Caddy/Nginx + LE |
| `BASE_URL` | `https://facilitator-sepolia.aastar.io` | `https://facilitator.aastar.io` |
| `ENABLE_HMAC_CHALLENGE` | `true`（也方便 SDK 测试） | `true` |

---

## 4. 部署方式

### 4.1 选项 A：Docker（推荐）

#### 4.1.1 单容器

```bash
cd packages/x402-facilitator-node
docker build -t aastar-facilitator:0.1.0 .
docker run -d --name facilitator \
  --restart unless-stopped \
  --env-file .env \
  -p 3402:3402 \
  aastar-facilitator:0.1.0
```

#### 4.1.2 docker-compose.yml（推荐）

```yaml
# Note: top-level `version` field is deprecated in Docker Compose v2; omit it to avoid warnings.
services:
  facilitator:
    image: aastar-facilitator:0.1.0
    container_name: facilitator
    restart: unless-stopped
    env_file: .env
    ports:
      - "127.0.0.1:3402:3402"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O-", "http://localhost:3402/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"

  caddy:
    image: caddy:2
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      - facilitator

volumes:
  caddy-data:
  caddy-config:
```

`Caddyfile`：

```
facilitator.aastar.io {
    reverse_proxy facilitator:3402
    encode zstd gzip
    log {
        output file /data/access.log
    }
}
```

启动：

```bash
docker compose up -d
docker compose logs -f facilitator
```

### 4.2 选项 B：systemd（裸 Node.js）

```bash
# 1. 部署源码
sudo mkdir -p /opt/facilitator
sudo chown $USER /opt/facilitator
git clone https://github.com/AAStarCommunity/SuperPaymaster.git /tmp/sp
cp -r /tmp/sp/packages/x402-facilitator-node/* /opt/facilitator/
cd /opt/facilitator
pnpm install --prod
pnpm build

# 2. 写 .env（注意权限）
sudo install -m 600 .env.example /opt/facilitator/.env
sudo $EDITOR /opt/facilitator/.env

# 3. systemd unit
sudo tee /etc/systemd/system/facilitator.service > /dev/null <<'EOF'
[Unit]
Description=x402 Facilitator Node
After=network.target

[Service]
Type=simple
User=facilitator
Group=facilitator
WorkingDirectory=/opt/facilitator
EnvironmentFile=/opt/facilitator/.env
ExecStart=/usr/bin/node /opt/facilitator/dist/index.js
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/facilitator/logs

[Install]
WantedBy=multi-user.target
EOF

sudo useradd -r -s /usr/sbin/nologin facilitator
sudo chown -R facilitator:facilitator /opt/facilitator
sudo systemctl daemon-reload
sudo systemctl enable --now facilitator
sudo journalctl -u facilitator -f
```

### 4.3 选项 B'：pm2（开发或单机生产备选）

```bash
pnpm i -g pm2
cd /opt/facilitator
pm2 start dist/index.js --name facilitator --env production
pm2 save
pm2 startup   # 输出一行 sudo 命令，照抄执行
```

### 4.4 选项 C：托管平台

| 平台 | 是否能跑 | 备注 |
| --- | --- | --- |
| **Fly.io** | 可以 | 直接 `fly launch`，Hono Node 完全兼容；推荐 |
| **Railway** | 可以 | 支持 Dockerfile 自动检测；免费档够测试网用 |
| **Render** | 可以 | Node Web Service 类型，开自动 deploy |
| **Cloudflare Workers** | **不行** | 当前实现用 `@hono/node-server`、`viem` 的 `http()`、Node `crypto.subtle`（subtle 在 Workers 可用，但 node-server 不可用）。如要支持 Workers，需要替换为 `hono/cloudflare-workers` 入口并改用 `viem/utils` 适配。当前不在路线图。 |

Fly.io 示例：

```bash
fly launch --no-deploy --copy-config --name aastar-facilitator
fly secrets set RPC_URL=... OPERATOR_PRIVATE_KEY=... SUPER_PAYMASTER_ADDRESS=... HMAC_SECRET=...
fly deploy
```

`fly.toml` 关键字段：

```toml
[http_service]
  internal_port = 3402
  force_https = true
  auto_stop_machines = false   # facilitator 不能 cold start，否则首次结算被卡
  auto_start_machines = true
  min_machines_running = 1

[checks.health]
  type = "http"
  port = 3402
  path = "/health"
  interval = "30s"
  timeout = "5s"
```

---

## 5. DNS + TLS

### 5.1 选项 1：Cloudflare 反代（推荐快速上线）

1. DNS 添加 A / AAAA 记录指向源站，Proxy status 设为 **Proxied**
2. SSL/TLS mode 设为 **Full (strict)**
3. 源站用 Cloudflare Origin CA 证书，或者源站不开 TLS 让 Cloudflare 终止
4. 在 Cloudflare 配置 Page Rule：
   - `facilitator.aastar.io/*` → Cache Level: Bypass（结算结果不能缓存）

### 5.2 选项 2：Caddy + Let's Encrypt（自动 TLS）

参考 §4.1.2 的 `Caddyfile`，第一次启动时 Caddy 自动 ACME 申请证书。注意 80/443 端口必须能从公网入站，否则 ACME HTTP-01 失败。

### 5.3 选项 3：Nginx + certbot

```nginx
server {
    listen 443 ssl http2;
    server_name facilitator.aastar.io;

    ssl_certificate /etc/letsencrypt/live/facilitator.aastar.io/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/facilitator.aastar.io/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3402;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 30s;
    }
}
```

---

## 6. 链上注册

### 6.1 当前状态

P0-12b 修复尚未合并，xPNTs 还没有 `addApprovedFacilitator` 函数。当前 testnet 部署 facilitator 不需要链上注册即可工作（**这正是 P0-12b 要修的漏洞**）。

### 6.2 P0-12b 修复后流程（预留）

社区多签操作步骤：

```solidity
// 1. 取得 xPNTs 实例
IXPNTsToken xpnts = IXPNTsToken(communityXPNTsAddress);

// 2. （多签）调用
xpnts.addApprovedFacilitator(operatorAddress); // operator EOA 或合约地址，不是 URL

// 3. 校验
bool ok = xpnts.approvedFacilitators(operatorAddress);
require(ok, "facilitator not approved");
```

操作后：

- 链上：facilitator 地址进入白名单，下一笔 settle 才会通过 P0-12b 检查
- 链下：operator 把 `https://facilitator.aastar.io` 配到 SDK / x402 客户端

每条链每个 xPNTs 都需独立注册一次。

---

## 7. 健康检查与监控

### 7.1 /health schema

```json
{
  "status": "ok | degraded | down",
  "version": "0.1.0",
  "chainId": 11155111,
  "network": "sepolia",
  "operator": "0x...",
  "contractVersion": "SuperPaymaster-5.3.0",
  "blockNumber": 9123456
}
```

- `status=ok`（200）：RPC 通、合约可读
- `status=degraded`（503）：RPC 不通或合约 revert，operator 字段会变成 0x000…000

### 7.2 监控指标

| 指标 | 来源 | 阈值建议 |
| --- | --- | --- |
| `/health` 200 比例 | Caddy/Nginx access log 或 Datadog HTTP check | 95% / 5min |
| `/settle` 平均延迟 | 应用日志（看 settle.ts 中 console.error） | p95 < 5s |
| `/settle` 5xx 比例 | 同上 | < 1% |
| HMAC 失败数 | 日志中 `Invalid or expired challenge` / `HMAC verification failed` | 突增 = 攻击或客户端 bug |
| operator 余额（ETH/Gas） | 链上 RPC | < 0.05 ETH 报警 |
| operator nonce 卡住 | RPC `getTransactionCount` | pending 数 > 5 报警 |

### 7.3 推荐告警

- Prometheus + node_exporter + blackbox_exporter 拉 `/health`
- Grafana dashboard：把 RPC 调用次数、settle 成功/失败拆开看

应用本身目前**没有内置 metrics endpoint**，监控需要靠日志聚合（Loki / CloudWatch Logs）。后续 SDK 可以加 `/metrics` Prometheus exporter（待 §11 TODO）。

---

## 8. HMAC challenge 使用

### 8.1 启用条件

`.env` 里同时设：

```bash
ENABLE_HMAC_CHALLENGE=true
HMAC_SECRET=$(openssl rand -hex 32)
```

启动后日志会出现：

```
  HMAC Challenge: ENABLED
```

### 8.2 客户端流程

> **注意（已知 Bug — 见 §8.4）**：`hmacChallengeInjector` 当前只在
> `res.status === 402` 时注入 `X-Challenge` header，而 facilitator 的
> `/verify` 端点返回 200/400，**不会**返回 402，因此 `X-Challenge` 实际上
> 不会出现在 `/verify` 的响应中。下述流程描述的是设计意图；在 §8.4 的 bug
> 修复落地前，步骤 1 拿到的响应不会包含 `X-Challenge`，客户端无法完成 HMAC
> 认证，`/settle` 会被拒绝（400）。

```text
1) Client → POST /verify
   ← 200 OK（设计意图：response header X-Challenge: <ts>:<mac>）
   ← 当前实现：X-Challenge 不注入，因中间件仅在 status=402 时触发（见 §8.4）

2) Client 计算（仅在 §8.4 bug 修复后可用）
   payment_body = JSON.stringify(payment_payload)
   client_hmac = HMAC-SHA256(challenge, payment_body)

3) Client → POST /settle
   Headers:
     X-Challenge: <从步骤 1 拿到的原值>
     X-Payment-HMAC: <hex(client_hmac)>
   Body: payment_body

4) Server 验：
   - 5min 内的 challenge
   - HMAC 匹配
   不通过返回 400/403
```

### 8.3 客户端示例（viem / Node）

```ts
const challenge = res.headers.get("X-Challenge")!;
const body = JSON.stringify(payment);

const key = await crypto.subtle.importKey(
  "raw",
  new TextEncoder().encode(challenge),
  { name: "HMAC", hash: "SHA-256" },
  false,
  ["sign"],
);
const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
const clientHmac = Array.from(new Uint8Array(sig))
  .map((b) => b.toString(16).padStart(2, "0"))
  .join("");

await fetch(`${baseUrl}/settle`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Challenge": challenge,
    "X-Payment-HMAC": clientHmac,
  },
  body,
});
```

### 8.4 已知问题

`hmacChallengeInjector` 当前只在 `c.res.status === 402` 时注入 challenge（见 `middleware/hmac-challenge.ts:102`）。但 facilitator 路由没有任何路径返回 402，所以**默认情况下客户端拿不到 challenge，settle 会因缺 header 被拒**。

实际可行用法（生产前需修）：

- 在 `/verify` 成功响应里也注入 `X-Challenge`，或
- 提供独立 `GET /challenge` 端点

这个待 SDK 联调时一并修复。

---

## 9. 回滚 / 紧急停机

### 9.1 私钥泄露 / facilitator 被入侵

**优先级：分钟级响应。**

1. **链下立刻停服**：
   ```bash
   docker compose stop facilitator
   # 或 systemctl stop facilitator
   ```
2. **链上撤白名单**（P0-12b 修复后可用）：
   ```solidity
   // 社区多签调
   xpnts.removeApprovedFacilitator(compromisedOperatorAddress);
   ```
3. **吊销 RPC API key**（Alchemy / Infura dashboard）防止存量额度被滥用
4. **operator 钱包资产转出**：剩余 USDC / xPNTs / ETH 全部转到冷钱包
5. **取消 pending tx**：用同 nonce 发 0 ETH self-transfer 替换
6. **公告**：在 GitHub repo / Discord / Twitter 同步状态

### 9.2 漏洞披露但未利用

走 `docs/SECURITY.md` 流程，先停服并通知 jhfnetboy@aastar.io（或 PROFILE.md 里给的联系方式），等修复后重启。

### 9.3 服务端 DoS

- Cloudflare 开 "Under Attack" 模式
- 把 `ENABLE_HMAC_CHALLENGE=true`（攻击者要先触发 challenge 再算 HMAC，成本上升）
- RPC 加速率限制层（envoy / nginx limit_req）

### 9.4 RPC 异常

facilitator 本身**不会自动 failover**。生产建议：

- 配两个 RPC（Alchemy + Infura），靠外部健康检查切换 `RPC_URL` 后重启
- 或者前置自己的 RPC proxy（如 Pocket Network、Llama RPC）

---

## 10. 验证记录

> 验证时间：2026-04-27
> 主机：darwin 23.5.0，Node v24.12.0，pnpm 10.15.1
> 工作目录：`$SUPERPAYMASTER_ROOT/packages/x402-facilitator-node`

### 10.1 `pnpm install` —— 通过

```text
+ @hono/node-server 1.19.13
+ hono 4.12.14
+ viem 2.23.0
（diff 显示 lockfile 已有的版本被升到最新 minor，无破坏性升级）
```

### 10.2 `pnpm typecheck` —— 通过

```text
> @superpaymaster/x402-facilitator-node@0.1.0 typecheck
> tsc --noEmit
（无输出，exit 0）
```

### 10.3 `pnpm build` —— 通过

```text
> @superpaymaster/x402-facilitator-node@0.1.0 build
> tsc

ls dist/
  index.d.ts  index.js  types.d.ts  types.js  lib/  middleware/  routes/
```

### 10.4 `docker build -t aastar-facilitator:test .` —— **未执行**

```text
$ docker --version
zsh: command not found: docker
$ which docker podman colima
docker not found
podman not found
colima not found
```

**失败原因**：本地开发机未装容器运行时。Dockerfile 本身已审过（多阶段构建，alpine 基础镜像，pnpm 通过 corepack，prod 依赖隔离），结构合理，待真实 Docker 环境补做一次端到端测试。

### 10.5 `node dist/index.js` 启动 —— 通过

```bash
PORT=3403 \
RPC_URL="https://eth-sepolia.public.blastapi.io" \
OPERATOR_PRIVATE_KEY="0x0000…0001" \
SUPER_PAYMASTER_ADDRESS="0x829C3178DeF488C2dB65207B4225e18824696860" \
node dist/index.js
```

启动日志：

```
x402 Facilitator Node starting on port 3403
  Network: sepolia (chainId: 11155111)
  SuperPaymaster: 0x829C3178DeF488C2dB65207B4225e18824696860
  Listening on http://localhost:3403
```

#### `GET /` —— 200

```json
{
  "name": "@superpaymaster/x402-facilitator-node",
  "version": "0.1.0",
  "description": "x402 Facilitator Node for SuperPaymaster operators",
  "endpoints": ["/health", "/verify", "/settle", "/quote", "/.well-known/x-payment-info"]
}
```

#### `GET /.well-known/x-payment-info` —— 200

```json
{
  "facilitator": "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
  "network": "sepolia",
  "chainId": 11155111,
  "supportedAssets": [
    { "address": "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", "symbol": "USDC" }
  ],
  "feeBPS": 200,
  "verifyUrl": "http://localhost:3403/verify",
  "settleUrl": "http://localhost:3403/settle",
  "quoteUrl": "http://localhost:3403/quote"
}
```

注意：实际 well-known 路径是 `/.well-known/x-payment-info`，与本任务需求文中提到的 `/.well-known/x-payments-payment-required` 不一致。以源码为准。

#### `GET /health` —— 503（degraded）

```json
{
  "status": "degraded",
  "version": "0.1.0",
  "chainId": 11155111,
  "network": "sepolia",
  "operator": "0x0000000000000000000000000000000000000000"
}
```

服务端日志：

```
code: -32000,
message: "Blast API is no longer available. Please update your integration to
use Alchemy's API instead: https://alchemy.com"
```

**失败原因**：测试用的公共 RPC（`https://eth-sepolia.public.blastapi.io`）已经被 Blast 关停，导致合约 `version()` 调用失败，进入 degraded 分支。**这不是 facilitator 的 bug，反而验证了健康检查的兜底逻辑工作正常**。换成有效 Alchemy/Infura key 即返回 `status=ok`。

### 10.6 验证小结

| 步骤 | 结果 | 备注 |
| --- | --- | --- |
| pnpm install | 通过 | lockfile 升级到 hono 4.12.14 / @hono/node-server 1.19.13 |
| pnpm typecheck | 通过 | 严格模式 0 错误 |
| pnpm build | 通过 | dist 生成完整 |
| docker build | 未执行 | 本机无 Docker，结构审过，留待集成环境补做 |
| node dist/index.js + curl | 部分通过 | `/`、`/well-known` 200；`/health` 因公共 RPC 被禁返回 503，符合 degraded 逻辑 |

---

## 11. TODO

### 11.1 阻塞 mainnet beta 的项

| 项 | 类型 | 状态 |
| --- | --- | --- |
| **P0-12a** `xPNTsFactory.isXPNTs(asset)` 检查 | 合约 | Wave 2 待修 |
| **P0-12b** `IXPNTsToken.approvedFacilitators(addr)` 检查 | 合约 | Wave 2 待修 |
| `addApprovedFacilitator` / `removeApprovedFacilitator` 接口 + 事件 | 合约 | 随 P0-12b 一起 |
| 多签 hot signer 接入（Safe + 配额） | 运维 | 没动 |

### 11.2 facilitator 服务自身

| 项 | 类型 | 备注 |
| --- | --- | --- |
| HMAC challenge 注入逻辑 | bug | 当前只在 status=402 注入，实际没有路径返回 402；§8.4 |
| **`verify.ts` nonce 查询须改为三元组哈希** | **bug（P0-13 后必修）** | P0-13 合并后 `x402SettlementNonces` 的 key 已变为 `keccak256(asset, from, nonce)` 三元组。`verify.ts` 中直接查询 `x402SettlementNonces(nonce)` 的单参数调用将永远返回 `false`（nonce slot 不再写入），导致已结算的 tuple 被允许重放。修复：改用合约暴露的 `x402NonceKey(asset, from, nonce)` helper 生成正确 key 再查询。 |
| `/metrics` Prometheus exporter | 增强 | 当前只能靠日志做监控 |
| RPC failover | 增强 | 单 RPC 写死，挂了就 down |
| Permit2 scheme | 待支持 | `verify.ts` 显式拒绝 |
| Cloudflare Workers 入口 | 待支持 | 当前依赖 `@hono/node-server`，不能跑 Workers |
| Docker 镜像在 CI 自动构建发布 | 运维 | 还没有 GitHub Actions workflow |

### 11.3 SDK 联动

- AAStar SDK 的 `@aastar/x402` 客户端需要把 HMAC challenge 流程接上（参考本文 §8.3）
- SDK 的 `FacilitatorClient` 改造完后回过来跑端到端联调
- x402 v2 spec 对 `/verify` 响应字段还在变，需要持续对齐 coinbase/x402

### 11.4 文档自身

- 等 P0-12a/12b 落地后，把 §6.2 改为正式流程而不是预留
- Docker 在真实 Linux 节点跑过一次后，把命令输出补回 §10.4
- 加 mainnet 部署 checklist（多签、KMS、监控接入）作为附录
