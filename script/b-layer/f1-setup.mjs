// F1 investigation setup, on top of g1-setup (same chain state as G1). Local anvil only.
// Adds:
//  - the UNMODIFIED eth-infinitism v0.7 sample TokenPaymaster (artifact from f1-build-tpm.sh) with a
//    plain ERC-20 (F1TestToken) and a 1:1 oracle (F1Oracle); staked 1 ETH / 86400 s like the SP,
//    10 ETH deposit; senders = MockAirAccounts that approved the TokenPaymaster (impersonated);
//  - two MockAirAccountGuarded (account-side guard on lockedOf/creditReservedOf; mode 1 = sigFail,
//    mode 2 = revert) funded with 2.5·a0 operator tokens, SBT holders in SP.
// Usage: node script/b-layer/f1-setup.mjs <g1SetupJson> <outJson>
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { getAddress } from "viem";
import { clients, deploy, send, EP, ANVIL_KEYS, eth, ROOT } from "./lib.mjs";
import { ABI, asImpersonated, maxCostOf, GAS } from "./g1-lib.mjs";

const [g1SetupJson, outJson] = process.argv.slice(2);
const S = JSON.parse(readFileSync(g1SetupJson, "utf8"));
const rpcUrl = S.rpcUrl;
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(rpcUrl)) throw new Error("local node only");
const d = S.deploy;
const ctx = clients(rpcUrl, ANVIL_KEYS[0]);
const read = (address, abi, functionName, args = []) => ctx.pub.readContract({ address, abi, functionName, args });
const DUMMY = "0x000000000000000000000000000000000000dEaD";

// ---- TokenPaymaster control -----------------------------------------------------------------
const TPM = JSON.parse(readFileSync(resolve(ROOT, "docs/design/aoa-balance-mode/b-layer/cases/f1/TokenPaymaster.json"), "utf8"));
const token = await deploy(ctx, "F1Fixtures.sol", "F1TestToken");
const oracle = await deploy(ctx, "F1Fixtures.sol", "F1Oracle");
const REFUND_POSTOP_COST = 40_000n;
const tpmHash = await ctx.wallet.deployContract({
    abi: TPM.abi, bytecode: TPM.bytecode, chain: null,
    args: [token.address, EP, DUMMY, DUMMY,
        { priceMarkup: 10n ** 26n, minEntryPointBalance: 0n, refundPostopCost: Number(REFUND_POSTOP_COST), priceMaxAge: 10 * 86400 },
        { cacheTimeToLive: 10 * 86400, maxOracleRoundAge: 10 * 86400, tokenOracle: oracle.address,
            nativeOracle: "0x0000000000000000000000000000000000000000", tokenToNativeOracle: true, tokenOracleReverse: false,
            nativeOracleReverse: false, priceUpdateThreshold: 10n ** 25n },
        { minSwapAmount: 1n, uniswapPoolFee: 3000, slippage: 5 },
        ctx.account.address],
});
const tpmRc = await ctx.pub.waitForTransactionReceipt({ hash: tpmHash });
if (tpmRc.status !== "success") throw new Error("TokenPaymaster deploy failed");
const tpm = getAddress(tpmRc.contractAddress);
await send(ctx, tpm, TPM.abi, "updateCachedPrice", [true]);
await send(ctx, tpm, TPM.abi, "deposit", [], eth("10"));
await send(ctx, tpm, TPM.abi, "addStake", [86_400], eth("1"));
const tpmStake = await read(EP, ABI.ep, "getDepositInfo", [tpm]);

// per-op pre-charge in tokens: (requiredPreFund + refundPostopCost·maxFee) at 1 token = 1 native
const perOpTokens = maxCostOf() + REFUND_POSTOP_COST * GAS.maxFeePerGas;
const tpmAccounts = {};
for (const [name, salt, bal] of [["t1", 201n, perOpTokens * 10n], ["tpm3", 202n, (perOpTokens * 5n) / 2n], ["tAfter", 203n, perOpTokens * 10n]]) {
    await send(ctx, S.factories.ok.address, ABI.factory, "createAccount", [S.owner, d.operatorToken, d.superPaymaster, salt]);
    const addr = await read(S.factories.ok.address, ABI.factory, "getAddress", [salt]);
    await send(ctx, token.address, token.abi, "mint", [addr, bal]);
    await asImpersonated(rpcUrl, ctx.pub, addr, token.address, token.abi, "approve", [tpm, 2n ** 255n]);
    tpmAccounts[name] = { address: addr, salt: Number(salt), balance: bal.toString() };
}

// ---- account-side guard (xPNTs v2 escrow) ---------------------------------------------------------
const guarded = {};
for (const [name, mode] of [["gSig", 1], ["gRev", 2]]) {
    const a = await deploy(ctx, "F1Fixtures.sol", "MockAirAccountGuarded", [EP, S.owner, d.operatorToken, mode]);
    await asImpersonated(rpcUrl, ctx.pub, d.registry, d.superPaymaster, ABI.sp, "updateSBTStatus", [a.address, true]);
    const bal = (BigInt(S.a0) * 5n) / 2n;
    await send(ctx, d.operatorToken, ABI.token, "mint", [a.address, bal]);
    guarded[name] = { address: a.address, mode, balance: bal.toString() };
}
// fresh SP senders for the "after" probes (plain MockAirAccount, funded, SBT)
const spAfter = {};
for (const [name, salt] of [["spAfter1", 301n], ["spAfter2", 302n], ["spAfter3", 303n], ["spAfter4", 304n]]) {
    await send(ctx, S.factories.ok.address, ABI.factory, "createAccount", [S.owner, d.operatorToken, d.superPaymaster, salt]);
    const addr = await read(S.factories.ok.address, ABI.factory, "getAddress", [salt]);
    await asImpersonated(rpcUrl, ctx.pub, d.registry, d.superPaymaster, ABI.sp, "updateSBTStatus", [addr, true]);
    await send(ctx, d.operatorToken, ABI.token, "mint", [addr, 3_000n * 10n ** 18n]);
    spAfter[name] = { address: addr, salt: Number(salt) };
}
// the SP itself must be above threshold for every F1 case (G1 left it at 0.1 ETH for B9-below)
await send(ctx, d.superPaymaster, ABI.sp, "addStake", [86_400], eth("0.9"));
const spStake = await read(EP, ABI.ep, "getDepositInfo", [d.superPaymaster]);

const out = { ...S, f1: {
    tokenPaymaster: tpm, tpmToken: token.address, tpmOracle: oracle.address, refundPostopCost: REFUND_POSTOP_COST.toString(),
    perOpTokens: perOpTokens.toString(), tpmStake: { stake: tpmStake.stake.toString(), unstakeDelaySec: tpmStake.unstakeDelaySec },
    spStake: { stake: spStake.stake.toString(), unstakeDelaySec: spStake.unstakeDelaySec },
    tpmAccounts, guarded, spAfter } };
// make the new senders nameable by access-check.mjs
for (const [n, a] of Object.entries({ ...tpmAccounts, ...guarded, ...spAfter })) out.accounts[n] = { address: a.address };
writeFileSync(outJson, JSON.stringify(out, null, 2));
console.log(JSON.stringify(out.f1, null, 2));
