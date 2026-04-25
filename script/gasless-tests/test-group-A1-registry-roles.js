#!/usr/bin/env node
/**
 * Test Group A1: Registry Role Lifecycle
 *
 * Tests: register community, register enduser, verify SBT, query roles.
 * Idempotent: skips already-registered roles. Uses timestamped community name.
 */
const {
  initTestEnv, getContracts, ROLES, ROLE_NAMES, ethers,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe, encodeCommunityRoleData, encodeEndUserRoleData,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group A1: Registry Role Lifecycle');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const gToken = c.gToken;
  const registry = c.registry;
  const sp = c.superPaymaster;

  const deployerAddr = deployer.address;
  const aaAccountA = process.env.TEST_AA_ACCOUNT_ADDRESS_A;
  printKeyValue('Deployer', deployerAddr);
  if (aaAccountA) printKeyValue('AA Account A', aaAccountA);

  // ──────────────────────────────────────────
  // Step 1: Check GToken balance, mint if needed
  // ──────────────────────────────────────────
  printStep(1, 'Check GToken balance for staking');
  const gBalance = await gToken.balanceOf(deployerAddr);
  const requiredGToken = ethers.parseEther('100');
  printKeyValue('GToken balance', ethers.formatEther(gBalance));

  if (gBalance < requiredGToken) {
    const gOwner = await gToken.owner();
    if (gOwner.toLowerCase() === deployerAddr.toLowerCase()) {
      const mintAmount = requiredGToken - gBalance;
      printInfo(`Minting ${ethers.formatEther(mintAmount)} GToken...`);
      await sendTxSafe(gToken, 'mint', [deployerAddr, mintAmount], 'Mint GToken');
    } else {
      printSkip(`Insufficient GToken and deployer is not GToken owner (owner: ${gOwner})`);
    }
  } else {
    printSuccess(`GToken balance sufficient: ${ethers.formatEther(gBalance)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: Approve GTokenStaking
  // ──────────────────────────────────────────
  printStep(2, 'Approve GTokenStaking for GToken');
  const stakingAddr = config.staking;
  const allowance = await gToken.allowance(deployerAddr, stakingAddr);
  if (allowance < requiredGToken) {
    await sendTxSafe(gToken, 'approve', [stakingAddr, ethers.MaxUint256], 'Approve GTokenStaking');
  } else {
    printSuccess(`Allowance already sufficient: ${ethers.formatEther(allowance)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: Register ROLE_COMMUNITY
  // ──────────────────────────────────────────
  printStep(3, 'Register ROLE_COMMUNITY for deployer');
  const hasCommunity = await registry.hasRole(ROLES.COMMUNITY, deployerAddr);
  if (hasCommunity) {
    printSkip('Deployer already has ROLE_COMMUNITY');
  } else {
    const ts = Date.now();
    const communityName = `E2ECommunity_${ts}`;
    const roleData = encodeCommunityRoleData(communityName, 'E2E test community', ethers.parseEther('30'));
    const receipt = await sendTxSafe(registry, 'registerRole', [ROLES.COMMUNITY, deployerAddr, roleData], 'registerRole(COMMUNITY)');
    if (receipt) {
      printSuccess(`Registered community: ${communityName}`);
    }
  }

  // ──────────────────────────────────────────
  // Step 4: Verify community registration
  // ──────────────────────────────────────────
  printStep(4, 'Verify community registration');
  const hasRoleNow = await registry.hasRole(ROLES.COMMUNITY, deployerAddr);
  assertTrue(hasRoleNow, 'deployer has ROLE_COMMUNITY');

  // Check SBT was minted for deployer
  try {
    const sbtBalance = await c.sbt.balanceOf(deployerAddr);
    assertGte(sbtBalance, 1n, 'Deployer SBT balance');
  } catch (e) {
    printInfo(`SBT check skipped: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 5: Register ROLE_ENDUSER for AA Account
  // ──────────────────────────────────────────
  printStep(5, 'Register ROLE_ENDUSER for AA Account');
  if (!aaAccountA) {
    printSkip('TEST_AA_ACCOUNT_ADDRESS_A not set in env');
  } else {
    const hasEnduser = await registry.hasRole(ROLES.ENDUSER, aaAccountA);
    if (hasEnduser) {
      printSkip(`AA Account ${aaAccountA} already has ROLE_ENDUSER`);
    } else {
      const roleData = encodeEndUserRoleData(deployerAddr, ethers.parseEther('0.3'));
      const receipt = await sendTxSafe(registry, 'safeMintForRole', [ROLES.ENDUSER, aaAccountA, roleData], 'safeMintForRole(ENDUSER)');
      if (receipt) {
        printSuccess(`Registered ENDUSER for ${aaAccountA}`);
      }
    }
  }

  // ──────────────────────────────────────────
  // Step 6: Verify SBT holder in SuperPaymaster
  // ──────────────────────────────────────────
  printStep(6, 'Verify sbtHolders in SuperPaymaster');
  if (aaAccountA) {
    try {
      const isSbtHolder = await sp.sbtHolders(aaAccountA);
      printKeyValue(`sbtHolders(${aaAccountA})`, isSbtHolder);
    } catch (e) {
      printInfo(`sbtHolders check: ${e.message.substring(0, 80)}`);
    }
  } else {
    printSkip('No AA account to check');
  }

  // ──────────────────────────────────────────
  // Step 7: Query getUserRoles, getRoleMembers
  // ──────────────────────────────────────────
  printStep(7, 'Query getUserRoles and getRoleMembers');
  try {
    const userRoles = await registry.getUserRoles(deployerAddr);
    printKeyValue('Deployer roles count', userRoles.length);
    for (const r of userRoles) {
      printKeyValue('  Role', ROLE_NAMES[r] || r);
    }
    assertTrue(userRoles.length > 0, 'Deployer has at least one role');
  } catch (e) {
    printError(`getUserRoles failed: ${e.message.substring(0, 80)}`);
  }

  try {
    const members = await registry.getRoleMembers(ROLES.COMMUNITY);
    printKeyValue('COMMUNITY members count', members.length);
    assertGte(members.length, 1, 'At least 1 COMMUNITY member');
  } catch (e) {
    printError(`getRoleMembers failed: ${e.message.substring(0, 80)}`);
  }

  const allPassed = printSummary('A1: Registry Roles');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });
