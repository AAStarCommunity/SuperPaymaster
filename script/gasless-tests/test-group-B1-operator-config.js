#!/usr/bin/env node
/**
 * Test Group B1: Operator Configuration
 *
 * Tests: read operator config, configureOperator, setOperatorLimits,
 * setOperatorPaused (pause/unpause cycle).
 * Requires deployer to have ROLE_COMMUNITY (run A1 first).
 */
const {
  initTestEnv, getContracts, ROLES, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertFalse,
  sendTxSafe,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group B1: Operator Configuration');
  resetCounters();

  const { config, provider, deployer, anni } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;
  const registry = c.registry;

  const deployerAddr = deployer.address;
  const anniAddr = process.env.OPERATOR_ADDRESS || (anni ? anni.address : null);

  // ──────────────────────────────────────────
  // Step 1: Read Anni's operator config
  // ──────────────────────────────────────────
  printStep(1, 'Read Anni operator config');
  if (anniAddr) {
    try {
      const op = await sp.operators(anniAddr);
      printKeyValue('isConfigured', op.isConfigured);
      printKeyValue('isPaused', op.isPaused);
      printKeyValue('aPNTsBalance', ethers.formatEther(op.aPNTsBalance));
      printKeyValue('exchangeRate', op.exchangeRate.toString());
      printKeyValue('reputation', op.reputation.toString());
      printKeyValue('xPNTsToken', op.xPNTsToken);
      printKeyValue('treasury', op.treasury);
      assertTrue(op.isConfigured, 'Anni operator is configured');
    } catch (e) {
      printError(`Read Anni config: ${e.message.substring(0, 80)}`);
    }
  } else {
    printSkip('OPERATOR_ADDRESS not set, skipping Anni check');
  }

  // ──────────────────────────────────────────
  // Step 2: Read deployer operator config
  // ──────────────────────────────────────────
  printStep(2, 'Read deployer operator config');
  let deployerConfigured = false;
  try {
    const op = await sp.operators(deployerAddr);
    deployerConfigured = op.isConfigured;
    printKeyValue('isConfigured', op.isConfigured);
    printKeyValue('aPNTsBalance', ethers.formatEther(op.aPNTsBalance));
    if (deployerConfigured) {
      printSuccess('Deployer operator already configured');
    } else {
      printInfo('Deployer not yet configured as operator');
    }
  } catch (e) {
    printError(`Read deployer config: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: Ensure ROLE_PAYMASTER_SUPER
  // ──────────────────────────────────────────
  printStep(3, 'Ensure deployer has ROLE_PAYMASTER_SUPER');
  const hasPS = await registry.hasRole(ROLES.PAYMASTER_SUPER, deployerAddr);
  if (hasPS) {
    printSuccess('Deployer already has ROLE_PAYMASTER_SUPER');
  } else {
    // Need ROLE_COMMUNITY first
    const hasCommunity = await registry.hasRole(ROLES.COMMUNITY, deployerAddr);
    if (!hasCommunity) {
      printSkip('Deployer lacks ROLE_COMMUNITY; run A1 first');
    } else {
      printInfo('Registering ROLE_PAYMASTER_SUPER...');
      // PaymasterSuperRoleData: tuple(address, uint256)
      const roleData = ethers.AbiCoder.defaultAbiCoder().encode(
        ["tuple(address,uint256)"],
        [[deployerAddr, ethers.parseEther("30")]]
      );
      await sendTxSafe(registry, 'registerRole', [ROLES.PAYMASTER_SUPER, deployerAddr, roleData], 'registerRole(PAYMASTER_SUPER)');
    }
  }

  // ──────────────────────────────────────────
  // Step 4: configureOperator
  // ──────────────────────────────────────────
  printStep(4, 'configureOperator');
  if (deployerConfigured) {
    printSkip('Deployer operator already configured');
  } else {
    const hasPSNow = await registry.hasRole(ROLES.PAYMASTER_SUPER, deployerAddr);
    if (!hasPSNow) {
      printSkip('Missing ROLE_PAYMASTER_SUPER, cannot configure');
    } else {
      const xPNTsToken = config.aPNTs;
      const treasury = deployerAddr;
      const exchangeRate = ethers.parseEther('1');
      const receipt = await sendTxSafe(sp, 'configureOperator',
        [xPNTsToken, treasury, exchangeRate], 'configureOperator');
      if (receipt) {
        const op = await sp.operators(deployerAddr);
        assertTrue(op.isConfigured, 'Operator now configured');
      }
    }
  }

  // ──────────────────────────────────────────
  // Step 5: setOperatorLimits
  // ──────────────────────────────────────────
  printStep(5, 'setOperatorLimits');
  try {
    const receipt = await sendTxSafe(sp, 'setOperatorLimits', [60], 'setOperatorLimits(60)');
    if (receipt) {
      const op = await sp.operators(deployerAddr);
      assertEqual(op.minTxInterval, 60n, 'minTxInterval');
    }
  } catch (e) {
    printError(`setOperatorLimits: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 6: Pause/Unpause cycle
  // ──────────────────────────────────────────
  printStep(6, 'setOperatorPaused (pause/unpause cycle)');
  try {
    // Pause
    await sendTxSafe(sp, 'setOperatorPaused', [deployerAddr, true], 'Pause operator');
    let op = await sp.operators(deployerAddr);
    assertTrue(op.isPaused, 'Operator is paused');

    // Unpause
    await sendTxSafe(sp, 'setOperatorPaused', [deployerAddr, false], 'Unpause operator');
    op = await sp.operators(deployerAddr);
    assertFalse(op.isPaused, 'Operator is unpaused');
  } catch (e) {
    printError(`Pause/unpause: ${e.message.substring(0, 80)}`);
  }

  const allPassed = printSummary('B1: Operator Config');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });
