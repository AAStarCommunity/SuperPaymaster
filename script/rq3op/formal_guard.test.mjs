import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
// The guard is dependency-free; evaluate its actual source without requiring viem installation.
const source=readFileSync(new URL('../a6-collector/formal.mjs',import.meta.url),'utf8');
const part=source.slice(source.indexOf('const STATE_TAG'),source.indexOf('export function archivedRpc')).replaceAll('export ','');
const guard=vm.runInNewContext(part+';guardRequest');
test('setup opt-in permits archived pending nonce read',()=>assert.doesNotThrow(()=>guard('eth_getTransactionCount',['0x'+'11'.repeat(20),'pending'],{pendingNonce:true})));
test('ordinary formal reads retain fixed-block rule',()=>assert.throws(()=>guard('eth_getTransactionCount',['0x'+'11'.repeat(20),'pending'])));
test('opt-in cannot permit other pending or dev reads',()=>{assert.throws(()=>guard('eth_call',[{},'pending'],{pendingNonce:true}));assert.throws(()=>guard('anvil_setBalance',[],{pendingNonce:true}));});
