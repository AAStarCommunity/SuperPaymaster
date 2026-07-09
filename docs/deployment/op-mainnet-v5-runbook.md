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
| 3 | `.env.op-mainnet` filled: `OP-MAINNET_RPC_URL`, signer (`DEPLOYER_ACCOUNT` keystore preferred over `PRIVATE_KEY`) | jason | 🔴 (template exists, secrets pending) |
| 4 | DVT mainnet validators + production nodes ready (BLS quorum is a slash prerequisite) | @repo:dvt | 🔴 |
| 5 | Chainlink ETH/USD price feed address for OP mainnet confirmed in deploy config | SP | 🟡 verify |
| 6 | Mycelium community Safe reachable on OP mainnet (`0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`, `oeth:`) for post-deploy ownership transfer (CC-31) | jason | ✅ address known |

---

## Deploy sequence

```bash
# 0. Pre-flight: confirm you are NOT about to hit the legacy V3 config.
#    config.op-mainnet.json is the target (authoritative); config.optimism.json is legacy V3.

# 1. Full-stack V5.4.2 deploy (writes deployments/config.op-mainnet.json).
./deploy-core op-mainnet          # add --force only if re-deploying over an unchanged srcHash

# 2. Verify on-chain versions match 5.4.2 (fail = stop).
./version-check-onchain.sh        # expect SuperPaymaster-5.4.2 / Registry-... V5 stack

# 3. Post-deploy ownership → EOA-first, then Safe once stable (mirror CC-29 model).
#    Owners/admins deploy under the deployer EOA for bring-up, then transfer to the Safe:
cast send <SuperPaymaster/Registry/LivenessRegistry/...> \
  "transferOwnership(address)" 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114 \
  --rpc-url "$OP_MAINNET_RPC_URL" --account <deployer-keystore>
#    Also: slashPolicyAdmin → Safe/Timelock (CC-30 item 6).

# 4. aPNTs mainnet address + fund SuperPaymaster deposit (CC-30 item 7).

# 5. EntryPoint stake / deposit for the paymaster as required.
```

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
