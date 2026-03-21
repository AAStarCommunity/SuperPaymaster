#!/usr/bin/env node
/**
 * Test Group E1: Pricing & Oracle
 *
 * Tests: cachedPrice, updatePrice, aPNTsPriceUSD, setAPNTSPrice,
 * Chainlink priceFeed direct read, PaymasterV4 updatePrice.
 */
const {
  initTestEnv, getContracts, ethers, ABI,
  printHeader, printStep, printSuccess, printError, printSkip, printInfo, printKeyValue,
  printSummary, resetCounters,
  assertEqual, assertTrue, assertGte,
  sendTxSafe,
} = require('./test-helpers');

async function main() {
  printHeader('Test Group E1: Pricing & Oracle');
  resetCounters();

  const { config, provider, deployer } = initTestEnv();
  const c = getContracts(config, deployer);
  const sp = c.superPaymaster;
  const priceFeed = c.priceFeed;

  // ──────────────────────────────────────────
  // Step 1: Read cachedPrice
  // ──────────────────────────────────────────
  printStep(1, 'Read cachedPrice');
  try {
    const cached = await sp.cachedPrice();
    printKeyValue('Price (raw)', cached.price.toString());
    printKeyValue('Updated at', new Date(Number(cached.updatedAt) * 1000).toISOString());
    printKeyValue('Round ID', cached.roundId.toString());
    printKeyValue('Decimals', cached.decimals.toString());

    const priceUsd = Number(cached.price) / Math.pow(10, Number(cached.decimals));
    printKeyValue('ETH/USD', `$${priceUsd.toFixed(2)}`);
    assertTrue(cached.price > 0n, 'Cached price > 0');
  } catch (e) {
    printError(`cachedPrice: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 2: updatePrice
  // ──────────────────────────────────────────
  printStep(2, 'updatePrice');
  try {
    await sendTxSafe(sp, 'updatePrice', [], 'updatePrice()');
    const cached = await sp.cachedPrice();
    printKeyValue('New updatedAt', new Date(Number(cached.updatedAt) * 1000).toISOString());
    printSuccess('Price cache updated');
  } catch (e) {
    printError(`updatePrice: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 3: Read aPNTsPriceUSD
  // ──────────────────────────────────────────
  printStep(3, 'Read aPNTsPriceUSD');
  let originalPrice = 0n;
  try {
    originalPrice = await sp.aPNTsPriceUSD();
    printKeyValue('aPNTsPriceUSD', ethers.formatEther(originalPrice));
    assertGte(originalPrice, 0n, 'aPNTsPriceUSD >= 0');
  } catch (e) {
    printError(`aPNTsPriceUSD: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 4: setAPNTSPrice cycle
  // ──────────────────────────────────────────
  printStep(4, 'setAPNTSPrice (set -> verify -> restore)');
  const testPrice = ethers.parseEther('0.03');
  try {
    // Set new price
    await sendTxSafe(sp, 'setAPNTSPrice', [testPrice], 'setAPNTSPrice(0.03)');
    const newPrice = await sp.aPNTsPriceUSD();
    assertEqual(newPrice, testPrice, 'aPNTsPriceUSD set to 0.03');

    // Restore original
    if (originalPrice > 0n) {
      await sendTxSafe(sp, 'setAPNTSPrice', [originalPrice], `Restore aPNTsPriceUSD(${ethers.formatEther(originalPrice)})`);
      const restored = await sp.aPNTsPriceUSD();
      assertEqual(restored, originalPrice, 'aPNTsPriceUSD restored');
    }
  } catch (e) {
    printError(`setAPNTSPrice: ${e.message.substring(0, 80)}`);
    // Try to restore on error
    if (originalPrice > 0n) {
      try { await sp.setAPNTSPrice(originalPrice); } catch (_) {}
    }
  }

  // ──────────────────────────────────────────
  // Step 5: Chainlink priceFeed direct read
  // ──────────────────────────────────────────
  printStep(5, 'Chainlink priceFeed.latestRoundData()');
  try {
    const data = await priceFeed.latestRoundData();
    const decimals = await priceFeed.decimals();
    const desc = await priceFeed.description();
    const priceUsd = Number(data.answer) / Math.pow(10, Number(decimals));

    printKeyValue('Feed description', desc);
    printKeyValue('Answer (raw)', data.answer.toString());
    printKeyValue('Price', `$${priceUsd.toFixed(2)}`);
    printKeyValue('Decimals', decimals.toString());
    printKeyValue('Updated at', new Date(Number(data.updatedAt) * 1000).toISOString());
    assertTrue(data.answer > 0n, 'Chainlink price > 0');
  } catch (e) {
    printError(`priceFeed: ${e.message.substring(0, 80)}`);
  }

  // ──────────────────────────────────────────
  // Step 6: PaymasterV4 updatePrice
  // ──────────────────────────────────────────
  printStep(6, 'PaymasterV4 updatePrice');
  const operatorAddr = process.env.OPERATOR_ADDRESS || deployer.address;
  try {
    const factory = c.paymasterFactory;
    const pmV4Addr = await factory.paymasterByOperator(operatorAddr);
    if (pmV4Addr === ethers.ZeroAddress) {
      printSkip('No PaymasterV4 for operator');
    } else {
      const pmV4 = new ethers.Contract(pmV4Addr, ABI.PaymasterV4, deployer);
      await sendTxSafe(pmV4, 'updatePrice', [], 'PaymasterV4.updatePrice()');

      const cached = await pmV4.cachedPrice();
      const v4Price = cached.price || cached[0];
      const v4UpdatedAt = cached.updatedAt || cached[1];
      printKeyValue('V4 cached price', v4Price.toString());
      printKeyValue('V4 cached updatedAt', new Date(Number(v4UpdatedAt) * 1000).toISOString());
      printSuccess('PaymasterV4 price updated');
    }
  } catch (e) {
    printError(`PaymasterV4 updatePrice: ${e.message.substring(0, 80)}`);
  }

  const allPassed = printSummary('E1: Pricing & Oracle');
  process.exit(allPassed ? 0 : 1);
}

main().catch(err => { console.error('Fatal:', err.message); process.exit(1); });
