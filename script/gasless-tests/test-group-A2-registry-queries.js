#!/usr/bin/env node
/**
 * Test Group A2: Registry View Queries (read-only)
 *
 * Validates role constants, role configs, member counts,
 * credit tier config, and wiring addresses.
 */
const {
  initTestEnv, getContracts, ROLES, ROLE_NAMES, ethers,
  printHeader, printStep, printSuccess, printError, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertGte,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group A2: Registry View Queries');
  resetCounters();

  const { config, provider } = initTestEnv();
  const c = getContracts(config, provider);
  const registry = c.registry;
  const deployerAddr = process.env.DEPLOYER_ADDRESS || '0xb5600060e6de5E11D3636731964218E53caadf0E';

  // ──────────────────────────────────────────
  // Step 1: Verify 7 ROLE constants match keccak256
  // ──────────────────────────────────────────
  printStep(1, 'Verify ROLE constants match keccak256');

  const roleEntries = [
    ['ROLE_COMMUNITY', 'COMMUNITY'],
    ['ROLE_ENDUSER', 'ENDUSER'],
    ['ROLE_PAYMASTER_SUPER', 'PAYMASTER_SUPER'],
    ['ROLE_PAYMASTER_AOA', 'PAYMASTER_AOA'],
    ['ROLE_DVT', 'DVT'],
    ['ROLE_ANODE', 'ANODE'],
    ['ROLE_KMS', 'KMS'],
  ];

  for (const [fnName, key] of roleEntries) {
    try {
      const onChain = await registry[fnName]();
      const expected = ROLES[key];
      assertEqual(onChain, expected, `${fnName}`);
    } catch (e) {
      printError(`${fnName}: ${e.message.substring(0, 80)}`);
    }
  }

  // ──────────────────────────────────────────
  // Step 2: getRoleConfig for all 7 roles
  // ──────────────────────────────────────────
  printStep(2, 'getRoleConfig for all 7 roles');

  for (const [key, hash] of Object.entries(ROLES)) {
    try {
      const cfg = await registry.getRoleConfig(hash);
      const isActive = cfg.isActive !== undefined ? cfg.isActive : cfg[7];
      printKeyValue(`${key} isActive`, isActive);
      printKeyValue(`${key} minStake`, ethers.formatEther(cfg.minStake || cfg[0]));
    } catch (e) {
      printInfo(`${key}: getRoleConfig error (${e.message.substring(0, 60)})`);
    }
  }

  // ──────────────────────────────────────────
  // Step 3: getRoleUserCount for each role
  // ──────────────────────────────────────────
  printStep(3, 'getRoleUserCount for each role');

  for (const [key, hash] of Object.entries(ROLES)) {
    try {
      const count = await registry.getRoleUserCount(hash);
      printKeyValue(`${key} members`, count.toString());
      assertGte(count, 0n, `${key} count >= 0`);
    } catch (e) {
      printError(`${key}: ${e.message.substring(0, 80)}`);
    }
  }

  // ──────────────────────────────────────────
  // Step 4: getUserRoles for deployer
  // ──────────────────────────────────────────
  printStep(4, 'getUserRoles for deployer');
  try {
    const roles = await registry.getUserRoles(deployerAddr);
    printKeyValue('Deployer role count', roles.length);
    for (const r of roles) {
      printKeyValue('  Role', ROLE_NAMES[r] || r);
    }
    assertTrue(roles.length > 0, 'Deployer has at least one role');
  } catch (e) {
    printError(`getUserRoles: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: creditTierConfig for levels 1-6
  // ──────────────────────────────────────────
  printStep(5, 'creditTierConfig for levels 1-6');

  for (let level = 1; level <= 6; level++) {
    try {
      const limit = await registry.creditTierConfig(level);
      printKeyValue(`Tier ${level} limit`, ethers.formatEther(limit));
    } catch (e) {
      printInfo(`Tier ${level}: ${e.message.substring(0, 60)}`);
    }
  }

  // ──────────────────────────────────────────
  // Step 6: Verify wiring addresses match config.json
  // ──────────────────────────────────────────
  printStep(6, 'Verify wiring addresses match config.json');

  try {
    const stakingAddr = await registry.GTOKEN_STAKING();
    assertEqual(stakingAddr.toLowerCase(), config.staking.toLowerCase(), 'GTOKEN_STAKING');
  } catch (e) {
    printError(`GTOKEN_STAKING: ${e.message.substring(0, 80)}`);
  }

  try {
    const mysbtAddr = await registry.MYSBT();
    assertEqual(mysbtAddr.toLowerCase(), config.sbt.toLowerCase(), 'MYSBT');
  } catch (e) {
    printError(`MYSBT: ${e.message.substring(0, 80)}`);
  }

  try {
    const spAddr = await registry.SUPER_PAYMASTER();
    assertEqual(spAddr.toLowerCase(), config.superPaymaster.toLowerCase(), 'SUPER_PAYMASTER');
  } catch (e) {
    printError(`SUPER_PAYMASTER: ${e.message.substring(0, 80)}`);
  }

  const allPassed = printSummary('A2: Registry Queries');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });
