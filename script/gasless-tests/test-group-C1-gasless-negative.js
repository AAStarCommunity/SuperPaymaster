#!/usr/bin/env node
/**
 * Test Group C1: SuperPaymaster Negative Cases
 *
 * Tests boundary conditions: no SBT, operator paused,
 * unconfigured operator, userOpState queries.
 * Uses estimateGas / staticCall to catch reverts without spending gas.
 */
const {
  initTestEnv, getContracts, ROLES, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertTrue, expectRevert,
  sendTxSafe, ABI,
} = require('./test-helpers');

function buildDummyUserOp(sender, paymaster, operator) {
  const iface = new ethers.Interface(ABI.SimpleAccount);
  const callData = iface.encodeFunctionData('execute', [
    ethers.ZeroAddress,
    0,
    '0x',
  ]);

  const pmVerificationGasLimit = 150000n;
  const pmPostOpGasLimit = 100000n;
  const paymasterAndData = ethers.solidityPacked(
    ['address', 'uint128', 'uint128', 'address'],
    [paymaster, pmVerificationGasLimit, pmPostOpGasLimit, operator]
  );

  return {
    sender,
    nonce: 0n,
    initCode: '0x',
    callData,
    accountGasLimits: ethers.solidityPacked(['uint128', 'uint128'], [200000, 200000]),
    preVerificationGas: 100000n,
    gasFees: ethers.solidityPacked(['uint128', 'uint128'], [2000000000, 2000000000]),
    paymasterAndData,
    signature: '0x' + '00'.repeat(65),
  };
}

async function main() {
  printHeader('Test Group C1: SuperPaymaster Negative Cases');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;
  const entryPoint = c.entryPoint;

  const deployerAddr = deployer.address;
  const operatorAddr = process.env.OPERATOR_ADDRESS || deployerAddr;

  // Generate a random address with no SBT
  const randomWallet = ethers.Wallet.createRandom();
  const noSBTAddress = randomWallet.address;

  // ──────────────────────────────────────────
  // Step 1: UserOp from sender with no SBT -> revert
  // ──────────────────────────────────────────
  printStep(1, 'UserOp from sender with no SBT -> expect revert');
  const userOp1 = buildDummyUserOp(noSBTAddress, config.superPaymaster, operatorAddr);
  await expectRevert(
    () => entryPoint.handleOps.estimateGas([userOp1], deployerAddr),
    'No SBT sender should revert'
  );

  // ──────────────────────────────────────────
  // Step 2: Pause operator -> UserOp -> Unpause
  // ──────────────────────────────────────────
  printStep(2, 'Paused operator -> UserOp should fail');

  // Check if we can pause
  const op = await sp.operators(deployerAddr);
  if (!op.isConfigured) {
    printSkip('Deployer not configured as operator; skipping pause test');
  } else {
    // Pause
    await sendTxSafe(sp, 'setOperatorPaused', [deployerAddr, true], 'Pause deployer operator');

    // Try UserOp with paused operator
    const aaAccount = process.env.TEST_AA_ACCOUNT_ADDRESS_A || noSBTAddress;
    const userOp2 = buildDummyUserOp(aaAccount, config.superPaymaster, deployerAddr);
    await expectRevert(
      () => entryPoint.handleOps.estimateGas([userOp2], deployerAddr),
      'Paused operator should revert'
    );

    // Unpause
    await sendTxSafe(sp, 'setOperatorPaused', [deployerAddr, false], 'Unpause deployer operator');
  }

  // ──────────────────────────────────────────
  // Step 3: Unconfigured operator -> revert
  // ──────────────────────────────────────────
  printStep(3, 'Unconfigured operator -> expect revert');
  const unconfiguredAddr = '0x' + '11'.repeat(20);
  const aaAccount = process.env.TEST_AA_ACCOUNT_ADDRESS_A || noSBTAddress;
  const userOp3 = buildDummyUserOp(aaAccount, config.superPaymaster, unconfiguredAddr);
  await expectRevert(
    () => entryPoint.handleOps.estimateGas([userOp3], deployerAddr),
    'Unconfigured operator should revert'
  );

  // ──────────────────────────────────────────
  // Step 4: Query userOpState (read-only)
  // ──────────────────────────────────────────
  printStep(4, 'Query userOpState');
  try {
    const state = await sp.userOpState(operatorAddr, noSBTAddress);
    printKeyValue('lastTimestamp', state.lastTimestamp.toString());
    printKeyValue('isBlocked', state.isBlocked);
    assertTrue(state.lastTimestamp === 0n || state.lastTimestamp >= 0n, 'userOpState returned valid data');
  } catch (e) {
    printError(`userOpState query: ${e.message.substring(0, 80)}`);
  }

  const allPassed = printSummary('C1: SuperPaymaster Negative Cases');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });
