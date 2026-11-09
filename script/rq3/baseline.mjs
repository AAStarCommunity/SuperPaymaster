// Frozen sample build, not a compiler or deployment executor.
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { keccak256 } from 'viem';
export const BUILD_SHA256='e54501a6b56462767094e1830e5a76ea86bdd89ee84935b7e8f9b37c26606961';
const raw=readFileSync(new URL('../a6-collector/artifacts/TokenPaymaster.json',import.meta.url));
if(createHash('sha256').update(raw).digest('hex')!==BUILD_SHA256) throw Error('frozen TPM build hash mismatch');
const code=Buffer.from(JSON.parse(raw).bytecode.slice(2),'hex');

export function runtimeFor(immutables) {
  // This exact creation bytecode stores constructor addresses at 0x80/0xa0/0xc0/0xe0
  // (byte offsets 122-124, 252-255, 240-244, 245-250). Its straight-line return
  // block at 0xb77 copies runtime and patches those words before RETURN at 0xc1f.
  const memory=Buffer.alloc(65536), stack=[];
  const write=(offset,value)=>Buffer.from(value.toString(16).padStart(64,'0'),'hex').copy(memory,offset);
  for(const [i,name] of ['entryPoint','uniswap','token','wrappedNative'].entries()) {
    if(!/^0x[0-9a-fA-F]{40}$/.test(immutables?.[name])) throw Error('TPM immutable address required: '+name);
    write(0x80+i*32,BigInt(immutables[name]));
  }
  let pc=0xb77;
  while(pc<=0xc1f) {
    const op=code[pc++];
    if(op===0x5b) continue;
    if(op===0x5f) stack.push(0n);
    else if(op>=0x60 && op<=0x7f) {
      const n=op-0x5f; stack.push(BigInt('0x'+code.subarray(pc,pc+n).toString('hex'))); pc+=n;
    } else if(op>=0x80 && op<=0x8f) stack.push(stack[stack.length-(op-0x7f)]);
    else if(op===0x01) stack.push(stack.pop()+stack.pop());
    else if(op===0x51) {const offset=Number(stack.pop());stack.push(BigInt('0x'+memory.subarray(offset,offset+32).toString('hex')));}
    else if(op===0x52) {const offset=Number(stack.pop());write(offset,stack.pop());}
    else if(op===0x39) {const dest=Number(stack.pop()), source=Number(stack.pop()), size=Number(stack.pop());code.copy(memory,dest,source,source+size);}
    else if(op===0xf3) {const offset=Number(stack.pop()), size=Number(stack.pop());return '0x'+memory.subarray(offset,offset+size).toString('hex');}
    else throw Error('unexpected frozen TPM return opcode');
  }
  throw Error('missing frozen TPM return');
}
export function baselineFor(immutables) {
  return {frozen_build_sha256:BUILD_SHA256, immutables,
    tpm_runtime_codehash:keccak256(runtimeFor(immutables))};
}
