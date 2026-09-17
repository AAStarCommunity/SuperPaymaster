// Deploy the two baseline comparator paymasters (VerifyingPaymaster, TokenPaymaster; both
// UNCHANGED eth-infinitism v0.7 samples — see script/a6-collector/build-baseline.sh) on a
// local anvil, staked + deposited, ready for the collector to drive ops through.
//
// Local nodes only (anvil), same restriction as script/b-layer/lib.mjs.
// Usage: node script/a6-collector/deploy-baselines.mjs <rpcUrl> <outJson>
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { getAddress } from 'viem';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import { clients, deploy, send, eth, ANVIL_KEYS } from '../b-layer/lib.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const [rpcUrl, outJson, configPath] = process.argv.slice(2);
if (!rpcUrl || !outJson) {
  console.error('usage: deploy-baselines.mjs <rpcUrl> <outJson> [<deployments/config.*.json>]');
  process.exit(2);
}
// b-layer/lib.mjs's EP constant is the canonical singleton address (0x0000...7da032), which only
// exists when a chain has the ERC-2470 deterministic deployer pre-funded at genesis (b-layer's own
// anvil fixtures do this). A plain `anvil` + `deploy-core anvil` run deploys its OWN EntryPoint at
// whatever address CREATE gives it — read the real one from the deploy's own config, don't assume.
const cfg = JSON.parse(readFileSync(configPath ?? resolve(ROOT, 'deployments/config.anvil.json'), 'utf8'));
const EP = getAddress(cfg.entryPoint);
if (!/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(rpcUrl)) {
  console.error('refusing: this deploys baseline paymasters only on a local node (http://127.0.0.1:<port>)');
  process.exit(2);
}

function loadArtifact(name) {
  const j = JSON.parse(readFileSync(resolve(ROOT, 'script/a6-collector/artifacts', `${name}.json`), 'utf8'));
  return { abi: j.abi, bytecode: j.bytecode };
}

async function deployRaw(ctx, { abi, bytecode }, args) {
  const hash = await ctx.wallet.deployContract({ abi, bytecode, args, chain: null });
  const rc = await ctx.pub.waitForTransactionReceipt({ hash });
  if (rc.status !== 'success') throw new Error('deploy failed');
  return { address: getAddress(rc.contractAddress), abi };
}

const ctx = clients(rpcUrl, ANVIL_KEYS[0]);
const DUMMY = '0x000000000000000000000000000000000000dEaD';
const STAKE_ETH = eth('1'); // matches this repo's own SP anvil stake convention
const UNSTAKE_DELAY = 86_400;
const DEPOSIT_ETH = eth('10');

// ── VerifyingPaymaster ────────────────────────────────────────────────────────────────
// verifyingSigner is a fresh local-only keypair — this collector signs its own off-chain
// approvals, it is not simulating a real third-party signing service.
const verifyingSignerKey = generatePrivateKey();
const verifyingSigner = privateKeyToAccount(verifyingSignerKey);
const vpmArtifact = loadArtifact('VerifyingPaymaster');
const vpm = await deployRaw(ctx, vpmArtifact, [EP, verifyingSigner.address]);
await send(ctx, vpm.address, vpm.abi, 'deposit', [], DEPOSIT_ETH);
await send(ctx, vpm.address, vpm.abi, 'addStake', [UNSTAKE_DELAY], STAKE_ETH);
console.log(`VerifyingPaymaster ${vpm.address}  signer ${verifyingSigner.address}  deposit ${DEPOSIT_ETH} wei  stake ${STAKE_ETH} wei`);

// ── TokenPaymaster ────────────────────────────────────────────────────────────────────
// Same fixture/config recipe as script/b-layer/f1-setup.mjs's proven TokenPaymaster deploy
// (1:1 test oracle, dummy wrappedNative/uniswap since no real swap path is exercised).
const token = await deploy(ctx, 'F1Fixtures.sol', 'F1TestToken');
const oracle = await deploy(ctx, 'F1Fixtures.sol', 'F1Oracle');
const REFUND_POSTOP_COST = 40_000n;
const tpmArtifact = loadArtifact('TokenPaymaster');
const tpm = await deployRaw(ctx, tpmArtifact, [
  token.address, EP, DUMMY, DUMMY,
  { priceMarkup: 10n ** 26n, minEntryPointBalance: 0n, refundPostopCost: Number(REFUND_POSTOP_COST), priceMaxAge: 10 * 86400 },
  {
    cacheTimeToLive: 10 * 86400, maxOracleRoundAge: 10 * 86400, tokenOracle: oracle.address,
    nativeOracle: '0x0000000000000000000000000000000000000000', tokenToNativeOracle: true,
    tokenOracleReverse: false, nativeOracleReverse: false, priceUpdateThreshold: 10n ** 25n,
  },
  { minSwapAmount: 1n, uniswapPoolFee: 3000, slippage: 5 },
  ctx.account.address,
]);
await send(ctx, tpm.address, tpm.abi, 'updateCachedPrice', [true]);
await send(ctx, tpm.address, tpm.abi, 'deposit', [], DEPOSIT_ETH);
await send(ctx, tpm.address, tpm.abi, 'addStake', [UNSTAKE_DELAY], STAKE_ETH);
console.log(`TokenPaymaster ${tpm.address}  token ${token.address}  oracle ${oracle.address}  deposit ${DEPOSIT_ETH} wei  stake ${STAKE_ETH} wei`);

const out = {
  rpcUrl,
  deployedAtUtc: new Date().toISOString(),
  verifyingPaymaster: { address: vpm.address, abi: vpm.abi, signerKey: verifyingSignerKey, signer: verifyingSigner.address },
  tokenPaymaster: { address: tpm.address, abi: tpm.abi, token: token.address, oracle: oracle.address },
};
writeFileSync(outJson, JSON.stringify(out, null, 2) + '\n');
console.log(`wrote ${outJson}`);
