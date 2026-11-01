import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { EXCLUSION_REASONS, armCounts } from './evidence.mjs';
const equal = (a,b) => JSON.stringify(a) === JSON.stringify(b);
const schema = JSON.parse(readFileSync(new URL('./evidence-index.schema.json', import.meta.url)));
function conforms(v,s) {
  if (s.$ref) return conforms(v,schema.$defs[s.$ref.split('/').at(-1)]);
  if (s.allOf && !s.allOf.every(x=>conforms(v,x))) return false;
  if (s.if && conforms(v,s.if) && s.then && !conforms(v,s.then)) return false;
  if (s.not && conforms(v,s.not)) return false;
  if (s.anyOf && !s.anyOf.some(x=>conforms(v,x))) return false;
  if ('const' in s && v !== s.const) return false;
  if (s.enum && !s.enum.includes(v)) return false;
  if (s.type === 'null') return v === null;
  if (s.type === 'boolean') return typeof v === 'boolean';
  if (s.type === 'integer') return Number.isSafeInteger(v) && v >= (s.minimum ?? -Infinity);
  if (s.type === 'string') return typeof v === 'string' && v.length >= (s.minLength ?? 0) && (!s.pattern || new RegExp(s.pattern).test(v));
  if (s.type === 'array') return Array.isArray(v) && v.length >= (s.minItems ?? 0) && v.length <= (s.maxItems ?? Infinity) && (!s.uniqueItems || new Set(v.map(JSON.stringify)).size === v.length) && v.every(x=>conforms(x,s.items));
  if (s.type === 'object' && (!v || typeof v !== 'object' || Array.isArray(v))) return false;
  if (s.required && !s.required.every(k=>v != null && k in v)) return false;
  if (s.properties && v && typeof v === 'object') return Object.entries(v).every(([k,x])=>s.properties[k] ? conforms(x,s.properties[k]) : s.additionalProperties === false ? false : typeof s.additionalProperties === 'object' ? conforms(x,s.additionalProperties) : true);
  return true;
}
export function windowErrors(rows, trailer, journal = null) {
  const errors = [], fail = message => errors.push(message);
  if (!trailer) return ['missing trailer: interrupted window'];
  if (trailer.schemaVersion !== 'a6-evidence-trailer/1') fail('invalid trailer version');
  if (trailer.void !== false || trailer.stopReason !== 'COMPLETE') fail('void window / fail-closed stop');
  if (!trailer.endPassport?.path || !trailer.endPassport?.raw) fail('missing end Passport');
  if (trailer.stopAttempt !== (rows.at(-1)?.attempt ?? null)) fail('stop attempt mismatch');
  const groups = new Map();
  rows.forEach((r,i)=>{
    if (!conforms(r,schema)) fail(`attempt ${i}: index schema violation`);
    if (r.windowId !== trailer.windowId || r.attempt !== i) fail('attempt identity/order mismatch or missing attempt');
    if (r.replacedBy !== null) fail('replacedBy must be null');
    if (r.included !== false || r.passports.end !== null) fail('row contains final disposition or end Passport');
    if (!EXCLUSION_REASONS.includes(r.exclusionReason)) fail('exclusion enum violation');
    if (r.stopReason) { fail('fail-closed stopped attempt'); if (i !== rows.length-1) fail('replacement/attempt after fail-closed stop'); }
    if (!groups.has(r.tripleIndex)) groups.set(r.tripleIndex,[]);
    groups.get(r.tripleIndex).push(r);
  });
  if (!Array.isArray(trailer.triples) || !Array.isArray(trailer.replacements)) return [...errors,'missing trailer triples/replacements'];
  const triples = new Map();
  for (const t of trailer.triples) {
    if (triples.has(t.tripleIndex)) fail('duplicate trailer candidate');
    triples.set(t.tripleIndex,t);
    const rs = groups.get(t.tripleIndex);
    if (!rs || !equal(t.attempts,rs.map(r=>r.attempt))) fail('candidate attempts missing or not retained');
    if (typeof t.included !== 'boolean') fail('invalid inclusion');
    if (t.included && (!rs || rs.length !== 3 || new Set(rs.map(r=>r.arm)).size !== 3 || rs.some(r=>r.verdict !== 'USEROP_SUCCESS' || r.stopReason || Object.entries(r.missing).some(([p,why])=>p !== '/passports/end' && !why.startsWith('not applicable'))))) fail('included candidate lacks three successful complete attempts');
  }
  if (triples.size !== groups.size) fail('trailer candidate coverage mismatch');
  const forward = new Map(), backward = new Map();
  const id = link => link && link.windowId === trailer.windowId && Number.isSafeInteger(link.tripleIndex) ? link.tripleIndex : null;
  for (const edge of trailer.replacements) {
    const a=id(edge.abandoned), b=id(edge.replacement);
    if (!EXCLUSION_REASONS.includes(edge.reason)) fail('abandonment enum violation');
    if (a === null || b === null || !groups.has(a) || !groups.has(b)) { fail('replacement references absent candidate'); continue; }
    if (forward.has(a) || backward.has(b)) fail('replacement must be one-to-one');
    forward.set(a,b); backward.set(b,a);
    if (triples.get(a)?.included !== false || groups.get(a).some(r=>r.included !== false)) fail('abandoned candidate included');
    if (Math.max(...groups.get(a).map(r=>r.attempt)) >= Math.min(...groups.get(b).map(r=>r.attempt))) fail('replacement precedes abandonment');
    if (groups.get(a).some(r=>r.stopReason)) fail('replacement after fail-closed stop');
    if (!groups.get(a).some(r=>r.exclusionReason === edge.reason)) fail('replacement reason disagrees with abandoned evidence');
  }
  for (const a of forward.keys()) {
    const seen = new Set(); let n=a;
    while (forward.has(n)) { if (seen.has(n)) { fail('replacement cycle'); break; } seen.add(n); n=forward.get(n); }
  }
  for (const [candidate,rs] of groups) for (const r of rs) {
    const expected=backward.has(candidate) ? {windowId:trailer.windowId,tripleIndex:backward.get(candidate)} : null;
    if (!equal(r.replaces,expected)) fail('replacement inverse mismatch');
  }
  const included=trailer.triples.filter(t=>t.included);
  if (included.length !== 50 || included.reduce((n,t)=>n+t.attempts.length,0) !== 150) fail('requires exactly 50 included triples / 150 included attempts');
  if (!equal(trailer.counts,armCounts(rows,trailer.triples))) fail('per-arm counts mismatch');
  if (journal) {
    const attempts=journal.filter(r=>r.kind==='attempt'), end=journal.at(-1);
    if (attempts.length !== rows.length) fail('index does not retain every journal attempt');
    for (let i=0;i<attempts.length;i++) {
      const a=attempts[i], r=rows[i];
      if (!r || a.attemptIndex !== r.attempt || a.tripletIndex !== r.tripleIndex || a.arm !== r.arm || a.verdict !== r.verdict || (a.stoppedBy?.reason ?? null) !== r.stopReason) fail('index/journal attempt mismatch');
    }
    if (end.kind !== 'run_end' || end.stop?.reason !== trailer.stopReason || (end.stop?.code !== 0) !== trailer.void) fail('trailer/journal stop mismatch');
    for (const t of trailer.triples) if (t.included !== (end.stop?.code === 0 && end.triplets?.some(x=>x.tripletIndex === t.tripleIndex && x.matched))) fail('trailer/journal matching mismatch');
  }
  return errors;
}
export function validateWindow(window, journal) {
  let rows;
  try { rows=readFileSync(resolve(window,'index.ndjson'),'utf8').trim().split('\n').filter(Boolean).map(JSON.parse); } catch { return ['missing or invalid index: interrupted window']; }
  let trailer;
  try { trailer=JSON.parse(readFileSync(resolve(window,'trailer.json'),'utf8')); } catch { return ['missing or invalid trailer: interrupted window']; }
  const errors = windowErrors(rows,trailer,journal);
  if (journal && trailer.endPassport?.path) {
    const path = resolve(window,trailer.endPassport.path);
    if (!path.startsWith(resolve(window) + '/')) errors.push('end Passport escapes window');
    else try {
      if (!equal(JSON.parse(readFileSync(path,'utf8')),journal.at(-1)?.passport)) errors.push('trailer end Passport differs from journal');
    } catch { errors.push('trailer end Passport unavailable'); }
  }
  return errors;
}
