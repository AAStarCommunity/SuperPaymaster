// B0 setup: canonical EntryPoint v0.7, SimpleAccountFactory, one account per case, the four
// violators + the compliant control. Writes the addresses to <out>.json.
// Usage: node script/b-layer/b0-setup.mjs <rpcUrl> <outJson> [stakeWei] [unstakeDelaySec]
import { writeFileSync } from "node:fs";
import { clients, etchEntryPoint, deploy, send, EP, EP_ABI, ANVIL_KEYS, eth } from "./lib.mjs";

const [rpcUrl, outJson, stakeArg, delayArg] = process.argv.slice(2);
if (!rpcUrl || !outJson) throw new Error("usage: b0-setup.mjs <rpcUrl> <outJson> [stakeWei] [unstakeDelaySec]");
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(rpcUrl)) throw new Error("local node only");
const STAKE = BigInt(stakeArg ?? eth("10").toString());
const DELAY = Number(delayArg ?? 86_400 * 2);

const ctx = clients(rpcUrl, ANVIL_KEYS[0]);
await etchEntryPoint(rpcUrl, ctx.pub);

const OWNER_KEY = ANVIL_KEYS[3];
const { privateKeyToAccount } = await import("viem/accounts");
const owner = privateKeyToAccount(OWNER_KEY).address;

const factory = await deploy(ctx, "SimpleAccountFactory.sol", "SimpleAccountFactory", [EP]);
const sink = await deploy(ctx, "B0Violators.sol", "B0Sink");
const cases = {
    control: await deploy(ctx, "B0Violators.sol", "B0PmCompliant"),
    op011_timestamp: await deploy(ctx, "B0Violators.sol", "B0PmTimestamp"),
    sto031_unstakedOwnStorage: await deploy(ctx, "B0Violators.sol", "B0PmUnstakedOwnStorage"),
    op070_unstakedTstore: await deploy(ctx, "B0Violators.sol", "B0PmUnstakedTstore"),
    sto021_stakedExternalWrite: await deploy(ctx, "B0Violators.sol", "B0PmStakedExternalWrite", [sink.address]),
};

const out = { rpcUrl, entryPoint: EP, factory: factory.address, sink: sink.address, owner, ownerKey: OWNER_KEY,
    stakeWei: STAKE.toString(), unstakeDelaySec: DELAY, cases: {} };
let salt = 0n;
for (const [name, pm] of Object.entries(cases)) {
    await send(ctx, EP, EP_ABI, "depositTo", [pm.address], eth("1"));
    if (name === "sto021_stakedExternalWrite") {
        await send(ctx, pm.address, pm.abi, "stake", [EP, DELAY], STAKE);
    }
    // one pre-deployed SimpleAccount per case (no initCode in B0; initCode is B4)
    await send(ctx, factory.address, factory.abi, "createAccount", [owner, salt]);
    const account = await ctx.pub.readContract({ address: factory.address, abi: factory.abi, functionName: "getAddress", args: [owner, salt] });
    await ctx.wallet.sendTransaction({ to: account, value: eth("1"), chain: null });
    out.cases[name] = { paymaster: pm.address, account, salt: salt.toString() };
    salt += 1n;
}
writeFileSync(outJson, JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 2));
