// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
/**
 * Shared TX utilities for the raw-ethers E2E tests that do NOT go through
 * test-helpers' sendTxSafe (micropayment / x402 / bls). These tests historically
 * called bare `tx.wait()` with no timeout and sent txs with ethers' default fee,
 * which produced two failure modes on Sepolia:
 *
 *   1. A tx stuck in the mempool hangs the process forever — `tx.wait()` polls
 *      with no deadline. On 2026-06-13 a single stuck settle tx hung the whole
 *      37-test suite for 26 minutes. waitTx() puts a hard ceiling on the wait.
 *
 *   2. A tx sent with ethers' default fee can be under-priced when Sepolia's
 *      baseFee rises after the gas estimate, and then sits unmined indefinitely.
 *      feeOverrides() bumps maxFeePerGas well above the current baseFee so the tx
 *      stays mineable.
 *
 * Both are deliberately small and dependency-free (ethers only) so any standalone
 * test can `require('./tx-utils')` without pulling in the full test-helpers stack.
 */
const { ethers } = require('ethers');

// Hard ceiling for a single tx confirmation. Sepolia blocks are ~12s; a healthy
// tx confirms in 1-2 blocks. 90s tolerates a short backlog without letting a
// truly stuck tx hang. Override with TX_WAIT_TIMEOUT_MS.
const TX_WAIT_TIMEOUT_MS = parseInt(process.env.TX_WAIT_TIMEOUT_MS || '90000', 10);

/**
 * Wait for a tx with a hard timeout. Returns the receipt, or throws a tagged
 * Error so a stuck tx is treated as a definite failure rather than an infinite
 * hang. ethers v6 `tx.wait(confirms, timeoutMs)` rejects (code 'TIMEOUT') once
 * the deadline passes — the tx may still mine later, but the test stops waiting.
 *
 * @param {ethers.TransactionResponse} tx
 * @param {string} label   short label for error messages
 * @param {number} timeoutMs
 * @returns {Promise<ethers.TransactionReceipt>}
 */
async function waitTx(tx, label = 'tx', timeoutMs = TX_WAIT_TIMEOUT_MS) {
  try {
    return await tx.wait(1, timeoutMs);
  } catch (e) {
    const msg = ((e && e.message) || '').toLowerCase();
    if (e && (e.code === 'TIMEOUT' || msg.includes('timeout') || msg.includes('wait for transaction'))) {
      // Tag with code='TIMEOUT' so isNetworkError() recognizes it and sendAndWait
      // retries (a wait-timeout means the tx is still in-flight; the message text
      // deliberately omits "timeout" so callers' message-based SKIP heuristics
      // treat a genuinely stuck standalone tx as FAIL, not a transient skip).
      const err = new Error(
        `${label}: tx ${tx.hash} not mined within ${Math.round(timeoutMs / 1000)}s ` +
        `(stuck in mempool — likely under-priced; re-run after the mempool clears)`
      );
      err.code = 'TIMEOUT';
      throw err;
    }
    throw e;
  }
}

/**
 * Build a fee-override object that bumps maxFeePerGas safely above the current
 * baseFee, so the tx stays mineable even if baseFee rises a little after send.
 * Merges any `extra` overrides (e.g. { gasLimit }). Falls back to just `extra`
 * (let ethers decide the fee) if fee data can't be read.
 *
 * @param {ethers.Provider} provider
 * @param {object} extra   extra tx overrides to merge (e.g. { gasLimit: 200000 })
 */
async function feeOverrides(provider, extra = {}) {
  try {
    const fd = await provider.getFeeData();
    const priority = fd.maxPriorityFeePerGas && fd.maxPriorityFeePerGas > 0n
      ? fd.maxPriorityFeePerGas
      : ethers.parseUnits('2', 'gwei');
    // fd.maxFeePerGas already ≈ 2*baseFee + priority from ethers; bump it again so
    // a rising baseFee between estimate and mine can't strand the tx.
    const ceiling = fd.maxFeePerGas && fd.maxFeePerGas > 0n
      ? fd.maxFeePerGas
      : ethers.parseUnits('20', 'gwei');
    return { maxFeePerGas: ceiling * 2n + priority, maxPriorityFeePerGas: priority, ...extra };
  } catch (_) {
    return { ...extra };
  }
}

// Network-error matcher (transport failures that are safe to retry — the call
// either never reached the node or we can re-confirm by tx hash). Deliberately
// excludes revert reasons, which must surface, not retry.
function isNetworkError(e) {
  const msg = ((e && (e.message || e.shortMessage)) || '').toLowerCase();
  const code = (e && e.code) || '';
  return /etimedout|econnreset|econnrefused|socket hang up|timeout|503|502|429|could not detect|failed to detect|server_error|network error|connection (reset|refused)|fetch failed|terminated/.test(msg)
    || ['TIMEOUT', 'NETWORK_ERROR', 'SERVER_ERROR', 'ECONNRESET', 'ETIMEDOUT'].includes(code);
}

