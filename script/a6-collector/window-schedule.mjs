import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { parseAbi } from 'viem';
import { createFrozenPlan } from './frozen-plan.mjs';
const names={SP:'SP',VerifyingPaymaster:'VPM',TokenPaymaster:'TPM'};
export function generateSchedule(seed,accounts,chainId) {
  const chain={10:'op-mainnet',11155420:'op-sepolia',11155111:'sepolia'}[chainId];
  if(!chain || typeof seed!=='string' || !seed || accounts.length!==3 || new Set(accounts.map(a=>a.toLowerCase())).size!==3 || accounts.some(a=>!/^0x[0-9a-f]{40}$/i.test(a))) throw Error('SCHEDULE_INPUT');
  return JSON.parse(execFileSync('python3',['-I','-B',fileURLToPath(new URL('./schedule.py',import.meta.url)),'--seed',seed,'--accounts',...accounts,'--chain',chain],{encoding:'utf8'}));
}
export const TARGET_TRIPLETS=50, SLOT_CAP=60, WINDOW_SLOTS=20, WINDOWS=3;
export const STOPPING_RULE='pre-registered: attempt every slot of the slice in schedule order without optional stopping; EXHAUSTED after the last slot; STOPPED on a fail-closed stop; never extend';
export function createWindow({readBundle,bundleSha256,seed,chainId,accounts,windowIndex}) {
  if(!Number.isInteger(windowIndex) || windowIndex<1 || windowIndex>WINDOWS) throw Error('WINDOW_INDEX');
  const firstSlot=(windowIndex-1)*WINDOW_SLOTS;
  const slice={windowIndex,firstSlot,lastSlot:firstSlot+WINDOW_SLOTS-1,slots:WINDOW_SLOTS};
  const schedule=generateSchedule(seed,accounts,chainId);
  const adapters=new Map(accounts.map(account=>[account,createFrozenPlan({readBundle,bundleSha256,account})]));
  for(const [account,a] of adapters) {
    if(a.plan.phaseC.addresses.S.toLowerCase()!==account.toLowerCase()) throw Error('PLAN_S_MISMATCH');
    if(a.plan.chainId!==chainId || (!Number.isInteger(a.plan.phaseC.attempts) || a.plan.phaseC.attempts<SLOT_CAP/accounts.length)) throw Error('PLAN_WINDOW_BUDGET');
  }
  return {adapters,manifest:{schema:'rq3-window-v1',pythonVersion:execFileSync('python3',['-I','-B','-c','import sys; print(sys.version)'],{encoding:'utf8'}).trim(),schedule,slice,plan_sha256:Object.fromEntries([...adapters].map(([s,a])=>[s,a.digest])),bundleSha256,targetTriplets:TARGET_TRIPLETS,slotCap:SLOT_CAP,stoppingRule:STOPPING_RULE,warmupAttempts:0,warmup:false}};
}
/** Traverse the slice in schedule order, using allocation indexes from the full schedule. */
export async function runSlots({schedule,slice},attempt,complete) {
  const all=schedule.payload.slots;
  if(all.length!==SLOT_CAP || all.some((slot,i)=>slot.block_slot!==i)) throw Error('SLOT_CAP');
  const scheduled=all.slice(slice.firstSlot,slice.lastSlot+1);
  const slots=[];let matched=0;
  const allocations=new Map();
  for(const slot of all.slice(0,slice.firstSlot)) {
    for(const name of slot.order) {
      const key=slot.senders[name]+':'+names[name];
      allocations.set(key,(allocations.get(key)??0)+1);
    }
  }
  for(const slot of scheduled) {
    const rows=[];
    let ok;
    try {
      for(const name of slot.order) {
        const arm=names[name],sender=slot.senders[name],key=sender+':'+arm,index=allocations.get(key)??0;
        allocations.set(key,index+1);
        rows.push(await attempt(slot,arm,sender,index));
      }
      ok=complete(rows);
    } catch (error) {
      if(error.attemptRow) rows.push(error.attemptRow);
      slots.push({block_slot:slot.block_slot,pair_id:slot.pair_id,matched:false,attempts:rows.map(r=>r.attemptIndex)});
      error.windowProgress={slots,complete:matched,status:'STOPPED',unusedSlots:scheduled.slice(slots.length).map(s=>s.block_slot)};
      throw error;
    }
    if(ok) matched++;
    slots.push({block_slot:slot.block_slot,pair_id:slot.pair_id,matched:ok,attempts:rows.map(r=>r.attemptIndex)});
  }
  return {slots,complete:matched,status:'EXHAUSTED',unusedSlots:[]};
}
/** Window outcome for the run_end line and trailer; unreached slots are listed, never dropped. */
export function windowRecord({schedule,slice},progress=null) {
  const {windowIndex,firstSlot,lastSlot,slots:scheduledSlots}=slice;
  return {schedule_sha256:schedule.sha256,stoppingRule:STOPPING_RULE,status:progress?.status??'STOPPED',targetTriplets:TARGET_TRIPLETS,slotCap:SLOT_CAP,
    windowIndex,firstSlot,lastSlot,scheduledSlots,usedSlots:progress?.slots.length??0,completeTriplets:progress?.complete??0,
    unusedSlots:progress?.unusedSlots??schedule.payload.slots.slice(firstSlot,lastSlot+1).map(slot=>slot.block_slot)};
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
