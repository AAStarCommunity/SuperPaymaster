#!/usr/bin/env node
// Build docs/design/aoa-balance-mode/EVIDENCE.sha256 and fill the sha256 cells of EVIDENCE-INDEX.md.
//
// Manifest scope (paths relative to docs/design/aoa-balance-mode/, verify there with
// `shasum -a 256 -c EVIDENCE.sha256`): every file under data/ except data/README.md, plus the raw
// evidence files that already existed before this index (step-0 inventory, B0 responses, B1–B10
// cases, the Rundler chain config) and the F1 manifest FILE itself (the frozen F1 set is its own
// group: b-layer/F1-EVIDENCE.sha256 is hashed here, its 22 members are verified by that manifest and
// are NOT re-listed or touched).
// Index cells: every occurrence of `sha256(<rel path>)=<64 hex | TBD>` is rewritten with the file's
// current hash; an unknown path fails the build.
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join } from 'node:path';

const BASE = 'docs/design/aoa-balance-mode';
const sha = (p) => createHash('sha256').update(readFileSync(join(BASE, p))).digest('hex');
const walk = (d) => readdirSync(join(BASE, d)).flatMap((e) => {
  const p = join(d, e);
  return statSync(join(BASE, p)).isDirectory() ? walk(p) : [p];
});

const files = [
  ...walk('data').filter((p) => p !== 'data/README.md' && p !== 'data/.gitignore'),
  'rehearsal/step0-inventory.json',
  ...walk('b-layer/b0'),
  ...readdirSync(join(BASE, 'b-layer/cases')).filter((e) => /\.(json|txt|js)$/.test(e)).map((e) => `b-layer/cases/${e}`),
  ...walk('b-layer/cases/layouts'),
  'b-layer/rundler-chain-31337.toml',
  'b-layer/F1-EVIDENCE.sha256',
].sort();

const lines = [
  '# AOA / SP 5.5.0 evidence manifest (machine-readable index: EVIDENCE-INDEX.md)',
  '# verify: cd docs/design/aoa-balance-mode && shasum -a 256 -c EVIDENCE.sha256',
  '# b-layer/F1-EVIDENCE.sha256 is the frozen F1 group (verify it separately inside b-layer/); its members are not listed here.',
  ...files.map((p) => `${sha(p)}  ${p}`),
];
writeFileSync(join(BASE, 'EVIDENCE.sha256'), lines.join('\n') + '\n');
console.log(`EVIDENCE.sha256: ${files.length} files`);

const idxPath = join(BASE, 'EVIDENCE-INDEX.md');
if (existsSync(idxPath)) {
  let idx = readFileSync(idxPath, 'utf8');
  let n = 0;
  idx = idx.replace(/sha256\(([^)\s]+)\)=(?:[0-9a-f]{64}|TBD)/g, (_, p) => {
    if (!existsSync(join(BASE, p))) throw new Error(`index cites a missing file: ${p}`);
    n++;
    return `sha256(${p})=${sha(p)}`;
  });
  writeFileSync(idxPath, idx);
  console.log(`EVIDENCE-INDEX.md: ${n} sha256 cells filled`);
}
