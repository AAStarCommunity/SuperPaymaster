#!/usr/bin/env node
/**
 * Test Group B2: Operator Deposit & Withdraw
 *
 * Tests: deposit, depositFor, withdraw, withdraw excess (revert).
 * Requires deployer operator to be configured (run B1 first).
 */
const {
  initTestEnv, getContracts, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe, expectRevert,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group B2: Operator Deposit & Withdraw');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;
  const aPNTs = c.aPNTs;

  // SP.withdraw() uses APNTS_TOKEN which may differ from config.aPNTs if the
  // 7-day timelock update hasn't been applied yet.
  const spApntsTokenAddr = await sp.APNTS_TOKEN();
  const spApntsToken = new ethers.Contract(
    spApntsTokenAddr,
    ['function balanceOf(address) view returns (uint256)'],
    deployer
  );
  const apntsTokenMatchesConfig = spApntsTokenAddr.toLowerCase() === (config.aPNTs || '').toLowerCase();
  if (!apntsTokenMatchesConfig) {
    printInfo(`SP.APNTS_TOKEN (${spApntsTokenAddr}) differs from config.aPNTs (${config.aPNTs})`);
    printInfo('deposit/depositFor/withdraw use APNTS_TOKEN; ERC20 balance assertions track that token.');
  }

  const deployerAddr = deployer.address;

  // Pre-check: operator must be configured
  const op = await sp.operators(deployerAddr);
  if (!op.isConfigured) {
    printError('Deployer operator not configured. Run B1 first.');
    process.exit(1);
  }

  // ──────────────────────────────────────────
  // Step 1: Read pre-balances
  // ──────────────────────────────────────────
  printStep(1, 'Read pre-balances');
  const aPNTsBalanceBefore = await aPNTs.balanceOf(deployerAddr);
  const opBefore = await sp.operators(deployerAddr);
  const opBalanceBefore = opBefore.aPNTsBalance;
  printKeyValue('aPNTs ERC20 balance', ethers.formatEther(aPNTsBalanceBefore));
  printKeyValue('Operator aPNTsBalance', ethers.formatEther(opBalanceBefore));

  if (aPNTsBalanceBefore < ethers.parseEther('15')) {
    printSkip('Insufficient aPNTs for deposit tests (need >= 15). Skipping write tests.');
    printSummary('B2: Operator Deposit/Withdraw');
    process.exit(2); // precondition not met → SKIP, not PASS
  }

  // ──────────────────────────────────────────
  // Step 2: Approve + deposit(10 ether)
  // ──────────────────────────────────────────
  printStep(2, 'deposit(10 ether)');
  const depositAmount = ethers.parseEther('10');

  // Ensure allowance
  const allowance = await aPNTs.allowance(deployerAddr, config.superPaymaster);
  if (allowance < depositAmount) {
    await sendTxSafe(aPNTs, 'approve', [config.superPaymaster, ethers.MaxUint256], 'Approve SuperPaymaster');
  }

  await sendTxSafe(sp, 'deposit', [depositAmount], 'deposit(10)');
  const opAfterDeposit = await sp.operators(deployerAddr);
  const expectedBalance = opBalanceBefore + depositAmount;
  assertEqual(opAfterDeposit.aPNTsBalance, expectedBalance, 'aPNTsBalance after deposit');

  // ──────────────────────────────────────────
  // Step 3: depositFor(deployer, 5 ether)
  // ──────────────────────────────────────────
  printStep(3, 'depositFor(deployer, 5 ether)');
  const depositForAmount = ethers.parseEther('5');
  await sendTxSafe(sp, 'depositFor', [deployerAddr, depositForAmount], 'depositFor(5)');
  const opAfterDepositFor = await sp.operators(deployerAddr);
  assertEqual(opAfterDepositFor.aPNTsBalance, expectedBalance + depositForAmount, 'aPNTsBalance after depositFor');

  // ──────────────────────────────────────────
  // Step 4: withdraw(3 ether)
  // ──────────────────────────────────────────
  printStep(4, 'withdraw(3 ether)');
  const withdrawAmount = ethers.parseEther('3');
  const apntsTokenBalanceBefore = await spApntsToken.balanceOf(deployerAddr);
  await sendTxSafe(sp, 'withdraw', [withdrawAmount], 'withdraw(3)');

  const opAfterWithdraw = await sp.operators(deployerAddr);
  const expectedAfterWithdraw = expectedBalance + depositForAmount - withdrawAmount;
  assertEqual(opAfterWithdraw.aPNTsBalance, expectedAfterWithdraw, 'aPNTsBalance after withdraw');

  const apntsTokenBalanceAfter = await spApntsToken.balanceOf(deployerAddr);
  assertEqual(apntsTokenBalanceAfter, apntsTokenBalanceBefore + withdrawAmount, `APNTS_TOKEN (${spApntsTokenAddr.slice(0, 10)}…) balance after withdraw`);

  // ──────────────────────────────────────────
  // Step 5: withdraw excess -> expect revert
  // ──────────────────────────────────────────
  printStep(5, 'withdraw excess -> expect revert');
  const excessAmount = opAfterWithdraw.aPNTsBalance + ethers.parseEther('1000');
  await expectRevert(
    () => sp.withdraw(excessAmount),
    'Withdraw excess amount'
  );

  // ──────────────────────────────────────────
  // Cleanup: withdraw all deposited back
  // ──────────────────────────────────────────
  printStep(6, 'Cleanup: withdraw remaining deposited amount');
  const remainingDeposited = depositAmount + depositForAmount - withdrawAmount;
  if (remainingDeposited > 0n) {
    await sendTxSafe(sp, 'withdraw', [remainingDeposited], `withdraw(${ethers.formatEther(remainingDeposited)})`);
    const opFinal = await sp.operators(deployerAddr);
    assertEqual(opFinal.aPNTsBalance, opBalanceBefore, 'Restored to original balance');
  }

  process.exit(finishTest('B2: Operator Deposit/Withdraw'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});
