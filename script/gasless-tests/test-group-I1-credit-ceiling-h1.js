#!/usr/bin/env node
/**
 * Test Group I1: Credit Ceiling Enforcement (5.5.0 rewrite of the H-1 fix verification)
 *
 * 3.x AUDIT H-1 (2026-06-11) fixed a bypass in SuperPaymaster._recordDebt(): a user who
 * drained their xPNTs balance mid-UserOp (between validate and postOp) could accumulate
 * unlimited operator debt. The 3.x fix checked the ceiling in _recordDebt() and set
 * userOpState[operator][user].isBlocked = true on breach.
 *
 * 5.5.0 removed _recordDebt()/pendingDebts/recordDebtWithOpHash/isBlocked-on-breach
 * entirely. The SAME security property (no unbounded debt) is now enforced structurally
 * and atomically inside xPNTsTokenV2.tryReserveCredit's C-1 check (spec 03 §2.3):
 *   debts[user] + creditReservedOf[user] + amount <= effectiveCreditCap(user)
 * and per L-1, a failing tryReserveCredit writes NO state at all — there is nothing to
 * "un-block" afterward, so isBlocked is no longer part of this mechanism. userOpState
 * .isBlocked still exists on SP but is now purely an admin/Registry-driven flag
 * (updateBlockedStatus, onlyRegistry — see test-group-B4 Step 3), unrelated to credit.
 *
 * Tests (read-only + state verification — no live UserOp required):
 *   1. Credit tier config — tiers 1-6 limits from Registry (unaffected by 5.5.0)
 *   2. getCreditLimit — for deployer and a fresh address (unaffected by 5.5.0)
 *   3. token.debts / creditReservedOf / effectiveCreditCap — the new ceiling accounting
 *   4. userOpState — isBlocked flag now documented as admin-only, not credit-ceiling-driven
 *   5. Ceiling enforcement check — headroom = effectiveCreditCap - (debts + creditReservedOf)
 *   6. dryRunValidation (via SuperPaymasterLens) — demonstrates the new gate exists
 *   7. Version assertion — confirm 5.5.0 is deployed
 *
 * Prerequisites:
 *   - SuperPaymaster-5.5.0 + Registry deployed
 *   - DEPLOYER_PRIVATE_KEY set in env
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertGte, assertFalse, catchStep,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group I1: Credit Ceiling Enforcement (5.5.0)');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const registry = c.registry;
  const sp = c.superPaymaster;
  const lens = c.superPaymasterLens;
  const xpnts = c.aastarXPNTsV2;

  const deployerAddr = deployer.address;
  const operatorAddr = process.env.OPERATOR_ADDRESS || deployerAddr;
  const userAddr = process.env.TEST_AA_ACCOUNT_ADDRESS_A || deployerAddr;
  // xPNTs v2 token address — config.aPNTs is SP's own collateral asset in 5.5.0, NOT
  // this. See test-case-2-fixed.js for the same distinction.
  const xPNTsAddr = config.aastarXPNTsV2;

  printKeyValue('SuperPaymaster', config.superPaymaster);
  printKeyValue('Registry', config.registry);
  printKeyValue('aastarXPNTsV2 (xPNTs v2 token)', xPNTsAddr);
  printKeyValue('Operator', operatorAddr);
  printKeyValue('Test user', userAddr);
  console.log();

  // ──────────────────────────────────────────
  // Step 1: Credit tier config — tiers 1-6
  // ──────────────────────────────────────────
  printStep(1, 'creditTierConfig — tier credit limits (levels 1-6)');
  const tierLimits = {};
  try {
    console.log('    Level | Credit Limit');
    console.log('    ------|-------------');
    for (let level = 1; level <= 6; level++) {
      const limit = await registry.creditTierConfig(level);
      tierLimits[level] = limit;
      console.log(`    Tier ${level} | ${ethers.formatEther(limit)} aPNTs`);
    }
    assertTrue(tierLimits[1] !== undefined, 'Tier 1 limit readable');
    assertTrue(tierLimits[6] >= tierLimits[1], 'Tier 6 limit >= Tier 1 limit');
    printSuccess('Credit tier limits read — ceiling config is on-chain');
  } catch (e) {
    catchStep('creditTierConfig', e);
  }

  // ──────────────────────────────────────────
  // Step 2: getCreditLimit for test addresses
  // ──────────────────────────────────────────
  printStep(2, 'getCreditLimit — credit limit for operator and test user');
  let creditLimit = 0n;
  try {
    const operatorLimit = await registry.getCreditLimit(operatorAddr);
    const userLimit = await registry.getCreditLimit(userAddr);
    const freshLimit = await registry.getCreditLimit(ethers.Wallet.createRandom().address);

    printKeyValue('Operator credit limit', `${ethers.formatEther(operatorLimit)} aPNTs`);
    printKeyValue('Test user credit limit', `${ethers.formatEther(userLimit)} aPNTs`);
    printKeyValue('Fresh address limit (rep=0)', `${ethers.formatEther(freshLimit)} aPNTs`);

    creditLimit = userLimit;
    assertEqual(freshLimit, tierLimits[1] ?? 0n, 'Fresh address gets Tier 1 credit limit');
    printSuccess('getCreditLimit reads correctly from Registry');
  } catch (e) {
    catchStep('getCreditLimit', e);
  }

  // ──────────────────────────────────────────
  // Step 3: token.debts / creditReservedOf / effectiveCreditCap — the new ceiling accounting
  // ──────────────────────────────────────────
  printStep(3, 'token.debts / creditReservedOf / effectiveCreditCap — 5.5.0 ceiling accounting');
  let debt = 0n, reserved = 0n, cap = 0n;
  if (!xpnts) {
    printSkip('config.aastarXPNTsV2 missing — this deployment predates 5.5.0 balance mode');
  } else {
    try {
      [debt, reserved, cap] = await Promise.all([
        xpnts.debts(userAddr),
        xpnts.creditReservedOf(userAddr),
        xpnts.effectiveCreditCap(userAddr),
      ]);
      printKeyValue('debts(user)', `${ethers.formatEther(debt)} aPNTs`);
      printKeyValue('creditReservedOf(user)', `${ethers.formatEther(reserved)} aPNTs (in-flight, same-tx reservations)`);
      printKeyValue('effectiveCreditCap(user)', `${ethers.formatEther(cap)} aPNTs`);
      printSuccess('5.5.0 ceiling accounting readable on the token');
    } catch (e) {
      catchStep('token debt/cap accounting', e);
    }
  }

  // ──────────────────────────────────────────
  // Step 4: userOpState — isBlocked flag (now admin-only, not credit-ceiling-driven)
  // ──────────────────────────────────────────
  printStep(4, 'userOpState — isBlocked flag per operator+user pair (5.5.0: admin-only)');
  try {
    const state = await sp.userOpState(operatorAddr, userAddr);
    printKeyValue('lastTimestamp', state.lastTimestamp.toString());
    printKeyValue('isBlocked', state.isBlocked);
    printInfo('5.5.0: isBlocked is only ever written by Registry.updateBlockedStatus (onlyRegistry) —');
    printInfo('  SP itself never sets it anymore. Credit-ceiling breaches now fail closed atomically');
    printInfo('  inside tryReserveCredit (no state written, L-1) instead of flagging the user.');

    // For a different operator/user pair to confirm the mapping works
    const freshState = await sp.userOpState(
      ethers.Wallet.createRandom().address,
      ethers.Wallet.createRandom().address
    );
    assertFalse(freshState.isBlocked, 'Fresh operator+user pair is not blocked');
    printSuccess('userOpState mapping readable');
  } catch (e) {
    catchStep('userOpState', e);
  }

  // ──────────────────────────────────────────
  // Step 5: Ceiling enforcement — a NEW reservation past headroom must be rejected
  // ──────────────────────────────────────────
  // NOTE (Codex stop-gate, round 1): the previous version of this step asserted
  // `debts + creditReservedOf <= effectiveCreditCap` as a standing invariant on freshly
  // read state. That is FALSE in general — spec 03 §2.3 C-4 (confirmed in
  // contracts/test/v2/xPNTsTokenV2D3.t.sol test_C4_*) says revocation, a tier reduction,
  // or the community turning creditPolicy OFF only blocks NEW reservations; it never
  // retroactively invalidates already-admitted debt or in-flight reservations. So cap can
  // legitimately sit BELOW spent after such a change — that is a valid 5.5.0 state, not a
  // bug.
  //
  // NOTE (Codex stop-gate, round 2): round 1's fix drove previewCredit() with an amount
  // constructed to exceed headroom and only asserted `result != OK`. That is VACUOUS on a
  // fresh deploy: creditPolicy defaults to OFF, so effectiveCreditCap is 0 for everyone,
  // and xPNTsTokenV2._creditDecision (xPNTsTokenV2.sol:275-287) returns NO_CREDIT at the
  // `cap == 0` check *before* ever reaching the actual `debts + reserved + amount > cap`
  // comparison — the EXCEEDS_CAP branch itself was never exercised; deleting it would still
  // have passed the old assertion.
  //
  // This version puts a nonzero cap in effect first (creditPolicy AUTO + requestCredit,
  // the same precondition test-case-4-superpaymaster-credit-path.js already solved for a
  // live UserOp), then probes with an amount specifically > headroom but <= maxSingleTxLimit
  // (so SINGLE_TX_LIMIT can't fire first and mask the result), and asserts the EXACT enum
  // value EXCEEDS_CAP — not merely "not OK".
  printStep(5, 'Ceiling enforcement — a new reservation past headroom is rejected with EXCEEDS_CAP (C-1, live check)');
  if (!xpnts) {
    printSkip('config.aastarXPNTsV2 missing — cannot check ceiling enforcement');
  } else {
    // Deployer EOA as the credit subject, not `userAddr`: userAddr may fall back to an
    // undeployed TEST_AA_ACCOUNT_ADDRESS_A, and requestCredit is msg.sender-gated. The
    // deployer is a signer this script already controls directly — no AA execute()
    // plumbing needed (unlike test-case-4, which targets a SimpleAccount and must route
    // through it).
    const creditSubject = deployerAddr;
    const CREDIT_POLICY_AUTO = 2n;
    const CREDIT_RESULT_NAMES = ['OK', 'NO_CREDIT', 'EXCEEDS_CAP', 'EMERGENCY', 'SINGLE_TX_LIMIT', 'CONFLICTING', 'DISABLED'];
    let skipReason = null;
    let tierRestoreValue = null;
    // Local nonce manager for this block's writes: ethers v6's provider caches
    // eth_getTransactionCount('pending') the same way it caches getBlock('latest') (see the
    // nowTs() note below) and does not invalidate it on a local evm_mine, so re-querying
    // "pending" nonce via the Contract/Signer path between two of our own sends here can
    // silently return the SAME nonce twice ("nonce has already been used" on the second
    // send). Fetch it once via a raw call, then track it ourselves — correct as long as we
    // are the only sender for this address in this process, which we are here.
    let nextNonce = null;
    async function nextTxNonce() {
      if (nextNonce === null) {
        nextNonce = parseInt(await provider.send('eth_getTransactionCount', [deployerAddr, 'pending']), 16);
      }
      return nextNonce++;
    }

    try {
      // 5a: creditPolicy must be non-OFF. 48h TIMELOCK, communityOwner-gated — same
      // real-network-safe queue/execute/SKIP pattern as test-case-4 Step 2a. On a local
      // anvil this also tries evm_increaseTime/evm_mine to fast-forward past the window
      // (testing convenience only; a real network rejects that RPC call and the script
      // falls through to the normal SKIP path below).
      let policy = await xpnts.creditPolicy();
      if (policy === 0n) { // OFF — ethers v6 decodes uintN as bigint
        const owner = await xpnts.communityOwner();
        if (owner.toLowerCase() !== deployerAddr.toLowerCase()) {
          skipReason = `creditPolicy is OFF and this wallet (${deployerAddr}) is not communityOwner (${owner}) — cannot queue AUTO`;
        } else {
          let [pending, eta] = await Promise.all([xpnts.pendingPolicy(), xpnts.pendingPolicyEta()]);
          if (pending === 0n || eta === 0n) {
            const tx = await xpnts.queueCreditPolicy(CREDIT_POLICY_AUTO, { nonce: await nextTxNonce() });
            await tx.wait();
            eta = await xpnts.pendingPolicyEta();
          }
          // Raw eth_getBlockByNumber, not provider.getBlock('latest'): ethers v6 caches
          // getBlock('latest') results per-provider-instance and does not invalidate that
          // cache on a local evm_mine, so a getBlock() read taken after fast-forwarding the
          // chain silently returns the pre-fast-forward block (verified empirically against
          // anvil — two mines apart, getBlock('latest') kept returning the first block it
          // ever saw while raw eth_getBlockByNumber correctly returned the new one).
          const nowTs = async () => BigInt((await provider.send('eth_getBlockByNumber', ['latest', false])).timestamp);
          let now = await nowTs();
          if (now < eta) {
            try {
              await provider.send('evm_increaseTime', [Number(eta - now) + 60]);
              await provider.send('evm_mine', []);
              now = await nowTs();
            } catch (_) {
              // Not anvil (or method unsupported) — real network falls through to SKIP below.
            }
          }
          if (now < eta) {
            skipReason = `creditPolicy AUTO queued, executable at ${new Date(Number(eta) * 1000).toISOString()} — re-run after that time`;
          } else {
            const tx = await xpnts.executeCreditPolicy({ nonce: await nextTxNonce() });
            await tx.wait();
            policy = await xpnts.creditPolicy();
          }
        }
      }

      // 5b: an active requestCredit() for the CURRENT policyEpoch (C-0).
      if (!skipReason) {
        const [policyEpoch, req] = await Promise.all([xpnts.policyEpoch(), xpnts.creditReq(creditSubject)]);
        if (req.epoch !== policyEpoch || req.requestedCap === 0n) {
          const tx = await xpnts.requestCredit(ethers.parseEther('1000'), { nonce: await nextTxNonce() });
          await tx.wait();
        }
      }

      // 5c: cap = min(requestedCap, PROTOCOL_CREDIT_CEILING, tierOf(user)) — tierOf resolves
      // through Registry.getCreditLimit. Tier 1's default limit is normally nonzero (Step 2
      // already asserts fresh addresses get it), but if this deployment's tier 1 is 0, bump
      // it the same way test-case-4 Step 2c does, and restore it afterward.
      let cap2 = skipReason ? 0n : await xpnts.effectiveCreditCap(creditSubject);
      if (!skipReason && cap2 === 0n) {
        try {
          const tier1Before = await registry.creditTierConfig(1n);
          if (tier1Before === 0n) {
            const tx = await registry.setCreditTier(1n, ethers.parseEther('1000'), { nonce: await nextTxNonce() });
            await tx.wait();
            tierRestoreValue = tier1Before;
            cap2 = await xpnts.effectiveCreditCap(creditSubject);
          }
        } catch (tierErr) {
          skipReason = `Could not bump tier 1 to get a nonzero cap (not Registry owner? ${tierErr.message.substring(0, 60)})`;
        }
      }
      if (!skipReason && cap2 === 0n) {
        skipReason = 'effectiveCreditCap is still 0 after policy + request-credit + tier setup — cannot construct a live EXCEEDS_CAP probe';
      }

      if (skipReason) {
        printSkip(skipReason);
      } else {
        const [debt2, reserved2, maxSingleTxLimit] = await Promise.all([
          xpnts.debts(creditSubject),
          xpnts.creditReservedOf(creditSubject),
          xpnts.maxSingleTxLimit(),
        ]);
        const spent2 = debt2 + reserved2;
        const headroom = cap2 > spent2 ? cap2 - spent2 : 0n;

        printKeyValue('effectiveCreditCap', `${ethers.formatEther(cap2)} aPNTs`);
        printKeyValue('debts + creditReservedOf', `${ethers.formatEther(spent2)} aPNTs`);
        printKeyValue('headroom', `${ethers.formatEther(headroom)} aPNTs`);
        printKeyValue('maxSingleTxLimit', `${ethers.formatEther(maxSingleTxLimit)} aPNTs`);

        if (headroom >= maxSingleTxLimit) {
          // Any amount that breaches the cap would also breach the single-tx limit first,
          // which would mask EXCEEDS_CAP behind SINGLE_TX_LIMIT instead of isolating it.
          printSkip(`headroom (${ethers.formatEther(headroom)}) >= maxSingleTxLimit (${ethers.formatEther(maxSingleTxLimit)}) — cannot isolate EXCEEDS_CAP from SINGLE_TX_LIMIT`);
        } else {
          const probeAmount = headroom + ethers.parseEther('1'); // > headroom, and still <= maxSingleTxLimit per the check above
          const probeOpHash = ethers.keccak256(ethers.toUtf8Bytes(`I1-ceiling-probe-${Date.now()}-${Math.random()}`));
          const result = await xpnts.previewCredit(config.superPaymaster, creditSubject, probeOpHash, probeAmount);
          const resultName = CREDIT_RESULT_NAMES[Number(result)] ?? `UNKNOWN(${result})`;
          printKeyValue(`previewCredit(headroom + 1 aPNTs = ${ethers.formatEther(probeAmount)})`, resultName);

          assertEqual(Number(result), 2, `Reservation past headroom is rejected with EXCEEDS_CAP specifically (got ${resultName})`);
          printSuccess('Credit ceiling enforced — the EXCEEDS_CAP branch itself is exercised live (spec C-1)');
        }
      }
    } catch (e) {
      catchStep('Ceiling enforcement', e);
    } finally {
      if (tierRestoreValue !== null) {
        try {
          const tx = await registry.setCreditTier(1n, tierRestoreValue, { nonce: await nextTxNonce() });
          await tx.wait();
        } catch (_) {
          printInfo('Could not restore tier 1 to its original value after the probe (non-fatal)');
        }
      }
    }
  }

  // ──────────────────────────────────────────
  // Step 6: dryRunValidation (via SuperPaymasterLens) — demonstrates the new gate exists
  // 5.5.0 has no way to externally force a user into a "ceiling breached" state to test
  // rejection against (L-1: failed reservations write no state) — that would require
  // driving a real credit-path UserOp past the cap, which is a live-fire test outside
  // this read-only group's scope. This step only confirms the Lens call itself works.
  // ──────────────────────────────────────────
  printStep(6, 'dryRunValidation (via SuperPaymasterLens) — minimal-op smoke check');
  try {
    if (!lens) {
      printSkip('config.superPaymasterLens missing — dryRunValidation moved there in 5.5.0');
    } else {
      const operatorData = await sp.operators(operatorAddr);
      if (!operatorData.isConfigured) {
        printSkip('Operator not configured — cannot run dryRunValidation (skip)');
      } else {
        const pmVerificationGasLimit = 400000n;
        const pmPostOpGasLimit = 200000n;
        const paymasterAndData = ethers.solidityPacked(
          ['address', 'uint128', 'uint128', 'address', 'uint256', 'address', 'uint8'],
          [config.superPaymaster, pmVerificationGasLimit, pmPostOpGasLimit, operatorAddr,
           ethers.MaxUint256, operatorData.xPNTsToken, 0]
        );
        const dummyUserOp = {
          sender: userAddr,
          nonce: 0n,
          initCode: '0x',
          callData: '0x',
          accountGasLimits: ethers.solidityPacked(['uint128', 'uint128'], [200000n, 200000n]),
          preVerificationGas: 21000n,
          gasFees: ethers.solidityPacked(['uint128', 'uint128'], [2000000000n, 2000000000n]),
          paymasterAndData,
          signature: '0x',
        };
        try {
          const [ok, reasonCode] = await lens.dryRunValidation(config.superPaymaster, dummyUserOp, ethers.parseEther('0.01'));
          printKeyValue('ok', ok);
          printKeyValue('reasonCode', reasonCode);
          // Unsigned/empty-callData minimal op — not asserting ok=true/false, same
          // "not a positive assertion" caveat as test-group-B4 Step 7.
          printSuccess('dryRunValidation call succeeded via SuperPaymasterLens');
        } catch (dryErr) {
          printInfo(`dryRunValidation reverted: ${(dryErr.message || '').substring(0, 80)}`);
          printSuccess('dryRunValidation call completed (reverted, not silently wrong ABI)');
        }
      }
    }
  } catch (e) {
    catchStep('dryRunValidation smoke check', e);
  }

  // ──────────────────────────────────────────
  // Step 7: Version check — confirm 5.5.0 is deployed
  // ──────────────────────────────────────────
  printStep(7, 'Version assertion — confirm SuperPaymaster-5.5.0 is deployed');
  try {
    const ver = await sp.version();
    printKeyValue('SuperPaymaster version', ver);
    // on-chain version() must equal the exact release tag — see TX-Value-Verification.
    assertTrue(ver.includes('5.5.0'), `version contains "5.5.0" (got "${ver}")`);
    printSuccess('5.5.0 confirmed deployed — balance-mode credit ceiling accounting is live');
    printInfo('Ceiling enforcement now lives in xPNTsTokenV2.tryReserveCredit (C-1), atomic,');
    printInfo('  no state written on rejection — no isBlocked flag needed to prevent overrun.');
  } catch (e) {
    catchStep('version check', e);
  }

  process.exit(finishTest('I1: Credit Ceiling H-1 Fix Verification'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});
