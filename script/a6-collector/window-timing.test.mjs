import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, realpathSync, rmSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const SCRIPT = 'script/a6-collector/window-timing.mjs';
const run = args => spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8' });
const full = out => ['--frozen-plan', '/missing', '--bundle-sha256', 'a'.repeat(64), '--seed', 's', '--formal-config', '/missing', '--config', '/missing',
  '--baselines', '/missing', '--rpc-a-file', '/missing', '--rpc-b-file', '/missing', '--out-dir', out];

test('timing probe refuses missing arguments and an existing output directory before reading anything', () => {
  const r = run([]);
  assert.equal(r.status, 2); assert.match(r.stderr, /--frozen-plan is required/);
  const d = realpathSync(mkdtempSync('/tmp/timing-a6-'));
  try {
    const w = run(full(join(d, 'window')));
    assert.equal(w.status, 2); assert.match(w.stderr, /basename must start with timing-/);
    const e = run(full(d));
    assert.equal(e.status, 2); assert.match(e.stderr, /--out-dir must not exist/);
    assert.deepStrictEqual(readdirSync(d), []);
    const c = run([...full(join(d, 'timing-new')), '--cap-b', '0']);
    assert.equal(c.status, 2); assert.match(c.stderr, /--cap-b must be 1\.\.99/);
  } finally { rmSync(d, { recursive: true, force: true }); }
});
test('timing probe is read-only by construction: no signer, lock, keychain, signing or send path', () => {
  const src = readFileSync(SCRIPT, 'utf8');
  assert.match(src, /readOnly: true/);
  assert.match(src, /must hold no signer/);
  for (const forbidden of ['acquireBundlerLock', 'acquireLock', 'withPasswordSource', 'keystore', 'writeContract', 'sendRawTransaction', 'signTransaction', 'collector-locks'])
    assert.ok(!src.includes(forbidden), forbidden);
});

test('--trace-tx times only A and keeps both tracer request shapes', async () => {
  const {runInNewContext} = await import('node:vm');
  const source = readFileSync(SCRIPT,'utf8');
  const code = source.slice(source.indexOf('let tpmTraces = null;'),source.indexOf('const result = { schema:'));
  const calls = [], traceTx='0x'+'44'.repeat(32);
  await runInNewContext(`(async()=>{${code}})()`,{
    traceTx,performance,mark:()=>({}),pubA:{request:async request=>calls.push(request)},
    pubB:{request:async()=>assert.fail('traced on B')}
  });
  assert.deepEqual(JSON.parse(JSON.stringify(calls)),[
    {method:'debug_traceTransaction',params:[traceTx,{tracer:'callTracer',tracerConfig:{withLog:true}}]},
    {method:'debug_traceTransaction',params:[traceTx,{tracer:'prestateTracer',tracerConfig:{diffMode:true}}]}
  ]);
});
