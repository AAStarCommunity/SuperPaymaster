# OP Mainnet V5.4.2 Deploy Runbook (CC-30 · G1)

**Goal**: bring OP mainnet (chain 10) from the legacy **V3** stack (`SuperPaymaster-3.2.2 / Registry-3.0.2`) up to the current **V5.4.2** full stack — the headline mainnet blocker (CC-30 G1). SDK/YAAA/airaccount canonical-mainnet all wait on this.

> **Core principle** (CC-30): testnet vs mainnet = **configuration only**; contract logic is identical to Sepolia V5.4.2 (already live + audited through Codex rounds). This runbook adds **no new deploy code** — the path already exists.

---

## The deploy path already exists

`./deploy-core op-mainnet` is the canonical V5.4.2 full-stack deploy:
- Reads `.env.op-mainnet` (RPC + signer).
- Runs `DeployLive.s.sol` — **v5.4-aware** (deploys core + `X402Facilitator` + `TimelockController` + `PolicyRegistry` and wires them; shares logic with `DeployV54.s.sol` via `V54Bootstrap` so they cannot drift).
- Writes `deployments/config.op-mainnet.json` (**authoritative** for OP mainnet V5; `config.optimism.json` is the legacy-V3 record — G10).

So G1 is **not** a code task; it is a **gated ops task**. Do NOT run it until the prerequisites below are green.

---

## Prerequisites (hard gates — all must be green)

| # | Gate | Owner | State |
|---|---|---|---|
| 1 | External security audit of V5.4.2 full stack passed | jason | 🔴 GA hard gate |
| 2 | OP mainnet deployer keystore funded (cast wallet / Foundry keystore) | jason | 🔴 |
| 3 | `.env.op-mainnet` filled: `OP_MAINNET_RPC_URL` (deploy-core reads `${ENV_UPPER//-/_}_RPC_URL`), signer (`DEPLOYER_ACCOUNT` keystore preferred over `PRIVATE_KEY`) | jason | 🔴 (template exists, secrets pending) |
| 4 | DVT mainnet validators + production nodes ready (BLS quorum is a slash prerequisite) | @repo:dvt | 🔴 |
| 5 | Chainlink ETH/USD price feed address for OP mainnet confirmed in deploy config | SP | 🟡 verify |
| 6 | Mycelium community Safe reachable on OP mainnet (`0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`, `oeth:`) for post-deploy ownership transfer (CC-31) | jason | ✅ address known |

---

## Deploy sequence

```bash
# 0. Pre-flight: load env; confirm OP_MAINNET_RPC_URL is set (deploy-core reads it as
#    ${ENV_UPPER//-/_}_RPC_URL). config.op-mainnet.json is the target (authoritative);
#    config.optimism.json is legacy V3 — do NOT deploy into it.
set -a; . ./.env.op-mainnet; set +a
[ -n "$OP_MAINNET_RPC_URL" ] || { echo "OP_MAINNET_RPC_URL unset"; exit 1; }

# 1. Full-stack V5.4.2 deploy → writes deployments/config.op-mainnet.json.
#    --fresh-deploy: this is the FIRST V5 deploy on chain 10 → new UUPS proxies. V5 is NOT an
#    in-place upgrade of the legacy V3 (storage layout differs), so the "--fresh-deploy will
#    LOSE all on-chain state" warning is EXPECTED and correct — the V3 stack is superseded,
#    not upgraded. (Use plain `./deploy-core op-mainnet` only for later same-stack redeploys;
#    `--force` only to override the skip-if-srcHash-unchanged guard.)
./deploy-core op-mainnet --fresh-deploy

# 2. Verify on-chain versions (fail = stop). Script takes the RPC URL as its arg.
./version-check-onchain.sh "$OP_MAINNET_RPC_URL"   # expect SuperPaymaster-5.4.2 / V5 stack

# 3. Post-deploy ownership → EOA-first, then Safe once stable (mirror CC-29 model).
#    Per Ownable contract (SuperPaymaster, Registry, LivenessRegistry, PolicyRegistry guardian,
#    factories, …) transfer to the Safe. Exact call is per-contract — Ownable uses
#    transferOwnership(address); slashPolicyAdmin / role-admins use their own setter (item 6).
cast send <each-Ownable-contract> \
  "transferOwnership(address)" 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114 \
  --rpc-url "$OP_MAINNET_RPC_URL" --account <deployer-keystore>
#    Also: slashPolicyAdmin → Safe/Timelock (CC-30 item 6, its own setter, not transferOwnership).

# 4. aPNTs mainnet address + fund SuperPaymaster deposit (CC-30 item 7).

# 5. EntryPoint stake / deposit for the paymaster as required.
```

> The `<each-Ownable-contract>` / `<deployer-keystore>` placeholders are the only non-literal
> parts — fill them from the freshly-written `config.op-mainnet.json` and your keystore name.

---

## Post-deploy — record + notify (do not skip)

1. Commit `deployments/config.op-mainnet.json` (real addresses) via a `deploy(op-mainnet): …` PR — the config-driven single source.
2. Post the mainnet addresses to **CC-30** and `@` the dependents:
   - `@repo:sdk` —接入 `CANONICAL_ADDRESSES[10]`（覆盖旧 V3）+ 链上 `version()==5.4.2` 自验 → 发主网 patch（CC-18 两阶段）。
   - `@repo:yaaa` — gasless 主网就绪。
   - `@repo:airaccount-contract` — aPNTs 主网地址交付。
3. Update memory `cc30-production-readiness`.

---

## Config authority (G10 — resolved)

| env / file | chain | stack | role |
|---|---|---|---|
| `op-mainnet` / `config.op-mainnet.json` | 10 | V5.4.2 | **authoritative** (this runbook targets it) |
| `optimism` / `config.optimism.json` | 10 | V3 (3.2.2) | **legacy record** — do not read for V5 canonical |

Downstream (SDK) should read OP-mainnet canonical from the `op-mainnet` config once populated.
