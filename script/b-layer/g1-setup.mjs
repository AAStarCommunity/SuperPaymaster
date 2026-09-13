// D5 gate G1 (B1–B10) setup on top of DeployBLayerAnvil (deploy.json). Local anvil only.
// - SP EntryPoint stake: 0.1 ETH / 86400 s (the "below threshold" state — the value Sepolia's and
//   OP mainnet's SP actually have, b-layer/README §2 finding 3). The runner tops it up for B9-above.
// - MockAirAccountFactory ×4: staked 1 ETH/86400 (ok), unstaked, 0.5 ETH/86400 (low stake),
//   1 ETH/3600 (short delay: below Rundler's 86400, above Alto's default 1 s).
// - one pre-deployed MockAirAccount per case (+ counterfactual B4 accounts), each an SBT holder in SP
//   (sbtHolders set by impersonating Registry → SP.updateSBTStatus, the Registry's own write path)
//   and funded with operator tokens (except the CREDIT-mode account B7).
// - B7: token credit policy AUTO via queue → +48 h → execute; account requestCredit (impersonated);
//   Registry credit tiers raised to 1000 aPNTs so a0 fits under the tier (tier source = Registry).
// - price refreshed after the warp.
// Usage: node script/b-layer/g1-setup.mjs <rpcUrl> <outJson>
import { writeFileSync } from "node:fs";
import { privateKeyToAccount } from "viem/accounts";
import { clients, deploy, send, rpc, EP, ANVIL_KEYS, eth } from "./lib.mjs";
import { ABI, loadDeploy, asImpersonated, maxCostOf, a0Of, GAS } from "./g1-lib.mjs";

const [rpcUrl, outJson] = process.argv.slice(2);
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(rpcUrl)) throw new Error("local node only");
const d = loadDeploy();
const ctx = clients(rpcUrl, ANVIL_KEYS[0]); // deployer = SP owner = operator = token communityOwner = Registry owner
const OWNER_KEY = ANVIL_KEYS[3];
const owner = privateKeyToAccount(OWNER_KEY).address;
const read = (address, abi, functionName, args = []) => ctx.pub.readContract({ address, abi, functionName, args });

// ---- SP stake: below threshold first -------------------------------------------------------
await send(ctx, d.superPaymaster, ABI.sp, "addStake", [86_400], eth("0.1"));

// ---- factories -------------------------------------------------------------------------------
const factories = {};
for (const [name, stake, delay] of [["ok", "1", 86_400], ["unstaked", null, 0], ["lowStake", "0.5", 86_400], ["shortDelay", "1", 3_600]]) {
    const f = await deploy(ctx, "BLayerAccounts.sol", "MockAirAccountFactory", [EP]);
    if (stake) await send(ctx, f.address, ABI.factory, "stake", [delay], eth(stake));
    const info = await read(EP, ABI.ep, "getDepositInfo", [f.address]);
    factories[name] = { address: f.address, stake: info.stake.toString(), unstakeDelaySec: info.unstakeDelaySec, staked: info.staked };
}

// ---- accounts --------------------------------------------------------------------------------
const tok = d.operatorToken;
const mint = (to, amount) => send(ctx, tok, ABI.token, "mint", [to, amount]);
const sbt = (user) => asImpersonated(rpcUrl, ctx.pub, d.registry, d.superPaymaster, ABI.sp, "updateSBTStatus", [user, true]);

const a0 = await a0Of(ctx, d, maxCostOf());
const a0Init = await a0Of(ctx, d, maxCostOf({ verificationGasLimit: GAS.verificationGasLimitInit }));
const accounts = {};
const plan = { b1: 1, b2: 2, b2x: 12, b3a: 3, b3b: 4, b3c: 5, b5: 6, b6: 7, b7: 8, b8: 9, b9: 10, b10: 11 };
for (const [name, salt] of Object.entries(plan)) {
    await send(ctx, factories.ok.address, ABI.factory, "createAccount", [owner, tok, d.superPaymaster, BigInt(salt)]);
    const addr = await read(factories.ok.address, ABI.factory, "getAddress", [BigInt(salt)]);
    await sbt(addr);
    // B2: room for exactly two locks of x0 (rate 1e18 → x0 = a0), the third must fail (T-R14-02).
    // B7: zero balance → tryLockForGas INSUFFICIENT → credit path.
    const amount = name === "b7" ? 0n : (name === "b2" || name === "b2x") ? (a0 * 5n) / 2n : 3_000n * 10n ** 18n;
    if (amount) await mint(addr, amount);
    accounts[name] = { address: addr, salt, balance: amount.toString() };
}
// B4: counterfactual accounts (same salt on each factory), SBT + funded before deployment
const b4 = {};
for (const [name, f] of Object.entries(factories)) {
    const addr = await read(f.address, ABI.factory, "getAddress", [100n]);
    await sbt(addr);
    await mint(addr, 3_000n * 10n ** 18n);
    b4[name] = { address: addr, factory: f.address, salt: 100 };
}

// ---- B7 credit: AUTO policy (queue → 48 h → execute), tier via Registry, requestCredit ------------
for (const lvl of [5, 4, 3, 2, 1]) await send(ctx, d.registry, ABI.registry, "setCreditTier", [BigInt(lvl), 1_000n * 10n ** 18n]);
await send(ctx, tok, ABI.token, "queueCreditPolicy", [2]);
await rpc(rpcUrl, "evm_increaseTime", [48 * 3600 + 60]);
await rpc(rpcUrl, "evm_mine", []);
await send(ctx, tok, ABI.token, "executeCreditPolicy", []);
await asImpersonated(rpcUrl, ctx.pub, accounts.b7.address, tok, ABI.token, "requestCredit", [1_000n * 10n ** 18n]);
// price cache must be fresh after the warp (validUntil = updatedAt + staleness)
await send(ctx, d.superPaymaster, ABI.sp, "updatePrice", []);

const spInfo = await read(EP, ABI.ep, "getDepositInfo", [d.superPaymaster]);
const out = {
    rpcUrl, deploy: d, ownerKeyIndex: 3, owner, factories, accounts, b4, // account owner = anvil dev key #3 (by index, key not written)
    a0: a0.toString(), a0Init: a0Init.toString(), gas: Object.fromEntries(Object.entries(GAS).map(([k, v]) => [k, v.toString()])),
    creditPolicy: await read(tok, ABI.token, "creditPolicy"),
    b7EffectiveCreditCap: (await read(tok, ABI.token, "effectiveCreditCap", [accounts.b7.address])).toString(),
    b7TierFromRegistry: (await read(d.registry, ABI.registry, "getCreditLimit", [accounts.b7.address])).toString(),
    spStake: { stake: spInfo.stake.toString(), unstakeDelaySec: spInfo.unstakeDelaySec, deposit: spInfo.deposit.toString() },
};
writeFileSync(outJson, JSON.stringify(out, null, 2));
console.log(JSON.stringify({ a0: out.a0, a0Init: out.a0Init, spStake: out.spStake, factories, creditPolicy: out.creditPolicy,
    b7Cap: out.b7EffectiveCreditCap }, null, 2));
