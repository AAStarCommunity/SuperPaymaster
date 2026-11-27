import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { toFunctionSelector, toHex } from 'viem';
import { sha256, stringify } from './evidence.mjs';
import { formalWindowFixture } from './formal-window-fixture.mjs';
import { parse, createFrozenPlan } from './frozen-plan.mjs';
import { sentWindowFixture } from './sent-window-fixture.mjs';
import { validateRun } from './validate.mjs';

const lc = x => String(x).toLowerCase();
const GET_DEPOSIT_INFO = toFunctionSelector('getDepositInfo(address)');
const planOf = (bundle, addr) => bundle.plans[Object.keys(bundle.plans).find(k => lc(k) === lc(addr))];

function snapshot(dir) {
  const saved = new Map();
  const walk = cur => {
    for (const entry of readdirSync(cur, { withFileTypes: true })) {
      const p = join(cur, entry.name);
      if (entry.isDirectory()) walk(p);
      else saved.set(p, readFileSync(p));
    }
  };
  walk(dir);
  return () => { for (const [p, bytes] of saved) writeFileSync(p, bytes); };
}

function applyPlanMutation(f, mutateBundle, mutateStakes) {
  const bundlePath = join(f.dir, 'bundle.json');
  const bundle = parse(readFileSync(bundlePath));
  mutateBundle(bundle);
  const bundleBytes = Buffer.from(stringify(bundle));
  const bundleSha256 = sha256(bundleBytes);
  writeFileSync(bundlePath, bundleBytes);

  const manifestPath = join(f.dir, 'manifest.json');
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  manifest.bundleSha256 = bundleSha256;
  const digests = {};
  for (const account of Object.keys(manifest.plan_sha256)) {
    const d = createFrozenPlan({ readBundle: () => bundleBytes, bundleSha256, account }).digest;
    digests[lc(account)] = d;
    manifest.plan_sha256[account] = d;
  }
  writeFileSync(manifestPath, stringify(manifest) + '\n');

  const lines = readFileSync(f.runPath, 'utf8').trim().split('\n').map(JSON.parse);
  const updatePassport = p => { if (mutateStakes) mutateStakes(p); };
  for (const row of lines) {
    if (row.kind === 'attempt') {
      row.bundleSha256 = bundleSha256;
      row.planDigest = digests[lc(row.sender)];
    }
    if (row.passport) updatePassport(row.passport);
  }
  writeFileSync(f.runPath, lines.map(stringify).join('\n') + '\n');

  if (mutateStakes) {
    const sample = lines[0].passport.invariant;
    const armByPm = new Map([
      [lc(sample.code.superPaymasterProxy.address), 'SP'],
      [lc(sample.code.verifyingPaymaster.address), 'VPM'],
      [lc(sample.code.tokenPaymaster.address), 'TPM'],
    ]);
    const pDir = join(f.dir, 'passports');
    for (const file of readdirSync(pDir)) {
      const pPath = join(pDir, file);
      const p = JSON.parse(readFileSync(pPath, 'utf8'));
      updatePassport(p);
      writeFileSync(pPath, stringify(p) + '\n');
    }
    const targetStakes = lines[0].passport.invariant.stakes;
    for (const ep of ['A', 'B']) {
      const rDir = join(f.dir, 'raw', ep);
      for (const file of readdirSync(rDir)) {
        const rPath = join(rDir, file);
        const recs = readFileSync(rPath, 'utf8').trim().split('\n').map(JSON.parse);
        for (const rec of recs) {
          if (rec.method !== 'eth_call') continue;
          const data = rec.params?.[0]?.data ?? '';
          if (!data.startsWith(GET_DEPOSIT_INFO)) continue;
          const pm = '0x' + data.slice(-40).toLowerCase();
          const arm = armByPm.get(pm);
          if (!arm) continue;
          const resp = JSON.parse(Buffer.from(rec.response, 'base64').toString('utf8'));
          const words = resp.result.slice(2).match(/.{64}/g);
          words[2] = toHex(BigInt(targetStakes[arm].stake), { size: 32 }).slice(2);
          words[3] = toHex(BigInt(targetStakes[arm].unstakeDelaySec), { size: 32 }).slice(2);
          resp.result = '0x' + words.join('');
          rec.response = rec.responseBase64 = Buffer.from(JSON.stringify(resp)).toString('base64');
        }
        writeFileSync(rPath, recs.map(stringify).join('\n') + '\n');
      }
    }
  }
}

