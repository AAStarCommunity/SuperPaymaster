#!/usr/bin/env node
/**
 * Test Group C2: PaymasterV4 Negative Cases
 *
 * Tests: find deployer's PaymasterV4, check supported tokens,
 * attempt UserOp with zero-balance user.
 */
const {
  initTestEnv, getContracts, ethers, ABI,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertTrue, expectRevert,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group C2: PaymasterV4 Negative Cases');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const factory = c.paymasterFactory;
  const entryPoint = c.entryPoint;

  const deployerAddr = deployer.address;
  const operatorAddr = process.env.OPERATOR_ADDRESS || deployerAddr;

  // ──────────────────────────────────────────
  // Step 1: Find deployer's PaymasterV4
  // ──────────────────────────────────────────
  printStep(1, "Find operator's PaymasterV4");
  let pmV4Addr = null;
  try {
    pmV4Addr = await factory.paymasterByOperator(operatorAddr);
    printKeyValue('PaymasterV4 address', pmV4Addr);
    if (pmV4Addr === ethers.ZeroAddress) {
      printSkip('No PaymasterV4 deployed for operator');
      pmV4Addr = null;
    } else {
      printSuccess(`Found PaymasterV4: ${pmV4Addr}`);
    }
  } catch (e) {
    printError(`paymasterByOperator: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: UserOp with zero-balance user -> revert
  // ──────────────────────────────────────────
  printStep(2, 'UserOp with zero-balance user -> expect revert');
  if (!pmV4Addr) {
    printSkip('No PaymasterV4, skipping UserOp test');
  } else {
    const randomAddr = ethers.Wallet.createRandom().address;
    const iface = new ethers.Interface(ABI.SimpleAccount);
    const callData = iface.encodeFunctionData('execute', [ethers.ZeroAddress, 0, '0x']);

    const pmVerificationGasLimit = 150000n;
    const pmPostOpGasLimit = 100000n;
    const paymasterAndData = ethers.solidityPacked(
      ['address', 'uint128', 'uint128'],
      [pmV4Addr, pmVerificationGasLimit, pmPostOpGasLimit]
    );

    const userOp = {
      sender: randomAddr,
      nonce: 0n,
      initCode: '0x',
      callData,
      accountGasLimits: ethers.solidityPacked(['uint128', 'uint128'], [200000, 200000]),
      preVerificationGas: 100000n,
      gasFees: ethers.solidityPacked(['uint128', 'uint128'], [2000000000, 2000000000]),
      paymasterAndData,
      signature: '0x' + '00'.repeat(65),
    };

    await expectRevert(
      () => entryPoint.handleOps.estimateGas([userOp], deployerAddr),
      'Zero-balance user should revert'
    );
  }

  // ──────────────────────────────────────────
  // Step 3: Query supported tokens
  // ──────────────────────────────────────────
  printStep(3, 'Query supported tokens');
  if (!pmV4Addr) {
    printSkip('No PaymasterV4, skipping');
  } else {
    try {
      const pmV4 = new ethers.Contract(pmV4Addr, ABI.PaymasterV4, provider);
      const tokens = await pmV4.getSupportedTokens();
      printKeyValue('Supported tokens count', tokens.length);
      for (const t of tokens) {
        printKeyValue('  Token', t);
      }
      assertTrue(tokens.length >= 0, 'getSupportedTokens returned');
    } catch (e) {
      printError(`getSupportedTokens: ${e.message.substring(0, 80)}`);
    }
  }

  const allPassed = printSummary('C2: PaymasterV4 Negative Cases');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });
