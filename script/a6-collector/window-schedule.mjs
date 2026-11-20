import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseAbi } from 'viem';
import { createFrozenPlan } from './frozen-plan.mjs';
const names={SP:'SP',VerifyingPaymaster:'VPM',TokenPaymaster:'TPM'};
export function generateSchedule(seed,accounts,chainId) {
  const chain={10:'op-mainnet',11155111:'sepolia'}[chainId];
  if(!chain || typeof seed!=='string' || !seed || accounts.length!==3 || new Set(accounts.map(a=>a.toLowerCase())).size!==3 || accounts.some(a=>!/^0x[0-9a-f]{40}$/i.test(a))) throw Error('SCHEDULE_INPUT');
  return JSON.parse(execFileSync('python3',['-B',fileURLToPath(new URL('./schedule.py',import.meta.url)),'--seed',seed,'--accounts',...accounts,'--chain',chain],{encoding:'utf8'}));
}
export function createWindow({readBundle,bundleSha256,seed,chainId,accounts}) {
  const schedule=generateSchedule(seed,accounts,chainId);
  const adapters=new Map(accounts.map(account=>[account,createFrozenPlan({readBundle,bundleSha256,account})]));
  for(const [account,a] of adapters) {
    if(a.plan.phaseC.addresses.S.toLowerCase()!==account.toLowerCase()) throw Error('PLAN_S_MISMATCH');
    if(a.plan.chainId!==chainId || (!Number.isInteger(a.plan.phaseC.attempts) || a.plan.phaseC.attempts<20)) throw Error('PLAN_WINDOW_BUDGET');
  }
  return {adapters,manifest:{schema:'rq3-window-v1',schedule,plan_sha256:Object.fromEntries([...adapters].map(([s,a])=>[s,a.digest])),bundleSha256,targetTriplets:50,slotCap:60,warmupAttempts:0,warmup:false}};
}
/** Fixed traversal: neither a row verdict nor the number of complete slots changes the schedule. */
export async function runSlots(schedule,attempt,complete) {
  const slots=[];let matched=0;const allocations=new Map();
  for(const slot of schedule.payload.slots) {
    const rows=[];
    for(const name of slot.order) {
      const arm=names[name],sender=slot.senders[name],key=sender+':'+arm,index=allocations.get(key)??0;
      allocations.set(key,index+1);
      try { rows.push(await attempt(slot,arm,sender,index)); }
      catch (error) {
        if(error.attemptRow) rows.push(error.attemptRow);
        slots.push({block_slot:slot.block_slot,pair_id:slot.pair_id,matched:false,attempts:rows.map(r=>r.attemptIndex)});
        error.windowProgress={slots,complete:matched};
        throw error;
      }
    }
    const ok=complete(rows);if(ok) matched++;
    slots.push({block_slot:slot.block_slot,pair_id:slot.pair_id,matched:ok,attempts:rows.map(r=>r.attemptIndex)});
  }
  return {slots,complete:matched};
}
const abi=parseAbi(['function operators(address) view returns (uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)',
  'function userOpState(address,address) view returns (uint48 lastTimestamp,bool isBlocked)']);
const encode=v=>JSON.stringify(v,(_,x)=>typeof x==='bigint'?x.toString():x);
/** Fresh A/B reads at every pin, including the pin immediately before submission. */
export async function waitForSlot({runtime,arm,operator,sender,paymaster,start,deadline,sleep=ms=>new Promise(r=>setTimeout(r,ms)),timeoutMs=180000}) {
  let first;const wallDeadline=Date.now()+timeoutMs;
  while(true) {
    const block=await runtime.refreshPin();first??=block;
    const values=await Promise.all([runtime.pubA,runtime.pubB].map(async client=>{
      const pinned=await client.getBlock({blockNumber:block.number});
      if(pinned.hash!==block.hash || pinned.timestamp!==block.timestamp) throw Error('SCHEDULE_RPC_DISAGREEMENT');
      if(arm!=='SP') return [0n,0n];
      const op=await client.readContract({address:paymaster,abi,functionName:'operators',args:[operator],blockNumber:block.number});
      const state=await client.readContract({address:paymaster,abi,functionName:'userOpState',args:[operator,sender],blockNumber:block.number});
      return [BigInt(op[5]),BigInt(state[0])];
    }));
    if(encode(values[0])!==encode(values[1])) throw Error('SCHEDULE_RPC_DISAGREEMENT');
    const [minTxInterval,lastTimestamp]=values[0],validAfter=lastTimestamp+minTxInterval;
    const wait={seconds:block.timestamp-first.timestamp,blocks:block.number-first.number,minTxInterval,lastTimestamp,validAfter,
      timestamp:block.timestamp,pin:{number:block.number,hash:block.hash},start,deadline};
    if(block.timestamp>deadline) return {allowed:false,reason:'slot_deadline_exceeded',wait};
    if(arm==='SP' && validAfter>deadline) return {allowed:false,reason:'sp_valid_after_exceeds_slot_deadline',wait};
    if(block.timestamp>=start && (arm!=='SP'||block.timestamp>=validAfter)) return {allowed:true,wait};
    if(Date.now()>=wallDeadline) throw Object.assign(Error('SCHEDULE_CLOCK_STALLED'),{wait});
    await sleep(250);
  }
}