// Nonce/in-flight conflicts — also retryable (re-read nonce on the next attempt).
function isNonceError(e) {
  const msg = ((e && (e.message || e.shortMessage)) || '').toLowerCase();
  return /nonce (too low|has already been used|expired)|replacement transaction underpriced|already known|in-flight transaction limit|could not coalesce/.test(msg);
}

/**
 * Retry a read-only call across transient network errors. View calls over a
 * flaky public RPC fail spuriously; a single ETIMEDOUT should never abort setup.
 *
 * @param {() => Promise<any>} fn
 * @param {string} label
 * @param {number} maxRetries
 */
async function retryView(fn, label = 'view', maxRetries = 5) {
  let lastErr;
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (e) {
      lastErr = e;
      if (isNetworkError(e) && attempt < maxRetries) {
        await new Promise((r) => setTimeout(r, attempt * 2000));
        continue;
      }
      throw e;
    }
  }
  throw lastErr;
}

/**
 * Send a state-changing tx and confirm it, surviving a flaky RPC — WITHOUT ever
 * double-applying the write. The critical invariant: every retry reuses the SAME
 * pinned nonce, so at most one tx in that slot can ever mine. A naive resend
 * would let ethers pick `getNonce('pending')`, which advances after our first
 * broadcast, landing a SECOND tx at a fresh nonce — i.e. a mint/deposit applied
 * twice. Pinning the nonce makes a resend a *replacement* of the same slot.
 *
 * Strategy per attempt:
 *   - reuse the pinned nonce; raise the fee ≥15% over our previous send so a
 *     resend is a valid replacement (also ≥ the current network estimate), which
 *     both prevents "replacement underpriced" and un-stalls an under-priced tx;
 *   - on ANY error, first check whether a tx we already broadcast at this nonce
 *     actually mined (covers wait-timeout, "nonce too low" = ours mined, and
 *     "already known"/"replacement underpriced" = still pending) and return it;
 *   - otherwise retry network/nonce errors with the bumped fee.
 * Net effect: each write "eventually submits exactly once" even on an unstable
 * network — the project's hard requirement.
 *
 * @param {ethers.Contract} contract  contract connected to a signer
 * @param {string} method
 * @param {any[]} args
 * @param {string} label
 * @param {{gasLimit?: number|bigint, maxRetries?: number}} opts
 * @returns {Promise<ethers.TransactionReceipt>}
 */
async function sendAndWait(contract, method, args, label, opts = {}) {
  const { gasLimit, maxRetries = 5 } = opts;
  const signer = contract.runner;
  const provider = signer.provider;

  // Pin the nonce up front so every retry replaces the SAME slot, never a second
  // tx at a fresh nonce. Retry the read itself — if we truly can't get it, fall
  // back to ethers' default (rare; only under sustained RPC failure).
  let nonce = null;
  try {
    nonce = await retryView(() => signer.getNonce('pending'), `${label} nonce`);
  } catch (_) {
    nonce = null;
  }

  let lastHash = null;
  let lastMaxFee = 0n;
  let lastPrio = 0n;
  let lastErr;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      const base = await feeOverrides(provider, gasLimit != null ? { gasLimit } : {});
      let maxFee = base.maxFeePerGas || 0n;
      let prio = base.maxPriorityFeePerGas || 0n;
      // A replacement must out-bid the prior send by ≥10% (use 15%), and must not
      // drop below the current network estimate either.
      if (lastMaxFee > 0n && maxFee < (lastMaxFee * 115n) / 100n) maxFee = (lastMaxFee * 115n) / 100n;
      if (lastPrio > 0n && prio < (lastPrio * 115n) / 100n) prio = (lastPrio * 115n) / 100n;
      const overrides = { ...base };
      if (nonce != null) overrides.nonce = nonce;
      if (maxFee > 0n) overrides.maxFeePerGas = maxFee;
      if (prio > 0n) overrides.maxPriorityFeePerGas = prio;

      const tx = await contract[method](...args, overrides);
      lastHash = tx.hash;
      lastMaxFee = maxFee;
      lastPrio = prio;
      const receipt = await waitTx(tx, label);
      // Emit the on-chain hash + explorer link for a verifiable evidence trail.
      console.log(`  ${label}: TX confirmed (gas: ${receipt.gasUsed}) tx=${tx.hash} https://sepolia.etherscan.io/tx/${tx.hash}`);
      return receipt;
    } catch (e) {
      lastErr = e;
      // Whatever the error, FIRST see if a tx we already broadcast at this nonce
      // mined. Covers: wait-timeout (it confirmed late), "nonce too low" (ours
      // mined so the resend was rejected — lastHash still points at it), and
      // "already known"/"replacement underpriced" (the prior one is still in the
      // mempool). Never resend when it already mined — that's the duplicate trap.
      // A mined-but-REVERTED tx (status 0) must surface as a failure, never be
      // returned as success — otherwise we'd mask an on-chain revert (the receipt
      // exists, but the call failed).
      if (lastHash) {
        const r = await provider.getTransactionReceipt(lastHash).catch(() => null);
        if (r) {
          if (r.status === 0) {
            const revErr = new Error(`${label}: tx ${lastHash} reverted on-chain (status 0)`);
            revErr.code = 'CALL_EXCEPTION';
            throw revErr;
          }
          console.log(`  ${label}: TX confirmed (late) tx=${lastHash} https://sepolia.etherscan.io/tx/${lastHash}`);
          return r;
        }
      }
      if ((isNetworkError(e) || isNonceError(e)) && attempt < maxRetries) {
        const kind = isNetworkError(e) ? 'network' : 'nonce';
        const reason = ((e && (e.message || e.shortMessage)) || '').slice(0, 60);
        console.log(`  ⚠️  ${label}: ${kind} error (${reason}) — retry ${attempt}/${maxRetries - 1} (same nonce${nonce != null ? ` ${nonce}` : ''}, bumped fee) in ${attempt * 3}s`);
        await new Promise((r) => setTimeout(r, attempt * 3000));
        continue;
      }
      throw e;
    }
  }
  throw lastErr;
}

