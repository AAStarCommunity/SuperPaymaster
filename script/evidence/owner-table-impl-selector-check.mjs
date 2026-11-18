// READ-ONLY positive control for the round-4 notInCode fix: for SP and Registry (UUPS proxies), shows whether each
// getter selector is in the proxy runtime and in the EIP-1967 implementation runtime, read on both endpoints.
// Usage: node script/evidence/owner-table-impl-selector-check.mjs <envFileWithRPC_URL> <secondRpcUrl> <block>
import { readFileSync } from "node:fs";
import { createPublicClient, http, toFunctionSelector } from "viem";
import { both, IMPL_SLOT, makeRedactor } from "../rehearsal/lib/two-endpoint.mjs";
const a = readFileSync(process.argv[2], "utf8").split("\n").find((l) => l.startsWith("RPC_URL=")).slice(8).trim(), b = process.argv[3];
const redact = makeRedactor([a, b]);
const cs = [a, b].map((u) => createPublicClient({ transport: http(u) })); const blockNumber = BigInt(process.argv[4]);
for (const [name, addr, fns] of [["SP", "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9", ["EXTENSION()", "guardian()", "pendingOwner()", "owner()", "xpntsFactory()"]],
                                 ["REGISTRY", "0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71", ["pendingOwner()", "owner()", "blsAggregator()"]]]) {
  const slot = await both(cs, (c) => c.getStorageAt({ address: addr, slot: IMPL_SLOT, blockNumber }), redact);
  const impl = "0x" + slot.value.slice(26);
  const own = (await both(cs, (c) => c.getCode({ address: addr, blockNumber }), redact)).value.toLowerCase();
  const ic = (await both(cs, (c) => c.getCode({ address: impl, blockNumber }), redact)).value.toLowerCase();
  for (const f of fns) { const s = toFunctionSelector("function " + f).slice(2);
    console.log(name, "impl", impl, f, "inProxyCode", own.includes("63" + s), "inImplCode", ic.includes("63" + s)); }
}
