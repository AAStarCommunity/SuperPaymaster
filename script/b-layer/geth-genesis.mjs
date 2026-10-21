// Build a geth --dev genesis that carries the canonical EntryPoint v0.7 + SenderCreator and the
// deterministic CREATE2 deployer (Alto deploys its simulation contracts through it), and funds
// the anvil dev keys used by the harness. Local node only.
// Usage: node script/b-layer/geth-genesis.mjs <devGenesisDump.json> <out.json>
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { privateKeyToAccount } from "viem/accounts";
import { ROOT, EP, SENDER_CREATOR, ANVIL_KEYS } from "./lib.mjs";

const [dumpPath, outPath] = process.argv.slice(2);
const g = JSON.parse(readFileSync(dumpPath, "utf8"));
const hex = (p) => readFileSync(resolve(ROOT, p), "utf8").trim();
// Arachnid deterministic-deployment-proxy runtime (same bytecode anvil pre-installs)
const CREATE2_DEPLOYER = "0x4e59b44847b379578588920ca78fbf26c0b4956c";
const CREATE2_RUNTIME = "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

g.alloc = g.alloc ?? {};
g.alloc[EP.toLowerCase().slice(2)] = { balance: "0x0", code: hex("contracts/test/fixtures/entrypoint-v0.7.runtime.hex") };
g.alloc[SENDER_CREATOR.toLowerCase().slice(2)] = { balance: "0x0", code: hex("contracts/test/fixtures/sendercreator-v0.7.runtime.hex") };
g.alloc[CREATE2_DEPLOYER.slice(2)] = { balance: "0x0", code: CREATE2_RUNTIME };
for (const k of ANVIL_KEYS) {
    g.alloc[privateKeyToAccount(k).address.toLowerCase().slice(2)] = { balance: "0x3635c9adc5dea00000000" }; // 1,000,000 ETH
}
writeFileSync(outPath, JSON.stringify(g, null, 2));
console.log(`genesis written: chainId ${g.config?.chainId}, alloc entries ${Object.keys(g.alloc).length}`);
