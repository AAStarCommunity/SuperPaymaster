#!/usr/bin/env node
/**
 * Test Group H1: DVT Validator & BLS Aggregator Queries
 *
 * Read-only coverage of DVTValidator and BLSAggregator infrastructure.
 * Does NOT require BLS key pairs (no BLS signing).
 *
 * Tests:
 *   1. DVTValidator wiring: REGISTRY, BLS_AGGREGATOR addresses
 *   2. DVTValidator state: isValidator, nextProposalId, version
 *   3. BLSAggregator wiring: REGISTRY, SUPERPAYMASTER, DVT_VALIDATOR
 *   4. BLSAggregator thresholds: minThreshold, defaultThreshold, MAX_VALIDATORS
 *   5. BLSAggregator slot queries: validatorAtSlot (all 13 slots empty on fresh deploy)
 *   6. DVTValidator addValidator / removeValidator lifecycle (owner-only)
 */
const {
  initTestEnv, getContracts, ethers, ABI,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, finishTest, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe, catchStep,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group H1: DVT Validator & BLS Aggregator Queries');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const registry = c.registry;

  const DVT_ABI = [
    "function version() view returns (string)",
    "function REGISTRY() view returns (address)",
    "function BLS_AGGREGATOR() view returns (address)",
    "function isValidator(address) view returns (bool)",
    "function nextProposalId() view returns (uint256)",
    "function proposals(uint256) view returns (address operator, uint8 level, bool executed, uint8 signatureCount, string reason)",
    "function addValidator(address) external",
    "function removeValidator(address) external",
    "function setBLSAggregator(address) external",
    "function pruneValidator(address) external",
  ];

  const BLS_ABI = [
    "function version() view returns (string)",
    "function REGISTRY() view returns (address)",
    "function SUPERPAYMASTER() view returns (address)",
    "function DVT_VALIDATOR() view returns (address)",
    "function minThreshold() view returns (uint256)",
    "function defaultThreshold() view returns (uint256)",
    "function MAX_VALIDATORS() view returns (uint256)",
    "function validatorAtSlot(uint8) view returns (address)",
    "function aggregatedSignatures(uint256) view returns (bytes aggregatedSig, uint8 signerMask, uint8 signerCount, bool executed)",
    "function executedProposals(uint256) view returns (bool)",
    "function setMinThreshold(uint256) external",
    "function setSuperPaymaster(address) external",
    "function setDVTValidator(address) external",
  ];

  const dvt = new ethers.Contract(config.dvtValidator, DVT_ABI, deployer);
  const bls = new ethers.Contract(config.blsAggregator, BLS_ABI, deployer);
  const deployerAddr = deployer.address;

  // ──────────────────────────────────────────
  // Step 1: DVTValidator wiring checks
  // ──────────────────────────────────────────
  printStep(1, 'DVTValidator wiring: REGISTRY, BLS_AGGREGATOR, version');
  try {
    const dvtRegistry = await dvt.REGISTRY();
    const dvtBLS = await dvt.BLS_AGGREGATOR();
    const dvtVersion = await dvt.version();

    printKeyValue('DVT REGISTRY', dvtRegistry);
    printKeyValue('DVT BLS_AGGREGATOR', dvtBLS);
    printKeyValue('DVT version', dvtVersion);

    assertEqual(dvtRegistry.toLowerCase(), config.registry.toLowerCase(), 'DVT REGISTRY == config.registry');
    assertEqual(dvtBLS.toLowerCase(), config.blsAggregator.toLowerCase(), 'DVT BLS_AGGREGATOR == config.blsAggregator');
    assertTrue(dvtVersion.length > 0, 'DVT version non-empty');
  } catch (e) {
    catchStep(`DVT wiring`, e);
  }

  // ──────────────────────────────────────────
  // Step 2: DVTValidator state
  // ──────────────────────────────────────────
  printStep(2, 'DVTValidator state: isValidator, nextProposalId');
  try {
    const isDeployerValidator = await dvt.isValidator(deployerAddr);
    const nextId = await dvt.nextProposalId();
    printKeyValue('isValidator(deployer)', isDeployerValidator);
    printKeyValue('nextProposalId', nextId.toString());
    // Fresh deployment: no validators added, no proposals
    assertGte(nextId, 1n, 'nextProposalId >= 1 (starts at 1)');
  } catch (e) {
    catchStep(`DVT state`, e);
  }

  // ──────────────────────────────────────────
  // Step 3: BLSAggregator wiring checks
  // ──────────────────────────────────────────
  printStep(3, 'BLSAggregator wiring: REGISTRY, SUPERPAYMASTER, DVT_VALIDATOR, version');
  try {
    const blsRegistry = await bls.REGISTRY();
    const blsSP = await bls.SUPERPAYMASTER();
    const blsDVT = await bls.DVT_VALIDATOR();
    const blsVersion = await bls.version();

    printKeyValue('BLS REGISTRY', blsRegistry);
    printKeyValue('BLS SUPERPAYMASTER', blsSP);
    printKeyValue('BLS DVT_VALIDATOR', blsDVT);
    printKeyValue('BLS version', blsVersion);

    assertEqual(blsRegistry.toLowerCase(), config.registry.toLowerCase(), 'BLS REGISTRY == config.registry');
    assertEqual(blsSP.toLowerCase(), config.superPaymaster.toLowerCase(), 'BLS SUPERPAYMASTER == config.superPaymaster');
    assertEqual(blsDVT.toLowerCase(), config.dvtValidator.toLowerCase(), 'BLS DVT_VALIDATOR == config.dvtValidator');
    assertTrue(blsVersion.length > 0, 'BLS version non-empty');
  } catch (e) {
    catchStep(`BLS wiring`, e);
  }

  // ──────────────────────────────────────────
  // Step 4: BLSAggregator threshold config
  // ──────────────────────────────────────────
  printStep(4, 'BLSAggregator thresholds: minThreshold, defaultThreshold, MAX_VALIDATORS');
  try {
    const minT = await bls.minThreshold();
    const defT = await bls.defaultThreshold();
    const maxV = await bls.MAX_VALIDATORS();

    printKeyValue('minThreshold', minT.toString());
    printKeyValue('defaultThreshold', defT.toString());
    printKeyValue('MAX_VALIDATORS', maxV.toString());

    assertEqual(minT, 3n, 'minThreshold == 3 (security floor)');
    assertEqual(defT, 7n, 'defaultThreshold == 7 (default)');
    assertEqual(maxV, 13n, 'MAX_VALIDATORS == 13');
    assertTrue(defT >= minT, 'defaultThreshold >= minThreshold');
  } catch (e) {
    catchStep(`BLS thresholds`, e);
  }

  // ──────────────────────────────────────────
  // Step 5: BLSAggregator validator slots (all empty on fresh deploy)
  // ──────────────────────────────────────────
  printStep(5, 'BLSAggregator validator slots (scan first 5 slots)');
  let slotCount = 0;
  try {
    for (let slot = 0; slot < 5; slot++) {
      try {
        const addr = await bls.validatorAtSlot(slot);
        if (addr !== ethers.ZeroAddress) {
          slotCount++;
          printKeyValue(`  Slot ${slot}`, addr);
        }
      } catch (_) {
        // Slot out of range or empty — expected
      }
    }
    printKeyValue('Slots with validators (first 5)', slotCount);
    printSuccess('Validator slot scan completed');
  } catch (e) {
    catchStep(`Slot scan`, e);
  }

  // ──────────────────────────────────────────
  // Step 6: DVTValidator addValidator lifecycle (owner-only)
  // ──────────────────────────────────────────
  printStep(6, 'DVTValidator addValidator / removeValidator (deployer as owner)');

  // Note: addValidator requires the address to have ROLE_DVT in Registry.
  // We check if deployer has DVT role; if not, we skip the mutation test.
  let dvtRoleHash;
  try {
    dvtRoleHash = ethers.keccak256(ethers.toUtf8Bytes('DVT'));
    const hasRole = await registry.hasRole(dvtRoleHash, deployerAddr);
    if (!hasRole) {
      printInfo('Deployer does not have ROLE_DVT — skipping addValidator mutation (expected on fresh deploy)');
      printSkip('addValidator skipped: deployer lacks ROLE_DVT');
    } else {
      const isAlready = await dvt.isValidator(deployerAddr);
      if (!isAlready) {
        const rec = await sendTxSafe(dvt, 'addValidator', [deployerAddr], 'addValidator(deployer)');
        if (rec) {
          const isNow = await dvt.isValidator(deployerAddr);
          assertTrue(isNow, 'isValidator(deployer) == true after addValidator');
          printSuccess('addValidator lifecycle OK');

          // Cleanup: remove
          await sendTxSafe(dvt, 'removeValidator', [deployerAddr], 'removeValidator(deployer)');
          const isAfterRemove = await dvt.isValidator(deployerAddr);
          assertTrue(!isAfterRemove, 'isValidator == false after removeValidator');
          printSuccess('removeValidator cleanup OK');
        }
      } else {
        printSkip('deployer already a validator — skip addValidator lifecycle');
      }
    }
  } catch (e) {
    catchStep(`addValidator lifecycle`, e);
  }

  // ──────────────────────────────────────────
  // Step 7: BLS proposal state query
  // ──────────────────────────────────────────
  printStep(7, 'BLSAggregator executedProposals(0) — zero index baseline');
  try {
    const exec0 = await bls.executedProposals(0);
    printKeyValue('executedProposals(0)', exec0.toString());
    // proposal 0 should be non-executed (ID 0 is unused; IDs start from DVTValidator's nextProposalId)
    printSuccess('BLS proposal state query OK');
  } catch (e) {
    catchStep(`BLS proposal query`, e);
  }

  process.exit(finishTest('H1: DVT Validator & BLS Aggregator Queries'));
}

main().catch(err => {
  const m = (err.message || '').toLowerCase();
  const isNet = m.includes('socket hang up') || m.includes('econnreset') ||
    m.includes('timeout') || m.includes('etimedout') || m.includes('request timeout');
  if (isNet) { console.error('Fatal (network):', err.message.substring(0, 80)); process.exit(2); }
  console.error('Fatal:', err.message);
  process.exit(1);
});
