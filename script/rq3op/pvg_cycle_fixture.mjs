// REHEARSAL: build the offline PVG 2-cycle fixture (a6-collector/pvg-cycle-fixture.json) from a fork-verify run.
// Usage: node script/rq3op/pvg_cycle_fixture.mjs <fork-verify dir with trailing slash>. Fork-only owner keys are public test scalars.
import { readFileSync, writeFileSync } from 'node:fs';
import { concat, pad, toHex, keccak256, getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { localUserOpHash } from '../a6-collector/gauge-lib.mjs';
import { finalizePVG, measurePVG } from '../a6-collector/pvg.mjs';
const R=process.argv[2];
const bundle=JSON.parse(readFileSync(R+'rq3-three-arm.verify.json'));
const meas=JSON.parse(readFileSync(R+'measurements.verify.json'));
const keys=Object.keys(bundle.plans);
const u128=v=>pad(toHex(v),{size:16});
const EP='0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const cases=[];
for (const row of meas.ops.ops.filter(o=>o.pvgNote)) {
  const si=keys.findIndex(k=>k.toLowerCase()===row.sender.toLowerCase());
  const plan=bundle.plans[keys[si]], pc=plan.phaseC;
  if (row.arm!=='TPM') continue; // VPM needs the on-chain getHash; keep the offline fixture to TPM (account signature only)
  const ownerKey=keccak256(toHex(`rq3-calib/fork-only/owner-${si}`));
  const owner=privateKeyToAccount(ownerKey);
  const L=row.limits;
  const base={sender:getAddress(row.sender),nonce:BigInt(row.nonce),initCode:'0x',callData:pc.taskCallData,
    accountGasLimits:concat([u128(BigInt(L.verification)),u128(BigInt(L.call))]),
    gasFees:concat([u128(BigInt(pc.priorityCap)),u128(BigInt(pc.feeCap))]),
    paymasterAndData:concat([getAddress(pc.addresses.TPM),u128(BigInt(L.paymasterVerification)),u128(BigInt(L.postOp))])};
  const bundler=getAddress(plan.externalInputs.data.phaseC.bundler);
  const sign=async value=>{const packed={...base,preVerificationGas:value,signature:'0x'};
    const h=localUserOpHash(packed,EP,11155111n); packed.signature=await owner.signMessage({message:{raw:h}}); return {packed,hash:h};};
  const top=await sign(row.pvgNote.sequence.map(BigInt).reduce((x,y)=>x>y?x:y));
  const fixture={source:`fork-verify ${row.arm} sender ${row.sender} round ${row.round} tx ${row.tx.hash}`,
    recordedUserOpHash:row.userOpHash, reconstructedUserOpHash:top.hash, chainId:11155111, entryPoint:EP, beneficiary:bundler,
    forkOnlyOwnerKeyLabel:`rq3-calib/fork-only/owner-${si}`, op:Object.fromEntries(Object.entries(base).map(([k,v])=>[k,typeof v==='bigint'?String(v):v])),
    lengths:pc.pvgLengths.TPM, reserve:String(pc.pvgReserve.TPM), recordedSequence:row.pvgNote.sequence};
  let err=null; try{await finalizePVG(sign,bundler,{lengths:pc.pvgLengths.TPM,reserve:pc.pvgReserve.TPM});}catch(e){err=e.message}
  fixture.currentResult=err;
  // which bytes oscillate: signature zero bytes at each sequence value
  fixture.iterations=[];
  for (const v of [...new Set(row.pvgNote.sequence)].map(BigInt)) { const r=await sign(v); const m=measurePVG(r.packed,bundler);
    const sig=Buffer.from(r.packed.signature.slice(2),'hex'); fixture.iterations.push({signedAt:String(v),ruleValue:String(m.value),
      signatureZeroBytes:[...sig].map((b,i)=>b===0?i:-1).filter(i=>i>=0), pvgWord:toHex(v,{size:32}), signature:r.packed.signature}); }
  cases.push(fixture);
}
console.log(JSON.stringify(cases.map(c=>({src:c.source,match:c.recordedUserOpHash===c.reconstructedUserOpHash,cur:c.currentResult,it:c.iterations.map(i=>[i.signedAt,i.ruleValue,i.signatureZeroBytes])})),null,1));
writeFileSync(new URL('../a6-collector/pvg-cycle-fixture.json',import.meta.url),JSON.stringify(cases,null,1)+'\n');
