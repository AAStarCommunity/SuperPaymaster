#!/usr/bin/env node
/**
 * Test Group F1: Staking Queries (read-only)
 *
 * Tests: totalStaked, GToken totalSupply, stakes, balanceOf,
 * getLockedStake, previewExitFee, wiring addresses.
 */
const {
  initTestEnv, getContracts, ROLES, ethers,
  printHeader, printStep, printSuccess, printError, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertGte,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group F1: Staking Queries');
  resetCounters();

  const { config, provider } = initTestEnv();
  const c = getContracts(config, provider);
  const staking = c.staking;
  const gToken = c.gToken;

  const deployerAddr = process.env.DEPLOYER_ADDRESS || '0xb5600060e6de5E11D3636731964218E53caadf0E';

  // ──────────────────────────────────────────
  // Step 1: totalStaked
  // ──────────────────────────────────────────
  printStep(1, 'totalStaked');
  try {
    const total = await staking.totalStaked();
    printKeyValue('Total staked', ethers.formatEther(total));
    assertGte(total, 0n, 'totalStaked >= 0');
  } catch (e) {
    printError(`totalStaked: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: GToken totalSupply
  // ──────────────────────────────────────────
  printStep(2, 'GToken totalSupply');
  try {
    const supply = await gToken.totalSupply();
    printKeyValue('GToken totalSupply', ethers.formatEther(supply));

    const cap = await gToken.cap();
    printKeyValue('GToken cap', ethers.formatEther(cap));
    assertTrue(supply <= cap, 'Supply <= cap');
  } catch (e) {
    printError(`GToken supply: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: stakes(deployer)
  // ──────────────────────────────────────────
  printStep(3, 'stakes(deployer)');
  try {
    const stake = await staking.stakes(deployerAddr);
    printKeyValue('amount', ethers.formatEther(stake.amount));
    printKeyValue('slashedAmount', ethers.formatEther(stake.slashedAmount));
    if (stake.stakedAt > 0n) {
      printKeyValue('stakedAt', new Date(Number(stake.stakedAt) * 1000).toISOString());
    } else {
      printKeyValue('stakedAt', '0 (not staked)');
    }
    assertTrue(stake.amount >= 0n, 'Stake amount valid');
  } catch (e) {
    printError(`stakes: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 4: balanceOf(deployer)
  // ──────────────────────────────────────────
  printStep(4, 'balanceOf(deployer) - net stake balance');
  try {
    const balance = await staking.balanceOf(deployerAddr);
    printKeyValue('Net stake balance', ethers.formatEther(balance));
    assertGte(balance, 0n, 'Balance >= 0');
  } catch (e) {
    printError(`balanceOf: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: getLockedStake for ROLE_COMMUNITY
  // ──────────────────────────────────────────
  printStep(5, 'getLockedStake(deployer, ROLE_COMMUNITY)');
  try {
    const locked = await staking.getLockedStake(deployerAddr, ROLES.COMMUNITY);
    printKeyValue('Locked for COMMUNITY', ethers.formatEther(locked));
    assertGte(locked, 0n, 'Locked stake >= 0');
  } catch (e) {
    printError(`getLockedStake: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 6: previewExitFee for ROLE_COMMUNITY
  // ──────────────────────────────────────────
  printStep(6, 'previewExitFee(deployer, ROLE_COMMUNITY)');
  try {
    const hasLock = await staking.hasRoleLock(deployerAddr, ROLES.COMMUNITY);
    if (!hasLock) {
      printInfo('No role lock for COMMUNITY, skipping previewExitFee');
    } else {
      const [fee, netAmount] = await staking.previewExitFee(deployerAddr, ROLES.COMMUNITY);
      printKeyValue('Exit fee', ethers.formatEther(fee));
      printKeyValue('Net amount', ethers.formatEther(netAmount));
      assertGte(fee, 0n, 'Exit fee >= 0');
    }
    printSuccess('previewExitFee check complete');
  } catch (e) {
    printError(`previewExitFee: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 7: Verify wiring addresses
  // ──────────────────────────────────────────
  printStep(7, 'Verify staking wiring');
  try {
    const registryAddr = await staking.REGISTRY();
    assertEqual(registryAddr.toLowerCase(), config.registry.toLowerCase(), 'REGISTRY');
  } catch (e) {
    printError(`REGISTRY: ${e.message.substring(0, 80)}`);
  }

  try {
    const gtokenAddr = await staking.GTOKEN();
    assertEqual(gtokenAddr.toLowerCase(), config.gToken.toLowerCase(), 'GTOKEN');
  } catch (e) {
    printError(`GTOKEN: ${e.message.substring(0, 80)}`);
  }

  try {
    const treasuryAddr = await staking.treasury();
    printKeyValue('Treasury', treasuryAddr);
    assertTrue(treasuryAddr !== ethers.ZeroAddress, 'Treasury is set');
  } catch (e) {
    printError(`treasury: ${e.message.substring(0, 80)}`);
  }

  const allPassed = printSummary('F1: Staking Queries');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });
