// Synthetic offline archive: exercises acceptance, never claims chain authenticity.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { repairFixture } from './repair-fixture.mjs';
import { armOrder } from './formal.mjs';
import { armCounts } from './evidence.mjs';
export function formalWindowFixture(dir) {
  const source=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/n50-mechanism.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse);
  const start=source[0], end=source.at(-1), attempts=[];
  let balance=start.passport.volatile.operatorBalance;
  for(let t=0;t<50;t++) for(const arm of armOrder(t)) {
    const a=source.slice(1+t*3,4+t*3).find(a=>a.arm===arm);
    for(const side of ['before','after']) for(const e of ['A','B']) if(arm!=='SP') a.readbacks[side][e].operatorBalance=balance;
    if(arm==='SP') balance=a.readbacks.after.A.operatorBalance;
    attempts.push(a);
  }
  for(const p of [start.passport,end.passport]) {
    p.chainId=11155111;p.allowSameEndpointLocal=false;
    for(const stake of Object.values(p.invariant.stakes)) Object.assign(stake,{staked:true,stake:'1000000000000000000',unstakeDelaySec:'86400'});
  }
  start.passport.block.number='99';start.passport.block.hash='0x'+(99).toString(16).padStart(64,'0');
  end.passport.block.number='400';end.passport.block.hash='0x'+(400).toString(16).padStart(64,'0');
  const f=repairFixture(dir,150,{formalSource:[start,...attempts,end]});
  Object.assign(f.start,{...start,...f.start,schema:'a6-gauge/2',rehearsal:false,rpcA:'https://a.example',rpcB:'https://b.example',allowSameEndpointLocal:false,protocolConformant:true});
  for(const a of f.attempts) Object.assign(a,{schema:'a6-gauge/2',runId:start.runId});
  const triplets=Array.from({length:50},(_,t)=>({tripletIndex:t,armOrder:armOrder(t),matched:true,attempts:[t*3,t*3+1,t*3+2]}));
  const journal=[f.start,...f.attempts,{...end,schema:'a6-gauge/2',rehearsal:false,passport:f.endPassport,triplets}];
  const triples=triplets.map(t=>({tripleIndex:t.tripletIndex,included:true,attempts:t.attempts}));
  const trailer={schemaVersion:'a6-evidence-trailer/1',windowId:'w',rehearsal:false,void:false,stopReason:'COMPLETE',stopAttempt:149,finalBlockCheck:f.finalBlockCheck,endPassport:f.endPassportRef,triples,replacements:[],counts:armCounts(f.rows,triples,[])};
  writeFileSync(join(dir,'index.ndjson'),f.rows.map(JSON.stringify).join('\n')+'\n');
  writeFileSync(join(dir,'trailer.json'),JSON.stringify(trailer));
  return journal;
}
