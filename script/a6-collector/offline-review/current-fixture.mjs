import { syntheticSummary } from './synthetic-summary.mjs';
// Historical controls keep their original inputs for the frozen validators. For
// current-validator runs, give an otherwise unchanged synthetic end envelope a
// distinct later block. Never use this helper on collected archive evidence.
import { readFileSync, writeFileSync } from 'node:fs';
import { keccak256, toBytes } from 'viem';
export function freshEnd(a) {
  const e=a.at(-1).passport, r=a.at(-2);
  e.block.number=String(BigInt(r.tx.blockNumber)+1n);
  e.block.hash=keccak256(toBytes(`synthetic round5 end ${r.tx.blockHash}`));
  return a;
}
// Historical appended accounting probes used COMPLETE after reaching count=1.
// Model those extra attempts under an unfinished target for current accounting checks;
// check-followups separately rejects the original post-target COMPLETE claim.
export function unfinishedTarget(a) {
  a[0].count = 2;
  a.at(-1).targetTriplets = 2;
  a.at(-1).exitCode = 10;
  a.at(-1).stop = { reason: 'MAX_ATTEMPTS', code: 10 };
  a[0].protocolConformant = false;
  return a;
}
export function currentFixture(file) {
  if (!file.startsWith('script/a6-collector/offline-review/fixtures/')) return file;
  const a=readFileSync(file,'utf8').trim().split('\n').map(JSON.parse);
  const e=a.at(-1).passport, r=a.at(-2);
  if(e?.block.hash===r.tx?.blockHash && e.block.number===r.tx.blockNumber) freshEnd(a);
  if (file.includes('/r2-postop-')) unfinishedTarget(a);
  syntheticSummary(a);
  const path=file.replace(/\.jsonl$/, '-current.jsonl');
  writeFileSync(path,a.map(JSON.stringify).join('\n')+'\n');
  return path;
}
