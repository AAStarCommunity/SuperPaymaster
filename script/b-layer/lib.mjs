// D5 gate G1 (B layer) harness — shared helpers. Local nodes only (anvil); never a public RPC.
// Spec: docs/design/aoa-balance-mode/D5-plan.md §3.
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
    createPublicClient, createWalletClient, http, encodeFunctionData, concat, pad, toHex,
    parseEther, getAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export const EP = "0x0000000071727De22E5E9d8BAf0edAc6f37da032";
export const SENDER_CREATOR = "0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C";
export const EP_CODEHASH = "0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58";

// anvil's well-known dev keys (public, local-only)
export const ANVIL_KEYS = [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
];

export function artifact(file, name) {
    const j = JSON.parse(readFileSync(resolve(ROOT, "out", file, `${name}.json`), "utf8"));
    return { abi: j.abi, bytecode: j.bytecode.object };
}

export function clients(rpc, key = ANVIL_KEYS[0]) {
    const transport = http(rpc, { timeout: 60_000 });
    const pub = createPublicClient({ transport });
    const account = privateKeyToAccount(key);
    const wallet = createWalletClient({ account, transport });
    return { pub, wallet, account };
}

export async function rpc(url, method, params) {
    const r = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    return r.json();
}

/** Put the canonical EntryPoint v0.7 + SenderCreator runtime at their canonical addresses. */
export async function etchEntryPoint(rpcUrl, pub) {
    const ep = readFileSync(resolve(ROOT, "contracts/test/fixtures/entrypoint-v0.7.runtime.hex"), "utf8").trim();
    const sc = readFileSync(resolve(ROOT, "contracts/test/fixtures/sendercreator-v0.7.runtime.hex"), "utf8").trim();
    // anvil: set the code; geth --dev: no setCode RPC — the code must come from the genesis alloc
    const r = await rpc(rpcUrl, "anvil_setCode", [EP, ep]);
    if (!r.error) await rpc(rpcUrl, "anvil_setCode", [SENDER_CREATOR, sc]);
    const code = await pub.getCode({ address: EP });
    if (!code || code === "0x") throw new Error("EntryPoint missing (geth: put it in the genesis alloc)");
    const { keccak256 } = await import("viem");
    if (keccak256(code) !== EP_CODEHASH) throw new Error("EntryPoint codehash mismatch");
}

export async function deploy(ctx, file, name, args = [], value = 0n) {
    const { abi, bytecode } = artifact(file, name);
    const hash = await ctx.wallet.deployContract({ abi, bytecode, args, value, chain: null });
    const rc = await ctx.pub.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`deploy ${name} failed`);
    return { address: getAddress(rc.contractAddress), abi };
}

export async function send(ctx, to, abi, functionName, args = [], value = 0n) {
    const hash = await ctx.wallet.writeContract({ address: to, abi, functionName, args, value, chain: null });
    const rc = await ctx.pub.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`${functionName} reverted`);
    return rc;
}

const EP_ABI = [
    { type: "function", name: "depositTo", stateMutability: "payable", inputs: [{ name: "a", type: "address" }], outputs: [] },
    { type: "function", name: "getNonce", stateMutability: "view", inputs: [{ name: "s", type: "address" }, { name: "k", type: "uint192" }], outputs: [{ type: "uint256" }] },
    {
        type: "function", name: "getUserOpHash", stateMutability: "view",
        inputs: [{
            name: "op", type: "tuple", components: [
                { name: "sender", type: "address" }, { name: "nonce", type: "uint256" },
                { name: "initCode", type: "bytes" }, { name: "callData", type: "bytes" },
                { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" },
                { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" },
                { name: "signature", type: "bytes" },
            ],
        }],
        outputs: [{ type: "bytes32" }],
    },
];
export { EP_ABI };

const u128 = (v) => pad(toHex(v), { size: 16 });

/**
 * Build + sign a v0.7 UserOperation. Returns { rpcOp (bundler JSON format), packed, hash }.
 * `pm` = { address, verificationGasLimit, postOpGasLimit, data } or null.
 */
export async function buildOp(ctx, { sender, nonce, callData = "0x", factory, factoryData,
    callGasLimit = 100_000n, verificationGasLimit = 300_000n, preVerificationGas = 100_000n,
    maxFeePerGas = 20_000_000_000n, maxPriorityFeePerGas = 2_000_000_000n, pm, ownerKey }) {
    const initCode = factory ? concat([factory, factoryData]) : "0x";
    const paymasterAndData = pm
        ? concat([pm.address, u128(pm.verificationGasLimit), u128(pm.postOpGasLimit), pm.data ?? "0x"])
        : "0x";
    const packed = {
        sender, nonce, initCode, callData,
        accountGasLimits: concat([u128(verificationGasLimit), u128(callGasLimit)]),
        preVerificationGas,
        gasFees: concat([u128(maxPriorityFeePerGas), u128(maxFeePerGas)]),
        paymasterAndData, signature: "0x",
    };
    const hash = await ctx.pub.readContract({ address: EP, abi: EP_ABI, functionName: "getUserOpHash", args: [packed] });
    const owner = privateKeyToAccount(ownerKey);
    const signature = await owner.signMessage({ message: { raw: hash } });
    packed.signature = signature;
    const rpcOp = {
        sender, nonce: toHex(nonce), callData,
        callGasLimit: toHex(callGasLimit), verificationGasLimit: toHex(verificationGasLimit),
        preVerificationGas: toHex(preVerificationGas),
        maxFeePerGas: toHex(maxFeePerGas), maxPriorityFeePerGas: toHex(maxPriorityFeePerGas),
        signature,
    };
    if (factory) { rpcOp.factory = factory; rpcOp.factoryData = factoryData; }
    if (pm) {
        rpcOp.paymaster = pm.address;
        rpcOp.paymasterVerificationGasLimit = toHex(pm.verificationGasLimit);
        rpcOp.paymasterPostOpGasLimit = toHex(pm.postOpGasLimit);
        rpcOp.paymasterData = pm.data ?? "0x";
    }
    return { rpcOp, packed, hash };
}

export const eth = parseEther;
export { encodeFunctionData };
