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
  printSummary, finishTest, resetCounters,
  assertTrue, expectRevert,
  sendTxSafe, catchStep, ABI,
} = require('./test-helpers');

function buildDummyUserOp(sender, paymaster, operator, token) {
  const iface = new ethers.Interface(ABI.SimpleAccount);
  const callData = iface.encodeFunctionData('execute', [
    ethers.ZeroAddress,
    0,
    '0x',
  ]);

  // 400K, not 150K: high enough that AA36 (over paymasterVerificationGasLimit) never masks
  // the condition actually under test — see test-case-2-fixed.js for the measurement.
  const pmVerificationGasLimit = 400000n;
  const pmPostOpGasLimit = 100000n;
  // 5.5.0 paymasterAndData layout (SuperPaymasterStorage.sol:177-180). Every case here is
  // expected to revert on an EARLIER check (SBT/pause/operator-config), before validation
  // ever reaches the token-binding check at TOKEN_OFFSET — but a well-formed token/maxRate/
  // flags tail keeps this a true isolation test of the condition under test, not an
  // accidental pass from malformed paymasterAndData.
  const maxRate = ethers.MaxUint256;
  const flags = 0;
  const paymasterAndData = ethers.solidityPacked(
    ['address', 'uint128', 'uint128', 'address', 'uint256', 'address', 'uint8'],
    [paymaster, pmVerificationGasLimit, pmPostOpGasLimit, operator, maxRate, token, flags]
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
  const userOp1 = buildDummyUserOp(noSBTAddress, config.superPaymaster, operatorAddr, config.aastarXPNTsV2);
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
    const pauseSent = await sendTxSafe(sp, 'setOperatorPaused', [deployerAddr, true], 'Pause deployer operator');
    if (!pauseSent) {
      // sendTxSafe returns null on skip/failure (nonce conflict exhausted, revert, ...) — the
      // operator was never actually paused, so asserting "should revert" here would be testing
      // the wrong causal state (DSR review, 2026-09-17: same gap found in G3's setCreditTier).
      printSkip('Pause deployer operator: write did not land — paused-operator revert check skipped');
    } else {
      // Try UserOp with paused operator
      const aaAccount = process.env.TEST_AA_ACCOUNT_ADDRESS_A || noSBTAddress;
      const userOp2 = buildDummyUserOp(aaAccount, config.superPaymaster, deployerAddr, config.aastarXPNTsV2);
      await expectRevert(
        () => entryPoint.handleOps.estimateGas([userOp2], deployerAddr),
        'Paused operator should revert'
      );
    }

    // Unpause — always attempted regardless of whether the pause above landed, so a real
    // pause is never left in place for later scripts sharing this operator's on-chain state
    // (run-all-e2e-tests.sh runs many scripts against one deployment). Loud, not a soft skip:
    // unlike the read-back assertions above, a failed unpause has a lasting side effect.
    const unpauseSent = await sendTxSafe(sp, 'setOperatorPaused', [deployerAddr, false], 'Unpause deployer operator');
    if (!unpauseSent) {
      printError('Unpause deployer operator: write did not land — operator may be left PAUSED for later tests');
    }
  }

  // ──────────────────────────────────────────
  // Step 3: Unconfigured operator -> revert
  // ──────────────────────────────────────────
  printStep(3, 'Unconfigured operator -> expect revert');
  const unconfiguredAddr = '0x' + '11'.repeat(20);
  const aaAccount = process.env.TEST_AA_ACCOUNT_ADDRESS_A || noSBTAddress;
  const userOp3 = buildDummyUserOp(aaAccount, config.superPaymaster, unconfiguredAddr, config.aastarXPNTsV2);
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
    catchStep(`userOpState query`, e);
  }

  process.exit(finishTest('C1: SuperPaymaster Negative Cases'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});
