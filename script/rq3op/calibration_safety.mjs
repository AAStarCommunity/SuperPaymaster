export function redact(value, opaque = false) {
  // Upstream errors may echo bare credentials or entire files.
  return opaque ? '<upstream details redacted>' : String(value).replace(/(?:https?|wss?):\/\/[^\s"'<>]+/gi, '<redacted-url>');
}

export async function requireFork(req, rpc, alive = pid => process.kill(pid, 0)) {
  if (!Number.isSafeInteger(req.forkPid) || req.forkPid <= 0 || !Number.isSafeInteger(req.forkPin) || req.forkPin < 0) {
    throw Error('child anvil PID and fork pin required');
  }
  try {
    alive(req.forkPid);
    const client = await rpc('web3_clientVersion');
    if (typeof client !== 'string' || !client.toLowerCase().startsWith('anvil')) throw Error();
    let block;
    try { block = (await rpc('anvil_nodeInfo')).forkConfig.forkBlockNumber; }
    catch { block = (await rpc('anvil_metadata')).forkedNetwork.forkBlockNumber; }
    if (block == null || BigInt(block) !== BigInt(req.forkPin)) throw Error();
    alive(req.forkPid);
  } catch {
    throw Error('endpoint is not a live child anvil at requested fork pin');
  }
}
