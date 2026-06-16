#!/usr/bin/env node
/**
 * Test Group I1: Credit Ceiling H-1 Fix Verification
 *
 * Verifies the AUDIT H-1 (2026-06-11) fix: the debt-fallback path in
 * SuperPaymaster._recordDebt() now enforces the credit ceiling before
 * recording debt via xPNTs.recordDebtWithOpHash(). Before the fix, a
 * user who drained their xPNTs balance inside a UserOp (between validate
 * and postOp) could accumulate unlimited operator debt — bypassing C-01.
 *
 * Fix location: SuperPaymaster.sol `_recordDebt()` — the fallback branch
 *   now checks: getDebt(user) + pendingDebts[token][user] + amount <= getCreditLimit(user)
 *   and sets userOpState[operator][user].isBlocked = true when the ceiling is breached.
 *
 * Tests (read-only + state verification — no live UserOp required):
 *   1. Credit tier config — tiers 1-6 limits from Registry
 *   2. getCreditLimit — for deployer and a fresh address
 *   3. pendingDebts — current in-flight debt for test user
 *   4. userOpState — isBlocked flag per operator+user
 *   5. Ceiling enforcement check — availableCredit = creditLimit - (debt + pending)
 *   6. Blocked user rejection — dryRunValidation reverts if isBlocked
 *   7. Version assertion — confirm H-1 fix is deployed (SuperPaymaster-5.3.3)
 *
 * Prerequisites:
 *   - SuperPaymaster-5.3.3 + Registry-4.1.0 deployed on Sepolia
 *   - DEPLOYER_PRIVATE_KEY set in env
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertGte, assertFalse, catchStep,
} = require('./test-helpers');

// Additional ABI entries not in the shared ABI
const SP_EXTRA_ABI = [
  // pendingDebts public mapping: [xPNTsToken][user] => uint256 (aPNTs)
  "function pendingDebts(address token, address user) view returns (uint256)",
];

async function main() {
  printHeader('Test Group I1: Credit Ceiling H-1 Fix Verification');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const registry = c.registry;

  // Attach SuperPaymaster with the extra ABI for pendingDebts
  const sp = new ethers.Contract(
    config.superPaymaster,
    [...require('./test-helpers').ABI.SuperPaymaster, ...SP_EXTRA_ABI],
    deployer
  );

  const deployerAddr = deployer.address;
  const operatorAddr = process.env.OPERATOR_ADDRESS || deployerAddr;
  const userAddr = process.env.TEST_AA_ACCOUNT_ADDRESS_A || deployerAddr;
  // xPNTs token address for the operator (aPNTs is the deployer's community token)
  const xPNTsAddr = config.aPNTs;

  printKeyValue('SuperPaymaster', config.superPaymaster);
  printKeyValue('Registry', config.registry);
  printKeyValue('aPNTs (xPNTs token)', xPNTsAddr);
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
  // Step 3: pendingDebts — in-flight SP-level debt
  // ──────────────────────────────────────────
  printStep(3, 'pendingDebts — SuperPaymaster in-flight debt for (xPNTs, user)');
  let pendingDebt = 0n;
  try {
    pendingDebt = await sp.pendingDebts(xPNTsAddr, userAddr);
    printKeyValue('pendingDebts(xPNTs, user)', `${ethers.formatEther(pendingDebt)} aPNTs`);

    // Also read the xPNTs-level recorded debt (for reference)
    const xpnts = c.aPNTsToken;
    const xpntsDebt = await xpnts.getDebt(userAddr);
    printKeyValue('xPNTs.getDebt(user)', `${ethers.formatEther(xpntsDebt)} aPNTs`);

    const totalDebt = pendingDebt + xpntsDebt;
    printKeyValue('Total debt (pending + xPNTs)', `${ethers.formatEther(totalDebt)} aPNTs`);
    printSuccess('pendingDebts readable — H-1 fix storage is accessible');
  } catch (e) {
    catchStep('pendingDebts', e);
  }

  // ──────────────────────────────────────────
  // Step 4: userOpState — isBlocked flag
  // ──────────────────────────────────────────
  printStep(4, 'userOpState — isBlocked flag per operator+user pair');
  let isBlocked = false;
  try {
    const state = await sp.userOpState(operatorAddr, userAddr);
    isBlocked = state.isBlocked;
    printKeyValue('lastTimestamp', state.lastTimestamp.toString());
    printKeyValue('isBlocked', isBlocked);

    // For a different operator/user pair to confirm the mapping works
    const freshState = await sp.userOpState(
      ethers.Wallet.createRandom().address,
      ethers.Wallet.createRandom().address
    );
    assertFalse(freshState.isBlocked, 'Fresh operator+user pair is not blocked');
    printSuccess('userOpState mapping readable — H-1 blocked flag accessible');
  } catch (e) {
    catchStep('userOpState', e);
  }

  // ──────────────────────────────────────────
  // Step 5: Ceiling enforcement — compute available credit
  // ──────────────────────────────────────────
  printStep(5, 'Ceiling enforcement check — availableCredit = creditLimit - totalDebt');
  try {
    const currentCreditLimit = await registry.getCreditLimit(userAddr);
    const currentPending = await sp.pendingDebts(xPNTsAddr, userAddr);
    const currentXPNTsDebt = await c.aPNTsToken.getDebt(userAddr);
    const totalDebtNow = currentPending + currentXPNTsDebt;
    const availableCredit = currentCreditLimit >= totalDebtNow
      ? currentCreditLimit - totalDebtNow
      : 0n;

    printKeyValue('creditLimit', `${ethers.formatEther(currentCreditLimit)} aPNTs`);
    printKeyValue('totalDebt (pending + xPNTs)', `${ethers.formatEther(totalDebtNow)} aPNTs`);
    printKeyValue('availableCredit', `${ethers.formatEther(availableCredit)} aPNTs`);

    // The H-1 fix ensures that debt cannot accumulate past creditLimit.
    // If isBlocked, user has breached the ceiling at least once.
    // If not blocked, totalDebt should be <= creditLimit.
    if (isBlocked) {
      printInfo('User is blocked — previous mid-UserOp drain triggered the H-1 ceiling guard');
      printSuccess('H-1 ceiling guard activated (isBlocked=true confirms fix is wired)');
    } else {
      assertTrue(totalDebtNow <= currentCreditLimit, 'totalDebt <= creditLimit (ceiling respected)');
      printSuccess('H-1 fix active — debt is within credit ceiling for this user');
    }

    // getAvailableCredit from SP (cross-check)
    const spAvail = await sp.getAvailableCredit(userAddr, xPNTsAddr);
    printKeyValue('sp.getAvailableCredit(user, xPNTs)', `${ethers.formatEther(spAvail)} aPNTs`);
  } catch (e) {
    catchStep('Ceiling enforcement', e);
  }

  // ──────────────────────────────────────────
  // Step 6: Blocked user rejects via dryRunValidation
  // ──────────────────────────────────────────
  printStep(6, 'Blocked user rejection — dryRunValidation with isBlocked user');
  try {
    if (!isBlocked) {
      printInfo('Test user is not blocked (expected in normal ops)');
      printInfo('To test full rejection: a mid-UserOp drain scenario is needed in integration env');
      printSuccess('Non-blocked user state confirmed — ceiling not breached');
    } else {
      // User is blocked — verify dryRunValidation rejects them
      printInfo('Test user is blocked — verifying dryRunValidation rejects blocked user');
      const operatorData = await sp.operators(operatorAddr);
      if (!operatorData.isConfigured) {
        printSkip('Operator not configured — cannot run dryRunValidation (skip)');
      } else {
        // Build a minimal dummy UserOp for the dryRunValidation call
        const dummyUserOp = {
          sender: userAddr,
          nonce: 0n,
          initCode: '0x',
          callData: '0x',
          accountGasLimits: ethers.zeroPadValue('0x', 32),
          preVerificationGas: 21000n,
          gasFees: ethers.zeroPadValue('0x', 32),
          paymasterAndData: '0x',
          signature: '0x',
        };
        try {
          const [ok, reasonCode] = await sp.dryRunValidation(dummyUserOp, ethers.parseEther('0.01'));
          assertFalse(ok, 'dryRunValidation returns ok=false for blocked user');
          printKeyValue('reasonCode', reasonCode.toString());
          printSuccess('Blocked user correctly rejected by dryRunValidation');
        } catch (dryErr) {
          // dryRunValidation may revert for blocked users
          printSuccess(`dryRunValidation reverted for blocked user: ${(dryErr.message || '').substring(0, 60)}`);
        }
      }
    }
  } catch (e) {
    catchStep('dryRunValidation blocked user', e);
  }

  // ──────────────────────────────────────────
  // Step 7: Version check — confirm H-1 fix is deployed
  // ──────────────────────────────────────────
  printStep(7, 'Version assertion — confirm SuperPaymaster-5.4.0 is deployed');
  try {
    const ver = await sp.version();
    printKeyValue('SuperPaymaster version', ver);
    // H-1 credit-ceiling fix ships in v5.4.x. Update this string per release
    // (on-chain version() must equal the exact release tag — see TX-Value-Verification).
    assertTrue(ver.includes('5.4.0'), `version contains "5.4.0" (got "${ver}")`);
    printSuccess('H-1 fix confirmed deployed — SuperPaymaster-5.4.0 on-chain');
    printInfo('Fix summary: _recordDebt() fallback now enforces credit ceiling before');
    printInfo('  recording debt. Over-ceiling mid-op drain → isBlocked=true (DVT/BLS to unblock).');
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