// Per-request timeout for RPC calls. ethers v6's default FetchRequest timeout is
// 300s, so a hung view call would block until the suite's own kill-switch fires
// (exactly the 300s E1 TIMEOUT we saw). 20s lets a stuck read fail fast and retry.
const RPC_REQUEST_TIMEOUT_MS = parseInt(process.env.RPC_REQUEST_TIMEOUT_MS || '20000', 10);

/**
 * Build a JsonRpcProvider hardened for a flaky public RPC:
 *   - a short per-request timeout (so a hung view fails fast instead of blocking
 *     until the suite kill-switch fires);
 *   - automatic retry of idempotent reads on transient network errors, so a lone
 *     socket-hangup / timeout doesn't fail the test.
 * Writes (eth_sendRawTransaction) are NEVER auto-retried at the provider layer —
 * a lost response may mean the tx was already broadcast; sendAndWait owns write
 * retries and does so safely (pinned nonce + fee bump).
 *
 * @param {string} rpcUrl
 * @param {number} chainId
 * @returns {ethers.JsonRpcProvider}
 */
function makeProvider(rpcUrl, chainId = 11155111) {
  const fr = new ethers.FetchRequest(rpcUrl);
  fr.timeout = RPC_REQUEST_TIMEOUT_MS;
  // staticNetwork avoids the initial eth_chainId auto-detect that can fail under load.
  const provider = new ethers.JsonRpcProvider(fr, chainId, { staticNetwork: true });

  // Redundant-broadcast targets (comma-separated public RPCs in E2E_BROADCAST_RPCS).
  // The PRIMARY rpcUrl stays the source of truth for reads — keeping the production
  // RPC (e.g. Alchemy) under test — but every raw tx is ALSO pushed to these public
  // RPCs. This defeats a primary that accepts-but-doesn't-propagate a tx (observed
  // with Alchemy on Sepolia: tx returns a hash yet never reaches block producers,
  // stranding it and inflating the pending nonce). With redundant broadcast the tx
  // actually mines, so the primary's nonce view self-heals. Empty → primary only.
  const broadcasters = (process.env.E2E_BROADCAST_RPCS || '')
    .split(',').map((s) => s.trim()).filter(Boolean)
    .map((u) => {
      const f = new ethers.FetchRequest(u);
      f.timeout = RPC_REQUEST_TIMEOUT_MS;
      return new ethers.JsonRpcProvider(f, chainId, { staticNetwork: true });
    });

  const origSend = provider.send.bind(provider);
  const NON_RETRYABLE = new Set(['eth_sendRawTransaction', 'eth_sendTransaction']);
  provider.send = async function (method, params) {
    // Fan a raw-tx broadcast out to the public fallbacks too (fire-and-forget;
    // "already known"/dup errors from them are expected and ignored).
    if (method === 'eth_sendRawTransaction' && broadcasters.length) {
      for (const b of broadcasters) b.send(method, params).catch(() => {});
    }
    const canRetry = !NON_RETRYABLE.has(method);
    const MAX = 5;
    let lastErr;
    for (let i = 0; i <= MAX; i++) {
      try {
        return await origSend(method, params);
      } catch (e) {
        lastErr = e;
        if (!canRetry || !isNetworkError(e) || i === MAX) throw e;
        await new Promise((r) => setTimeout(r, 600 * (i + 1)));
      }
    }
    throw lastErr;
  };
  return provider;
}

module.exports = { waitTx, feeOverrides, sendAndWait, retryView, makeProvider, isNetworkError, isNonceError, TX_WAIT_TIMEOUT_MS, RPC_REQUEST_TIMEOUT_MS };
