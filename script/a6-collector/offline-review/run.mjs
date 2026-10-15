// Complete offline review; each child exits before the next starts. No chain is required.
import { spawnSync } from 'node:child_process';
for (const name of ['check.mjs','check-library.mjs','check-round2.mjs','check-round3.mjs','check-round4.mjs','check-shared-balance.mjs','check-round5.mjs','check-receipt-attribution.mjs','check-review.mjs','check-followups.mjs']) {
  const r=spawnSync(process.execPath,[`script/a6-collector/offline-review/${name}`],{stdio:'inherit'});
  if(r.error) throw r.error;
  if(r.status!==0) process.exit(r.status ?? 1);
}