test('frozen window U-6 validates stakes against each sender plan and C16 steps', async t => {
  const dir = mkdtempSync(join(process.cwd(), '.u6-stake-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const f = { dir, ...await sentWindowFixture(dir) };
  const restore = snapshot(dir);
  const validate = () => validateRun(f.runPath, { frozenPlan: join(dir, 'bundle.json'), registered: f.registered });

  await t.test('accepts window when stakes equal non-1-ETH plan values and reordered C16 steps', () => {
    try {
      applyPlanMutation(f, bundle => {
        for (const plan of Object.values(bundle.plans)) {
          plan.deploymentContext.stakeWei = 500000000000000000n;
          plan.pin.stake = 100000000000000000n;
          plan.deploymentContext.stakeDelay = 43200;
        }
        const vpmIdx = bundle.steps.findIndex(s => s.id === '0/C16.vpm');
        const [vpm] = bundle.steps.splice(vpmIdx, 1);
        vpm.target.find(x => x.signature === 'getDepositInfo(address)').expected = [0, 1, 500000000000000000n, 43200, 0];
        bundle.steps.push(vpm);
        const tpmIdx = bundle.steps.findIndex(s => s.id === '0/C16.tpm');
        const [tpm] = bundle.steps.splice(tpmIdx, 1);
        tpm.target.find(x => x.signature === 'getDepositInfo(address)').expected = [0, 1, 700000000000000000n, 43200, 0];
        bundle.steps.unshift(tpm);
      }, p => {
        const expected = { SP: '600000000000000000', VPM: '500000000000000000', TPM: '700000000000000000' };
        for (const [arm, stake] of Object.entries(expected)) {
          Object.assign(p.invariant.stakes[arm], { stake, unstakeDelaySec: 43200 });
          Object.assign(p.volatile.depositInfo[arm], { stake, unstakeDelaySec: 43200 });
        }
      });
      const r = validate();
      assert.equal(r.validatorExit, 0, JSON.stringify(r));
      assert.equal(r.accepted, true, JSON.stringify(r));
      assert.deepEqual(r.errors, []);

      // Stake below non-1-ETH plan value in one sender's end passport is rejected.
      const endPath = join(dir, `passports/end-${f.accounts[1]}.json`);
      const pEnd = JSON.parse(readFileSync(endPath, 'utf8'));
      pEnd.invariant.stakes.VPM.stake = '499999999999999999';
      writeFileSync(endPath, stringify(pEnd) + '\n');
      const low = validate();
      assert.equal(low.validatorExit, 1, JSON.stringify(low));
      assert.match(low.errors.join('\n'), /arm VPM: paymaster stake below 500000000000000000 wei/);
    } finally { restore(); }
  });

  await t.test('rejects stakes or delays below any sender plan even when >= 1 ETH / 86400', () => {
    for (const [mutate, pattern] of [
      [b => { planOf(b, f.accounts[1]).pin.stake = 1n; }, /arm SP: paymaster stake below 1000000000000000001 wei/],
      [b => { planOf(b, f.accounts[2]).deploymentContext.stakeDelay = 86401; }, /arm SP: paymaster unstakeDelaySec below 86401/],
      [b => { b.steps.find(s => s.id === '0/C16.vpm').target.find(x => x.signature === 'getDepositInfo(address)').expected[2] = 1000000000000000001n; }, /arm VPM: paymaster stake below 1000000000000000001 wei/],
      [b => { b.steps.find(s => s.id === '0/C16.tpm').target.find(x => x.signature === 'getDepositInfo(address)').expected[3] = 86401; }, /arm TPM: paymaster unstakeDelaySec below 86401/],
    ]) {
      try {
        applyPlanMutation(f, mutate);
        const r = validate();
        assert.equal(r.validatorExit, 1, JSON.stringify(r));
        assert.equal(r.accepted, false);
        assert.match(r.errors.join('\n'), pattern);
      } finally { restore(); }
    }
  });

  await t.test('missing C16 step, target, expected field, or sender plan field produces validation error', () => {
    for (const [mutate, pattern] of [
      [b => { b.steps = b.steps.filter(s => s.id !== '0/C16.vpm'); }, /arm VPM: missing frozen stake plan/],
      [b => { b.steps.find(s => s.id === '0/C16.tpm').target = []; }, /arm TPM: missing frozen stake plan/],
      [b => { b.steps.find(s => s.id === '0/C16.vpm').target.find(x => x.signature === 'getDepositInfo(address)').expected.length = 3; }, /arm VPM: missing frozen stake plan/],
      [b => { delete planOf(b, f.accounts[1]).pin.stake; }, /arm SP: missing frozen stake plan/],
      [b => { delete planOf(b, f.accounts[2]).deploymentContext.stakeWei; }, /arm SP: missing frozen stake plan/],
    ]) {
      try {
        applyPlanMutation(f, mutate);
        const r = validate();
        assert.equal(r.validatorExit, 1, JSON.stringify(r));
        assert.equal(r.accepted, false);
        assert.match(r.errors.join('\n'), pattern);
      } finally { restore(); }
    }
  });
});

test('non-window U-6 still requires 1 ETH stake and 86400 unstakeDelaySec', t => {
  const dir = mkdtempSync(join(process.cwd(), '.u6-nonwin-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const journal = formalWindowFixture(dir);
  const runPath = join(dir, 'run.jsonl');
  writeFileSync(runPath, journal.map(JSON.stringify).join('\n') + '\n');
  const ok = validateRun(runPath);
  assert.equal(ok.validatorExit, 0, JSON.stringify(ok));

  journal[0].passport.invariant.stakes.SP.stake = '999999999999999999';
  journal.at(-1).passport.invariant.stakes.VPM.unstakeDelaySec = '86399';
  writeFileSync(runPath, journal.map(JSON.stringify).join('\n') + '\n');
  const bad = validateRun(runPath);
  assert.equal(bad.validatorExit, 1, JSON.stringify(bad));
  assert.match(bad.errors.join('\n'), /arm SP: paymaster stake below 1000000000000000000 wei/);
  assert.match(bad.errors.join('\n'), /arm VPM: paymaster unstakeDelaySec below 86400/);
});
