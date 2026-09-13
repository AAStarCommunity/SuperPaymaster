#!/usr/bin/env node
// Runtime sizes (EIP-170) from forge artifacts, selecting each artifact by its OWN metadata
// (evmVersion / optimizer runs / viaIR / compilationTarget) — never by file name, because forge
// names artifacts X.json, X.default.json or X.registry-size.json depending on what was compiled.
// Also reports whether the artifact's source keccak equals the source file in the tree.
//
// Usage: node script/evidence/sizes.mjs <tree root (has out/ and contracts/)> [Contract=relSourcePath ...]
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';

const root = process.argv[2] || '.';
const { keccak256, toHex } = await import('viem');
const DEFAULT = [
  'SuperPaymaster=contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol',
  'SuperPaymasterLens=contracts/src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol',
  'xPNTsTokenV2=contracts/src/tokens/v2/xPNTsTokenV2.sol',
  'xPNTsTokenV2Ext=contracts/src/tokens/v2/xPNTsTokenV2Ext.sol',
  'APNTsCapped=contracts/src/tokens/APNTsCapped.sol',
  'BLSAggregator=contracts/src/modules/monitoring/BLSAggregator.sol',
];
const targets = process.argv.length > 3 ? process.argv.slice(3) : DEFAULT;
const EIP170 = 24576;
const rows = [];
for (const t of targets) {
  const [name, src] = t.split('=');
  const srcAbs = join(root, src);
  if (!existsSync(srcAbs)) { rows.push({ contract: name, source: src, note: 'source not in this tree' }); continue; }
  const srcKeccak = keccak256(toHex(readFileSync(srcAbs)));
  const dirs = [];
  const walk = (d) => { for (const e of readdirSync(d, { withFileTypes: true })) { const p = join(d, e.name); if (e.isDirectory()) walk(p); else if (e.name === `${name}.json` || e.name.startsWith(`${name}.`) && e.name.endsWith('.json')) dirs.push(p); } };
  walk(join(root, 'out'));
  for (const f of dirs) {
    let j; try { j = JSON.parse(readFileSync(f, 'utf8')); } catch { continue; }
    const m = j.metadata; if (!m) continue;
    const target = Object.keys(m.settings.compilationTarget)[0];
    if (target !== src) continue;
    const rt = (j.deployedBytecode?.object || '0x').slice(2);
    rows.push({
      contract: name, artifact: relative(root, f), runs: m.settings.optimizer.runs, evm: m.settings.evmVersion,
      viaIR: m.settings.viaIR, runtimeBytes: rt.length / 2, headroom: EIP170 - rt.length / 2,
      sourceKeccakMatchesTree: m.sources[src]?.keccak256 === srcKeccak,
    });
  }
}
console.log(JSON.stringify({ tree: process.env.SIZES_TREE_LABEL || root, eip170: EIP170, rows }, null, 2));
