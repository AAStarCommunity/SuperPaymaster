// Read-only: size + keccak256 of deployed/creation bytecode for the SP 5.5.0 release set from a forge out/ dir.
// Usage: node docs/release/attest-hashes.mjs <outDir>  -> JSON on stdout
// Note: forge artifacts carry zeroed immutables, so runtimeKeccak is an artifact hash, not an on-chain codehash.
import { readFileSync, existsSync } from 'node:fs';
import { keccak256 } from 'viem';

const out = process.argv[2];
if (!out) { console.error('usage: attest-hashes.mjs <outDir>'); process.exit(2); }
const SET = ['SuperPaymaster', 'SuperPaymasterAdmin', 'SuperPaymasterLens', 'Registry', 'xPNTsTokenV2',
  'xPNTsTokenV2Ext', 'xPNTsFactoryV2', 'AOAProtocolRegistry', 'GlobalTierSource', 'APNTsCapped'];
const rows = SET.map((n) => {
  let p = `${out}/${n}.sol/${n}.json`;
  if (!existsSync(p)) p = `${out}/${n}.sol/${n}.default.json`;
  const d = JSON.parse(readFileSync(p, 'utf8'));
  const rt = d.deployedBytecode.object;
  const cr = d.bytecode.object;
  const size = (rt.length - 2) / 2;
  return {
    contract: n,
    artifact: p.slice(out.length + 1),
    runtimeBytes: size,
    headroom: 24576 - size,
    runtimeKeccak: keccak256(rt),
    creationKeccak: keccak256(cr),
    immutableRefs: Object.keys(d.deployedBytecode.immutableReferences || {}).length,
    compiler: d.metadata?.compiler?.version,
    runs: d.metadata?.settings?.optimizer?.runs,
    viaIR: d.metadata?.settings?.viaIR,
    evm: d.metadata?.settings?.evmVersion,
  };
});
console.log(JSON.stringify(rows, null, 1));
