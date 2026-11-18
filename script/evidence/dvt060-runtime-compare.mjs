#!/usr/bin/env node
// READ-ONLY: compare the runtime code deployed at the old DVTValidator with a local build of a given
// source commit, on BOTH endpoints. Same method as verify-attested-runtime.mjs: require equal length,
// zero every immutableReferences range of the artifact in the on-chain bytes, then require the masked
// on-chain bytes == the artifact's deployedBytecode, byte for byte (this includes the trailing CBOR
// metadata section, i.e. its metadata hash when the build emits one).
// Build recipe (the commit's own [profile.default]):
//   git archive <commit> foundry.toml contracts/src singleton-paymaster/lib/openzeppelin-contracts-v5.0.2 | tar -x -C <dir>
//   (cd <dir> && mkdir -p contracts/lib && forge build --offline contracts/src/modules/monitoring/DVTValidator.sol)
// Usage: node script/evidence/dvt060-runtime-compare.mjs <envFileWithRPC_URL> <secondRpcUrl> <artifact.json> <block> <address> <commit> <out.json>
import { readFileSync, writeFileSync } from "node:fs";
import { createPublicClient, http, keccak256, getAddress } from "viem";
import { makeRedactor, assertIndependent, both, verifyPin } from "../rehearsal/lib/two-endpoint.mjs";

const CHAIN_ID = 11155111;
let redact = String;

export function maskAndCompare(onchainHex, artifact) {
    const art = artifact.deployedBytecode.object.replace(/^0x/, "");
    const chain = onchainHex.replace(/^0x/, "");
    const ranges = Object.values(artifact.deployedBytecode.immutableReferences ?? {}).flat();
    if (chain.length !== art.length) return { match: false, reason: `length ${chain.length / 2} != ${art.length / 2}`, ranges: ranges.length };
    let masked = chain;
    const immutables = [];
    for (const { start, length } of ranges) {
        immutables.push({ start, value: "0x" + chain.slice(start * 2, (start + length) * 2) });
        masked = masked.slice(0, start * 2) + "00".repeat(length) + masked.slice((start + length) * 2);
    }
    let firstDiff = -1;
    for (let i = 0; i < masked.length; i += 2) if (masked.slice(i, i + 2) !== art.slice(i, i + 2)) { firstDiff = i / 2; break; }
    return { match: firstDiff === -1, firstDiff, ranges: ranges.length, immutables,
        onchainCodehash: keccak256("0x" + chain), maskedKeccak: keccak256("0x" + masked), artifactKeccak: keccak256("0x" + art) };
}

async function main() {
    const [envFile, secondRpc, artifactPath, blockArg, addressArg, commit, outPath] = process.argv.slice(2);
    const rpcUrl = readFileSync(envFile, "utf8").split("\n").find((l) => l.startsWith("RPC_URL="))?.slice(8).trim();
    redact = makeRedactor([rpcUrl, secondRpc]);
    const providers = assertIndependent(rpcUrl, secondRpc);
    const clients = [rpcUrl, secondRpc].map((u) => createPublicClient({ transport: http(u, { timeout: 60_000 }) }));
    const blk = await clients[0].getBlock({ blockNumber: BigInt(blockArg) });
    const pin = await verifyPin(clients, CHAIN_ID, Number(blockArg), blk.hash);
    const address = getAddress(addressArg);
    const code = await both(clients, (c) => c.getCode({ address, blockNumber: BigInt(blockArg) }), redact);
    if (!code.ok) throw new Error("getCode failed: " + code.error);
    const artifact = JSON.parse(readFileSync(artifactPath, "utf8"));
    const result = maskAndCompare(code.value ?? "0x", artifact);
    const out = { address, commit, artifactRuntimeKeccak: result.artifactKeccak, pin, endpoints: providers,
        method: "mask artifact immutableReferences in the on-chain bytes; masked bytes == artifact deployedBytecode (incl. CBOR tail)", ...result };
    writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n");
    console.log(JSON.stringify({ match: result.match, firstDiff: result.firstDiff, ranges: result.ranges, block: pin.number, endpoints: providers }));
    process.exit(result.match ? 0 : 1);
}

if (process.argv[1] && import.meta.url.endsWith("/" + process.argv[1].split("/").pop())) {
    main().catch((e) => { console.error("COMPARE FAILED: " + redact(e?.stack ?? e)); process.exit(1); });
}
