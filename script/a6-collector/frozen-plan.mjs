import { feesWithinRule } from './fee-policy.mjs';
import { pvgRule, reservePVG, nullPVGColumns } from './pvg.mjs';
import { createHash } from 'node:crypto';
import { parseAbi, keccak256, toHex } from 'viem';
import { settlementBranch, settlementSignatures } from '../rq3op/branch.mjs';
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
export const parse = bytes => JSON.parse(String(bytes), (_key,value,context) => typeof value === 'number' && !Number.isSafeInteger(value) ? BigInt(context.source) : value);
function canonical(value) {
  if (typeof value === 'bigint') return value.toString();
  if (Array.isArray(value)) return '['+value.map(canonical).join(',')+']';
  if (value && typeof value === 'object') return '{'+Object.keys(value).sort().map(k=>canonical(k)+':'+canonical(value[k])).join(',')+'}';
  return JSON.stringify(value).replace(/[\u007f-\uffff]/g,c=>'\\u'+c.charCodeAt(0).toString(16).padStart(4,'0'));
}
const need = (ok,code) => { if (!ok) throw Error(code); };
const same = (a,b) => String(a).toLowerCase()===String(b).toLowerCase();
const abi=parseAbi(['function operators(address) view returns (uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)','function gasParams() view returns (uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)',
 'function getDepositInfo(address) view returns (uint256 deposit,bool staked,uint112 stake,uint32 unstakeDelaySec,uint48 withdrawTime)']);
