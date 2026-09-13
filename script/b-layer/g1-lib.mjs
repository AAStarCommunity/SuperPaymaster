// D5 gate G1 (B1–B10) — shared helpers on top of lib.mjs. Local nodes only.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createWalletClient, http, concat, pad, toHex, encodeFunctionData, getAddress } from "viem";
import { ROOT, EP, artifact, buildOp, rpc } from "./lib.mjs";

export const DEPLOY_JSON = process.env.G1_DEPLOY_JSON ? resolve(ROOT, process.env.G1_DEPLOY_JSON) : resolve(ROOT, "docs/design/aoa-balance-mode/b-layer/cases/deploy.json");

// Fixed UserOperation gas/fee fields for every case (so a0 = maxCost-priced reservation is the
// same on both bundlers). paymasterPostOpGasLimit ≥ MIN_POST_OP_GAS (200000, spec §3.2).
export const GAS = {
    verificationGasLimit: 250_000n,
    verificationGasLimitInit: 1_200_000n, // B4: initCode (CREATE2 of the account + factory bookkeeping)
    callGasLimit: 60_000n,
    preVerificationGas: 100_000n,
    pmVerificationGasLimit: 300_000n,
    pmPostOpGasLimit: 250_000n,
    maxFeePerGas: 3_000_000_000n,
    maxPriorityFeePerGas: 2_000_000_000n,
};
export const MIN_POST_OP_GAS = 200_000n;
export const FLAG_SP_RENEW = 1;
export const FLAG_ACCOUNT_RENEW = 2;

function mergeAbis(...abis) {
    const seen = new Set();
    const out = [];
    for (const abi of abis) for (const x of abi) {
        const k = `${x.type}:${x.name}:${(x.inputs ?? []).map((i) => i.type).join(",")}`;
        if (!seen.has(k)) { seen.add(k); out.push(x); }
    }
    return out;
}

