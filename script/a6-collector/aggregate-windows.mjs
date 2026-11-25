import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { validateRun } from './validate.mjs';
import { REGISTERED_WINDOW } from './window-schedule.mjs';

// Exact passport leaves permitted to change at a boundary. SP interval configuration is
// invariant. Per-sender SP timestamps, EntryPoint nonces and token balances are recorded
// in attempt evidence, not in the current passport format.
const BOUNDARY_MUTABLE_PATHS = [
  ['invariant','superPaymaster','cachedPrice','price'],
  ['volatile','cachedPriceUpdatedAt'],
  ['volatile','operatorBalance'],
  ['volatile','depositInfo','SP','deposit'],
  ['volatile','depositInfo','VPM','deposit'],
  ['volatile','depositInfo','TPM','deposit'],
];

function boundaryState(passport) {
  const state = structuredClone(passport);
  delete state.block;
  for (const path of BOUNDARY_MUTABLE_PATHS) {
    let parent = state;
    for (const key of path.slice(0,-1)) parent = parent?.[key];
    if (parent) delete parent[path.at(-1)];
  }
  return state;
}

function bracket(window) {
  const passports = Object.values(window.passports).flatMap(({start,end})=>[start,end]);
  passports.push(window.finalPassport);
  const blocks = passports.map(p=>BigInt(p.block.number));
  return {first:blocks.reduce((a,b)=>a<b?a:b),last:blocks.reduce((a,b)=>a>b?a:b)};
}

export function aggregateWindows(dirs, {frozenPlan, registered:registration} = {}) {
  const registered = {...REGISTERED_WINDOW,...registration};
  const {windows:windowCount,slotCap,targetTriplets} = registered;
  const errors = [];
  const invalid = () => ({outcome:'INVALID-INTERRUPTED', errors});
  if (!Number.isSafeInteger(windowCount) || windowCount < 1 || !Array.isArray(dirs)
      || dirs.length !== windowCount || dirs.some(dir=>typeof dir !== 'string' || !dir)) {
    errors.push(`requires ${windowCount} window directories`);
    return invalid();
  }
  if (!Number.isSafeInteger(targetTriplets) || targetTriplets < 1) {
    errors.push('invalid aggregate target');
    return invalid();
  }
  const reports = dirs.map(dir=>validateRun(resolve(dir,'run.jsonl'),{frozenPlan,registered}));
  for (const [i,report] of reports.entries()) if (!report.accepted || !report.window || report.stop !== 'EXHAUSTED') {
    errors.push(`${dirs[i]}: slice is not accepted: ${[...report.errors,report.missing,report.crash].filter(Boolean).join('; ') || report.stop}`);
  }
  if (errors.length) return invalid();
  const windows = reports.map(report=>report.window).sort((a,b)=>a.windowIndex-b.windowIndex);
  const first = windows[0];
  const ranges = windows.map(window=>window.windowIndex);
  if (new Set(ranges).size !== windowCount) errors.push('duplicate slice range');
  if (ranges.some((index,i)=>index !== i+1)) errors.push('missing registered slice range');
  if (windows.some(w=>typeof w.runId !== 'string' || !w.runId) || new Set(windows.map(w=>w.runId)).size !== windowCount) {
    errors.push('window runIds must be distinct and nonempty');
  }
  if (windows.some(w=>w.scheduleSha256 !== first.scheduleSha256 || w.bundleSha256 !== first.bundleSha256 ||
      !isDeepStrictEqual(w.planSha256,first.planSha256))) errors.push('schedule, bundle or plan digests differ across windows');
  if (windows.some(w=>w.chainId !== first.chainId || !isDeepStrictEqual(w.accounts,first.accounts))) {
    errors.push('chain or account identity differs across windows');
  }
  const slots = windows.flatMap(w=>w.slots);
  if (slots.length !== slotCap || slots.some((slot,i)=>slot !== i)) errors.push('global slot coverage mismatch');
  const allocations = windows.flatMap(w=>w.allocationKeys);
  if (new Set(allocations).size !== allocations.length) errors.push('repeated sender, arm and allocation index across windows');
  if (errors.length) return invalid();
  for (let i=1; i<windows.length; i++) {
    const prior = windows[i-1], next = windows[i];
    if (bracket(prior).last >= bracket(next).first) errors.push(`windows ${i} and ${i+1}: overlapping or reversed passport brackets`);
    for (const [sender,{end}] of Object.entries(prior.passports)) {
      const start = next.passports[sender]?.start;
      if (!start || !isDeepStrictEqual(boundaryState(end),boundaryState(start))) {
        errors.push(`windows ${i} and ${i+1}: boundary passport drift for ${sender}`);
      }
    }
    for (const [key,{first}] of Object.entries(next.nonceRanges)) {
      const previous = prior.nonceRanges[key];
      if (previous && BigInt(first) !== BigInt(previous.last)+1n) {
        errors.push(`windows ${i} and ${i+1}: nonce discontinuity for ${key}`);
      }
    }
  }
  if (errors.length) return invalid();
  const completeTriplets = reports.reduce((sum,report)=>sum+report.matchedTriplets,0);
  return {outcome:completeTriplets >= targetTriplets ? 'COMPLETE' : 'INCOMPLETE',completeTriplets,targetTriplets,errors};
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [, , ...args] = process.argv;
  const dirs = [], options = {};
  const names = {'--frozen-plan':'frozenPlan','--registered-seed':'seed','--registered-schedule-sha256':'scheduleSha256'};
  let invalidArgs = false;
  for (let i=0; i<args.length; i++) {
    const arg = args[i];
    if (!arg.startsWith('--')) dirs.push(arg);
    else if (!Object.hasOwn(names,arg) || Object.hasOwn(options,names[arg]) || !args[i+1] || args[i+1].startsWith('--')) {
      invalidArgs = true;
      break;
    } else options[names[arg]] = args[++i];
  }
  const {frozenPlan,seed,scheduleSha256} = options;
  const result = invalidArgs || !frozenPlan || !seed || !scheduleSha256
    ? {outcome:'INVALID-INTERRUPTED',errors:['usage: aggregate-windows.mjs <window-dir> <window-dir> <window-dir> --frozen-plan <bundle> --registered-seed <seed> --registered-schedule-sha256 <hex>']}
    : aggregateWindows(dirs,{frozenPlan,registered:{seed,scheduleSha256}});
  console.log(JSON.stringify(result,null,2));
  process.exitCode = {COMPLETE:0,INCOMPLETE:3,'INVALID-INTERRUPTED':1}[result.outcome];
}