export function createFrozenPlan({readBundle,bundleSha256,account}) {
  const bytes=readBundle(); need(hash(bytes)===bundleSha256,'BUNDLE_DIGEST_MISMATCH');
  const bundle=parse(bytes), key=Object.keys(bundle.plans).find(k=>same(k,account));
  need(key,'PLAN_ACCOUNT_MISSING');
  const plan=bundle.plans[key], pc=plan.phaseC, digest=hash(canonical(plan));
  need(same(pc.addresses.S,key),'PLAN_S_MISMATCH');
  need(plan.schema==='rq3-deploylive-1' && plan.gasPolicy.frozen===true,'PLAN_SCHEMA');
  need(['balance','credit'].includes(pc.spBranch),'PLAN_BRANCH_MISSING');
  const fees={maxFeePerGas:BigInt(pc.feeCap),maxPriorityFeePerGas:BigInt(pc.priorityCap)};
  need(feesWithinRule(fees,pc.feeRule),'PLAN_FEE_CHANGED');
  const gas={},pmGas={};
  for(const arm of ['SP','VPM','TPM']) {
    const b=pc.bounds[arm];
    const source=pc.gasSources[arm].preVerification;
    const {reserve,fixedLengths,...rule}=source;
    need(b.preVerification===null && canonical(rule)===canonical(pvgRule),'PLAN_PVG_RULE');
    need(canonical(fixedLengths)===canonical(pc.pvgLengths[arm]) &&
      BigInt(reserve)===BigInt(pc.pvgReserve[arm]) && BigInt(reserve)===reservePVG(fixedLengths),'PLAN_PVG_RESERVE');
    gas[arm]={callGasLimit:BigInt(b.call),verificationGasLimit:BigInt(b.verification),preVerificationGas:0n,...fees};
    pmGas[arm]={ver:BigInt(b.paymasterVerification),post:BigInt(b.postOp)};
  }
  const frozen={gas,pmGas,fees,pvgRule,callData:pc.taskCallData};
  function verify() {
    need(hash(readBundle())===bundleSha256,'BUNDLE_DIGEST_MISMATCH');
    need(hash(canonical(plan))===digest,'PLAN_DIGEST_MISMATCH');
  }
  return {plan,digest,frozen,
    row(arm,tripletIndex) {
      need(Object.hasOwn(gas,arm) && Number.isInteger(tripletIndex) && tripletIndex>=0 && tripletIndex<pc.attempts,'PLAN_ALLOCATION');
      return {...nullPVGColumns(),planDigest:digest,bundleSha256,gasSources:pc.gasSources[arm],spPostOpRule:pc.spPostOpRule,feeRule:pc.feeRule,
        allocation:{S:key,arm,tripletIndex,attempts:pc.attempts}};
    },
    bind(config,cfg,baselines,bMax,maxAttempts) {
      need(BigInt(bMax)===1n && maxAttempts<=pc.attempts,'PLAN_ALLOCATION');
      need([pc.addresses.X,pc.addresses.Q,plan.addresses.aPNTs].every(token=>!same(pc.addresses.T,token)),'PLAN_TASK_TOKEN_COLLISION');
      const input=plan.externalInputs.data.phaseC;
      for(const [actual,expected] of [[config.sender,key],[config.operator,plan.deploymentContext.operator],
        [config.factory,plan.deploymentContext.accountFactory],[config.accounts.owner.address,input.accountOwner],
        [config.accounts.bundler.address,input.bundler],[config.accounts.verifyingSigner.address,input.verifyingSigner],
        [cfg.entryPoint,plan.addresses.entryPoint],[cfg.superPaymaster,pc.addresses.SP],
        [baselines.verifyingPaymaster.address,pc.addresses.VPM],[baselines.tokenPaymaster.address,pc.addresses.TPM],
        [baselines.tokenPaymaster.token,pc.addresses.Q],[config.task.token,pc.addresses.T],[config.task.recipient,pc.recipient]]) need(same(actual,expected),'PLAN_CONFIG_MISMATCH');
      need(BigInt(config.salt)===BigInt(input.salt) && config.chainId===plan.chainId,'PLAN_CONFIG_MISMATCH');
      config.fees=fees; config.feeRule=pc.feeRule; config.bundlerGasLimit=pc.bounds.SP.outer;
      return frozen;
    },
    async send(runtime,arm,args) {
      need(args.functionName==='handleOps' && Object.hasOwn(gas,arm),'PLAN_SETUP_REQUIRED');
      await this.beforeSend(runtime);
      return runtime.writeContract({...args,gas:BigInt(pc.bounds[arm].outer)});
    },
    async beforeSend(runtime) {
      verify();
      const block=await runtime.refreshPin();
      for(const client of [runtime.pubA,runtime.pubB]) {
        need(await client.getChainId()===plan.chainId,'PLAN_CHAIN_CHANGED');
        const pinned=await client.getBlock({blockNumber:block.number});
        need(pinned.hash===block.hash && pinned.baseFeePerGas===block.baseFeePerGas,'PLAN_BLOCK_CHANGED');
        need(feesWithinRule(fees,pc.feeRule,block.baseFeePerGas),'PLAN_FEE_CHANGED');
        const g=await client.readContract({address:pc.addresses.SP,abi,functionName:'gasParams',blockNumber:block.number});
        need(canonical(g)===canonical(pc.gasTuple),'PLAN_GAS_CHANGED');
        const operator=await client.readContract({address:pc.addresses.SP,abi,functionName:'operators',args:[plan.deploymentContext.operator],blockNumber:block.number});
        need(BigInt(operator[5])===BigInt(pc.minTxInterval),'PLAN_INTERVAL_CHANGED');
        const s=await client.readContract({address:plan.addresses.entryPoint,abi,functionName:'getDepositInfo',args:[pc.addresses.SP],blockNumber:block.number});
        const values=Array.isArray(s)?s:[s.deposit,s.staked,s.stake,s.unstakeDelaySec,s.withdrawTime];
        need(values[1]===true && BigInt(values[2])===BigInt(plan.pin.stake)+BigInt(plan.deploymentContext.stakeWei) && BigInt(values[3])===BigInt(plan.deploymentContext.stakeDelay) && BigInt(values[4])===0n,'PLAN_STAKE_CHANGED');
      }
      verify();
      return {number:block.number,hash:block.hash};
    }
  };
}
/** Shared receipt path: persist the observed branch and raw receipt even on refusal. */
export function persistSettlement(row,receipt,{arm,...context},persist) {
  row.receipt=receipt;
  try {
    row.spBranch=arm==='SP'?settlementBranch(receipt.logs,{...context,topics:Object.fromEntries(Object.entries(settlementSignatures).map(([k,v])=>[k,keccak256(toHex(v))]))}):null;
  } catch(error) {
    row.spBranch=error.branch;
    row.stoppedBy={reason:'SP_BRANCH_MISMATCH'};
    persist(row);
    throw Error('SP_BRANCH_MISMATCH');
  }
  persist(row);
}