export const ABI = {
    sp: artifact("SuperPaymaster.sol", "SuperPaymaster").abi,
    token: mergeAbis(artifact("xPNTsTokenV2.sol", "xPNTsTokenV2").abi, artifact("xPNTsTokenV2Ext.sol", "xPNTsTokenV2Ext").abi),
    registry: artifact("Registry.sol", "Registry").abi,
    account: artifact("BLayerAccounts.sol", "MockAirAccount").abi,
    factory: artifact("BLayerAccounts.sol", "MockAirAccountFactory").abi,
    ep: [
        { type: "function", name: "getNonce", stateMutability: "view", inputs: [{ name: "s", type: "address" }, { name: "k", type: "uint192" }], outputs: [{ type: "uint256" }] },
        { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
        {
            type: "function", name: "getDepositInfo", stateMutability: "view", inputs: [{ name: "a", type: "address" }],
            outputs: [{ type: "tuple", components: [
                { name: "deposit", type: "uint256" }, { name: "staked", type: "bool" }, { name: "stake", type: "uint112" },
                { name: "unstakeDelaySec", type: "uint32" }, { name: "withdrawTime", type: "uint48" }] }],
        },
        {
            type: "function", name: "handleOps", stateMutability: "nonpayable", outputs: [],
            inputs: [{ name: "ops", type: "tuple[]", components: [
                { name: "sender", type: "address" }, { name: "nonce", type: "uint256" },
                { name: "initCode", type: "bytes" }, { name: "callData", type: "bytes" },
                { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" },
                { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" },
                { name: "signature", type: "bytes" }] }, { name: "beneficiary", type: "address" }],
        },
        { type: "error", name: "FailedOp", inputs: [{ name: "opIndex", type: "uint256" }, { name: "reason", type: "string" }] },
        { type: "error", name: "FailedOpWithRevert", inputs: [{ name: "opIndex", type: "uint256" }, { name: "reason", type: "string" }, { name: "inner", type: "bytes" }] },
    ],
};

export function loadDeploy() { return JSON.parse(readFileSync(DEPLOY_JSON, "utf8")); }

/** paymasterData (after the 52-byte v0.7 prefix): operator ‖ maxRate(32) ‖ token ‖ flags(1) — spec §3.2 */
export function pmData({ operator, token, maxRate = 10n ** 18n, flags = 0 }) {
    return concat([operator, pad(toHex(maxRate), { size: 32 }), token, pad(toHex(flags), { size: 1 })]);
}

/** Build + sign a v0.7 op for a MockAirAccount; `accountRenew` appends the option-A flag byte 0x01. */
export async function buildG1Op(ctx, d, { sender, nonceKey = 0n, ownerKey, flags = 0, accountRenew = false,
    factory, factoryData, verificationGasLimit, pmPostOpGasLimit = GAS.pmPostOpGasLimit, callData }) {
    const nonce = await ctx.pub.readContract({ address: EP, abi: ABI.ep, functionName: "getNonce", args: [sender, nonceKey] });
    const { rpcOp, packed, hash } = await buildOp(ctx, {
        sender, nonce, ownerKey, factory, factoryData,
        callData: callData ?? encodeFunctionData({ abi: ABI.account, functionName: "execute", args: ["0x000000000000000000000000000000000000dEaD", 0n, "0x"] }),
        callGasLimit: GAS.callGasLimit,
        verificationGasLimit: verificationGasLimit ?? (factory ? GAS.verificationGasLimitInit : GAS.verificationGasLimit),
        preVerificationGas: GAS.preVerificationGas,
        maxFeePerGas: GAS.maxFeePerGas, maxPriorityFeePerGas: GAS.maxPriorityFeePerGas,
        pm: { address: d.superPaymaster, verificationGasLimit: GAS.pmVerificationGasLimit, postOpGasLimit: pmPostOpGasLimit,
            data: pmData({ operator: d.operator, token: d.operatorToken, flags }) },
    });
    if (accountRenew) { rpcOp.signature = concat([rpcOp.signature, "0x01"]); packed.signature = rpcOp.signature; }
    return { rpcOp, packed, hash, nonce };
}

/** requiredPrefund = maxCost handed to validatePaymasterUserOp (EntryPoint v0.7). */
export function maxCostOf({ verificationGasLimit = GAS.verificationGasLimit, pmPostOpGasLimit = GAS.pmPostOpGasLimit } = {}) {
    return (verificationGasLimit + GAS.callGasLimit + GAS.pmVerificationGasLimit + pmPostOpGasLimit + GAS.preVerificationGas)
        * GAS.maxFeePerGas;
}

/** a0 exactly as SP 5.5.0 computes it (validatePaymasterUserOp §3 / §10.3). */
export async function a0Of(ctx, d, maxCost) {
    const [price, , , decimals] = await ctx.pub.readContract({ address: d.superPaymaster, abi: ABI.sp, functionName: "cachedPrice" });
    const aUsd = await ctx.pub.readContract({ address: d.superPaymaster, abi: ABI.sp, functionName: "aPNTsPriceUSD" });
    const fee = await ctx.pub.readContract({ address: d.superPaymaster, abi: ABI.sp, functionName: "protocolFeeBPS" });
    const ceilDiv = (a, b) => (a + b - 1n) / b;
    const base = ceilDiv(maxCost * BigInt(price) * 10n ** 18n, 10n ** BigInt(decimals) * aUsd);
    return ceilDiv(base * (10_000n + fee + 1_000n), 10_000n);
}

/** Send a tx as an arbitrary address on anvil (anvil_impersonateAccount). */
export async function asImpersonated(rpcUrl, pub, from, to, abi, functionName, args = [], value = 0n) {
    await rpc(rpcUrl, "anvil_impersonateAccount", [from]);
    await rpc(rpcUrl, "anvil_setBalance", [from, "0x56BC75E2D63100000"]); // 100 ETH for gas
    const w = createWalletClient({ account: getAddress(from), transport: http(rpcUrl) });
    const hash = await w.writeContract({ address: to, abi, functionName, args, value, chain: null });
    const rc = await pub.waitForTransactionReceipt({ hash });
    await rpc(rpcUrl, "anvil_stopImpersonatingAccount", [from]);
    if (rc.status !== "success") throw new Error(`${functionName} as ${from} reverted`);
    return rc;
}

export async function waitReceipt(bundlerUrl, userOpHash, tries = 40) {
    for (let i = 0; i < tries; i++) {
        const r = await rpc(bundlerUrl, "eth_getUserOperationReceipt", [userOpHash]);
        if (r.result) return r.result;
        await new Promise((res) => setTimeout(res, 500));
    }
    return null;
}
